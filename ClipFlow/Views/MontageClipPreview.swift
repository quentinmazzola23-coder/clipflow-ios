//
//  MontageClipPreview.swift
//  ClipFlow
//
//  REVOIR UN CLIP depuis la liste du montage.
//
//  Le numéro affiché sur l'aperçu du montage ne sert que si l'on peut vérifier
//  à quoi il correspond. Sans cet écran, on lisait « 47 », on ouvrait la liste,
//  et on tombait sur une ligne avec une vignette d'une image — pas de quoi
//  décider de garder ou de rejeter un plan.
//
//  Il joue EN BOUCLE, comme la sélection au dérushage : un plan d'une seconde
//  vu une fois ne se juge pas.
//

import SwiftUI
import AVKit
import AVFoundation

struct MontageClipPreview: View {
    let passage: Passage

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if unavailable {
                    ContentUnavailableView(
                        "Clip illisible",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Ni plage cachée ni copie source sur cet appareil. "
                                          + "C'est un défaut de disponibilité du média, "
                                          + "pas une erreur de manipulation.")
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(passage.rush?.originalFilename ?? "Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .task { await load() }
        .onDisappear {
            // Le lecteur ET son observateur partent ensemble : un observateur
            // survivant relancerait la lecture d'un élément que plus personne
            // n'affiche, son compris.
            player?.pause()
            if let loopObserver {
                NotificationCenter.default.removeObserver(loopObserver)
            }
            loopObserver = nil
            player = nil
        }
    }

    private func load() async {
        guard let source = MediaAvailabilityService.exportSource(for: passage) else {
            unavailable = true
            return
        }
        let rate = Float(passage.speedNumerator) / Float(max(1, passage.speedDenominator))
        let asset = AVURLAsset(url: source.url)
        let item = AVPlayerItem(asset: asset)
        // BORNÉ À LA PLAGE DU CLIP : sans cela on regarderait toute la plage
        // cachée, marges comprises, et on jugerait un plan qu'on n'a pas monté.
        item.forwardPlaybackEndTime = source.rangeInFile.end
        let created = AVPlayer(playerItem: item)
        // PUBLIÉ AVANT LE SEEK, et c'est la correction d'un vrai piège.
        //
        // Un seek à tolérance nulle sur du 4K prend plusieurs centaines de
        // millisecondes. Refermer la feuille pendant ce temps — geste banal,
        // on s'est trompé de ligne — faisait passer `onDisappear` sur un
        // `player` encore nil : il n'avait rien à arrêter. La suite du
        // chargement installait ensuite un lecteur et un observateur que plus
        // aucune vue ne détenait, et le son continuait sans moyen de l'arrêter.
        player = created
        await created.seek(to: source.rangeInFile.start,
                           toleranceBefore: .zero, toleranceAfter: .zero)
        // La feuille a pu partir pendant le seek.
        guard !Task.isCancelled else {
            created.pause()
            created.replaceCurrentItem(with: nil)
            player = nil
            return
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item, queue: .main
        ) { _ in
            Task { @MainActor in
                await created.seek(to: source.rangeInFile.start,
                                   toleranceBefore: .zero, toleranceAfter: .zero)
                created.rate = rate > 0 ? rate : 1
            }
        }
        // VITESSE DU CLIP, pas la vitesse réelle.
        //
        // Un clip à 0,5× prélève une demi-seconde de rush pour une seconde de
        // montage : le jouer à vitesse normale montrait la bonne image mais
        // deux fois trop vite, et la boucle durait la moitié de la durée
        // annoncée juste au-dessus dans la liste. On jugeait un plan sur un
        // rythme qui n'est pas le sien.
        created.rate = rate > 0 ? rate : 1
    }
}
