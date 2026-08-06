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
        // Sans copie locale : les passages validés restent exportables hors ligne
        // uniquement si leur plage source est cachée (vérifié passage par passage).
        return .unavailable
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
