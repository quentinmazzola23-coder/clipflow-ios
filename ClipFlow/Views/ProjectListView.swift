//
//  ProjectListView.swift
//  ClipFlow
//
//  Écran Projets : liste, création, suppression, accès stockage.
//

import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ClipProject.updatedAt, order: .reverse) private var projects: [ClipProject]
    @State private var showStorage = false
    @State private var pendingDeletion: ClipProject?

    var body: some View {
        List {
            ForEach(projects) { project in
                NavigationLink(value: project.persistentModelID) {
                    ProjectRow(project: project)
                }
            }
            .onDelete { offsets in
                if let index = offsets.first { pendingDeletion = projects[index] }
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView(
                    "Aucun projet",
                    systemImage: "film.stack",
                    description: Text("Créez un projet puis importez vos rushes depuis Photos.")
                )
            }
        }
        .navigationTitle("ClipFlow")
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let project = modelContext.model(for: id) as? ClipProject {
                ProjectEditorView(project: project)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showStorage = true
                } label: {
                    Label("Stockage", systemImage: "internaldrive")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createProject()
                } label: {
                    Label("Nouveau projet", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showStorage) {
            NavigationStack { StorageView() }
        }
        .confirmationDialog(
            "Supprimer ce projet ?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer projet et fichiers (\(pendingDeletionSize))", role: .destructive) {
                if let project = pendingDeletion {
                    deleteProjectAndFiles(project)
                }
                pendingDeletion = nil
            }
            Button("Annuler", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Supprime le projet, ses copies de rushes et ses caches sur l'iPhone. Les vidéos originales de Photos et les clips déjà exportés ne sont pas touchés.")
        }
    }

    private var pendingDeletionSize: String {
        guard let project = pendingDeletion else { return "" }
        var bytes: Int64 = 0
        for rush in project.rushes {
            if let path = rush.localSourceRelativePath {
                let url = StorageManager.url(forSourceRelativePath: path)
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        for passage in project.passages {
            if let path = passage.cachedRangeRelativePath {
                let url = StorageManager.url(forCachedRangeRelativePath: path)
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return StorageManager.formatBytes(bytes)
    }

    /// La cascade SwiftData efface les entités, PAS les fichiers : suppression
    /// disque explicite (sources copiées + plages cachées) — sinon fuite
    /// d'espace silencieuse à chaque projet supprimé.
    private func deleteProjectAndFiles(_ project: ClipProject) {
        for rush in project.rushes {
            if let path = rush.localSourceRelativePath {
                try? FileManager.default.removeItem(at: StorageManager.url(forSourceRelativePath: path))
            }
        }
        for passage in project.passages {
            if let path = passage.cachedRangeRelativePath {
                try? FileManager.default.removeItem(at: StorageManager.url(forCachedRangeRelativePath: path))
            }
        }
        modelContext.delete(project)
        try? modelContext.save()
        ThumbnailCache.shared.clearMemory()
    }

    private func createProject() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        let project = ClipProject(name: "Projet du \(formatter.string(from: .now))")
        modelContext.insert(project)
        try? modelContext.save()
    }

}

private struct ProjectRow: View {
    let project: ClipProject

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            HStack(spacing: 12) {
                Label("\(project.rushes.count) rushes", systemImage: "film")
                Label("\(project.passages.count) sélections", systemImage: "scissors")
                let exported = project.passages.filter { $0.exportState == .exported }.count
                if exported > 0 {
                    Label("\(exported) exportés", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(project.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
