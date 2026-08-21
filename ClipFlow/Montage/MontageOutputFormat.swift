//
//  MontageOutputFormat.swift
//  ClipFlow
//
//  FORMAT DE SORTIE du montage : paysage 16:9 ou portrait 9:16, toujours en
//  4K et en 60 images par seconde.
//
//  Le cadre ne se déduit plus du premier clip placé. C'était commode tant que
//  tous les rushes avaient la même orientation, mais dès qu'on en mélange, le
//  format du fichier dépendait de quel clip la musique avait mis en tête —
//  autant dire du hasard. Il se choisit désormais, et il tient.
//
//  RECADRER PLUTÔT QUE CEINTURER. Poser une source 16:9 dans un cadre 9:16
//  laisse par nature deux bandes noires énormes. Le recadrage prend à la place
//  la bande centrale de l'image : on perd les bords, on garde toute la
//  surface utile. C'est presque toujours ce qu'on veut pour du POV, où
//  l'action est au centre.
//

import Foundation
import CoreGraphics

enum MontageOutputFormat: String, Codable, CaseIterable, Sendable {
    /// Suit l'orientation du premier clip placé, en la ramenant à l'un des
    /// deux formats standards.
    case auto
    case landscape
    case portrait

    var label: String {
        switch self {
        case .auto: return "Automatique"
        case .landscape: return "16:9 — paysage"
        case .portrait: return "9:16 — vertical"
        }
    }

    var shortLabel: String {
        switch self {
        case .auto: return "Auto"
        case .landscape: return "16:9"
        case .portrait: return "9:16"
        }
    }

    /// Taille de rendu, en pixels. TOUJOURS 4K.
    ///
    /// - `sourceOriented` : taille du premier clip, orientation appliquée.
    ///   Elle ne sert qu'au mode automatique, pour savoir de quel côté pencher.
    ///
    /// Les dimensions sont paires : les encodeurs H.264 et HEVC refusent les
    /// dimensions impaires, et l'échec arrive tard, à l'écriture du fichier.
    func renderSize(sourceOriented: CGSize) -> CGSize {
        switch resolved(sourceOriented: sourceOriented) {
        case .portrait: return CGSize(width: 2160, height: 3840)
        default: return CGSize(width: 3840, height: 2160)
        }
    }

    /// Format effectif, une fois l'automatique tranché.
    func resolved(sourceOriented: CGSize) -> MontageOutputFormat {
        guard self == .auto else { return self }
        // Carré ou indéterminé : le paysage est le défaut le moins surprenant,
        // c'est le format d'origine des caméras d'action.
        guard sourceOriented.width > 0, sourceOriented.height > 0 else { return .landscape }
        return sourceOriented.height > sourceOriented.width ? .portrait : .landscape
    }

    /// Taille de rendu qui N'AGRANDIT RIEN : le plus grand cadre du format
    /// voulu qui tienne dans la source.
    ///
    /// C'est la taille de la PREMIÈRE passe quand le suréchantillonnage est
    /// actif. Composer directement en 4K laisserait AVFoundation agrandir avec
    /// son filtre bilinéaire, et la seconde passe n'aurait plus rien à
    /// rattraper — on ne récupère pas du détail perdu, on ne fait que lisser
    /// un flou déjà là.
    func nativeRenderSize(sourceOriented: CGSize, cropToFill: Bool) -> CGSize {
        let target = renderSize(sourceOriented: sourceOriented)
        guard sourceOriented.width > 0, sourceOriented.height > 0 else { return target }
        let targetAspect = target.width / target.height
        let sourceAspect = sourceOriented.width / sourceOriented.height

        let size: CGSize
        if cropToFill {
            // Recadrage : le plus grand rectangle du bon rapport DANS la source.
            size = sourceAspect > targetAspect
                ? CGSize(width: sourceOriented.height * targetAspect,
                         height: sourceOriented.height)
                : CGSize(width: sourceOriented.width,
                         height: sourceOriented.width / targetAspect)
        } else {
            // Ceinturage : le plus petit cadre du bon rapport AUTOUR de la source.
            size = sourceAspect > targetAspect
                ? CGSize(width: sourceOriented.width,
                         height: sourceOriented.width / targetAspect)
                : CGSize(width: sourceOriented.height * targetAspect,
                         height: sourceOriented.height)
        }
        // Jamais plus grand que la cible : une source 8K n'a pas à produire un
        // fichier intermédiaire plus lourd que le fichier final.
        let capped = CGSize(width: min(size.width, target.width),
                            height: min(size.height, target.height))
        // Dimensions PAIRES : les encodeurs H.264 et HEVC refusent l'impair, et
        // l'échec arrive tard, à l'écriture.
        return CGSize(width: max(2, (capped.width / 2).rounded() * 2),
                      height: max(2, (capped.height / 2).rounded() * 2))
    }

    /// Facteur d'agrandissement qu'imposera la seconde passe.
    func upscaleFactor(sourceOriented: CGSize, cropToFill: Bool) -> Double {
        let native = nativeRenderSize(sourceOriented: sourceOriented, cropToFill: cropToFill)
        let target = renderSize(sourceOriented: sourceOriented)
        guard native.height > 0 else { return 1 }
        return Double(target.height / native.height)
    }

    /// Rapport largeur/hauteur du rendu.
    func aspect(sourceOriented: CGSize) -> Double {
        let size = renderSize(sourceOriented: sourceOriented)
        return Double(size.width / size.height)
    }
}

/// Ce que l'importation a trouvé comme orientations dans les rushes.
///
/// Sert à ne poser la question du format QUE lorsqu'elle se pose vraiment :
/// des rushes tous filmés dans le même sens n'ont besoin d'aucun arbitrage.
struct RushFormatSurvey: Sendable {
    var landscapeCount: Int = 0
    var portraitCount: Int = 0

    var total: Int { landscapeCount + portraitCount }
    /// Les deux orientations coexistent : quel que soit le format choisi, une
    /// partie des rushes sera recadrée ou ceinturée.
    var isMixed: Bool { landscapeCount > 0 && portraitCount > 0 }

    var summary: String {
        if isMixed {
            return "\(landscapeCount) rush(es) en paysage et \(portraitCount) en vertical"
        }
        if portraitCount > 0 { return "\(portraitCount) rush(es) en vertical" }
        return "\(landscapeCount) rush(es) en paysage"
    }

    /// Format qui recadre le moins de rushes.
    var majorityFormat: MontageOutputFormat {
        portraitCount > landscapeCount ? .portrait : .landscape
    }
}
