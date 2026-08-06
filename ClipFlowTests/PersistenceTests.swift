//
//  PersistenceTests.swift
//  ClipFlowTests
//
//  Persistance SwiftData en mémoire : insertion, relations, relecture.
//

import Testing
import SwiftData
import CoreMedia
@testable import ClipFlow

@MainActor
struct PersistenceTests {

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ClipProject.self, Rush.self, Passage.self,
            configurations: configuration
        )
    }

    @Test func projectRoundTrip() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let project = ClipProject(name: "Test")
        project.finalDurationCentiseconds = 130
        context.insert(project)

        let rush = Rush()
        rush.orderIndex = 0
        rush.originalFilename = "IMG_0001.mov"
        rush.durationValue = 600 * 8
        rush.durationTimescale = 600
        rush.project = project
        context.insert(rush)

        let passage = Passage()
        passage.validationIndex = 0
        passage.setStart(CMTime(value: 1200, timescale: 600)) // 2 s
        passage.sourceDurationValue = 13
        passage.sourceDurationTimescale = 20
        passage.categories = ["type:reveal", "lieu:grange"]
        passage.rush = rush
        passage.project = project
        context.insert(passage)
        try context.save()

        let projects = try context.fetch(FetchDescriptor<ClipProject>())
        #expect(projects.count == 1)
        let fetched = try #require(projects.first)
        #expect(fetched.rushes.count == 1)
        #expect(fetched.passages.count == 1)

        let fetchedPassage = try #require(fetched.passages.first)
        #expect(abs(fetchedPassage.start.seconds - 2.0) < 1e-9)
        #expect(abs(fetchedPassage.sourceDuration.seconds - 0.65) < 1e-9)
        #expect(fetchedPassage.categories.contains("lieu:grange"))
        #expect(fetchedPassage.rush === fetched.rushes.first)
    }

    @Test func cascadeDeleteRemovesChildren() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let project = ClipProject(name: "À supprimer")
        context.insert(project)
        let rush = Rush()
        rush.project = project
        context.insert(rush)
        let passage = Passage()
        passage.rush = rush
        passage.project = project
        context.insert(passage)
        try context.save()

        context.delete(project)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Rush>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Passage>()).isEmpty)
    }

    @Test func categoryGroupsEncodeDecode() {
        let groups = [CategoryGroup(name: "essai", options: ["a", "b"])]
        let data = CategoryGroup.encode(groups)
        let decoded = CategoryGroup.decode(data)
        #expect(decoded == groups)
    }
}
