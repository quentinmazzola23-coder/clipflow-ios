//
//  ExportLiveActivity.swift
//  ClipFlowWidgets
//
//  Live Activity de la file d'export : Dynamic Island (iPhone 16 Pro) +
//  bannière écran verrouillé. Affiche clip courant / total et la progression
//  du clip en cours.
//

import ActivityKit
import WidgetKit
import SwiftUI

/// Jaune ClipFlow (répliqué : l'extension n'embarque pas Theme.swift).
private let clipFlowAccent = Color(red: 1.0, green: 0.8, blue: 0.0)

struct ExportLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExportActivityAttributes.self) { context in
            // Écran verrouillé / bannière.
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(clipFlowAccent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("\(context.state.clipIndex)/\(context.state.totalClips)")
                            .font(.headline.monospacedDigit())
                    } icon: {
                        Image(systemName: "film.stack")
                            .foregroundStyle(clipFlowAccent)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(clipFlowAccent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.clipName)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        ProgressView(value: context.state.progress)
                            .tint(clipFlowAccent)
                        if context.state.failedClips > 0 {
                            Text("\(context.state.failedClips) échec(s)")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }
            } compactLeading: {
                Label {
                    Text("\(context.state.clipIndex)/\(context.state.totalClips)")
                        .font(.caption2.monospacedDigit())
                } icon: {
                    Image(systemName: "film.stack")
                        .foregroundStyle(clipFlowAccent)
                }
                .labelStyle(.titleAndIcon)
            } compactTrailing: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(clipFlowAccent)
            } minimal: {
                ProgressView(value: context.state.progress)
                    .progressViewStyle(.circular)
                    .tint(clipFlowAccent)
            }
            .keylineTint(clipFlowAccent)
        }
    }
}

private struct LockScreenView: View {
    let state: ExportActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Export \(state.clipIndex)/\(state.totalClips)", systemImage: "film.stack")
                    .font(.headline)
                    .foregroundStyle(clipFlowAccent)
                Spacer()
                Text(state.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            Text(state.clipName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            ProgressView(value: state.progress)
                .tint(clipFlowAccent)
            if state.failedClips > 0 {
                Text("\(state.failedClips) échec(s)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
    }
}
