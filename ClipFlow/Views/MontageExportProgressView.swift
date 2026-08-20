//
//  MontageExportProgressView.swift
//  ClipFlow
//
//  Progression de l'export du montage — VUE SÉPARÉE, et c'est le point.
//
//  `MontageExportController.progress` change plusieurs fois par seconde. La
//  lire dans le corps de l'écran de montage y créerait une dépendance
//  d'observation : tout l'écran (forme d'onde, densité, en-tête) se
//  reconstruirait à chaque image encodée. Le même défaut a déjà coûté un
//  menu impossible à faire défiler pendant un export.
//

import SwiftUI

struct MontageExportProgressView: View {

    var body: some View {
        let progress = MontageExportController.shared.progress
        HStack(spacing: 8) {
            // Style linéaire : sur iOS, le style circulaire avec `value` rend
            // un simple sablier indéterminé — la fraction disparaît.
            ProgressView(value: progress)
                .frame(width: 90)
            Text("\(Int(progress * 100)) %")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityLabel("Export du montage : \(Int(progress * 100)) pour cent")
    }
}
