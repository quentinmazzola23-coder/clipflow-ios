//
//  PhotoExportService.swift
//  ClipFlow
//
//  Enregistrement des rendus dans Photos via PhotoKit, dans un album PAR
//  PROJET : « ClipFlow — <nom du projet> » (visible dans Pellicule → Albums,
//  synchronisé iCloud Photos). Sans cela, tous les clips de tous les projets
//  s'entassaient dans un album unique.
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

    /// Préfixe commun : tous les albums de l'app restent groupés
    /// alphabétiquement dans Photos.
    static let albumPrefix = "ClipFlow"

    /// Nom d'album pour un projet. Un nom vide, ou réduit à des espaces,
    /// retombe sur l'album générique plutôt que de produire « ClipFlow —  ».
    /// Les caractères de contrôle et retours à la ligne sont retirés (Photos
    /// accepte des titres arbitraires, mais ils deviennent illisibles).
    static func albumTitle(forProjectNamed name: String) -> String {
        let cleaned = name
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return albumPrefix }
        // Titre borné : au-delà, Photos tronque à l'affichage de toute façon.
        let limited = cleaned.count > 60 ? String(cleaned.prefix(60)) : cleaned
        return "\(albumPrefix) — \(limited)"
    }

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

    /// Album de ce titre s'il existe, sinon création.
    private static func ensureAlbum(titled title: String) async throws -> PHAssetCollection {
        let fetch = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular,
            options: {
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "title = %@", title)
                return options
            }()
        )
        if let existing = fetch.firstObject { return existing }

        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID,
              let created = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [placeholderID], options: nil
              ).firstObject else {
            throw PhotoExportError.saveFailed("création de l'album « \(title) » impossible")
        }
        return created
    }

    /// Enregistre la vidéo dans Photos + album DU PROJET, supprime le fichier
    /// temporaire après confirmation. Retourne l'identifiant local de l'asset.
    /// `projectName` absent → album générique « ClipFlow ».
    @discardableResult
    static func saveToPhotos(fileURL: URL, projectName: String? = nil) async throws -> String? {
        try await ensureAuthorization()
        let title = projectName.map { albumTitle(forProjectNamed: $0) } ?? albumPrefix
        let album = try await ensureAlbum(titled: title)

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
