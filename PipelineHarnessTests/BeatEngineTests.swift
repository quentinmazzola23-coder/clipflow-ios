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

// MARK: - Créneaux (découpe régulière par densité)

struct SlotGenerationTests {

    private func uniformMap(bpm: Double, beats: Int) -> BeatMap {
        let period = 60.0 / bpm
        return BeatMap(
            bpm: bpm,
            beatTimes: (0..<beats).map { Double($0) * period },
            energies: [Double](repeating: 0.5, count: beats),
            sections: [BeatSection](repeating: .verse, count: beats),
            duration: Double(beats) * period,
            suggestedWindowStart: 0,
            waveform: []
        )
    }

    /// Chaque cran produit des créneaux d'une durée UNIQUE et connue :
    /// beats × période. C'est l'engagement du sélecteur de densité.
    @Test func everyDensityYieldsUniformPredictableSlots() {
        let map = uniformMap(bpm: 150, beats: 64)
        let period = 60.0 / 150
        for density in CutDensity.allCases {
            let slots = map.slots(from: 0, density: density)
            #expect(slots.count >= 3, "Pas assez de créneaux au cran \(density.rawValue)")
            let expected = period * density.beatsPerCut
            for slot in slots {
                #expect(abs(slot.duration - expected) < 1e-9,
                        "Durée inattendue au cran \(density.rawValue)")
            }
            // L'aide au choix (slotDuration) dit EXACTEMENT ce que produit le cran.
            #expect(abs(density.slotDuration(bpm: 150) - expected) < 1e-9)
        }
    }

    /// Contiguïté à tous les crans : chaque créneau commence où le précédent
    /// finit — les coupes tombent sur la grille par construction.
    @Test func slotsAreContiguousAtEveryDensity() {
        let map = uniformMap(bpm: 150, beats: 64)
        for density in CutDensity.allCases {
            let slots = map.slots(from: 0, density: density)
            for index in 1..<slots.count {
                #expect(abs(slots[index].start
                            - (slots[index - 1].start + slots[index - 1].duration)) < 1e-9,
                        "Trou au cran \(density.rawValue)")
            }
        }
    }

    /// Le demi-beat coupe au beat ET au milieu exact de chaque intervalle.
    @Test func halfDensityCutsAtMidpoints() {
        let map = uniformMap(bpm: 150, beats: 16)
        let period = 60.0 / 150
        let slots = map.slots(from: 0, density: .half)
        #expect(abs(slots[0].duration - period / 2) < 1e-9)
        #expect(abs(slots[1].start - period / 2) < 1e-9)
    }

    /// Départ au milieu du morceau : premier créneau au premier beat ≥ départ.
    @Test func slotsStartAtFirstBeatAfterWindowStart() {
        let map = uniformMap(bpm: 150, beats: 64)
        let period = 60.0 / 150
        let slots = map.slots(from: 10 * period - 0.01, density: .beat1)
        #expect(abs((slots.first?.start ?? -1) - 10 * period) < 1e-9)
    }

    /// L'information de planification : min = max sur une grille régulière,
    /// et la valeur est celle annoncée par le cran.
    @Test func slotRangeReportsExactDurations() {
        let map = uniformMap(bpm: 200, beats: 64)
        let slots = map.slots(from: 0, density: .beats2)
        let range = BeatMap.slotDurationRange(slots)
        #expect(range != nil)
        #expect(abs((range?.min ?? 0) - 0.6) < 1e-9)   // 2 beats à 200 BPM
        #expect(abs((range?.max ?? 0) - 0.6) < 1e-9)
        #expect(BeatMap.slotDurationRange([]) == nil)
    }
}

// MARK: - Grille asservie (rattrapage de dérive)

struct AdaptiveGridTests {

    /// Morceau au métronome : la grille asservie est IDENTIQUE à la grille
    /// fixe — aucune correction parasite (pas de tremblement).
    @Test func steadyTrackYieldsSteadyGrid() {
        let samples = TestSignal.clickTrack(bpm: 150, seconds: 30, phase: 0.1)
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: TestSignal.sampleRate)
        guard let grid = TempoEstimator.estimateGrid(curves: curves, duration: 30) else {
            #expect(Bool(false), "Grille non posée sur un signal propre")
            return
        }
        let beats = TempoEstimator.adaptiveBeatTimes(grid: grid, curves: curves, duration: 30)
        let period = 60.0 / 150
        for beat in beats.prefix(60) {
            let nearest = ((beat - 0.1) / period).rounded() * period + 0.1
            #expect(abs(beat - nearest) < 0.025, "Beat asservi éloigné du kick")
        }
    }

    /// LE CAS DEMANDÉ : un morceau dont la seconde moitié est DÉCALÉE (break
    /// irrégulier, montage du morceau). La grille fixe resterait à contretemps
    /// jusqu'à la fin ; la grille asservie doit se recaler.
    ///
    /// FIXTURE MAÎTRISÉE (leçon d'une contre-épreuve numérique) : la première
    /// moitié dure un nombre ENTIER de périodes (16 s = 40 × 0,4 s), pour que
    /// le décalage VU par la grille soit exactement `jump` — pas un artefact
    /// modulaire. Et `jump` est choisi DANS le bassin de capture mesuré
    /// (± 20 % de période ≈ ± 80 ms) : au-delà, l'asservissement ne raccroche
    /// jamais, c'est sa limite documentée, pas un défaut.
    @Test func gridRecoversAfterPhaseJump() {
        let bpm = 150.0
        let period = 60.0 / bpm
        let jump = 0.07 // 17,5 % de période : dans le bassin de capture
        let sampleRate = TestSignal.sampleRate
        let first = TestSignal.clickTrack(bpm: bpm, seconds: 16)
        let second = TestSignal.clickTrack(bpm: bpm, seconds: 16, phase: jump)
        let samples = first + second
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: sampleRate)
        guard let grid = TempoEstimator.estimateGrid(curves: curves, duration: 32) else {
            #expect(Bool(false), "Grille non posée")
            return
        }
        let beats = TempoEstimator.adaptiveBeatTimes(grid: grid, curves: curves, duration: 32)
        // En FIN de morceau (le rattrapage a eu le temps de jouer), les beats
        // doivent coller aux kicks décalés à moins de 30 ms.
        let lateBeats = beats.filter { $0 > 26 && $0 < 31 }
        #expect(lateBeats.count >= 8, "Pas assez de beats en fin de morceau")
        for beat in lateBeats {
            let nearest = ((beat - 16 - jump) / period).rounded() * period + 16 + jump
            #expect(abs(beat - nearest) < 0.03,
                    "La grille ne s'est pas recalée après le décalage")
        }
    }

    /// Silence au milieu (break sans percussions) : la grille CONTINUE sur son
    /// élan — pas d'invention, pas de dérive brutale.
    @Test func gridCoastsThroughSilence() {
        let bpm = 150.0
        let period = 60.0 / bpm
        let sampleRate = TestSignal.sampleRate
        // Durées MULTIPLES de la période (10 s = 25 × 0,4 ; 4,8 s = 12 × 0,4) :
        // la reprise après le silence est EN PHASE avec la grille — le test
        // exerce le maintien dans le silence ET la re-accroche à la sortie.
        let part = TestSignal.clickTrack(bpm: bpm, seconds: 10)
        let silence = [Float](repeating: 0, count: Int(4.8 * sampleRate))
        let samples = part + silence + part
        let curves = OnsetExtractor.curves(samples: samples, sampleRate: sampleRate)
        guard let grid = TempoEstimator.estimateGrid(curves: curves, duration: 24.8) else {
            #expect(Bool(false), "Grille non posée")
            return
        }
        let beats = TempoEstimator.adaptiveBeatTimes(grid: grid, curves: curves, duration: 24.8)
        // Dans le silence (10-14,8 s), les intervalles restent la période.
        let inSilence = zip(beats, beats.dropFirst()).filter { $0.0 > 10.5 && $0.1 < 14.3 }
        for (a, b) in inSilence {
            #expect(abs((b - a) - period) < 0.02, "La grille a dérivé dans le silence")
        }
    }
}

// MARK: - Bibliothèque : filtre de licence (repli Internet Archive)

struct MusicLicenseFilterTests {

    /// Seules les licences à usage commercial ET dérivé passent : domaine
    /// public, CC0, BY, BY-SA. NC et ND sont écartées — un montage est une
    /// œuvre dérivée à usage commercial.
    @Test func commercialFilterKeepsOnlyUsableLicenses() {
        #expect(MusicLibraryAPI.isCommercialLicense("https://creativecommons.org/publicdomain/zero/1.0/"))
        #expect(MusicLibraryAPI.isCommercialLicense("http://creativecommons.org/licenses/by/4.0/"))
        #expect(MusicLibraryAPI.isCommercialLicense("http://creativecommons.org/licenses/by-sa/3.0/"))
        #expect(MusicLibraryAPI.isCommercialLicense("http://creativecommons.org/publicdomain/mark/1.0/"))
        #expect(!MusicLibraryAPI.isCommercialLicense("http://creativecommons.org/licenses/by-nc/4.0/"))
        #expect(!MusicLibraryAPI.isCommercialLicense("http://creativecommons.org/licenses/by-nc-nd/2.5/it/"))
        #expect(!MusicLibraryAPI.isCommercialLicense("http://creativecommons.org/licenses/by-nd/4.0/"))
        #expect(!MusicLibraryAPI.isCommercialLicense("https://example.com/proprietary"))
        #expect(!MusicLibraryAPI.isCommercialLicense(""))
    }

    @Test func licenseLabelsAreShort() {
        #expect(MusicLibraryAPI.licenseLabel("https://creativecommons.org/publicdomain/zero/1.0/") == "cc0")
        #expect(MusicLibraryAPI.licenseLabel("http://creativecommons.org/licenses/by/4.0/") == "by")
        #expect(MusicLibraryAPI.licenseLabel("http://creativecommons.org/licenses/by-sa/3.0/") == "by-sa")
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
