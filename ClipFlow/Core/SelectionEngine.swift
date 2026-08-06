//
//  SelectionEngine.swift
//  ClipFlow
//
//  Logique pure de sélection à durée fixe. Aucune dépendance UI — testable.
//

import Foundation
import CoreMedia

enum SelectionError: Error, LocalizedError, Equatable {
    /// Le rush est plus court que la durée source requise.
    case rushTooShort(rushDuration: CMTime, required: CMTime)

    var errorDescription: String? {
        switch self {
        case .rushTooShort(let rushDuration, let required):
            return String(
                format: "Rush trop court : %.2f s disponibles, %.2f s nécessaires.",
                rushDuration.seconds, required.seconds
            )
        }
    }
}

enum SelectionEngine {

    /// Crée une sélection de durée source fixe dans un rush.
    ///
    /// - Parameters:
    ///   - touchTime: temps touché dans le rush.
    ///   - sourceDuration: durée SOURCE fixe (déjà calculée depuis durée finale × vitesse).
    ///   - rushDuration: durée totale du rush.
    ///   - anchorCenter: si vrai, le toucher est le CENTRE de la sélection ;
    ///     sinon il en est le DÉBUT (défaut).
    ///
    /// La sélection est recalée automatiquement si elle déborde du rush.
    /// Erreur claire si le rush est trop court.
    static func makeSelection(touchTime: CMTime,
                              sourceDuration: CMTime,
                              rushDuration: CMTime,
                              anchorCenter: Bool) throws -> CMTimeRange {
        guard CMTimeCompare(rushDuration, sourceDuration) >= 0 else {
            throw SelectionError.rushTooShort(rushDuration: rushDuration, required: sourceDuration)
        }
        var start = touchTime
        if anchorCenter {
            let half = CMTimeMultiplyByRatio(sourceDuration, multiplier: 1, divisor: 2)
            start = CMTimeSubtract(touchTime, half)
        }
        return clamp(CMTimeRange(start: start, duration: sourceDuration), rushDuration: rushDuration)
    }

    /// Déplace la sélection de `delta` sans changer sa durée, recalée aux bornes.
    static func move(_ range: CMTimeRange,
                     by delta: CMTime,
                     rushDuration: CMTime) -> CMTimeRange {
        let moved = CMTimeRange(start: CMTimeAdd(range.start, delta), duration: range.duration)
        return clamp(moved, rushDuration: rushDuration)
    }

    /// Déplacement image par image à la cadence native du rush.
    /// `frames` peut être négatif (image précédente).
    static func nudge(_ range: CMTimeRange,
                      frames: Int,
                      frameDuration: CMTime,
                      rushDuration: CMTime) -> CMTimeRange {
        let delta = CMTimeMultiply(frameDuration, multiplier: Int32(frames))
        return move(range, by: delta, rushDuration: rushDuration)
    }

    /// Recale la sélection dans [0, rushDuration] sans modifier sa durée.
    static func clamp(_ range: CMTimeRange, rushDuration: CMTime) -> CMTimeRange {
        var start = range.start
        if CMTimeCompare(start, .zero) < 0 {
            start = .zero
        }
        let end = CMTimeAdd(start, range.duration)
        if CMTimeCompare(end, rushDuration) > 0 {
            start = CMTimeSubtract(rushDuration, range.duration)
            if CMTimeCompare(start, .zero) < 0 { start = .zero }
        }
        return CMTimeRange(start: start, duration: range.duration)
    }
}
