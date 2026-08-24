//
//  RenderQueue.swift
//  ClipFlow
//
//  File de rendu : UN passage à la fois (mémoire + température maîtrisées),
//  pause / annulation / reprise, relance d'un passage, protection anti-doublons,
//  état sauvegardé après chaque clip — un plantage n'oblige jamais à
//  recommencer les rendus déjà terminés.
//

import Foundation
import SwiftData
import CoreMedia
import AVFoundation
import Observation
import UIKit
import ActivityKit

/// Progression publiée vers l'interface.
struct RenderQueueSnapshot: Sendable {
    var totalJobs: Int = 0
    var finishedJobs: Int = 0
    var failedJobs: Int = 0
    /// Numéro (1-indexé) du clip en cours dans la file.
    var currentClipNumber: Int = 0
    var currentPassageName: String?
    var currentProgress: Double = 0
    var isPaused: Bool = false
    var isRunning: Bool = false
    var pauseReason: String?
    var lastResultSummary: String?
}

@MainActor
@Observable
final class RenderQueueController {

    private(set) var snapshot = RenderQueueSnapshot()

    /// Drapeau « la file tourne », PROPRIÉTÉ À PART de `snapshot`.
    ///
    /// Indispensable : `snapshot` change plusieurs fois par seconde (la
    /// progression). Toute vue qui lisait `snapshot.isRunning` — même pour
    /// un simple `onChange` — déclarait donc une dépendance d'observation sur
    /// la structure ENTIÈRE et se reconstruisait à chaque image rendue. C'est
    /// ce qui ramenait le défaut du menu ⋯ qui remonte en haut pendant un
    /// export, malgré l'isolation de la pastille de progression.
    /// Cette propriété-ci ne change que deux fois par export.
    private(set) var isRunningFlag = false
    private var container: ModelContainer?
    private var worker: Task<Void, Never>?
    private var pendingPassageIDs: [PersistentIdentifier] = [] {
        didSet { hasPendingFlag = !pendingPassageIDs.isEmpty }
    }

    /// « Des passages attendent d'être rendus », propriété SÉPARÉE et
    /// observable — comme `isRunningFlag`, pour que les vues consultent l'état
    /// de la file sans dépendre de la progression.
    ///
    /// Indispensable au garde de suppression : une file EN PAUSE a
    /// `isRunningFlag == false` mais des passages toujours en attente. Se fier
    /// au seul drapeau d'exécution laissait supprimer le projet, ce qui
    /// détruisait des `Passage` dont les identifiants restaient dans la file —
    /// accès à des entités SwiftData mortes à la reprise.
    private(set) var hasPendingFlag = false
    /// Passage retiré de la file mais ni fini ni échoué (rendu en cours) —
    /// sans lui, totalJobs sous-compte de 1 pendant chaque rendu.
    private var inFlightCount = 0
    private var userPaused = false
    /// Relances automatiques par passage (plafonnées à 3).
    private var retryCounts: [PersistentIdentifier: Int] = [:]
    /// Live Activity d'export (Dynamic Island + écran verrouillé).
    private var exportActivity: Activity<ExportActivityAttributes>?
    /// Dernière progression poussée vers la Live Activity (throttling).
    private var lastActivityProgress: Double = -1
    private var lastActivityClipNumber = 0

    static let shared = RenderQueueController()
    private init() {}

    func configure(container: ModelContainer) {
        let firstConfiguration = (self.container == nil)
        self.container = container
        // Reprise après crash : des passages peuvent rester figés en
        // .rendering/.queued (états fantômes, spinner éternel). Au premier
        // configure, hors file active, ils repassent en .notExported.
        if firstConfiguration, !snapshot.isRunning, pendingPassageIDs.isEmpty {
            let context = container.mainContext
            let renderingRaw = ExportState.rendering.rawValue
            let queuedRaw = ExportState.queued.rawValue
            let descriptor = FetchDescriptor<Passage>(
                predicate: #Predicate { $0.exportStateRaw == renderingRaw || $0.exportStateRaw == queuedRaw }
            )
            if let phantoms = try? context.fetch(descriptor), !phantoms.isEmpty {
                for passage in phantoms {
                    passage.exportState = .notExported
                }
                try? context.save()
            }
        }
    }

    /// Des passages du rush donné sont-ils en cours ou en attente de rendu ?
    /// (garde anti-course : suppression de fichier pendant une lecture).
    /// Retire de la file les passages d'un projet qu'on s'apprête à supprimer.
    /// Sans cela leurs identifiants survivaient à la suppression, et la
    /// reprise déréférençait des entités détruites.
    func forget(passageIDs: [PersistentIdentifier]) {
        guard !passageIDs.isEmpty else { return }
        let removed = Set(passageIDs)
        pendingPassageIDs.removeAll { removed.contains($0) }
        snapshot.totalJobs = max(0, snapshot.totalJobs - removed.count)
    }

    /// Vrai si un rendu clip-par-clip tourne ou attend.
    ///
    /// NE COUVRE PAS l'export du montage : voir `MediaAvailabilityService`
    /// pour le garde complet, à consulter avant toute suppression de fichier.
    func isBusy() -> Bool {
        snapshot.isRunning || !pendingPassageIDs.isEmpty
    }

    /// Ajoute les passages à la file (doublons ignorés : déjà en file ou déjà
    /// en cours). Un passage déjà exporté peut être relancé explicitement.
    func enqueue(passageIDs: [PersistentIdentifier]) {
        guard container != nil else { return }
        // Nouvelle session d'export (rien en cours, file vide) : les compteurs
        // de la session précédente ne s'additionnent pas à la nouvelle
        // (sinon « clip 6/8 » au premier clip du lot suivant).
        if !snapshot.isRunning, pendingPassageIDs.isEmpty, inFlightCount == 0 {
            snapshot.finishedJobs = 0
            snapshot.failedJobs = 0
            snapshot.lastResultSummary = nil
            retryCounts.removeAll()
        }
        for id in passageIDs where !pendingPassageIDs.contains(id) {
            pendingPassageIDs.append(id)
        }
        snapshot.totalJobs = snapshot.finishedJobs + snapshot.failedJobs
            + inFlightCount + pendingPassageIDs.count
        startIfNeeded()
    }

    func pause() {
        userPaused = true
        snapshot.isPaused = true
        snapshot.pauseReason = "Pause demandée."
    }

    func resume() {
        userPaused = false
        snapshot.isPaused = false
        snapshot.pauseReason = nil
        startIfNeeded()
    }

    func cancelAll() {
        // Les passages encore en file redeviennent .notExported — sinon ils
        // restent des fantômes .queued (horloge éternelle) que le nettoyage
        // de configure() ne rattrape qu'au prochain démarrage de l'app.
        if let container {
            let context = container.mainContext
            for id in pendingPassageIDs {
                if let passage = context.model(for: id) as? Passage,
                   passage.exportState == .queued || passage.exportState == .rendering {
                    passage.exportState = .notExported
                }
            }
            try? context.save()
        }
        pendingPassageIDs.removeAll()
        worker?.cancel()
        // PAS de worker = nil ici : seul le defer de runLoop() le fait, quand
        // le rendu en vol est réellement terminé — sinon un enqueue pendant le
        // drainage démarrerait un DEUXIÈME runLoop concurrent (deux rendus
        // entrelacés, course sur le cache moteur, même fichier de sortie).
        inFlightCount = 0
        snapshot = RenderQueueSnapshot()
        ThermalMonitor.shared.setRenderingActive(false)
        endActivity()
    }

    // MARK: - Live Activity (Dynamic Island / écran verrouillé)

    private var activityState: ExportActivityAttributes.ContentState {
        ExportActivityAttributes.ContentState(
            clipIndex: max(1, snapshot.currentClipNumber),
            totalClips: max(1, snapshot.totalJobs),
            progress: min(1, max(0, snapshot.currentProgress)),
            clipName: snapshot.currentPassageName ?? "Export…",
            failedClips: snapshot.failedJobs
        )
    }

    private func startActivityIfNeeded() {
        guard exportActivity == nil,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        exportActivity = try? Activity.request(
            attributes: ExportActivityAttributes(),
            content: .init(state: activityState, staleDate: nil)
        )
        lastActivityProgress = -1
        lastActivityClipNumber = 0
    }

    /// Pousse l'état si le clip a changé ou si la progression a avancé d'au
    /// moins 2 % — jamais de rafale d'updates.
    private func updateActivityThrottled(force: Bool = false) {
        guard let activity = exportActivity else { return }
        let clipChanged = snapshot.currentClipNumber != lastActivityClipNumber
        let progressed = abs(snapshot.currentProgress - lastActivityProgress) >= 0.02
        guard force || clipChanged || progressed else { return }
        lastActivityClipNumber = snapshot.currentClipNumber
        lastActivityProgress = snapshot.currentProgress
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endActivity() {
        guard let activity = exportActivity else { return }
        exportActivity = nil
        let content = ActivityContent(state: activityState, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    /// Un rendu est-il RÉELLEMENT en vol ? `worker != nil` ne suffit pas :
    /// `cancelAll` réinitialise le snapshot alors que la tâche vit encore.
    private var workerIsAlive = false

    private func startIfNeeded() {
        guard !workerIsAlive, !userPaused, !pendingPassageIDs.isEmpty else { return }
        workerIsAlive = true
        worker = Task { await runLoop() }
    }

    /// Relance manuelle : filet quand la file affiche des passages en attente
    /// sans rien traiter. Ne fait rien si un rendu tourne déjà.
    func restartIfIdle() {
        guard !workerIsAlive else { return }
        userPaused = false
        snapshot.isPaused = false
        snapshot.pauseReason = nil
        startIfNeeded()
    }

    /// La file a des passages en attente mais rien ne tourne — état anormal
    /// que l'interface doit rendre visible plutôt que d'afficher un « 0/N »
    /// figé sans explication.
    var isStalled: Bool {
        !workerIsAlive && !userPaused && !pendingPassageIDs.isEmpty
    }

    private func runLoop() async {
        // Sortie AVANT le defer : le drapeau doit être rendu ici, sinon la
        // file se croirait occupée à jamais.
        guard let container else {
            workerIsAlive = false
            worker = nil
            return
        }
        snapshot.isRunning = true
        isRunningFlag = true
        ThermalMonitor.shared.setRenderingActive(true)
        startActivityIfNeeded()
        defer {
            snapshot.isRunning = false
            isRunningFlag = false
            snapshot.currentPassageName = nil
            snapshot.currentClipNumber = 0
            ThermalMonitor.shared.setRenderingActive(false)
            worker = nil
            workerIsAlive = false
            endActivity()
            if pendingPassageIDs.isEmpty {
                // Rien à drainer : chaque passe de rendu ferme sa propre
                // session moteur (plus de cache entre clips).
            } else {
                // Des passages ont été (ré)ajoutés pendant le drainage d'une
                // annulation : relance immédiate (worker était encore non-nil,
                // startIfNeeded ne pouvait pas démarrer).
                startIfNeeded()
            }
        }

        while !pendingPassageIDs.isEmpty {
            if Task.isCancelled { return }
            if userPaused { return }

            // Politique thermique / batterie entre chaque passage.
            switch ThermalMonitor.shared.renderPolicy {
            case .pause(let reason):
                snapshot.pauseReason = reason
                // Attente passive puis nouvelle évaluation.
                try? await Task.sleep(for: .seconds(30))
                continue
            case .throttle:
                snapshot.pauseReason = "Température élevée — cadence réduite."
                try? await Task.sleep(for: .seconds(10))
            case .proceed:
                snapshot.pauseReason = nil
            }

            let passageID = pendingPassageIDs.removeFirst()
            // Compté « en vol » jusqu'à la fin de l'itération (succès, échec,
            // relance ou annulation) — sinon totalJobs sous-compte de 1.
            inFlightCount = 1
            defer { inFlightCount = 0 }
            let context = container.mainContext

            guard let passage = context.model(for: passageID) as? Passage,
                  let project = passage.project else {
                snapshot.failedJobs += 1
                continue
            }

            // Préparation du job sur le MainActor (lecture SwiftData), rendu hors MainActor.
            guard let source = MediaAvailabilityService.exportSource(for: passage) else {
                passage.exportState = .failed
                passage.lastExportError = "Source indisponible hors ligne (ni plage cachée, ni copie locale)."
                snapshot.failedJobs += 1
                try? context.save()
                continue
            }

            // Nom d'export : numéro d'ordre + catégories.
            let existing = Set(project.visiblePassages.compactMap(\.exportedFilename))
            let categoryValues = passage.categories.map { entry in
                entry.split(separator: ":").last.map(String.init) ?? entry
            }
            let filename = NamingEngine.makeName(
                orderNumber: project.nextExportNumber,
                categories: categoryValues,
                originalName: passage.rush?.originalFilename,
                existingNames: existing
            )

            // SOURCE À CADENCE BASSE : le flux optique s'applique MÊME si le
            // réglage global l'éteint.
            //
            // Un tel clip n'est plus ralenti (RationalSpeed.effective) : deux
            // images vraies y sont séparées d'1/30 s et il n'en manque qu'une
            // sur deux pour atteindre 60 i/s. C'est le régime FACILE de
            // l'interpolation — exactement celui d'une source 60 i/s ralentie
            // de moitié. Le réglage global, lui, a été éteint pour le régime
            // DIFFICILE : 1/15 s entre deux images vraies, trois images sur
            // quatre à fabriquer, sur du mouvement rapide. Le plafond de
            // vitesse rend ce régime impossible, donc la raison d'éteindre ne
            // s'applique plus ici.
            //
            // Sans cela, un montage mêlant du 30 et du 60 i/s montre deux
            // rendus de mouvement différents d'un clip à l'autre.
            //
            // La condition « à vitesse réelle » n'est PAS décorative : les
            // clips validés AVANT le plafond gardent une vitesse ralentie
            // enregistrée. Leur appliquer le flux les mettrait précisément
            // dans le régime difficile qu'on cherche à éviter — et ils y
            // seraient passés en silence, alors qu'ils fonctionnaient jusque-là
            // par duplication. On ne change pas le rendu d'un travail déjà fait.
            let atRealSpeed = passage.speedNumerator >= passage.speedDenominator
            let lowFrameRateSource = passage.sourceNominalFrameRate > 1
                && passage.sourceNominalFrameRate <= RationalSpeed.slowMotionFloor
                && atRealSpeed
            let interpolates = project.opticalFlowEnabled || lowFrameRateSource

            let job = RenderJob(
                sourceURL: source.url,
                sourceRange: source.rangeInFile,
                finalDuration: ExactDuration(centiseconds: passage.finalDurationCentiseconds),
                speed: RationalSpeed(numerator: passage.speedNumerator, denominator: passage.speedDenominator),
                fps: project.exportFPS,
                codec: project.exportCodec,
                outputFilename: filename,
                // Colorimétrie figée sur le passage à la validation — jamais
                // "sdr" par défaut quand le rush a été supprimé.
                colorimetry: passage.colorimetry,
                // Flux optique DÉSACTIVÉ par défaut (réglage du projet) : sans
                // lui, chaque image du ralenti est une VRAIE image du rush,
                // répétée. Mouvement plus saccadé, mais aucun pixel inventé —
                // donc aucun artefact possible.
                forceFastEngine: !interpolates
            )

            passage.exportState = .rendering
            snapshot.currentPassageName = filename
            snapshot.currentProgress = 0
            snapshot.currentClipNumber = snapshot.finishedJobs + snapshot.failedJobs + 1
            updateActivityThrottled(force: true)
            try? context.save() // état persistant AVANT le rendu

            // Tâche de fond système : si l'écran se verrouille pendant le
            // rendu, iOS accorde ~30 s — assez pour TERMINER le clip en cours
            // (pas pour enchaîner ; le reste reprend à la réouverture).
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClipFlow.Render") {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }

            do {
                let result = try await VideoRenderPipeline.render(job: job) { progress in
                    Task { @MainActor in
                        RenderQueueController.shared.snapshot.currentProgress = progress
                        RenderQueueController.shared.updateActivityThrottled()
                    }
                }
                // FORMAT DE SORTIE ET RECADRAGE, comme au montage.
                //
                // Sans cette étape, on réglait un cadrage, on le voyait sur
                // l'aperçu, et le clip déposé dans Photos sortait au format de
                // la caméra — deux chemins de sortie qui ne racontaient pas la
                // même chose. Elle ne fait rien quand le rapport colle déjà et
                // que le cadrage est au centre, ce qui est le cas courant.
                var exportURL = result.outputURL
                // Dimensions et poids RÉELLEMENT livrés, quand le recadrage a
                // eu lieu : le bilan décrivait sinon le fichier intermédiaire,
                // que personne ne verra jamais.
                var deliveredWidth = result.width
                var deliveredHeight = result.height
                var deliveredBytes = result.fileSizeBytes
                if let framed = try? await ClipReframer.reframe(
                    source: result.outputURL,
                    outputFormat: project.outputFormat,
                    cropToFill: project.cropToFillOutput,
                    cropCenter: passage.cropCenter,
                    colorimetry: passage.colorimetry
                ) {
                    try? FileManager.default.removeItem(at: result.outputURL)
                    exportURL = framed
                    let framedAsset = AVURLAsset(url: framed)
                    if let track = try? await framedAsset.loadTracks(withMediaType: .video).first,
                       let natural = try? await track.load(.naturalSize),
                       let transform = try? await track.load(.preferredTransform) {
                        let oriented = natural.applying(transform)
                        deliveredWidth = Int(abs(oriented.width).rounded())
                        deliveredHeight = Int(abs(oriented.height).rounded())
                    }
                    deliveredBytes = Int64(
                        (try? framed.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    )
                }
                // Album par projet (réglage global) : sinon album commun.
                let assetID = try await PhotoExportService.saveToPhotos(
                    fileURL: exportURL,
                    projectName: project.albumPerProject ? project.name : nil
                )

                passage.exportState = .exported
                passage.exportedFilename = filename
                passage.exportedAssetIdentifier = assetID
                passage.lastExportError = nil
                project.nextExportNumber += 1
                snapshot.finishedJobs += 1
                var corrected = result.correctedFrames > 0
                    ? ", \(result.correctedFrames) image(s) anti-flash" : ""
                if result.maxLumaDeviation > 0 {
                    corrected += String(format: " (dev max %.0f)", result.maxLumaDeviation)
                }
                if result.failsafeOverrides > 0 {
                    corrected += ", \(result.failsafeOverrides) rejet(s) neutralisé(s) par le disjoncteur"
                }
                // Les images répétées sont le PRINCIPE du rendu sans
                // interpolation : les signaler serait un faux avertissement.
                // Elles ne sont anormales que si le clip livré a réellement
                // été interpolé (elles trahissent alors un clip figé) — donc
                // ni quand le flux optique est éteint, NI après un repli.
                // Un rendu HDR n'interpole jamais : compter ses images
                // répétées comme suspectes serait un faux avertissement, au
                // même titre qu'après un repli.
                let interpolationDelivered = interpolates
                    && !result.opticalFlowRejected
                    && !result.opticalFlowSkippedForHDR
                if result.duplicatePairs > 0, interpolationDelivered {
                    corrected += ", ⚠️ \(result.duplicatePairs) paire(s) d'images identiques"
                }
                // PLAGE DYNAMIQUE CONSERVÉE : l'export HDR est la raison
                // d'être du chemin 10 bits, il doit se constater sur le bilan
                // et pas seulement à l'œil sur le clip livré.
                if result.exportedColorimetry != "sdr" {
                    corrected += ", HDR conservé (\(result.exportedColorimetry.uppercased()), "
                        + "BT.2020 10 bits)"
                }
                if result.opticalFlowSkippedForHDR {
                    corrected += ", flux optique non appliqué sur ce clip HDR "
                        + "(moteur non validé en 10 bits BT.2020)"
                }
                // REJET DU FLUX OPTIQUE : donnée décisive pour savoir si ce
                // moteur mérite d'être rallumé — elle doit être VISIBLE.
                if result.opticalFlowRejected {
                    corrected += ", ⛔️ flux optique écarté sur ce clip "
                        + "(\(result.rejectedArtifactFrames) image(s) aberrante(s)) — "
                        + "rendu sans interpolation"
                }
                if result.untaggedInterpolatedFrames > 0 {
                    corrected += ", ⛔️ \(result.untaggedInterpolatedFrames) image(s) sans "
                        + "attachement colorimétrique (étiquetées d'après le profil de rendu)"
                }
                // Jamais « contrôle OK » quand des images aberrantes sont
                // livrées. Mais sans interpolation, aucun pixel n'est
                // inventé : ce qui reste vient de la SOURCE, et l'annoncer
                // comme un artefact serait mensonger dans l'autre sens.
                let measurement = String(format: " (écart max %.0f sur %d tuile(s))",
                                         result.maxOutputAnomaly, result.maxDeviatingTiles)
                if result.artifactFrames.isEmpty {
                    corrected += ", contrôle image par image OK" + measurement
                } else {
                    let indices = result.artifactFrames.prefix(8).map(String.init).joined(separator: ", ")
                    corrected += interpolationDelivered
                        ? ", ⚠️ image(s) aberrante(s) LIVRÉE(S) aux indices \(indices)" + measurement
                        : ", variation forte aux indices \(indices) — contenu source, rien d'inventé"
                            + measurement
                }
                if result.uncheckedInterpolatedFrames > 0 {
                    corrected += ", \(result.uncheckedInterpolatedFrames) non contrôlée(s)"
                }
                if result.discardedDecodedFrames > 0 {
                    corrected += ", \(result.discardedDecodedFrames) écartée(s) au décodage"
                }
                corrected += ", cadence source \(result.sourceIntervalInfo)"
                snapshot.lastResultSummary = String(
                    format: "%@ — %.2f s, %d images, %@, %d×%d, %@, moteur : %@%@, rendu en %.0f s",
                    filename, result.durationSeconds, result.frameCount,
                    result.codec.uppercased(), deliveredWidth, deliveredHeight,
                    StorageManager.formatBytes(deliveredBytes),
                    result.engineName, corrected, result.processingSeconds
                )
            } catch is CancellationError {
                // Annulation via « Tout annuler » : la file est vidée, personne
                // ne re-référencera ce passage — .queued serait un fantôme
                // (horloge éternelle). Cohérent avec le nettoyage de configure().
                passage.exportState = .notExported
                try? context.save()
                return
            } catch {
                // Relance automatique (option, activée par défaut) : jusqu'à
                // 3 tentatives par passage avant échec définitif.
                let autoRetry = (UserDefaults.standard.object(forKey: "autoRetryFailedExports") as? Bool) ?? true
                let attempts = retryCounts[passageID, default: 0]
                if autoRetry, attempts < 3 {
                    retryCounts[passageID] = attempts + 1
                    passage.exportState = .queued
                    passage.lastExportError = "Relance \(attempts + 1)/3 — \(error.localizedDescription)"
                    pendingPassageIDs.append(passageID)
                } else {
                    passage.exportState = .failed
                    passage.lastExportError = error.localizedDescription
                    snapshot.failedJobs += 1
                }
            }
            try? context.save() // état persistant APRÈS chaque clip
        }
    }
}
