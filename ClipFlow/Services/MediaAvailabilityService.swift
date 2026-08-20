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

    /// GARDE UNIQUE avant toute suppression de fichier média.
    ///
    /// Il existe DEUX producteurs qui lisent des fichiers pendant des minutes :
    /// la file d'export clip-par-clip et l'export du montage. Chaque garde
    /// écrit à la main n'en consultait qu'un — d'où des suppressions qui
    /// arrachaient les sources sous une session d'export en cours, avec un
    /// échec invisible à l'arrivée. Tout garde passe désormais par ici.
    ///
    /// Retourne nil si l'opération est sûre, sinon la raison à afficher.
    @MainActor
    static func blockingReason() -> String? {
        if RenderQueueController.shared.isBusy() {
            return "Export de clips en cours — cette action supprimerait des fichiers en cours de lecture. Réessayez une fois la file terminée."
        }
        if MontageExportController.shared.isExporting {
            let name = MontageExportController.shared.projectName.map { " (\($0))" } ?? ""
            return "Export du montage en cours\(name) — cette action supprimerait des fichiers en cours de lecture. Réessayez une fois l'export terminé."
        }
        return nil
    }


    /// Réévalue la disponibilité d'un rush d'après l'état du disque.
    /// (Plus de proxys : la copie source locale est l'unique média de lecture.)
    static func evaluate(rush: Rush) -> RushAvailability {
        let hasLocalSource = rush.localSourceRelativePath.map {
            FileManager.default.fileExists(atPath: StorageManager.url(forSourceRelativePath: $0).path)
        } ?? false

        if hasLocalSource {
            return .offlineReady
        }
        // Source libérée : plus de lecture possible, mais les passages restent
        // exportables si leurs plages sont cachées.
        let allCached = !rush.passages.isEmpty && rush.passages.allSatisfy { passage in
            guard let cached = passage.cachedRangeRelativePath else { return false }
            return FileManager.default.fileExists(
                atPath: StorageManager.url(forCachedRangeRelativePath: cached).path
            )
        }
        return allCached ? .sourceReleased : .unavailable
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
