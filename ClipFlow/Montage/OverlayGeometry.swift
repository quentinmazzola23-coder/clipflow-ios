//
//  OverlayGeometry.swift
//  ClipFlow
//
//  ENCOMBREMENT d'une incrustation, en fractions de l'image rendue.
//
//  Règle unique, partagée par l'éditeur, l'aperçu et l'écran de montage. Elle
//  a d'abord vécu en trois copies dans les vues, ce qui a produit exactement
//  ce qu'on pouvait craindre : un logo posé dans un coin par une formule et
//  déplacé par une autre au premier réglage de taille.
//
//  Elle ne charge AUCUN fichier. Le rapport d'une image est mémorisé sur le
//  calque (`imageAspect`) au moment où on la pose : sans cela, recaler les
//  ancrages depuis l'écran de montage aurait imposé de rouvrir tous les PNG.
//
//  ⚠️ Toute modification ici doit être reportée dans `OverlayRenderer`, qui
//  dessine le fichier exporté — c'est lui qui fait foi.
//

import Foundation
import UIKit

enum OverlayGeometry {

    /// Largeur RÉELLEMENT occupée, en fraction de la largeur de l'image.
    ///
    /// Pour une image, c'est la valeur réglée au curseur. Pour un texte, NON :
    /// `relativeWidth` n'y pilote que le corps de police, et la largeur dépend
    /// du nombre de caractères. Un titre de vingt-cinq lettres à 50 % occupe
    /// une fois et demie la largeur de l'image — l'ancrage « gauche » le
    /// poussait alors à moitié hors champ.
    static func span(of layer: OverlayLayer) -> Double {
        switch layer.kind {
        case .image:
            return layer.relativeWidth
        case .text:
            return textSpan(layer.text, relativeWidth: layer.relativeWidth)
        }
    }

    /// Largeur occupée par un texte donné, pour une taille de police donnée.
    ///
    /// Mesurée à une largeur de RÉFÉRENCE : la formule du rendu
    /// (`largeur × relativeWidth × 0,22`) est linéaire en largeur d'image, le
    /// rapport ne dépend donc pas de la définition de sortie.
    static func textSpan(_ text: String, relativeWidth: Double) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, relativeWidth > 0 else { return 0 }
        let reference: CGFloat = 1000
        let font = UIFont.systemFont(
            ofSize: reference * CGFloat(relativeWidth) * 0.22,
            weight: .semibold
        )
        let measured = (trimmed as NSString).size(withAttributes: [.font: font])
        return Double(measured.width / reference)
    }

    /// Hauteur occupée, en fraction de la HAUTEUR de l'image.
    ///
    /// `videoRatio` est le rapport largeur/hauteur du RENDU. Il intervient
    /// parce que la taille est réglée en fraction de la LARGEUR : sur un
    /// montage large, un logo carré à 30 % de largeur occupe 53 % de la
    /// hauteur. Une marge verticale fixe le coupait donc en haut du cadre.
    static func height(of layer: OverlayLayer, videoRatio: Double) -> Double {
        switch layer.kind {
        case .image:
            return layer.relativeWidth * layer.imageAspect * videoRatio
        case .text:
            // Même formule que le rendu : corps = largeur × 0,22, interligne 1,2.
            return layer.relativeWidth * 0.22 * 1.2 * videoRatio
        }
    }

    /// Taille de police initiale d'un texte, pour qu'il TIENNE dans le cadre.
    ///
    /// Une valeur en dur ne peut pas convenir : à 0,5, tout titre de plus
    /// d'une douzaine de capitales naissait plus large que l'image, coupé des
    /// deux côtés à l'aperçu comme à l'export, et les trois colonnes
    /// d'ancrage donnaient alors le même centre. Le span étant linéaire en
    /// `relativeWidth`, une mesure à 1 suffit à déduire ce qui rentre.
    ///
    /// 0,94 est le seuil de `OverlayLayer.anchoredCenter` : au-delà, les
    /// marges de 3 % ne tiennent plus.
    static func initialTextWidth(for text: String) -> Double {
        let spanAtFull = textSpan(text, relativeWidth: 1)
        guard spanAtFull > 0 else { return 0.5 }
        return min(0.5, max(0.05, 0.94 / spanAtFull))
    }
}
