//
//  StorageView.swift
//  ClipFlow
//
//  Gestion du stockage : tailles par catégorie, suppressions ciblées.
//  Ne supprime JAMAIS d'original dans Photos.
//

import SwiftUI
import SwiftData

struct StorageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var blockedMessage: String?
    @State private var orphanMusicSize: Int64 = 0
    @State private var proxiesSize: Int64 = 0
    @State private var rangesSize: Int64 = 0
    @State private var sourcesSize: Int64 = 0
    @State private var exportsSize: Int64 = 0
    @State private var freeSpace: Int64 = 0

    var body: some View {
        List {
            Section("Espace disponible sur l'iPhone") {
                Text(StorageManager.formatBytes(freeSpace))
                    .font(.title3.monospacedDigit())
            }
            Section("Occupation ClipFlow") {
                // Suppression directe, sans confirmation (demande utilisateur).
                row("Proxys (anciens, inutilisés)", size: proxiesSize) {
                    StorageManager.clearProxies()
                    ThumbnailCache.shared.clearMemory()
                    refresh()
                }
                row("Plages sources en cache", size: rangesSize) {
                    // GARDE : ces fichiers sont la source des exports. Les
                    // supprimer pendant un rendu le cassait, et rendait les
                    // passages dont le rush avait été libéré DÉFINITIVEMENT
                    // inexportables (plus de source pour reconstruire).
                    guard guardOrExplain() else { return }
                    StorageManager.clearCachedRanges()
                    forgetCachedRanges()
                    refresh()
                }
                row("Rendus temporaires", size: exportsSize) {
                    // GARDE : c'est le dossier où l'encodeur écrit le fichier
                    // en cours.
                    guard guardOrExplain() else { return }
                    StorageManager.clearExports()
                    refresh()
                }
                row("Fichiers musicaux orphelins", size: orphanMusicSize) {
                    guard guardOrExplain() else { return }
                    clearOrphanMusic()
                    refresh()
                }
                HStack {
                    Text("Copies sources (mode hors-ligne)")
                    Spacer()
                    Text(StorageManager.formatBytes(sourcesSize))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Vos morceaux importés se gèrent dans la Bibliothèque de l'écran Montage — ils ne sont pas touchés ici. Les vidéos originales de votre photothèque ne sont jamais supprimées par ClipFlow. Supprimer les proxys est sans risque : ils se régénèrent automatiquement. Supprimer une plage en cache peut rendre un clip non exportable hors ligne.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Stockage")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }
            }
        }
        .onAppear(perform: refresh)
        .alert("Action impossible", isPresented: Binding(
            get: { blockedMessage != nil },
            set: { if !$0 { blockedMessage = nil } }
        )) {
            Button("OK") { blockedMessage = nil }
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    /// Vrai si l'opération peut se faire ; sinon affiche POURQUOI.
    private func guardOrExplain() -> Bool {
        if let reason = MediaAvailabilityService.blockingReason() {
            blockedMessage = reason
            return false
        }
        return true
    }

    /// Après purge des plages, les passages ne doivent plus prétendre en
    /// avoir une : sans ça, l'export échouait sur un fichier absent au lieu
    /// de retomber sur la copie source.
    private func forgetCachedRanges() {
        let descriptor = FetchDescriptor<Passage>()
        guard let passages = try? modelContext.fetch(descriptor) else { return }
        for passage in passages {
            guard passage.cachedRangeRelativePath != nil
                    || passage.smoothedRangeRelativePath != nil else { continue }
            passage.cachedRangeRelativePath = nil
            // Le fichier lissé était dans le dossier purgé lui aussi : le
            // passage doit cesser de le réclamer, sinon le montage viserait un
            // fichier absent au lieu de retomber sur la copie source.
            passage.smoothedRangeRelativePath = nil
        }
        try? modelContext.save()
    }

    /// Fichiers de Music/ que la BIBLIOTHÈQUE ne connaît pas.
    ///
    /// ⚠️ La référence est la bibliothèque (`MusicTrack`), PAS les projets.
    /// Comparer aux `project.musicFilename` effacerait tous les morceaux
    /// importés mais pas encore utilisés dans un montage — c'est-à-dire la
    /// bibliothèque elle-même. Ne restent ici que de vrais reliquats :
    /// fichiers laissés par une version antérieure ou par un import
    /// interrompu.
    private func orphanMusicFiles() -> [URL] {
        let descriptor = FetchDescriptor<MusicTrack>()
        let known = Set((try? modelContext.fetch(descriptor))?.map(\.filename) ?? [])
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: MusicStore.musicDirectory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.filter { !known.contains($0.lastPathComponent) }
    }

    private func clearOrphanMusic() {
        // Par `MusicStore` : la carte de rythme en cache part avec le fichier,
        // sinon elle resterait orpheline à son tour.
        for url in orphanMusicFiles() {
            MusicStore.deleteMusic(filename: url.lastPathComponent)
        }
    }

    private func row(_ title: String, size: Int64, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(StorageManager.formatBytes(size))
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func refresh() {
        orphanMusicSize = orphanMusicFiles().reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        proxiesSize = StorageManager.proxiesSize()
        rangesSize = StorageManager.cachedRangesSize()
        sourcesSize = StorageManager.sourcesSize()
        exportsSize = StorageManager.exportsSize()
        freeSpace = StorageManager.availableCapacity()
    }
}
