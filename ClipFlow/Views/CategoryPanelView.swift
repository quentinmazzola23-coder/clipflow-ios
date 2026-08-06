//
//  CategoryPanelView.swift
//  ClipFlow
//
//  Attribution rapide de catégories : boutons tactiles par groupe.
//  Les valeurs sélectionnées sont encodées "groupe:option".
//

import SwiftUI

struct CategoryPanelView: View {
    let groups: [CategoryGroup]
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.name.capitalized)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(group.options, id: \.self) { option in
                                    let key = "\(group.name):\(option)"
                                    Button {
                                        if selected.contains(key) {
                                            selected.remove(key)
                                        } else {
                                            selected.insert(key)
                                        }
                                    } label: {
                                        Text(option)
                                            .font(.subheadline)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(
                                                selected.contains(key) ? Color.accentColor : Color(.systemGray5),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(selected.contains(key) ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Catégories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Effacer") { selected.removeAll() }
                }
            }
        }
    }
}

/// Disposition en lignes qui passent à la ligne (chips de catégories).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
