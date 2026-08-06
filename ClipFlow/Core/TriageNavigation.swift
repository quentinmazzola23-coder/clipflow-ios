//
//  TriageNavigation.swift
//  ClipFlow
//
//  Logique pure de navigation de triage — testable sans UI.
//

import Foundation

enum TriageNavigation {

    /// Index du prochain élément NON traité, en recherche circulaire à partir
    /// de l'élément qui suit `current` (nil = démarrer au début).
    /// Retourne nil si tout est traité ou si la liste est vide.
    static func nextUntreatedIndex(after current: Int?, treated: [Bool]) -> Int? {
        let count = treated.count
        guard count > 0 else { return nil }
        let begin = (current ?? -1) + 1
        for offset in 0..<count {
            let index = ((begin + offset) % count + count) % count
            if !treated[index] { return index }
        }
        return nil
    }
}
