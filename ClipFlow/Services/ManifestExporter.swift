//
//  ManifestExporter.swift
//  ClipFlow
//
//  Manifeste JSON partageable décrivant tous les passages d'un projet.
//

import Foundation
import CoreMedia

struct ManifestEntry: Codable {
    var source: String
    var timecodeIn: Double
    var timecodeOut: Double
    var sourceDurationSeconds: Double
    var finalDurationSeconds: Double
    var speed: String
    var outputFPS: Int
    var categories: [String]
    var renderedFilename: String?
    var engineSettings: String
}

struct Manifest: Codable {
    var projectName: String
    var generatedAt: String
    var entries: [ManifestEntry]
}

enum ManifestExporter {

    /// Écrit le manifeste JSON dans Exports et retourne son URL (pour ShareLink).
    static func writeManifest(for project: ClipProject) throws -> URL {
        let formatter = ISO8601DateFormatter()
        let entries = project.orderedPassages.map { passage -> ManifestEntry in
            let range = passage.sourceRange
            return ManifestEntry(
                source: passage.rush?.originalFilename ?? "inconnu",
                timecodeIn: range.start.seconds,
                timecodeOut: range.end.seconds,
                sourceDurationSeconds: range.duration.seconds,
                finalDurationSeconds: Double(passage.finalDurationCentiseconds) / 100,
                speed: RationalSpeed(
                    numerator: passage.speedNumerator,
                    denominator: passage.speedDenominator
                ).label,
                outputFPS: project.exportFPS,
                categories: passage.categories,
                renderedFilename: passage.exportedFilename,
                engineSettings: "\(project.exportCodec), \(project.exportFPS) fps, interpolation flux optique"
            )
        }
        let manifest = Manifest(
            projectName: project.name,
            generatedAt: formatter.string(from: .now),
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        let url = StorageManager.exportsDirectory
            .appendingPathComponent("\(NamingEngine.sanitize(project.name)).manifest.json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
