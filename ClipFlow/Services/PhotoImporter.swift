//
//  PhotoImporter.swift
//  ClipFlow
//
//  Importation depuis PhotosPicker :
//  - transfert par FICHIER (jamais de vidéo complète dans un Data) ;
//  - copie immédiate de l'URL temporaire vers un emplacement contrôlé ;
//  - extraction des métadonnées via AVAsset (asynchrone) ;
//  - progression individuelle et annulation par élément.
//

import Foundation
import SwiftUI
import PhotosUI
import AVFoundation
import Photos

/// Représentation fichier d'une vidéo issue de PhotosPicker.
/// `FileRepresentation` transfère un fichier sur disque — pas de chargement mémoire.
struct VideoFileTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { transfer in
            SentTransferredFile(transfer.url)
        } importing: { received in
            // L'URL reçue est temporaire : copie immédiate vers un emplacement
            // contrôlé par l'app. Nom unique pour éviter les collisions.
            let destination = StorageManager.sourcesDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            StorageManager.excludeFromBackup(destination)
            return VideoFileTransfer(url: destination)
        }
    }
}

/// Métadonnées extraites d'un rush importé.
struct ImportedRushInfo: Sendable {
    var assetIdentifier: String?
    var originalFilename: String
    var captureDate: Date?
    var fileCreationDate: Date?
    var pickOrder: Int
    var localRelativePath: String
    var duration: CMTime
    var width: Int
    var height: Int
    var nominalFrameRate: Double
    var codec: String
    var rotationDegrees: Int
    var colorimetry: String
    var is10Bit: Bool
    var fileSizeBytes: Int64
}

enum ImportError: Error, LocalizedError {
    case transferFailed(String)
    case noVideoTrack
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .transferFailed(let name):
            return "Transfert impossible pour « \(name) ». Si la vidéo est dans iCloud, ouvrez Photos pour la télécharger, puis réessayez."
        case .noVideoTrack:
            return "Aucune piste vidéo trouvée dans ce fichier."
        case .insufficientSpace:
            return "Espace disque insuffisant pour importer cette vidéo."
        }
    }
}

/// Progression d'importation, publiée élément par élément.
struct ImportProgress: Sendable {
    var completed: Int
    var total: Int
    var currentName: String
    var errors: [String]
}

final class PhotoImporter {

    /// Importe UN élément du picker. L'appelant intègre chaque rush au fur et à
    /// mesure : une interruption (appel, fermeture) ne perd que l'élément en
    /// cours, et la re-sélection est dédupliquée par identifiant PhotoKit.
    static func importSingle(_ item: PhotosPickerItem, pickOrder: Int) async throws -> ImportedRushInfo {
        let displayName = item.itemIdentifier ?? "vidéo \(pickOrder + 1)"
        guard let transfer = try await item.loadTransferable(type: VideoFileTransfer.self) else {
            throw ImportError.transferFailed(displayName)
        }
        var info = try await extractMetadata(from: transfer.url, pickOrder: pickOrder)
        info.assetIdentifier = item.itemIdentifier
        // Date de capture PHAsset si l'accès Photos en lecture est accordé.
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if let id = item.itemIdentifier, status == .authorized || status == .limited {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            if let asset = fetch.firstObject {
                info.captureDate = asset.creationDate
            }
        }
        return info
    }

    /// Extraction asynchrone des métadonnées — API `load(...)` moderne d'AVFoundation.
    static func extractMetadata(from url: URL, pickOrder: Int) async throws -> ImportedRushInfo {
        let asset = AVURLAsset(url: url)

        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        let (naturalSize, transform, frameRate, formatDescriptions) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions
        )

        // Date de création dans les métadonnées du conteneur.
        var creationDate: Date?
        if let item = try await asset.load(.creationDate) {
            creationDate = try await item.load(.dateValue)
        }

        // Codec + colorimétrie depuis la description de format.
        var codec = "inconnu"
        var colorimetry = "sdr"
        var is10Bit = false
        if let format = formatDescriptions.first {
            let fourCC = CMFormatDescriptionGetMediaSubType(format)
            codec = fourCCString(fourCC)
            let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
            if let transferKey = extensions?[kCVImageBufferTransferFunctionKey as String] as? String {
                if transferKey == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                    colorimetry = "hlg"
                } else if transferKey == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
                    colorimetry = "pq"
                } else {
                    colorimetry = "sdr"
                }
            }
            if codec.hasPrefix("hvc") || codec.hasPrefix("hev") {
                // Profil 10 bits détectable via les extensions de profil ; approximation
                // par la colorimétrie HDR — affiné sur appareil réel.
                is10Bit = (colorimetry != "sdr")
            }
        }

        // Rotation depuis preferredTransform.
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        let rotation = (Int(round(angle)) % 360 + 360) % 360

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let fsCreation = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate

        return ImportedRushInfo(
            assetIdentifier: nil,
            originalFilename: url.lastPathComponent,
            captureDate: nil,
            fileCreationDate: creationDate ?? fsCreation,
            pickOrder: pickOrder,
            localRelativePath: url.lastPathComponent,
            duration: duration,
            width: Int(abs(naturalSize.width)),
            height: Int(abs(naturalSize.height)),
            nominalFrameRate: Double(frameRate),
            codec: codec,
            rotationDegrees: rotation,
            colorimetry: colorimetry,
            is10Bit: is10Bit,
            fileSizeBytes: Int64(fileSize)
        )
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
