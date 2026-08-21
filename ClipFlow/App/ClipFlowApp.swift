//
//  ClipFlowApp.swift
//  ClipFlow
//
//  Point d'entrée. Conteneur SwiftData strictement local (aucune synchronisation CloudKit).
//

import SwiftUI
import SwiftData
import AVFAudio

@main
struct ClipFlowApp: App {

    /// Conteneur SwiftData local. Stocké dans Application Support, exclu d'aucune
    /// sauvegarde (les métadonnées de projet sont petites et doivent être sauvegardées ;
    /// seuls les fichiers vidéo volumineux sont exclus, voir StorageManager).
    let container: ModelContainer

    init() {
        do {
            let storeURL = StorageManager.applicationSupportDirectory
                .appendingPathComponent("ClipFlow.store")
            let configuration = ModelConfiguration(
                url: storeURL,
                cloudKitDatabase: .none
            )
            container = try ModelContainer(
                for: ClipProject.self, Rush.self, Passage.self, MusicTrack.self,
                     OverlayLayer.self, OverlayPreset.self, OverlayPresetEntry.self,
                configurations: configuration
            )
        } catch {
            fatalError("Impossible d'initialiser la base SwiftData : \(error)")
        }
        // Rendus orphelins (crash entre rendu et enregistrement Photos) :
        // purge au lancement — aucune file ne tourne encore à cet instant.
        StorageManager.clearExports()

        // Images d'incrustation devenues orphelines : ramassées ici, quand
        // rien n'est en cours. Poser un préréglage ne détruit délibérément
        // aucun PNG (voir OverlayPresetStore.apply) — c'est le prix à payer
        // pour ne jamais effacer la seule copie d'une image.
        let pruneContext = ModelContext(container)
        OverlayStore.pruneUnreferencedImages(context: pruneContext)

        // CATÉGORIE AUDIO .playback, ET C'EST IMPORTANT. Sans elle, la
        // catégorie par défaut (.soloAmbient) OBÉIT AU COMMUTATEUR SONNERIE :
        // téléphone en silencieux → aperçu du montage et lecture des rushes
        // muets, sans la moindre erreur. Une app de montage vidéo est un
        // lecteur multimédia : elle joue même en mode silencieux, comme
        // YouTube ou CapCut.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

/// Racine de navigation. Sombre par défaut (outil vidéo), accent unique.
/// (La NavigationStack vit dans ProjectListView, qui possède le chemin pour
/// pousser un projet fraîchement créé directement dans l'éditeur.)
struct RootView: View {
    /// Contexte de la base — `.task` n'existe pas sur une `Scene`, la reprise
    /// au lancement vit donc ici, dans la première vue.
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ProjectListView()
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            // REPRISE AU LANCEMENT, dans cet ordre :
            //  1. les musiques des projets d'avant la bibliothèque y entrent —
            //     sinon elles passeraient pour des fichiers orphelins, et un
            //     tap dans l'écran Stockage les aurait effacées ;
            //  2. les analyses interrompues repartent — la file vit en
            //     mémoire, un morceau importé puis l'app fermée restait sinon
            //     bloqué sur « en attente d'analyse ».
            .task {
                MusicLibraryController.adoptProjectMusic(context: modelContext)
                MusicLibraryController.shared.resumePending(context: modelContext)
            }
    }
}
