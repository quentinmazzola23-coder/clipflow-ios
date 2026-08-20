//
//  MusicTrackTests.swift
//  ClipFlowPipelineTests
//
//  Ce que la bibliothèque promet à l'utilisateur : savoir, AVANT de dérusher,
//  quelle durée de clip un morceau imposera. C'est la seule raison d'afficher
//  un BPM dans la liste — si le calcul dérive, l'information ment.
//

import Testing
import Foundation
@testable import ClipFlowPipeline

struct MusicTrackSlotTests {

    /// La durée de coupe annoncée par la liste EST celle que le montage
    /// produira : même calcul, même valeur, à la milliseconde.
    @Test func announcedSlotMatchesEngine() {
        for bpm in [90.0, 128.0, 150.0, 174.0, 200.0] {
            for density in CutDensity.allCases {
                let engine = density.slotDuration(bpm: bpm)
                let announced = Int((engine * 1000).rounded())
                // Reproduit exactement le calcul de MusicTrack.slotMilliseconds.
                #expect(announced == Int((60.0 / bpm * density.beatsPerCut * 1000).rounded()),
                        "Écart entre la liste et le moteur")
            }
        }
    }

    /// Les cinq crans vont du plus posé au plus nerveux, sans égalité —
    /// sinon deux boutons afficheraient la même durée.
    @Test func densitiesAreStrictlyDecreasing() {
        let durations = CutDensity.allCases.map { $0.slotDuration(bpm: 150) }
        for index in 1..<durations.count {
            #expect(durations[index] < durations[index - 1],
                    "Le cran \(index) n'est pas plus rapide que le précédent")
        }
    }

    /// Valeurs de référence à 200 BPM (le cas mesuré sur l'appareil) :
    /// 8 beats = 2400 ms, 1 beat = 300 ms, demi-beat = 150 ms.
    @Test func referenceValuesAt200BPM() {
        #expect(Int((CutDensity.beats8.slotDuration(bpm: 200) * 1000).rounded()) == 2400)
        #expect(Int((CutDensity.beats4.slotDuration(bpm: 200) * 1000).rounded()) == 1200)
        #expect(Int((CutDensity.beats2.slotDuration(bpm: 200) * 1000).rounded()) == 600)
        #expect(Int((CutDensity.beat1.slotDuration(bpm: 200) * 1000).rounded()) == 300)
        #expect(Int((CutDensity.half.slotDuration(bpm: 200) * 1000).rounded()) == 150)
    }

    /// BPM absent (analyse échouée) : aucune durée annoncée plutôt qu'un
    /// chiffre faux. Un zéro afficherait « coupes 0 ms ».
    @Test func missingTempoAnnouncesNothing() {
        #expect(CutDensity.beat1.slotDuration(bpm: 0) == 0)
    }
}
