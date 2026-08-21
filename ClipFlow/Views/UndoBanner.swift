//
//  UndoBanner.swift
//  ClipFlow
//
//  ANNULATION ÉPHÉMÈRE : le filet qui remplace les confirmations.
//
//  L'app ne demande jamais « êtes-vous sûr ? », et c'est un bon choix : sur un
//  écran qu'on utilise au pouce, chaque boîte de dialogue est un geste de plus
//  pour une question dont la réponse est presque toujours oui. Mais supprimer
//  était alors définitif et instantané — un rush effacé par mégarde ne revenait
//  pas.
//
//  La réponse n'est pas de remettre des confirmations, c'est de rendre le
//  retour possible : l'action part immédiatement, un bandeau discret propose
//  « Annuler » pendant quelques secondes, puis la suppression est consommée.
//  On garde la vitesse et on perd le risque.
//
//  Le bandeau se veut MINIMAL : une ligne, en bas, au-dessus du pouce, qui
//  n'attrape aucun geste en dehors de son propre bouton.
//

import SwiftUI

/// Une suppression en sursis.
@MainActor
struct PendingDeletion: Identifiable {
    let id = UUID()
    /// Ce qui a disparu, à la première personne de l'objet : « Rush supprimé ».
    let label: String
    /// Consomme la suppression : efface les fichiers et l'entité.
    let commit: () -> Void
    /// Rétablit ce qui était masqué.
    let restore: () -> Void
}

/// Détient la suppression en sursis et son minuteur.
///
/// Une seule à la fois : empiler les annulations demanderait de les présenter
/// et de les expliquer, pour un besoin que personne n'a. Une nouvelle
/// suppression consomme la précédente — ce qui est exactement ce que
/// l'utilisateur signifie en supprimant deux fois de suite.
@Observable
@MainActor
final class DeletionUndo {
    private(set) var pending: PendingDeletion?
    private var timer: Task<Void, Never>?

    /// Délai de grâce. Cinq secondes : le temps de voir le bandeau et de
    /// réagir, sans laisser un état incertain traîner sur l'écran.
    static let graceSeconds: Double = 5

    func schedule(label: String,
                  commit: @escaping () -> Void,
                  restore: @escaping () -> Void) {
        // La précédente est consommée : deux suppressions de suite veulent
        // dire que la première était voulue.
        consumeNow()
        let item = PendingDeletion(label: label, commit: commit, restore: restore)
        pending = item
        timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.graceSeconds))
            guard !Task.isCancelled, pending?.id == item.id else { return }
            pending = nil
            item.commit()
        }
    }

    func undo() {
        guard let item = pending else { return }
        timer?.cancel()
        timer = nil
        pending = nil
        item.restore()
    }

    /// Consomme immédiatement ce qui attend — à appeler en quittant l'écran :
    /// un sursis ne doit pas survivre à la vue qui l'affichait, sinon plus rien
    /// ne peut l'annuler et l'objet resterait masqué sans jamais être effacé.
    func consumeNow() {
        guard let item = pending else { timer?.cancel(); timer = nil; return }
        timer?.cancel()
        timer = nil
        pending = nil
        item.commit()
    }
}

/// Bandeau d'annulation, à poser en surimpression au bas d'un écran.
struct UndoBannerView: View {
    let pending: PendingDeletion
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(pending.label)
                .font(.footnote)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onUndo) {
                Text("Annuler")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    // Prise confortable sans bouton dessiné : le bandeau est
                    // déjà une interruption, un cadre de plus l'alourdirait.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
