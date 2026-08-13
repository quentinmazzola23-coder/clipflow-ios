//
//  TimelineRulerTests.swift
//  ClipFlowTests
//
//  Règle graduée de la timeline : le pas doit rendre le niveau de zoom
//  LISIBLE — secondes quand on est large, numéros d'image quand on est fin —
//  sans jamais produire d'étiquettes qui se chevauchent.
//

import Testing
import UIKit
@testable import ClipFlow

struct TimelineRulerTests {

    private let spacing = 64.0   // espacement minimal visé, en points

    /// Vue globale (2 pt/s) : des secondes isolées seraient illisibles, le pas
    /// doit s'élargir jusqu'à une durée qui tient.
    @Test func wideZoomUsesCoarseSecondSteps() {
        let step = TimelineUIView.rulerStep(pointsPerSecond: 2, frameRate: 30)
        guard case .seconds(let value) = step else {
            Issue.record("Pas en images alors que le zoom est très large : \(step)")
            return
        }
        #expect(value * 2 >= spacing)
    }

    /// Zoom de travail (60 pt/s) : la seconde est le bon pas, et surtout pas
    /// des images (elles seraient à 2 pt l'une de l'autre).
    @Test func workingZoomUsesSeconds() {
        let step = TimelineUIView.rulerStep(pointsPerSecond: 60, frameRate: 30)
        #expect(step == .seconds(2))
    }

    /// Zoom maximal (600 pt/s) : une image occupe 20 pt à 30 i/s — la règle
    /// bascule en numéros d'image, ce qui est tout l'intérêt du dézoom fin.
    @Test func tightZoomSwitchesToFrames() {
        let step = TimelineUIView.rulerStep(pointsPerSecond: 600, frameRate: 30)
        guard case .frames(let count, let rate) = step else {
            Issue.record("Pas en secondes alors que le zoom permet les images : \(step)")
            return
        }
        #expect(rate == 30)
        #expect(Double(count) / 30 * 600 >= spacing)
        #expect(count < 30, "Un pas d'une seconde entière doit repasser en secondes")
    }

    /// Cadence inconnue : jamais de numéros d'image inventés.
    @Test func unknownFrameRateNeverProducesFrames() {
        let step = TimelineUIView.rulerStep(pointsPerSecond: 600, frameRate: 0)
        if case .frames = step {
            Issue.record("Numéros d'image produits sans cadence connue")
        }
    }

    /// Quel que soit le zoom, les étiquettes gardent l'espacement minimal.
    @Test func stepAlwaysRespectsMinimumSpacing() {
        for zoom in stride(from: 2.0, through: 600.0, by: 7.0) {
            for rate in [24.0, 30.0, 60.0, 120.0] {
                let step = TimelineUIView.rulerStep(pointsPerSecond: CGFloat(zoom), frameRate: rate)
                let spacingInPoints = step.interval * zoom
                #expect(spacingInPoints >= spacing - 0.001,
                        "Étiquettes trop serrées à \(zoom) pt/s, \(rate) i/s : \(spacingInPoints) pt")
            }
        }
    }

    /// Le compteur repart de zéro à chaque clip : c'est la position DANS le
    /// rush qui intéresse, pas la position dans la timeline entière.
    @Test func labelsAreRelativeToTheClip() {
        #expect(TimelineUIView.rulerLabel(offsetInSegment: 0, step: .seconds(1)) == "0 s")
        #expect(TimelineUIView.rulerLabel(offsetInSegment: 5, step: .seconds(1)) == "5 s")
        #expect(TimelineUIView.rulerLabel(offsetInSegment: 65, step: .seconds(5)) == "1:05")
    }

    /// En mode image, l'étiquette se lit sans calcul mental : seconde + image.
    @Test func frameLabelsCombineSecondAndFrame() {
        let step = TimelineUIView.RulerStep.frames(count: 5, frameRate: 30)
        #expect(TimelineUIView.rulerLabel(offsetInSegment: 2.0, step: step) == "2 s")
        #expect(TimelineUIView.rulerLabel(offsetInSegment: 2 + 7.0 / 30, step: step) == "2s +7i")
    }
}
