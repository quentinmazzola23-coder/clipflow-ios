//
//  ProjectEditorView.swift
//  ClipFlow
//
//  Écran principal : visionneuse (proxy), timeline continue, sélection à durée
//  fixe, validation, catégories, importation PhotosPicker, progression des
//  tâches de fond. Le mode paysage agrandit la visionneuse et la timeline.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import AudioToolbox

struct ProjectEditorView: View {
    @Bindable var project: ClipProject
    @Environment(\.modelContext) private var modelContext

    // Importation — service partagé (survit à la navigation).
    @State private var pickerItems: [PhotosPickerItem] = []
    /// Moments forts repérés, par identité de rush (clé du cache disque).
    @State private var motionPeaks: [String: [MotionPeak]] = [:]
    /// Rush en cours d'analyse — l'interface doit le dire, l'analyse dure.
    @State private var analyzingRushKey: String?
    @State private var analysisTask: Task<Void, Never>?
    /// Présentation programmatique du sélecteur Photos (bouton +, illustration
    /// centrale, et ouverture AUTOMATIQUE à l'arrivée dans un projet vide).
    @State private var showPicker = false
    /// L'ouverture automatique ne se produit qu'une fois par apparition.
    @State private var autoPickerLaunched = false
    private var importer: ImportController { ImportController.shared }

    /// Segments MÉMOÏSÉS : reconstruits uniquement quand les rushes changent
    /// (import, suppression) — plus de tri + projection à chaque tick de lecture.
    @State private var segments: [TimelineSegment] = []

    // Navigation temporelle. Le positionnement externe passe par un jeton
    // one-shot (voir ProgrammaticSeek).
    @State private var playhead: Double = 0
    @State private var seek: ProgrammaticSeek?
    @State private var seekCounter = 0

    // Sélection courante (temps LOCAL au rush, base source).
    @State private var selectionRushIndex: Int?
    @State private var selectionRange: CMTimeRange?
    /// Passage validé en cours d'ÉDITION (tap sur un clip vert) : Rejeter
    /// devient « Suppr. clip », Valider met à jour la position.
    @State private var editingPassageID: PersistentIdentifier?
    /// Stats développeur (menu ⋯).
    @AppStorage("devStatsEnabled") private var devStatsEnabled = false

    // UI.
    @State private var playback = ProxyPlaybackEngine()
    @State private var showReview = false
    @State private var showExports = false
    @State private var errorMessage: String?
    @State private var exportToast: String?
    @State private var showGrid = false
    /// Son de la prévisualisation coupé (mémorisé entre sessions).
    @AppStorage("previewMuted") private var previewMuted = false
    @State private var slowPreview = false
    @State private var showReleaseConfirm = false

    private let validateHaptic = UINotificationFeedbackGenerator()

    // MARK: - Modèle de timeline

    /// Nom lisible d'un rush : les copies issues du picker portent un UUID
    /// (aucune valeur informative) → « Rush n ».
    private func rushDisplayName(_ rush: Rush, index: Int) -> String {
        let stem = (rush.originalFilename as NSString).deletingPathExtension
        if UUID(uuidString: stem) != nil || stem.count >= 30 {
            return "Rush \(index + 1)"
        }
        return stem
    }

    private func rebuildSegments() {
        var offset: Double = 0
        segments = project.orderedRushes.enumerated().map { index, rush in
            let stem = (rush.originalFilename as NSString).deletingPathExtension
            let isUUIDName = UUID(uuidString: stem) != nil || stem.count >= 30
            let segment = TimelineSegment(
                rushIndex: index,
                title: isUUIDName ? "\(index + 1)" : "\(index + 1) · \(stem)",
                mediaURL: rush.localSourceRelativePath.map { StorageManager.url(forSourceRelativePath: $0) },
                thumbKey: rush.localSourceRelativePath ?? rush.originalFilename,
                startOffset: offset,
                duration: rush.duration.seconds,
                frameRate: rush.nominalFrameRate
            )
            offset += rush.duration.seconds
            return segment
        }
    }

    private func segmentStart(rushIndex: Int) -> Double {
        segments.first(where: { $0.rushIndex == rushIndex })?.startOffset ?? 0
    }

    // MARK: - Moments forts

    /// Identité stable d'un rush pour le cache d'analyse — la même que celle
    /// du cache de vignettes (jamais l'index : un réordonnancement mélangerait
    /// les résultats entre rushes).
    private func motionKey(for rush: Rush) -> String {
        rush.localSourceRelativePath ?? rush.originalFilename
    }

    /// Marqueurs de TOUS les rushes analysés, convertis en temps global.
    private var globalMarkers: [Double] {
        var result: [Double] = []
        for (index, rush) in project.orderedRushes.enumerated() {
            guard let peaks = motionPeaks[motionKey(for: rush)] else { continue }
            let start = segmentStart(rushIndex: index)
            result.append(contentsOf: peaks.map { start + $0.time })
        }
        return result
    }

    /// Charge les moments déjà calculés (cache disque) sans rien analyser.
    private func loadCachedPeaks() {
        let spacing = fixedSourceDuration.seconds
        for rush in project.orderedRushes {
            let key = motionKey(for: rush)
            guard motionPeaks[key] == nil,
                  let cached = MotionPeakStore.peaks(key: key, spacing: spacing) else { continue }
            motionPeaks[key] = cached
        }
    }

    /// Analyse le rush sous la tête de lecture.
    ///
    /// Un rush à la fois, volontairement : l'analyse décode la vidéo et se
    /// dispute le décodeur avec la lecture. En analyser plusieurs en parallèle
    /// les priverait mutuellement — leçon déjà payée sur le banc d'essai.
    private func analyzeCurrentRush() {
        guard let rush = currentRush,
              let path = rush.localSourceRelativePath else {
            errorMessage = "Ce rush n'a plus sa copie locale — analyse impossible."
            return
        }
        let key = motionKey(for: rush)
        guard analyzingRushKey == nil else { return }

        let url = StorageManager.url(forSourceRelativePath: path)
        let spacing = fixedSourceDuration.seconds
        analyzingRushKey = key
        analysisTask = Task {
            defer { analyzingRushKey = nil }
            do {
                let samples = try await Task.detached(priority: .userInitiated) {
                    try await MotionAnalyzer.samples(for: url)
                }.value
                let peaks = MotionAnalyzer.peaks(from: samples, minimumSpacing: spacing)
                guard !Task.isCancelled else { return }
                motionPeaks[key] = peaks
                MotionPeakStore.save(peaks, key: key, spacing: spacing)
                if peaks.isEmpty {
                    errorMessage = "Aucun moment ne se détache nettement dans ce rush : le mouvement y est régulier."
                }
            } catch is CancellationError {
                // Abandon volontaire : rien à signaler.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Efface les repères du projet (mémoire ET cache disque).
    private func clearMotionPeaks() {
        for rush in project.orderedRushes {
            MotionPeakStore.clear(key: motionKey(for: rush))
        }
        motionPeaks.removeAll()
    }

    /// Amène la tête de lecture au prochain moment fort (tous rushes confondus).
    private func jumpToNextPeak() {
        let markers = globalMarkers.sorted()
        guard !markers.isEmpty else { return }
        // Bouclage : après le dernier, on revient au premier.
        let target = markers.first(where: { $0 > playhead + 0.05 }) ?? markers[0]
        playhead = target
        seekCounter += 1
        seek = ProgrammaticSeek(token: seekCounter, time: target)
        if let index = rushIndex(atGlobalTime: target) {
            let rushes = project.orderedRushes
            if index < rushes.count {
                playback.load(rush: rushes[index])
                playback.seek(to: CMTime(seconds: target - segmentStart(rushIndex: index),
                                         preferredTimescale: 600))
            }
        }
    }

    private func rushIndex(atGlobalTime time: Double) -> Int? {
        segments.last(where: { $0.startOffset <= time })?.rushIndex
    }

    private var currentRushIndex: Int? { rushIndex(atGlobalTime: playhead) }
    private var currentRush: Rush? {
        currentRushIndex.flatMap { index in
            let rushes = project.orderedRushes
            return index < rushes.count ? rushes[index] : nil
        }
    }

    private var overlays: [TimelineOverlay] {
        var result: [TimelineOverlay] = []
        for passage in project.orderedPassages {
            guard let rush = passage.rush,
                  let index = project.orderedRushes.firstIndex(where: { $0 === rush }) else { continue }
            result.append(TimelineOverlay(
                kind: .validated,
                globalStart: segmentStart(rushIndex: index) + passage.start.seconds,
                duration: passage.sourceDuration.seconds
            ))
        }
        if let index = selectionRushIndex, let range = selectionRange {
            result.append(TimelineOverlay(
                kind: .currentSelection,
                globalStart: segmentStart(rushIndex: index) + range.start.seconds,
                duration: range.duration.seconds
            ))
        }
        return result
    }

    /// Durée SOURCE fixe de la sélection = durée finale × vitesse.
    private var fixedSourceDuration: CMTime {
        TimeMath.sourceDuration(
            final: project.finalDuration,
            speed: RationalSpeed(numerator: project.speedNumerator, denominator: project.speedDenominator)
        )
    }

    // MARK: - Corps

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                playerArea
                    .frame(maxHeight: isLandscape ? .infinity : geometry.size.height * 0.54)
                statusBar
                TimelineView(
                    segments: segments,
                    overlays: overlays,
                    markers: globalMarkers,
                    seek: seek,
                    onScrub: handleScrub,
                    onTap: handleTap,
                    onSelectionDrag: handleSelectionDrag,
                    onSelectionDragEnded: persistAfterMove
                )
                .frame(height: isLandscape ? 100 : 120)
                .overlay(alignment: .leading) {
                    // Coupe-son de la prévisualisation, sur le bord gauche.
                    Button {
                        previewMuted.toggle()
                        playback.muted = previewMuted
                    } label: {
                        Image(systemName: previewMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: previewMuted ? .red : .primary, diameter: 36))
                    .accessibilityLabel(previewMuted ? "Rétablir le son" : "Couper le son")
                    .padding(.leading, 8)
                }
                controlBar(isLandscape: isLandscape)
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) {
            // Toast de fin d'exports : la file tourne en fond, l'utilisateur
            // n'a jamais à ouvrir l'écran Exports pour savoir si c'est fini.
            if let exportToast {
                Text(exportToast)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.green.opacity(0.55)), in: Capsule())
                    .padding(.bottom, 116)
                    .transition(.opacity)
            }
        }
        .onChange(of: RenderQueueController.shared.snapshot.isRunning) { wasRunning, isRunning in
            let snapshot = RenderQueueController.shared.snapshot
            if wasRunning, !isRunning, snapshot.finishedJobs > 0 {
                let failures = snapshot.failedJobs > 0 ? " · \(snapshot.failedJobs) échec(s)" : ""
                withAnimation { exportToast = "\(snapshot.finishedJobs) export(s) terminé(s) ✓\(failures)" }
                AudioServicesPlaySystemSound(1001)
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { exportToast = nil }
                }
            }
        }
        .sheet(isPresented: $showReview) {
            NavigationStack { ReviewView(project: project) }
        }
        .sheet(isPresented: $showGrid) {
            NavigationStack {
                RushGridView(project: project) { index in
                    showGrid = false
                    jump(toRushIndex: index)
                }
            }
        }
        .sheet(isPresented: $showExports) {
            NavigationStack { RenderQueueView(project: project) }
        }
        // Sélecteur Photos unique, présentable depuis le bouton +,
        // l'illustration centrale, ou automatiquement (projet vide).
        .photosPicker(
            isPresented: $showPicker,
            selection: $pickerItems,
            selectionBehavior: .default,     // sélection rapide par glissement
            matching: .videos,
            preferredItemEncoding: .current
        )
        .alert("ClipFlow", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Libérer les copies sources ?",
            isPresented: $showReleaseConfirm,
            titleVisibility: .visible
        ) {
            Button("Libérer l'espace", role: .destructive) {
                guard !RenderQueueController.shared.isBusy() else {
                    errorMessage = "Export en cours — libération possible une fois la file terminée (un fichier en cours de lecture ne doit pas être supprimé)."
                    return
                }
                let freed = MediaAvailabilityService.releaseSources(in: project)
                try? modelContext.save()
                rebuildSegments()
                errorMessage = "Espace libéré : \(StorageManager.formatBytes(freed)). Les originaux restent intacts dans Photos."
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Supprime les copies locales des rushes dont tous les passages sont déjà mis en cache pour l'export. Les originaux dans Photos ne sont jamais touchés. Une nouvelle sélection dans un rush libéré ne pourra plus être exportée sans réimporter la vidéo.")
        }
        .task { await retryMissingCaches() }
        .onChange(of: importer.progress?.completed) { _, _ in
            // Les rushes apparaissent au fil de l'importation.
            rebuildSegments()
        }
        .onChange(of: importer.completionToken) { _, _ in
            rebuildSegments()
            seekCounter += 1
            seek = ProgrammaticSeek(token: seekCounter, time: playhead)
            playback.load(rush: currentRush)
            if !importer.lastErrors.isEmpty {
                errorMessage = "Importation terminée avec \(importer.lastErrors.count) erreur(s) :\n"
                    + importer.lastErrors.prefix(5).joined(separator: "\n")
            }
        }
        .onAppear {
            // Réglages globaux appliqués à l'ouverture (maintien entre projets).
            AppSettings.apply(to: project)
            rebuildSegments()
            RenderQueueController.shared.configure(container: modelContext.container)
            playback.lightPreview = project.previewLight
            playback.muted = previewMuted
            if devStatsEnabled { DevStatsMonitor.shared.start() }
            // La timeline suit la lecture (le scrubbing manuel, lui, met en pause).
            playback.onTick = { time in
                handlePlaybackTick(time)
            }
            // Projet vide (fraîchement créé ou non) : le sélecteur Photos
            // s'ouvre de lui-même — zéro tap entre « Nouveau projet » et le
            // choix des rushes. Une seule fois par apparition, jamais pendant
            // une importation en cours.
            // Repères déjà calculés : rétablis sans rien réanalyser.
            loadCachedPeaks()
            if !autoPickerLaunched && project.rushes.isEmpty && importer.progress == nil {
                autoPickerLaunched = true
                showPicker = true
            }
        }
        .onDisappear {
            // Retour à la liste des projets : la lecture s'arrête toujours,
            // et une analyse en cours n'a plus de destinataire.
            playback.pause()
            analysisTask?.cancel()
            analysisTask = nil
        }
    }

    // MARK: - Sous-vues

    private var playerArea: some View {
        ZStack {
            PlayerLayerView(player: playback.player)
            if project.rushes.isEmpty && importer.progress == nil {
                // L'illustration centrale EST un bouton d'import (même picker
                // que le + de la barre).
                Button {
                    showPicker = true
                } label: {
                    ContentUnavailableView(
                        "Aucun rush",
                        systemImage: "photo.badge.plus",
                        description: Text("Touchez ici (ou le bouton +) pour importer des vidéos.")
                    )
                }
                .buttonStyle(.plain)
            }
            // Bandeau compact EN HAUT : n'occulte pas la visionneuse — le
            // triage peut commencer pendant l'importation.
            if let progress = importer.progress {
                VStack {
                    ImportProgressBanner(
                        progress: progress,
                        startedAt: importer.startedAt,
                        onCancel: { importer.cancel() }
                    )
                    Spacer()
                }
            }
            // Stats développeur (menu ⋯ → Stats développeur).
            if devStatsEnabled {
                VStack {
                    HStack {
                        Spacer()
                        DevStatsOverlay(stats: DevStatsMonitor.shared)
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
        }
        .onChange(of: currentRushIndex) { _, _ in
            playback.load(rush: currentRush)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let rush = currentRush, let index = currentRushIndex {
                Text("Rush \(index + 1)/\(project.rushes.count)")
                    .font(.footnote.bold().monospacedDigit())
                Text(rushDisplayName(rush, index: index))
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f s", rush.duration.seconds))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                availabilityBadge(rush.availability)
            } else {
                Text("Touchez la timeline pour créer une sélection de \(project.finalDuration.label)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Timecodes de la sélection courante (début → fin dans le rush).
            if let range = selectionRange {
                // Position au centième RETIRÉE : la règle graduée de la
                // timeline situe la sélection bien mieux qu'un couple de
                // nombres, et s'adapte au zoom.
                Text("✂︎ \(project.finalDuration.label)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            // Progression globale du triage.
            let treated = project.orderedRushes.filter { !$0.passages.isEmpty }.count
            Text("\(treated)/\(project.rushes.count) traités · \(project.passages.count) passages")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(treated == project.rushes.count && !project.rushes.isEmpty ? .green : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func availabilityBadge(_ availability: RushAvailability) -> some View {
        let (text, color): (String, Color) = switch availability {
        case .offlineReady: ("hors ligne ✓", .green)
        case .localReady: ("local", .blue)
        case .importing: ("import…", .orange)
        case .needsICloudDownload: ("iCloud requis", .red)
        case .unavailable: ("indisponible", .red)
        case .sourceReleased: ("source libérée", .orange)
        case .unknown: ("?", .gray)
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
    }

    // MARK: Barre de commandes — verre liquide, adaptative.
    // Portrait : deux rangées ; paysage : une rangée compacte (visionneuse max).

    @ViewBuilder
    private var transportButtons: some View {
        // Navigation manuelle entre rushes (aucun passage automatique).
        Button { goToRush(offset: -1) } label: { Image(systemName: "chevron.backward.2") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Rush précédent")
            .disabled((currentRushIndex ?? 0) <= 0)
            .keyboardShortcut(.leftArrow, modifiers: [.command])
        Button { goToRush(offset: 1) } label: { Image(systemName: "chevron.forward.2") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Rush suivant")
            .disabled(currentRushIndex.map { $0 >= project.rushes.count - 1 } ?? true)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
        // Saut direct au prochain rush sans passage validé.
        Button { goToNextUntreatedRush() } label: { Image(systemName: "arrow.right.to.line") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Prochain rush non traité")
            .disabled(project.rushes.isEmpty)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])

        // Image par image sur la sélection.
        Button { nudgeSelection(frames: -1) } label: { Image(systemName: "backward.frame") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Image précédente")
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(selectionRange == nil)
        Button {
            playback.isPlaying ? playback.pause() : playback.play()
        } label: {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(GlassIconButtonStyle(tint: Theme.accent, diameter: 44))
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Lecture")
        .keyboardShortcut(.space, modifiers: [])
        Button { nudgeSelection(frames: 1) } label: { Image(systemName: "forward.frame") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Image suivante")
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(selectionRange == nil)

        // Boucle de la sélection courante.
        Button { playSelectionLoop() } label: { Image(systemName: "repeat") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Lire la sélection en boucle")
            .disabled(selectionRange == nil)

        // Bascule prévisualisation ralentie 0,5× (n'affecte pas l'export).
        Button {
            slowPreview.toggle()
            playback.slowPreview = slowPreview
            playback.refreshRate()
        } label: {
            Image(systemName: slowPreview ? "tortoise.fill" : "tortoise")
        }
        .buttonStyle(GlassIconButtonStyle(tint: slowPreview ? Theme.accent : .primary, diameter: 40))
        .accessibilityLabel("Prévisualisation au ralenti")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Spacer()

        if editingPassageID != nil {
            // Mode édition d'un clip validé : suppression directe du clip.
            Button("Suppr. clip", role: .destructive) { deleteEditingPassage() }
                .buttonStyle(.glass)
        } else {
            // Écarter le RUSH sous le curseur, pas seulement la sélection :
            // c'est le geste utile du triage — un rush inintéressant sort de
            // la timeline en un appui. Ses passages déjà validés survivent
            // (relation .nullify) et s'exportent via leurs plages cachées.
            Button("Suppr. rush", role: .destructive) {
                deleteRushUnderPlayhead()
            }
            .buttonStyle(.glass)
            .disabled(currentRush == nil)

            // Valide le clip PUIS purge le rush de la timeline (le clip
            // s'exporte via sa plage cachée).
            Button("Val. + Suppr.") { validateAndDeleteRush() }
                .buttonStyle(.glass)
                .disabled(selectionRange == nil)
        }

        Button(editingPassageID != nil ? "Mettre à jour" : "Valider") {
            validateSelection()
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .disabled(selectionRange == nil)
        .keyboardShortcut(.return, modifiers: [])
    }

    /// Pastille « clip courant / total + % » affichée dans la barre flottante
    /// pendant que la file d'export tourne (miroir de la Live Activity).
    @ViewBuilder
    private var exportProgressChip: some View {
        let queue = RenderQueueController.shared.snapshot
        if queue.isRunning {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Theme.accent.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, queue.currentProgress))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text("\(queue.currentClipNumber)/\(queue.totalJobs) · \(Int(queue.currentProgress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
        }
    }

    private func controlBar(isLandscape: Bool) -> some View {
        Group {
            if isLandscape {
                HStack(spacing: 10) {
                    transportButtons
                    exportProgressChip
                    actionButtons
                }
            } else {
                VStack(spacing: 10) {
                    // Cibles réparties sur toute la largeur.
                    HStack(spacing: 0) {
                        Group { transportButtons }
                            .frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 12) {
                        exportProgressChip
                        actionButtons
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                startImport(items)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showGrid = true
            } label: {
                Image(systemName: "square.grid.3x3")
            }
            .disabled(project.rushes.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                durationMenu
                Toggle("Toucher = centre de la sélection", isOn: $project.touchAnchorIsCenter)
                Toggle("Stats développeur", isOn: Binding(
                    get: { devStatsEnabled },
                    set: { enabled in
                        devStatsEnabled = enabled
                        enabled ? DevStatsMonitor.shared.start() : DevStatsMonitor.shared.stop()
                    }
                ))
                Toggle("Aperçu léger (540p, + fluide)", isOn: Binding(
                    get: { project.previewLight },
                    set: { newValue in
                        project.previewLight = newValue
                        playback.lightPreview = newValue
                        playback.applyPreviewQualityChange()
                        touch()
                    }
                ))
                // Flux optique : désactivé par défaut. Activé, il FABRIQUE les
                // images intermédiaires (mouvement plus fluide) et peut donc
                // fabriquer des artefacts ; désactivé, chaque image du ralenti
                // est une vraie image du rush, répétée.
                Toggle("Flux optique (fluide, peut créer des artefacts)", isOn: Binding(
                    get: { project.opticalFlowEnabled },
                    set: { newValue in
                        project.opticalFlowEnabled = newValue
                        touch()
                    }
                ))
                Toggle("Album Photos par projet", isOn: Binding(
                    get: { project.albumPerProject },
                    set: { newValue in
                        project.albumPerProject = newValue
                        touch()
                    }
                ))
                // MOMENTS FORTS — proposition, jamais décision : l'app repère
                // où ça bouge plus que d'habitude, le choix reste à l'œil.
                Button {
                    analyzeCurrentRush()
                } label: {
                    Label(analyzingRushKey == nil ? "Repérer les moments forts (ce rush)" : "Analyse en cours…",
                          systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(analyzingRushKey != nil || currentRush == nil)
                if !globalMarkers.isEmpty {
                    Button {
                        jumpToNextPeak()
                    } label: {
                        Label("Aller au moment suivant (\(globalMarkers.count))", systemImage: "forward.end.alt")
                    }
                    Button(role: .destructive) {
                        clearMotionPeaks()
                    } label: {
                        Label("Effacer les repères", systemImage: "xmark.circle")
                    }
                }
                Button {
                    showReleaseConfirm = true
                } label: {
                    let releasable = MediaAvailabilityService.releasableSources(in: project)
                        .reduce(Int64(0)) { $0 + $1.bytes }
                    Label("Libérer l'espace (\(StorageManager.formatBytes(releasable)))",
                          systemImage: "internaldrive")
                }
                Button {
                    showReview = true
                } label: {
                    Label("Relecture des passages (\(project.passages.count))", systemImage: "play.rectangle.on.rectangle")
                }
                Button {
                    showExports = true
                } label: {
                    Label("Exports", systemImage: "square.and.arrow.up")
                }
                // Suivi de version — entrée informative, peu contrastée.
                Section {
                    Text("v\(BuildInfo.version) (\(BuildInfo.build)) · \(BuildInfo.stamp)")
                        .font(.caption2)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var durationMenu: some View {
        Menu("Durée finale : \(project.finalDuration.label)") {
            ForEach(ExactDuration.presets, id: \.centiseconds) { preset in
                Button(preset.label) {
                    project.finalDurationCentiseconds = preset.centiseconds
                    touch()
                }
            }
            // Valeur personnalisée au centième : quelques pas rapides.
            Menu("Personnalisée") {
                ForEach([110, 120, 140, 160, 175, 250], id: \.self) { centiseconds in
                    Button(ExactDuration(centiseconds: centiseconds).label) {
                        project.finalDurationCentiseconds = centiseconds
                        touch()
                    }
                }
            }
        }
    }

    // MARK: - Actions timeline

    private func handleScrub(_ globalTime: Double) {
        // Le scrubbing manuel prend toujours la main : toute lecture en cours
        // (boucle automatique comprise) est mise en pause.
        if playback.isPlaying {
            playback.pause()
        }
        playhead = globalTime
        guard let index = rushIndex(atGlobalTime: globalTime) else { return }
        let local = globalTime - segmentStart(rushIndex: index)
        playback.load(rush: project.orderedRushes[index])
        // Seek adaptatif : grossier pendant le geste, exact à l'arrêt.
        playback.scrub(to: CMTime(seconds: local, preferredTimescale: 600))
    }

    /// Suivi de lecture : la timeline défile pour rester alignée sur l'image
    /// affichée. Throttlé, et via jeton one-shot (pas de boucle de rétroaction :
    /// setPlayhead supprime son propre rappel de scrubbing).
    private func handlePlaybackTick(_ time: CMTime) {
        guard playback.isPlaying, let index = currentRushIndex else { return }
        // Boucle courte (sélection) : timeline immobile — un défilement en
        // va-et-vient serait illisible et coûterait du CPU pour rien.
        if let loopDuration = playback.activeLoopDuration, loopDuration < 3 { return }
        let rushDuration = project.orderedRushes[index].duration.seconds
        // Borné STRICTEMENT dans le rush courant : atteindre la frontière
        // ferait basculer currentRushIndex et rechargerait le média en boucle.
        let global = min(
            segmentStart(rushIndex: index) + time.seconds,
            segmentStart(rushIndex: index) + max(rushDuration - 0.01, 0)
        )
        guard abs(global - playhead) > 0.04 else { return }
        playhead = global
        seekCounter += 1
        seek = ProgrammaticSeek(token: seekCounter, time: global)
    }

    /// Déplacement manuel vers le rush précédent (-1) ou suivant (+1).
    private func goToRush(offset: Int) {
        let rushes = project.orderedRushes
        guard !rushes.isEmpty else { return }
        jump(toRushIndex: min(max((currentRushIndex ?? 0) + offset, 0), rushes.count - 1))
    }

    /// Saute au prochain rush SANS passage validé (recherche circulaire,
    /// logique pure dans TriageNavigation — testée unitairement).
    private func goToNextUntreatedRush() {
        let rushes = project.orderedRushes
        let treated = rushes.map { !$0.passages.isEmpty }
        guard let target = TriageNavigation.nextUntreatedIndex(after: currentRushIndex, treated: treated) else {
            if !rushes.isEmpty {
                errorMessage = "Tous les rushes ont au moins un passage validé. 🎉"
            }
            return
        }
        jump(toRushIndex: target)
    }

    /// Positionne la timeline sur un rush et lance sa lecture en boucle
    /// (arrivée via bouton uniquement — jamais pendant un scrubbing manuel).
    private func jump(toRushIndex target: Int) {
        let rushes = project.orderedRushes
        guard target >= 0, target < rushes.count else { return }
        let rush = rushes[target]
        let time = segmentStart(rushIndex: target)
        playhead = time
        seekCounter += 1
        seek = ProgrammaticSeek(token: seekCounter, time: time)
        playback.load(rush: rush)
        playback.playLoop(range: CMTimeRange(start: .zero, duration: rush.duration))
    }

    private func handleTap(_ globalTime: Double) {
        guard let index = rushIndex(atGlobalTime: globalTime) else { return }
        let rush = project.orderedRushes[index]
        let local = CMTime(seconds: globalTime - segmentStart(rushIndex: index), preferredTimescale: 600)
        // Tap sur un clip DÉJÀ VALIDÉ → mode édition : la sélection épouse le
        // clip, boucle immédiate ; Suppr. clip / Valider (mise à jour) au menu.
        if let existing = rush.passages.first(where: {
            CMTimeRangeContainsTime($0.sourceRange, time: local)
        }) {
            editingPassageID = existing.persistentModelID
            selectionRushIndex = index
            selectionRange = existing.sourceRange
            playSelectionLoop()
            recenterOnSelection()
            return
        }

        editingPassageID = nil
        do {
            let range = try SelectionEngine.makeSelection(
                touchTime: local,
                sourceDuration: fixedSourceDuration,
                rushDuration: rush.duration,
                anchorCenter: project.touchAnchorIsCenter
            )
            selectionRushIndex = index
            selectionRange = range
            // La sélection posée se rejoue immédiatement en boucle, jusqu'à
            // validation, rejet ou déplacement — et la timeline se recentre
            // dessus.
            playSelectionLoop()
            recenterOnSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Supprime le passage en cours d'édition (fichier de plage inclus).
    private func deleteEditingPassage() {
        guard let id = editingPassageID,
              let passage = modelContext.model(for: id) as? Passage else { return }
        playback.pause()
        if let cached = passage.cachedRangeRelativePath {
            try? FileManager.default.removeItem(
                at: StorageManager.url(forCachedRangeRelativePath: cached)
            )
        }
        modelContext.delete(passage)
        touch()
        editingPassageID = nil
        selectionRange = nil
        selectionRushIndex = nil
    }

    /// Recentre la timeline sur le milieu de la sélection courante.
    private func recenterOnSelection() {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let center = segmentStart(rushIndex: index)
            + range.start.seconds + range.duration.seconds / 2
        playhead = center
        seekCounter += 1
        seek = ProgrammaticSeek(token: seekCounter, time: center)
    }

    private func handleSelectionDrag(_ deltaSeconds: Double) {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let rush = project.orderedRushes[index]
        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 600)
        let moved = SelectionEngine.move(range, by: delta, rushDuration: rush.duration)
        selectionRange = moved
        // La boucle SUIT le doigt : relance depuis le nouveau début à chaque
        // mouvement (seeks coalescés dans le moteur — fluide, pas de tempête).
        playback.dragLoop(range: moved)
    }

    private func persistAfterMove() {
        // Relâcher après déplacement : la boucle reprend depuis le nouvel
        // emplacement et la timeline se recentre sur la sélection.
        if selectionRange != nil {
            playSelectionLoop()
            recenterOnSelection()
        }
    }

    private func nudgeSelection(frames: Int) {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let rush = project.orderedRushes[index]
        let fps = rush.nominalFrameRate > 1 ? rush.nominalFrameRate : 30
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        selectionRange = SelectionEngine.nudge(
            range, frames: frames, frameDuration: frameDuration, rushDuration: rush.duration
        )
        // La boucle repart de l'emplacement ajusté, timeline recentrée.
        playSelectionLoop()
        recenterOnSelection()
    }

    private func playSelectionLoop() {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        playback.load(rush: project.orderedRushes[index])
        playback.playLoop(range: range)
    }

    // MARK: - Validation

    /// Cœur commun de la validation : crée le passage, nettoie l'état de
    /// sélection. PAS d'export automatique (phase séparée), PAS de saut au
    /// rush suivant (navigation au choix de l'utilisateur).
    private func commitSelection() -> (Passage, Rush)? {
        guard let index = selectionRushIndex, let range = selectionRange else { return nil }
        // La validation arrête la boucle de prévisualisation.
        playback.pause()
        let rush = project.orderedRushes[index]

        let passage = Passage()
        passage.validationIndex = (project.passages.map(\.validationIndex).max() ?? -1) + 1
        passage.setStart(range.start)
        passage.sourceDurationValue = range.duration.value
        passage.sourceDurationTimescale = range.duration.timescale
        passage.finalDurationCentiseconds = project.finalDurationCentiseconds
        passage.speedNumerator = project.speedNumerator
        passage.speedDenominator = project.speedDenominator
        // Caractéristiques source FIGÉES : le rush peut être supprimé ensuite,
        // l'export garde la bonne colorimétrie (HDR jamais rendu en SDR muet).
        passage.colorimetry = rush.colorimetry
        passage.is10Bit = rush.is10Bit
        passage.sourceNominalFrameRate = rush.nominalFrameRate
        passage.rush = rush
        passage.project = project
        modelContext.insert(passage)
        touch()

        validateHaptic.notificationOccurred(.success)
        selectionRange = nil
        selectionRushIndex = nil
        return (passage, rush)
    }

    private func validateSelection() {
        // Mode édition : mise à jour de la position du clip existant + nouvelle
        // plage cachée (l'ancienne ne couvre plus forcément la sélection).
        if let id = editingPassageID {
            guard let passage = modelContext.model(for: id) as? Passage,
                  let rush = passage.rush,
                  let range = selectionRange else { return }
            playback.pause()
            passage.setStart(range.start)
            if let old = passage.cachedRangeRelativePath {
                try? FileManager.default.removeItem(
                    at: StorageManager.url(forCachedRangeRelativePath: old)
                )
                passage.cachedRangeRelativePath = nil
            }
            touch()
            validateHaptic.notificationOccurred(.success)
            editingPassageID = nil
            selectionRange = nil
            selectionRushIndex = nil
            Task {
                if await !cacheSourceRange(for: passage, rush: rush) {
                    errorMessage = "Nouvelle plage non mise en cache — conservez le rush pour exporter ce clip."
                }
            }
            return
        }

        guard let (passage, rush) = commitSelection() else { return }
        // Export automatique optionnel (toggle dans l'écran Exports).
        if project.autoExportOnValidate {
            RenderQueueController.shared.enqueue(passageIDs: [passage.persistentModelID])
        }
        // Mise en cache de la plage source pleine qualité (export hors-ligne).
        // Échec SIGNALÉ : un passage sans plage cachée dépend de la copie
        // source — l'utilisateur doit le savoir avant toute libération.
        Task {
            if await !cacheSourceRange(for: passage, rush: rush) {
                errorMessage = "Mise en cache de la plage impossible pour ce passage — conservez le rush (l'export utilisera la copie source complète)."
            }
        }
    }

    /// « Val. + Suppr. » : valide le passage PUIS purge le rush de la timeline
    /// (entité + fichier source). Suppression UNIQUEMENT si : la plage du
    /// nouveau passage est cachée, TOUS les autres passages du rush le sont
    /// aussi, et aucun rendu n'est en cours (anti-course fichier).
    private func validateAndDeleteRush() {
        guard let (passage, rush) = commitSelection() else { return }
        Task {
            let cached = await cacheSourceRange(for: passage, rush: rush)
            guard cached else {
                errorMessage = "Plage non mise en cache — rush conservé pour garantir l'export du clip."
                return
            }
            let allCached = rush.passages.allSatisfy { p in
                guard let path = p.cachedRangeRelativePath else { return false }
                return FileManager.default.fileExists(
                    atPath: StorageManager.url(forCachedRangeRelativePath: path).path
                )
            }
            guard allCached else {
                errorMessage = "Un autre passage de ce rush n'a pas encore sa plage cachée — rush conservé."
                return
            }
            // Purge à mesure : toutes les plages du rush étant cachées, les
            // exports (en cours comme futurs) passent par les caches — la
            // suppression du fichier source est sûre, aucun blocage.
            deleteRush(rush)
            if project.autoExportOnValidate {
                RenderQueueController.shared.enqueue(passageIDs: [passage.persistentModelID])
            }
        }
    }

    /// Écarte le rush sous la tête de lecture (bouton « Suppr. rush »).
    ///
    /// Une sélection en cours sur ce rush n'aurait plus de support : elle est
    /// abandonnée en même temps. Un rush dont un passage validé n'a PAS encore
    /// sa plage cachée est conservé — sinon l'export de ce passage deviendrait
    /// impossible, le fichier source ayant disparu.
    private func deleteRushUnderPlayhead() {
        guard let rush = currentRush else { return }
        let pending = project.passages.filter { $0.rush === rush && $0.cachedRangeRelativePath == nil }
        guard pending.isEmpty else {
            errorMessage = "\(pending.count) passage(s) de ce rush n'ont pas encore leur plage cachée — rush conservé (leur export deviendrait impossible)."
            return
        }
        selectionRange = nil
        selectionRushIndex = nil
        deleteRush(rush)
    }

    /// Purge un rush de la timeline : fichier source supprimé, entité effacée.
    /// Ses passages validés survivent (relation .nullify) et s'exportent via
    /// leurs plages cachées.
    private func deleteRush(_ rush: Rush) {
        playback.pause()
        if let path = rush.localSourceRelativePath {
            try? FileManager.default.removeItem(at: StorageManager.url(forSourceRelativePath: path))
        }
        modelContext.delete(rush)
        touch()
        rebuildSegments()
        playback.load(rush: currentRush)
    }

    /// Copie passthrough (sans réencodage) de la plage sélectionnée + marge.
    /// L'offset stocké est le PTS RÉEL du premier échantillon écrit — exact
    /// par construction (un passthrough HEVC ne peut pas couper mi-GOP :
    /// l'ancien AVAssetExportSession recalait la coupe sur l'image clé
    /// précédente et l'offset supposé devenait faux, décalant le contenu de
    /// chaque export différemment). Le fichier produit est vérifié avant
    /// d'être déclaré utilisable.
    @discardableResult
    private func cacheSourceRange(for passage: Passage, rush: Rush) async -> Bool {
        guard let sourcePath = rush.localSourceRelativePath else { return false }
        let sourceURL = StorageManager.url(forSourceRelativePath: sourcePath)
        let margin = MediaAvailabilityService.cacheMargin(for: rush)
        let start = CMTimeMaximum(.zero, CMTimeSubtract(passage.start, margin))
        let end = CMTimeMinimum(rush.duration, CMTimeAdd(passage.sourceRange.end, margin))
        let filename = "range-\(UUID().uuidString).mov"
        let destination = StorageManager.url(forCachedRangeRelativePath: filename)

        guard let actualStart = await Self.remuxRange(
            source: sourceURL, destination: destination,
            start: start, end: end
        ) else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        // Sanité : le premier échantillon écrit doit précéder (ou égaler) le
        // début de la sélection — sinon la plage ne couvre pas le passage.
        guard CMTimeCompare(actualStart, passage.start) <= 0 else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        StorageManager.excludeFromBackup(destination)
        // Le start du passage reste en temps RUSH ; le décalage mémorisé est
        // le zéro RÉEL du fichier caché (rebasage exact à l'export).
        passage.cachedRangeRelativePath = filename
        passage.cachedRangeOffsetValue = actualStart.value
        passage.cachedRangeOffsetTimescale = actualStart.timescale
        try? modelContext.save()
        return true
    }

    /// Découpe passthrough manuelle : AVAssetReader (échantillons compressés)
    /// → AVAssetWriter (sourceFormatHint). Retourne le PTS source du premier
    /// échantillon écrit (= zéro du fichier produit), ou nil en cas d'échec.
    nonisolated private static func remuxRange(source: URL,
                                              destination: URL,
                                              start: CMTime,
                                              end: CMTime) async -> CMTime? {
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (formatDescriptions, preferredTransform) = try await track.load(
                .formatDescriptions, .preferredTransform
            )
            guard let formatHint = formatDescriptions.first else { return nil }

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: start, end: end)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // passthrough
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { return nil }

            // Le lecteur passthrough livre depuis l'image de synchronisation
            // nécessaire au décodage : on écrit TOUT et on mémorise le PTS
            // minimal réellement écrit.
            var samples: [CMSampleBuffer] = []
            var minPTS = CMTime.positiveInfinity
            while let sample = output.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isValid, CMTimeCompare(pts, minPTS) < 0 { minPTS = pts }
                samples.append(sample)
            }
            // STATUT DU LECTEUR : `copyNextSampleBuffer` renvoie nil aussi bien
            // à la fin normale du flux QUE sur erreur. Sans ce contrôle, une
            // lecture interrompue produisait une plage cachée TRONQUÉE, promue
            // ensuite source d'export après « Val. + Suppr. » — le rush
            // original ayant été purgé, la perte était définitive et
            // silencieuse.
            guard reader.status == .completed else { return nil }
            guard !samples.isEmpty, minPTS != .positiveInfinity else { return nil }

            let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                           sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = false
            // ROTATION PRÉSERVÉE : sans cette ligne, la plage cachée perd la
            // preferredTransform du rush → exports couchés à 90°.
            input.transform = preferredTransform
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: minPTS)

            for sample in samples {
                // Attente BORNÉE : un encodeur qui n'accepte plus rien figerait
                // la mise en cache indéfiniment, sans message.
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed || ContinuousClock.now > deadline {
                        writer.cancelWriting()
                        return nil
                    }
                    try await Task.sleep(for: .milliseconds(4))
                }
                guard input.append(sample) else {
                    writer.cancelWriting()
                    return nil
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { return nil }

            // Vérification du fichier produit : lisible et durée plausible.
            let produced = AVURLAsset(url: destination)
            let producedDuration = try await produced.load(.duration)
            let requestedDuration = CMTimeSubtract(end, minPTS).seconds
            guard producedDuration.seconds > requestedDuration - 0.5 else { return nil }

            return minPTS
        } catch {
            return nil
        }
    }

    // MARK: - Importation

    /// Délégué au service partagé ImportController — la tâche survit à la
    /// navigation, la bannière réapparaît au retour dans l'éditeur.
    private func startImport(_ items: [PhotosPickerItem]) {
        pickerItems = []
        importer.start(items: items, project: project, context: modelContext)
    }

    /// Passages dont la plage cachée manque (app tuée pendant la mise en
    /// cache) : nouvelle tentative à l'ouverture du projet.
    private func retryMissingCaches() async {
        try? await Task.sleep(for: .seconds(2)) // laisse l'ouverture respirer
        for passage in project.orderedPassages {
            // Invalidation des caches DÉFECTUEUX d'une version antérieure :
            // plage créée sans rotation alors que le rush en a une → exports
            // à 90°. Supprimée ici, recréée correctement juste après.
            if let path = passage.cachedRangeRelativePath,
               let rush = passage.rush, rush.rotationDegrees != 0 {
                let url = StorageManager.url(forCachedRangeRelativePath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    let asset = AVURLAsset(url: url)
                    if let track = try? await asset.loadTracks(withMediaType: .video).first,
                       let transform = try? await track.load(.preferredTransform),
                       transform.isIdentity {
                        try? FileManager.default.removeItem(at: url)
                        passage.cachedRangeRelativePath = nil
                        try? modelContext.save()
                    }
                }
            }

            let missing = passage.cachedRangeRelativePath.map {
                !FileManager.default.fileExists(atPath: StorageManager.url(forCachedRangeRelativePath: $0).path)
            } ?? true
            guard missing,
                  let rush = passage.rush,
                  rush.localSourceRelativePath != nil else { continue }
            await cacheSourceRange(for: passage, rush: rush)
        }
    }

    /// Sauvegarde automatique après chaque modification importante.
    /// Les réglages du projet deviennent les réglages GLOBAUX (maintenus
    /// entre les projets).
    private func touch() {
        project.updatedAt = .now
        try? modelContext.save()
        AppSettings.capture(from: project)
    }
}

// MARK: - Bandeau de progression d'importation

/// Bandeau COMPACT en haut de la visionneuse : n'occulte pas l'image, le
/// triage peut commencer pendant l'importation. Pourcentage, barre, temps
/// restant estimé, annulation. Le signal sonore de fin est joué par startImport.
private struct ImportProgressBanner: View {
    let progress: ImportProgress
    let startedAt: Date?
    let onCancel: () -> Void

    private var fraction: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.completed) / Double(progress.total)
    }

    /// Estimation à partir de la moyenne par élément déjà importé.
    private var remainingText: String? {
        guard let startedAt, progress.completed >= 1, progress.completed < progress.total else { return nil }
        let elapsed = Date.now.timeIntervalSince(startedAt)
        let remaining = elapsed / Double(progress.completed) * Double(progress.total - progress.completed)
        if remaining < 60 { return String(format: "≈ %.0f s", remaining) }
        return String(format: "≈ %d min", Int((remaining / 60).rounded()))
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(.blue)
                .frame(width: 90)
            Text("\(Int((fraction * 100).rounded())) % · \(progress.completed)/\(progress.total)")
                .font(.footnote.bold().monospacedDigit())
            if let remainingText {
                Text(remainingText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !progress.errors.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(in: Capsule())
        .padding(.top, 8)
    }
}
