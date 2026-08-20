//
//  BeatEngineTests.swift
//  ClipFlowPipelineTests
//
//  Moteur rythmique : détection de BPM, phase, sections, créneaux.
//
//  Les signaux sont SYNTHÉTIQUES et déterministes : un kick est une bouffée
//  d'énergie posée à un instant connu. Si le moteur ne retrouve pas un tempo
//  qu'on a fabriqué nous-mêmes, il n'a aucune chance sur un vrai morceau.
//  Le comportement attendu est celui du script beat_edit_pov.py (référence
//  calibrée) : doublage d'octave sous 130 BPM, percentiles 75/20/55,
//  multiplicateurs drop 1 / build 1 / verse 2 / break 3.
//

import Testing
import Foundation
@testable import ClipFlowPipeline

// MARK: - Fabrique de signaux

enum TestSignal {
    static let sampleRate = 22_050.0

    /// Piste de « kicks » : silence + une bouffée sinusoïdale amortie sur
    /// chaque temps. Déterministe, sans bruit aléatoire.
    static func clickTrack(bpm: Double, seconds: Double,
                           clickHz: Double = 180, clickLength: Double = 0.05,
                           phase: Double = 0) -> [Float] {
        let total = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: total)
        let period = 60.0 / bpm
        let clickSamples = Int(clickLength * sampleRate)
        var t = phase
        while t < seconds {
            let start = Int(t * sampleRate)
            for offset in 0..<clickSamples where start + offset < total {
                let envelope = Float(1 - Double(offset) / Double(clickSamples))
                let value = sinf(Float(2 * Double.pi * clickHz * Double(offset) / sampleRate))
                samples[start + offset] += 0.9 * envelope * value
            }
            t += period
        }
        return samples
    }
}

// MARK: - Tempo

struct TempoTests {

    /// 150 BPM fabriqué → 150 BPM détecté. La tolérance (±1,5) est serrée à
    /// dessein : une erreur d'un BPM décale déjà la fin d'une fenêtre de 45 s.
    @Test func detectsFabricatedTempo() {
        let samples = TestSignal.clickTrack(bpm: 150, seconds: 30)
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: TestSignal.sampleRate)
        let bpm = TempoEstimator.estimateBPM(envelope: curves.onsetEnvelope,
                                             hopSeconds: curves.hopSeconds)
        #expect(bpm != nil)
        #expect(abs((bpm ?? 0) - 150) < 1.5, "BPM détecté hors tolérance")
    }

    /// Règle d'octave du script : 90 BPM fabriqué → 180 BPM rendu (la
    /// pulsation ressentie du hardstyle est au kick, pas à la blanche).
    @Test func doublesLowTempo() {
        let samples = TestSignal.clickTrack(bpm: 90, seconds: 30)
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: TestSignal.sampleRate)
        let bpm = TempoEstimator.estimateBPM(envelope: curves.onsetEnvelope,
                                             hopSeconds: curves.hopSeconds)
        #expect(bpm != nil)
        #expect(abs((bpm ?? 0) - 180) < 3, "90 BPM doit être rendu 180")
    }

    /// La PHASE retrouve le décalage fabriqué : les beats de la grille tombent
    /// sur les kicks à ±25 ms (deux trames d'analyse).
    @Test func phaseLandsOnClicks() {
        let offset = 0.137
        let samples = TestSignal.clickTrack(bpm: 150, seconds: 30, phase: offset)
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: TestSignal.sampleRate)
        let grid = TempoEstimator.estimateGrid(curves: curves, duration: 30)
        #expect(grid != nil)
        guard let grid else { return }
        let beats = TempoEstimator.beatTimes(grid: grid, duration: 30)
        #expect(beats.count > 60)
        // Chaque beat de la grille doit être proche d'UN kick fabriqué.
        let period = 60.0 / 150
        for beat in beats.prefix(40) {
            let nearestClick = ((beat - offset) / period).rounded() * period + offset
            #expect(abs(beat - nearestClick) < 0.025,
                    "Beat éloigné du kick le plus proche")
        }
    }

    /// Silence total : aucune grille inventée.
    @Test func silenceYieldsNothing() {
        let samples = [Float](repeating: 0, count: Int(20 * TestSignal.sampleRate))
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: TestSignal.sampleRate)
        let bpm = TempoEstimator.estimateBPM(envelope: curves.onsetEnvelope,
                                             hopSeconds: curves.hopSeconds)
        // Enveloppe plate → pas de pic d'autocorrélation exploitable.
        #expect(bpm == nil || curves.onsetEnvelope.allSatisfy { $0 == 0 })
    }
}

// MARK: - Sections

struct SectionClassificationTests {

    /// Un plateau d'énergie haute avec attaques fortes est classé drop ;
    /// le creux le plus bas est classé break.
    @Test func dropAndBreakLandWhereBuilt() {
        var energies = [Double](repeating: 0.5, count: 64)
        var onsets = [Double](repeating: 0.3, count: 64)
        for index in 24..<32 { energies[index] = 1.0; onsets[index] = 1.0 }   // climax
        for index in 48..<56 { energies[index] = 0.05; onsets[index] = 0.05 } // creux

        let sections = BeatAnalyzer.classify(energies: energies, onsets: onsets)
        #expect(sections.count == 64)
        // Cœur du climax (la moyenne glissante s'étale sur 8 beats).
        for index in 26..<30 {
            #expect(sections[index] == .drop, "Beat \(index) devrait être drop")
        }
        // Cœur du creux.
        for index in 50..<54 {
            #expect(sections[index] == .breakdown, "Beat \(index) devrait être break")
        }
    }

    /// Une montée régulière vers le climax contient des beats build.
    ///
    /// La forme du signal est choisie pour que le percentile 55 de l'énergie
    /// lissée tombe DANS la montée : moitié du morceau au calme, un tiers en
    /// montée, le reste au sommet — comme la structure réelle d'un morceau
    /// EDM. Un signal aux valeurs toutes égales rendrait les seuils
    /// percentiles dégénérés et ne testerait rien.
    @Test func risingEnergyProducesBuild() {
        var energies = [Double](repeating: 0.2, count: 64)
        var onsets = [Double](repeating: 0.15, count: 64)
        // Beats 32-52 : montée 0,2 → 0,9 ; beats 53-63 : sommet.
        for index in 32..<53 {
            energies[index] = 0.2 + 0.7 * Double(index - 32) / 20
        }
        for index in 53..<64 { energies[index] = 0.9; onsets[index] = 0.9 }

        let sections = BeatAnalyzer.classify(energies: energies, onsets: onsets)
        let buildCount = sections[32..<53].filter { $0 == .build }.count
        #expect(buildCount >= 3,
                "Montée fabriquée sans beats build : \(sections[32..<53])")
    }

    /// Tableaux incohérents : réponse vide, pas d'accès hors bornes.
    @Test func mismatchedInputsYieldNothing() {
        #expect(BeatAnalyzer.classify(energies: [1, 2], onsets: [1]).isEmpty)
        #expect(BeatAnalyzer.classify(energies: [], onsets: []).isEmpty)
    }
}

// MARK: - Créneaux

struct SlotGenerationTests {

    private func uniformMap(bpm: Double, beats: Int,
                            sections: [BeatSection]) -> BeatMap {
        let period = 60.0 / bpm
        return BeatMap(
            bpm: bpm,
            beatTimes: (0..<beats).map { Double($0) * period },
            energies: [Double](repeating: 0.5, count: beats),
            sections: sections,
            duration: Double(beats) * period,
            suggestedWindowStart: 0,
            waveform: []
        )
    }

    /// Les multiplicateurs du script : drop consomme 1 beat, verse 2, break 3.
    @Test func slotDurationsFollowSectionMultipliers() {
        let period = 60.0 / 150
        let sections: [BeatSection] =
            [.drop, .verse, .verse, .breakdown, .breakdown, .breakdown, .build]
            + Array(repeating: .drop, count: 9)
        let map = uniformMap(bpm: 150, beats: 16, sections: sections)
        let slots = map.slots(from: 0)

        #expect(slots[0].section == .drop)
        #expect(abs(slots[0].duration - period) < 1e-9)
        #expect(slots[1].section == .verse)
        #expect(abs(slots[1].duration - 2 * period) < 1e-9)
        #expect(slots[2].section == .breakdown)
        #expect(abs(slots[2].duration - 3 * period) < 1e-9)
    }

    /// Contiguïté : chaque créneau commence où le précédent finit — les
    /// coupes tombent sur les beats PAR CONSTRUCTION, jamais par arrondi.
    @Test func slotsAreContiguousOnBeats() {
        let sections = (0..<64).map { index -> BeatSection in
            switch index % 4 {
            case 0: return .drop
            case 1: return .verse
            case 2: return .build
            default: return .breakdown
            }
        }
        let map = uniformMap(bpm: 150, beats: 64, sections: sections)
        let slots = map.slots(from: 0)
        #expect(slots.count > 5)
        for index in 1..<slots.count {
            #expect(abs(slots[index].start - (slots[index - 1].start + slots[index - 1].duration)) < 1e-9,
                    "Trou ou chevauchement entre créneaux")
        }
        // Chaque début de créneau EST un instant de beat de la carte.
        for slot in slots {
            #expect(map.beatTimes.contains(where: { abs($0 - slot.start) < 1e-9 }),
                    "Un créneau ne démarre pas sur un beat")
        }
    }

    /// Départ au milieu du morceau : le premier créneau démarre au premier
    /// beat ≥ départ demandé.
    @Test func slotsStartAtFirstBeatAfterWindowStart() {
        let map = uniformMap(bpm: 150, beats: 64,
                             sections: Array(repeating: .drop, count: 64))
        let period = 60.0 / 150
        let slots = map.slots(from: 10 * period - 0.01)
        #expect(abs((slots.first?.start ?? -1) - 10 * period) < 1e-9)
    }
}

// MARK: - Fenêtre suggérée

struct SuggestedWindowTests {

    /// La fenêtre suggérée se cale sur le cluster de drops le plus énergique.
    @Test func windowTargetsStrongestDropCluster() {
        let period = 60.0 / 150
        let count = 400 // ~160 s de musique
        let beats = (0..<count).map { Double($0) * period }
        var sections = [BeatSection](repeating: .verse, count: count)
        var rolling = [Double](repeating: 0.3, count: count)
        // Cluster faible vers 30 s, cluster FORT vers 100 s.
        for index in 75..<85 { sections[index] = .drop; rolling[index] = 0.5 }
        for index in 250..<262 { sections[index] = .drop; rolling[index] = 1.0 }

        let start = BeatAnalyzer.suggestedWindow(beats: beats, sections: sections,
                                                 rolling: rolling, duration: 160)
        let strongClusterTime = beats[250]
        // Départ = centre − 35 % de la cible (45 s) → environ 15,75 s avant.
        #expect(start > strongClusterTime - 45, "Fenêtre trop en amont")
        #expect(start < strongClusterTime, "La fenêtre doit précéder le cluster")
    }

    /// Morceau court : pas de fenêtre — départ à zéro.
    @Test func shortTrackStartsAtZero() {
        let beats = (0..<40).map { Double($0) * 0.4 }
        let sections = [BeatSection](repeating: .drop, count: 40)
        let rolling = [Double](repeating: 1.0, count: 40)
        #expect(BeatAnalyzer.suggestedWindow(beats: beats, sections: sections,
                                             rolling: rolling, duration: 16) == 0)
    }
}
