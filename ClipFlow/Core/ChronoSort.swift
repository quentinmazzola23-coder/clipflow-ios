//
//  ChronoSort.swift
//  ClipFlow
//
//  Tri chronologique des rushes, par cascade de repli :
//  1. date de création PHAsset ;
//  2. métadonnée de création du fichier vidéo ;
//  3. timecode (réservé — non lu dans le MVP) ;
//  4. nom du fichier ;
//  5. ordre de sélection dans le picker.
//

import Foundation

/// Clé de tri d'un rush, indépendante de SwiftData — testable.
struct RushSortKey: Hashable, Sendable {
    var assetCreationDate: Date?
    var fileCreationDate: Date?
    var timecodeSeconds: Double?
    var filename: String
    var pickOrder: Int
}

enum ChronoSort {

    /// Comparateur : true si `a` doit précéder `b`.
    static func isOrderedBefore(_ a: RushSortKey, _ b: RushSortKey) -> Bool {
        // 1. Date PHAsset.
        switch (a.assetCreationDate, b.assetCreationDate) {
        case let (da?, db?) where da != db:
            return da < db
        default:
            break
        }
        // 2. Date fichier.
        switch (a.fileCreationDate, b.fileCreationDate) {
        case let (da?, db?) where da != db:
            return da < db
        default:
            break
        }
        // 3. Timecode.
        switch (a.timecodeSeconds, b.timecodeSeconds) {
        case let (ta?, tb?) where ta != tb:
            return ta < tb
        default:
            break
        }
        // 4. Nom de fichier (tri naturel : IMG_2 avant IMG_10).
        let nameComparison = a.filename.compare(
            b.filename,
            options: [.numeric, .caseInsensitive],
            range: nil,
            locale: Locale(identifier: "fr_FR")
        )
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        // 5. Ordre de sélection.
        return a.pickOrder < b.pickOrder
    }

    static func sorted(_ keys: [RushSortKey]) -> [RushSortKey] {
        keys.sorted(by: isOrderedBefore)
    }

    /// Indices triés (pour réordonner une collection parallèle).
    static func sortedIndices(_ keys: [RushSortKey]) -> [Int] {
        keys.indices.sorted { isOrderedBefore(keys[$0], keys[$1]) }
    }
}
