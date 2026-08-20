//
//  MusicStore.swift
//  ClipFlow
//
//  Stockage de la musique d'un projet et cache des cartes de rythme.
//
//  La musique vit dans Application Support (comme les sources copiées) : elle
//  fait partie du projet, elle ne doit pas être purgée par le système. La
//  carte de rythme vit dans Caches : recalculable en quelques secondes.
//

import Foundation

enum MusicStore {

    static var musicDirectory: URL {
        let url = StorageManager.applicationSupportDirectory
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var beatMapsDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("BeatMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copie un fichier choisi dans Files vers le stockage du projet.
    /// L'URL du sélecteur est à PORTÉE DE SÉCURITÉ : la copie se fait dans la
    /// fenêtre start/stopAccessing — après, le fichier nous appartient.
    static func importMusic(from pickedURL: URL) throws -> String {
        let accessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessing { pickedURL.stopAccessingSecurityScopedResource() } }

        let filename = UUID().uuidString + "." + (pickedURL.pathExtension.isEmpty
                                                  ? "m4a" : pickedURL.pathExtension)
        let destination = musicDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: pickedURL, to: destination)
        return filename
    }

    static func url(forMusicFilename filename: String) -> URL {
        musicDirectory.appendingPathComponent(filename)
    }

    static func deleteMusic(filename: String) {
        try? FileManager.default.removeItem(at: url(forMusicFilename: filename))
        try? FileManager.default.removeItem(at: beatMapURL(musicFilename: filename))
    }

    // MARK: - Cache des cartes de rythme

    private static func beatMapURL(musicFilename: String) -> URL {
        beatMapsDirectory.appendingPathComponent(
            musicFilename + ".v\(BeatMap.schemaVersion).json"
        )
    }

    static func cachedBeatMap(musicFilename: String) -> BeatMap? {
        guard let data = try? Data(contentsOf: beatMapURL(musicFilename: musicFilename)) else {
            return nil
        }
        return try? JSONDecoder().decode(BeatMap.self, from: data)
    }

    static func saveBeatMap(_ map: BeatMap, musicFilename: String) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: beatMapURL(musicFilename: musicFilename), options: .atomic)
    }
}
