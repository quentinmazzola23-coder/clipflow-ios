//
//  Models.swift
//  ClipFlow
//
//  Modèles SwiftData — strictement locaux, prévus pour migration (schéma versionné
//  par valeurs par défaut ; toute évolution passera par un VersionedSchema).
//

import Foundation
import SwiftData
import CoreMedia

// MARK: - États

/// Disponibilité d'un rush par rapport à Photos / au stockage local.
enum RushAvailability: Int, Codable {
    case unknown = 0
    /// Fichier disponible localement (copie app ou original local).
    case localReady = 1
    /// L'original est dans iCloud, téléchargement nécessaire via le sélecteur Photos.
    case needsICloudDownload = 2
    /// Importation en cours.
    case importing = 3
    /// Prêt pour le travail hors ligne (proxy + source ou plage cachée présents).
    case offlineReady = 4
    /// Source introuvable (élément supprimé de Photos, cache purgé...).
    case unavailable = 5
    /// Copie source libérée volontairement — proxy conservé, passages
    /// exportables via leurs plages cachées.
    case sourceReleased = 6
}

/// Statut éditorial d'un passage.
enum PassageStatus: Int, Codable {
    case principal = 0
    case alternative = 1
    case rejete = 2
}

/// État d'export d'un passage.
enum ExportState: Int, Codable {
    case notExported = 0
    case queued = 1
    case rendering = 2
    case exported = 3
    case failed = 4
}

// MARK: - Projet

@Model
final class ClipProject {
    var name: String = "Nouveau projet"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    // Paramètres de sélection / export.
    /// Durée FINALE (après ralentissement), en centièmes de seconde. 130 = 1,30 s.
    var finalDurationCentiseconds: Int = 130
    /// Vitesse rationnelle : num/den. 1/2 = 0,5×.
    var speedNumerator: Int = 1
    var speedDenominator: Int = 2
    /// Cadence de sortie.
    var exportFPS: Int = 60
    /// Le toucher crée la sélection centrée (true) ou en début (false, défaut).
    var touchAnchorIsCenter: Bool = false
    /// Mode hors-ligne garanti : copie intégrale des sources dans l'app.
    var guaranteedOfflineMode: Bool = false
    /// Lancer automatiquement le rendu d'un passage dès sa validation.
    var autoExportOnValidate: Bool = true
    /// true = proxys légers 240p (économie d'espace) ; false (défaut) =
    /// proxys 720p tout-intra, prévisualisation nette et scrubbing instantané.
    var proxy240p: Bool = false
    /// Conserver l'audio ralenti (non implémenté dans le MVP, exposé pour le schéma).
    var keepSlowedAudio: Bool = false
    /// Codec d'export : "hevc" (défaut), "h264".
    var exportCodec: String = "hevc"

    /// Groupes de catégories configurables, encodés en JSON
    /// [{"name": "type", "options": ["reveal", "détail", ...]}, ...]
    var categoryGroupsJSON: Data = Data()

    /// Compteur de numérotation des exports (001, 002...).
    var nextExportNumber: Int = 1

    @Relationship(deleteRule: .cascade, inverse: \Rush.project)
    var rushes: [Rush] = []

    @Relationship(deleteRule: .cascade, inverse: \Passage.project)
    var passages: [Passage] = []

    init(name: String) {
        self.name = name
        self.categoryGroupsJSON = CategoryGroup.encodeDefaults()
    }

    var finalDuration: ExactDuration { ExactDuration(centiseconds: finalDurationCentiseconds) }

    var categoryGroups: [CategoryGroup] {
        get { CategoryGroup.decode(categoryGroupsJSON) }
        set { categoryGroupsJSON = CategoryGroup.encode(newValue) }
    }

    /// Rushes triés dans l'ordre chronologique établi à l'importation.
    var orderedRushes: [Rush] { rushes.sorted { $0.orderIndex < $1.orderIndex } }

    /// Passages triés par ordre de validation.
    var orderedPassages: [Passage] { passages.sorted { $0.validationIndex < $1.validationIndex } }
}

// MARK: - Rush

@Model
final class Rush {
    /// Position chronologique dans le projet.
    var orderIndex: Int = 0

    /// Identifiant PhotoKit stable, si disponible.
    var assetIdentifier: String?
    var originalFilename: String = ""
    var captureDate: Date?
    /// Date de création lue dans les métadonnées du fichier (repli du tri).
    var fileCreationDate: Date?
    /// Ordre de sélection dans le picker (dernier repli du tri).
    var pickOrder: Int = 0

    // Métadonnées techniques.
    var durationValue: Int64 = 0
    var durationTimescale: Int32 = 600
    var width: Int = 0
    var height: Int = 0
    var nominalFrameRate: Double = 0
    var codec: String = ""
    /// Rotation en degrés (0/90/180/270), issue de la preferredTransform.
    var rotationDegrees: Int = 0
    /// Colorimétrie : "sdr", "hlg", "pq", "appleLog", "dolbyVision", "inconnue".
    var colorimetry: String = "inconnue"
    var is10Bit: Bool = false

    // Stockage.
    /// Chemin relatif de la copie source persistante (Application Support), si copiée.
    var localSourceRelativePath: String?
    /// Chemin relatif du proxy (Caches), si généré.
    var proxyRelativePath: String?
    var availabilityRaw: Int = RushAvailability.unknown.rawValue

    var project: ClipProject?

    @Relationship(deleteRule: .cascade, inverse: \Passage.rush)
    var passages: [Passage] = []

    init() {}

    var duration: CMTime {
        CMTime(value: durationValue, timescale: durationTimescale)
    }

    var availability: RushAvailability {
        get { RushAvailability(rawValue: availabilityRaw) ?? .unknown }
        set { availabilityRaw = newValue.rawValue }
    }
}

// MARK: - Passage (sélection validée)

@Model
final class Passage {
    /// Ordre de validation — détermine l'ordre de relecture et la numérotation.
    var validationIndex: Int = 0

    /// Début de la sélection DANS le rush source (temps source, avant ralenti).
    var startValue: Int64 = 0
    var startTimescale: Int32 = 600

    /// Durée SOURCE de la sélection (redondant avec le projet mais figé à la
    /// validation : changer la durée globale ensuite ne casse pas les passages).
    var sourceDurationValue: Int64 = 0
    var sourceDurationTimescale: Int32 = 600
    /// Durée finale figée (centisecondes) au moment de la validation.
    var finalDurationCentiseconds: Int = 130
    var speedNumerator: Int = 1
    var speedDenominator: Int = 2

    /// Catégories attribuées, format "groupe:option".
    var categories: [String] = []
    var statusRaw: Int = PassageStatus.principal.rawValue

    /// Plage source pleine qualité mise en cache pour export hors-ligne (chemin relatif).
    var cachedRangeRelativePath: String?
    /// Temps du RUSH correspondant au zéro du fichier de plage caché
    /// (le start du passage reste toujours exprimé dans la base du rush).
    var cachedRangeOffsetValue: Int64 = 0
    var cachedRangeOffsetTimescale: Int32 = 600
    var exportStateRaw: Int = ExportState.notExported.rawValue
    var exportedFilename: String?
    var lastExportError: String?

    var rush: Rush?
    var project: ClipProject?

    init() {}

    var start: CMTime { CMTime(value: startValue, timescale: startTimescale) }
    var cachedRangeOffset: CMTime { CMTime(value: cachedRangeOffsetValue, timescale: cachedRangeOffsetTimescale) }
    var sourceDuration: CMTime { CMTime(value: sourceDurationValue, timescale: sourceDurationTimescale) }
    var sourceRange: CMTimeRange { CMTimeRange(start: start, duration: sourceDuration) }

    var status: PassageStatus {
        get { PassageStatus(rawValue: statusRaw) ?? .principal }
        set { statusRaw = newValue.rawValue }
    }

    var exportState: ExportState {
        get { ExportState(rawValue: exportStateRaw) ?? .notExported }
        set { exportStateRaw = newValue.rawValue }
    }

    func setStart(_ time: CMTime) {
        startValue = time.value
        startTimescale = time.timescale
    }
}

// MARK: - Catégories

/// Un groupe de catégories ("type", "lieu"...) avec ses options.
struct CategoryGroup: Codable, Hashable, Identifiable {
    var name: String
    var options: [String]
    var id: String { name }

    static let defaults: [CategoryGroup] = [
        .init(name: "type", options: ["reveal", "détail", "transition"]),
        .init(name: "lieu", options: ["grange", "salon", "cuisine", "extérieur"]),
        .init(name: "mouvement", options: ["fixe", "push-in", "pull-out", "pan-gauche", "pan-droite"]),
        .init(name: "comportement", options: ["statique", "dynamique"]),
    ]

    static func encodeDefaults() -> Data { encode(defaults) }

    static func encode(_ groups: [CategoryGroup]) -> Data {
        (try? JSONEncoder().encode(groups)) ?? Data()
    }

    static func decode(_ data: Data) -> [CategoryGroup] {
        (try? JSONDecoder().decode([CategoryGroup].self, from: data)) ?? defaults
    }
}
