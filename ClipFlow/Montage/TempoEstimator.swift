//
//  TempoEstimator.swift
//  ClipFlow
//
//  BPM et GRILLE DE BEATS depuis l'enveloppe d'attaques.
//
//  Choix assumé : grille RÉGULIÈRE (période constante + phase optimale), pas
//  de suivi de tempo variable. Les musiques visées (hardstyle, EDM) sont
//  produites au métronome — un suivi adaptatif n'apporterait que des occasions
//  de dériver. La période est affinée par interpolation parabolique pour que
//  l'erreur reste sous une demi-image même en bout de fenêtre.
//
//  Règle d'octave du script d'origine, conservée à l'identique : un BPM
//  détecté sous 130 est DOUBLÉ (la pulsation perçue du hardstyle est au
//  kick, pas à la blanche).
//
//  Logique pure, testable en CI sur signaux synthétiques.
//

import Foundation

/// Grille de beats régulière posée sur un morceau.
struct BeatGrid: Sendable, Equatable {
    var bpm: Double
    /// Instant du premier beat (secondes).
    var phase: Double
    /// Période entre deux beats (secondes) — 60 / bpm.
    var period: Double
}

enum TempoEstimator {

    /// Plage de recherche, identique à l'esprit du script (hardstyle > 140).
    static let minimumBPM = 60.0
    static let maximumBPM = 220.0
    /// Sous ce BPM, la détection est réputée être tombée sur la blanche :
    /// doublée, comme dans le script (`if bpm_raw < 130: bpm *= 2`).
    static let octaveDoublingThreshold = 130.0

    /// Estime la grille complète : BPM (autocorrélation), puis phase
    /// (balayage exhaustif d'une période).
    static func estimateGrid(curves: AnalysisCurves, duration: Double) -> BeatGrid? {
        guard let bpm = estimateBPM(envelope: curves.onsetEnvelope,
                                    hopSeconds: curves.hopSeconds) else { return nil }
        let period = 60.0 / bpm
        let envelopePhase = bestPhase(envelope: curves.onsetEnvelope,
                                      hopSeconds: curves.hopSeconds,
                                      period: period)
        // La phase est trouvée dans le TEMPS DES TRAMES ; l'instant réel du
        // beat est au centre de la fenêtre d'analyse (voir AnalysisCurves).
        return BeatGrid(bpm: bpm,
                        phase: envelopePhase + curves.frameCenterOffset,
                        period: period)
    }

    /// BPM par AUTOCORRÉLATION de l'enveloppe d'attaques : le décalage qui
    /// superpose le mieux l'enveloppe avec elle-même est la période du kick.
    static func estimateBPM(envelope: [Float], hopSeconds: Double) -> Double? {
        let minLag = Int((60.0 / maximumBPM) / hopSeconds)         // période courte
        let maxLag = Int((60.0 / minimumBPM) / hopSeconds) + 1     // période longue
        guard envelope.count > maxLag + 2, minLag >= 2 else { return nil }

        // Enveloppe centrée : sans cela, la composante continue écrase tout.
        let mean = envelope.reduce(Float(0), +) / Float(envelope.count)
        let centered = envelope.map { Double($0 - mean) }

        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var sum = 0.0
            for index in 0..<(centered.count - lag) {
                sum += centered[index] * centered[index + lag]
            }
            // Normalisation par le nombre de termes : sans elle, les lags
            // courts (plus de termes) seraient structurellement avantagés.
            scores[lag] = sum / Double(centered.count - lag)
        }

        guard var bestLag = (minLag...maxLag).max(by: { scores[$0] < scores[$1] }),
              scores[bestLag] > 0 else { return nil }

        // PIÈGE D'OCTAVE BASSE : si la moitié du lag retenu est aussi un pic
        // fort (≥ 80 % du score), la vraie pulsation est la plus RAPIDE des
        // deux — l'autocorrélation d'un signal périodique culmine à tous les
        // multiples de la période, et le multiple peut gagner par bruit.
        let halfLag = bestLag / 2
        if halfLag >= minLag, scores[halfLag] >= scores[bestLag] * 0.8 {
            bestLag = halfLag
        }

        // Interpolation parabolique du pic : le lag entier est précis à
        // ±0,5 trame (~6 ms) ; sur 100 beats l'erreur cumulée serait audible.
        var refinedLag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let left = scores[bestLag - 1]
            let center = scores[bestLag]
            let right = scores[bestLag + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-12 {
                let delta = 0.5 * (left - right) / denominator
                if abs(delta) < 1 { refinedLag += delta }
            }
        }

        // AFFINAGE PAR MULTIPLE LONG. La parabole sur le lag court laisse une
        // erreur de quelques millisecondes de période — invisible sur un beat,
        // mais CUMULÉE sur 80 beats elle décale la fin du montage d'une image.
        // Le pic d'autocorrélation à m × lag porte la même information avec m
        // fois moins d'erreur relative : on le mesure et on divise.
        let multiple = min(8, (centered.count / 2) / bestLag)
        if multiple >= 2 {
            let center = Int((refinedLag * Double(multiple)).rounded())
            if center + 2 < centered.count {
                let localScores = (center - 2)...(center + 2)
                let values = localScores.map { autocorrelation(centered, lag: $0) }
                if let peakOffset = values.indices.max(by: { values[$0] < values[$1] }) {
                    var longLag = Double(center - 2 + peakOffset)
                    if peakOffset > 0, peakOffset < values.count - 1 {
                        let denominator = values[peakOffset - 1] - 2 * values[peakOffset]
                            + values[peakOffset + 1]
                        if abs(denominator) > 1e-12 {
                            let delta = 0.5 * (values[peakOffset - 1] - values[peakOffset + 1]) / denominator
                            if abs(delta) < 1 { longLag += delta }
                        }
                    }
                    let candidate = longLag / Double(multiple)
                    // Garde-fou : l'affinage ne peut que PRÉCISER, jamais sauter
                    // sur un autre pic — écart borné à une trame.
                    if abs(candidate - refinedLag) < 1 { refinedLag = candidate }
                }
            }
        }

        var bpm = 60.0 / (refinedLag * hopSeconds)
        // Règle d'octave du script : la pulsation ressentie est au kick.
        // Le doublement n'a lieu que s'il reste DANS la plage — sinon les
        // deux clauses s'annuleraient sur (110 ; 130) et la règle documentée
        // ne s'appliquerait jamais à ces tempos.
        if bpm < octaveDoublingThreshold, bpm * 2 <= maximumBPM { bpm *= 2 }
        return bpm
    }

    /// Autocorrélation à un lag donné, normalisée par le nombre de termes.
    private static func autocorrelation(_ centered: [Double], lag: Int) -> Double {
        guard lag > 0, lag < centered.count else { return 0 }
        var sum = 0.0
        for index in 0..<(centered.count - lag) {
            sum += centered[index] * centered[index + lag]
        }
        return sum / Double(centered.count - lag)
    }

    /// Phase de la grille : parmi tous les départs possibles dans UNE période,
    /// celui qui aligne la grille sur le plus d'attaques.
    ///
    /// Somme d'enveloppe interpolée aux instants de grille — exhaustif et
    /// borné (une période ≈ 35 pas à 150 BPM).
    static func bestPhase(envelope: [Float], hopSeconds: Double, period: Double) -> Double {
        guard !envelope.isEmpty, period > 0 else { return 0 }
        let duration = Double(envelope.count) * hopSeconds
        let steps = max(8, Int(period / hopSeconds))
        var bestPhase = 0.0
        var bestScore = -Double.infinity

        for step in 0..<steps {
            let phase = Double(step) * period / Double(steps)
            var score = 0.0
            var t = phase
            while t < duration {
                score += Double(interpolated(envelope, at: t / hopSeconds))
                t += period
            }
            if score > bestScore {
                bestScore = score
                bestPhase = phase
            }
        }
        return bestPhase
    }

    /// Instants de tous les beats de la grille sur [0 ; duration].
    static func beatTimes(grid: BeatGrid, duration: Double) -> [Double] {
        guard grid.period > 0 else { return [] }
        var result: [Double] = []
        var t = grid.phase
        while t < duration {
            result.append(t)
            t += grid.period
        }
        return result
    }

    /// Lecture linéairement interpolée d'un tableau à un index fractionnaire.
    static func interpolated(_ values: [Float], at index: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        if index <= 0 { return values[0] }
        let upperBound = Double(values.count - 1)
        if index >= upperBound { return values[values.count - 1] }
        let lower = Int(index)
        let fraction = Float(index - Double(lower))
        return values[lower] * (1 - fraction) + values[lower + 1] * fraction
    }
}
