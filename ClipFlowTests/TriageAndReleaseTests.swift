//
//  TriageAndReleaseTests.swift
//  ClipFlowTests
//
//  Navigation de triage (recherche circulaire) et règles de libération
//  des copies sources.
//

import Testing
import Foundation
import SwiftData
@testable import ClipFlow

struct TriageNavigationTests {

    @Test func emptyListReturnsNil() {
        #expect(TriageNavigation.nextUntreatedIndex(after: nil, treated: []) == nil)
    }

    @Test func allTreatedReturnsNil() {
        #expect(TriageNavigation.nextUntreatedIndex(after: 1, treated: [true, true, true]) == nil)
    }

    @Test func startsFromBeginningWhenNoCurrent() {
        #expect(TriageNavigation.nextUntreatedIndex(after: nil, treated: [true, false, false]) == 1)
    }

    @Test func skipsTreatedForward() {
        #expect(TriageNavigation.nextUntreatedIndex(after: 0, treated: [false, true, true, false]) == 3)
    }

    @Test func wrapsAroundCircularly() {
        // Courant = 2, seuls les index 0 et 1 restent non traités → retour à 0.
        #expect(TriageNavigation.nextUntreatedIndex(after: 2, treated: [false, false, true]) == 0)
    }

    @Test func currentIsLastWrapsToStart() {
        #expect(TriageNavigation.nextUntreatedIndex(after: 3, treated: [false, true, true, true]) == 0)
    }

    @Test func currentUntreatedIsNotReturnedFirst() {
        // Le rush courant (non traité) ne doit pas être re-proposé en premier :
        // on cherche à partir du SUIVANT — mais on y revient en dernier recours.
        #expect(TriageNavigation.nextUntreatedIndex(after: 1, treated: [true, false, true]) == 1)
    }
}

@MainActor
struct ReleaseSourcesTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ClipProject.self, Rush.self, Passage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Crée un fichier factice et retourne son nom.
    private func makeFile(in directory: URL, name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
        return name
    }

    @Test func releaseRulesAndDeletion() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let project = ClipProject(name: "Libération")
        context.insert(project)

        let suffix = UUID().uuidString
        var createdURLs: [URL] = []
        defer { createdURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Rush A : source + passage avec plage cachée + proxy → LIBÉRABLE.
        let sourceA = try makeFile(in: StorageManager.sourcesDirectory, name: "srcA-\(suffix).mov")
        let cachedA = try makeFile(in: StorageManager.cachedRangesDirectory, name: "rangeA-\(suffix).mov")
        let proxyA = try makeFile(in: StorageManager.proxiesDirectory, name: "proxyA-\(suffix).mp4")
        createdURLs += [
            StorageManager.url(forSourceRelativePath: sourceA),
            StorageManager.url(forCachedRangeRelativePath: cachedA),
            StorageManager.url(forProxyRelativePath: proxyA),
        ]
        let rushA = Rush()
        rushA.localSourceRelativePath = sourceA
        rushA.proxyRelativePath = proxyA
        rushA.project = project
        context.insert(rushA)
        let passageA = Passage()
        passageA.cachedRangeRelativePath = cachedA
        passageA.rush = rushA
        passageA.project = project
        context.insert(passageA)

        // Rush B : source + passage SANS plage cachée → NON libérable.
        let sourceB = try makeFile(in: StorageManager.sourcesDirectory, name: "srcB-\(suffix).mov")
        createdURLs.append(StorageManager.url(forSourceRelativePath: sourceB))
        let rushB = Rush()
        rushB.localSourceRelativePath = sourceB
        rushB.project = project
        context.insert(rushB)
        let passageB = Passage()
        passageB.rush = rushB
        passageB.project = project
        context.insert(passageB)

        // Rush C : source mais AUCUN passage → NON libérable (rien à préserver,
        // mais libérer empêcherait toute sélection future exportable).
        let sourceC = try makeFile(in: StorageManager.sourcesDirectory, name: "srcC-\(suffix).mov")
        createdURLs.append(StorageManager.url(forSourceRelativePath: sourceC))
        let rushC = Rush()
        rushC.localSourceRelativePath = sourceC
        rushC.project = project
        context.insert(rushC)

        try context.save()

        // Règles.
        let releasable = MediaAvailabilityService.releasableSources(in: project)
        #expect(releasable.count == 1)
        #expect(releasable.first?.rush === rushA)

        // Libération effective.
        let freed = MediaAvailabilityService.releaseSources(in: project)
        #expect(freed > 0)
        #expect(rushA.localSourceRelativePath == nil)
        #expect(!FileManager.default.fileExists(
            atPath: StorageManager.url(forSourceRelativePath: sourceA).path
        ))
        // Proxy conservé → état "source libérée".
        #expect(rushA.availability == .sourceReleased)
        // B et C intacts.
        #expect(rushB.localSourceRelativePath == sourceB)
        #expect(rushC.localSourceRelativePath == sourceC)
        // L'export de A reste possible via sa plage cachée.
        #expect(MediaAvailabilityService.exportSource(for: passageA) != nil)
    }
}
