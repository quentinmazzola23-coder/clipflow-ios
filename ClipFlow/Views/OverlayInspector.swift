//
//  OverlayInspector.swift
//  ClipFlow
//
//  Réglages de l'incrustation SÉLECTIONNÉE : position, taille, durée.
//
//  SUR LE DÉFAUT « le sélecteur revient tout seul sur Toute la vidéo » : la
//  cause exacte n'est PAS établie. Une première explication — « le calque
//  n'était pas observé » — a été vérifiée puis démentie : l'ancien code lisait
//  bien les propriétés du calque dans son corps, ce qui suffit à l'observer.
//  Deux pistes crédibles restent, et les deux sont traitées ici plutôt que
//  laissées au hasard :
//    1. l'enregistrement SwiftData se faisait PENDANT la validation du
//       sélecteur, au milieu de la mise à jour de la vue ; il est maintenant
//       différé au tour de boucle suivant ;
//    2. l'écran de montage lisait les mêmes propriétés dans son propre corps,
//       donc reconstruisait cette feuille à chaque réglage qu'on y faisait ;
//       il travaille désormais sur une copie mémorisée (voir MontageView).
//  Si le symptôme revient, c'est qu'aucune des deux n'était la bonne — ne pas
//  repartir de l'hypothèse « pas observé », elle est écartée.
//
//  POSITION PAR ANCRAGE plutôt qu'au doigt seul : neuf points (les quatre
//  angles, les quatre milieux de bord, le centre). Un logo se pose presque
//  toujours sur l'un d'eux, et viser un coin au pouce sur un aperçu de la
//  taille d'une carte postale est pénible. Le glissement reste possible pour
//  les cas particuliers. L'ancrage est MÉMORISÉ : changer la taille recolle
//  l'incrustation à son coin au lieu de la laisser déborder.
//
//  TAILLE AU CURSEUR plutôt qu'au pincement : le pincement se disputait le
//  geste avec le glissement — SwiftUI rapporte le point milieu des deux
//  doigts, et l'incrustation sautait sous la main pendant qu'on la
//  redimensionnait.
//

import SwiftUI
import SwiftData

struct OverlayInspector: View {
    @Bindable var layer: OverlayLayer
    /// Nombre de clips du montage courant — borne les rangs.
    var clipCount: Int
    /// Hauteur de l'incrustation, en fraction de la hauteur de l'image.
    /// Fournie par l'écran parent, seul à connaître la forme réelle du
    /// contenu (rapport de l'image, hauteur du texte).
    var relativeHeight: Double
    /// Durée réelle de la portée. Fermeture ÉVALUÉE À LA DEMANDE : calculée à
    /// chaque passage, elle refaisait le calcul des portées cent fois par
    /// seconde pendant un glissement, sur le fil principal.
    var durationLabel: () -> String
    var onChange: () -> Void

    /// Marges des ancrages de bord, en fraction de l'image, DÉDUITES DE LA
    /// TAILLE réelle : sinon un logo ancré dans un angle puis agrandi sortait
    /// du cadre, et un ancrage haut/bas coupait une image haute.
    private var horizontalInset: Double { min(0.45, layer.relativeWidth / 2 + 0.03) }
    private var verticalInset: Double { min(0.45, relativeHeight / 2 + 0.03) }

    /// Rangs REMIS DANS LES BORNES pour l'affichage. `Stepper(in:)` plante sur
    /// une plage inversée : « Can't form Range with upperBound < lowerBound ».
    /// Le cas arrive dès qu'on change la densité de coupe, qui divise ou
    /// multiplie le nombre de clips par seize.
    private var lastIndex: Int { max(0, clipCount - 1) }
    private var safeFirst: Int { min(max(0, layer.firstClipIndex), lastIndex) }
    private var safeLast: Int { min(max(safeFirst, layer.lastClipIndex), lastIndex) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                anchorGrid
                sizeControl
            }

            scopeControl
        }
        // Les rangs hors bornes sont recalés DANS LE MODÈLE, pas seulement à
        // l'écran : afficher une portée que l'export n'applique pas serait
        // pire que de la corriger.
        .task(id: clipCount) { clampScope() }
    }

    private func clampScope() {
        guard clipCount > 0 else { return }
        if layer.firstClipIndex != safeFirst { layer.firstClipIndex = safeFirst }
        if layer.lastClipIndex != safeLast { layer.lastClipIndex = safeLast }
    }

    /// Enregistre AU TOUR SUIVANT. Sauvegarder pendant la validation d'un
    /// sélecteur, c'est écrire dans le modèle au milieu d'une mise à jour de
    /// vue — piste n° 1 du défaut décrit en tête de fichier.
    private func commit() {
        Task { @MainActor in onChange() }
    }

    // MARK: - Ancrages

    private var anchorGrid: some View {
        VStack(spacing: 4) {
            Text("Position")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { column in
                            anchorButton(row: row, column: column)
                        }
                    }
                }
            }
        }
    }

    private func anchorButton(row: Int, column: Int) -> some View {
        let index = row * 3 + column
        // Allumé d'après l'ancrage MÉMORISÉ, pas d'après la position : les
        // marges bougent avec la taille, et le bouton s'éteignait tout seul
        // dès qu'on touchait au curseur.
        let isCurrent = layer.anchorIndex == index
        return Button {
            layer.anchorIndex = index
            applyAnchor()
            commit()
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isCurrent ? Theme.accent : Color.white.opacity(0.18))
                .frame(width: 26, height: 20)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.white.opacity(0.25), lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(anchorName(row: row, column: column))
    }

    /// Recolle l'incrustation sur son ancrage avec les marges du moment.
    private func applyAnchor() {
        guard layer.anchorIndex >= 0 else { return }
        let row = layer.anchorIndex / 3
        let column = layer.anchorIndex % 3
        layer.centerX = switch column {
        case 0: horizontalInset
        case 1: 0.5
        default: 1 - horizontalInset
        }
        layer.centerY = switch row {
        case 0: verticalInset
        case 1: 0.5
        default: 1 - verticalInset
        }
    }

    private func anchorName(row: Int, column: Int) -> String {
        let vertical = ["haut", "milieu", "bas"][row]
        let horizontal = ["gauche", "centre", "droite"][column]
        return row == 1 && column == 1 ? "Centre" : "\(vertical) \(horizontal)"
    }

    // MARK: - Taille

    private var sizeControl: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Taille")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(layer.relativeWidth * 100)) %")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $layer.relativeWidth,
                in: 0.05...1.0,
                onEditingChanged: { editing in
                    if !editing {
                        applyAnchor() // la marge a changé : on se recolle
                        commit()
                    }
                }
            )
            .tint(Theme.accent)
            Text("Part de la largeur de l'image")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Portée

    private var scopeControl: some View {
        VStack(spacing: 8) {
            Picker("Durée", selection: $layer.spansWholeMontage) {
                Text("Toute la vidéo").tag(true)
                Text("Certains clips").tag(false)
            }
            .pickerStyle(.segmented)
            .onChange(of: layer.spansWholeMontage) { _, whole in
                if !whole { clampScope() }
                commit()
            }

            if !layer.spansWholeMontage {
                if clipCount > 0 {
                    HStack(spacing: 12) {
                        Stepper(value: $layer.firstClipIndex, in: 0...lastIndex) {
                            Text("Du clip \(safeFirst + 1)")
                                .font(.caption.monospacedDigit())
                        }
                        .onChange(of: layer.firstClipIndex) { _, first in
                            if layer.lastClipIndex < first { layer.lastClipIndex = first }
                            commit()
                        }
                        Stepper(value: $layer.lastClipIndex, in: safeFirst...lastIndex) {
                            Text("au clip \(safeLast + 1)")
                                .font(.caption.monospacedDigit())
                        }
                        .onChange(of: layer.lastClipIndex) { _, _ in commit() }
                    }
                    // La durée réelle, en clair : des rangs de clips ne parlent
                    // pas d'eux-mêmes.
                    Text(durationLabel())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Aucun clip dans le montage — la portée par clips demande un montage construit.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
