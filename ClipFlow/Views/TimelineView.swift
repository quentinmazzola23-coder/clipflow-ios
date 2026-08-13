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
    /// Fichier original servant aux vignettes (nil si source indisponible).
    var mediaURL: URL?
    /// Identité STABLE du rush pour le cache de vignettes — jamais l'index
    /// (un réordonnancement mélangerait les images entre rushes).
    var thumbKey: String
    var startOffset: Double   // secondes depuis le début de la timeline
    var duration: Double
    /// Cadence du rush : sert la règle graduée quand le zoom devient trop fin
    /// pour la seconde et bascule en numéros d'image. 0 = inconnue.
    var frameRate: Double = 0
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
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // Recyclage des tuiles : clé "rush#tuile" → layer.
    private var activeTiles: [String: CALayer] = [:]
    private var tilePool: [CALayer] = []
    private var separatorLayers: [CALayer] = []
    private var labelLayers: [CATextLayer] = []
    private var overlayLayers: [CALayer] = []
    private var rulerLayers: [CALayer] = []
    private let playheadLayer = CALayer()

    private var totalDuration: Double { segments.last.map { $0.startOffset + $0.duration } ?? 0 }
    private var lastRushIndexUnderPlayhead = -1
    private var suppressScrubCallback = false

    private let boundaryHaptic = UIImpactFeedbackGenerator(style: .light)
    private let selectionHaptic = UIImpactFeedbackGenerator(style: .medium)

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)

        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .fast
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        playheadLayer.backgroundColor = UIColor.systemRed.cgColor
        layer.addSublayer(playheadLayer)

        // Pose + ajustement en UN SEUL geste : appui ≥ 0,12 s → la sélection
        // se pose immédiatement, glisser ajuste, relâcher lance la boucle.
        let placeAndDrag = UILongPressGestureRecognizer(target: self, action: #selector(handlePlaceAndDrag(_:)))
        placeAndDrag.minimumPressDuration = 0.12
        scrollView.addGestureRecognizer(placeAndDrag)

        // Toucher bref (< 0,12 s) : pose simple au relâcher.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: placeAndDrag)
        scrollView.addGestureRecognizer(tap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionDrag(_:)))
        drag.delegate = self
        scrollView.addGestureRecognizer(drag)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        // Double-tap à DEUX doigts : bascule zoom travail ↔ vue globale
        // (deux doigts = aucun conflit avec la pose de sélection).
        let zoomToggle = UITapGestureRecognizer(target: self, action: #selector(handleZoomToggle(_:)))
        zoomToggle.numberOfTapsRequired = 2
        zoomToggle.numberOfTouchesRequired = 2
        scrollView.addGestureRecognizer(zoomToggle)
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
        layoutRuler()
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

    // MARK: Vignettes — l'image du rush RÉPÉTÉE sur toute sa longueur

    /// Largeur d'une tuile ; la même image du rush est répétée tuile par tuile.
    private let thumbnailWidth: CGFloat = 84

    private func updateVisibleTiles() {
        guard bounds.width > 0, !segments.isEmpty else { return }
        let visibleMinX = scrollView.contentOffset.x - thumbnailWidth
        let visibleMaxX = scrollView.contentOffset.x + bounds.width + thumbnailWidth

        var neededKeys = Set<String>()

        for segment in segments {
            let segmentMinX = x(forTime: segment.startOffset)
            let segmentMaxX = x(forTime: segment.startOffset + segment.duration)
            guard segmentMaxX > visibleMinX, segmentMinX < visibleMaxX else { continue }

            let firstTile = max(0, Int((visibleMinX - segmentMinX) / thumbnailWidth))
            let lastTile = max(firstTile, Int((min(visibleMaxX, segmentMaxX) - segmentMinX) / thumbnailWidth))

            for tileIndex in firstTile...lastTile {
                let tileX = segmentMinX + CGFloat(tileIndex) * thumbnailWidth
                guard tileX < segmentMaxX else { continue }
                let key = "\(segment.rushIndex)#\(tileIndex)"
                neededKeys.insert(key)
                let frame = CGRect(
                    x: tileX, y: 14,
                    width: min(thumbnailWidth, segmentMaxX - tileX),
                    height: bounds.height - 14
                )
                if let tile = activeTiles[key] {
                    // Reposition systématique : le zoom déplace les segments.
                    tile.frame = frame
                } else {
                    let tile = dequeueTile()
                    tile.frame = frame
                    contentView.layer.addSublayer(tile)
                    activeTiles[key] = tile
                    populate(tile: tile, segment: segment, key: key)
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
        tile.borderWidth = 0.5
        tile.borderColor = UIColor(white: 0, alpha: 0.4).cgColor
        tile.backgroundColor = UIColor(white: 0.18, alpha: 1).cgColor
        return tile
    }

    /// Toutes les tuiles d'un rush partagent la MÊME image (milieu du rush) :
    /// une seule génération par rush, puis cache instantané. Le cache est
    /// indexé par l'identité du FICHIER (thumbKey), pas par la position.
    private func populate(tile: CALayer, segment: TimelineSegment, key: String) {
        guard let mediaURL = segment.mediaURL else { return }
        let midpoint = max(min(segment.duration / 2, segment.duration - 0.05), 0)
        let requestTime = CMTime(seconds: midpoint, preferredTimescale: 600)

        if let hit = ThumbnailCache.shared.cachedThumbnail(key: segment.thumbKey, time: requestTime) {
            tile.contents = hit.cgImage
            return
        }
        ThumbnailCache.shared.requestThumbnail(
            fileURL: mediaURL, key: segment.thumbKey, time: requestTime
        ) { [weak self] image in
            guard let self, let image else { return }
            // L'image arrive une fois : peupler TOUTES les tuiles du rush
            // actuellement affichées.
            let prefix = "\(segment.rushIndex)#"
            for (tileKey, layer) in self.activeTiles where tileKey.hasPrefix(prefix) {
                layer.contents = image.cgImage
            }
        }
    }

    // MARK: Séparations et étiquettes de rush

    /// Clé de la dernière construction : évite de détruire/recréer tous les
    /// layers à chaque passage de layout quand rien n'a changé.
    private var separatorsBuildKey = ""

    private func layoutSeparators() {
        let key = "\(segments.count)|\(pointsPerSecond)|\(totalDuration)|\(bounds.height)"
        guard key != separatorsBuildKey else { return }
        separatorsBuildKey = key

        separatorLayers.forEach { $0.removeFromSuperlayer() }
        labelLayers.forEach { $0.removeFromSuperlayer() }
        separatorLayers.removeAll()
        labelLayers.removeAll()

        for segment in segments {
            let separator = CALayer()
            separator.backgroundColor = UIColor.white.withAlphaComponent(0.45).cgColor
            separator.frame = CGRect(x: x(forTime: segment.startOffset), y: 0, width: 1, height: bounds.height)
            contentView.layer.addSublayer(separator)
            separatorLayers.append(separator)

            let label = CATextLayer()
            label.string = " \(segment.title) "
            label.fontSize = 11
            label.foregroundColor = UIColor.white.cgColor
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            label.cornerRadius = 5
            label.contentsScale = UIScreen.main.scale
            label.frame = CGRect(x: x(forTime: segment.startOffset) + 3, y: 1, width: 110, height: 14)
            contentView.layer.addSublayer(label)
            labelLayers.append(label)
        }
    }

    // MARK: Règle graduée — lecture directe du niveau de zoom

    /// Pas de graduation, exprimé soit en secondes, soit en IMAGES quand le
    /// zoom devient plus fin que la seconde.
    enum RulerStep: Equatable {
        case seconds(Double)
        /// Pas de `count` images, à la cadence `frameRate`.
        case frames(count: Int, frameRate: Double)

        /// Durée d'un pas, en secondes.
        var interval: Double {
            switch self {
            case .seconds(let value): return value
            case .frames(let count, let rate): return Double(count) / max(rate, 1)
            }
        }
    }

    /// Espacement minimal entre deux étiquettes, en points : en dessous, elles
    /// se chevauchent et la règle devient illisible.
    private static let minimumLabelSpacing: CGFloat = 64

    /// Choisit le pas le plus FIN qui laisse au moins `minimumLabelSpacing`
    /// entre deux graduations. Échelle « 1-2-5 » classique, prolongée en
    /// images quand la seconde devient trop grossière pour le zoom courant.
    static func rulerStep(pointsPerSecond: CGFloat, frameRate: Double) -> RulerStep {
        let secondLadder: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]

        // Le zoom permet-il de distinguer des images ? On ne bascule en
        // numéros d'image que si la cadence est connue ET si une seconde
        // occupe assez de place pour que plusieurs images soient lisibles.
        if frameRate > 0 {
            let pointsPerFrame = pointsPerSecond / CGFloat(frameRate)
            let frameLadder = [1, 2, 5, 10, 15, 20]
            for count in frameLadder {
                if pointsPerFrame * CGFloat(count) >= minimumLabelSpacing {
                    // Un pas qui atteindrait une seconde entière retombe dans
                    // l'échelle des secondes : plus lisible.
                    if Double(count) >= frameRate { break }
                    return .frames(count: count, frameRate: frameRate)
                }
            }
        }

        for value in secondLadder where CGFloat(value) * pointsPerSecond >= Self.minimumLabelSpacing {
            return .seconds(value)
        }
        return .seconds(secondLadder.last ?? 300)
    }

    /// Étiquette d'une graduation, exprimée DANS LE CLIP (le compteur repart à
    /// zéro à chaque rush) : c'est la position utile pour juger un passage.
    static func rulerLabel(offsetInSegment: Double, step: RulerStep) -> String {
        switch step {
        case .seconds(let value):
            let total = offsetInSegment
            let minutes = Int(total / 60)
            let seconds = total - Double(minutes) * 60
            if value < 1 {
                return minutes > 0
                    ? String(format: "%d:%04.1f", minutes, seconds)
                    : String(format: "%.1f s", seconds)
            }
            return minutes > 0
                ? String(format: "%d:%02d", minutes, Int(seconds.rounded()))
                : String(format: "%d s", Int(seconds.rounded()))
        case .frames(_, let frameRate):
            // Numéro d'image DANS LA SECONDE courante : « 2 s +7 i » se lit
            // sans calcul mental, contrairement à un numéro absolu.
            let totalFrames = Int((offsetInSegment * frameRate).rounded())
            let framesPerSecond = max(Int(frameRate.rounded()), 1)
            let second = totalFrames / framesPerSecond
            let frame = totalFrames % framesPerSecond
            return frame == 0 ? "\(second) s" : "\(second)s +\(frame)i"
        }
    }

    /// Trace les graduations visibles. Reconstruite au défilement comme au
    /// zoom : seule la portion à l'écran est dessinée.
    private func layoutRuler() {
        rulerLayers.forEach { $0.removeFromSuperlayer() }
        rulerLayers.removeAll()
        guard bounds.width > 0, !segments.isEmpty else { return }

        let visibleMinX = scrollView.contentOffset.x - 40
        let visibleMaxX = scrollView.contentOffset.x + bounds.width + 40

        for segment in segments {
            let segmentMinX = x(forTime: segment.startOffset)
            let segmentMaxX = x(forTime: segment.startOffset + segment.duration)
            guard segmentMaxX > visibleMinX, segmentMinX < visibleMaxX else { continue }

            let step = Self.rulerStep(pointsPerSecond: pointsPerSecond, frameRate: segment.frameRate)
            let interval = step.interval
            guard interval > 0 else { continue }

            // Première graduation visible DANS ce segment.
            let firstVisibleOffset = max(0, Double((visibleMinX - segmentMinX) / pointsPerSecond))
            var tickIndex = Int(firstVisibleOffset / interval)

            while true {
                let offsetInSegment = Double(tickIndex) * interval
                if offsetInSegment > segment.duration { break }
                let tickX = segmentMinX + CGFloat(offsetInSegment) * pointsPerSecond
                if tickX > visibleMaxX { break }
                tickIndex += 1
                guard tickX >= visibleMinX else { continue }

                // Trait : plus marqué sur les secondes entières.
                let isWholeSecond = abs(offsetInSegment.rounded() - offsetInSegment) < 0.001
                let tick = CALayer()
                tick.backgroundColor = UIColor.white
                    .withAlphaComponent(isWholeSecond ? 0.5 : 0.28).cgColor
                tick.frame = CGRect(x: tickX, y: 14, width: 1,
                                    height: isWholeSecond ? 9 : 6)
                contentView.layer.addSublayer(tick)
                rulerLayers.append(tick)

                // Fond sombre : les graduations passent par-dessus les
                // vignettes, illisibles autrement sur une image claire.
                let label = CATextLayer()
                label.string = " " + Self.rulerLabel(offsetInSegment: offsetInSegment, step: step)
                label.fontSize = 9
                label.foregroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
                label.backgroundColor = UIColor.black.withAlphaComponent(0.5).cgColor
                label.cornerRadius = 3
                label.contentsScale = UIScreen.main.scale
                let width: CGFloat = {
                    if case .frames = step { return 52 }
                    return 40
                }()
                label.frame = CGRect(x: tickX + 2, y: 15, width: width, height: 11)
                contentView.layer.addSublayer(label)
                rulerLayers.append(label)
            }
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

    /// Appui maintenu : pose (ou saisit) la sélection puis l'ajuste en continu.
    private var placeDragLastX: CGFloat = 0

    @objc private func handlePlaceAndDrag(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: contentView)
        switch recognizer.state {
        case .began:
            scrollView.isScrollEnabled = false
            placeDragLastX = location.x
            if currentSelectionFrame?.insetBy(dx: -12, dy: 0).contains(location) == true {
                // Appui sur la sélection existante : simple saisie pour déplacer.
                selectionHaptic.impactOccurred(intensity: 0.6)
            } else {
                // Appui ailleurs : pose immédiate, le glissement ajustera.
                selectionHaptic.impactOccurred()
                onTap?(time(forX: location.x))
            }
        case .changed:
            let delta = Double((location.x - placeDragLastX) / pointsPerSecond)
            placeDragLastX = location.x
            if delta != 0 { onSelectionDrag?(delta) }
        case .ended, .cancelled, .failed:
            scrollView.isScrollEnabled = true
            onSelectionDragEnded?()
        default:
            break
        }
    }

    @objc private func handleSelectionDrag(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            let translation = recognizer.translation(in: contentView)
            recognizer.setTranslation(.zero, in: contentView)
            let delta = Double(translation.x / pointsPerSecond)
            onSelectionDrag?(delta)
        case .ended, .cancelled:
            onSelectionDragEnded?()
        default:
            break
        }
    }

    /// Deux niveaux de zoom mémorisés : travail (60 pt/s) ↔ vue globale (5 pt/s).
    @objc private func handleZoomToggle(_ recognizer: UITapGestureRecognizer) {
        let anchorTime = playheadTime
        pointsPerSecond = pointsPerSecond > 15 ? 5 : 60
        boundaryHaptic.impactOccurred()
        setNeedsLayout()
        layoutIfNeeded()
        setPlayhead(time: anchorTime, animated: false)
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
        layoutRuler()
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
