//
//  CropFrameOverlay.swift
//  ClipFlow
//
//  CE QUI SERA GARDÉ, montré sur l'aperçu — et déplaçable au doigt.
//
//  Quand le format de sortie ne correspond pas à l'orientation du rush, le
//  montage jette les bords. C'était invisible : on découvrait le cadrage à
//  l'export, une fois le montage fait. Ce calque montre la portion retenue en
//  clair, assombrit le reste, et laisse la déplacer d'un glissé.
//
//  UN SEUL AXE RÉPOND, ET C'EST VOULU. L'image est agrandie jusqu'à couvrir le
//  cadre : l'axe qui a servi à cet ajustement n'a plus le moindre jeu. Une
//  source 16:9 dans un cadre vertical ne se déplace donc qu'horizontalement,
//  une source verticale dans un cadre 16:9 que verticalement. `CropGeometry`
//  borne les deux axes ; l'axe verrouillé y reçoit un intervalle réduit au
//  centre, ce qui immobilise le cadre sans qu'aucun cas particulier n'ait à
//  être écrit ici.
//
//  AUCUNE COMMANDE AJOUTÉE. Pas de bouton « recadrer », pas de poignée, pas de
//  validation : le geste EST la commande. La barre du bas ne bouge pas d'un
//  point — ce calque vit entièrement en surimpression de la visionneuse.
//

import SwiftUI

struct CropFrameOverlay: View {
    /// Taille du rush, rotation appliquée.
    var orientedSize: CGSize
    /// Cadre de rendu du montage (4K, dans le format retenu).
    var renderSize: CGSize
    var cropToFill: Bool
    /// Centre courant, en fractions de l'image orientée.
    var center: CGPoint
    /// Appelé PENDANT le glissé (affichage seulement, aucun enregistrement).
    var onMove: (CGPoint) -> Void
    /// Appelé une seule fois, au relâchement : c'est là qu'on enregistre.
    var onCommit: (CGPoint) -> Void

    /// Origine du glissé, avec le point de départ du doigt.
    ///
    /// Le point de départ sert de FILET : un glissé interrompu (appel entrant,
    /// feuille qui s'ouvre) ne reçoit jamais son `onEnded` et laisse une
    /// origine périmée derrière lui. Sans cette comparaison, le geste suivant
    /// repartirait de l'ancienne position et le cadre sauterait — le même
    /// défaut que l'éditeur d'incrustations a déjà eu à corriger.
    @State private var dragOrigin: (center: CGPoint, start: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            let ratio = orientedSize.height > 0
                ? orientedSize.width / orientedSize.height : 0
            let videoRect = OverlayGeometry.fittedRect(in: geometry.size, ratio: ratio)
            let kept = CropGeometry.keptRect(center: center,
                                             orientedSize: orientedSize,
                                             renderSize: renderSize,
                                             cropToFill: cropToFill)
            // Du repère fractionnaire de l'image vers les points de l'écran.
            let keptFrame = CGRect(
                x: videoRect.minX + kept.minX * videoRect.width,
                y: videoRect.minY + kept.minY * videoRect.height,
                width: kept.width * videoRect.width,
                height: kept.height * videoRect.height
            )

            ZStack {
                // HORS CADRE ASSOMBRI. Un simple trait ne suffisait pas à faire
                // comprendre de quel côté se trouve ce qu'on perd.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .reverseMask {
                        Rectangle()
                            .frame(width: keptFrame.width, height: keptFrame.height)
                            .position(x: keptFrame.midX, y: keptFrame.midY)
                    }

                Rectangle()
                    .stroke(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: keptFrame.width, height: keptFrame.height)
                    .position(x: keptFrame.midX, y: keptFrame.midY)

                // SURFACE DE PRISE PLEINE, pas seulement le trait : SwiftUI ne
                // teste que les pixels dessinés, et un cadre au trait fin
                // serait inattrapable au pouce.
                //
                // Elle s'arrête à 24 points du bord gauche : le balayage de
                // retour de la navigation part de là et gagne toujours. Mieux
                // vaut une bande morte franche qu'un geste qui referme l'écran
                // une fois sur trois.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(0, videoRect.width - 24), height: videoRect.height)
                    .position(x: videoRect.midX + 12, y: videoRect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let origin = beginOrContinue(value)
                                let moved = CGPoint(
                                    x: origin.x + value.translation.width / videoRect.width,
                                    y: origin.y + value.translation.height / videoRect.height
                                )
                                onMove(CropGeometry.clamp(moved,
                                                          orientedSize: orientedSize,
                                                          renderSize: renderSize,
                                                          cropToFill: cropToFill))
                            }
                            .onEnded { value in
                                let origin = beginOrContinue(value)
                                let moved = CGPoint(
                                    x: origin.x + value.translation.width / videoRect.width,
                                    y: origin.y + value.translation.height / videoRect.height
                                )
                                dragOrigin = nil
                                // ENREGISTREMENT AU SEUL RELÂCHEMENT. Écrire à
                                // chaque image reconstruirait la vue des
                                // dizaines de fois par seconde et saccaderait
                                // le glissé.
                                onCommit(CropGeometry.clamp(moved,
                                                            orientedSize: orientedSize,
                                                            renderSize: renderSize,
                                                            cropToFill: cropToFill))
                            }
                    )
            }
            .animation(nil, value: center)
        }
        .allowsHitTesting(true)
    }

    /// Reprend l'origine du glissé en cours, ou l'installe.
    private func beginOrContinue(_ value: DragGesture.Value) -> CGPoint {
        if let known = dragOrigin, known.start == value.startLocation {
            return known.center
        }
        let fresh = center
        dragOrigin = (center: fresh, start: value.startLocation)
        return fresh
    }
}

private extension View {
    /// Découpe un trou de la forme donnée dans la vue.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
