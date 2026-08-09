//
//  RushGridView.swift
//  ClipFlow
//
//  Vue grille : navigation directe dans les rushes à l'échelle (100+).
//  Vignette + numéro + badge d'état ; toucher = saut dans la timeline.
//

import SwiftUI
import CoreMedia

struct RushGridView: View {
    let project: ClipProject
    /// Rappel avec l'index du rush choisi.
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(project.orderedRushes.enumerated()), id: \.element.persistentModelID) { index, rush in
                    Button {
                        onSelect(index)
                    } label: {
                        RushGridCell(rush: rush, index: index)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .navigationTitle("Rushes (\(project.rushes.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer") { dismiss() }
            }
        }
    }
}

private struct RushGridCell: View {
    let rush: Rush
    let index: Int
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color(.systemGray5))
                }
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )

            // Numéro + durée.
            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .font(.caption.bold())
                Text(String(format: "%.1fs", rush.duration.seconds))
                    .font(.caption2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            // Badge : vert = traité (≥ 1 passage validé).
            if !rush.passages.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .background(Circle().fill(.white))
                    .padding(5)
            }
        }
        .task {
            guard thumbnail == nil, let sourcePath = rush.localSourceRelativePath else { return }
            let url = StorageManager.url(forSourceRelativePath: sourcePath)
            let midpoint = max(rush.duration.seconds / 2 - 0.05, 0)
            ThumbnailCache.shared.requestThumbnail(
                fileURL: url,
                key: sourcePath,
                time: CMTime(seconds: midpoint, preferredTimescale: 600)
            ) { image in
                thumbnail = image
            }
        }
    }
}
