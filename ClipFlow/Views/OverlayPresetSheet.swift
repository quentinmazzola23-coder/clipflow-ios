//
//  OverlayPresetSheet.swift
//  ClipFlow
//
//  Liste des préréglages d'incrustations : en poser un, en enregistrer un,
//  en supprimer un.
//
//  Un tap sur une ligne POSE le préréglage et referme — c'est l'action qu'on
//  vient chercher, elle ne doit pas coûter deux gestes. La suppression passe
//  par le glissement, geste que personne ne fait par accident.
//
//  La configuration remplacée est capturée automatiquement sous « Avant le
//  préréglage », qui apparaît dans cette même liste : revenir en arrière est un
//  tap, pas une boîte de dialogue. C'est la réponse de l'app à « aucune
//  confirmation » — on ne demande pas la permission, on rend le retour possible.
//

import SwiftUI
import SwiftData

struct OverlayPresetSheet: View {
    @Bindable var project: ClipProject
    /// Forme du montage d'arrivée : les ancrages y sont recalculés.
    var videoRatio: Double

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \OverlayPreset.updatedAt, order: .reverse)
    private var presets: [OverlayPreset]

    @State private var showNameField = false
    @State private var draftName = ""
    @State private var message: String?

    private var currentCount: Int { project.overlays.count }

    /// Préréglages visibles ici : tous les vrais, plus le filet de CE projet.
    /// Le filet d'un autre projet reposerait des incrustations qu'on n'a jamais
    /// posées, sous un libellé qui promet le contraire.
    private var visiblePresets: [OverlayPreset] {
        presets.filter { !$0.isAutoBackup || $0.backupProject === project }
    }

    var body: some View {
        List {
            if visiblePresets.isEmpty {
                Section {
                    Text("Aucun préréglage. Posez vos incrustations, puis "
                         + "enregistrez-les ici pour les reposer sur un autre projet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(visiblePresets) { preset in
                Button {
                    apply(preset)
                } label: {
                    row(preset)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        OverlayPresetStore.delete(preset, context: modelContext)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }

            Section {
                Button {
                    draftName = suggestedName()
                    showNameField = true
                } label: {
                    Label(currentCount > 0
                          ? "Enregistrer les \(currentCount) incrustation(s) en cours"
                          : "Rien à enregistrer",
                          systemImage: "square.and.arrow.down")
                }
                .disabled(currentCount == 0)
            }
        }
        .navigationTitle("Préréglages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Terminé") { dismiss() }
            }
        }
        .alert("Nom du préréglage", isPresented: $showNameField) {
            TextField("Intro + filigrane", text: $draftName)
            Button("Enregistrer") { save() }
            Button("Annuler", role: .cancel) { draftName = "" }
        }
        .alert("Préréglages", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func row(_ preset: OverlayPreset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: preset.isAutoBackup
                  ? "arrow.uturn.backward.circle" : "square.stack.3d.up")
                .font(.title3)
                .foregroundStyle(preset.isAutoBackup ? .orange : Theme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                Text(preset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Le détail des portées : c'est ce qui distingue deux
                // préréglages qui ont le même nombre d'éléments.
                ForEach(preset.entries.sorted(by: { $0.stackOrder < $1.stackOrder })) { entry in
                    Text("• \(entryLabel(entry)) — \(entry.scopeLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func entryLabel(_ entry: OverlayPresetEntry) -> String {
        switch entry.kind {
        case .image: return "image"
        case .text:
            let t = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "texte" : "« \(t) »"
        }
    }

    /// Nom proposé, tiré du contenu : on reconnaît un préréglage à ce qu'il
    /// contient bien mieux qu'à « Préréglage 3 ».
    private func suggestedName() -> String {
        let images = project.overlays.filter { $0.kind == .image }.count
        let texts = project.overlays.compactMap { layer -> String? in
            guard layer.kind == .text else { return nil }
            let t = layer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let first = texts.first, images > 0 { return "\(first) + logo" }
        if let first = texts.first { return first }
        if images == 1 { return "Filigrane" }
        if images > 1 { return "\(images) logos" }
        return "Préréglage"
    }

    private func save() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        draftName = ""
        guard !trimmed.isEmpty else {
            message = "Un préréglage sans nom serait introuvable dans la liste : "
                + "rien n'a été enregistré."
            return
        }
        guard currentCount > 0 else { return }
        // Un nom réservé porterait à confusion avec le filet de retour.
        let safe = trimmed == OverlayPresetStore.autoBackupName
            ? trimmed + " (copie)" : trimmed
        OverlayPresetStore.capture(from: project, name: safe, context: modelContext)
    }

    private func apply(_ preset: OverlayPreset) {
        OverlayPresetStore.apply(preset, to: project,
                                 videoRatio: videoRatio, context: modelContext)
        dismiss()
    }
}
