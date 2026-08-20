//
//  MusicLibraryTests.swift
//  ClipFlowPipelineTests
//
//  Client de la bibliothèque en ligne (Openverse) : construction d'URL et
//  analyse de réponse. Le réseau n'est PAS testé ici — ce qui l'est, c'est
//  que l'app ne casse jamais sur ce que l'API renvoie réellement, y compris
//  ses entrées incomplètes.
//

import Testing
import Foundation
@testable import ClipFlowPipeline

struct MusicLibraryTests {

    /// L'URL de recherche impose le filtre COMMERCIAL — c'est la promesse
    /// faite à l'utilisateur, elle ne doit pas disparaître dans un remaniement.
    @Test func searchURLEnforcesCommercialLicense() throws {
        let url = try #require(MusicLibraryAPI.searchURL(query: "hardstyle kick"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []
        #expect(components.host == "api.openverse.org")
        #expect(items.contains(URLQueryItem(name: "license_type", value: "commercial")))
        #expect(items.contains(URLQueryItem(name: "q", value: "hardstyle kick")))
        #expect(items.contains(URLQueryItem(name: "category", value: "music")))
    }

    /// Les caractères à encoder (espaces, accents) ne cassent pas l'URL.
    @Test func searchURLSurvivesAccentsAndSpaces() {
        #expect(MusicLibraryAPI.searchURL(query: "montée épique & drop") != nil)
    }

    /// Réponse nominale : les champs utiles sont extraits, la durée est
    /// convertie des millisecondes vers les secondes.
    @Test func parseExtractsFields() throws {
        let json = """
        {"result_count": 1, "results": [
            {"id": "abc-123", "title": "Neon Ride", "creator": "DJ Test",
             "url": "https://cdn.example.org/neon.mp3", "duration": 213000,
             "license": "by", "attribution": "\\"Neon Ride\\" by DJ Test is licensed under CC BY 4.0."}
        ]}
        """
        let results = try MusicLibraryAPI.parse(Data(json.utf8))
        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.title == "Neon Ride")
        #expect(first.creator == "DJ Test")
        #expect(abs(first.durationSeconds - 213) < 0.001)
        #expect(first.license == "by")
        #expect(first.fileURL.absoluteString == "https://cdn.example.org/neon.mp3")
        #expect(first.attribution.contains("CC BY"))
    }

    /// TOLÉRANCE entrée par entrée : un titre sans URL de fichier, ou en
    /// http non sécurisé, est écarté — il ne fait pas échouer la page.
    @Test func entriesWithoutUsableFileAreDropped() throws {
        let json = """
        {"results": [
            {"id": "a", "title": "Sans fichier", "url": null},
            {"id": "b", "title": "Non securise", "url": "http://insecure.example.org/x.mp3"},
            {"id": "c", "title": "Valide", "creator": null,
             "url": "https://cdn.example.org/ok.mp3", "duration": null,
             "license": null, "attribution": null}
        ]}
        """
        let results = try MusicLibraryAPI.parse(Data(json.utf8))
        #expect(results.count == 1)
        let only = try #require(results.first)
        #expect(only.id == "c")
        // Les champs absents ont des valeurs de repli affichables, pas des trous.
        #expect(only.creator == "Inconnu")
        #expect(only.durationSeconds == 0)
    }

    /// Réponse illisible : une erreur EXPLICITE, jamais un tableau vide
    /// silencieux — un tableau vide dirait « aucun résultat », ce qui serait
    /// un mensonge sur une panne.
    @Test func garbageResponseThrows() {
        #expect(throws: MusicLibraryError.self) {
            _ = try MusicLibraryAPI.parse(Data("<html>maintenance</html>".utf8))
        }
    }

    /// Page vide légitime : zéro résultat, zéro erreur.
    @Test func emptyPageYieldsEmptyList() throws {
        let results = try MusicLibraryAPI.parse(Data(#"{"results": []}"#.utf8))
        #expect(results.isEmpty)
    }
}
