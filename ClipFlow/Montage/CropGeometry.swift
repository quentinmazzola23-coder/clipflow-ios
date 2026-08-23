//
//  CropGeometry.swift
//  ClipFlow
//
//  RECADRAGE DÉPLAÇABLE : où se situe, dans l'image source, la portion que le
//  montage garde.
//
//  Poser une source 16:9 dans un cadre 9:16 (ou l'inverse) oblige à jeter les
//  bords. Jusqu'ici on gardait le centre, sans discussion possible. Ce fichier
//  est la règle unique qui décide de la portion gardée, et il sert À LA FOIS
//  au cadre affiché dans l'éditeur et à la transformation appliquée à
//  l'export. Une seule formule, deux usages : c'est la seule façon d'être sûr
//  que ce qu'on montre est ce qui sort.
//
//  DEUX PROPRIÉTÉS QUI GOUVERNENT TOUT LE RESTE.
//
//  1. LE CENTRE EST FRACTIONNAIRE, jamais en pixels. L'aperçu du montage
//     compose en 4K plein, tandis que la première passe d'un export
//     suréchantillonné compose à la taille native — jusqu'à trois fois et
//     demie plus petite. Un décalage en pixels serait juste dans l'un et faux
//     dans l'autre ; une fraction traverse les deux sans retouche.
//
//  2. UN SEUL AXE EST LIBRE À LA FOIS. L'échelle de remplissage est un `max`
//     de deux rapports : celui des deux qui l'emporte fait coïncider son axe
//     avec le cadre, et cet axe n'a alors plus le moindre jeu. Une source plus
//     large que le cadre ne se déplace qu'horizontalement, une source plus
//     étroite que verticalement. Offrir un déplacement libre en deux
//     dimensions donnerait une poignée qui ne répond pas sur un axe — ou pire,
//     ferait apparaître du noir dans un montage vendu comme sans bandes.
//
//  Le repère est celui de l'image ORIENTÉE (rotation déjà appliquée), origine
//  en HAUT à gauche : `y = 0` garde le haut de l'image. C'est le repère de la
//  composition vidéo, et c'est aussi celui de l'écran — les deux coïncident,
//  ce qui évite au cadre affiché d'être le miroir vertical du recadrage réel.
//

import Foundation
import CoreGraphics

enum CropGeometry {

    /// Comportement historique : on garde le centre.
    static let centered = CGPoint(x: 0.5, y: 0.5)

    /// Échelle de remplissage — la même que celle du composeur.
    ///
    /// Isolée ici pour que les bornes, le rectangle gardé et la transformation
    /// finale se déduisent tous du MÊME nombre. Quand cette règle vivait dans
    /// la seule fonction qui l'utilisait, toute vue qui voulait dessiner le
    /// cadre devait la réécrire — et deux formules qui divergent d'un arrondi
    /// donnent un cadre qui ne coïncide pas avec ce qui est rogné.
    static func scale(orientedSize: CGSize,
                      renderSize: CGSize,
                      cropToFill: Bool) -> CGFloat {
        guard orientedSize.width > 0, orientedSize.height > 0 else { return 1 }
        let byWidth = renderSize.width / orientedSize.width
        let byHeight = renderSize.height / orientedSize.height
        return cropToFill ? max(byWidth, byHeight) : min(byWidth, byHeight)
    }

    /// Part de l'image RÉELLEMENT gardée sur chaque axe, entre 0 et 1.
    ///
    /// Exactement l'un des deux vaut 1 en mode recadrage : c'est l'axe verrouillé.
    static func visibleFraction(orientedSize: CGSize,
                                renderSize: CGSize,
                                cropToFill: Bool) -> CGSize {
        guard orientedSize.width > 0, orientedSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let s = scale(orientedSize: orientedSize, renderSize: renderSize, cropToFill: cropToFill)
        let scaled = CGSize(width: orientedSize.width * s, height: orientedSize.height * s)
        guard scaled.width > 0, scaled.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: min(1, renderSize.width / scaled.width),
                      height: min(1, renderSize.height / scaled.height))
    }

    /// Débattement du centre, par axe.
    ///
    /// Un axe verrouillé rend l'intervalle dégénéré `0,5…0,5` — pas un
    /// intervalle vide ni inversé. L'interface s'en sert pour savoir quel axe
    /// répond au doigt, et ne doit jamais avoir à le deviner autrement.
    static func bounds(orientedSize: CGSize,
                       renderSize: CGSize,
                       cropToFill: Bool) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let visible = visibleFraction(orientedSize: orientedSize,
                                      renderSize: renderSize,
                                      cropToFill: cropToFill)
        return (axisBounds(visible: Double(visible.width)),
                axisBounds(visible: Double(visible.height)))
    }

    /// Ramène un centre dans son débattement.
    ///
    /// LE RECADRAGE EST BORNÉ ICI, PAS DANS LA VUE. Le composeur applique ce
    /// que le modèle contient, et le modèle peut porter une valeur devenue
    /// hors bornes : il suffit qu'un rush soit remplacé, qu'une rotation soit
    /// corrigée, ou que le format de sortie passe de 16:9 à 9:16 après coup.
    /// Un centre non borné laisse alors entrer une bande noire dans un montage
    /// qui promet de n'en avoir aucune.
    static func clamp(_ center: CGPoint,
                      orientedSize: CGSize,
                      renderSize: CGSize,
                      cropToFill: Bool) -> CGPoint {
        let limits = bounds(orientedSize: orientedSize,
                            renderSize: renderSize,
                            cropToFill: cropToFill)
        return CGPoint(x: clampAxis(Double(center.x), to: limits.x),
                       y: clampAxis(Double(center.y), to: limits.y))
    }

    /// Portion gardée, en FRACTIONS de l'image orientée (origine en haut à
    /// gauche). C'est le rectangle que l'éditeur dessine sur l'aperçu.
    static func keptRect(center: CGPoint,
                         orientedSize: CGSize,
                         renderSize: CGSize,
                         cropToFill: Bool) -> CGRect {
        let visible = visibleFraction(orientedSize: orientedSize,
                                      renderSize: renderSize,
                                      cropToFill: cropToFill)
        let safe = clamp(center, orientedSize: orientedSize,
                         renderSize: renderSize, cropToFill: cropToFill)
        return CGRect(x: safe.x - visible.width / 2,
                      y: safe.y - visible.height / 2,
                      width: visible.width,
                      height: visible.height)
    }

    /// Y a-t-il quelque chose à régler ?
    ///
    /// Faux quand les rapports coïncident (rien n'est jeté) et faux en mode
    /// ceinturage (rien n'est jeté non plus : l'image entière est conservée
    /// entre deux bandes). Dans ces deux cas, montrer un cadre déplaçable
    /// promettrait un réglage sans effet.
    static func isAdjustable(orientedSize: CGSize,
                             renderSize: CGSize,
                             cropToFill: Bool) -> Bool {
        guard cropToFill else { return false }
        let visible = visibleFraction(orientedSize: orientedSize,
                                      renderSize: renderSize,
                                      cropToFill: cropToFill)
        // Un pour mille de jeu : en deçà, le déplacement possible est
        // inférieur à l'épaisseur du trait qui le dessine.
        return visible.width < 0.999 || visible.height < 0.999
    }

    // MARK: - Détail

    private static func axisBounds(visible: Double) -> ClosedRange<Double> {
        let half = visible / 2
        let low = half
        let high = 1 - half
        // Axe verrouillé (`visible` vaut 1, ou déborde d'un cheveu par
        // arrondi) : intervalle dégénéré au centre. Construire `low...high`
        // avec low > high ferait planter Swift, pas retourner un vide.
        guard low < high else { return 0.5...0.5 }
        return low...high
    }

    private static func clampAxis(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
