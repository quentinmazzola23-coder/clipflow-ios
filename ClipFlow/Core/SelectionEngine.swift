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

    /// Crée une sélection allant du toucher JUSQU'À LA FIN DU RUSH.
    ///
    /// Mode de durée à part entière, au même titre que « 1,3 s » : ici la durée
    /// n'est pas imposée, c'est le rush restant qui la donne. Le toucher est
    /// toujours le DÉBUT — ancrer au centre n'aurait pas de sens pour une
    /// sélection dont la fin est fixée d'avance.
    ///
    /// - Parameter minimumDuration: en dessous, il ne reste pas assez de rush
    ///   pour produire un clip (typiquement deux images source).
    static func makeSelectionToEnd(touchTime: CMTime,
                                   rushDuration: CMTime,
                                   minimumDuration: CMTime) throws -> CMTimeRange {
        var start = touchTime
        if CMTimeCompare(start, .zero) < 0 { start = .zero }
        let remaining = CMTimeSubtract(rushDuration, start)
        guard CMTimeCompare(remaining, minimumDuration) >= 0 else {
            throw SelectionError.rushTooShort(rushDuration: remaining, required: minimumDuration)
        }
        return CMTimeRange(start: start, duration: remaining)
    }

    /// Déplace le DÉBUT d'une sélection « jusqu'à la fin du rush » : la fin
    /// reste collée au bout du rush, donc la durée change avec le déplacement.
    ///
    /// `move` ne convient pas ici — elle conserve la durée et se contente de
    /// glisser la fenêtre, ce qui décollerait la sélection de la fin du rush.
    static func moveOpenEnd(_ range: CMTimeRange,
                            by delta: CMTime,
                            rushDuration: CMTime,
                            minimumDuration: CMTime) -> CMTimeRange {
        var start = CMTimeAdd(range.start, delta)
        if CMTimeCompare(start, .zero) < 0 { start = .zero }
        let latest = CMTimeSubtract(rushDuration, minimumDuration)
        if CMTimeCompare(start, latest) > 0 { start = latest }
        if CMTimeCompare(start, .zero) < 0 { start = .zero }
        return CMTimeRange(start: start, duration: CMTimeSubtract(rushDuration, start))
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
