//
//  TimeMath.swift
//  ClipFlow
//
//  Toutes les conversions temporelles sont RATIONNELLES (CMTime / entiers).
//  Aucune approximation en virgule flottante dans les calculs de durées,
//  de timestamps ou de nombres d'images.
//

import Foundation
import CoreMedia

/// Durée exacte exprimée en centièmes de seconde (précision demandée : 1/100 s).
struct ExactDuration: Hashable, Codable, Sendable {
    var centiseconds: Int

    var seconds: Double { Double(centiseconds) / 100.0 }
    var cmTime: CMTime { CMTime(value: CMTimeValue(centiseconds), timescale: 100) }

    static let presets: [ExactDuration] = [
        ExactDuration(centiseconds: 100),  // 1,0 s
        ExactDuration(centiseconds: 130),  // 1,3 s
        ExactDuration(centiseconds: 150),  // 1,5 s
        ExactDuration(centiseconds: 200),  // 2,0 s
    ]

    var label: String {
        String(format: "%d,%02d s", centiseconds / 100, centiseconds % 100)
    }
}

/// Vitesse de lecture rationnelle. 1/2 = 0,5× (durée doublée).
struct RationalSpeed: Hashable, Codable, Sendable {
    var numerator: Int
    var denominator: Int

    static let half = RationalSpeed(numerator: 1, denominator: 2)

    var label: String {
        if numerator == 1 && denominator == 2 { return "0,5×" }
        return "\(numerator)/\(denominator)×"
    }
}

enum TimeMath {

    /// Durée à prélever dans le rush ORIGINAL pour obtenir `final` après
    /// ralentissement à `speed`.
    ///
    /// duréeSource = duréeFinale × vitesse.
    /// Exemple : 1,3 s à 0,5× → 0,65 s exactement.
    /// Résultat exact : valeur = cs × num, timescale = 100 × den.
    static func sourceDuration(final: ExactDuration, speed: RationalSpeed) -> CMTime {
        let value = CMTimeValue(final.centiseconds * speed.numerator)
        let timescale = CMTimeScale(100 * speed.denominator)
        return reduce(CMTime(value: value, timescale: timescale))
    }

    /// Nombre d'images de sortie pour `final` à `fps`.
    /// frames = cs × fps / 100. Exact si divisible (1,3 s × 60 = 78).
    /// Retourne aussi un indicateur d'exactitude ; si inexact, arrondi au plus proche.
    static func outputFrameCount(final: ExactDuration, fps: Int) -> (count: Int, exact: Bool) {
        let numerator = final.centiseconds * fps
        if numerator % 100 == 0 {
            return (numerator / 100, true)
        }
        // Arrondi au plus proche, en signalant l'inexactitude à l'appelant.
        return ((numerator + 50) / 100, false)
    }

    /// Timestamp de présentation de l'image de sortie `index` à `fps`
    /// (0-indexé) : index / fps, exact.
    static func outputPTS(frameIndex: Int, fps: Int) -> CMTime {
        CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
    }

    /// Temps SOURCE correspondant à l'image de sortie `index` :
    /// t_source = start + (index / fps) × vitesse
    ///          = start + index × num / (fps × den)   — exact.
    static func sourceTime(forOutputFrame index: Int,
                           fps: Int,
                           speed: RationalSpeed,
                           selectionStart: CMTime) -> CMTime {
        let offset = CMTime(
            value: CMTimeValue(index * speed.numerator),
            timescale: CMTimeScale(fps * speed.denominator)
        )
        return CMTimeAdd(selectionStart, offset)
    }

    /// Réduction de fraction pour garder des timescales raisonnables.
    static func reduce(_ time: CMTime) -> CMTime {
        guard time.timescale != 0 else { return time }
        let g = gcd(abs(Int64(time.value)), Int64(time.timescale))
        guard g > 1 else { return time }
        return CMTime(value: time.value / CMTimeValue(g),
                      timescale: CMTimeScale(Int64(time.timescale) / g))
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}

// MARK: - Plan de rendu

/// Décrit comment produire chaque image finale : copie exacte d'une image source
/// ou interpolation entre deux images sources avec une phase donnée.
enum FramePlanEntry: Equatable, Sendable {
    /// L'image source `sourceIndex` correspond déjà exactement au timestamp voulu.
    case copy(sourceIndex: Int)
    /// Interpoler entre `previousIndex` et `nextIndex` à la phase `phase` ∈ ]0;1[.
    case interpolate(previousIndex: Int, nextIndex: Int, phase: Float)
}

enum FramePlanError: Error, LocalizedError {
    case notEnoughSourceFrames
    case targetOutsideSourceRange(frameIndex: Int)

    var errorDescription: String? {
        switch self {
        case .notEnoughSourceFrames:
            return "Pas assez d'images sources décodées pour couvrir la sélection."
        case .targetOutsideSourceRange(let index):
            return "L'image finale \(index) sort de la plage source décodée."
        }
    }
}

enum FramePlanner {

    /// Tolérance d'égalité entre un timestamp cible et une image source :
    /// 1/6000 s, très inférieure au demi-intervalle d'une source 240 fps.
    static let matchTolerance = CMTime(value: 1, timescale: 6000)

    /// Construit le plan de production des `outputFrameCount` images finales.
    ///
    /// - Parameters:
    ///   - sourcePTS: timestamps réels des images sources décodées (croissants),
    ///     exprimés dans le temps du rush original.
    ///   - selectionStart: début de la sélection dans le rush.
    ///   - outputFrameCount: nombre d'images finales.
    ///   - fps: cadence de sortie.
    ///   - speed: vitesse rationnelle (1/2 pour 0,5×).
    ///
    /// Ne génère PAS d'interpolation quand une image source tombe exactement sur
    /// le timestamp cible (ex. source 120 fps ralentie 0,5× vers 60 fps).
    static func plan(sourcePTS: [CMTime],
                     selectionStart: CMTime,
                     outputFrameCount: Int,
                     fps: Int,
                     speed: RationalSpeed) throws -> [FramePlanEntry] {
        guard sourcePTS.count >= 2 else { throw FramePlanError.notEnoughSourceFrames }

        var entries: [FramePlanEntry] = []
        entries.reserveCapacity(outputFrameCount)

        // Intervalle source médian : borne la tolérance de fin de rush.
        var intervals: [Double] = []
        intervals.reserveCapacity(sourcePTS.count - 1)
        for i in 1..<sourcePTS.count {
            intervals.append(CMTimeSubtract(sourcePTS[i], sourcePTS[i - 1]).seconds)
        }
        let medianInterval = intervals.sorted()[intervals.count / 2]

        // Parcours séquentiel : les cibles sont croissantes, on avance un curseur.
        var cursor = 0

        for frameIndex in 0..<outputFrameCount {
            let target = TimeMath.sourceTime(forOutputFrame: frameIndex,
                                             fps: fps,
                                             speed: speed,
                                             selectionStart: selectionStart)

            // Avancer le curseur tant que la prochaine image source reste ≤ cible.
            while cursor + 1 < sourcePTS.count,
                  CMTimeCompare(sourcePTS[cursor + 1], target) <= 0 {
                cursor += 1
            }

            let current = sourcePTS[cursor]

            // Correspondance exacte (à la tolérance près) ?
            if CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(current, target)), matchTolerance) <= 0 {
                entries.append(.copy(sourceIndex: cursor))
                continue
            }
            if cursor + 1 < sourcePTS.count {
                let next = sourcePTS[cursor + 1]
                if CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(next, target)), matchTolerance) <= 0 {
                    entries.append(.copy(sourceIndex: cursor + 1))
                    continue
                }
                // Interpolation : phase = (cible − précédente) / (suivante − précédente).
                let numerator = CMTimeSubtract(target, current)
                let denominator = CMTimeSubtract(next, current)
                let phase = Float(numerator.seconds / denominator.seconds)
                guard phase > 0, phase < 1 else {
                    throw FramePlanError.targetOutsideSourceRange(frameIndex: frameIndex)
                }
                entries.append(.interpolate(previousIndex: cursor, nextIndex: cursor + 1, phase: phase))
            } else {
                // Cible après la dernière image source (sélection collée à la
                // fin du rush) : dernière image DUPLIQUÉE si l'écart reste
                // inférieur à 1,5 intervalle source — sinon vraie erreur.
                let overshoot = CMTimeSubtract(target, current).seconds
                if overshoot <= medianInterval * 1.5 {
                    entries.append(.copy(sourceIndex: cursor))
                } else {
                    throw FramePlanError.targetOutsideSourceRange(frameIndex: frameIndex)
                }
            }
        }
        return entries
    }
}
