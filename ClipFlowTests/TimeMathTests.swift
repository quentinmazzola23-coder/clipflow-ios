//
//  TimeMathTests.swift
//  ClipFlowTests
//
//  Calculs temporels exacts : durée source, nombre d'images, plan de rendu.
//

import Testing
import CoreMedia
@testable import ClipFlow

struct TimeMathTests {

    // MARK: Durée source

    @Test func sourceDurationHalfSpeed_1_3s() {
        let duration = TimeMath.sourceDuration(
            final: ExactDuration(centiseconds: 130),
            speed: .half
        )
        // 1,3 s à 0,5× → 0,65 s exactement (13/20 s).
        #expect(CMTimeCompare(duration, CMTime(value: 13, timescale: 20)) == 0)
        #expect(abs(duration.seconds - 0.65) < 1e-12)
    }

    @Test func sourceDurationHalfSpeed_1_5s() {
        let duration = TimeMath.sourceDuration(
            final: ExactDuration(centiseconds: 150),
            speed: .half
        )
        #expect(abs(duration.seconds - 0.75) < 1e-12)
    }

    // MARK: Nombre d'images

    @Test func frameCount78For1_3sAt60fps() {
        let (count, exact) = TimeMath.outputFrameCount(final: ExactDuration(centiseconds: 130), fps: 60)
        #expect(count == 78)
        #expect(exact)
    }

    @Test func frameCount90For1_5sAt60fps() {
        let (count, exact) = TimeMath.outputFrameCount(final: ExactDuration(centiseconds: 150), fps: 60)
        #expect(count == 90)
        #expect(exact)
    }

    @Test func frameCountInexactCaseIsFlagged() {
        // 1,25 s à 30 fps = 37,5 images → inexact, arrondi à 38.
        let (count, exact) = TimeMath.outputFrameCount(final: ExactDuration(centiseconds: 125), fps: 30)
        #expect(count == 38)
        #expect(!exact)
    }

    // MARK: Timestamps

    @Test func outputPTSIsExactRational() {
        let pts = TimeMath.outputPTS(frameIndex: 77, fps: 60)
        #expect(pts.value == 77 && pts.timescale == 60)
    }

    @Test func sourceTimeMapping() {
        // Image de sortie 10 à 60 fps, 0,5×, départ 0,2 s :
        // t = 0,2 + 10/120 = 0,2 + 1/12 s.
        let time = TimeMath.sourceTime(
            forOutputFrame: 10, fps: 60, speed: .half,
            selectionStart: CMTime(value: 1, timescale: 5)
        )
        let expected = CMTimeAdd(CMTime(value: 1, timescale: 5), CMTime(value: 1, timescale: 12))
        #expect(CMTimeCompare(time, expected) == 0)
    }

    // MARK: Plan de rendu

    /// Source 60 fps ralentie 0,5× vers 60 fps : une image interpolée (phase 0,5)
    /// entre chaque paire d'images sources, en alternance stricte.
    @Test func planAlternatesCopyAndInterpolationFor60fpsSource() throws {
        let sourcePTS = (0...80).map { CMTime(value: CMTimeValue($0), timescale: 60) }
        let start = CMTime(value: 12, timescale: 60) // 0,2 s
        let plan = try FramePlanner.plan(
            sourcePTS: sourcePTS, selectionStart: start,
            outputFrameCount: 78, fps: 60, speed: .half
        )
        #expect(plan.count == 78)
        var copies = 0, interpolations = 0
        for (index, entry) in plan.enumerated() {
            switch entry {
            case .copy:
                #expect(index % 2 == 0)
                copies += 1
            case .interpolate(_, _, let phase):
                #expect(index % 2 == 1)
                #expect(abs(phase - 0.5) < 1e-4)
                interpolations += 1
            }
        }
        #expect(copies == 39)
        #expect(interpolations == 39)
    }

    /// Source 120 fps ralentie 0,5× vers 60 fps : chaque timestamp final tombe
    /// exactement sur une image source — AUCUNE interpolation générée.
    @Test func planUsesOnlyCopiesFor120fpsSource() throws {
        let sourcePTS = (0...200).map { CMTime(value: CMTimeValue($0), timescale: 120) }
        let plan = try FramePlanner.plan(
            sourcePTS: sourcePTS, selectionStart: .zero,
            outputFrameCount: 78, fps: 60, speed: .half
        )
        #expect(plan.allSatisfy { if case .copy = $0 { return true } ; return false })
    }

    /// Sélection collée à la FIN du rush : le dernier timestamp final dépasse
    /// la dernière image source d'une fraction d'intervalle — la dernière
    /// image est DUPLIQUÉE (tolérance 1,5 intervalle), pas d'échec.
    @Test func planDuplicatesLastFrameAtRushEnd() throws {
        // Rush 1 s à 60 fps : PTS 0..59/60. Sélection 0,65 s finissant à 1,0 s
        // (start 0,35 s). Dernier target = 0,35 + 77/120 ≈ 0,9917 s, au-delà
        // du dernier PTS (59/60 ≈ 0,9833) de 1/120 s.
        let sourcePTS = (0..<60).map { CMTime(value: CMTimeValue($0), timescale: 60) }
        let start = CMTime(value: 7, timescale: 20) // 0,35 s
        let plan = try FramePlanner.plan(
            sourcePTS: sourcePTS, selectionStart: start,
            outputFrameCount: 78, fps: 60, speed: .half
        )
        #expect(plan.count == 78)
        #expect(plan.last == .copy(sourceIndex: 59))
    }

    /// Sélection sortant de la plage décodée → erreur claire, pas de silence.
    @Test func planThrowsWhenSourceTooShort() {
        let sourcePTS = (0...10).map { CMTime(value: CMTimeValue($0), timescale: 60) }
        #expect(throws: FramePlanError.self) {
            _ = try FramePlanner.plan(
                sourcePTS: sourcePTS, selectionStart: .zero,
                outputFrameCount: 78, fps: 60, speed: .half
            )
        }
    }
}

/// Correctif 7 — PTS de destination des images interpolées.
///
/// L'ancien calcul arrondissait au timescale SOURCE : à 600 (iPhone) les
/// phases 0,25/0,50/0,75 restaient distinctes, mais à un timescale grossier
/// (≤ 100, cas des réencodages Photos) elles retombaient sur la MÊME valeur —
/// PTS dupliqués ou décroissants, sans la moindre erreur, avec des images
/// fausses à l'arrivée. La base fixe 1/90000 rend ce cas impossible.
struct InterpolatedPTSTests {

    /// Reproduit le calcul du moteur (même formule, sans VideoToolbox).
    private func destinationPTS(previous: CMTime, next: CMTime, phases: [Float]) -> [CMTime] {
        let ptsTimescale: CMTimeScale = 90_000
        let base = CMTimeConvertScale(previous, timescale: ptsTimescale, method: .roundHalfAwayFromZero)
        let span = CMTimeConvertScale(CMTimeSubtract(next, previous),
                                      timescale: ptsTimescale, method: .roundHalfAwayFromZero)
        return phases.map { CMTimeAdd(base, CMTimeMultiplyByFloat64(span, multiplier: Float64($0))) }
    }

    /// Cas qui cassait : source à 30 i/s exprimée au timescale 30. L'intervalle
    /// vaut 1/30 ; arrondi à ce timescale, les trois phases donnaient 0.
    @Test func coarseSourceTimescaleStillYieldsDistinctPTS() {
        let previous = CMTime(value: 3, timescale: 30)
        let next = CMTime(value: 4, timescale: 30)
        let stamps = destinationPTS(previous: previous, next: next, phases: [0.25, 0.5, 0.75])
        for index in 1..<stamps.count {
            #expect(CMTimeCompare(stamps[index], stamps[index - 1]) > 0,
                    "PTS non strictement croissants : \(stamps.map(\.seconds))")
        }
        #expect(CMTimeCompare(stamps[0], previous) > 0)
        #expect(CMTimeCompare(stamps[stamps.count - 1], next) < 0)
    }

    /// Timescale fin (600, cas iPhone) : le comportement ne régresse pas.
    @Test func fineSourceTimescaleRemainsCorrect() {
        let previous = CMTime(value: 60, timescale: 600)
        let next = CMTime(value: 80, timescale: 600)
        let stamps = destinationPTS(previous: previous, next: next, phases: [0.25, 0.5, 0.75])
        #expect(abs(stamps[1].seconds - 0.11666) < 0.001)
        for index in 1..<stamps.count {
            #expect(CMTimeCompare(stamps[index], stamps[index - 1]) > 0)
        }
    }
}
