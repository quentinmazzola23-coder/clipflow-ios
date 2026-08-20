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
//  LES COMPTEURS MONTRENT CE QU'ILS CONTIENNENT. C'est le corollaire de la
//  règle « le modèle n'est écrit que sur geste ». Une version intermédiaire
//  affichait des rangs bornés au montage courant tout en gardant les vrais :
//  l'écran annonçait « du clip 6 au clip 6 » sur une portée enregistrée 40→80,
//  si bien qu'un seul appui sur le « − », geste anodin, écrasait le 80 par un
//  4 sans que rien n'ait jamais montré ce qu'on détruisait. Les rangs affichés
//  sont donc les rangs réels ; le dépassement du montage courant est dit en
//  toutes lettres, et le bornage reste où il sert : au rendu.
//
//  POSITION PAR ANCRAGE plutôt qu'au doigt seul : neuf points (les quatre
//  angles, les quatre milieux de bord, le centre). La règle de placement vit
//  dans `OverlayLayer.anchoredCenter` et l'encombrement dans
//  `OverlayGeometry` — une seule copie de chaque, partagée avec la création et
//  avec le recalage d'orientation.
//
//  TAILLE AU CURSEUR plutôt qu'au pincement : le pincement se disputait le
//  geste avec le glissement — SwiftUI rapporte le point milieu des deux
//  doigts, et l'incrustation sautait sous la main.
//

import SwiftUI
import SwiftData

struct OverlayInspector: View {
    @Bindable var layer: OverlayLayer
    /// Nombre de clips du montage courant.
    var clipCount: Int
    /// Rapport largeur/hauteur du rendu — pilote l'encombrement vertical.
    var videoRatio: Double
    /// Durée réelle de la portée. Fermeture ÉVALUÉE À LA DEMANDE : calculée à
    /// chaque passage, elle refaisait la résolution des portées cent fois par
    /// seconde pendant un glissement, sur le fil principal.
    var durationLabel: () -> String
    var onChange: () -> Void

    @FocusState private var editingText: Bool
    /// Dernier texte non vide : un texte effacé ne se dessine nulle part, on
    /// le rend plutôt que d'enregistrer un calque invisible.
    @State private var lastNonEmptyText = ""

    private var relativeSpan: Double { OverlayGeometry.span(of: layer) }
    private var relativeHeight: Double {
        OverlayGeometry.height(of: layer, videoRatio: videoRatio)
    }

    /// Rangs RÉELS, tels qu'ils sont enregistrés.
    private var lastIndex: Int { max(0, clipCount - 1) }
    private var realFirst: Int { max(0, layer.firstClipIndex) }
    private var realLast: Int { max(realFirst, layer.lastClipIndex) }
    /// La portée dépasse-t-elle le montage courant ? Ce n'est pas une erreur —
    /// elle redeviendra juste dès que le montage s'allongera.
    private var outOfPlan: Bool { clipCount > 0 && realLast > lastIndex }

    private var textIsBlank: Bool {
        layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 12) {
            if layer.kind == .text { textField }

            HStack(alignment: .top, spacing: 16) {
                anchorGrid
                sizeControl
            }

            scopeControl
        }
        .onAppear { if !textIsBlank { lastNonEmptyText = layer.text } }
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
        layer.anchorVideoRatio = videoRatio
    }

    // MARK: - Texte

    /// Le texte reste MODIFIABLE après l'ajout.
    ///
    /// Il ne se saisissait qu'une fois, dans l'alerte de création : une faute
    /// de frappe obligeait à supprimer l'incrustation, en recréer une, et
    /// refaire tout le placement.
    private var textField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Texte", text: $layer.text)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .focused($editingText)
                .submitLabel(.done)
                .onSubmit { finishEditing() }
                // Écrire change la largeur du texte, donc la marge de son
                // ancrage : on recolle à chaque frappe, mais on N'ENREGISTRE
                // PAS — un `save()` SwiftData par caractère saccaderait la
                // saisie. La sauvegarde vient à la validation, ou à la
                // fermeture de l'écran.
                .onChange(of: layer.text) { _, new in
                    let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Pas de recalage sur une largeur nulle : le champ vidé,
                    // l'ancrage aurait collé le calque à 3 % du bord et perdu
                    // la position réglée.
                    guard !trimmed.isEmpty else { return }
                    lastNonEmptyText = new
                    applyAnchor()
                }

            if textIsBlank {
                Text("Texte vide : cette incrustation ne sera dessinée ni dans l'aperçu "
                     + "ni dans le fichier exporté. Retapez un texte, ou supprimez-la.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        // SORTIE DE CLAVIER EXPLICITE. La touche Retour la donnait déjà, mais
        // rien ne le disait, et le clavier recouvre la rangée Terminé.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Terminé") { finishEditing() }
            }
        }
    }

    private func finishEditing() {
        // Un texte vide ne produit rien au rendu : on rend la dernière valeur
        // utile plutôt que d'enregistrer un calque que personne ne dessinera.
        if textIsBlank, !lastNonEmptyText.isEmpty { layer.text = lastNonEmptyText }
        applyAnchor()
        editingText = false
        commit()
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
                // dépend du nombre de caractères. On affiche donc l'occupation
                // réelle, en orange dès qu'elle déborde du cadre.
                Text("\(Int(relativeSpan * 100)) % de large")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(relativeSpan > 1 ? .orange : .secondary)
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
                        // Les plages contiennent TOUJOURS la valeur affichée,
                        // donc `Stepper(in:)` ne peut pas recevoir de plage
                        // inversée — le plantage « Can't form Range with
                        // upperBound < lowerBound » reste écarté.
                        Stepper(value: Binding(
                            get: { realFirst },
                            set: { new in
                                let first = max(0, new)
                                layer.firstClipIndex = first
                                if layer.lastClipIndex < first { layer.lastClipIndex = first }
                                commit()
                            }
                        ), in: 0...max(lastIndex, realFirst)) {
                            Text("Du clip \(realFirst + 1)")
                                .font(.caption.monospacedDigit())
                        }
                        Stepper(value: Binding(
                            get: { realLast },
                            set: { new in
                                layer.lastClipIndex = max(realFirst, new)
                                commit()
                            }
                        ), in: realFirst...max(lastIndex, realLast)) {
                            Text("au clip \(realLast + 1)")
                                .font(.caption.monospacedDigit())
                        }
                    }

                    if outOfPlan {
                        Text("Ce montage ne compte que \(clipCount) clip(s) : "
                             + "l'incrustation s'arrêtera au dernier. La portée "
                             + "enregistrée est gardée et se rétablira si le "
                             + "montage s'allonge.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    // La durée réelle, en clair : des rangs de clips ne parlent
                    // pas d'eux-mêmes. Calculée sur les rangs BORNÉS, puisqu'elle
                    // décrit ce qui sera réellement rendu.
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
