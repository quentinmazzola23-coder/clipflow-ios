//
//  PhotoExportService.swift
//  ClipFlow
//
//  Enregistrement des rendus dans Photos via PhotoKit, en autorisation
//  « ajout seul » (.addOnly) — le minimum nécessaire.
//  Le fichier temporaire n'est supprimé qu'APRÈS confirmation de Photos.
//

import Foundation
import Photos

enum PhotoExportError: Error, LocalizedError {
    case authorizationDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Autorisation d'ajout à Photos refusée. Activez-la dans Réglages → ClipFlow."
        case .saveFailed(let details):
            return "Enregistrement dans Photos impossible : \(details)"
        }
    }
}

enum PhotoExportService {

    /// Demande (si nécessaire) l'autorisation d'AJOUT seul.
    static func ensureAddAuthorization() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw PhotoExportError.authorizationDenied
            }
        default:
            throw PhotoExportError.authorizationDenied
        }
    }

    /// Enregistre la vidéo dans Photos puis supprime le fichier temporaire.
    /// Retourne l'identifiant local du nouvel asset si disponible.
    @discardableResult
    static func saveToPhotos(fileURL: URL) async throws -> String? {
        try await ensureAddAuthorization()

        var placeholderIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Ne PAS déplacer le fichier : suppression manuelle après confirmation.
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: fileURL, options: options)
                placeholderIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PhotoExportError.saveFailed(error.localizedDescription)
        }

        // Confirmation obtenue — suppression du fichier temporaire.
        try? FileManager.default.removeItem(at: fileURL)
        return placeholderIdentifier
    }
}
