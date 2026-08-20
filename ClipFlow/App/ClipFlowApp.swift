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
                for: ClipProject.self, Rush.self, Passage.self,
                configurations: configuration
            )
        } catch {
            fatalError("Impossible d'initialiser la base SwiftData : \(error)")
        }
        // Rendus orphelins (crash entre rendu et enregistrement Photos) :
        // purge au lancement — aucune file ne tourne encore à cet instant.
        StorageManager.clearExports()

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
    var body: some View {
        ProjectListView()
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
    }
}
