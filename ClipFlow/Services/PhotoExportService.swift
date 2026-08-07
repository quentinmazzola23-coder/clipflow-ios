//
//  PhotoExportService.swift
//  ClipFlow
//
//  Enregistrement des rendus dans Photos via PhotoKit, dans un album dédié
//  « ClipFlow » (visible dans Pellicule → Albums, synchronisé iCloud Photos).
//  La création/recherche d'album exige l'autorisation complète (.readWrite).
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
            return "Autorisation Photos refusée. Activez l'accès complet dans Réglages → ClipFlow → Photos (nécessaire pour l'album ClipFlow)."
        case .saveFailed(let details):
            return "Enregistrement dans Photos impossible : \(details)"
        }
    }
}

enum PhotoExportService {

    static let albumTitle = "ClipFlow"

    /// Demande (si nécessaire) l'autorisation complète — requise pour l'album.
    static func ensureAuthorization() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard granted == .authorized || granted == .limited else {
                throw PhotoExportError.authorizationDenied
            }
        default:
            throw PhotoExportError.authorizationDenied
        }
    }

    /// Album « ClipFlow » existant, sinon création.
    private static func ensureAlbum() async throws -> PHAssetCollection {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular,
            options: {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "title = %@", albumTitle)
                return options
            }()
        )
        if let existing = fetch.firstObject { return existing }

        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID,
              let created = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [placeholderID], options: nil
              ).firstObject else {
            throw PhotoExportError.saveFailed("création de l'album ClipFlow impossible")
        }
        return created
    }

    /// Enregistre la vidéo dans Photos + album ClipFlow, supprime le fichier
    /// temporaire après confirmation. Retourne l'identifiant local de l'asset.
    @discardableResult
    static func saveToPhotos(fileURL: URL) async throws -> String? {
        try await ensureAuthorization()
        let album = try await ensureAlbum()

        var assetIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Ne PAS déplacer le fichier : suppression manuelle après confirmation.
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: fileURL, options: options)
                if let placeholder = request.placeholderForCreatedAsset,
                   let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                    albumRequest.addAssets([placeholder] as NSArray)
                    assetIdentifier = placeholder.localIdentifier
                }
            }
        } catch {
            throw PhotoExportError.saveFailed(error.localizedDescription)
        }

        // Confirmation obtenue — suppression du fichier temporaire.
        try? FileManager.default.removeItem(at: fileURL)
        return assetIdentifier
    }
}
