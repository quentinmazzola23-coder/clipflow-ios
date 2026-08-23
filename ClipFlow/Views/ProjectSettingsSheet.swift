//
//  ProjectSettingsSheet.swift
//  ClipFlow
//
//  LES RÉGLAGES DU PROJET, dans une feuille qui reste ouverte.
//
//  Ils vivaient dans le menu ⋯. Un menu iOS se referme au premier choix : régler
//  la durée, puis le format, puis le recadrage, puis le suréchantillonnage,
//  c'était rouvrir le menu quatre fois — et redescendre à chaque fois dans le
//  sous-menu où l'interrupteur se trouvait. Quatre réglages qu'on touche
//  ensemble, presque toujours au même moment, coûtaient une dizaine de gestes.
//
//  Ici, on ouvre une fois, on règle ce qu'on veut, on ferme. Chaque
//  modification est enregistrée immédiatement : la fermeture ne valide rien,
//  elle ne fait que refermer — il n'y a donc rien à annuler, et pas de bouton
//  « Annuler » qui laisserait croire le contraire.
//
//  LES ACTIONS RESTENT DANS LE MENU. Analyser un rush, revoir ses clips,
//  libérer de l'espace : ce sont des gestes uniques, et un menu qui se referme
//  après est exactement ce qu'on veut. Seuls les réglages avaient besoin de
//  durer.
//

import SwiftUI
import SwiftData

struct ProjectSettingsSheet: View {
    @Bindable var project: ClipProject
    @Binding var devStatsEnabled: Bool
    /// Appelé quand la qualité d'aperçu change : le moteur de lecture doit
    /// recharger, la vue ne peut pas le faire à sa place.
    var onPreviewQualityChange: (Bool) -> Void
    /// Enregistrement du projet, tel que l'éditeur le fait partout ailleurs.
    var onTouch: () -> Void
    /// Demande d'ouverture de la feuille de durée exacte. Elle ne peut pas être
    /// présentée par-dessus celle-ci : l'éditeur l'ouvre une fois celle-ci
    /// refermée.
    var onCustomDuration: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Durée des clips") {
                    Picker("Durée finale", selection: durationModeBinding) {
                        ForEach(ExactDuration.presets, id: \.centiseconds) { preset in
                            Text(preset.label).tag(DurationMode.fixed(preset.centiseconds))
                        }
                        // La durée personnalisée courante reste visible et
                        // cochée quand elle ne fait pas partie des valeurs types.
                        if !project.durationToRushEnd,
                           !ExactDuration.presets.contains(where: {
                               $0.centiseconds == project.finalDurationCentiseconds
                           }) {
                            Text(project.finalDuration.label)
                                .tag(DurationMode.fixed(project.finalDurationCentiseconds))
                        }
                        Text("Jusqu'à la fin du rush").tag(DurationMode.toRushEnd)
                    }
                    .pickerStyle(.inline)

                    Button("Durée personnalisée…") {
                        // Refermer D'ABORD : iOS ne présente pas une feuille
                        // par-dessus une autre depuis la même vue, et la
                        // demande serait avalée sans un mot.
                        onCustomDuration()
                        dismiss()
                    }
                }

                Section("Format de la vidéo") {
                    Picker("Format", selection: Binding(
                        get: { project.outputFormat },
                        set: { project.outputFormat = $0; onTouch() }
                    )) {
                        ForEach(MontageOutputFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.inline)

                    Toggle("Recadrer plutôt que ceinturer", isOn: Binding(
                        get: { project.cropToFillOutput },
                        set: { project.cropToFillOutput = $0; onTouch() }
                    ))
                    Toggle("Suréchantillonner à l'export", isOn: Binding(
                        get: { project.upscaleOnExport },
                        set: { project.upscaleOnExport = $0; onTouch() }
                    ))
                } footer: {
                    Text("Export toujours en 4K, 60 images par seconde. "
                         + "Le recadrage se déplace au doigt sur l'aperçu.")
                }

                Section("Dérushage") {
                    Toggle("Toucher = centre du clip", isOn: Binding(
                        get: { project.touchAnchorIsCenter },
                        set: { newValue in
                            project.touchAnchorIsCenter = newValue
                            AppSettings.captureFlag(\.touchAnchorIsCenter, value: newValue)
                            onTouch()
                        }
                    ))
                    Toggle("Aperçu léger (540p, plus fluide)", isOn: Binding(
                        get: { project.previewLight },
                        set: { newValue in
                            project.previewLight = newValue
                            onPreviewQualityChange(newValue)
                            onTouch()
                        }
                    ))
                }

                Section {
                    // Flux optique : désactivé par défaut. Activé, il FABRIQUE
                    // les images intermédiaires (mouvement plus fluide) et peut
                    // donc fabriquer des artefacts ; désactivé, chaque image du
                    // ralenti est une vraie image du rush, répétée.
                    Toggle("Flux optique", isOn: Binding(
                        get: { project.opticalFlowEnabled },
                        set: { project.opticalFlowEnabled = $0; onTouch() }
                    ))
                    Toggle("Album Photos par projet", isOn: Binding(
                        get: { project.albumPerProject },
                        set: { project.albumPerProject = $0; onTouch() }
                    ))
                    Toggle("Stats développeur", isOn: $devStatsEnabled)
                } header: {
                    Text("Export")
                } footer: {
                    Text("Le flux optique fabrique les images intermédiaires : "
                         + "mouvement plus fluide, artefacts possibles. Sans lui, "
                         + "chaque image du ralenti est une vraie image du rush, "
                         + "répétée.")
                }

                Section {
                    Text("v\(BuildInfo.version) (\(BuildInfo.build)) · \(BuildInfo.stamp)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .onChange(of: devStatsEnabled) { _, enabled in
            enabled ? DevStatsMonitor.shared.start() : DevStatsMonitor.shared.stop()
        }
    }

    /// Mode de durée courant, écrit dans les deux champs du projet.
    private var durationModeBinding: Binding<DurationMode> {
        Binding(
            get: {
                project.durationToRushEnd
                    ? .toRushEnd
                    : .fixed(project.finalDurationCentiseconds)
            },
            set: { mode in
                switch mode {
                case .toRushEnd:
                    project.durationToRushEnd = true
                case .fixed(let centiseconds):
                    project.durationToRushEnd = false
                    project.finalDurationCentiseconds = centiseconds
                }
                onTouch()
            }
        )
    }
}
