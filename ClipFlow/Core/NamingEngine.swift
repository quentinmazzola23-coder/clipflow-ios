//
//  NamingEngine.swift
//  ClipFlow
//
//  Génération des noms d'export : `001_reveal_grange_fixe_statique.mov`.
//  Logique pure — testable.
//

import Foundation

struct NamingRules: Codable, Hashable, Sendable {
    var includeOrderNumber: Bool = true
    var orderNumberDigits: Int = 3
    var includeDate: Bool = false
    var includeOriginalName: Bool = false
    var separator: String = "_"
    var stripAccents: Bool = true
    var fileExtension: String = "mov"

    static let `default` = NamingRules()
}

enum NamingEngine {

    /// Construit le nom d'un export.
    ///
    /// - Parameters:
    ///   - orderNumber: numéro d'ordre (1 → "001").
    ///   - categories: valeurs de catégories dans l'ordre des groupes
    ///     (ex. ["reveal", "grange", "fixe", "statique"]).
    ///   - originalName: nom original du rush (optionnel selon règles).
    ///   - date: date à inclure si demandé.
    ///   - existingNames: noms déjà utilisés — collision → suffixe -2, -3...
    static func makeName(orderNumber: Int,
                         categories: [String],
                         originalName: String? = nil,
                         date: Date? = nil,
                         rules: NamingRules = .default,
                         existingNames: Set<String> = []) -> String {
        var parts: [String] = []

        if rules.includeOrderNumber {
            parts.append(String(format: "%0\(rules.orderNumberDigits)d", orderNumber))
        }
        if rules.includeDate, let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "fr_FR")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            parts.append(formatter.string(from: date))
        }
        if rules.includeOriginalName, let originalName, !originalName.isEmpty {
            let stem = (originalName as NSString).deletingPathExtension
            parts.append(sanitize(stem, rules: rules))
        }
        // Catégories, dédupliquées en conservant l'ordre.
        var seen = Set<String>()
        for category in categories {
            let cleaned = sanitize(category, rules: rules)
            guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            parts.append(cleaned)
        }

        var base = parts.joined(separator: rules.separator)
        if base.isEmpty { base = "clip" }

        // Collision : suffixe incrémental.
        var candidate = "\(base).\(rules.fileExtension)"
        var attempt = 2
        while existingNames.contains(candidate) {
            candidate = "\(base)\(rules.separator)\(attempt).\(rules.fileExtension)"
            attempt += 1
        }
        return candidate
    }

    /// Nettoie un segment : accents (option), minuscules, caractères sûrs uniquement.
    static func sanitize(_ input: String, rules: NamingRules = .default) -> String {
        var text = input.lowercased()
        if rules.stripAccents {
            text = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let mapped = text.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) { return Character(scalar) }
            if scalar == " " || scalar == "_" { return "-" }
            return "\u{0}" // marqueur de suppression
        }
        return String(mapped.filter { $0 != "\u{0}" })
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
