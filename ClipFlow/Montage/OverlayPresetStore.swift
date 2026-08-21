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

    /// Remplace la sauvegarde automatique par l'état courant du projet.
    ///
    /// Une seule sauvegarde existe à la fois : elle sert de « pas comme ça,
    /// finalement », pas d'historique. Un empilement demanderait de la ménager
    /// et de l'expliquer, pour un besoin que personne n'a exprimé.
    @MainActor
    static func refreshAutoBackup(from project: ClipProject, context: ModelContext) {
        // Rien à sauvegarder : on ne remplace pas un état utile par du vide.
        guard !project.overlays.isEmpty else { return }
        for old in fetchAll(context: context) where old.isAutoBackup {
            delete(old, context: context)
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

        for layer in project.overlays {
            if let filename = layer.imageFilename {
                OverlayStore.deleteImage(filename: filename)
            }
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

        try? context.save()
    }

    // MARK: - Gestion

    @MainActor
    static func fetchAll(context: ModelContext) -> [OverlayPreset] {
        let descriptor = FetchDescriptor<OverlayPreset>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Supprime un préréglage ET ses fichiers image.
    ///
    /// La cascade SwiftData efface les entrées, pas les PNG qu'elles
    /// désignent : sans ce passage, chaque préréglage supprimé laisserait ses
    /// images sur le disque, définitivement.
    @MainActor
    static func delete(_ preset: OverlayPreset, context: ModelContext) {
        for entry in preset.entries {
            if let filename = entry.imageFilename {
                OverlayStore.deleteImage(filename: filename)
            }
        }
        context.delete(preset)
        try? context.save()
    }
}
