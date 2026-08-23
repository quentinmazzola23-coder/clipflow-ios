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
import CoreGraphics

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

    /// Le sélecteur de rushes s'est-il déjà ouvert TOUT SEUL pour ce projet ?
    ///
    /// Persisté sur le projet, pas dans un état de vue : le drapeau de session
    /// se réarmait à chaque réouverture, si bien qu'un projet dont on avait
    /// supprimé les rushes au fil du dérushage rouvrait la photothèque en
    /// pleine figure. L'ouverture automatique est une commodité de PREMIÈRE
    /// ouverture — après, c'est une intrusion.
    var didAutoOpenPicker: Bool = false

    /// Derniere position de la tete de lecture, en centiemes de seconde de
    /// temps GLOBAL de timeline. -1 = jamais posee.
    ///
    /// Rouvrir un projet de vingt-cinq rushes repartait au debut : il fallait
    /// refaire defiler jusqu'au dernier rush traite, a chaque session. Stockee
    /// en centiemes comme le reste des durees de l'app, pour rester dans
    /// l'arithmetique rationnelle et ne pas trainer un Double a virgule.
    var playheadCentiseconds: Int = -1

    /// Empreinte de l'habillage tel que la dernière pose de préréglage l'a
    /// laissé. Vide tant qu'aucun préréglage n'a été posé.
    ///
    /// Elle sert à distinguer « l'habillage courant vient d'un préréglage » de
    /// « l'utilisateur l'a retouché depuis » — la seule question qui décide si
    /// le filet de retour doit être renouvelé.
    var overlaySignatureAfterPreset: String = ""

    /// Format du fichier exporte : automatique, 16:9 ou 9:16. Toujours rendu
    /// en 4K et 60 i/s, quel que soit le choix.
    ///
    /// Le cadre se deduisait du PREMIER clip place. Commode tant que tous les
    /// rushes ont la meme orientation ; des qu'on en melange, le format du
    /// fichier dependait de quel clip la musique avait mis en tete.
    var outputFormatRaw: String = MontageOutputFormat.auto.rawValue

    /// Recadrer pour remplir le cadre (vrai) plutot que ceinturer de noir.
    ///
    /// Poser une source 16:9 dans un cadre 9:16 laisse par nature deux bandes
    /// noires enormes. Le recadrage prend la bande centrale : on perd les
    /// bords, on garde toute la surface utile.
    var cropToFillOutput: Bool = true

    /// Le choix du format a-t-il deja ete propose pour ce projet ?
    ///
    /// La feuille s'ouvre apres la premiere importation, quand on decouvre
    /// les orientations reelles des rushes. La reproposer a chaque import
    /// serait une confirmation deguisee — le reglage reste accessible dans le
    /// menu, c'est suffisant.
    var didAskOutputFormat: Bool = false

    /// Sureechantillonner a l'export quand le recadrage impose un
    /// agrandissement.
    ///
    /// Recadrer une source 1080p en 9:16 donne 608x1080 : la porter en 4K
    /// vertical, c'est l'agrandir trois fois et demie. L'agrandissement
    /// interne d'AVFoundation est bilineaire, d'ou l'aspect mou. La seconde
    /// passe agrandit au filtre Lanczos et redessine les incrustations a la
    /// definition finale — au prix d'un second encodage complet.
    var upscaleOnExport: Bool = true

    // Paramètres de sélection / export.
    /// Durée FINALE (après ralentissement), en centièmes de seconde. 130 = 1,30 s.
    var finalDurationCentiseconds: Int = 130
    /// Mode de durée « JUSQU'À LA FIN DU RUSH » : la sélection va du toucher
    /// au bout du rush, sa longueur n'est plus imposée.
    ///
    /// C'est un choix de durée au même titre que 1,3 s, pas une action
    /// ponctuelle : il reste actif jusqu'à ce qu'une durée fixe soit
    /// rechoisie, et se maintient d'un projet à l'autre (AppSettings).
    /// `finalDurationCentiseconds` conserve la dernière durée fixe retenue —
    /// revenir en arrière ne fait rien perdre.
    var durationToRushEnd: Bool = false
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
    /// DÉSACTIVÉ : le rendu concurrent de l'édition affamait le décodeur
    /// (lecteur noir) — l'export est une phase séparée, lancée explicitement.
    var autoExportOnValidate: Bool = false
    /// Aperçu léger (540p au lieu de 720p) — réserve du décodeur pour la
    /// fluidité sur les très longs projets.
    var previewLight: Bool = false
    /// Enregistrer les exports dans un album Photos PROPRE AU PROJET
    /// (« ClipFlow — <nom> ») plutôt que dans l'album commun « ClipFlow ».
    /// L'album suit le nom du projet au moment de l'export.
    var albumPerProject: Bool = true
    /// Interpolation par FLUX OPTIQUE (VideoToolbox) pour créer les images
    /// intermédiaires du ralenti.
    ///
    /// DÉSACTIVÉ PAR DÉFAUT : le flux optique fabrique des images qui
    /// n'existent pas, et fabrique donc aussi des artefacts visibles (flashs)
    /// que ni le failsafe en ligne ni le contrôle du fichier produit n'ont
    /// entièrement éliminés sur du contenu réel. Sans lui, chaque image du
    /// ralenti est une VRAIE image du rush, répétée : le mouvement est plus
    /// saccadé, mais aucun pixel n'est inventé — donc aucun artefact possible.
    /// Réactivable à tout moment dans le menu ⋯.
    var opticalFlowEnabled: Bool = false
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

    // MARK: Montage musical

    /// Fichier musical du projet (nom dans Application Support/Music), nil
    /// tant qu'aucune musique n'a été choisie.
    var musicFilename: String?
    /// Nom d'origine du fichier choisi — le seul nom parlant pour l'utilisateur.
    var musicTitle: String?
    /// Départ de la fenêtre de montage dans la musique, en centisecondes.
    /// nil = utiliser le départ SUGGÉRÉ par l'analyse (cluster de drops).
    /// Persisté : déplacer la fenêtre puis revenir au projet ne perd rien.
    var montageStartCentiseconds: Int?
    /// Densité de découpe du montage (CutDensity.rawValue). Le cran du milieu
    /// (une coupe par beat) par défaut — le comportement CapCut.
    var montageDensityRaw: Int = 3

    @Relationship(deleteRule: .cascade, inverse: \Rush.project)
    var rushes: [Rush] = []

    @Relationship(deleteRule: .cascade, inverse: \Passage.project)
    var passages: [Passage] = []

    /// Incrustations du montage (logo, filigrane, texte). En cascade : elles
    /// n'ont aucun sens hors du projet qui les porte.
    @Relationship(deleteRule: .cascade, inverse: \OverlayLayer.project)
    var overlays: [OverlayLayer] = []

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
    /// Rushes visibles, triés — les suppressions EN ATTENTE sont exclues ici,
    /// à la source.
    ///
    /// Filtrer dans les vues aurait décalé les index de rush, dont dépend tout
    /// le calcul de temps global de la timeline. En passant par l'accesseur,
    /// l'app entière voit la même liste et l'arithmétique reste cohérente.
    var outputFormat: MontageOutputFormat {
        get { MontageOutputFormat(rawValue: outputFormatRaw) ?? .auto }
        set { outputFormatRaw = newValue.rawValue }
    }

    /// Orientations trouvees dans les rushes du projet.
    var rushFormatSurvey: RushFormatSurvey {
        var survey = RushFormatSurvey()
        for rush in visibleRushes {
            let size = rush.orientedSize
            guard size.width > 0, size.height > 0 else { continue }
            if size.height > size.width { survey.portraitCount += 1 }
            else { survey.landscapeCount += 1 }
        }
        return survey
    }

    var orderedRushes: [Rush] {
        rushes.filter { !$0.isPendingDeletion }.sorted { $0.orderIndex < $1.orderIndex }
    }

    /// Rushes visibles, non triés — pour compter sans trier.
    var visibleRushes: [Rush] { rushes.filter { !$0.isPendingDeletion } }

    /// Clips visibles, non triés.
    var visiblePassages: [Passage] { passages.filter { !$0.isPendingDeletion } }

    /// Passages triés par ordre de validation, hors suppressions en attente.
    var orderedPassages: [Passage] {
        passages.filter { !$0.isPendingDeletion }
            .sorted { $0.validationIndex < $1.validationIndex }
    }
}

// MARK: - Rush

@Model
final class Rush {

    /// Suppression EN ATTENTE : l'objet et ses fichiers existent encore, mais
    /// l'app fait comme s'ils n'existaient plus.
    ///
    /// C'est ce qui rend « Annuler » possible sans boîte de confirmation. La
    /// demande était « zéro confirmation » et elle est juste — les
    /// confirmations ralentissent tout — mais supprimer était alors définitif
    /// et instantané : un geste de travers coûtait le travail. La bonne réponse
    /// à « pas de confirmation » n'est pas « pas de filet », c'est
    /// l'annulation : on agit tout de suite, on peut revenir pendant quelques
    /// secondes. Passé le délai, la suppression est consommée pour de bon.
    var isPendingDeletion: Bool = false

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
    /// Taille du fichier source (déduplication de repli sans identifiant PhotoKit).
    var fileSizeBytes: Int64 = 0
    /// Rotation en degrés (0/90/180/270), issue de la preferredTransform.
    var rotationDegrees: Int = 0

    /// Taille TELLE QU'ON LA VOIT, rotation appliquee.
    ///
    /// `width`/`height` sont les dimensions du capteur : un rush filme en
    /// vertical avec un iPhone est stocke en 1920x1080 avec une rotation de
    /// 90 degres. Juger l'orientation sur les seules dimensions brutes le
    /// classerait en paysage, et le montage se serait cadre a l'envers.
    var orientedSize: CGSize {
        let rotated = rotationDegrees % 180 != 0
        return rotated ? CGSize(width: height, height: width)
                       : CGSize(width: width, height: height)
    }
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

    /// .nullify : supprimer un rush (bouton « Val. + Suppr. ») ne doit PAS
    /// détruire ses passages validés — ils s'exportent via leur plage cachée.
    @Relationship(deleteRule: .nullify, inverse: \Passage.rush)
    var passages: [Passage] = []

    /// Clips VISIBLES de ce rush — les suppressions en sursis exclues.
    ///
    /// La collection brute reste celle de SwiftData ; tout ce qui compte,
    /// affiche ou agit doit passer par ici. Un clip masqué qui restait
    /// attrapable au doigt se laissait re-valider, puis s'effaçait cinq
    /// secondes plus tard avec son fichier de plage — la validation n'ayant
    /// jamais levé le sursis.
    var visiblePassages: [Passage] {
        passages.filter { !$0.isPendingDeletion }
    }

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
    /// Suppression EN ATTENTE — voir `Rush.isPendingDeletion`.
    var isPendingDeletion: Bool = false

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

    /// Caractéristiques SOURCE figées à la validation — le rush peut être
    /// supprimé ensuite (Val. + Suppr.), l'export doit rester correct.
    var colorimetry: String = "sdr"
    var is10Bit: Bool = false
    var sourceNominalFrameRate: Double = 0

    /// Plage source pleine qualité mise en cache pour export hors-ligne (chemin relatif).
    var cachedRangeRelativePath: String?
    /// Temps du RUSH correspondant au zéro du fichier de plage caché
    /// (le start du passage reste toujours exprimé dans la base du rush).
    /// Version LISSEE de ce clip : 60 i/s obtenus par flux optique, rendue une
    /// fois et reutilisee par le montage.
    ///
    /// Ne concerne que les sources a cadence basse (30 i/s ou moins), qui ne
    /// sont plus ralenties (RationalSpeed.effective) et n'ont donc qu'une image
    /// sur deux a fabriquer pour atteindre 60 i/s — le regime facile de
    /// l'interpolation.
    ///
    /// Le montage assemble des plages cachees et les etire sans jamais
    /// interpoler : sans ce fichier, un clip 30 i/s y serait DUPLIQUE vers
    /// 60 i/s, et son mouvement trancherait avec celui des clips 60 i/s du
    /// meme montage. Le fichier contient exactement le clip fini, demarrant a
    /// zero, a sa duree finale.
    var smoothedRangeRelativePath: String?

    var cachedRangeOffsetValue: Int64 = 0
    var cachedRangeOffsetTimescale: Int32 = 600
    var exportStateRaw: Int = ExportState.notExported.rawValue
    var exportedFilename: String?
    /// Identifiant PhotoKit de l'asset exporté (album, relecture future).
    var exportedAssetIdentifier: String?
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
