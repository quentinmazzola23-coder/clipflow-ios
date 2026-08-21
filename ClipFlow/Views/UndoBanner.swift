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

/// Détient les suppressions en sursis et leurs minuteurs.
///
/// UNE PILE, et non un emplacement unique. La première version consommait la
/// suppression précédente dès qu'une nouvelle arrivait, en se justifiant par
/// « deux suppressions de suite veulent dire que la première était voulue ».
/// C'était faux : écarter quatre rushes ratés à la file est précisément le
/// rythme du dérushage, donc le moment où le filet sert le plus. Trois
/// suppressions passaient définitivement, sans un mot, sous un bandeau qui
/// affichait toujours le même libellé.
///
/// Chaque suppression a donc son propre sursis, et « Annuler » défait la plus
/// récente — l'ordre naturel quand on revient sur ses pas.
@Observable
@MainActor
final class DeletionUndo {
    private(set) var items: [PendingDeletion] = []
    private var timers: [UUID: Task<Void, Never>] = [:]

    /// La suppression annulable maintenant : la dernière posée.
    var pending: PendingDeletion? { items.last }
    /// Combien attendent encore — le bandeau le dit quand il y en a plusieurs.
    var count: Int { items.count }

    /// Délai de grâce. Cinq secondes : le temps de voir le bandeau et de
    /// réagir, sans laisser un état incertain traîner sur l'écran.
    static let graceSeconds: Double = 5

    func schedule(label: String,
                  commit: @escaping () -> Void,
                  restore: @escaping () -> Void) {
        let item = PendingDeletion(label: label, commit: commit, restore: restore)
        items.append(item)
        timers[item.id] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.graceSeconds))
            guard !Task.isCancelled,
                  let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items.remove(at: index)
            timers[item.id] = nil
            item.commit()
        }
    }

    func undo() {
        guard let item = items.popLast() else { return }
        timers[item.id]?.cancel()
        timers[item.id] = nil
        item.restore()
    }

    /// Consomme immédiatement TOUT ce qui attend — à appeler en quittant
    /// l'écran : un sursis ne doit pas survivre à la vue qui l'affichait, sinon
    /// plus rien ne peut l'annuler et l'objet resterait masqué sans jamais être
    /// effacé. Dans l'ordre où les suppressions ont été demandées.
    func consumeNow() {
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        let waiting = items
        items.removeAll()
        for item in waiting { item.commit() }
    }
}

/// Bandeau d'annulation, à poser en surimpression au bas d'un écran.
struct UndoBannerView: View {
    let pending: PendingDeletion
    /// Nombre total de suppressions encore annulables.
    var count: Int = 1
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // La rafale est DITE : sans ce compte, quatre suppressions
            // d'affilée affichaient quatre fois le même libellé, et rien
            // n'indiquait combien restaient récupérables.
            Text(count > 1 ? "\(pending.label) · \(count) annulables" : pending.label)
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
