//
//  StorageManager.swift
//  ClipFlow
//
//  Organisation du stockage :
//  - Application Support : base SwiftData + copies sources persistantes ;
//  - Caches : proxys régénérables ;
//  - Temporary/Exports : rendus provisoires ;
//  - fichiers vidéo volumineux exclus des sauvegardes iCloud de l'app.
//

import Foundation

enum StorageManager {

    // MARK: - Répertoires

    static var applicationSupportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies sources persistantes (mode hors-ligne garanti + plages cachées).
    static var sourcesDirectory: URL {
        subdirectory(of: applicationSupportDirectory, named: "Sources")
    }

    /// Plages sources pleine qualité mises en cache après validation d'un passage.
    static var cachedRangesDirectory: URL {
        subdirectory(of: applicationSupportDirectory, named: "CachedRanges")
    }

    /// Proxys régénérables — Caches (le système peut purger, l'app sait régénérer).
    static var proxiesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return subdirectory(of: caches, named: "Proxies")
    }

    /// Rendus provisoires avant enregistrement dans Photos.
    static var exportsDirectory: URL {
        let tmp = FileManager.default.temporaryDirectory
        return subdirectory(of: tmp, named: "Exports")
    }

    private static func subdirectory(of parent: URL, named name: String) -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Exclusion des sauvegardes iCloud

    /// À appliquer à tout fichier vidéo volumineux stocké dans Application Support.
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Espace disque

    /// Octets réellement disponibles pour un usage important.
    static func availableCapacity() -> Int64 {
        let url = applicationSupportDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Refuse une importation si l'espace restant après copie passerait sous 2 Go.
    static func canAccommodate(bytes: Int64) -> Bool {
        let margin: Int64 = 2_000_000_000
        return availableCapacity() - bytes > margin
    }

    // MARK: - Mesure et nettoyage

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    static func proxiesSize() -> Int64 { directorySize(proxiesDirectory) }
    static func cachedRangesSize() -> Int64 { directorySize(cachedRangesDirectory) }
    static func sourcesSize() -> Int64 { directorySize(sourcesDirectory) }
    static func exportsSize() -> Int64 { directorySize(exportsDirectory) }

    static func clearProxies() { clearDirectory(proxiesDirectory) }
    static func clearCachedRanges() { clearDirectory(cachedRangesDirectory) }
    static func clearExports() { clearDirectory(exportsDirectory) }

    private static func clearDirectory(_ url: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Résolution de chemins relatifs

    static func url(forSourceRelativePath path: String) -> URL {
        sourcesDirectory.appendingPathComponent(path)
    }

    static func url(forProxyRelativePath path: String) -> URL {
        proxiesDirectory.appendingPathComponent(path)
    }

    static func url(forCachedRangeRelativePath path: String) -> URL {
        cachedRangesDirectory.appendingPathComponent(path)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
