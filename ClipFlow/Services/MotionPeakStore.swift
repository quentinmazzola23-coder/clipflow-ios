//
//  MotionPeakStore.swift
//  ClipFlow
//
//  Conservation des moments repérés, par rush.
//
//  L'analyse coûte quelques secondes par rush : la refaire à chaque ouverture
//  de projet serait insupportable. Les résultats vont dans Caches/ — effaçables
//  par le système sans perte (une nouvelle analyse les reconstruit), donc
//  jamais dans les données de l'app.
//
//  Aucune modification du schéma SwiftData : la clé est l'identité du FICHIER
//  source, la même que celle du cache de vignettes.
//

import Foundation

enum MotionPeakStore {

    private struct Record: Codable {
        var espacement: Double
        var peaks: [Stored]
    }

    private struct Stored: Codable {
        var time: Double
        var score: Double
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionPeaks", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func fileURL(key: String) -> URL {
        // Nom de fichier sûr, quelle que soit la clé d'origine.
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    /// Moments conservés pour ce rush, à condition que l'espacement demandé
    /// soit le même : changer la durée des clips change les propositions.
    static func peaks(key: String, spacing: Double) -> [MotionPeak]? {
        guard let data = try? Data(contentsOf: fileURL(key: key)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              abs(record.espacement - spacing) < 0.001 else { return nil }
        return record.peaks.map { MotionPeak(time: $0.time, score: $0.score) }
    }

    static func save(_ peaks: [MotionPeak], key: String, spacing: Double) {
        let record = Record(
            espacement: spacing,
            peaks: peaks.map { Stored(time: $0.time, score: $0.score) }
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: fileURL(key: key), options: .atomic)
    }

    static func clear(key: String) {
        try? FileManager.default.removeItem(at: fileURL(key: key))
    }
}
