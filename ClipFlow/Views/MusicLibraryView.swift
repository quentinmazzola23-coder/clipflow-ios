//
//  MusicLibraryView.swift
//  ClipFlow
//
//  BIBLIOTHÈQUE MUSICALE LOCALE : la banque de morceaux, importée une fois,
//  analysée une fois, réutilisée dans tous les projets.
//
//  Remplace la recherche en ligne, retirée après mesure : une fois écartées
//  les licences non commerciales, les catalogues libres ne rendaient rien
//  d'utilisable pour un montage POV, et les bons catalogues (Artlist,
//  Epidemic) réservent leurs API aux plateformes sous contrat. L'app fait
//  donc ce qu'elle peut faire excellemment : gérer TES morceaux.
//
//  Chaque ligne affiche le BPM et la DURÉE DE COUPE que le morceau produira
//  au cran de densité courant. C'est le point : on choisit sa musique en
//  sachant ce qu'elle imposera aux clips, avant même de dérusher.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MusicLibraryView: View {
    /// Densité courante du projet — sert à afficher la durée de coupe.
    var density: CutDensity
    /// Morceau déjà retenu par le projet, s'il y en a un — marqué dans la liste.
    var currentFilename: String?
    /// Morceau retenu. La feuille se ferme derrière.
    var onPick: (MusicTrack) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \MusicTrack.importedAt, order: .reverse) private var tracks: [MusicTrack]

    @State private var showImporter = false
    @State private var message: String?
    @State private var pendingDeletion: MusicTrack?
    @State private var sortByBPM = false

    private var library: MusicLibraryController { MusicLibraryController.shared }

    /// Tri par BPM quand demandé — on cherche souvent « un morceau à 150 ».
    private var displayed: [MusicTrack] {
        sortByBPM ? tracks.sorted { $0.bpm > $1.bpm } : tracks
    }

    var body: some View {
        List {
            if library.isWorking {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Analyse : \(library.analyzingTitle ?? "…")")
                                .font(.footnote)
                            Text("\(library.remainingCount) morceau(x) restant(s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if tracks.isEmpty {
                Section {
                    VStack(spacing: 14) {
                        Text("Aucun morceau dans la bibliothèque.\n\nImportez vos musiques une seule fois : ClipFlow les analyse et retient leur BPM. Ensuite, un seul tap suffit pour les réutiliser sur n'importe quel projet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        // BOUTON EXPLICITE : un écran vide qui ne renvoie qu'à
                        // un petit « + » de barre d'outils laisse l'utilisateur
                        // sans porte d'entrée visible.
                        Button {
                            showImporter = true
                        } label: {
                            Label("Importer des morceaux", systemImage: "plus")
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(displayed) { track in
                        row(track)
                    }
                } header: {
                    Text("\(tracks.count) morceau(x)")
                }
            }
        }
        .task {
            // Reprend une analyse laissée en plan (app fermée pendant l'import).
            library.resumePending(context: modelContext)
        }
        .navigationTitle("Bibliothèque")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Fermer")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { sortByBPM.toggle() } label: {
                    Image(systemName: sortByBPM ? "metronome.fill" : "clock")
                }
                .accessibilityLabel(sortByBPM ? "Trier par date d'import" : "Trier par BPM")
                .disabled(tracks.count < 2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Importer des morceaux")
            }
        }
        // IMPORT EN LOT : on vide un dossier de téléchargements d'un coup,
        // au lieu d'un aller-retour par morceau.
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let outcome = library.importTracks(from: urls, context: modelContext)
                if !outcome.failures.isEmpty {
                    message = "\(outcome.added) morceau(x) importé(s). Échecs :\n"
                        + outcome.failures.joined(separator: "\n")
                }
            case .failure(let error):
                message = "Sélection impossible : \(error.localizedDescription)"
            }
        }
        .alert("Bibliothèque", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(
            "Supprimer ce morceau ?",
            isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let track = pendingDeletion { library.delete(track, context: modelContext) }
                pendingDeletion = nil
            }
            Button("Annuler", role: .cancel) { pendingDeletion = nil }
        } message: {
            // SEULE confirmation de l'app, et elle se justifie : le morceau
            // sert peut-être à des projets déjà montés, qui perdraient leur
            // bande-son sans possibilité de la retrouver.
            if let track = pendingDeletion {
                let used = library.projectsUsing(track, context: modelContext)
                Text(used.isEmpty
                     ? "Le fichier sera effacé du téléphone."
                     : "Utilisé par \(used.count) projet(s) : \(used.map(\.name).joined(separator: ", ")). Leur montage perdra sa musique.")
            }
        }
    }

    private func row(_ track: MusicTrack) -> some View {
        Button {
            guard track.isAnalyzed else {
                message = track.analysisError
                    ?? "Ce morceau n'est pas encore analysé — patientez quelques secondes."
                return
            }
            track.lastUsedAt = .now
            try? modelContext.save()
            onPick(track)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if track.isAnalyzed {
                        HStack(spacing: 10) {
                            Label(String(format: "%.0f BPM", track.bpm), systemImage: "metronome")
                            Text(track.durationLabel)
                            if let ms = track.slotMilliseconds(density: density) {
                                Text("coupes \(ms) ms")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    } else if let error = track.analysisError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else {
                        Text("En attente d'analyse…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                if track.filename == currentFilename {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                } else if track.isAnalyzed {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 44) // cible tactile réglementaire
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = track
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
            // Secours dès que le morceau n'est pas exploitable — pas
            // seulement en cas d'erreur affichée. Un morceau resté « en
            // attente » (app fermée pendant l'import) n'avait aucune issue.
            if !track.isAnalyzed {
                Button {
                    library.reanalyze(track, context: modelContext)
                } label: {
                    Label("Analyser", systemImage: "arrow.clockwise")
                }
                .tint(Theme.accent)
            }
        }
    }
}
