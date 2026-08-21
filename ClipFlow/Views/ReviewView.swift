//
//  ReviewView.swift
//  ClipFlow
//
//  Mode Relecture : passages validés lus à la suite, dans l'ordre de capture,
//  depuis les PROXYS (réactivité maximale, pas de flux optique ici).
//  Actions : lecture continue, suppression, réordonnancement, catégories.
//

import SwiftUI
import SwiftData
import CoreMedia

struct ReviewView: View {
    @Bindable var project: ClipProject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var playback = ProxyPlaybackEngine()
    @State private var blockedMessage: String?
    @State private var playAllTask: Task<Void, Never>?
    @State private var currentPassageID: PersistentIdentifier?

    /// Ordre de relecture = ordre de capture (rush, puis position dans le rush).
    private var reviewOrder: [Passage] {
        project.passages.sorted { a, b in
            let ra = a.rush?.orderIndex ?? 0
            let rb = b.rush?.orderIndex ?? 0
            if ra != rb { return ra < rb }
            return CMTimeCompare(a.start, b.start) < 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: playback.player)
                .frame(maxHeight: 260)

            HStack {
                Button {
                    playAllTask == nil ? startPlayAll() : stopPlayAll()
                } label: {
                    Label(playAllTask == nil ? "Tout lire" : "Arrêter",
                          systemImage: playAllTask == nil ? "play.fill" : "stop.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                Spacer()
                Text("\(reviewOrder.count) clip(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            List {
                ForEach(reviewOrder) { passage in
                    PassageRow(
                        passage: passage,
                        isCurrent: passage.persistentModelID == currentPassageID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { playOne(passage) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            delete(passage)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .alert("Action impossible", isPresented: Binding(
            get: { blockedMessage != nil },
            set: { if !$0 { blockedMessage = nil } }
        )) {
            Button("OK") { blockedMessage = nil }
        } message: {
            Text(blockedMessage ?? "")
        }
        .navigationTitle("Relecture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer") {
                    stopPlayAll()
                    dismiss()
                }
            }
        }
        .onDisappear { stopPlayAll() }
    }

    // MARK: - Lecture

    private func playOne(_ passage: Passage) {
        stopPlayAll()
        guard let rush = passage.rush else { return }
        currentPassageID = passage.persistentModelID
        playback.load(rush: rush)
        playback.playLoop(range: passage.sourceRange)
    }

    /// Lecture continue : chaque passage joué une fois, enchaînement automatique.
    private func startPlayAll() {
        stopPlayAll()
        let passages = reviewOrder
        playAllTask = Task {
            for passage in passages {
                guard !Task.isCancelled else { break }
                guard let rush = passage.rush else { continue }
                currentPassageID = passage.persistentModelID
                playback.load(rush: rush)
                playback.playLoop(range: passage.sourceRange)
                // Durée de lecture réelle du segment source (les proxys conservent
                // la base de temps du rush).
                let seconds = passage.sourceDuration.seconds
                try? await Task.sleep(for: .seconds(seconds))
            }
            // ÉPILOGUE SEULEMENT SI LA TÂCHE VIT ENCORE. Annulée (l'utilisateur
            // a tapé un passage précis), sa continuation reprend APRÈS que la
            // nouvelle lecture a démarré : ce `pause()` coupait alors le
            // passage qu'on venait de lancer, et effaçait son surlignage.
            guard !Task.isCancelled else { return }
            playback.pause()
            currentPassageID = nil
            playAllTask = nil
        }
    }

    private func stopPlayAll() {
        playAllTask?.cancel()
        playAllTask = nil
        playback.pause()
        currentPassageID = nil
    }

    private func delete(_ passage: Passage) {
        // Sa plage cachée peut être en cours de lecture par un rendu.
        if let reason = MediaAvailabilityService.blockingReason() {
            blockedMessage = reason
            return
        }
        if currentPassageID == passage.persistentModelID { stopPlayAll() }
        if let cached = passage.cachedRangeRelativePath {
            try? FileManager.default.removeItem(
                at: StorageManager.url(forCachedRangeRelativePath: cached)
            )
        }
        modelContext.delete(passage)
        try? modelContext.save()
    }
}

private struct PassageRow: View {
    let passage: Passage
    let isCurrent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(passage.validationIndex + 1) · \(passage.rush?.originalFilename ?? "rush supprimé")")
                    .font(.subheadline)
                Text(String(format: "%.2f s → %@",
                            passage.sourceDuration.seconds,
                            ExactDuration(centiseconds: passage.finalDurationCentiseconds).label))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if passage.exportState == .exported {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 2)
    }
}
