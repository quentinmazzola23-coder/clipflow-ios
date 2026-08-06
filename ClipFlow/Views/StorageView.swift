//
//  StorageView.swift
//  ClipFlow
//
//  Gestion du stockage : tailles par catégorie, suppressions ciblées.
//  Ne supprime JAMAIS d'original dans Photos.
//

import SwiftUI

struct StorageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var proxiesSize: Int64 = 0
    @State private var rangesSize: Int64 = 0
    @State private var sourcesSize: Int64 = 0
    @State private var exportsSize: Int64 = 0
    @State private var freeSpace: Int64 = 0
    @State private var confirmAction: StorageAction?

    enum StorageAction: String, Identifiable {
        case proxies, ranges, exports
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section("Espace disponible sur l'iPhone") {
                Text(StorageManager.formatBytes(freeSpace))
                    .font(.title3.monospacedDigit())
            }
            Section("Occupation ClipFlow") {
                row("Proxys (régénérables)", size: proxiesSize) {
                    confirmAction = .proxies
                }
                row("Plages sources en cache", size: rangesSize) {
                    confirmAction = .ranges
                }
                row("Rendus temporaires", size: exportsSize) {
                    confirmAction = .exports
                }
                HStack {
                    Text("Copies sources (mode hors-ligne)")
                    Spacer()
                    Text(StorageManager.formatBytes(sourcesSize))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Les vidéos originales de votre photothèque ne sont jamais supprimées par ClipFlow. Supprimer les proxys est sans risque : ils se régénèrent automatiquement. Supprimer une plage en cache peut rendre un passage non exportable hors ligne.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Stockage")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { dismiss() }
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Supprimer ces fichiers ?",
            isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } })
        ) {
            Button("Supprimer", role: .destructive) {
                switch confirmAction {
                case .proxies: StorageManager.clearProxies()
                case .ranges: StorageManager.clearCachedRanges()
                case .exports: StorageManager.clearExports()
                case nil: break
                }
                ThumbnailCache.shared.clearMemory()
                refresh()
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private func row(_ title: String, size: Int64, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(StorageManager.formatBytes(size))
                .foregroundStyle(.secondary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func refresh() {
        proxiesSize = StorageManager.proxiesSize()
        rangesSize = StorageManager.cachedRangesSize()
        sourcesSize = StorageManager.sourcesSize()
        exportsSize = StorageManager.exportsSize()
        freeSpace = StorageManager.availableCapacity()
    }
}
