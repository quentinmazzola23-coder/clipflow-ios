//
//  TimelineView.swift
//  ClipFlow
//
//  Timeline tactile virtualisée. Une seule vue UIKit (UIScrollView + CALayers
//  recyclées) — jamais une vue SwiftUI par miniature. Seule la zone visible
//  est peuplée ; miniatures issues des proxys via ThumbnailCache.
//
//  Tête de lecture fixe au centre ; faire défiler la timeline = scrubbing.
//  Gestes : toucher (créer sélection), glisser la sélection (déplacer),
//  pincer (zoom), appui long sur la sélection (réglage fin ×10),
//  haptique aux franchissements de rush.
//

import SwiftUI
import UIKit
import CoreMedia

// MARK: - Modèle d'affichage

/// Segment de rush projeté sur la timeline continue.
struct TimelineSegment: Equatable {
    var rushIndex: Int
    var title: String
    var proxyPath: String?
    var startOffset: Double   // secondes depuis le début de la timeline
    var duration: Double
}

/// Plage à surligner (sélection courante ou passage validé).
struct TimelineOverlay: Equatable {
    enum Kind: Equatable { case currentSelection, validated }
    var kind: Kind
    var globalStart: Double
    var duration: Double
}

// MARK: - Vue UIKit

final class TimelineUIView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    // Configuration.
    var segments: [TimelineSegment] = [] { didSet { if segments != oldValue { rebuild() } } }
    var overlays: [TimelineOverlay] = [] { didSet { if overlays != oldValue { layoutOverlays() } } }

    // Rappels vers SwiftUI.
    var onScrub: ((Double) -> Void)?
    var onTap: ((Double) -> Void)?
    var onSelectionDrag: ((Double) -> Void)?      // delta en secondes (déjà affiné si besoin)
    var onSelectionDragEnded: (() -> Void)?

    // Zoom : points par seconde. Minimum très bas = vue globale du montage
    // (2 pt/s ≈ 3 min de rushes visibles par écran) pour naviguer vite.
    private var pointsPerSecond: CGFloat = 60 {
        didSet { pointsPerSecond = min(max(pointsPerSecond, 2), 600) }
    }
    private let tileWidth: CGFloat = 60
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // Recyclage des tuiles : clé "rush#tuile" → layer.
    private var activeTiles: [String: CALayer] = [:]
    private var tilePool: [CALayer] = []
    private var separatorLayers: [CALayer] = []
    private var labelLayers: [CATextLayer] = []
    private var overlayLayers: [CALayer] = []
    private let playheadLayer = CALayer()

    private var totalDuration: Double { segments.last.map { $0.startOffset + $0.duration } ?? 0 }
    private var lastRushIndexUnderPlayhead = -1
    private var fineAdjust = false
    private var suppressScrubCallback = false

    private let boundaryHaptic = UIImpactFeedbackGenerator(style: .light)
    private let selectionHaptic = UIImpactFeedbackGenerator(style: .medium)

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 1)

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .fast
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        playheadLayer.backgroundColor = UIColor.systemRed.cgColor
        layer.addSublayer(playheadLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionDrag(_:)))
        drag.delegate = self
        scrollView.addGestureRecognizer(drag)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        scrollView.addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let width = CGFloat(totalDuration) * pointsPerSecond
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.contentSize = contentView.frame.size
        // Tête de lecture au centre : marges pour atteindre 0 et la fin.
        scrollView.contentInset = UIEdgeInsets(
            top: 0, left: bounds.width / 2, bottom: 0, right: bounds.width / 2
        )
        playheadLayer.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        updateVisibleTiles()
        layoutSeparators()
        layoutOverlays()
    }

    private func rebuild() {
        activeTiles.values.forEach { $0.removeFromSuperlayer() }
        activeTiles.removeAll()
        setNeedsLayout()
    }

    // MARK: Conversions temps ↔ points

    private func x(forTime time: Double) -> CGFloat { CGFloat(time) * pointsPerSecond }
    private func time(forX x: CGFloat) -> Double {
        min(max(Double(x / pointsPerSecond), 0), totalDuration)
    }

    /// Temps global sous la tête de lecture.
    var playheadTime: Double {
        time(forX: scrollView.contentOffset.x + scrollView.contentInset.left)
    }

    /// Positionne la timeline sur un temps global (sans rappel de scrubbing).
    func setPlayhead(time: Double, animated: Bool) {
        suppressScrubCallback = true
        let offsetX = x(forTime: time) - scrollView.contentInset.left
        scrollView.setContentOffset(CGPoint(x: offsetX, y: 0), animated: animated)
        if !animated { suppressScrubCallback = false }
    }

    // MARK: Tuiles visibles

    private func updateVisibleTiles() {
        guard bounds.width > 0, !segments.isEmpty else { return }
        let visibleMinX = scrollView.contentOffset.x - tileWidth
        let visibleMaxX = scrollView.contentOffset.x + bounds.width + tileWidth

        var neededKeys = Set<String>()

        for segment in segments {
            let segmentMinX = x(forTime: segment.startOffset)
            let segmentMaxX = x(forTime: segment.startOffset + segment.duration)
            guard segmentMaxX > visibleMinX, segmentMinX < visibleMaxX else { continue }

            let firstTile = max(0, Int((visibleMinX - segmentMinX) / tileWidth))
            let lastTile = Int((min(visibleMaxX, segmentMaxX) - segmentMinX) / tileWidth)

            for tileIndex in firstTile...max(firstTile, lastTile) {
                let tileX = segmentMinX + CGFloat(tileIndex) * tileWidth
                guard tileX < segmentMaxX else { continue }
                let key = "\(segment.rushIndex)#\(tileIndex)"
                neededKeys.insert(key)
                if activeTiles[key] == nil {
                    let tile = dequeueTile()
                    tile.frame = CGRect(
                        x: tileX, y: 14,
                        width: min(tileWidth, segmentMaxX - tileX),
                        height: bounds.height - 14
                    )
                    contentView.layer.addSublayer(tile)
                    activeTiles[key] = tile
                    populate(tile: tile, segment: segment, tileIndex: tileIndex)
                }
            }
        }

        // Recyclage des tuiles sorties de la zone visible.
        for (key, tile) in activeTiles where !neededKeys.contains(key) {
            tile.removeFromSuperlayer()
            tile.contents = nil
            tilePool.append(tile)
            activeTiles.removeValue(forKey: key)
        }
    }

    private func dequeueTile() -> CALayer {
        if let tile = tilePool.popLast() { return tile }
        let tile = CALayer()
        tile.contentsGravity = .resizeAspectFill
        tile.masksToBounds = true
        tile.backgroundColor = UIColor(white: 0.18, alpha: 1).cgColor
        return tile
    }

    private func populate(tile: CALayer, segment: TimelineSegment, tileIndex: Int) {
        guard let proxyPath = segment.proxyPath else { return }
        // Temps LOCAL au rush représenté par le centre de la tuile.
        let localSeconds = (Double(tileIndex) * Double(tileWidth) + Double(tileWidth) / 2)
            / Double(pointsPerSecond)
        let clamped = min(localSeconds, max(segment.duration - 0.05, 0))
        let requestTime = CMTime(seconds: clamped, preferredTimescale: 600)

        if let hit = ThumbnailCache.shared.cachedThumbnail(proxyPath: proxyPath, time: requestTime) {
            tile.contents = hit.cgImage
            return
        }
        let key = "\(segment.rushIndex)#\(tileIndex)"
        ThumbnailCache.shared.requestThumbnail(proxyPath: proxyPath, time: requestTime) { [weak self] image in
            guard let self, let image,
                  let current = self.activeTiles[key] else { return }
            current.contents = image.cgImage
        }
    }

    // MARK: Séparations et étiquettes de rush

    private func layoutSeparators() {
        separatorLayers.forEach { $0.removeFromSuperlayer() }
        labelLayers.forEach { $0.removeFromSuperlayer() }
        separatorLayers.removeAll()
        labelLayers.removeAll()

        for segment in segments {
            let separator = CALayer()
            separator.backgroundColor = UIColor.white.withAlphaComponent(0.8).cgColor
            separator.frame = CGRect(x: x(forTime: segment.startOffset), y: 0, width: 1.5, height: bounds.height)
            contentView.layer.addSublayer(separator)
            separatorLayers.append(separator)

            let label = CATextLayer()
            label.string = " \(segment.title) "
            label.fontSize = 11
            label.foregroundColor = UIColor.white.cgColor
            label.backgroundColor = UIColor.black.withAlphaComponent(0.65).cgColor
            label.cornerRadius = 3
            label.contentsScale = UIScreen.main.scale
            label.frame = CGRect(x: x(forTime: segment.startOffset) + 3, y: 1, width: 190, height: 14)
            contentView.layer.addSublayer(label)
            labelLayers.append(label)
        }
    }

    // MARK: Surlignages (sélection, passages validés)

    private func layoutOverlays() {
        overlayLayers.forEach { $0.removeFromSuperlayer() }
        overlayLayers.removeAll()
        for overlay in overlays {
            let layer = CALayer()
            switch overlay.kind {
            case .currentSelection:
                layer.borderColor = UIColor.systemYellow.cgColor
                layer.borderWidth = 2.5
                layer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18).cgColor
            case .validated:
                layer.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25).cgColor
            }
            layer.frame = CGRect(
                x: x(forTime: overlay.globalStart), y: 14,
                width: x(forTime: overlay.duration), height: bounds.height - 14
            )
            layer.cornerRadius = 3
            contentView.layer.addSublayer(layer)
            overlayLayers.append(layer)
        }
    }

    private var currentSelectionFrame: CGRect? {
        guard let overlay = overlays.first(where: { $0.kind == .currentSelection }) else { return nil }
        return CGRect(
            x: x(forTime: overlay.globalStart), y: 0,
            width: x(forTime: overlay.duration), height: bounds.height
        )
    }

    // MARK: Gestes

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: contentView)
        selectionHaptic.impactOccurred()
        onTap?(time(forX: location.x))
    }

    @objc private func handleSelectionDrag(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let translation = recognizer.translation(in: contentView)
            recognizer.setTranslation(.zero, in: contentView)
            var delta = Double(translation.x / pointsPerSecond)
            if fineAdjust { delta /= 10 } // réglage fin après appui long
            onSelectionDrag?(delta)
        case .ended, .cancelled:
            fineAdjust = false
            onSelectionDragEnded?()
        default:
            break
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            let location = recognizer.location(in: contentView)
            if currentSelectionFrame?.contains(location) == true {
                fineAdjust = true
                selectionHaptic.impactOccurred()
            }
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let anchorTime = playheadTime
        pointsPerSecond *= recognizer.scale
        recognizer.scale = 1
        setNeedsLayout()
        layoutIfNeeded()
        setPlayhead(time: anchorTime, animated: false)
    }

    /// Le glissement de sélection ne démarre QUE sur la sélection courante ;
    /// ailleurs, le défilement standard du scroll view garde la main.
    /// (`override` : UIView déclare déjà cette méthode.)
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer is UIPanGestureRecognizer,
              recognizer.view === scrollView || recognizer.view === contentView else { return true }
        guard let frame = currentSelectionFrame else { return false }
        let location = recognizer.location(in: contentView)
        return frame.insetBy(dx: -12, dy: 0).contains(location)
    }

    // MARK: UIScrollViewDelegate — scrubbing

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleTiles()
        let time = playheadTime
        // Haptique au franchissement d'une séparation de rush.
        if let segment = segments.last(where: { $0.startOffset <= time }) {
            if segment.rushIndex != lastRushIndexUnderPlayhead {
                if lastRushIndexUnderPlayhead != -1 { boundaryHaptic.impactOccurred() }
                lastRushIndexUnderPlayhead = segment.rushIndex
            }
        }
        if suppressScrubCallback {
            if !scrollView.isDragging && !scrollView.isDecelerating { suppressScrubCallback = false }
            return
        }
        onScrub?(time)
    }
}

// MARK: - Pont SwiftUI

/// Demande de positionnement one-shot : le jeton garantit UNE seule application
/// (un temps brut ré-appliqué à chaque rafraîchissement SwiftUI figeait le scroll).
struct ProgrammaticSeek: Equatable {
    var token: Int
    var time: Double
}

struct TimelineView: UIViewRepresentable {
    var segments: [TimelineSegment]
    var overlays: [TimelineOverlay]
    /// Positionnement demandé de l'extérieur (boutons rush précédent/suivant...).
    var seek: ProgrammaticSeek?

    var onScrub: (Double) -> Void
    var onTap: (Double) -> Void
    var onSelectionDrag: (Double) -> Void
    var onSelectionDragEnded: () -> Void

    final class Coordinator {
        var lastAppliedToken = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TimelineUIView {
        let view = TimelineUIView()
        view.onScrub = onScrub
        view.onTap = onTap
        view.onSelectionDrag = onSelectionDrag
        view.onSelectionDragEnded = onSelectionDragEnded
        return view
    }

    func updateUIView(_ view: TimelineUIView, context: Context) {
        view.segments = segments
        view.overlays = overlays
        view.onScrub = onScrub
        view.onTap = onTap
        view.onSelectionDrag = onSelectionDrag
        view.onSelectionDragEnded = onSelectionDragEnded
        if let seek, seek.token != context.coordinator.lastAppliedToken {
            context.coordinator.lastAppliedToken = seek.token
            // Différé d'un cycle : garantit un layout à jour après un changement
            // de segments dans la même passe.
            DispatchQueue.main.async {
                view.setPlayhead(time: seek.time, animated: false)
            }
        }
    }
}
