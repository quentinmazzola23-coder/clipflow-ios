//
//  MontageVariant.swift
//  ClipFlow
//
//  PLUSIEURS MONTAGES POUR UN MÊME PROJET.
//
//  Un projet ne retenait qu'un montage : une musique, une fenêtre, une densité,
//  un format. Sortir la même session en 16:9 puis en 9:16 obligeait à tout
//  reprendre de mémoire — et à perdre le premier réglage en posant le second.
//
//  UNE VARIANTE EST UN INSTANTANÉ, PAS UN SECOND MODÈLE. Elle recopie les
//  réglages du projet et sait les lui rendre. C'est exactement le patron des
//  préréglages d'incrustations, et c'est délibéré : faire vivre l'écran de
//  montage sur « la variante active » aurait demandé de dérouter chacune de ses
//  lectures, avec la certitude qu'un oubli laisserait un réglage lu au projet
//  et écrit à la variante. Ici, un seul état fait foi — celui du projet — et
//  les variantes ne sont que des copies qu'on rappelle.
//
//  CE QU'ELLE NE PORTE PAS : les incrustations. Elles appartiennent au projet
//  et restent partagées par toutes ses variantes. Un logo posé une fois vaut
//  pour les deux formats ; s'il devait un jour différer, ce serait un second
//  chantier, pas un effet de bord de celui-ci.
//

import Foundation
import SwiftData

@Model
final class MontageVariant {

    /// Nom donné par l'utilisateur, ou déduit du format à l'enregistrement.
    var name: String = "Montage"
    var createdAt: Date = Date(timeIntervalSince1970: 0)

    // Réglages recopiés du projet.
    var musicFilename: String?
    var musicTitle: String?
    var montageStartCentiseconds: Int?
    var montageDensityRaw: Int = 3
    var outputFormatRaw: String = MontageOutputFormat.auto.rawValue
    var cropToFillOutput: Bool = true
    var upscaleOnExport: Bool = true

    var project: ClipProject?

    init() {}

    /// Résumé d'une ligne : ce qui distingue vraiment deux variantes.
    var summary: String {
        let format = MontageOutputFormat(rawValue: outputFormatRaw) ?? .auto
        let music = musicTitle ?? "sans musique"
        return "\(format.shortLabel) · \(music)"
    }
}

enum MontageVariantStore {

    /// Enregistre les réglages COURANTS du projet comme variante.
    ///
    /// Un enregistrement ne bascule sur rien : le projet garde ses réglages,
    /// on vient seulement d'en poser une copie qu'on pourra rappeler.
    @discardableResult
    static func capture(from project: ClipProject,
                        name: String,
                        in context: ModelContext) -> MontageVariant {
        let variant = MontageVariant()
        variant.name = name
        variant.createdAt = Date()
        variant.musicFilename = project.musicFilename
        variant.musicTitle = project.musicTitle
        variant.montageStartCentiseconds = project.montageStartCentiseconds
        variant.montageDensityRaw = project.montageDensityRaw
        variant.outputFormatRaw = project.outputFormatRaw
        variant.cropToFillOutput = project.cropToFillOutput
        variant.upscaleOnExport = project.upscaleOnExport
        variant.project = project
        context.insert(variant)
        try? context.save()
        return variant
    }

    /// Résultat d'un rappel.
    enum ApplyOutcome {
        case applied(musicChanged: Bool)
        /// La musique de la variante n'est plus sur le disque : RIEN n'a été
        /// écrit. Écraser les réglages courants aurait fait perdre une musique
        /// valide en échange d'une qui n'existe plus.
        case musicMissing
    }

    /// Rend au projet les réglages d'une variante.
    ///
    /// Signale si la musique a changé — l'appelant doit alors relancer
    /// l'analyse rythmique, sans quoi l'écran garderait la grille de beats de
    /// l'ancien morceau sur le nouveau.
    @discardableResult
    static func apply(_ variant: MontageVariant,
                      to project: ClipProject,
                      in context: ModelContext) -> ApplyOutcome {
        // FICHIER VÉRIFIÉ AVANT LA MOINDRE ÉCRITURE. Une musique supprimée de
        // la bibliothèque ne prévient pas les variantes qui s'en servaient :
        // rappeler ce montage aurait remplacé la musique courante — bien
        // vivante — par un nom qui ne désigne plus rien, et le projet se serait
        // retrouvé sans montage possible.
        if let filename = variant.musicFilename,
           !FileManager.default.fileExists(
               atPath: MusicStore.url(forMusicFilename: filename).path) {
            return .musicMissing
        }
        let musicChanged = project.musicFilename != variant.musicFilename
        project.musicFilename = variant.musicFilename
        project.musicTitle = variant.musicTitle
        project.montageStartCentiseconds = variant.montageStartCentiseconds
        project.montageDensityRaw = variant.montageDensityRaw
        project.outputFormatRaw = variant.outputFormatRaw
        project.cropToFillOutput = variant.cropToFillOutput
        project.upscaleOnExport = variant.upscaleOnExport
        try? context.save()
        return .applied(musicChanged: musicChanged)
    }

    /// Met à jour une variante existante depuis les réglages courants.
    static func update(_ variant: MontageVariant,
                       from project: ClipProject,
                       in context: ModelContext) {
        variant.musicFilename = project.musicFilename
        variant.musicTitle = project.musicTitle
        variant.montageStartCentiseconds = project.montageStartCentiseconds
        variant.montageDensityRaw = project.montageDensityRaw
        variant.outputFormatRaw = project.outputFormatRaw
        variant.cropToFillOutput = project.cropToFillOutput
        variant.upscaleOnExport = project.upscaleOnExport
        try? context.save()
    }

    static func delete(_ variant: MontageVariant, in context: ModelContext) {
        // AUCUN FICHIER À EFFACER : une variante ne possède rien. Sa musique
        // appartient à la bibliothèque et sert peut-être à un autre projet.
        context.delete(variant)
        try? context.save()
    }

    /// Nom proposé à l'enregistrement : le format suffit à distinguer les deux
    /// cas d'usage courants, et personne n'a envie de taper un nom au pouce.
    static func suggestedName(for project: ClipProject, existing: [MontageVariant]) -> String {
        let format = project.outputFormat
        let base = format == .auto ? "Montage" : format.shortLabel
        guard existing.contains(where: { $0.name == base }) else { return base }
        var index = 2
        while existing.contains(where: { $0.name == "\(base) \(index)" }) { index += 1 }
        return "\(base) \(index)"
    }
}
