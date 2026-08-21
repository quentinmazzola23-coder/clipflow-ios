//
//  OverlayPresetStore.swift
//  ClipFlow
//
//  Capture et pose des préréglages d'incrustations.
//
//  Deux opérations seulement, et toutes deux DUPLIQUENT les fichiers image :
//  un préréglage et un projet ne partagent jamais un PNG. Sans cette règle,
//  supprimer une incrustation d'un projet — ce qui efface son fichier —
//  viderait en silence tous les préréglages qui s'en servaient.
//

import Foundation
import SwiftData

enum OverlayPresetStore {

    /// Nom réservé à la sauvegarde automatique faite avant chaque pose.
    static let autoBackupName = "Avant le préréglage"

    // MARK: - Enregistrer

    /// Capture les incrustations d'un projet dans un nouveau préréglage.
    @discardableResult
    @MainActor
    static func capture(from project: ClipProject,
                        name: String,
                        isAutoBackup: Bool = false,
                        context: ModelContext) -> OverlayPreset {
        let preset = OverlayPreset(name: name, isAutoBackup: isAutoBackup)
        context.insert(preset)
        // Le filet est PROPRE au projet ; un vrai préréglage n'appartient à
        // personne et se repose partout.
        if isAutoBackup { preset.backupProject = project }

        for layer in project.overlays.sorted(by: { $0.stackOrder < $1.stackOrder }) {
            let entry = OverlayPresetEntry()
            entry.kind = layer.kind
            entry.text = layer.text
            // COPIE du fichier : voir l'en-tête. Si la copie échoue, l'entrée
            // est conservée sans image plutôt que de pointer sur le fichier du
            // projet, qui peut disparaître à tout moment.
            entry.imageFilename = layer.imageFilename.flatMap {
                OverlayStore.duplicateImage(filename: $0)
            }
            entry.imageAspect = layer.imageAspect
            entry.centerX = layer.centerX
            entry.centerY = layer.centerY
            entry.relativeWidth = layer.relativeWidth
            entry.opacity = layer.opacity
            entry.anchorIndex = layer.anchorIndex
            entry.anchorVideoRatio = layer.anchorVideoRatio
            entry.spansWholeMontage = layer.spansWholeMontage
            entry.firstClipIndex = layer.firstClipIndex
            entry.lastClipIndex = layer.lastClipIndex
            entry.stackOrder = layer.stackOrder
            context.insert(entry)
            entry.preset = preset
        }

        preset.updatedAt = .now
        try? context.save()
        return preset
    }

    /// Met en place le filet de CE projet, s'il n'en a pas déjà un.
    ///
    /// Deux règles, toutes deux apprises de la même manière — en constatant ce
    /// qu'on perdait :
    ///
    /// 1. LE FILET DÉCRIT LE DERNIER ÉTAT MANUEL, et rien d'autre. Il n'est
    ///    remplacé que si l'habillage a été RETOUCHÉ depuis la dernière pose.
    ///    Les deux règles naïves sont fausses toutes les deux : écraser à
    ///    chaque pose y met le préréglage précédent — que l'utilisateur possède
    ///    déjà dans sa liste — et ne jamais écraser fige le tout premier état,
    ///    si bien que « Avant le préréglage » désigne, une session plus tard,
    ///    quelque chose qui n'a plus rien à voir avec l'avant.
    /// 2. Un projet sans incrustation n'a rien à sauvegarder, mais son ancien
    ///    filet devient PÉRIMÉ : il doit partir, sinon il se ferait passer pour
    ///    le retour en arrière d'un état qu'il ne décrit pas.
    @MainActor
    static func refreshAutoBackup(from project: ClipProject, context: ModelContext) {
        let existing = fetchAll(context: context).filter {
            $0.isAutoBackup && $0.backupProject === project
        }
        guard !project.overlays.isEmpty else {
            for old in existing { context.delete(old) }
            try? context.save()
            return
        }
        if !existing.isEmpty {
            // Rien n'a bougé depuis la dernière pose : l'habillage courant EST
            // un préréglage, le sauvegarder n'apporterait rien et écraserait
            // le vrai travail manuel.
            guard signature(of: project) != project.overlaySignatureAfterPreset else { return }
            for old in existing { context.delete(old) }
        }
        capture(from: project, name: autoBackupName,
                isAutoBackup: true, context: context)
    }

    // MARK: - Appliquer

    /// Pose un préréglage sur un projet, en REMPLAÇANT ce qui s'y trouve.
    ///
    /// - `videoRatio` : forme du montage de destination. Les incrustations
    ///   ANCRÉES y sont recalculées, pour qu'un logo « bas droite » atterrisse
    ///   dans le coin du nouveau cadre plutôt qu'à la place qu'il occupait dans
    ///   un montage d'une autre orientation. Celles posées librement gardent
    ///   leur position en fractions.
    @MainActor
    static func apply(_ preset: OverlayPreset,
                      to project: ClipProject,
                      videoRatio: Double,
                      context: ModelContext) {
        // L'état courant part au filet AVANT d'être détruit — sauf s'il s'agit
        // du filet lui-même, qu'on est en train de reposer.
        if !preset.isAutoBackup {
            refreshAutoBackup(from: project, context: context)
        }

        // Les PNG des calques remplacés NE SONT PAS effacés ici. Le filet en
        // détient des copies, mais une duplication peut avoir échoué (disque
        // plein, fichier déjà manquant) : effacer l'original détruirait alors
        // la seule copie, en silence. Les fichiers devenus orphelins sont
        // ramassés au lancement par `OverlayStore.pruneUnreferencedImages`, ce
        // qui échange un risque de perte contre un peu d'espace temporaire.
        for layer in project.overlays {
            context.delete(layer)
        }

        for entry in preset.entries.sorted(by: { $0.stackOrder < $1.stackOrder }) {
            let layer = OverlayLayer()
            layer.kind = entry.kind
            layer.text = entry.text
            layer.imageFilename = entry.imageFilename.flatMap {
                OverlayStore.duplicateImage(filename: $0)
            }
            layer.imageAspect = entry.imageAspect
            layer.relativeWidth = entry.relativeWidth
            layer.opacity = entry.opacity
            layer.anchorIndex = entry.anchorIndex
            layer.centerX = entry.centerX
            layer.centerY = entry.centerY
            layer.anchorVideoRatio = entry.anchorVideoRatio
            layer.spansWholeMontage = entry.spansWholeMontage
            layer.firstClipIndex = entry.firstClipIndex
            layer.lastClipIndex = entry.lastClipIndex
            layer.stackOrder = entry.stackOrder

            // Ancrage recalculé pour la forme du montage d'ARRIVÉE.
            if layer.anchorIndex >= 0, videoRatio > 0,
               let center = OverlayLayer.anchoredCenter(
                anchorIndex: layer.anchorIndex,
                relativeSpan: OverlayGeometry.span(of: layer),
                relativeHeight: OverlayGeometry.height(of: layer, videoRatio: videoRatio)) {
                layer.centerX = center.x
                layer.centerY = center.y
                layer.anchorVideoRatio = videoRatio
            }

            context.insert(layer)
            layer.project = project
        }

        // Empreinte de CE QUI VIENT D'ÊTRE POSÉ : elle permettra de savoir si
        // l'utilisateur a retouché à la main avant la pose suivante.
        project.overlaySignatureAfterPreset = signature(of: project)
        try? context.save()

        // Le filet vient d'être reposé : il a joué son rôle. On le retire pour
        // que la pose suivante puisse en capturer un neuf — sinon le premier
        // filet resterait en place à jamais et le retour ne servirait qu'une
        // fois. APRÈS la recopie et la sauvegarde : `delete` efface aussi ses
        // PNG, dont les calques viennent de recevoir des copies indépendantes.
        if preset.isAutoBackup {
            delete(preset, context: context)
        }
    }

    // MARK: - Gestion

    @MainActor
    static func fetchAll(context: ModelContext) -> [OverlayPreset] {
        let descriptor = FetchDescriptor<OverlayPreset>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Supprime un préréglage. Ses fichiers image sont laissés au
    /// ramasse-miettes.
    ///
    /// Les effacer ici paraissait propre, et c'était un piège : consommer le
    /// filet passe par ce chemin JUSTE APRÈS avoir recopié ses images vers les
    /// nouveaux calques. Si une recopie avait échoué — disque plein, fichier
    /// déjà manquant — on détruisait la seule copie restante, exactement la
    /// perte que `apply` avait pris soin d'écarter deux lignes plus haut.
    ///
    /// La règle est donc unique dans toute l'app : SEUL
    /// `OverlayStore.pruneUnreferencedImages` efface un PNG d'incrustation, au
    /// lancement, sur un inventaire complet. Un fichier orphelin coûte un peu
    /// d'espace jusqu'au prochain démarrage ; une image détruite ne revient pas.
    @MainActor
    static func delete(_ preset: OverlayPreset, context: ModelContext) {
        context.delete(preset)
        try? context.save()
    }

    /// Supprime les filets dont le projet a disparu.
    ///
    /// `.nullify` les laisse avec `backupProject == nil` : plus aucun écran ne
    /// les affiche (la feuille ne montre que le filet du projet courant), donc
    /// plus personne ne peut les effacer — et leurs entrées continuent de
    /// référencer leurs PNG, ce qui les protège aussi du ramasse-miettes.
    /// Invisibles, indestructibles, et occupant de la place à jamais.
    @MainActor
    static func purgeOrphanBackups(context: ModelContext) {
        for ghost in fetchAll(context: context)
        where ghost.isAutoBackup && ghost.backupProject == nil {
            context.delete(ghost)
        }
        try? context.save()
    }

    /// Empreinte de l'habillage courant.
    ///
    /// Sert à savoir si l'utilisateur a RETOUCHÉ à la main depuis la dernière
    /// pose de préréglage. Sans elle, il fallait choisir entre deux filets
    /// également faux : un filet écrasé à chaque pose y mettait le préréglage
    /// précédent — que l'utilisateur a déjà dans sa liste — et un filet jamais
    /// écrasé figeait le tout premier état, en continuant de s'appeler
    /// « Avant le préréglage » une session entière plus tard.
    @MainActor
    static func signature(of project: ClipProject) -> String {
        project.overlays
            .sorted { $0.stackOrder < $1.stackOrder }
            .map { layer in
                [String(layer.stackOrder), layer.kindRaw, layer.text,
                 layer.imageFilename ?? "",
                 String(format: "%.4f", layer.centerX),
                 String(format: "%.4f", layer.centerY),
                 String(format: "%.4f", layer.relativeWidth),
                 String(format: "%.3f", layer.opacity),
                 String(layer.anchorIndex), String(layer.spansWholeMontage),
                 String(layer.firstClipIndex), String(layer.lastClipIndex)]
                    .joined(separator: "|")
            }
            .joined(separator: "\n")
    }
}
