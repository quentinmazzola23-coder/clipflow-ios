//
//  MusicLibraryView.swift
//  ClipFlow
//
//  BIBLIOTHÈQUE MUSICALE EN LIGNE (Openverse — titres à licence commerciale).
//
//  Même philosophie que le reste : une recherche, des pastilles de genre pour
//  chercher SANS taper, pré-écoute d'un tap, « Utiliser » télécharge et rend
//  la main au montage. Aucune confirmation.
//

import SwiftUI
import AVFoundation

struct MusicLibraryView: View {
    /// Appelé avec le fichier téléchargé (local) et sa fiche.
    var onPicked: (URL, MusicSearchResult) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [MusicSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    /// Note visible quand la recherche est passée par la source de repli.
    @State private var fallbackNote: String?
    @State private var downloadingID: String?
    @State private var previewingID: String?
    @State private var previewPlayer: AVPlayer?
    @State private var searchTask: Task<Void, Never>?

    /// Genres d'un tap — requêtes en anglais, la langue du catalogue.
    private static let genres: [(label: String, query: String)] = [
        ("Électro", "electronic beat"),
        ("Hardstyle", "hardstyle"),
        ("Hip-hop", "hip hop beat"),
        ("Rock", "rock energetic"),
        ("Cinématique", "cinematic epic"),
        ("Chill", "chill lofi"),
    ]

    var body: some View {
        List {
            Section {
                genreChips
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            // Repli actif : le dire, sans en faire une erreur — les résultats
            // sont là, simplement d'un autre catalogue.
            if let fallbackNote {
                Section {
                    Label(fallbackNote, systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if isSearching {
                    HStack {
                        ProgressView()
                        Text("Recherche…").foregroundStyle(.secondary)
                    }
                } else if results.isEmpty && hasSearched {
                    Text("Aucun titre trouvé pour cette recherche — essayez d'autres mots (en anglais, le catalogue est international).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(results) { result in
                        row(result)
                    }
                }
            } footer: {
                if !results.isEmpty {
                    Text("Titres à licence commerciale (CC0 / CC-BY). Les titres CC-BY demandent de créditer l'auteur — le crédit est conservé avec le projet.")
                }
            }
        }
        .navigationTitle("Bibliothèque")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Rechercher un titre, un genre…")
        .onSubmit(of: .search) { search(query) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Fermer la bibliothèque")
            }
        }
        .onDisappear {
            searchTask?.cancel()
            previewPlayer?.pause()
        }
        .onAppear {
            // Écran jamais vide : une première fournée sans aucun geste.
            if results.isEmpty, !hasSearched { search("electronic beat") }
        }
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.genres, id: \.label) { genre in
                    Button {
                        query = genre.query
                        search(genre.query)
                    } label: {
                        Text(genre.label)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ result: MusicSearchResult) -> some View {
        HStack(spacing: 12) {
            // Pré-écoute : lecture en continu depuis le réseau, un tap.
            Button {
                togglePreview(result)
            } label: {
                Image(systemName: previewingID == result.id ? "pause.fill" : "play.fill")
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel(previewingID == result.id ? "Pause" : "Pré-écouter")

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(result.creator).lineLimit(1)
                    if result.durationSeconds > 0 {
                        Text("· \(Int(result.durationSeconds / 60)):\(String(format: "%02d", Int(result.durationSeconds) % 60))")
                    }
                    Text("· \(result.license.uppercased())")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()

            if downloadingID == result.id {
                ProgressView()
            } else {
                Button("Utiliser") { use(result) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(downloadingID != nil)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        errorMessage = nil
        fallbackNote = nil
        isSearching = true
        hasSearched = true
        searchTask = Task {
            defer { isSearching = false }
            do {
                // Toute la mécanique (trois lignes de défense : Openverse,
                // Openverse en UA navigateur, Internet Archive) vit dans
                // MusicLibraryAPI — un seul chemin testable.
                let outcome = try await MusicLibraryAPI.search(query: trimmed)
                guard !Task.isCancelled else { return }
                results = outcome.results
                fallbackNote = outcome.fallbackNote
            } catch is CancellationError {
                // Tâche remplacée par une nouvelle recherche : ne rien toucher.
            } catch let error as URLError {
                guard !Task.isCancelled else { return }
                // Réseau : dire CLAIREMENT que c'est la connexion, pas l'app.
                results = []
                errorMessage = "Pas de connexion à la bibliothèque (\(error.localizedDescription)). Vérifiez le réseau puis réessayez."
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func togglePreview(_ result: MusicSearchResult) {
        if previewingID == result.id {
            previewPlayer?.pause()
            previewingID = nil
            return
        }
        previewPlayer?.pause()
        let player = AVPlayer(url: result.fileURL)
        previewPlayer = player
        previewingID = result.id
        player.play()
    }

    private func use(_ result: MusicSearchResult) {
        previewPlayer?.pause()
        previewingID = nil
        downloadingID = result.id
        Task {
            defer { downloadingID = nil }
            do {
                let (temporary, response) = try await URLSession.shared.download(
                    for: MusicLibraryAPI.request(for: result.fileURL)
                )
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw MusicLibraryError.badResponse(status: http.statusCode)
                }
                // Extension d'après l'URL du fichier (mp3 le plus souvent).
                let ext = result.fileURL.pathExtension.isEmpty ? "mp3" : result.fileURL.pathExtension
                let named = temporary.deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try? FileManager.default.moveItem(at: temporary, to: named)
                onPicked(named, result)
                dismiss()
            } catch let error as URLError {
                errorMessage = "Téléchargement interrompu (\(error.localizedDescription)). Vérifiez le réseau puis réessayez."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
