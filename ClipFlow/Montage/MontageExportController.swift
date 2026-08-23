//
//  MontageExportController.swift
//  ClipFlow
//
//  EXPORT DU MONTAGE — service PARTAGÉ, volontairement hors de la vue.
//
//  Pourquoi ce fichier existe. L'export vivait dans une `Task` non stockée de
//  MontageView, qui est présentée en `fullScreenCover` : fermer l'écran
//  détruisait la vue sans arrêter la tâche, et le rouvrir en recréait une
//  neuve dont TOUS les verrous repartaient à zéro. Trois dégâts mesurés :
//    - relancer un export visait le MÊME fichier de sortie que celui encore
//      en écriture — les deux sessions s'écrasaient ;
//    - changer de musique supprimait le fichier que la session lisait ;
//    - « Libérer l'espace » ne consultait que la file clip-par-clip et
//      arrachait les plages sources sous la session.
//  Dans les trois cas l'échec atterrissait dans l'état d'une vue morte :
//  l'utilisateur ne voyait RIEN et ne trouvait pas son montage dans Photos.
//
//  Ici l'état survit à la vue. Tous les gardes de suppression de l'app
//  consultent `isExporting` (voir MediaAvailabilityService, StorageView,
//  ProjectListView), et l'écran de montage n'est plus qu'un afficheur.
//
//  DEUX PROPRIÉTÉS SÉPARÉES, pas une structure unique : `progress` change
//  plusieurs fois par seconde, `isExporting` deux fois par export. Les
//  regrouper créerait une dépendance d'observation sur la progression dans
//  toute vue qui lit seulement l'état — le défaut qui faisait déjà se
//  reconstruire l'éditeur à chaque image rendue.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class MontageExportController {

    static let shared = MontageExportController()

    /// Vrai pendant tout l'export. Change deux fois par export.
    private(set) var isExporting = false
    /// Avancement 0…1. Change plusieurs fois par seconde — À LIRE UNIQUEMENT
    /// dans une vue isolée (voir la note d'en-tête).
    private(set) var progress: Double = 0
    /// Nom du projet dont l'export tourne — pour que les gardes puissent dire
    /// CE QUI bloque, pas seulement « occupé ».
    private(set) var projectName: String?

    /// Résultat du dernier export terminé, consommé par l'écran de montage à
    /// sa réapparition : un export achevé pendant que l'écran était fermé
    /// doit quand même être annoncé.
    private(set) var lastOutcome: Outcome?
    /// Projet qui a lancé l'export dont `lastOutcome` rend compte — sans quoi
    /// un résultat non consommé serait annoncé par le premier écran de montage
    /// ouvert, fût-ce celui d'un autre projet.
    private(set) var lastOutcomeProject: String?
    /// Jeton qui change à chaque résultat. Observer `lastOutcome` directement
    /// raterait deux résultats identiques d'affilée (deux réussites).
    private(set) var lastOutcomeToken = UUID()

    enum Outcome: Equatable {
        case saved
        case failed(String)
        case cancelled
    }

    private var task: Task<Void, Never>?

    /// Part de la barre de progression revenant au lissage des clips a cadence
    /// basse. Sans ce partage, la barre atteindrait 100 % avant meme que la
    /// composition ne commence.
    private static let smoothingShare = 0.2

    private init() {}

    /// Lance l'export. Refuse si un export tourne déjà — deux sessions
    /// viseraient le même fichier de sortie.
    func start(plan: MontagePlan,
               sources: [Int: URL],
               musicURL: URL,
               overlays: [ResolvedOverlay] = [],
               outputFormat: MontageOutputFormat = .auto,
               cropToFill: Bool = true,
               upscale: Bool = true,
               sourceOriented: CGSize = .zero,
               smoothing: [MontageSmoothingRequest] = [],
               onSmoothed: (([Int: String]) -> Void)? = nil,
               outputFilename: String,
               albumName: String?,
               projectName: String) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        lastOutcome = nil
        self.projectName = projectName

        task = Task { [weak self] in
            do {
                // PHASE 0 — LISSAGE des clips à cadence basse.
                //
                // Elle précède la composition parce qu'elle CHANGE les fichiers
                // sources : le montage insère la version 60 i/s à la place de la
                // plage cachée. Sa base de temps est identique — même début,
                // même durée, seule la cadence monte — donc les points d'entrée
                // du plan restent valables tels quels.
                //
                // Un clip qui n'a pas pu être lissé garde simplement sa plage
                // d'origine : l'export continue.
                var sources = sources
                if !smoothing.isEmpty {
                    let produced = await MontageSmoothing.prepare(smoothing) { value in
                        Task { @MainActor in self?.progress = value * Self.smoothingShare }
                    }
                    for (clipID, filename) in produced {
                        sources[clipID] = StorageManager.url(
                            forCachedRangeRelativePath: filename)
                    }
                    // Mémorisation APRÈS coup, sur l'acteur principal : rendu
                    // une fois, réutilisé à tous les exports suivants.
                    if !produced.isEmpty { onSmoothed?(produced) }
                }

                // DEUX PASSES ou une seule ?
                //
                // Le suréchantillonnage ne vaut une seconde passe d'encodage
                // que s'il y a vraiment un agrandissement à faire : sur un
                // montage 4K qui sort en 4K sans recadrage, le facteur vaut 1
                // et la passe ne ferait que réencoder, plus lentement, pour un
                // résultat identique.
                let factor = outputFormat.upscaleFactor(sourceOriented: sourceOriented,
                                                        cropToFill: cropToFill)
                let twoPass = upscale && sourceOriented != .zero
                    && factor >= MontageUpscaler.minimumUsefulFactor

                let montage = try await MontageComposer.build(
                    plan: plan, sources: sources, musicURL: musicURL,
                    // Les incrustations sont dessinées par la SECONDE passe,
                    // à la définition finale : les laisser ici les ferait
                    // agrandir avec l'image, donc flouter.
                    overlays: twoPass ? [] : overlays,
                    outputFormat: outputFormat, cropToFill: cropToFill,
                    renderAtNativeSize: twoPass,
                    forExport: true
                )
                try Task.checkCancellation()
                // BARRE PARTAGÉE ENTRE LES PHASES RÉELLEMENT PRÉVUES.
                //
                // L'export compte jusqu'à trois étapes — lissage, composition,
                // agrandissement — et chacune rapporte sa propre progression de
                // 0 à 1. Sans ce partage, la barre repartirait de zéro à chaque
                // étape, ou atteindrait 100 % avant la dernière.
                let composeBase = smoothing.isEmpty ? 0 : Self.smoothingShare
                let remaining = 1 - composeBase
                let composeSpan = twoPass ? remaining / 2 : remaining
                var fileURL = try await MontageComposer.export(
                    montage, outputFilename: outputFilename
                ) { value in
                    Task { @MainActor in
                        self?.progress = composeBase + value * composeSpan
                    }
                }
                try Task.checkCancellation()

                if twoPass {
                    let upscaleBase = composeBase + composeSpan
                    let upscaleSpan = 1 - upscaleBase
                    let target = outputFormat.renderSize(sourceOriented: sourceOriented)
                    let upscaled = try await MontageUpscaler.upscale(
                        source: fileURL, to: target, overlays: overlays,
                        frameRate: 60
                    ) { value in
                        Task { @MainActor in
                            self?.progress = upscaleBase + value * upscaleSpan
                        }
                    }
                    // Le fichier natif a joué son rôle : il ne sert plus qu'à
                    // occuper de la place.
                    try? FileManager.default.removeItem(at: fileURL)
                    fileURL = upscaled
                }
                try Task.checkCancellation()
                _ = try await PhotoExportService.saveToPhotos(fileURL: fileURL,
                                                             projectName: albumName)
                try? FileManager.default.removeItem(at: fileURL)
                self?.finish(.saved)
            } catch is CancellationError {
                self?.finish(.cancelled)
            } catch {
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    /// Annule l'export en cours (fermeture de l'écran, suppression du projet).
    func cancel() {
        guard isExporting else { return }
        task?.cancel()
    }

    /// Marque le résultat comme vu — l'écran l'a annoncé, il ne le rejouera pas.
    func consumeOutcome() {
        lastOutcome = nil
        lastOutcomeProject = nil
    }

    private func finish(_ outcome: Outcome) {
        isExporting = false
        progress = 0
        lastOutcomeProject = projectName
        projectName = nil
        lastOutcome = outcome
        lastOutcomeToken = UUID()
        task = nil
    }
}
