//
//  NamingAndSortTests.swift
//  ClipFlowTests
//

import Testing
import Foundation
@testable import ClipFlow

struct NamingTests {

    @Test func canonicalName() {
        let name = NamingEngine.makeName(
            orderNumber: 1,
            categories: ["reveal", "grange", "fixe", "statique"]
        )
        #expect(name == "001_reveal_grange_fixe_statique.mov")
    }

    @Test func accentsStripped() {
        let name = NamingEngine.makeName(orderNumber: 2, categories: ["détail", "extérieur"])
        #expect(name == "002_detail_exterieur.mov")
    }

    @Test func duplicateCategoriesRemoved() {
        let name = NamingEngine.makeName(orderNumber: 3, categories: ["fixe", "fixe", "Fixe"])
        #expect(name == "003_fixe.mov")
    }

    @Test func collisionGetsSuffix() {
        let existing: Set<String> = ["004_reveal.mov", "004_reveal_2.mov"]
        let name = NamingEngine.makeName(orderNumber: 4, categories: ["reveal"], existingNames: existing)
        #expect(name == "004_reveal_3.mov")
    }

    @Test func emptyCategoriesFallback() {
        let name = NamingEngine.makeName(orderNumber: 5, categories: [])
        #expect(name == "005.mov")
    }
}

struct ChronoSortTests {

    private func key(asset: Date? = nil, file: Date? = nil,
                     name: String = "a.mov", pick: Int = 0) -> RushSortKey {
        RushSortKey(assetCreationDate: asset, fileCreationDate: file,
                    timecodeSeconds: nil, filename: name, pickOrder: pick)
    }

    @Test func assetDateWinsFirst() {
        let earlier = key(asset: Date(timeIntervalSince1970: 100), name: "z.mov", pick: 9)
        let later = key(asset: Date(timeIntervalSince1970: 200), name: "a.mov", pick: 0)
        #expect(ChronoSort.isOrderedBefore(earlier, later))
        #expect(!ChronoSort.isOrderedBefore(later, earlier))
    }

    @Test func fileDateUsedWhenAssetDateMissing() {
        let earlier = key(file: Date(timeIntervalSince1970: 100), name: "z.mov")
        let later = key(file: Date(timeIntervalSince1970: 200), name: "a.mov")
        #expect(ChronoSort.isOrderedBefore(earlier, later))
    }

    @Test func naturalFilenameOrder() {
        let two = key(name: "IMG_2.mov")
        let ten = key(name: "IMG_10.mov")
        // Tri naturel : IMG_2 avant IMG_10 (pas d'ordre lexicographique naïf).
        #expect(ChronoSort.isOrderedBefore(two, ten))
    }

    @Test func pickOrderIsFinalFallback() {
        let first = key(name: "same.mov", pick: 0)
        let second = key(name: "same.mov", pick: 1)
        #expect(ChronoSort.isOrderedBefore(first, second))
    }

    @Test func fullCascadeSort() {
        let a = key(asset: Date(timeIntervalSince1970: 300), name: "c.mov", pick: 0)
        let b = key(file: Date(timeIntervalSince1970: 100), name: "b.mov", pick: 1)
        let c = key(name: "a.mov", pick: 2)
        let sorted = ChronoSort.sortedIndices([a, b, c])
        // Sans paire de dates comparables au même niveau, le repli descend
        // jusqu'au nom : a.mov < b.mov < c.mov.
        #expect(sorted == [2, 1, 0])
    }
}
