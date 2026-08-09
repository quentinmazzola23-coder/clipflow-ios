//
//  PlayerView.swift
//  ClipFlow
//
//  Moteur de lecture basé sur AVQueuePlayer + AVPlayerLooper :
//  les boucles de sélection sont SANS COUTURE (le système précharge
//  l'itération suivante — aucun hoquet au rebouclage, contrairement à un
//  seek manuel qui redécode depuis l'image clé à chaque tour).
//
//  Pendant le déplacement de la sélection, un mode « boucle légère »
//  (seeks coalescés) suit le doigt ; au relâcher, la vraie boucle
//  AVPlayerLooper prend le relais.
//

import SwiftUI
import AVFoundation
import AVKit
import Observation

@MainActor
@Observable
final class ProxyPlaybackEngine {

    let player = AVQueuePlayer()

    private var currentURL: URL?
    private var looper: AVPlayerLooper?
    private var looperDuration: Double?
    /// Boucle légère du mode glissement (seeks coalescés, sans looper).
    private var manualLoopRange: CMTimeRange?
    private var seekInFlight = false
    private var pendingSeekTarget: CMTime?
    private var timeObserver: Any?
    private(set) var isPlaying = false

    /// Prévisualisation au ralenti 0,5× (bascule tortue). Lecture uniquement.
    var slowPreview = false
    private var playbackRate: Float { slowPreview ? 0.5 : 1.0 }

    /// Aperçu léger : 540p au lieu de 720p (réserve de décodeur).
    var lightPreview = false

    /// Coupe le son de la prévisualisation (persiste à travers les items :
    /// propriété du player, pas de l'item).
    var muted: Bool = false {
        didSet { player.isMuted = muted }
    }

    /// Rappel périodique pendant la lecture (suivi de timeline).
    var onTick: ((CMTime) -> Void)?

    /// Durée de la boucle active (nil si lecture libre).
    var activeLoopDuration: Double? { looperDuration ?? manualLoopRange?.duration.seconds }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        // 30 Hz suffisent au suivi de timeline et au rebouclage léger —
        // moitié moins de travail sur le fil principal qu'à 60 Hz.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.onTick?(time)
                // Rebouclage de la boucle LÉGÈRE uniquement (le looper gère la sienne).
                if let range = self.manualLoopRange,
                   CMTimeCompare(time, range.end) >= 0 {
                    self.requestSeek(to: range.start)
                }
            }
        }
    }

    // MARK: - Chargement

    private func makeItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        // Plafond 720p (ou 540p en aperçu léger) : netteté suffisante pour
        // juger, décodage léger. L'export lit toujours la pleine résolution.
        item.preferredMaximumResolution = lightPreview
            ? CGSize(width: 960, height: 540)
            : CGSize(width: 1280, height: 720)
        return item
    }

    /// Rebâtit l'item courant après un changement de qualité d'aperçu.
    func applyPreviewQualityChange() {
        guard let currentURL else { return }
        let wasPlaying = isPlaying
        teardownLoops()
        pause()
        player.removeAllItems()
        player.insert(makeItem(url: currentURL), after: nil)
        if wasPlaying { play() }
    }

    /// Charge le fichier ORIGINAL du rush (lecture directe, sans proxys).
    func load(rush: Rush?) {
        var url: URL?
        if let sourcePath = rush?.localSourceRelativePath {
            let candidate = StorageManager.url(forSourceRelativePath: sourcePath)
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        guard url?.path != currentURL?.path else { return }
        currentURL = url
        teardownLoops()
        pause()
        player.removeAllItems()
        if let url {
            player.insert(makeItem(url: url), after: nil)
        }
    }

    private func teardownLoops() {
        looper?.disableLooping()
        looper = nil
        looperDuration = nil
        manualLoopRange = nil
    }

    // MARK: - Transport

    /// Positionne la lecture (scrubbing) — tolérance nulle.
    func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Lecture libre (sans boucle).
    func play() {
        teardownLoops()
        rebuildSingleItemIfNeeded()
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    /// Boucle SANS COUTURE d'une plage : AVPlayerLooper précharge chaque
    /// itération — aucun hoquet au rebouclage.
    func playLoop(range: CMTimeRange) {
        guard let currentURL else { return }
        teardownLoops()
        player.pause()
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: makeItem(url: currentURL), timeRange: range)
        looperDuration = range.duration.seconds
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    /// Boucle LÉGÈRE pendant le glissement de la sélection : relance la
    /// lecture depuis le nouveau début à chaque mouvement, avec des seeks
    /// coalescés (jamais plus d'un seek en vol — pas de tempête de seeks).
    func dragLoop(range: CMTimeRange) {
        if looper != nil {
            looper?.disableLooping()
            looper = nil
            looperDuration = nil
            rebuildSingleItemIfNeeded()
        }
        manualLoopRange = range
        requestSeek(to: range.start)
        if !isPlaying {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// Applique immédiatement le changement de vitesse si une lecture est en cours.
    func refreshRate() {
        if isPlaying {
            player.rate = playbackRate
        }
    }

    // MARK: - Interne

    /// Après un looper, la file contient les items de boucle : reconstruire
    /// un item simple pour la lecture libre / le scrubbing.
    private func rebuildSingleItemIfNeeded() {
        guard let currentURL else { return }
        if player.items().count != 1 || player.currentItem == nil {
            player.removeAllItems()
            player.insert(makeItem(url: currentURL), after: nil)
        }
    }

    /// Seek coalescé : si un seek est déjà en vol, mémorise la dernière cible
    /// et l'exécute à la fin du seek courant.
    private func requestSeek(to target: CMTime) {
        guard !seekInFlight else {
            pendingSeekTarget = target
            return
        }
        seekInFlight = true
        player.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: CMTime(value: 1, timescale: 30)
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seekInFlight = false
                if let pending = self.pendingSeekTarget {
                    self.pendingSeekTarget = nil
                    self.requestSeek(to: pending)
                }
            }
        }
    }
}

/// Vue AVPlayerLayer sans les commandes système.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}
