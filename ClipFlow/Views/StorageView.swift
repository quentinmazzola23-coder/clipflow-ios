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

    var body: some View {
        List {
            Section("Espace disponible sur l'iPhone") {
                Text(StorageManager.formatBytes(freeSpace))
                    .font(.title3.monospacedDigit())
            }
            Section("Occupation ClipFlow") {
                // Suppression directe, sans confirmation (demande utilisateur).
                row("Proxys (anciens, inutilisés)", size: proxiesSize) {
                    StorageManager.clearProxies()
                    ThumbnailCache.shared.clearMemory()
                    refresh()
                }
                row("Plages sources en cache", size: rangesSize) {
                    StorageManager.clearCachedRanges()
                    refresh()
                }
                row("Rendus temporaires", size: exportsSize) {
                    StorageManager.clearExports()
                    refresh()
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
