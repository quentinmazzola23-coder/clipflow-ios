//
//  DurationConversionTests.swift
//  ClipFlowPipelineTests
//
//  Conversion durée source ↔ durée finale, et écriture des durées.
//
//  Ces tests portent sur l'option « jusqu'à la fin du rush » : là, ce n'est
//  plus la durée finale qui décide de la longueur prélevée, c'est l'inverse.
//  Si l'aller-retour n'est pas exact, un clip validé à durée fixe se retrouve
//  exporté avec un centième de trop ou de moins — donc une image en plus ou
//  en moins à 60 i/s. Logique PURE : vérifiable sans média, sans appareil.
//

import Testing
import Foundation
import CoreMedia
@testable import ClipFlowPipeline

struct DurationConversionTests {

    /// Aller-retour EXACT pour toutes les durées proposées par l'app :
    /// une sélection ordinaire ne doit jamais dériver d'un centième.
    @Test func roundTripIsExactForEveryPreset() {
        for preset in ExactDuration.presets {
            let source = TimeMath.sourceDuration(final: preset, speed: .half)
            let back = TimeMath.finalDuration(source: source, speed: .half)
            #expect(back.centiseconds == preset.centiseconds,
                    "Aller-retour non exact")
        }
    }

    /// Aller-retour exact sur tout le domaine du choix personnalisé
    /// (0,10 s → 10,00 s, au centième).
    @Test func roundTripIsExactAcrossCustomRange() {
        for centiseconds in stride(from: 10, through: 1000, by: 1) {
            let duration = ExactDuration(centiseconds: centiseconds)
            let source = TimeMath.sourceDuration(final: duration, speed: .half)
            let back = TimeMath.finalDuration(source: source, speed: .half)
            #expect(back.centiseconds == centiseconds, "Dérive sur une durée personnalisée")
        }
    }

    /// Cas réel de « jusqu'à la fin du rush » : une longueur quelconque
    /// prélevée dans le rush, ralentie de moitié, double.
    /// 3,4 s de source à 0,5× → 6,80 s finales.
    @Test func extendedSelectionDoublesAtHalfSpeed() {
        let source = CMTime(value: 34, timescale: 10)
        let final = TimeMath.finalDuration(source: source, speed: .half)
        #expect(final.centiseconds == 680)
    }

    /// Une plage arbitraire issue d'un rush (timescale 600, non divisible)
    /// est arrondie au centième le PLUS PROCHE, jamais tronquée.
    @Test func arbitraryRangeRoundsToNearestHundredth() {
        // 1007/600 s = 1,678333… s de source → 3,356666… s finales → 336 cs.
        let final = TimeMath.finalDuration(source: CMTime(value: 1007, timescale: 600),
                                           speed: .half)
        #expect(final.centiseconds == 336)
    }

    /// Une durée nulle ou négative ne doit pas produire de durée valide :
    /// mieux vaut zéro, que l'appelant refuse, qu'un clip sans image.
    @Test func nonPositiveSourceYieldsZero() {
        #expect(TimeMath.finalDuration(source: .zero, speed: .half).centiseconds == 0)
        #expect(TimeMath.finalDuration(source: CMTime(value: -100, timescale: 600),
                                       speed: .half).centiseconds == 0)
    }

    /// Écriture courte : pas de zéros de fin inutiles dans les menus.
    @Test func labelsAreWrittenShort() {
        #expect(ExactDuration(centiseconds: 100).label == "1 s")
        #expect(ExactDuration(centiseconds: 130).label == "1,3 s")
        #expect(ExactDuration(centiseconds: 150).label == "1,5 s")
        #expect(ExactDuration(centiseconds: 200).label == "2 s")
        #expect(ExactDuration(centiseconds: 125).label == "1,25 s")
        #expect(ExactDuration(centiseconds: 7).label == "0,07 s")
    }

    /// Les durées types demandées : 1 s, 1,3 s, 1,5 s, 2 s — dans cet ordre.
    @Test func presetsAreTheFourExpectedDurations() {
        #expect(ExactDuration.presets.map(\.centiseconds) == [100, 130, 150, 200])
    }
}
