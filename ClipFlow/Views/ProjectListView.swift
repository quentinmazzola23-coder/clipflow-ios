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

    var body: some View {
        List {
            ForEach(projects) { project in
                NavigationLink(value: project.persistentModelID) {
                    ProjectRow(project: project)
                }
            }
            .onDelete(perform: deleteProjects)
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

    private func createProject() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        let project = ClipProject(name: "Projet du \(formatter.string(from: .now))")
        modelContext.insert(project)
        try? modelContext.save()
    }

    private func deleteProjects(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(projects[index])
        }
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
                let proxied = project.rushes.filter { $0.proxyRelativePath != nil }.count
                if proxied < project.rushes.count {
                    Label("proxys \(proxied)/\(project.rushes.count)", systemImage: "gearshape.arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
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
