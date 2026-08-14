//
//  MotionAnalyzerTests.swift
//  ClipFlowTests
//
//  Sélection des moments forts. Toute la logique de décision est PURE : elle
//  se vérifie sans décoder une seule vidéo, donc sans appareil.
//

import Testing
import Foundation
@testable import ClipFlow

struct MotionPeakPickingTests {

    /// Suite d'échantillons à énergie constante, avec des pics injectés.
    private func samples(count: Int,
                         base: Double = 10,
                         noise: Double = 0,
                         peaks: [Int: Double] = [:]) -> [MotionSample] {
        (0..<count).map { index in
            // Bruit déterministe : un test qui dépend du hasard ne prouve rien.
            let wobble = noise == 0 ? 0 : noise * sin(Double(index) * 1.7)
            let energy = (peaks[index] ?? base) + wobble
            return MotionSample(time: Double(index) / MotionAnalyzer.samplesPerSecond, energy: energy)
        }
    }

    /// Mouvement parfaitement régulier : RIEN ne se détache. C'est le cas d'un
    /// POV à vitesse constante — proposer des moments au hasard serait pire
    /// que ne rien proposer.
    @Test func steadyMotionYieldsNoPeak() {
        let found = MotionAnalyzer.peaks(from: samples(count: 120), minimumSpacing: 0.65)
        #expect(found.isEmpty)
    }

    /// Un pic franc au milieu d'un régime calme est retenu, au bon instant.
    @Test func isolatedBurstIsFound() {
        let series = samples(count: 120, base: 10, peaks: [60: 90])
        let found = MotionAnalyzer.peaks(from: series, minimumSpacing: 0.65)
        #expect(found.count == 1)
        let expected = 60.0 / MotionAnalyzer.samplesPerSecond
        #expect(abs((found.first?.time ?? -1) - expected) < 0.01)
    }

    /// Le score EST relatif au régime local : le même pic absolu compte moins
    /// dans un rush déjà agité. C'est ce qui évite de tout proposer sur une
    /// séquence rapide de bout en bout.
    @Test func scoreIsRelativeToLocalRegime() {
        let calm = MotionAnalyzer.peaks(
            from: samples(count: 120, base: 10, noise: 1, peaks: [60: 60]), minimumSpacing: 0.65
        )
        let agitated = MotionAnalyzer.peaks(
            from: samples(count: 120, base: 45, noise: 12, peaks: [60: 95]), minimumSpacing: 0.65
        )
        // Aucune proposition parasite de part et d'autre : c'est ce que le
        // seuil de 0,6 laissait passer (un frisson de bruit obtenait 1,1).
        #expect(calm.count == 1, "Propositions parasites (calme) : \(calm.map(\.time))")
        #expect(agitated.count == 1, "Propositions parasites (agité) : \(agitated.map(\.time))")

        let calmScore = calm.first?.score ?? 0
        let agitatedScore = agitated.first?.score ?? 0
        #expect(calmScore > agitatedScore,
                "Écart identique (+50) : score calme \(calmScore), agité \(agitatedScore)")
    }

    /// Du bruit SEUL, sans aucun événement : rien ne doit être proposé.
    /// C'est la contre-épreuve directe du défaut mesuré par la CI.
    @Test func noiseAloneYieldsNoPeak() {
        let found = MotionAnalyzer.peaks(
            from: samples(count: 200, base: 30, noise: 6), minimumSpacing: 0.65
        )
        #expect(found.isEmpty, "Le bruit seul produit des moments : \(found.map(\.score))")
    }

    /// Deux propositions ne doivent JAMAIS se chevaucher : elles produiraient
    /// deux clips quasi identiques.
    @Test func peaksNeverOverlap() {
        // Trois pics rapprochés (0,08 s d'écart) : un seul doit survivre.
        let series = samples(count: 120, base: 8, peaks: [60: 80, 61: 78, 62: 76])
        let spacing = 0.65
        let found = MotionAnalyzer.peaks(from: series, minimumSpacing: spacing)
        #expect(found.count == 1)

        for index in 1..<max(found.count, 1) {
            #expect(found[index].time - found[index - 1].time >= spacing)
        }
    }

    /// Pics bien séparés : tous retenus, et rendus dans l'ordre du rush
    /// (l'utilisateur parcourt sa timeline de gauche à droite).
    @Test func distantPeaksAreAllKeptAndOrdered() {
        let series = samples(count: 240, base: 8, peaks: [40: 70, 120: 75, 200: 72])
        let found = MotionAnalyzer.peaks(from: series, minimumSpacing: 0.65)
        #expect(found.count == 3)
        #expect(found == found.sorted { $0.time < $1.time })
    }

    /// Le plafond protège l'utilisateur : au-delà, ce n'est plus une
    /// proposition mais une liste à trier — exactement ce qu'on lui épargne.
    @Test func countIsCapped() {
        var injected: [Int: Double] = [:]
        for index in stride(from: 20, to: 400, by: 20) { injected[index] = 90 }
        let series = samples(count: 420, base: 8, peaks: injected)
        let found = MotionAnalyzer.peaks(from: series, minimumSpacing: 0.65, maximumCount: 5)
        #expect(found.count == 5)
    }

    /// Une scène totalement immobile ne doit pas transformer le moindre
    /// frémissement en « moment fort » : sans plancher, une agitation nulle
    /// rendrait le score infini.
    @Test func perfectlyStillSceneIsNotAmplified() {
        var series = samples(count: 120, base: 0)
        series[60] = MotionSample(time: series[60].time, energy: 0.5)
        let found = MotionAnalyzer.peaks(from: series, minimumSpacing: 0.65)
        #expect(found.isEmpty, "Un frémissement de 0,5 niveau ne fait pas un moment fort")
    }

    /// Trop peu d'échantillons : aucune référence fiable, donc aucune
    /// proposition — plutôt que des suggestions tirées de rien.
    @Test func tooFewSamplesYieldNothing() {
        #expect(MotionAnalyzer.peaks(from: samples(count: 3), minimumSpacing: 0.65).isEmpty)
    }
}
