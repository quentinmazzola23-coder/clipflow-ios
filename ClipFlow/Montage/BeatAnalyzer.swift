//
//  BeatAnalyzer.swift
//  ClipFlow
//
//  ORCHESTRATION de l'analyse musicale : courbes → grille de beats → énergie
//  par beat → sections (drop / build / verse / break) → fenêtre suggérée.
//
//  La classification est le PORT DIRECT de `beat_edit_pov.py` (la référence
//  calibrée sur les musiques réelles de l'utilisateur) :
//    combined  = énergie_lissée × attaque_au_beat
//    drop      : combined  ≥ percentile 75
//    break     : lissée    ≤ percentile 20
//    build     : gradient > 0,006  ET  lissée < percentile 55
//    verse     : le reste
//  Fenêtre suggérée : le cluster de drops le plus énergique (voisinage 6 s),
//  départ recalé à 35 % de la durée cible avant son centre.
//
//  Logique pure — testable en CI sur signaux synthétiques.
//

import Foundation

enum BeatAnalyzer {

    /// Lissage de l'énergie par beat : fenêtre de 8 beats (script).
    static let rollingWindow = 8
    /// Percentiles du script — NE PAS retoucher sans recalibrer sur les
    /// musiques réelles : ces valeurs sont le produit d'itérations mesurées.
    static let dropPercentile = 75.0
    static let breakPercentile = 20.0
    static let buildPercentile = 55.0
    static let buildGradientThreshold = 0.006
    /// Durée cible de la fenêtre suggérée (ne borne PAS le montage : seul le
    /// nombre de clips décide de la fin — c'est un point de départ proposé).
    static let suggestedWindowTarget = 40.0 // TARGET_MUSIC_DURATION du script

    /// Analyse complète d'un signal mono déjà décodé.
    static func analyze(samples: [Float], sampleRate: Double) -> BeatMap? {
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: sampleRate)
        let duration = Double(samples.count) / sampleRate
        guard let grid = TempoEstimator.estimateGrid(curves: curves, duration: duration) else {
            return nil
        }
        let beats = TempoEstimator.beatTimes(grid: grid, duration: duration)
        guard beats.count >= 4 else { return nil }
        return map(curves: curves, grid: grid, beats: beats, duration: duration)
    }

    /// Cœur séparé de l'analyse (grille déjà posée) — testable directement.
    static func map(curves: AnalysisCurves, grid: BeatGrid,
                    beats: [Double], duration: Double) -> BeatMap {
        // Énergie et attaque À CHAQUE BEAT — lecture interpolée, via la
        // conversion temps réel → trame (compensation du centre de fenêtre).
        let energies = beats.map {
            Double(TempoEstimator.interpolated(curves.rms, at: curves.frameIndex(at: $0)))
        }
        let onsets = beats.map {
            Double(TempoEstimator.interpolated(curves.onsetEnvelope, at: curves.frameIndex(at: $0)))
        }

        let sections = classify(energies: energies, onsets: onsets)
        let rolling = rollingMean(energies, window: min(rollingWindow, max(1, energies.count)))
        let window = suggestedWindow(beats: beats, sections: sections,
                                     rolling: rolling, duration: duration)

        return BeatMap(
            bpm: grid.bpm,
            beatTimes: beats,
            energies: energies,
            sections: sections,
            duration: duration,
            suggestedWindowStart: window,
            waveform: waveformBuckets(curves.rms)
        )
    }

    /// Classification de chaque beat — port du script, seuils percentiles
    /// calculés sur CE morceau (indépendant du genre et du mastering).
    static func classify(energies: [Double], onsets: [Double]) -> [BeatSection] {
        guard !energies.isEmpty, energies.count == onsets.count else { return [] }
        let rolling = rollingMean(energies, window: min(rollingWindow, energies.count))
        let gradient = centralGradient(rolling)
        let combined = zip(rolling, onsets).map { $0 * $1 }

        let dropThreshold = percentile(combined, dropPercentile)
        let breakThreshold = percentile(rolling, breakPercentile)
        let buildThreshold = percentile(rolling, buildPercentile)

        return (0..<energies.count).map { index in
            if combined[index] >= dropThreshold { return .drop }
            if rolling[index] <= breakThreshold { return .breakdown }
            if gradient[index] > buildGradientThreshold, rolling[index] < buildThreshold {
                return .build
            }
            return .verse
        }
    }

    /// Fenêtre suggérée : centre = le drop au voisinage (± 6 s) le plus
    /// énergique ; départ = centre − 35 % de la durée cible. Sans drop,
    /// départ au début du morceau — pas de fenêtre inventée.
    static func suggestedWindow(beats: [Double], sections: [BeatSection],
                                rolling: [Double], duration: Double) -> Double {
        guard beats.count == sections.count, beats.count == rolling.count else { return 0 }
        if duration <= suggestedWindowTarget * 1.1 { return 0 }

        let dropIndices = sections.indices.filter { sections[$0] == .drop }
        guard !dropIndices.isEmpty else { return 0 }

        var bestScore = -Double.infinity
        var bestCenter = beats[dropIndices[0]]
        for index in dropIndices {
            let center = beats[index]
            var score = 0.0
            for other in dropIndices where abs(beats[other] - center) < 6.0 {
                score += rolling[other]
            }
            if score > bestScore {
                bestScore = score
                bestCenter = center
            }
        }
        let start = max(0, bestCenter - suggestedWindowTarget * 0.35)
        // Bornage du script : la fenêtre recule pour tenir entière.
        return min(start, max(0, duration - suggestedWindowTarget))
    }

    // MARK: - Outils numériques (équivalents numpy du script)

    /// Moyenne glissante 'same' (np.convolve(ones/win, mode='same')) :
    /// fenêtre centrée, bords remplis de zéros — les bords sortent atténués,
    /// exactement comme dans le script.
    static func rollingMean(_ values: [Double], window: Int) -> [Double] {
        guard window > 1, !values.isEmpty else { return values }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in 0..<values.count { prefix[index + 1] = prefix[index] + values[index] }
        // np 'same' : la fenêtre déborde des bords, les termes manquants
        // valent zéro, le DIVISEUR reste la taille de fenêtre. Pour une
        // fenêtre PAIRE, numpy met le débord À GAUCHE : l'élément i moyenne
        // [i−4 ; i+3] pour une fenêtre de 8 — vérifié par exécution sur une
        // rampe. L'inverser décalerait toute la courbe lissée d'un beat par
        // rapport au script calibré.
        let leftReach = window - 1 - (window - 1) / 2
        let rightReach = (window - 1) / 2
        return (0..<values.count).map { index in
            let lower = max(0, index - leftReach)
            let upper = min(values.count - 1, index + rightReach)
            return (prefix[upper + 1] - prefix[lower]) / Double(window)
        }
    }

    /// np.gradient : différences centrales, un côté aux bords.
    static func centralGradient(_ values: [Double]) -> [Double] {
        guard values.count >= 2 else { return values.map { _ in 0 } }
        return (0..<values.count).map { index in
            if index == 0 { return values[1] - values[0] }
            if index == values.count - 1 { return values[index] - values[index - 1] }
            return (values[index + 1] - values[index - 1]) / 2
        }
    }

    /// Percentile linéaire (np.percentile par défaut).
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = (Double(sorted.count - 1)) * p / 100
        let lower = Int(position)
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// Enveloppe réduite pour l'affichage (max par seau — le max, pas la
    /// moyenne : une forme d'onde moyennée écrase les kicks qu'on veut voir).
    static func waveformBuckets(_ rms: [Float], target: Int = 400) -> [Float] {
        guard rms.count > target else { return rms }
        var result = [Float](repeating: 0, count: target)
        for bucket in 0..<target {
            let lower = bucket * rms.count / target
            let upper = max(lower + 1, (bucket + 1) * rms.count / target)
            var maximum: Float = 0
            for index in lower..<upper { maximum = max(maximum, rms[index]) }
            result[bucket] = maximum
        }
        return result
    }
}
