//
//  MontagePlanTests.swift
//  ClipFlowPipelineTests
//
//  Placement des clips sur les créneaux : arithmétique CMTime exacte.
//
//  L'exigence centrale : les positions de timeline se TÉLESCOPENT — la fin
//  d'un clip est le début du suivant, au 1/600 s près, quel que soit le
//  nombre de clips. Un cumul d'arrondi d'un centième par clip ferait dériver
//  le montage de la musique en moins d'une minute.
//

import Testing
import Foundation
import CoreMedia
@testable import ClipFlowPipeline

struct MontagePlanTests {

    private let half = RationalSpeed(numerator: 1, denominator: 2)

    /// Créneaux réguliers à 150 BPM (0,4 s), démarrant à `start`.
    private func uniformSlots(count: Int, start: Double = 0,
                              duration: Double = 0.4) -> [BeatSlot] {
        (0..<count).map { index in
            BeatSlot(start: start + Double(index) * duration,
                     duration: duration,
                     section: .drop,
                     beatIndex: index)
        }
    }

    /// Clip généreux : dix secondes de fichier, départ au début.
    private func clip(id: Int, fileSeconds: Double = 10,
                      startSeconds: Double = 0) -> MontageClipCandidate {
        MontageClipCandidate(
            id: id,
            startInFile: CMTime(seconds: startSeconds, preferredTimescale: 600),
            fileDuration: CMTime(seconds: fileSeconds, preferredTimescale: 600),
            speed: half
        )
    }

    /// Chaque clip occupe SON créneau, dans l'ordre, à la durée du créneau.
    @Test func clipsFillSlotsInOrder() {
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: 3),
            clips: [clip(id: 0), clip(id: 1), clip(id: 2)],
            windowStart: 0
        )
        #expect(plan.placements.count == 3)
        #expect(plan.placements.map(\.clipID) == [0, 1, 2])
        #expect(plan.skippedClipIDs.isEmpty)
        for placement in plan.placements {
            #expect(abs(placement.timelineDuration.seconds - 0.4) < 1e-9)
            // 0,5× : la source prélevée vaut la MOITIÉ du créneau.
            #expect(abs(placement.sourceRange.duration.seconds - 0.2) < 1e-9)
        }
    }

    /// Télescopage : sur 200 créneaux, la fin du dernier clip vaut EXACTEMENT
    /// la somme des durées — aucune dérive d'arrondi cumulée.
    @Test func timelineTelescopesWithoutDrift() {
        let count = 200
        let clips = (0..<count).map { clip(id: $0) }
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: count),
            clips: clips,
            windowStart: 0
        )
        #expect(plan.placements.count == count)
        for index in 1..<plan.placements.count {
            let previousEnd = CMTimeAdd(plan.placements[index - 1].timelineStart,
                                        plan.placements[index - 1].timelineDuration)
            #expect(CMTimeCompare(previousEnd, plan.placements[index].timelineStart) == 0,
                    "Dérive à la position \(index)")
        }
    }

    /// La fenêtre décale la musique, pas la timeline : les positions de
    /// timeline démarrent à zéro même quand la fenêtre démarre à 60 s.
    @Test func windowStartShiftsMusicNotTimeline() {
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: 4, start: 60),
            clips: (0..<4).map { clip(id: $0) },
            windowStart: 60
        )
        #expect(CMTimeCompare(plan.placements[0].timelineStart, .zero) == 0)
        #expect(abs(plan.musicStart.seconds - 60) < 1e-9)
    }

    /// RÉGRESSION « amorce noire » : quand la fenêtre demandée tombe ENTRE
    /// deux beats (départ suggéré, arrondi de persistance), l'origine du
    /// montage est le premier créneau — jamais windowStart brut. Sinon le
    /// fichier commençait par du vide avec musique par-dessus.
    @Test func offBeatWindowStartYieldsNoBlackLeadIn() {
        // Créneaux sur les beats 60,0 / 60,4 / 60,8… ; fenêtre demandée 59,85.
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: 4, start: 60),
            clips: (0..<4).map { clip(id: $0) },
            windowStart: 59.85
        )
        // Le premier clip démarre à ZÉRO de la timeline…
        #expect(CMTimeCompare(plan.placements[0].timelineStart, .zero) == 0)
        // …et la musique démarre au premier BEAT, pas à la valeur brute.
        #expect(abs(plan.musicStart.seconds - 60) < 1e-9)
    }

    /// Un clip dont le fichier ne couvre pas le créneau est ÉCARTÉ, jamais
    /// tronqué : le créneau prend le clip suivant.
    @Test func tooShortClipIsSkippedNotTruncated() {
        // Créneau break de 1,2 s → 0,6 s de source requis ; le clip 1 n'a que
        // 0,3 s de fichier disponible.
        let slots = [BeatSlot(start: 0, duration: 1.2, section: .breakdown, beatIndex: 0),
                     BeatSlot(start: 1.2, duration: 1.2, section: .breakdown, beatIndex: 3)]
        let plan = MontagePlanner.plan(
            slots: slots,
            clips: [clip(id: 0, fileSeconds: 0.3), clip(id: 1), clip(id: 2)],
            windowStart: 0
        )
        #expect(plan.skippedClipIDs == [0])
        #expect(plan.placements.map(\.clipID) == [1, 2])
        // Le créneau écarté n'a PAS été perdu : il a pris le clip suivant.
        #expect(CMTimeCompare(plan.placements[0].timelineStart, .zero) == 0)
    }

    /// Le point d'entrée du clip est respecté : la plage source démarre là où
    /// l'utilisateur a validé, pas au début du fichier.
    @Test func sourceRangeStartsAtValidatedEntry() {
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: 1),
            clips: [clip(id: 0, fileSeconds: 10, startSeconds: 3.5)],
            windowStart: 0
        )
        #expect(abs(plan.placements[0].sourceRange.start.seconds - 3.5) < 1e-9)
    }

    /// Plus de créneaux que de clips : le montage S'ARRÊTE au dernier clip.
    @Test func montageStopsWhenClipsRunOut() {
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: 10),
            clips: [clip(id: 0), clip(id: 1)],
            windowStart: 0
        )
        #expect(plan.placements.count == 2)
        #expect(abs(plan.totalDuration.seconds - 0.8) < 1e-9)
    }

    /// Plus de clips que de créneaux : les surnuméraires restent dehors,
    /// sans être comptés comme écartés (ils ne sont pas défectueux).
    @Test func leftoverClipsAreNeitherPlacedNorSkipped() {
        let plan = MontagePlanner.plan(
            slots: uniformSlots(count: 2),
            clips: (0..<5).map { clip(id: $0) },
            windowStart: 0
        )
        #expect(plan.placements.count == 2)
        #expect(plan.skippedClipIDs.isEmpty)
    }

    /// Aucun clip, aucun créneau : plan vide, durée nulle — pas de plantage.
    @Test func degenerateInputsYieldEmptyPlan() {
        let empty = MontagePlanner.plan(slots: [], clips: [], windowStart: 0)
        #expect(empty.placements.isEmpty)
        #expect(CMTimeCompare(empty.totalDuration, .zero) == 0)

        let noClips = MontagePlanner.plan(slots: uniformSlots(count: 3),
                                          clips: [], windowStart: 0)
        #expect(noClips.placements.isEmpty)
    }
}
