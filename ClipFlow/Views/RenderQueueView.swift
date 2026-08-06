//
//  RenderQueueView.swift
//  ClipFlow
//
//  File de rendu : progression par passage et globale, pause, annulation,
//  relance des échecs, partage du manifeste.
//

import SwiftUI
import SwiftData

struct RenderQueueView: View {
    @Bindable var project: ClipProject
    @Environment(\.dismiss) private var dismiss
    @State private var manifestURL: URL?

    private var queue: RenderQueueController { RenderQueueController.shared }
    private var thermal: ThermalMonitor { ThermalMonitor.shared }

    var body: some View {
        List {
            Section("File de rendu") {
                let snapshot = queue.snapshot
                if snapshot.isRunning || snapshot.totalJobs > 0 {
                    if let name = snapshot.currentPassageName {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name).font(.subheadline.bold())
                            ProgressView(value: snapshot.currentProgress)
                        }
                    }
                    ProgressView(
                        value: Double(snapshot.finishedJobs),
                        total: Double(max(snapshot.totalJobs, 1))
                    ) {
                        Text("Global : \(snapshot.finishedJobs)/\(snapshot.totalJobs) — \(snapshot.failedJobs) échec(s)")
                            .font(.caption)
                    }
                    if let reason = snapshot.pauseReason {
                        Label(reason, systemImage: "thermometer.medium")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let summary = snapshot.lastResultSummary {
                        Text(summary).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        if snapshot.isPaused {
                            Button("Reprendre") { queue.resume() }
                        } else {
                            Button("Pause") { queue.pause() }
                        }
                        Spacer()
                        Button("Tout annuler", role: .destructive) { queue.cancelAll() }
                    }
                } else {
                    Text("Aucun rendu en cours.").foregroundStyle(.secondary)
                }
            }

            Section("Passages") {
                ForEach(project.orderedPassages) { passage in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(passage.exportedFilename
                                 ?? "Passage \(passage.validationIndex + 1) — \(passage.rush?.originalFilename ?? "")")
                                .font(.subheadline)
                            if let error = passage.lastExportError {
                                Text(error).font(.caption2).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        switch passage.exportState {
                        case .exported:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .rendering:
                            ProgressView()
                        case .failed:
                            Button("Relancer") {
                                queue.enqueue(passageIDs: [passage.persistentModelID])
                            }
                            .font(.caption)
                        case .queued:
                            Image(systemName: "clock").foregroundStyle(.secondary)
                        case .notExported:
                            EmptyView()
                        }
                    }
                }
            }

            Section {
                Button {
                    let notExported = project.orderedPassages
                        .filter { $0.exportState != .exported && $0.status != .rejete }
                        .map(\.persistentModelID)
                    queue.enqueue(passageIDs: notExported)
                } label: {
                    Label("Exporter tous les passages restants", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    manifestURL = try? ManifestExporter.writeManifest(for: project)
                } label: {
                    Label("Générer le manifeste JSON", systemImage: "doc.text")
                }
                if let manifestURL {
                    ShareLink(item: manifestURL) {
                        Label("Partager le manifeste", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Exports")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fermer") { dismiss() }
            }
        }
    }
}
