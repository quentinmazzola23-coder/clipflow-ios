//
//  ImportController.swift
//  ClipFlow
//
//  Importation en service PARTAGÉ : la tâche survit à la navigation (quitter
//  l'éditeur pendant un import est sûr, la bannière réapparaît au retour).
//  Chaque rush est intégré et sauvegardé dès son arrivée ; doublons ignorés
//  (identifiant PhotoKit, ou taille+durée+dimensions quand l'identifiant
//  manque). Ordre = ordre de sélection dans le picker.
//

import Foundation
import SwiftUI
import SwiftData
import PhotosUI
import AudioToolbox
import UIKit

@MainActor
@Observable
final class ImportController {

    static let shared = ImportController()

    private(set) var progress: ImportProgress?
    private(set) var startedAt: Date?
    private(set) var lastErrors: [String] = []
    /// Incrémenté à chaque fin d'importation — déclencheur d'interface.
    private(set) var completionToken = 0

    private var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }

    private init() {}

    func cancel() {
        task?.cancel()
    }

    func start(items: [PhotosPickerItem], project: ClipProject, context: ModelContext) {
        guard task == nil, !items.isEmpty else { return }
        startedAt = .now
        lastErrors = []
        task = Task {
            var errors: [String] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                progress = ImportProgress(
                    completed: index, total: items.count,
                    currentName: "vidéo \(index + 1)", errors: errors
                )
                do {
                    let info = try await PhotoImporter.importSingle(item, pickOrder: index)
                    integrate(info, into: project, context: context)
                } catch is CancellationError {
                    break
                } catch {
                    errors.append("Vidéo \(index + 1) : \(error.localizedDescription)")
                }
            }
            progress = ImportProgress(
                completed: items.count, total: items.count,
                currentName: "", errors: errors
            )
            project.updatedAt = .now
            try? context.save()
            lastErrors = errors
            // Signal de fin : son système + haptique de succès.
            AudioServicesPlaySystemSound(1001)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            completionToken += 1
            progress = nil
            startedAt = nil
            task = nil
        }
    }

    /// Intègre un rush importé (dédupliqué). Persistance immédiate.
    private func integrate(_ info: ImportedRushInfo, into project: ClipProject, context: ModelContext) {
        // Doublon : identifiant PhotoKit, ou repli taille+durée+dimensions
        // quand le picker n'a pas fourni d'identifiant.
        let isDuplicate = project.rushes.contains { existing in
            if let id = info.assetIdentifier, let existingID = existing.assetIdentifier {
                return id == existingID
            }
            return existing.fileSizeBytes == info.fileSizeBytes
                && existing.fileSizeBytes > 0
                && existing.durationValue == info.duration.value
                && existing.durationTimescale == info.duration.timescale
                && existing.width == info.width
                && existing.height == info.height
        }
        if isDuplicate {
            try? FileManager.default.removeItem(
                at: StorageManager.url(forSourceRelativePath: info.localRelativePath)
            )
            return
        }

        let rush = Rush()
        rush.orderIndex = (project.rushes.map(\.orderIndex).max() ?? -1) + 1
        rush.assetIdentifier = info.assetIdentifier
        rush.originalFilename = info.originalFilename
        rush.captureDate = info.captureDate
        rush.fileCreationDate = info.fileCreationDate
        rush.pickOrder = info.pickOrder
        rush.durationValue = info.duration.value
        rush.durationTimescale = info.duration.timescale
        rush.width = info.width
        rush.height = info.height
        rush.nominalFrameRate = info.nominalFrameRate
        rush.codec = info.codec
        rush.rotationDegrees = info.rotationDegrees
        rush.colorimetry = info.colorimetry
        rush.is10Bit = info.is10Bit
        rush.fileSizeBytes = info.fileSizeBytes
        rush.localSourceRelativePath = info.localRelativePath
        rush.availability = .offlineReady
        rush.project = project
        context.insert(rush)
        try? context.save() // reprise possible après interruption
    }
}
