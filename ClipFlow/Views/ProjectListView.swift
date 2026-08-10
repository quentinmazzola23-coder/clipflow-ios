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
    /// Chemin de navigation possédé ici : « Nouveau projet » pousse
    /// directement l'éditeur du projet créé (zéro tap intermédiaire).
    @State private var navigationPath: [PersistentIdentifier] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listContent
        }
    }

    private var listContent: some View {
        List {
            ForEach(projects) { project in
                NavigationLink(value: project.persistentModelID) {
                    HStack {
                        ProjectRow(project: project)
                        Spacer(minLength: 8)
                        projectMenu(project)
                    }
                }
                // Balayage gauche COMPLET = suppression directe (fichiers
                // disque inclus), sans étape intermédiaire.
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteProjectAndFiles(project)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
        }
        // Pas de rebond de défilement quand la liste tient à l'écran.
        .scrollBounceBehavior(.basedOnSize)
        // Version + horodatage de build, discrets en bas de la page.
        .safeAreaInset(edge: .bottom) {
            Text("v\(BuildInfo.version) (\(BuildInfo.build)) · \(BuildInfo.stamp)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
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
    }

    /// Menu ⋯ par projet — mêmes options que dans l'éditeur, accessibles
    /// sans ouvrir le projet.
    private func projectMenu(_ project: ClipProject) -> some View {
        Menu {
            Menu("Durée finale : \(project.finalDuration.label)") {
                ForEach(ExactDuration.presets, id: \.centiseconds) { preset in
                    Button(preset.label) {
                        project.finalDurationCentiseconds = preset.centiseconds
                        try? modelContext.save()
                        AppSettings.capture(from: project)
                    }
                }
            }
            Toggle("Toucher = centre de la sélection", isOn: settingBinding(project, \.touchAnchorIsCenter))
            Toggle("Export automatique à la validation", isOn: settingBinding(project, \.autoExportOnValidate))
            Toggle("Aperçu léger (540p, + fluide)", isOn: settingBinding(project, \.previewLight))
            Button {
                guard !RenderQueueController.shared.isBusy() else { return }
                _ = MediaAvailabilityService.releaseSources(in: project)
                try? modelContext.save()
            } label: {
                let releasable = MediaAvailabilityService.releasableSources(in: project)
                    .reduce(Int64(0)) { $0 + $1.bytes }
                Label("Libérer l'espace (\(StorageManager.formatBytes(releasable)))",
                      systemImage: "internaldrive")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    /// Liaison de réglage : écrit le projet ET les réglages globaux.
    private func settingBinding(_ project: ClipProject,
                                _ keyPath: ReferenceWritableKeyPath<ClipProject, Bool>) -> Binding<Bool> {
        Binding(
            get: { project[keyPath: keyPath] },
            set: { newValue in
                project[keyPath: keyPath] = newValue
                try? modelContext.save()
                AppSettings.capture(from: project)
            }
        )
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
        // Nouveau projet = réglages globaux courants (maintien entre projets).
        AppSettings.apply(to: project)
        modelContext.insert(project)
        try? modelContext.save()
        // Ouverture immédiate de l'éditeur — qui, projet vide, ouvre de
        // lui-même le sélecteur Photos : création → choix des rushes direct.
        navigationPath.append(project.persistentModelID)
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
