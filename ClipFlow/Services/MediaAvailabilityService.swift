//
//  MediaAvailabilityService.swift
//  ClipFlow
//
//  Détermine l'état de disponibilité de chaque rush. L'app elle-même n'utilise
//  JAMAIS le réseau : seul le sélecteur système Photos peut déclencher un
//  téléchargement iCloud lors de la sélection.
//

import Foundation
import AVFoundation

enum MediaAvailabilityService {

    /// Réévalue la disponibilité d'un rush d'après l'état du disque.
    static func evaluate(rush: Rush) -> RushAvailability {
        let hasLocalSource = rush.localSourceRelativePath.map {
            FileManager.default.fileExists(atPath: StorageManager.url(forSourceRelativePath: $0).path)
        } ?? false

        let hasProxy = rush.proxyRelativePath.map {
            FileManager.default.fileExists(atPath: StorageManager.url(forProxyRelativePath: $0).path)
        } ?? false

        if hasLocalSource && hasProxy {
            return .offlineReady
        }
        if hasLocalSource {
            return .localReady
        }
        if hasProxy {
            // Source libérée volontairement : navigation via proxy, exports via
            // les plages cachées des passages existants.
            return .sourceReleased
        }
        return .unavailable
    }

    // MARK: - Libération d'espace

    /// Rushes dont la copie source peut être libérée sans rien perdre :
    /// au moins un passage, et Tous les passages ont leur plage cachée sur disque.
    static func releasableSources(in project: ClipProject) -> [(rush: Rush, url: URL, bytes: Int64)] {
        project.rushes.compactMap { rush in
            guard let path = rush.localSourceRelativePath else { return nil }
            let url = StorageManager.url(forSourceRelativePath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard !rush.passages.isEmpty else { return nil }
            let allCached = rush.passages.allSatisfy { passage in
                guard let cached = passage.cachedRangeRelativePath else { return false }
                return FileManager.default.fileExists(
                    atPath: StorageManager.url(forCachedRangeRelativePath: cached).path
                )
            }
            guard allCached else { return nil }
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return (rush, url, bytes)
        }
    }

    /// Supprime les copies sources libérables. Retourne les octets récupérés.
    /// Ne touche JAMAIS aux originaux dans Photos ni aux plages cachées.
    @discardableResult
    static func releaseSources(in project: ClipProject) -> Int64 {
        var freed: Int64 = 0
        for entry in releasableSources(in: project) {
            do {
                try FileManager.default.removeItem(at: entry.url)
                entry.rush.localSourceRelativePath = nil
                entry.rush.availability = evaluate(rush: entry.rush)
                freed += entry.bytes
            } catch {
                // Fichier verrouillé ? On passe — retentable depuis le menu.
            }
        }
        return freed
    }

    /// Un passage est-il prêt pour un export hors ligne ?
    /// Vrai si sa plage pleine qualité est cachée, ou si la source complète est locale.
    static func isPassageExportReady(_ passage: Passage) -> Bool {
        if let cached = passage.cachedRangeRelativePath,
           FileManager.default.fileExists(atPath: StorageManager.url(forCachedRangeRelativePath: cached).path) {
            return true
        }
        if let rush = passage.rush, let source = rush.localSourceRelativePath,
           FileManager.default.fileExists(atPath: StorageManager.url(forSourceRelativePath: source).path) {
            return true
        }
        return false
    }

    /// Source pleine qualité pour l'export : URL du fichier + plage de la
    /// sélection EXPRIMÉE DANS LA BASE DE TEMPS DE CE FICHIER.
    /// Priorité : plage cachée dédiée, puis copie source complète.
    struct ExportSource {
        var url: URL
        var rangeInFile: CMTimeRange
    }

    static func exportSource(for passage: Passage) -> ExportSource? {
        if let cached = passage.cachedRangeRelativePath {
            let url = StorageManager.url(forCachedRangeRelativePath: cached)
            if FileManager.default.fileExists(atPath: url.path) {
                // Le zéro du fichier caché correspond à cachedRangeOffset dans le rush.
                let rebasedStart = CMTimeSubtract(passage.start, passage.cachedRangeOffset)
                return ExportSource(
                    url: url,
                    rangeInFile: CMTimeRange(start: rebasedStart, duration: passage.sourceDuration)
                )
            }
        }
        if let rush = passage.rush, let source = rush.localSourceRelativePath {
            let url = StorageManager.url(forSourceRelativePath: source)
            if FileManager.default.fileExists(atPath: url.path) {
                return ExportSource(url: url, rangeInFile: passage.sourceRange)
            }
        }
        return nil
    }

    /// La plage cachée contient la sélection avec marge : son temps zéro
    /// correspond à `cacheStart` dans le rush original.
    /// Marge par défaut : 12 images à la cadence native (min 0,2 s).
    static func cacheMargin(for rush: Rush) -> CMTime {
        let fps = rush.nominalFrameRate > 1 ? rush.nominalFrameRate : 30
        let margin = max(12.0 / fps, 0.2)
        return CMTime(seconds: margin, preferredTimescale: 600)
    }
}
