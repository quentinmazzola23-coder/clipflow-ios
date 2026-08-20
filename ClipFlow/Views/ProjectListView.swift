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
    @State private var blockedMessage: String?

    /// Un rendu (clips ou montage) tourne-t-il ? Les suppressions de projet
    /// sont interdites tant que c'est vrai.
    private var isAnyExportRunning: Bool {
        RenderQueueController.shared.isRunningFlag
            || RenderQueueController.shared.hasPendingFlag
            || MontageExportController.shared.isExporting
    }

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
                    // Supprimer pendant un rendu détruisait les fichiers que
                    // le moteur lisait ET les entités SwiftData qu'il écrivait
                    // encore à la fin de chaque clip : plantage garanti.
                    .disabled(isAnyExportRunning)
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
        // Placée AVANT la barre : posée après, cette vue se serait superposée
        // à la barre d'actions et aurait avalé le tap sur « + » — le seul
        // bouton utile quand justement il n'y a aucun projet.
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView(
                    "Aucun projet",
                    systemImage: "film.stack",
                    description: Text("Créez un projet puis importez vos rushes depuis Photos.")
                )
                // Purement informative : elle ne doit intercepter aucun geste.
                .allowsHitTesting(false)
            }
        }
        // Barre d'actions BASSE : « Stockage » à gauche, « Nouveau projet » à
        // droite — les deux boutons qui occupaient les coins hauts.
        .safeAreaInset(edge: .bottom) { bottomActionBar }
        .navigationTitle("ClipFlow")
        .navigationDestination(for: PersistentIdentifier.self) { id in
            if let project = modelContext.model(for: id) as? ClipProject {
                ProjectEditorView(project: project)
            }
        }
        .sheet(isPresented: $showStorage) {
            NavigationStack { StorageView() }
        }
        .alert("Action impossible", isPresented: Binding(
            get: { blockedMessage != nil },
            set: { if !$0 { blockedMessage = nil } }
        )) {
            Button("OK") { blockedMessage = nil }
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    /// Les deux actions de l'écran, à portée de pouce.
    ///
    /// Boutons montés avec `GlassIconButtonStyle`, le style DÉJÀ utilisé
    /// partout dans l'éditeur, et non un empilement refait à la main : c'est
    /// lui qui pose la zone tactile (`contentShape`) en plus du verre. Sans
    /// elle, un bouton `.plain` ne réagit que sur les traits de son glyphe —
    /// le « + » n'était touchable que sur la croix elle-même, au milieu d'un
    /// disque de 58 points. En barre d'outils, le système fournissait cette
    /// zone ; en la descendant ici, il fallait la fournir soi-même.
    private var bottomActionBar: some View {
        HStack {
            Button {
                showStorage = true
            } label: {
                Image(systemName: "internaldrive")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            .accessibilityLabel("Stockage")

            Spacer()

            Button {
                createProject()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(GlassIconButtonStyle(tint: Theme.accent, diameter: 58, glyphSize: 24))
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
                // Garde UNIFIÉ (file de clips + export montage), et l'échec
                // est DIT : le silence laissait croire à un bouton mort.
                if let reason = MediaAvailabilityService.blockingReason() {
                    blockedMessage = reason
                    return
                }
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
                AppSettings.captureDuration(
                    centiseconds: project.finalDurationCentiseconds,
                    toRushEnd: project.durationToRushEnd
                )
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
                // UNE SEULE clé écrite : ce projet n'a pas forcément été
                // aligné sur les réglages globaux, tout recapturer depuis lui
                // ferait reculer les réglages faits ailleurs.
                AppSettings.captureFlag(keyPath, value: newValue)
            }
        )
    }

    /// La cascade SwiftData efface les entités, PAS les fichiers : suppression
    /// disque explicite (sources copiées + plages cachées) — sinon fuite
    /// d'espace silencieuse à chaque projet supprimé.
    private func deleteProjectAndFiles(_ project: ClipProject) {
        // GARDE DANS LA FONCTION, pas seulement sur le bouton : un balayage
        // complet déclenche l'action sans passer par l'état `disabled`, et un
        // bouton grisé n'explique rien. Ici l'utilisateur apprend CE QUI bloque.
        if let reason = MediaAvailabilityService.blockingReason() {
            blockedMessage = reason
            return
        }
        // Les passages de ce projet quittent la file AVANT la suppression :
        // leurs identifiants survivraient sinon à des entités détruites.
        RenderQueueController.shared.forget(
            passageIDs: project.passages.map(\.persistentModelID)
        )
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
        // La MUSIQUE n'est PAS supprimée : depuis la bibliothèque locale, un
        // morceau appartient à la banque et sert souvent à plusieurs projets.
        // Il se supprime depuis l'écran Bibliothèque, qui prévient alors des
        // projets concernés.
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
