//
//  SelectionModeTests.swift
//  ClipFlowPipelineTests
//
//  Modes de durée d'une sélection. Logique PURE (CoreMedia seul) : vérifiable
//  sur le runner macOS, donc réellement exécutée à chaque poussée — un test
//  qui ne tourne nulle part ne protège de rien.
//

import Testing
import Foundation
import CoreMedia
@testable import ClipFlowPipeline

// MARK: - Mode « jusqu'à la fin du rush »

/// Mode de durée où la LONGUEUR n'est plus imposée : la sélection court du
/// toucher au bout du rush. Sa règle de déplacement diffère donc de celle
/// d'une sélection à durée fixe, et c'est le cœur de ce qui est vérifié ici.
struct OpenEndSelectionTests {

    private let rushDuration = CMTime(value: 10, timescale: 1)   // 10 s
    private let minimum = CMTime(value: 2, timescale: 60)        // 2 images à 60 i/s

    @Test func selectionRunsFromTouchToEndOfRush() throws {
        let range = try SelectionEngine.makeSelectionToEnd(
            touchTime: CMTime(value: 4, timescale: 1),
            rushDuration: rushDuration,
            minimumDuration: minimum
        )
        #expect(CMTimeCompare(range.start, CMTime(value: 4, timescale: 1)) == 0)
        #expect(abs(range.duration.seconds - 6) < 0.0001)
        #expect(abs(CMTimeRangeGetEnd(range).seconds - rushDuration.seconds) < 0.0001)
    }

    /// Un toucher négatif (recalage de la timeline) démarre à zéro, jamais
    /// avant le début du rush.
    @Test func touchBeforeStartIsClampedToZero() throws {
        let range = try SelectionEngine.makeSelectionToEnd(
            touchTime: CMTime(value: -3, timescale: 1),
            rushDuration: rushDuration,
            minimumDuration: minimum
        )
        #expect(CMTimeCompare(range.start, .zero) == 0)
        #expect(abs(range.duration.seconds - 10) < 0.0001)
    }

    /// Toucher trop près de la fin : refus explicite plutôt qu'un clip d'une
    /// seule image.
    @Test func touchTooCloseToEndIsRejected() {
        #expect(throws: SelectionError.self) {
            try SelectionEngine.makeSelectionToEnd(
                touchTime: CMTime(value: 999, timescale: 100),
                rushDuration: rushDuration,
                minimumDuration: minimum
            )
        }
    }

    /// Déplacer la sélection RACCOURCIT ou RALLONGE : la fin reste collée au
    /// bout du rush. C'est la différence avec `move`, qui garde la longueur.
    @Test func movingKeepsEndPinnedToRushEnd() throws {
        let range = try SelectionEngine.makeSelectionToEnd(
            touchTime: CMTime(value: 4, timescale: 1),
            rushDuration: rushDuration,
            minimumDuration: minimum
        )
        let later = SelectionEngine.moveOpenEnd(
            range, by: CMTime(value: 1, timescale: 1),
            rushDuration: rushDuration, minimumDuration: minimum
        )
        #expect(abs(later.start.seconds - 5) < 0.0001)
        #expect(abs(later.duration.seconds - 5) < 0.0001)
        #expect(abs(CMTimeRangeGetEnd(later).seconds - rushDuration.seconds) < 0.0001)

        let earlier = SelectionEngine.moveOpenEnd(
            range, by: CMTime(value: -2, timescale: 1),
            rushDuration: rushDuration, minimumDuration: minimum
        )
        #expect(abs(earlier.start.seconds - 2) < 0.0001)
        #expect(abs(earlier.duration.seconds - 8) < 0.0001)
    }

    /// Le déplacement ne peut ni sortir du rush, ni réduire la sélection en
    /// dessous du minimum exploitable.
    @Test func movingIsBoundedOnBothSides() throws {
        let range = try SelectionEngine.makeSelectionToEnd(
            touchTime: CMTime(value: 4, timescale: 1),
            rushDuration: rushDuration,
            minimumDuration: minimum
        )
        let far = SelectionEngine.moveOpenEnd(
            range, by: CMTime(value: 99, timescale: 1),
            rushDuration: rushDuration, minimumDuration: minimum
        )
        #expect(CMTimeCompare(far.duration, minimum) >= 0)
        #expect(abs(CMTimeRangeGetEnd(far).seconds - rushDuration.seconds) < 0.0001)

        let before = SelectionEngine.moveOpenEnd(
            range, by: CMTime(value: -99, timescale: 1),
            rushDuration: rushDuration, minimumDuration: minimum
        )
        #expect(CMTimeCompare(before.start, .zero) == 0)
        #expect(abs(before.duration.seconds - 10) < 0.0001)
    }

    /// Un rush plus court que le minimum ne produit aucune sélection, même
    /// touché à son tout début.
    @Test func rushShorterThanMinimumYieldsNothing() {
        #expect(throws: SelectionError.self) {
            try SelectionEngine.makeSelectionToEnd(
                touchTime: .zero,
                rushDuration: CMTime(value: 1, timescale: 60),
                minimumDuration: minimum
            )
        }
    }
}
