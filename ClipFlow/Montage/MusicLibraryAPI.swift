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
            return "La bibliothèque a répondu avec le code \(status). "
                + "Si cela persiste, le service Openverse est peut-être en panne — ce n'est pas une erreur de votre part."
        case .rateLimited:
            return "Limite de recherches atteinte (20 par minute en accès libre). Attendez une minute puis réessayez — ce n'est pas un bug."
        case .decoding(let details):
            return "Réponse de la bibliothèque illisible (\(details)) — le format de l'API a peut-être changé, signalez-le."
        }
    }
}

enum MusicLibraryAPI {

    static let pageSize = 25

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
