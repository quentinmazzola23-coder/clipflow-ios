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
    /// Ordre CROISSANT : le projet le plus récent se retrouve EN BAS de la
    /// liste, là où le pouce arrive sans effort. C'est l'inverse de la
    /// convention habituelle, et c'est délibéré — sur un iPhone 16 Pro tenu à
    /// une main, le haut de l'écran est la zone la plus coûteuse à atteindre,
    /// or c'est le dernier projet qu'on rouvre neuf fois sur dix.
    @Query(sort: \ClipProject.updatedAt, order: .forward) private var projects: [ClipProject]
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
            // Informations de build : reléguées EN HAUT, la zone désormais la
            // moins accessible — rien d'actionnable n'y reste.
            Text("v\(BuildInfo.version) (\(BuildInfo.build)) · \(BuildInfo.stamp)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(projects) { project in
                NavigationLink(value: project.persistentModelID) {
                    HStack {
                        ProjectRow(project: project)
                        Spacer(minLength: 8)
                        projectMenu(project)
                    }
                    // Sonde placée DANS une ligne : ses vues parentes
                    // contiennent forcément la zone de défilement de la liste
                    // (ce ne serait pas garanti depuis un .background posé sur
                    // la List elle-même).
                    .background(ScrollBounceDisabler())
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
        // Rebond supprimé quand la liste tient à l'écran. Au-delà, c'est
        // ScrollBounceDisabler (ci-dessous) qui l'empêche : `.basedOnSize` ne
        // couvre QUE le cas « contenu plus court que l'écran ».
        .scrollBounceBehavior(.basedOnSize)
        // Ouverture directement en bas : le dernier projet est sous le pouce
        // sans un seul geste de défilement.
        .defaultScrollAnchor(.bottom)
        // Barre d'actions BASSE : « Stockage » à gauche, « Nouveau projet » à
        // droite — les deux boutons qui occupaient les coins hauts.
        .safeAreaInset(edge: .bottom) { bottomActionBar }
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
        .sheet(isPresented: $showStorage) {
            NavigationStack { StorageView() }
        }
    }

    /// Les deux actions de l'écran, à portée de pouce.
    private var bottomActionBar: some View {
        HStack {
            Button {
                showStorage = true
            } label: {
                Image(systemName: "internaldrive")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stockage")

            Spacer()

            Button {
                createProject()
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Nouveau projet")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    /// Menu ⋯ par projet — mêmes options que dans l'éditeur, accessibles
    /// sans ouvrir le projet.
    private func projectMenu(_ project: ClipProject) -> some View {
        Menu {
            Menu("Durée finale : \(durationLabel(project))") {
                Picker("Durée", selection: durationModeBinding(project)) {
                    ForEach(ExactDuration.presets, id: \.centiseconds) { preset in
                        Text(preset.label).tag(DurationMode.fixed(preset.centiseconds))
                    }
                    if !project.durationToRushEnd,
                       !ExactDuration.presets.contains(where: {
                           $0.centiseconds == project.finalDurationCentiseconds
                       }) {
                        Text(project.finalDuration.label)
                            .tag(DurationMode.fixed(project.finalDurationCentiseconds))
                    }
                    Text("Jusqu'à la fin du rush").tag(DurationMode.toRushEnd)
                }
                // Options à plat : pas de sous-menu supplémentaire.
                .pickerStyle(.inline)
            }
            Toggle("Toucher = centre de la sélection", isOn: settingBinding(project, \.touchAnchorIsCenter))
            Toggle("Export automatique à la validation", isOn: settingBinding(project, \.autoExportOnValidate))
            Toggle("Aperçu léger (540p, + fluide)", isOn: settingBinding(project, \.previewLight))
            Toggle("Flux optique (fluide, peut créer des artefacts)",
                   isOn: settingBinding(project, \.opticalFlowEnabled))
            Toggle("Album Photos par projet", isOn: settingBinding(project, \.albumPerProject))
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

    private func durationLabel(_ project: ClipProject) -> String {
        project.durationToRushEnd ? "fin du rush" : project.finalDuration.label
    }

    /// Même choix unique que dans l'éditeur : durée fixe OU fin du rush.
    /// Le réglage est global, donc il suit le prochain projet créé.
    private func durationModeBinding(_ project: ClipProject) -> Binding<DurationMode> {
        Binding(
            get: {
                project.durationToRushEnd
                    ? .toRushEnd
                    : .fixed(project.finalDurationCentiseconds)
            },
            set: { mode in
                switch mode {
                case .toRushEnd:
                    project.durationToRushEnd = true
                case .fixed(let centiseconds):
                    project.durationToRushEnd = false
                    project.finalDurationCentiseconds = centiseconds
                }
                try? modelContext.save()
                AppSettings.capture(from: project)
            }
        )
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
