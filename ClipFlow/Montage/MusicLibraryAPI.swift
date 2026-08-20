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

/// Résultat d'une recherche : les titres, et par QUELLE source ils sont
/// arrivés — l'utilisateur doit savoir quand le repli a joué.
struct MusicSearchOutcome: Sendable {
    var results: [MusicSearchResult]
    /// nil = Openverse (nominal) ; sinon note à afficher.
    var fallbackNote: String?
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

    /// User-Agent de NAVIGATEUR, pour le second essai Openverse. Leur pare-feu
    /// (Cloudflare) profile le couple UA + empreinte TLS : un UA applicatif
    /// sur l'empreinte TLS d'Apple passe pour un robot sur certains réseaux
    /// (401 constaté sur appareil, 4G ET Wi-Fi, alors que l'API répond 200
    /// ailleurs). Un UA Safari sur cette même empreinte est COHÉRENT — Safari
    /// EST CFNetwork.
    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// Recherche en TROIS lignes de défense — l'utilisateur ne doit jamais se
    /// retrouver sans bibliothèque pour une histoire de pare-feu :
    ///  1. Openverse, UA applicatif (nominal) ;
    ///  2. Openverse, UA navigateur (contourne le filtrage d'UA) ;
    ///  3. Internet Archive (hôte indépendant, sans clé) — avec une note
    ///     visible disant que le repli a joué.
    static func search(query: String, page: Int = 1) async throws -> MusicSearchOutcome {
        guard let url = searchURL(query: query, page: page) else {
            return MusicSearchOutcome(results: [], fallbackNote: nil)
        }
        var lastStatus = 0

        for userAgent in [nil, browserUserAgent] {
            do {
                var openverseRequest = request(for: url)
                if let userAgent {
                    try await Task.sleep(for: .milliseconds(600))
                    openverseRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                }
                let (data, response) = try await URLSession.shared.data(for: openverseRequest)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 { throw MusicLibraryError.rateLimited }
                    guard http.statusCode == 200 else {
                        lastStatus = http.statusCode
                        continue
                    }
                }
                return MusicSearchOutcome(results: try parse(data), fallbackNote: nil)
            } catch let error as MusicLibraryError {
                throw error
            } catch is CancellationError {
                // Recherche ANNULÉE (l'utilisateur a relancé) : propager telle
                // quelle. L'avaler faisait traverser les trois lignes de
                // défense à une tâche morte, qui affichait ensuite une fausse
                // « erreur réseau » par-dessus la recherche suivante.
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                // Vraie erreur réseau sur Openverse : on tente la suite.
            }
        }
        try Task.checkCancellation()

        // Ligne 3 : Internet Archive.
        let archiveResults = try await searchArchive(query: query)
        let reason = lastStatus > 0 ? "code \(lastStatus)" : "réseau injoignable"
        return MusicSearchOutcome(
            results: archiveResults,
            fallbackNote: "Openverse inaccessible (\(reason)) — résultats via Internet Archive. Catalogue différent, licences vérifiées pareillement."
        )
    }

    // MARK: - Internet Archive (repli sans clé)

    /// Recherche archive.org : audio sous licence libre COMMERCIALE
    /// (domaine public, CC0, CC-BY, CC-BY-SA — jamais NC ni ND : un montage
    /// est une œuvre dérivée à usage commercial).
    static func archiveSearchURL(query: String) -> URL? {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")
        // La requête entre dans une expression Lucene : les caractères de
        // syntaxe (parenthèses, deux-points, guillemets…) sont retirés — un
        // titre avec « : » ne doit pas casser la recherche entière.
        let cleaned = query.map { char -> Character in
            "():[]{}^~*?!\\\"".contains(char) ? " " : char
        }
        let sanitized = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard !sanitized.isEmpty else { return nil }
        let q = "(\(sanitized)) AND mediatype:(audio) AND format:(MP3) AND licenseurl:*"
        components?.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "fl[]", value: "licenseurl"),
            URLQueryItem(name: "rows", value: "20"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json"),
        ]
        return components?.url
    }

    /// Une licence est COMMERCIALE si elle est domaine public / CC0 / BY /
    /// BY-SA. Tout ce qui contient nc ou nd est écarté.
    static func isCommercialLicense(_ licenseURL: String) -> Bool {
        let lowered = licenseURL.lowercased()
        guard lowered.contains("creativecommons.org") else { return false }
        if lowered.contains("-nc") || lowered.contains("-nd") { return false }
        return lowered.contains("publicdomain") || lowered.contains("/zero/")
            || lowered.contains("/by/") || lowered.contains("/by-sa/")
            || lowered.contains("/mark/")
    }

    /// Libellé court d'une licence à partir de son URL.
    static func licenseLabel(_ licenseURL: String) -> String {
        let lowered = licenseURL.lowercased()
        if lowered.contains("/zero/") || lowered.contains("publicdomain") { return "cc0" }
        if lowered.contains("/by-sa/") { return "by-sa" }
        if lowered.contains("/by/") { return "by" }
        return "cc"
    }

    private struct ArchiveSearchPage: Decodable {
        struct Response: Decodable { var docs: [ArchiveDoc] }
        var response: Response
    }
    /// `creator` d'archive.org : parfois une chaîne, parfois une liste.
    private struct ArchiveDoc: Decodable {
        var identifier: String?
        var title: String?
        var creator: FlexibleString?
        var licenseurl: String?
    }
    struct FlexibleString: Decodable {
        var value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                value = single
            } else if let list = try? container.decode([String].self) {
                value = list.first ?? ""
            } else {
                value = ""
            }
        }
    }
    private struct ArchiveMetadata: Decodable {
        struct File: Decodable {
            var name: String?
            var format: String?
            var length: String?
        }
        var files: [File]
    }

    static func searchArchive(query: String) async throws -> [MusicSearchResult] {
        guard let url = archiveSearchURL(query: query) else { return [] }
        let (data, response) = try await URLSession.shared.data(for: request(for: url))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MusicLibraryError.badResponse(status: http.statusCode)
        }
        let page: ArchiveSearchPage
        do {
            page = try JSONDecoder().decode(ArchiveSearchPage.self, from: data)
        } catch {
            throw MusicLibraryError.decoding(error.localizedDescription)
        }
        let candidates = page.response.docs.filter {
            isCommercialLicense($0.licenseurl ?? "") && $0.identifier != nil
        }

        // Résolution du FICHIER mp3 de chaque entrée (l'index ne le donne
        // pas) : appels métadonnées en parallèle, entrées sans mp3 écartées.
        return await withTaskGroup(of: MusicSearchResult?.self) { group in
            for doc in candidates.prefix(12) {
                group.addTask {
                    await resolveArchiveItem(doc: doc)
                }
            }
            var results: [MusicSearchResult] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results.sorted { $0.title < $1.title }
        }
    }

    private static func resolveArchiveItem(doc: ArchiveDoc) async -> MusicSearchResult? {
        guard let identifier = doc.identifier,
              let metadataURL = URL(string: "https://archive.org/metadata/\(identifier)") else {
            return nil
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request(for: metadataURL)),
              let metadata = try? JSONDecoder().decode(ArchiveMetadata.self, from: data) else {
            return nil
        }
        // Le premier mp3 de l'entrée — les albums entiers donnent leur 1ʳᵉ piste.
        guard let mp3 = metadata.files.first(where: {
            ($0.name ?? "").lowercased().hasSuffix(".mp3")
        }), let name = mp3.name,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let fileURL = URL(string: "https://archive.org/download/\(identifier)/\(encoded)") else {
            return nil
        }
        let licenseURL = doc.licenseurl ?? ""
        let title = doc.title ?? name
        let creator = doc.creator?.value ?? "Inconnu"
        return MusicSearchResult(
            id: "ia-\(identifier)",
            title: title,
            creator: creator,
            fileURL: fileURL,
            durationSeconds: Double(mp3.length ?? "") ?? 0,
            license: licenseLabel(licenseURL),
            attribution: "\(title) — \(creator) (\(licenseLabel(licenseURL).uppercased()), via Internet Archive, \(licenseURL))"
        )
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
