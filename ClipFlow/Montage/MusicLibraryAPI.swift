//
//  MusicLibraryAPI.swift
//  ClipFlow
//
//  BIBLIOTHÈQUE MUSICALE EN LIGNE — client Openverse (openverse.org).
//
//  Pourquoi Openverse : c'est le seul agrégateur SÉRIEUX interrogeable sans
//  compte ni clé (accès anonyme : 20 recherches/minute, 200/jour — large pour
//  un usage personnel). Il fédère notamment Jamendo et Freesound, et son
//  filtre `license_type=commercial` ne renvoie QUE des titres dont la licence
//  autorise l'usage commercial (CC0, CC-BY, CC-BY-SA). Les API des banques
//  payantes (Epidemic Sound, Artlist) sont réservées aux partenaires sous
//  contrat — hors de portée d'une app personnelle.
//
//  ATTENTION LICENCE : CC-BY exige de CRÉDITER l'auteur. Le champ
//  `attribution` livré par l'API est stocké avec le projet et montré à
//  l'utilisateur — à coller dans la description de la vidéo publiée.
//
//  Ce fichier est PUR (Foundation seul) : construction d'URL et analyse de
//  réponse testables en CI sans réseau.
//

import Foundation

/// Un titre de la bibliothèque en ligne.
struct MusicSearchResult: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var creator: String
    /// URL du FICHIER audio (téléchargement direct).
    var fileURL: URL
    /// Durée en secondes (0 si inconnue).
    var durationSeconds: Double
    /// Licence courte ("cc0", "by", "by-sa"...).
    var license: String
    /// Crédit prêt à coller, fourni par l'API.
    var attribution: String
}

enum MusicLibraryError: Error, LocalizedError {
    case badResponse(status: Int)
    case rateLimited
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            if status == 401 || status == 403 {
                return "La bibliothèque (Openverse) a refusé la connexion (code \(status)) malgré une nouvelle tentative automatique. "
                    + "Leur pare-feu bloque parfois certains réseaux mobiles : essayez en Wi-Fi. "
                    + "Si ça échoue aussi en Wi-Fi, signalez-le — ce n'est pas une erreur de votre part."
            }
            return "La bibliothèque a répondu avec le code \(status) malgré une nouvelle tentative. "
                + "Le service Openverse est probablement en panne passagère — réessayez plus tard, ce n'est pas une erreur de votre part."
        case .rateLimited:
            return "Limite de recherches atteinte (20 par minute en accès libre). Attendez une minute puis réessayez — ce n'est pas un bug."
        case .decoding(let details):
            return "Réponse de la bibliothèque illisible (\(details)) — le format de l'API a peut-être changé, signalez-le."
        }
    }
}

enum MusicLibraryAPI {

    static let pageSize = 25

    /// Requête IDENTIFIÉE, comme la documentation Openverse le demande : leur
    /// pare-feu rejette en 401/403 certains clients au User-Agent générique
    /// (celui de CFNetwork en fait partie selon le réseau traversé). Constaté
    /// sur appareil : 401 en 4G avec l'UA par défaut, 200 avec un UA nommé.
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("ClipFlow-iOS/1.0 (github.com/quentinmazzola23-coder/clipflow-ios)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    /// Recherche avec UNE retentative automatique : les rejets du pare-feu
    /// Openverse (401/403) et les erreurs passagères (5xx) se résolvent le
    /// plus souvent au second essai — l'utilisateur n'a pas à le faire lui-même.
    static func search(query: String, page: Int = 1) async throws -> [MusicSearchResult] {
        guard let url = searchURL(query: query, page: page) else { return [] }
        var lastStatus = 0
        for attempt in 0..<2 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(1500))
            }
            let (data, response) = try await URLSession.shared.data(for: request(for: url))
            guard let http = response as? HTTPURLResponse else {
                return try parse(data)
            }
            switch http.statusCode {
            case 200:
                return try parse(data)
            case 429:
                throw MusicLibraryError.rateLimited
            default:
                lastStatus = http.statusCode
                continue
            }
        }
        throw MusicLibraryError.badResponse(status: lastStatus)
    }

    /// URL de recherche : uniquement des titres à licence COMMERCIALE.
    static func searchURL(query: String, page: Int = 1) -> URL? {
        var components = URLComponents(string: "https://api.openverse.org/v1/audio/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "license_type", value: "commercial"),
            URLQueryItem(name: "category", value: "music"),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        return components?.url
    }

    /// Analyse la réponse JSON. TOLÉRANTE entrée par entrée : un titre sans
    /// URL de fichier est écarté, il ne fait pas échouer la page entière.
    static func parse(_ data: Data) throws -> [MusicSearchResult] {
        let page: RawPage
        do {
            page = try JSONDecoder().decode(RawPage.self, from: data)
        } catch {
            throw MusicLibraryError.decoding(error.localizedDescription)
        }
        return page.results.compactMap { raw in
            guard let id = raw.id,
                  let urlString = raw.url, let fileURL = URL(string: urlString),
                  fileURL.scheme == "https" else { return nil }
            return MusicSearchResult(
                id: id,
                title: raw.title ?? "Sans titre",
                creator: raw.creator ?? "Inconnu",
                fileURL: fileURL,
                durationSeconds: Double(raw.duration ?? 0) / 1000,
                license: raw.license ?? "?",
                attribution: raw.attribution ?? ""
            )
        }
    }

    // MARK: - Schéma brut Openverse (tout optionnel : tolérance maximale)

    private struct RawPage: Decodable {
        var results: [RawResult]
    }

    private struct RawResult: Decodable {
        var id: String?
        var title: String?
        var creator: String?
        var url: String?
        /// Durée en MILLISECONDES chez Openverse.
        var duration: Int?
        var license: String?
        var attribution: String?
    }
}
