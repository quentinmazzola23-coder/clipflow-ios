//
//  OverlayInspector.swift
//  ClipFlow
//
//  Réglages de l'incrustation SÉLECTIONNÉE : texte, position, taille, durée.
//
//  SUR LE DÉFAUT « le sélecteur revient tout seul sur Toute la vidéo » : la
//  cause exacte n'est PAS établie. Une première explication — « le calque
//  n'était pas observé » — a été vérifiée puis démentie : l'ancien code lisait
//  bien les propriétés du calque dans son corps, ce qui suffit à l'observer.
//  Deux pistes crédibles restent, et les deux sont traitées plutôt que
//  laissées au hasard :
//    1. l'enregistrement SwiftData se faisait PENDANT la validation du
//       sélecteur, au milieu d'une mise à jour de vue ; il est différé au tour
//       de boucle suivant (voir `commit()`) ;
//    2. l'écran de montage lisait les mêmes propriétés dans son propre corps,
//       donc reconstruisait cette feuille à chaque réglage qu'on y faisait ;
//       il travaille désormais sur une copie mémorisée (voir MontageView).
//  Si le symptôme revient, c'est qu'aucune des deux n'était la bonne — ne pas
//  repartir de l'hypothèse « pas observé », elle est écartée.
//
//  LE MODÈLE N'EST ÉCRIT QUE SUR GESTE DE L'UTILISATEUR. Les compteurs de
//  portée passent par des liaisons BORNÉES : ils affichent des rangs valables
//  pour le montage courant sans jamais réécrire ceux qui sont enregistrés. Un
//  recalage automatique a existé et détruisait les portées — le nombre de
//  clips varie à chaque déplacement de la fenêtre musicale, et « du clip 40 au
//  clip 80 » devenait définitivement « 5 → 5 » le temps d'un passage court.
//
//  POSITION PAR ANCRAGE plutôt qu'au doigt seul : neuf points (les quatre
//  angles, les quatre milieux de bord, le centre). Un logo se pose presque
//  toujours sur l'un d'eux, et viser un coin au pouce sur un aperçu de la
//  taille d'une carte postale est pénible. Le glissement reste possible. La
//  règle de placement vit dans `OverlayLayer.anchoredCenter` — une seule
//  copie, partagée avec la création.
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
    /// Hauteur occupée, en fraction de la hauteur de l'image.
    var relativeHeight: Double
    /// Largeur RÉELLEMENT occupée, en fraction de la largeur de l'image.
    /// Fournie par le parent : pour un texte, elle est MESURÉE, `relativeWidth`
    /// n'y réglant que le corps de police.
    var relativeSpan: Double
    /// Durée réelle de la portée. Fermeture ÉVALUÉE À LA DEMANDE : calculée à
    /// chaque passage, elle refaisait la résolution des portées cent fois par
    /// seconde pendant un glissement, sur le fil principal.
    var durationLabel: () -> String
    var onChange: () -> Void

    /// Rangs BORNÉS pour l'affichage seulement. `Stepper(in:)` plante sur une
    /// plage inversée (« Can't form Range with upperBound < lowerBound »), cas
    /// atteint dès qu'on change la densité de coupe — elle divise ou multiplie
    /// le nombre de clips par seize.
    private var lastIndex: Int { max(0, clipCount - 1) }
    private var safeFirst: Int { min(max(0, layer.firstClipIndex), lastIndex) }
    private var safeLast: Int { min(max(safeFirst, layer.lastClipIndex), lastIndex) }

    var body: some View {
        VStack(spacing: 12) {
            if layer.kind == .text { textField }

            HStack(alignment: .top, spacing: 16) {
                anchorGrid
                sizeControl
            }

            scopeControl
        }
    }

    /// Enregistre AU TOUR SUIVANT. Sauvegarder pendant la validation d'un
    /// sélecteur, c'est écrire dans le modèle au milieu d'une mise à jour de
    /// vue — piste n° 1 du défaut décrit en tête de fichier.
    private func commit() {
        Task { @MainActor in onChange() }
    }

    /// Recolle l'incrustation sur son ancrage avec les marges du moment.
    private func applyAnchor() {
        guard let center = OverlayLayer.anchoredCenter(
            anchorIndex: layer.anchorIndex,
            relativeSpan: relativeSpan,
            relativeHeight: relativeHeight
        ) else { return }
        layer.centerX = center.x
        layer.centerY = center.y
    }

    // MARK: - Texte

    /// Le texte reste MODIFIABLE après l'ajout.
    ///
    /// Il ne se saisissait qu'une fois, dans l'alerte de création : une faute
    /// de frappe obligeait à supprimer l'incrustation, en recréer une, et
    /// refaire tout le placement.
    private var textField: some View {
        TextField("Texte", text: $layer.text)
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .submitLabel(.done)
            .onSubmit { commit() }
            // Écrire change la largeur du texte, donc la marge de son ancrage.
            .onChange(of: layer.text) { _, _ in
                applyAnchor()
                commit()
            }
    }

    // MARK: - Ancrages

    private var anchorGrid: some View {
        VStack(spacing: 4) {
            Text("Position")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Espacement NUL : chaque case porte déjà 6 pt de marge tactile,
            // les ajouter creuserait des trous morts entre les prises.
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 0) {
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
                .frame(width: 30, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.white.opacity(0.25), lineWidth: 0.5)
                }
                // Zone tactile ÉLARGIE au-delà du dessin : neuf cases de 44 pt
                // occuperaient toute la largeur de l'écran et ne laisseraient
                // pas de place au curseur de taille. 42 × 36 pt de prise pour
                // 30 × 24 pt de dessin est le compromis — et se tromper de
                // case ne coûte qu'une nouvelle touche.
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(anchorName(row: row, column: column))
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
                // Le pourcentage ne veut PAS dire la même chose pour les deux
                // types : sur un texte le curseur règle le corps de police, et
                // annoncer « 50 % de la largeur » était faux — la largeur
                // dépend du nombre de caractères.
                Text(layer.kind == .image
                     ? "\(Int(layer.relativeWidth * 100)) %"
                     : "\(Int(relativeSpan * 100)) % de large")
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
            Text(layer.kind == .image
                 ? "Part de la largeur de l'image"
                 : "Taille de police")
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
            .onChange(of: layer.spansWholeMontage) { _, _ in commit() }

            if !layer.spansWholeMontage {
                if clipCount > 0 {
                    HStack(spacing: 12) {
                        // LIAISONS BORNÉES : elles montrent un rang valable
                        // pour le montage courant, et n'écrivent QUE si
                        // l'utilisateur touche le compteur. Lire ne modifie
                        // jamais la portée enregistrée.
                        Stepper(value: Binding(
                            get: { safeFirst },
                            set: { new in
                                let first = min(max(0, new), lastIndex)
                                layer.firstClipIndex = first
                                if layer.lastClipIndex < first { layer.lastClipIndex = first }
                                commit()
                            }
                        ), in: 0...lastIndex) {
                            Text("Du clip \(safeFirst + 1)")
                                .font(.caption.monospacedDigit())
                        }
                        Stepper(value: Binding(
                            get: { safeLast },
                            set: { new in
                                layer.lastClipIndex = min(max(safeFirst, new), lastIndex)
                                commit()
                            }
                        ), in: safeFirst...lastIndex) {
                            Text("au clip \(safeLast + 1)")
                                .font(.caption.monospacedDigit())
                        }
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
