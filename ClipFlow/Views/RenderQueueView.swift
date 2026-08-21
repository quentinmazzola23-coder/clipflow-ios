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
    @AppStorage("autoRetryFailedExports") private var autoRetry = true

    private var queue: RenderQueueController { RenderQueueController.shared }
    private var thermal: ThermalMonitor { ThermalMonitor.shared }

    private var pendingPassages: [Passage] {
        project.orderedPassages.filter { $0.exportState != .exported }
    }

    private var exportedPassages: [Passage] {
        project.orderedPassages.filter { $0.exportState == .exported }
    }

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
                    // Des passages attendent, rien ne tourne, aucune pause :
                    // état anormal. Le dire et offrir la sortie, plutôt que
                    // laisser un « 0/N » figé sans explication.
                    if queue.isStalled {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("File à l'arrêt alors que des clips attendent.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Relancer la file") { queue.restartIfIdle() }
                                .font(.caption.bold())
                        }
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
                Toggle("Relance automatique des échecs (3 essais)", isOn: $autoRetry)
                    .font(.subheadline)
                // Export au fil de la validation (comme avant). Compromis :
                // le rendu partage le décodeur avec l'aperçu — préférer OFF
                // sur les très longs triages.
                Toggle("Export automatique à la validation", isOn: $project.autoExportOnValidate)
                    .font(.subheadline)
            }

            // Actions EN HAUT (demande utilisateur).
            Section {
                Button {
                    let notExported = pendingPassages
                        .filter { $0.status != .rejete }
                        .map(\.persistentModelID)
                    queue.enqueue(passageIDs: notExported)
                } label: {
                    Label("Exporter tous les clips restants (\(pendingPassages.count))",
                          systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(pendingPassages.isEmpty)
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

            // Seuls les passages restants sont listés ; les réussites sont
            // rangées dans le sous-menu « Exportés » au fur et à mesure.
            if !pendingPassages.isEmpty {
                Section("À exporter (\(pendingPassages.count))") {
                    ForEach(pendingPassages) { passage in
                        passageRow(passage)
                    }
                }
            }

            if !exportedPassages.isEmpty {
                Section {
                    DisclosureGroup("Exportés (\(exportedPassages.count)) ✓") {
                        ForEach(exportedPassages) { passage in
                            HStack {
                                Text(passage.exportedFilename ?? "clip")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
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

    @ViewBuilder
    private func passageRow(_ passage: Passage) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(passage.exportedFilename
                     ?? "Clip \(passage.validationIndex + 1)")
                    .font(.subheadline)
                if let error = passage.lastExportError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            switch passage.exportState {
            case .rendering:
                ProgressView()
            case .failed:
                Button("Relancer") {
                    queue.enqueue(passageIDs: [passage.persistentModelID])
                }
                .font(.caption)
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}
