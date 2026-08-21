//
//  OutputFormatSheet.swift
//  ClipFlow
//
//  CHOIX DU FORMAT DE SORTIE, proposé une fois les rushes importés.
//
//  Il n'apparaît QUE lorsque la question se pose vraiment : des rushes tous
//  filmés dans le même sens n'ont besoin d'aucun arbitrage, et l'app ne pose
//  pas de questions dont elle connaît la réponse. Mélanger du paysage et du
//  vertical, en revanche, force un choix — quel que soit le format retenu, une
//  partie des rushes sera recadrée.
//
//  Le choix reste modifiable à tout moment depuis l'écran de montage : cette
//  feuille est une commodité au bon moment, pas un passage obligé.
//

import SwiftUI
import SwiftData

struct OutputFormatSheet: View {
    @Bindable var project: ClipProject
    var survey: RushFormatSurvey

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Format de la vidéo")
                    .font(.title3.weight(.semibold))
                Text(survey.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if survey.isMixed {
                    Text("Vos rushes n'ont pas tous la même orientation : "
                         + "quel que soit le format, une partie sera recadrée.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 14) {
                formatCard(.landscape, ratio: 16.0 / 9)
                formatCard(.portrait, ratio: 9.0 / 16)
            }

            Toggle(isOn: Binding(
                get: { project.cropToFillOutput },
                set: { newValue in
                    project.cropToFillOutput = newValue
                    try? modelContext.save()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recadrer pour remplir le cadre")
                        .font(.subheadline)
                    Text(project.cropToFillOutput
                         ? "Les bords hors cadre sont coupés — aucune bande noire."
                         : "L'image entière est conservée, avec des bandes noires.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accent)

            Text("Export toujours en 4K, 60 images par seconde.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                dismiss()
            } label: {
                Label("Continuer", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
        }
        .padding(20)
        .presentationDetents([.height(430)])
    }

    /// Une vignette par format : la forme se juge à l'œil, pas au libellé.
    private func formatCard(_ format: MontageOutputFormat, ratio: Double) -> some View {
        let isCurrent = project.outputFormat.resolved(
            sourceOriented: firstRushSize) == format
        return Button {
            project.outputFormat = format
            try? modelContext.save()
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Theme.accent.opacity(0.35) : Color.white.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isCurrent ? Theme.accent : .white.opacity(0.25),
                                    lineWidth: isCurrent ? 2 : 0.5)
                    }
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(height: 96)
                Text(format.shortLabel)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                Text(format == .landscape ? "3840 × 2160" : "2160 × 3840")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Taille du premier rush, pour résoudre le mode automatique.
    private var firstRushSize: CGSize {
        project.orderedRushes.first?.orientedSize ?? .zero
    }
}
