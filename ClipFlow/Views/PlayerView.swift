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
    private var currentProxyPath: String?
    private var loopRange: CMTimeRange?
    private var timeObserver: Any?
    private(set) var isPlaying = false

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

    /// Charge le proxy d'un rush (sans relancer si déjà chargé).
    func load(proxyPath: String?) {
        guard proxyPath != currentProxyPath else { return }
        currentProxyPath = proxyPath
        loopRange = nil
        pause()
        guard let proxyPath else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let url = StorageManager.url(forProxyRelativePath: proxyPath)
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    /// Positionne la lecture (scrubbing) — tolérance nulle, proxy tout-intra.
    func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play() {
        loopRange = nil
        player.play()
        isPlaying = true
    }

    /// Lecture en boucle de la sélection uniquement.
    func playLoop(range: CMTimeRange) {
        loopRange = range
        player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
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
