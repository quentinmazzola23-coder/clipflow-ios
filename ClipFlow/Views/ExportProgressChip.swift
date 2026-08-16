//
//  ExportProgressChip.swift
//  ClipFlow
//
//  Pastille d'export de la barre flottante : « clip courant / total + % »,
//  PERMANENTE (« 0/0 · 0 % » au repos), et cliquable pour ouvrir la file.
//
//  VUE SÉPARÉE, ET C'EST LE POINT ESSENTIEL. La progression change plusieurs
//  fois par seconde pendant un rendu. Lire l'état de la file directement dans
//  le corps de l'éditeur y créait une dépendance d'observation : TOUTE la vue
//  se reconstruisait à chaque tick, et un menu ouvert repartait en haut à
//  chaque fois — impossible de le faire défiler pendant un export.
//
//  Isolée ici, seule cette pastille se redessine.
//

import SwiftUI

struct ExportProgressChip: View {

    var onTap: () -> Void

    var body: some View {
        let queue = RenderQueueController.shared.snapshot
        let hasWork = queue.totalJobs > 0
        Button(action: onTap) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Theme.accent.opacity(0.25), lineWidth: 3)
                    if queue.isRunning {
                        Circle()
                            .trim(from: 0, to: max(0.02, queue.currentProgress))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 16, height: 16)
                Text("\(queue.currentClipNumber)/\(queue.totalJobs) · \(Int(queue.currentProgress * 100)) %")
                    .font(.caption.monospacedDigit())
                    // Au repos, la pastille ne doit pas attirer l'œil autant
                    // qu'un rendu en cours.
                    .foregroundStyle(hasWork ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    // Chiffres jamais tronqués : ce sont les boutons d'action
                    // qui cèdent la place, pas la mesure.
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exports : \(queue.currentClipNumber) sur \(queue.totalJobs)")
        .accessibilityHint("Ouvre la file d'export")
    }
}
