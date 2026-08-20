//
//  OverlayRenderer.swift
//  ClipFlow
//
//  Rendu des incrustations dans la composition vidéo.
//
//  MÉCANISME : `AVVideoCompositionCoreAnimationTool`, l'outil prévu par
//  AVFoundation pour poser des calques Core Animation sur une vidéo.
//
//  IL NE SERT QUE L'EXPORT. Apple le documente comme un outil de rendu hors
//  ligne : attaché à la composition d'un `AVPlayerItem`, il est ignoré ou
//  laisse le lecteur noir. L'aperçu redessine donc les incrustations en
//  SwiftUI (`OverlayPreviewLayer`), avec les mêmes fractions et la même
//  formule de police — toute modification de géométrie ici doit être reportée
//  là-bas, sinon l'aperçu ment sur le fichier produit.
//
//  APPARITION/DISPARITION SANS EFFET. Une couche Core Animation est visible
//  par défaut sur toute la durée ; pour la borner, on utilise une animation
//  d'opacité en MARCHES (valeurs 0/1, `calculationMode = .discrete`). Ce
//  n'est pas un fondu déguisé : la valeur saute, il n'existe aucune image
//  intermédiaire. C'est le seul moyen de dater une couche dans cet outil.
//
//  ⚠️ Les animations doivent être « gelées » : `beginTime` jamais nul (sinon
//  AVFoundation le remplace par l'heure courante et la couche clignote au
//  hasard), `isRemovedOnCompletion = false`, et une base de temps figée.
//

import Foundation
import AVFoundation
import UIKit
import CoreMedia

enum OverlayRenderer {

    /// Construit l'arbre de calques et l'accroche à la composition vidéo.
    /// Sans incrustation, la composition est laissée telle quelle.
    static func attach(_ overlays: [ResolvedOverlay],
                       to videoComposition: AVMutableVideoComposition,
                       renderSize: CGSize,
                       totalDuration: CMTime) {
        guard !overlays.isEmpty, renderSize.width > 0, renderSize.height > 0 else { return }

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        parentLayer.addSublayer(videoLayer)
        // Rendu déterministe : pas d'horloge courante, pas d'animation
        // implicite héritée.
        parentLayer.isGeometryFlipped = false

        for overlay in overlays {
            guard let layer = makeLayer(overlay, renderSize: renderSize) else { continue }
            applyVisibilityWindow(overlay, to: layer, totalDuration: totalDuration)
            parentLayer.addSublayer(layer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )
    }

    // MARK: - Fabrique de calques

    static func makeLayer(_ overlay: ResolvedOverlay, renderSize: CGSize) -> CALayer? {
        switch overlay.kind {
        case .image:
            return makeImageLayer(overlay, renderSize: renderSize)
        case .text:
            return makeTextLayer(overlay, renderSize: renderSize)
        }
    }

    private static func makeImageLayer(_ overlay: ResolvedOverlay,
                                       renderSize: CGSize) -> CALayer? {
        guard let url = overlay.imageURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }

        let width = renderSize.width * CGFloat(overlay.relativeWidth)
        // Le rapport d'origine est CONSERVÉ : une image déformée trahirait
        // un logo, et l'utilisateur n'a réglé qu'une largeur.
        let ratio = image.size.height / max(image.size.width, 1)
        let height = width * ratio

        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsGravity = .resizeAspect
        layer.frame = frame(width: width, height: height,
                            overlay: overlay, renderSize: renderSize)
        layer.isOpaque = false
        return layer
    }

    private static func makeTextLayer(_ overlay: ResolvedOverlay,
                                      renderSize: CGSize) -> CALayer? {
        let trimmed = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // La largeur relative pilote la TAILLE DE POLICE : c'est ce que le
        // curseur de taille règle, et ça reste lisible quelle que soit la
        // définition de sortie.
        let fontSize = renderSize.width * CGFloat(overlay.relativeWidth) * 0.22
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let measured = (trimmed as NSString).size(withAttributes: attributes)

        let layer = CATextLayer()
        layer.string = NSAttributedString(string: trimmed, attributes: attributes)
        layer.alignmentMode = .center
        layer.isWrapped = false
        // Échelle 1 : la composition rend déjà en pixels vidéo, pas en points
        // d'écran. Reprendre l'échelle de l'écran doublerait la résolution du
        // texte sur un appareil Retina et le rendrait flou après remise à
        // l'échelle.
        layer.contentsScale = 1
        layer.frame = frame(width: measured.width, height: measured.height,
                            overlay: overlay, renderSize: renderSize)
        return layer
    }

    /// Cadre centré sur la position relative, exprimé dans le repère vidéo.
    ///
    /// Core Animation a son origine EN BAS À GAUCHE alors que l'utilisateur
    /// place son incrustation dans un repère d'écran (origine en haut) : la
    /// coordonnée verticale est retournée ici, une fois pour toutes.
    private static func frame(width: CGFloat, height: CGFloat,
                              overlay: ResolvedOverlay, renderSize: CGSize) -> CGRect {
        let centerX = renderSize.width * CGFloat(overlay.centerX)
        let centerY = renderSize.height * (1 - CGFloat(overlay.centerY))
        return CGRect(x: centerX - width / 2, y: centerY - height / 2,
                      width: width, height: height)
    }

    // MARK: - Fenêtre de visibilité

    /// Rend la couche visible sur [start ; start + duration] et invisible
    /// ailleurs — par MARCHES, sans la moindre image de transition.
    ///
    /// Les temps clés d'une animation Core Animation sont des FRACTIONS de sa
    /// propre durée. L'animation couvre donc tout le montage, et les bornes de
    /// l'incrustation y sont exprimées en proportions : c'est la seule façon
    /// d'obtenir des dates justes.
    static func applyVisibilityWindow(_ overlay: ResolvedOverlay,
                                      to layer: CALayer,
                                      totalDuration: CMTime) {
        let total = totalDuration.seconds
        guard total > 0.001 else { layer.opacity = 1; return }

        let start = max(0, overlay.start.seconds)
        let end = min(total, start + overlay.duration.seconds)

        // Couvre tout le montage : aucune animation. Une animation inutile est
        // une occasion d'erreur en moins.
        if start <= 0.001, end >= total - 0.001 {
            layer.opacity = 1
            return
        }
        guard end > start else { layer.opacity = 0; return }

        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        // Quatre marches : invisible, visible, invisible, et la dernière
        // valeur que `.discrete` exige pour tenir jusqu'à la fin.
        animation.values = [0, 1, 0, 0]
        animation.keyTimes = [
            0,
            NSNumber(value: start / total),
            NSNumber(value: end / total),
            1,
        ]
        // MARCHES : la valeur SAUTE d'un temps clé au suivant. Aucune image
        // intermédiaire n'est calculée — ce n'est pas un fondu déguisé.
        animation.calculationMode = .discrete
        animation.duration = total
        // beginTime nul serait remplacé par l'heure courante et la couche
        // clignoterait au hasard. Cette constante signifie « le début de la
        // composition ».
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        layer.add(animation, forKey: "visibility")
    }
}
