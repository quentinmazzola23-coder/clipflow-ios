//
//  PlayerView.swift
//  ClipFlow
//
//  Visionneuse basée sur les PROXYS (jamais les 4K pendant la navigation).
//  Gère : lecture simple, lecture en boucle d'une sélection, seek de scrubbing
//  à tolérance nulle (proxys tout-intra → seek instantané).
//

import SwiftUI
import AVFoundation
import AVKit
import Observation

@MainActor
@Observable
final class ProxyPlaybackEngine {

    let player = AVPlayer()
    private var currentKey: String?
    private var loopRange: CMTimeRange?
    private var timeObserver: Any?
    private(set) var isPlaying = false

    /// Prévisualisation au ralenti 0,5× (bascule tortue). N'affecte que la
    /// lecture — l'export n'en dépend jamais. La préview 0,5× est saccadée
    /// (pas d'interpolation ici) ; le rendu final, lui, est interpolé.
    var slowPreview = false
    private var playbackRate: Float { slowPreview ? 0.5 : 1.0 }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        // Observation périodique pour le bouclage de sélection.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let range = self.loopRange, self.isPlaying else { return }
                if CMTimeCompare(time, range.end) >= 0 {
                    await self.player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    /// Charge la meilleure source de lecture d'un rush : proxy si prêt,
    /// sinon repli sur le fichier ORIGINAL (décodage matériel AVPlayer —
    /// permet de visualiser immédiatement pendant la génération des proxys).
    func load(rush: Rush?) {
        var url: URL?
        if let proxyPath = rush?.proxyRelativePath {
            let candidate = StorageManager.url(forProxyRelativePath: proxyPath)
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        if url == nil, let sourcePath = rush?.localSourceRelativePath {
            let candidate = StorageManager.url(forSourceRelativePath: sourcePath)
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        let key = url?.path
        guard key != currentKey else { return }
        currentKey = key
        loopRange = nil
        pause()
        guard let url else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    /// Positionne la lecture (scrubbing) — tolérance nulle, proxy tout-intra.
    func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() {
        loopRange = nil
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    /// Lecture en boucle d'une plage (sélection ou rush entier).
    func playLoop(range: CMTimeRange) {
        loopRange = range
        player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    /// Applique immédiatement le changement de vitesse si une lecture est en cours.
    func refreshRate() {
        if isPlaying {
            player.rate = playbackRate
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
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
