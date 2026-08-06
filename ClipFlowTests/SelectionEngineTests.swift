//
//  SelectionEngineTests.swift
//  ClipFlowTests
//

import Testing
import CoreMedia
@testable import ClipFlow

struct SelectionEngineTests {

    private let sourceDuration = CMTime(value: 13, timescale: 20) // 0,65 s
    private let rushDuration = CMTime(value: 10, timescale: 1)    // 10 s

    @Test func touchIsStartByDefault() throws {
        let range = try SelectionEngine.makeSelection(
            touchTime: CMTime(value: 2, timescale: 1),
            sourceDuration: sourceDuration,
            rushDuration: rushDuration,
            anchorCenter: false
        )
        #expect(CMTimeCompare(range.start, CMTime(value: 2, timescale: 1)) == 0)
        #expect(CMTimeCompare(range.duration, sourceDuration) == 0)
    }

    @Test func touchAsCenterOption() throws {
        let range = try SelectionEngine.makeSelection(
            touchTime: CMTime(value: 2, timescale: 1),
            sourceDuration: sourceDuration,
            rushDuration: rushDuration,
            anchorCenter: true
        )
        // Début = 2 − 0,325 = 1,675 s.
        #expect(abs(range.start.seconds - 1.675) < 1e-9)
        #expect(CMTimeCompare(range.duration, sourceDuration) == 0)
    }

    @Test func selectionClampedAtRushEnd() throws {
        let range = try SelectionEngine.makeSelection(
            touchTime: CMTime(value: 99, timescale: 10), // 9,9 s — déborde
            sourceDuration: sourceDuration,
            rushDuration: rushDuration,
            anchorCenter: false
        )
        // Recalée : fin = durée du rush, durée inchangée.
        #expect(abs(range.end.seconds - 10.0) < 1e-9)
        #expect(CMTimeCompare(range.duration, sourceDuration) == 0)
    }

    @Test func selectionClampedAtRushStart() throws {
        let range = try SelectionEngine.makeSelection(
            touchTime: .zero,
            sourceDuration: sourceDuration,
            rushDuration: rushDuration,
            anchorCenter: true
        )
        #expect(CMTimeCompare(range.start, .zero) == 0)
    }

    @Test func rushTooShortThrowsClearError() {
        #expect(throws: SelectionError.self) {
            _ = try SelectionEngine.makeSelection(
                touchTime: .zero,
                sourceDuration: sourceDuration,
                rushDuration: CMTime(value: 1, timescale: 2), // 0,5 s < 0,65 s
                anchorCenter: false
            )
        }
    }

    @Test func moveKeepsDurationAndClamps() {
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: sourceDuration)
        let moved = SelectionEngine.move(
            range, by: CMTime(value: 100, timescale: 1), rushDuration: rushDuration
        )
        #expect(CMTimeCompare(moved.duration, sourceDuration) == 0)
        #expect(abs(moved.end.seconds - 10.0) < 1e-9)

        let movedBack = SelectionEngine.move(
            range, by: CMTime(value: -100, timescale: 1), rushDuration: rushDuration
        )
        #expect(CMTimeCompare(movedBack.start, .zero) == 0)
    }

    @Test func nudgeByOneFrameAt60fps() {
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: sourceDuration)
        let frameDuration = CMTime(value: 1, timescale: 60)
        let nudged = SelectionEngine.nudge(
            range, frames: 1, frameDuration: frameDuration, rushDuration: rushDuration
        )
        let expected = CMTimeAdd(CMTime(value: 1, timescale: 1), frameDuration)
        #expect(CMTimeCompare(nudged.start, expected) == 0)

        let back = SelectionEngine.nudge(
            nudged, frames: -1, frameDuration: frameDuration, rushDuration: rushDuration
        )
        #expect(CMTimeCompare(back.start, range.start) == 0)
    }
}
