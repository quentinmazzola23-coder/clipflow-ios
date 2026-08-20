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

    private init() {}

    /// Lance l'export. Refuse si un export tourne déjà — deux sessions
    /// viseraient le même fichier de sortie.
    func start(plan: MontagePlan,
               sources: [Int: URL],
               musicURL: URL,
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
                let montage = try await MontageComposer.build(
                    plan: plan, sources: sources, musicURL: musicURL
                )
                try Task.checkCancellation()
                let fileURL = try await MontageComposer.export(
                    montage, outputFilename: outputFilename
                ) { value in
                    Task { @MainActor in self?.progress = value }
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
