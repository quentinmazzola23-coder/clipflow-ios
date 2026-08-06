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

/// Progression publiée vers l'interface.
struct RenderQueueSnapshot: Sendable {
    var totalJobs: Int = 0
    var finishedJobs: Int = 0
    var failedJobs: Int = 0
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
    private var userPaused = false

    static let shared = RenderQueueController()
    private init() {}

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Ajoute les passages à la file (doublons ignorés : déjà en file ou déjà
    /// en cours). Un passage déjà exporté peut être relancé explicitement.
    func enqueue(passageIDs: [PersistentIdentifier]) {
        guard container != nil else { return }
        for id in passageIDs where !pendingPassageIDs.contains(id) {
            pendingPassageIDs.append(id)
        }
        snapshot.totalJobs = snapshot.finishedJobs + snapshot.failedJobs + pendingPassageIDs.count
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
        pendingPassageIDs.removeAll()
        worker?.cancel()
        worker = nil
        snapshot = RenderQueueSnapshot()
        ThermalMonitor.shared.setRenderingActive(false)
    }

    private func startIfNeeded() {
        guard worker == nil, !userPaused, !pendingPassageIDs.isEmpty else { return }
        worker = Task { await runLoop() }
    }

    private func runLoop() async {
        guard let container else { return }
        snapshot.isRunning = true
        ThermalMonitor.shared.setRenderingActive(true)
        defer {
            snapshot.isRunning = false
            snapshot.currentPassageName = nil
            ThermalMonitor.shared.setRenderingActive(false)
            worker = nil
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
                colorimetry: passage.rush?.colorimetry ?? "sdr"
            )

            passage.exportState = .rendering
            snapshot.currentPassageName = filename
            snapshot.currentProgress = 0
            try? context.save() // état persistant AVANT le rendu

            do {
                let result = try await VideoRenderPipeline.render(job: job) { progress in
                    Task { @MainActor in
                        RenderQueueController.shared.snapshot.currentProgress = progress
                    }
                }
                try await PhotoExportService.saveToPhotos(fileURL: result.outputURL)

                passage.exportState = .exported
                passage.exportedFilename = filename
                passage.lastExportError = nil
                project.nextExportNumber += 1
                snapshot.finishedJobs += 1
                snapshot.lastResultSummary = String(
                    format: "%@ — %.2f s, %d images, %@, %d×%d, %@, moteur : %@, rendu en %.0f s",
                    filename, result.durationSeconds, result.frameCount,
                    result.codec.uppercased(), result.width, result.height,
                    StorageManager.formatBytes(result.fileSizeBytes),
                    result.engineName, result.processingSeconds
                )
            } catch is CancellationError {
                passage.exportState = .queued
                try? context.save()
                return
            } catch {
                passage.exportState = .failed
                passage.lastExportError = error.localizedDescription
                snapshot.failedJobs += 1
            }
            try? context.save() // état persistant APRÈS chaque clip
        }
    }
}
