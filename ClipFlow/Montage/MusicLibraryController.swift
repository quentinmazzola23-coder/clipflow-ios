//
//  MusicLibraryController.swift
//  ClipFlow
//
//  IMPORT ET ANALYSE EN LOT des morceaux de la bibliothèque.
//
//  Service PARTAGÉ, hors des vues : on importe vingt morceaux d'un coup et on
//  s'en va. L'analyse continue pendant qu'on dérushe, et l'état survit à la
//  fermeture de l'écran — une tâche logée dans une vue serait perdue au
//  premier retour en arrière (leçon déjà payée sur l'export du montage).
//
//  UN MORCEAU À LA FOIS, délibérément : l'analyse décode l'audio et se
//  dispute le processeur avec la lecture des proxys. En paralléliser plusieurs
//  ne diviserait pas le temps total, ça saccaderait la prévisualisation.
//

import Foundation
import SwiftData

@Observable
@MainActor
final class MusicLibraryController {

    static let shared = MusicLibraryController()

    /// Titre en cours d'analyse — affiché dans la liste.
    private(set) var analyzingTitle: String?
    /// Morceaux restant à analyser (celui en cours compris).
    private(set) var remainingCount = 0

    /// File d'OBJETS, pas d'identifiants.
    ///
    /// `persistentModelID` relevé juste après un `insert` est TEMPORAIRE :
    /// SwiftData le remplace à l'enregistrement, et le résoudre plus tard
    /// échouait — le morceau restait bloqué sur « en attente d'analyse » pour
    /// toujours. Le contrôleur étant sur l'acteur principal, les objets ne
    /// traversent aucune frontière d'isolation : les garder est sûr et exact.
    private var queue: [MusicTrack] = []
    /// Morceau en cours d'analyse — pour que `delete` sache s'il doit annuler.
    private var analyzing: MusicTrack?
    private var worker: Task<Void, Never>?

    private init() {}

    var isWorking: Bool { analyzingTitle != nil || !queue.isEmpty }

    // MARK: - Import

    /// Copie les fichiers choisis dans la bibliothèque et lance leur analyse.
    /// Retourne le nombre de morceaux réellement importés, et les échecs.
    @discardableResult
    func importTracks(from urls: [URL], context: ModelContext) -> (added: Int, failures: [String]) {
        var added = 0
        var failures: [String] = []

        for url in urls {
            do {
                let filename = try MusicStore.importMusic(from: url)
                let track = MusicTrack()
                track.title = url.deletingPathExtension().lastPathComponent
                track.filename = filename
                track.fileSizeBytes = Int64(
                    (try? MusicStore.url(forMusicFilename: filename)
                        .resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                )
                context.insert(track)
                // Enregistré IMMÉDIATEMENT : l'objet doit être persistant
                // avant d'entrer dans la file.
                try? context.save()
                added += 1
                queue.append(track)
            } catch {
                failures.append("\(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
        remainingCount = queue.count
        startWorkerIfNeeded(context: context)
        return (added, failures)
    }

    /// Relance l'analyse d'un morceau qui avait échoué.
    func reanalyze(_ track: MusicTrack, context: ModelContext) {
        track.analysisError = nil
        track.isAnalyzed = false
        try? context.save()
        queue.append(track)
        remainingCount = queue.count
        startWorkerIfNeeded(context: context)
    }

    /// Reprend les analyses laissées en plan par une fermeture de l'app.
    ///
    /// La file vit en mémoire : sans cette reprise, un morceau importé puis
    /// interrompu restait « en attente d'analyse » définitivement, sans
    /// aucun moyen de le relancer.
    func resumePending(context: ModelContext) {
        let descriptor = FetchDescriptor<MusicTrack>()
        let pending = ((try? context.fetch(descriptor)) ?? []).filter {
            !$0.isAnalyzed && $0.analysisError == nil && !queue.contains($0)
        }
        guard !pending.isEmpty else { return }
        queue.append(contentsOf: pending)
        remainingCount = queue.count
        startWorkerIfNeeded(context: context)
    }

    /// Import d'UN fichier dont l'utilisateur attend le résultat (choix d'une
    /// musique depuis l'écran Montage). Analysé sur place, pas via la file :
    /// sinon le morceau était décodé deux fois en parallèle, une fois par le
    /// contrôleur et une fois par l'écran.
    func importAndAnalyze(url: URL, context: ModelContext) async throws -> MusicTrack {
        let filename = try MusicStore.importMusic(from: url)
        let track = MusicTrack()
        track.title = url.deletingPathExtension().lastPathComponent
        track.filename = filename
        track.fileSizeBytes = Int64(
            (try? MusicStore.url(forMusicFilename: filename)
                .resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        )
        context.insert(track)
        try? context.save()

        analyzing = track
        analyzingTitle = track.title
        remainingCount = queue.count + 1
        defer {
            analyzing = nil
            analyzingTitle = nil
            remainingCount = queue.count
        }
        await analyze(track, context: context)
        return track
    }

    // MARK: - Analyse

    private func startWorkerIfNeeded(context: ModelContext) {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.runQueue(context: context)
        }
    }

    private func runQueue(context: ModelContext) async {
        defer {
            worker = nil
            analyzingTitle = nil
            remainingCount = 0
        }
        while !queue.isEmpty {
            let track = queue.removeFirst()
            remainingCount = queue.count + 1
            // Supprimé entre-temps : ne pas ressusciter une entité morte.
            guard track.modelContext != nil else { continue }
            analyzing = track
            analyzingTitle = track.title
            await analyze(track, context: context)
            analyzing = nil
        }
    }

    private func analyze(_ track: MusicTrack, context: ModelContext) async {
        let url = track.url
        let filename = track.filename
        do {
            // Décodage + FFT hors acteur principal : plusieurs secondes de
            // calcul, l'interface doit rester vivante pendant ce temps.
            let map = try await Task.detached(priority: .utility) { () -> BeatMap? in
                let decoded = try await MusicDecoder.monoSamples(of: url)
                return BeatAnalyzer.analyze(samples: decoded.samples,
                                            sampleRate: decoded.sampleRate)
            }.value
            // Le morceau a pu être supprimé PENDANT le décodage : écrire
            // sur une entité détruite fait planter SwiftData, ou pire la
            // ressuscite alors que son fichier n'existe plus.
            guard track.modelContext != nil else { return }
            guard let map else {
                track.analysisError = "Aucune pulsation régulière détectée. "
                    + "Ce morceau n'a probablement pas de percussions marquées — le montage se cale dessus."
                track.isAnalyzed = false
                try? context.save()
                return
            }
            MusicStore.saveBeatMap(map, musicFilename: filename)
            track.bpm = map.bpm
            track.durationSeconds = map.duration
            track.isAnalyzed = true
            track.analysisError = nil
            try? context.save()
        } catch is CancellationError {
            // Abandon volontaire : le morceau reste à analyser.
        } catch {
            guard track.modelContext != nil else { return }
            track.analysisError = error.localizedDescription
            track.isAnalyzed = false
            try? context.save()
        }
    }

    // MARK: - Suppression

    /// Supprime un morceau ET son fichier. Les projets qui l'utilisaient
    /// perdent leur musique — c'est dit à l'appelant, qui prévient.
    func delete(_ track: MusicTrack, context: ModelContext) {
        queue.removeAll { $0 === track }
        // Analyse EN COURS sur ce morceau : l'arrêter avant de détruire
        // l'entité, sinon la suite du décodage écrit dans le vide.
        if analyzing === track {
            worker?.cancel()
            worker = nil
            analyzing = nil
            analyzingTitle = nil
        }
        remainingCount = queue.count

        // DÉTACHER les projets AVANT la suppression : sans cela ils gardaient
        // un nom de fichier mort et rejouaient l'échec à chaque ouverture du
        // montage, sans jamais dire quoi faire.
        let filename = track.filename
        for project in projectsUsing(track, context: context) {
            project.musicFilename = nil
            project.musicTitle = nil
            project.montageStartCentiseconds = nil
        }
        MusicStore.deleteMusic(filename: filename)
        context.delete(track)
        try? context.save()
    }

    // MARK: - Reprise des projets d'avant la bibliothèque

    /// Fait entrer dans la bibliothèque les musiques attachées aux projets
    /// existants — celles importées quand la musique appartenait au projet.
    ///
    /// Sans cette reprise, ces fichiers seraient inconnus de la bibliothèque :
    /// invisibles dans la liste (« importe une fois, réutilise partout »
    /// deviendrait faux pour tout l'existant) ET comptés comme orphelins dans
    /// l'écran Stockage, où un seul tap les aurait effacés alors qu'ils
    /// servent encore.
    static func adoptProjectMusic(context: ModelContext) {
        let projects = (try? context.fetch(FetchDescriptor<ClipProject>())) ?? []
        let known = Set(((try? context.fetch(FetchDescriptor<MusicTrack>())) ?? [])
            .map(\.filename))
        var adopted = Set<String>()

        for project in projects {
            guard let filename = project.musicFilename,
                  !known.contains(filename), !adopted.contains(filename) else { continue }
            let url = MusicStore.url(forMusicFilename: filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let track = MusicTrack()
            track.title = project.musicTitle ?? "Morceau importé"
            track.filename = filename
            track.fileSizeBytes = Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            )
            // Carte de rythme déjà en cache : le morceau arrive analysé,
            // sans refaire le calcul.
            if let cached = MusicStore.cachedBeatMap(musicFilename: filename) {
                track.bpm = cached.bpm
                track.durationSeconds = cached.duration
                track.isAnalyzed = true
            }
            context.insert(track)
            adopted.insert(filename)
        }
        if !adopted.isEmpty { try? context.save() }
    }

    /// Projets qui désignent ce morceau — pour prévenir avant suppression.
    func projectsUsing(_ track: MusicTrack, context: ModelContext) -> [ClipProject] {
        let filename = track.filename
        let descriptor = FetchDescriptor<ClipProject>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.musicFilename == filename }
    }
}
