//
//  OverlayPreset.swift
//  ClipFlow
//
//  PRÉRÉGLAGES D'INCRUSTATIONS : une configuration complète — « texte d'intro
//  sur le premier clip, filigrane sur toute la vidéo » — enregistrée une fois
//  et reposée sur n'importe quel projet.
//
//  Un préréglage possède SES PROPRES FICHIERS IMAGE, copiés au moment de
//  l'enregistrement. C'est le point délicat : s'il pointait sur l'image du
//  projet d'origine, supprimer ce projet — ou simplement retirer l'incrustation
//  — viderait le préréglage de sa substance, sans rien annoncer. Chaque
//  propriétaire a donc sa copie, et personne ne marche sur les fichiers d'un
//  autre. Une incrustation pèse quelques centaines de kilo-octets ; c'est bien
//  moins cher qu'un comptage de références qu'on finirait par se tromper.
//
//  Les positions sont en FRACTIONS et les portées en RANGS DE CLIPS, donc un
//  préréglage traverse les projets sans conversion : « premier clip » reste le
//  premier clip, quel que soit le montage.
//

import Foundation
import SwiftData

@Model
final class OverlayPreset {

    var name: String = "Préréglage"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// Sauvegarde AUTOMATIQUE de la configuration remplacée.
    ///
    /// Appliquer un préréglage écrase ce qui était en place. Plutôt que de
    /// poser une boîte de confirmation — l'app n'en veut nulle part — l'état
    /// précédent est capturé ici, sous un nom réservé. Rien n'est perdu, et
    /// revenir en arrière est un simple tap sur un préréglage de plus.
    var isAutoBackup: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \OverlayPresetEntry.preset)
    var entries: [OverlayPresetEntry] = []

    init(name: String = "Préréglage", isAutoBackup: Bool = false) {
        self.name = name
        self.isAutoBackup = isAutoBackup
    }

    /// Résumé lisible : « 1 image · 1 texte », pour reconnaître un préréglage
    /// sans l'appliquer.
    var summary: String {
        let images = entries.filter { $0.kind == .image }.count
        let texts = entries.filter { $0.kind == .text }.count
        var parts: [String] = []
        if images > 0 { parts.append("\(images) image\(images > 1 ? "s" : "")") }
        if texts > 0 { parts.append("\(texts) texte\(texts > 1 ? "s" : "")") }
        return parts.isEmpty ? "vide" : parts.joined(separator: " · ")
    }
}

@Model
final class OverlayPresetEntry {

    var kindRaw: String = OverlayKind.text.rawValue
    var text: String = ""
    /// Copie PROPRE au préréglage, dans le même dossier que les incrustations.
    var imageFilename: String?
    /// Rapport hauteur/largeur de l'image, repris tel quel : le recalculer
    /// demanderait de rouvrir le fichier.
    var imageAspect: Double = 0

    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var relativeWidth: Double = 0.3
    var anchorIndex: Int = -1
    var anchorVideoRatio: Double = 0

    var spansWholeMontage: Bool = true
    var firstClipIndex: Int = 0
    var lastClipIndex: Int = 0
    var stackOrder: Int = 0

    var preset: OverlayPreset?

    init() {}

    var kind: OverlayKind {
        get { OverlayKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var imageURL: URL? {
        imageFilename.map { OverlayStore.url(forImageNamed: $0) }
    }

    /// Description de la portée, pour la liste des préréglages.
    var scopeLabel: String {
        if spansWholeMontage { return "toute la vidéo" }
        let first = firstClipIndex + 1
        let last = lastClipIndex + 1
        return first == last ? "clip \(first)" : "clips \(first) à \(last)"
    }
}
