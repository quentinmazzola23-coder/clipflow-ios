//
//  MontageClipsSheet.swift
//  ClipFlow
//
//  LA LISTE DES CLIPS DU MONTAGE : leur ordre, leur numéro, leur suppression.
//
//  L'écran de montage montrait le résultat sans jamais montrer la matière. On y
//  repérait bien qu'un plan tombait mal, mais rien ne permettait de dire lequel,
//  ni de le retirer, ni de le déplacer : il fallait ressortir vers le dérushage,
//  retrouver le clip à l'œil dans la timeline, et revenir. Pour un montage de
//  cent cinquante plans, autant dire jamais.
//
//  LE NUMÉRO EST LA CLÉ DE TOUT. C'est le même que celui affiché discrètement
//  sur l'aperçu pendant la lecture : on voit passer le plan 47, on ouvre cette
//  liste, on va au 47. Sans cette correspondance, une liste de clips serait un
//  inventaire de plus.
//
//  L'ORDRE EST CELUI DE VALIDATION, et il se réécrit. `orderedPassages` trie sur
//  `validationIndex` : déplacer une ligne renumérote la suite. Aucun champ
//  nouveau n'a été nécessaire — l'ordre du montage a toujours été celui-là, il
//  n'était simplement pas modifiable.
//

import SwiftUI
import SwiftData
import AVFoundation

struct MontageClipsSheet: View {
    @Bindable var project: ClipProject
    /// Appelé quand l'ordre ou le contenu change : le plan doit être refait.
    var onChanged: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var undo = DeletionUndo()
    @State private var blockedMessage: String?
    /// Un déplacement ou une suppression a-t-il eu lieu ?
    ///
    /// Sans ce drapeau, refermer la liste reconstruisait le plan et jetait le
    /// lecteur MÊME quand on n'avait rien touché — or ouvrir la liste pour y
    /// lire un numéro, hésiter, et ressortir est exactement le geste que cet
    /// écran doit rendre possible. On perdait sa position de lecture et
    /// plusieurs secondes de reconstruction pour rien.
    @State private var didChange = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(project.orderedPassages.enumerated()),
                        id: \.element.persistentModelID) { index, passage in
                    MontageClipRow(number: index + 1, passage: passage)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            }
            .listStyle(.plain)
            .navigationTitle("Clips (\(project.orderedPassages.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // GLISSER TOUJOURS ACTIF, pas de bouton « Modifier ».
                //
                // `EditMode` permanent évite le tap supplémentaire qui précède
                // chaque réorganisation, et les poignées disent d'elles-mêmes
                // que les lignes se déplacent.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .overlay(alignment: .bottomTrailing) {
                if let pending = undo.pending {
                    UndoButton(pending: pending, count: undo.count) { undo.undo() }
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
            .animation(.snappy(duration: 0.22), value: undo.pending?.id)
            .alert("Action impossible", isPresented: Binding(
                get: { blockedMessage != nil },
                set: { if !$0 { blockedMessage = nil } }
            )) {
                Button("OK") { blockedMessage = nil }
            } message: {
                Text(blockedMessage ?? "")
            }
            .overlay {
                if project.orderedPassages.isEmpty {
                    ContentUnavailableView(
                        "Aucun clip",
                        systemImage: "rectangle.stack",
                        description: Text("Validez des clips au dérushage : ils apparaîtront ici, "
                                          + "dans l'ordre du montage.")
                    )
                }
            }
        }
        .onDisappear {
            // Un sursis ne survit pas à l'écran qui l'affichait : sinon plus
            // rien ne peut l'annuler, et le clip resterait masqué sans jamais
            // être effacé.
            undo.consumeNow()
            if didChange { onChanged() }
        }
    }

    /// Réordonne en RÉÉCRIVANT les index de validation.
    ///
    /// Toute la suite est renumérotée, pas seulement la ligne déplacée : des
    /// index à trous se recroiseraient à la première insertion, et deux clips
    /// portant le même rang auraient un ordre décidé par le hasard du tri.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = project.orderedPassages
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, passage) in ordered.enumerated() {
            passage.validationIndex = index
        }
        // PUIS RENUMÉROTATION GLOBALE, sursis compris : ne renuméroter que les
        // lignes visibles laissait un clip en attente de suppression sur un
        // rang que l'un d'elles venait de reprendre. L'annuler ensuite posait
        // deux clips au même rang, et leur ordre cessait d'être le nôtre.
        project.renumberPassages()
        didChange = true
        try? modelContext.save()
        onChanged()
    }

    private func delete(at offsets: IndexSet) {
        // JAMAIS PENDANT UN EXPORT : il lit en ce moment les fichiers de ces
        // clips, et les effacer sous lui ferait échouer la composition après
        // plusieurs minutes de rendu.
        if let reason = MediaAvailabilityService.blockingReason() {
            blockedMessage = reason
            return
        }
        let ordered = project.orderedPassages
        for offset in offsets where offset >= 0 && offset < ordered.count {
            let passage = ordered[offset]
            // MISE EN SURSIS, comme partout ailleurs : les fichiers restent en
            // place le temps qu'un « Annuler » puisse encore les rappeler.
            passage.isPendingDeletion = true
            undo.schedule(label: "Clip supprimé") {
                if let cached = passage.cachedRangeRelativePath {
                    try? FileManager.default.removeItem(
                        at: StorageManager.url(forCachedRangeRelativePath: cached))
                }
                MontageSmoothing.discard(passage)
                modelContext.delete(passage)
                // Les rangs redeviennent consécutifs : c'est ce qui garde
                // `validationIndex` égal à la POSITION, donc les numéros
                // identiques d'un écran à l'autre.
                project.renumberPassages()
                try? modelContext.save()
            } restore: {
                passage.isPendingDeletion = false
                project.renumberPassages()
                try? modelContext.save()
                onChanged()
            }
        }
        didChange = true
        try? modelContext.save()
        onChanged()
    }
}

/// Une ligne : le numéro, une vignette, la durée, l'état d'export.
private struct MontageClipRow: View {
    let number: Int
    let passage: Passage
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            // LE NUMÉRO D'ABORD, en chiffres tabulaires : c'est par lui qu'on
            // relie ce qu'on a vu passer à l'écran et la ligne qu'on cherche.
            Text("\(number)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 30, alignment: .trailing)

            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.08))
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(passage.rush?.originalFilename.isEmpty == false
                     ? passage.rush!.originalFilename
                     : "Rush supprimé")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(durationLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if passage.exportState == .exported {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .task {
            guard thumbnail == nil else { return }
            guard let source = MediaAvailabilityService.exportSource(for: passage) else { return }
            ThumbnailCache.shared.requestThumbnail(
                fileURL: source.url,
                key: source.url.lastPathComponent,
                time: source.rangeInFile.start
            ) { image in
                thumbnail = image
            }
        }
    }

    private var durationLabel: String {
        let seconds = Double(passage.finalDurationCentiseconds) / 100
        return String(format: "%.2f s", seconds)
    }
}
