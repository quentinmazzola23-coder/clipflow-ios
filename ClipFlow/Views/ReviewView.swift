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
    @State private var playAllTask: Task<Void, Never>?
    @State private var currentPassageID: PersistentIdentifier?
    @State private var editingPassage: Passage?
    @State private var editingCategories: Set<String> = []

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
                .buttonStyle(.borderedProminent)
                Spacer()
                Text("\(reviewOrder.count) passage(s)")
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
                        Button {
                            editingPassage = passage
                            editingCategories = Set(passage.categories)
                        } label: {
                            Label("Catégories", systemImage: "tag")
                        }
                    }
                }
            }
            .listStyle(.plain)
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
        .sheet(item: $editingPassage) { passage in
            CategoryPanelView(groups: project.categoryGroups, selected: $editingCategories)
                .presentationDetents([.medium])
                .onDisappear {
                    passage.categories = editingCategories.sorted()
                    try? modelContext.save()
                }
        }
        .onDisappear { stopPlayAll() }
    }

    // MARK: - Lecture

    private func playOne(_ passage: Passage) {
        stopPlayAll()
        guard let proxyPath = passage.rush?.proxyRelativePath else { return }
        currentPassageID = passage.persistentModelID
        playback.load(proxyPath: proxyPath)
        playback.playLoop(range: passage.sourceRange)
    }

    /// Lecture continue : chaque passage joué une fois, enchaînement automatique.
    private func startPlayAll() {
        stopPlayAll()
        let passages = reviewOrder
        playAllTask = Task {
            for passage in passages {
                guard !Task.isCancelled else { break }
                guard let proxyPath = passage.rush?.proxyRelativePath else { continue }
                currentPassageID = passage.persistentModelID
                playback.load(proxyPath: proxyPath)
                playback.playLoop(range: passage.sourceRange)
                // Durée de lecture réelle du segment source (les proxys conservent
                // la base de temps du rush).
                let seconds = passage.sourceDuration.seconds
                try? await Task.sleep(for: .seconds(seconds))
            }
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
                HStack(spacing: 6) {
                    Text(String(format: "%.2f s → %@",
                                passage.sourceDuration.seconds,
                                ExactDuration(centiseconds: passage.finalDurationCentiseconds).label))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(passage.categories.prefix(3), id: \.self) { category in
                        Text(category.split(separator: ":").last.map(String.init) ?? category)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                }
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
