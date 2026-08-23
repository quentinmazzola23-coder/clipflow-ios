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

    /// Plus grand cadre du rapport voulu tenant dans l'espace, CENTRÉ.
    ///
    /// C'est la règle qui dit où se trouve réellement l'image dans une vue qui
    /// la contient en boîte aux lettres — indispensable dès qu'un geste doit
    /// être converti en fraction d'image, puisque la vue est plus grande que
    /// l'image et que diviser par la taille de la vue donnerait un gain faux.
    ///
    /// Elle vivait en deux exemplaires (aperçu d'incrustations, éditeur
    /// d'incrustations). Le recadrage déplaçable en aurait fait un troisième :
    /// c'est exactement le défaut que l'en-tête de ce fichier raconte, un
    /// élément posé par une formule et déplacé par une autre.
    static func fittedRect(in available: CGSize, ratio: CGFloat) -> CGRect {
        guard available.width > 0, available.height > 0, ratio > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        var size = CGSize(width: available.width, height: available.width / ratio)
        if size.height > available.height {
            size = CGSize(width: available.height * ratio, height: available.height)
        }
        return CGRect(x: (available.width - size.width) / 2,
                      y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

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
            // 0 = rapport jamais relevé : carré supposé pour DESSINER, jamais
            // pour écrire. Le recalage d'orientation, lui, saute ces calques
            // plutôt que d'enregistrer une position déduite d'une supposition.
            let aspect = layer.imageAspect > 0 ? layer.imageAspect : 1
            return layer.relativeWidth * aspect * videoRatio
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
