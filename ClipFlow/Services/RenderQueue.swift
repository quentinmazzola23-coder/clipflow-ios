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
    private var container: ModelContainer?
    private var worker: Task<Void, Never>?
    private var pendingPassageIDs: [PersistentIdentifier] = []
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

    private func startIfNeeded() {
        guard worker == nil, !userPaused, !pendingPassageIDs.isEmpty else { return }
        worker = Task { await runLoop() }
    }

    private func runLoop() async {
        guard let container else { return }
        snapshot.isRunning = true
        ThermalMonitor.shared.setRenderingActive(true)
        startActivityIfNeeded()
        defer {
            snapshot.isRunning = false
            snapshot.currentPassageName = nil
            snapshot.currentClipNumber = 0
            ThermalMonitor.shared.setRenderingActive(false)
            worker = nil
            endActivity()
            if pendingPassageIDs.isEmpty {
                // File vide : libère la session moteur conservée entre les clips.
                VideoRenderPipeline.drainCachedEngine()
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
            let existing = Set(project.passages.compactMap(\.exportedFilename))
            let categoryValues = passage.categories.map { entry in
                entry.split(separator: ":").last.map(String.init) ?? entry
            }
            let filename = NamingEngine.makeName(
                orderNumber: project.nextExportNumber,
                categories: categoryValues,
                originalName: passage.rush?.originalFilename,
                existingNames: existing
            )

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
                colorimetry: passage.colorimetry
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
                let assetID = try await PhotoExportService.saveToPhotos(fileURL: result.outputURL)

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
                if result.duplicatePairs > 0 {
                    corrected += ", ⚠️ \(result.duplicatePairs) paire(s) d'images identiques"
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
                    result.codec.uppercased(), result.width, result.height,
                    StorageManager.formatBytes(result.fileSizeBytes),
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
