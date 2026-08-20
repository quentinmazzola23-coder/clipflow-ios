//
//  OverlayLayer.swift
//  ClipFlow
//
//  INCRUSTATIONS du montage : une image (logo, filigrane) ou un texte, posés
//  sur toute la vidéo ou sur une plage de clips choisie.
//
//  AUCUN EFFET, délibérément : pas de fondu, pas d'animation, pas d'ombre.
//  L'incrustation apparaît, reste, disparaît. C'est la demande, et c'est
//  aussi ce qui garantit un rendu identique à l'aperçu — un effet, c'est une
//  interpolation de plus à faire correspondre entre deux moteurs.
//
//  POSITION ET TAILLE EN FRACTIONS de la vidéo, jamais en pixels : l'aperçu
//  fait quelques centaines de points, l'export en fait plusieurs milliers.
//  Un placement en points aurait glissé entre les deux ; en fractions, ce
//  qu'on voit est ce qu'on obtient, quelle que soit la définition.
//

import Foundation
import SwiftData
import CoreGraphics
import CoreMedia

@Model
final class OverlayLayer {

    /// "image" ou "texte" — stocké en chaîne pour que SwiftData migre sans
    /// bruit si un troisième type apparaît un jour.
    var kindRaw: String = OverlayKind.text.rawValue

    /// Texte affiché (type texte). Toujours blanc, sans contour ni ombre.
    var text: String = ""
    /// Nom du fichier image dans Application Support/Overlays (type image).
    var imageFilename: String?

    // MARK: Géométrie, en FRACTIONS de la largeur/hauteur de la vidéo

    /// Centre de l'incrustation. 0,5 / 0,5 = centre de l'image.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Largeur relative à celle de la vidéo. 0,3 = 30 % de la largeur.
    /// La hauteur suit le rapport d'origine de l'image (ou du texte rendu).
    var relativeWidth: Double = 0.3

    // MARK: Portée temporelle, exprimée en CLIPS

    /// Vrai : présent du début à la fin du montage (cas du filigrane).
    var spansWholeMontage: Bool = true
    /// Index du premier et du dernier clip couverts (inclus), quand la portée
    /// est limitée. Ce sont des rangs dans le montage, pas des secondes :
    /// déplacer la fenêtre musicale ne décale pas l'incrustation.
    var firstClipIndex: Int = 0
    var lastClipIndex: Int = 0

    /// Ancrage choisi, 0-8 (ligne × 3 + colonne) ; -1 = posé librement.
    ///
    /// Mémorisé pour que l'incrustation RESTE collée à son coin quand on
    /// change sa taille : sans lui, agrandir un logo ancré en bas à gauche le
    /// faisait déborder du cadre, la marge dépendant de la largeur.
    var anchorIndex: Int = -1

    /// Ordre d'empilement : les derniers ajoutés passent devant.
    var stackOrder: Int = 0

    var project: ClipProject?

    init() {}

    var kind: OverlayKind {
        get { OverlayKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var imageURL: URL? {
        imageFilename.map { OverlayStore.url(forImageNamed: $0) }
    }

}

enum OverlayKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
}

/// Une incrustation résolue en temps ABSOLU, prête pour le rendu.
/// Convertir les rangs de clips en secondes est fait une seule fois, à partir
/// du plan de montage — les deux moteurs (aperçu, export) lisent la même.
struct ResolvedOverlay: Sendable {
    var kind: OverlayKind
    var text: String
    var imageURL: URL?
    var centerX: Double
    var centerY: Double
    var relativeWidth: Double
    /// Plage dans le temps du MONTAGE (zéro = première image).
    var start: CMTime
    var duration: CMTime
    var stackOrder: Int
}
