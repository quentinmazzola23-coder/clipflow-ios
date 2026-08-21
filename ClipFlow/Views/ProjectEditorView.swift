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
    @Environment(\.scenePhase) private var scenePhase

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
    @State private var showOutputFormat = false
    /// L'ouverture automatique ne se produit qu'une fois par apparition.
    @State private var autoPickerLaunched = false
    private var importer: ImportController { ImportController.shared }

    /// Segments MÉMOÏSÉS : reconstruits uniquement quand les rushes changent
    /// (import, suppression) — plus de tri + projection à chaque tick de lecture.
    @State private var segments: [TimelineSegment] = []

    // Navigation temporelle. Le positionnement externe passe par un jeton
    // one-shot (voir ProgrammaticSeek).
    @State private var playhead: Double = 0
    @State private var undo = DeletionUndo()
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
    @State private var showMontage = false
    @State private var showExports = false
    @State private var errorMessage: String?
    @State private var exportToast: String?
    @State private var showGrid = false
    /// Son de la prévisualisation coupé (mémorisé entre sessions).
    @AppStorage("previewMuted") private var previewMuted = false
    @State private var slowPreview = false
    @State private var showCustomDuration = false

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

    /// Le clip en cours d'édition existe-t-il encore, et est-il encore
    /// visible ? La Relecture peut l'avoir mis en sursis pendant qu'on était
    /// dessus.
    private func dropEditingIfGone() {
        guard let id = editingPassageID else { return }
        let passage = modelContext.model(for: id) as? Passage
        if passage == nil || passage?.isPendingDeletion == true {
            editingPassageID = nil
            selectionRange = nil
            selectionRushIndex = nil
        }
    }

    private var overlays: [TimelineOverlay] {
        var result: [TimelineOverlay] = []
        for passage in project.orderedPassages {
            guard let rush = passage.rush,
                  let index = project.orderedRushes.firstIndex(where: { $0 === rush }) else { continue }
            result.append(TimelineOverlay(
                kind: passage.exportState == .exported ? .exported : .validated,
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

    /// Libellé de la durée COURANTE, quel que soit le mode.
    private var durationLabel: String {
        project.durationToRushEnd ? "fin du rush" : project.finalDuration.label
    }

    /// Durée source minimale exploitable : deux images du rush. En dessous,
    /// il n'y a pas de mouvement à ralentir, juste une image figée.
    private func minimumSourceDuration(for rush: Rush) -> CMTime {
        let fps = rush.nominalFrameRate > 1 ? rush.nominalFrameRate : 30
        return CMTime(value: 2, timescale: CMTimeScale(fps.rounded()))
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
            // BANDEAU D'ANNULATION posé SUR la barre de commandes, jamais
            // au-dessus d'elle dans le flux.
            //
            // `safeAreaInset` avait l'air plus propre, mais il RÉDUIT la
            // hauteur disponible : la barre remontait d'une quarantaine de
            // points à l'apparition du bandeau. Or le cas visé est la rafale —
            // on écarte quatre rushes de suite au même endroit — et la
            // deuxième frappe serait tombée sur le bouton voisin. Un filet qui
            // provoque la faute qu'il doit rattraper ne vaut rien.
            //
            // En surimpression, la mise en page ne bouge pas d'un point ; le
            // bandeau masque brièvement la barre, ce qui est sans conséquence :
            // il disparaît en cinq secondes et son seul geste est « Annuler ».
            .overlay(alignment: .bottom) {
                if let pending = undo.pending {
                    UndoBannerView(pending: pending, count: undo.count) { undo.undo() }
                        .padding(.bottom, 6)
                }
            }
            .animation(.snappy(duration: 0.22), value: undo.pending?.id)
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
        // DRAPEAU SÉPARÉ, pas `snapshot.isRunning` : lire `snapshot` ici
        // déclarait une dépendance d'observation sur la structure entière —
        // qui change à chaque image rendue — et reconstruisait TOUT l'éditeur
        // pendant un export. C'est le défaut du menu ⋯ qui remonte en haut,
        // que l'isolation de la pastille seule ne suffisait pas à tuer.
        .onChange(of: RenderQueueController.shared.isRunningFlag) { wasRunning, isRunning in
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
        // Toute feuille COUPE la lecture de l'éditeur : sans cela, la boucle
        // de sélection continuait à jouer son et image sous la feuille, et se
        // superposait au lecteur de la Relecture — deux bandes-son mêlées.
        .onChange(of: showReview) { _, presented in if presented { playback.pause() } }
        .onChange(of: showGrid) { _, presented in if presented { playback.pause() } }
        .onChange(of: showExports) { _, presented in if presented { playback.pause() } }
        .onChange(of: showMontage) { _, presented in if presented { playback.pause() } }
        .onChange(of: showPicker) { _, presented in if presented { playback.pause() } }
        .onChange(of: showCustomDuration) { _, presented in if presented { playback.pause() } }
        .sheet(isPresented: $showReview, onDismiss: dropEditingIfGone) {
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
        // Montage : plein écran — c'est une étape de travail entière, pas un
        // panneau d'appoint.
        .fullScreenCover(isPresented: $showMontage) {
            NavigationStack {
                MontageView(project: project)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showMontage = false
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .accessibilityLabel("Fermer le montage")
                        }
                    }
            }
        }
        .sheet(isPresented: $showOutputFormat) {
            OutputFormatSheet(project: project, survey: project.rushFormatSurvey)
        }
        .sheet(isPresented: $showCustomDuration) {
            CustomDurationSheet(
                initial: project.finalDuration,
                speed: RationalSpeed(numerator: project.speedNumerator,
                                     denominator: project.speedDenominator)
            ) { duration in
                // Choisir une durée exacte, c'est choisir une durée FIXE :
                // le mode « fin du rush » ne peut pas rester actif à côté.
                project.durationToRushEnd = false
                project.finalDurationCentiseconds = duration.centiseconds
                touch()
            }
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
        .task { await retryMissingCaches() }
        .onChange(of: importer.progress?.completed) { _, _ in
            // Les rushes apparaissent au fil de l'importation.
            rebuildSegments()
        }
        .onChange(of: importer.completionToken) { _, _ in
            rebuildSegments()
            proposeOutputFormatIfUseful()
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
            // Repères déjà calculés : rétablis sans rien réanalyser.
            loadCachedPeaks()
            resolveLeftoverDeletions()
            restorePlayhead()
            markLegacyProjectAsOpened()
            openPickerOnFirstUse()
        }
        // Le bouton principal ne declenche PAS onDisappear : sans ce relais,
        // quitter l'app par le bas perdait la position de lecture, alors que
        // c'est le geste le plus courant pour interrompre une session.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            savePlayhead()
        }
        .onDisappear {
            // Retour à la liste des projets : la lecture s'arrête toujours,
            // et une analyse en cours n'a plus de destinataire.
            playback.pause()
            analysisTask?.cancel()
            analysisTask = nil
            // Un sursis ne survit pas à l'écran qui l'affichait : sans le
            // bandeau, plus rien ne pourrait l'annuler et l'objet resterait
            // masqué sans jamais être effacé.
            undo.consumeNow()
            savePlayhead()
        }
    }

    // MARK: - Sous-vues

    private var playerArea: some View {
        ZStack {
            PlayerLayerView(player: playback.player)
            if project.visibleRushes.isEmpty && importer.progress == nil {
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
                Text("Rush \(index + 1)/\(project.visibleRushes.count)")
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
                Text("Touchez la timeline pour créer une sélection de \(durationLabel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Timecodes de la sélection courante (début → fin dans le rush).
            if let range = selectionRange {
                // Position au centième RETIRÉE : la règle graduée de la
                // timeline situe la sélection bien mieux qu'un couple de
                // nombres, et s'adapte au zoom.
                // En mode « fin du rush » la longueur varie d'une sélection à
                // l'autre : afficher le réglage n'apprendrait rien, c'est la
                // durée finale RÉELLE de ce clip qui compte.
                Text("✂︎ \(clipDurationLabel(for: range))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            // Progression globale du triage.
            let treated = project.orderedRushes.filter { !$0.visiblePassages.isEmpty }.count
            Text("\(treated)/\(project.visibleRushes.count) rushes traités · \(project.visiblePassages.count) clips")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(treated == project.visibleRushes.count && !project.visibleRushes.isEmpty ? .green : .secondary)
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
            .disabled(currentRushIndex.map { $0 >= project.visibleRushes.count - 1 } ?? true)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
        // Saut direct au prochain rush sans passage validé.
        Button { goToNextUntreatedRush() } label: { Image(systemName: "arrow.right.to.line") }
            .buttonStyle(GlassIconButtonStyle(diameter: 40))
            .accessibilityLabel("Prochain rush non traité")
            .disabled(project.visibleRushes.isEmpty)
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

    private var exportProgressChip: some View {
        ExportProgressChip { showExports = true }
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
            .disabled(project.visibleRushes.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            // ÉTAPE SUIVANTE du flux : dérushage → montage sur la musique.
            Button {
                showMontage = true
            } label: {
                Image(systemName: "music.note")
            }
            .disabled(project.visiblePassages.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
            // MENU ORGANISÉ PAR MOMENT D'USAGE, et non par nature technique.
            //
            // Tout vivait ici à plat : réglages, repérage, relecture, exports,
            // entretien. Revenir sur l'app après trois semaines, c'était ne
            // plus savoir ce qu'elle sait faire. Les sections suivent l'ordre
            // réel du travail — on dérushe, puis on revoit, puis on exporte —
            // et les libellés nomment l'ACTION plutôt que l'objet : « Revoir
            // mes clips » se comprend sans avoir à deviner ce qu'était une
            // « relecture des passages ».
            Menu {
                Section("Pendant le dérushage") {
                    durationMenu
                    // MOMENTS FORTS — proposition, jamais décision : l'app
                    // repère où ça bouge plus que d'habitude, le choix reste
                    // à l'œil.
                    Button {
                        analyzeCurrentRush()
                    } label: {
                        Label(analyzingRushKey == nil
                              ? "Repérer les moments forts de ce rush"
                              : "Analyse en cours…",
                              systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(analyzingRushKey != nil || currentRush == nil)
                    if !globalMarkers.isEmpty {
                        Button {
                            jumpToNextPeak()
                        } label: {
                            Label("Aller au moment fort suivant (\(globalMarkers.count))",
                                  systemImage: "forward.end.alt")
                        }
                        Button(role: .destructive) {
                            clearMotionPeaks()
                        } label: {
                            Label("Effacer les moments repérés", systemImage: "xmark.circle")
                        }
                    }
                }

                Section("Format de la vidéo") {
                    Picker("Format", selection: Binding(
                        get: { project.outputFormat },
                        set: { newValue in
                            project.outputFormat = newValue
                            touch()
                        }
                    )) {
                        ForEach(MontageOutputFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                    Toggle("Recadrer plutôt que ceinturer", isOn: Binding(
                        get: { project.cropToFillOutput },
                        set: { newValue in
                            project.cropToFillOutput = newValue
                            touch()
                        }
                    ))
                    Toggle("Suréchantillonner à l'export", isOn: Binding(
                        get: { project.upscaleOnExport },
                        set: { newValue in
                            project.upscaleOnExport = newValue
                            touch()
                        }
                    ))
                }

                Section("Quand les clips sont faits") {
                    Button {
                        showReview = true
                    } label: {
                        Label("Revoir mes clips (\(project.visiblePassages.count))",
                              systemImage: "play.rectangle.on.rectangle")
                    }
                    Button {
                        showExports = true
                    } label: {
                        Label("Envoyer mes clips dans Photos",
                              systemImage: "square.and.arrow.up")
                    }
                }

                // Réglages en SOUS-MENU : ils se touchent rarement, et les
                // laisser à plat noyait les actions du jour sous quatre
                // interrupteurs.
                Menu {
                    Toggle("Toucher = centre du clip", isOn: Binding(
                        get: { project.touchAnchorIsCenter },
                        set: { newValue in
                            project.touchAnchorIsCenter = newValue
                            AppSettings.captureFlag(\.touchAnchorIsCenter, value: newValue)
                            touch()
                        }
                    ))
                    Toggle("Aperçu léger (540p, plus fluide)", isOn: Binding(
                        get: { project.previewLight },
                        set: { newValue in
                            project.previewLight = newValue
                            playback.lightPreview = newValue
                            playback.applyPreviewQualityChange()
                            touch()
                        }
                    ))
                    // Flux optique : désactivé par défaut. Activé, il FABRIQUE
                    // les images intermédiaires (mouvement plus fluide) et peut
                    // donc fabriquer des artefacts ; désactivé, chaque image du
                    // ralenti est une vraie image du rush, répétée.
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
                    Toggle("Stats développeur", isOn: Binding(
                        get: { devStatsEnabled },
                        set: { enabled in
                            devStatsEnabled = enabled
                            enabled ? DevStatsMonitor.shared.start() : DevStatsMonitor.shared.stop()
                        }
                    ))
                } label: {
                    Label("Réglages", systemImage: "slider.horizontal.3")
                }

                Section {
                    Button {
                        releaseSourcesNow()
                    } label: {
                        let releasable = MediaAvailabilityService.releasableSources(in: project)
                            .reduce(Int64(0)) { $0 + $1.bytes }
                        Label("Libérer \(StorageManager.formatBytes(releasable)) d'espace",
                              systemImage: "internaldrive")
                    }
                    // Suivi de version — entrée informative, peu contrastée.
                    Text("v\(BuildInfo.version) (\(BuildInfo.build)) · \(BuildInfo.stamp)")
                        .font(.caption2)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var durationMenu: some View {
        Menu("Durée finale : \(durationLabel)") {
            // Une seule liste de modes, cochée : « jusqu'à la fin du rush » est
            // un choix de durée comme les autres, pas une action à part.
            Picker("Durée", selection: durationModeBinding) {
                ForEach(ExactDuration.presets, id: \.centiseconds) { preset in
                    Text(preset.label).tag(DurationMode.fixed(preset.centiseconds))
                }
                // La durée personnalisée courante reste visible et cochée quand
                // elle ne fait pas partie des valeurs types.
                if !project.durationToRushEnd,
                   !ExactDuration.presets.contains(where: {
                       $0.centiseconds == project.finalDurationCentiseconds
                   }) {
                    Text(project.finalDuration.label)
                        .tag(DurationMode.fixed(project.finalDurationCentiseconds))
                }
                Text("Jusqu'à la fin du rush").tag(DurationMode.toRushEnd)
            }
            // Options présentées À PLAT dans le menu de durée : un Picker
            // laissé au style par défaut ouvrirait un sous-menu de plus, soit
            // un tap supplémentaire pour un choix fait en permanence.
            .pickerStyle(.inline)
            Divider()
            Button("Durée personnalisée…") { showCustomDuration = true }
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
                touch()
            }
        )
    }

    /// Durée finale réelle d'une plage sélectionnée, telle qu'elle sera figée
    /// dans le passage à la validation.
    private func clipDurationLabel(for range: CMTimeRange) -> String {
        TimeMath.finalDuration(
            source: range.duration,
            speed: RationalSpeed(numerator: project.speedNumerator,
                                 denominator: project.speedDenominator)
        ).label
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
        let treated = rushes.map { !$0.visiblePassages.isEmpty }
        guard let target = TriageNavigation.nextUntreatedIndex(after: currentRushIndex, treated: treated) else {
            if !rushes.isEmpty {
                errorMessage = "Tous les rushes ont au moins un clip validé. 🎉"
            }
            return
        }
        jump(toRushIndex: target)
    }

    // MARK: - Ouverture du projet
    //
    // Ces trois traitements vivaient DANS `onAppear`. Le corps a fini par
    // dépasser ce que le vérificateur de types de Swift démêle en temps
    // raisonnable, et il refusait alors de compiler sans rien dire du fond.
    // Les sortir les rend aussi lisibles un par un.

    /// RÉTABLIT ce qu'une fin brutale a laissé en sursis.
    ///
    /// `isPendingDeletion` est PERSISTÉ : si l'app est tuée pendant les cinq
    /// secondes de grâce, le rush ou le clip reste masqué — invisible dans
    /// l'app, jamais effacé du disque, impossible à récupérer. C'est le revers
    /// exact du mécanisme d'annulation, et il faut le refermer à l'ouverture.
    ///
    /// On rétablit plutôt qu'on ne consomme : perdre l'intention de supprimer
    /// coûte un geste, perdre le rush coûte le travail. Le déséquilibre entre
    /// les deux erreurs tranche la question.
    private func resolveLeftoverDeletions() {
        var restored = false
        for rush in project.rushes where rush.isPendingDeletion {
            rush.isPendingDeletion = false
            restored = true
        }
        for passage in project.passages where passage.isPendingDeletion {
            passage.isPendingDeletion = false
            restored = true
        }
        if restored {
            try? modelContext.save()
            rebuildSegments()
        }
    }

    /// Note la position POUR CE PROJET, afin de rouvrir là où on s'est arrêté.
    private func savePlayhead() {
        project.playheadCentiseconds = Int((playhead * 100).rounded())
        try? modelContext.save()
    }

    /// Propose le format de sortie APRÈS l'importation, et une seule fois.
    ///
    /// La question ne se pose que si les rushes mêlent paysage et vertical :
    /// avec une orientation unique, le mode automatique donne déjà le bon
    /// cadre et demander serait une confirmation déguisée. Le réglage reste
    /// dans le menu pour les cas où l'on veut du vertical à partir de rushes
    /// tous filmés à plat.
    private func proposeOutputFormatIfUseful() {
        guard !project.didAskOutputFormat else { return }
        let survey = project.rushFormatSurvey
        guard survey.isMixed else { return }
        project.didAskOutputFormat = true
        // Défaut posé sur l'orientation MAJORITAIRE : c'est celui qui recadre
        // le moins de rushes, et il est déjà juste si l'utilisateur valide
        // sans réfléchir.
        if project.outputFormat == .auto { project.outputFormat = survey.majorityFormat }
        try? modelContext.save()
        showOutputFormat = true
    }

    /// Rouvre le projet LÀ OÙ on s'était arrêté.
    ///
    /// Les segments viennent d'être bâtis, donc le temps global mémorisé a de
    /// nouveau un sens. Borné à la durée réelle : des rushes ont pu être
    /// supprimés depuis, et une tête de lecture au-delà de la fin ne montrerait
    /// rien.
    private func restorePlayhead() {
        guard project.playheadCentiseconds >= 0, let last = segments.last else { return }
        let total = last.startOffset + last.duration
        let saved = Double(project.playheadCentiseconds) / 100
        guard total > 0, saved > 0.05 else { return }
        let target = min(saved, max(0, total - 0.05))
        guard let index = rushIndex(atGlobalTime: target) else { return }
        playhead = target
        // La timeline se recale par le même chemin que la navigation manuelle,
        // et le lecteur charge le rush voulu — SANS lancer la lecture : on
        // rouvre sur une image, pas sur une boucle qui démarre toute seule.
        seekCounter += 1
        seek = ProgrammaticSeek(token: seekCounter, time: target)
        playback.load(rush: project.orderedRushes[index])
        playback.seek(to: CMTime(seconds: target - segmentStart(rushIndex: index),
                                 preferredTimescale: 600))
    }

    /// Projet ANTÉRIEUR au marqueur d'ouverture : s'il porte la moindre trace
    /// de travail, on le tient pour déjà ouvert.
    ///
    /// Sans cela, la photothèque s'ouvrirait une dernière fois sur un projet en
    /// cours, à la première mise à jour qui introduit ce champ.
    private func markLegacyProjectAsOpened() {
        guard !project.didAutoOpenPicker else { return }
        guard !project.passages.isEmpty || !project.overlays.isEmpty
                || project.musicFilename != nil else { return }
        project.didAutoOpenPicker = true
        try? modelContext.save()
    }

    /// PREMIÈRE ouverture seulement : le sélecteur Photos s'ouvre de lui-même,
    /// pour qu'il n'y ait aucun tap entre « Nouveau projet » et le choix des
    /// rushes.
    ///
    /// Le marqueur vit SUR LE PROJET, pas dans un état de vue. Un drapeau de
    /// session se réarmait à chaque réouverture : un projet dont on avait
    /// supprimé les rushes au fil du dérushage rouvrait la photothèque en
    /// pleine figure, à chaque fois. Rendre le service une fois est utile ;
    /// le répéter est une intrusion.
    private func openPickerOnFirstUse() {
        guard !project.didAutoOpenPicker, !autoPickerLaunched,
              project.rushes.isEmpty, importer.progress == nil else { return }
        autoPickerLaunched = true
        project.didAutoOpenPicker = true
        try? modelContext.save()
        showPicker = true
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
        // Un clip EN SURSIS n'existe plus pour l'interface : il n'est plus
        // dessiné, il ne doit plus être attrapable. Le retaper posait une
        // sélection sur un clip fantôme ; le re-valider ne levait PAS le
        // sursis, et il s'effaçait cinq secondes plus tard avec son fichier de
        // plage. L'annulation passe par le bandeau, jamais par la timeline.
        if let existing = rush.visiblePassages.first(where: {
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
            let range: CMTimeRange
            if project.durationToRushEnd {
                range = try SelectionEngine.makeSelectionToEnd(
                    touchTime: local,
                    rushDuration: rush.duration,
                    minimumDuration: minimumSourceDuration(for: rush)
                )
            } else {
                range = try SelectionEngine.makeSelection(
                    touchTime: local,
                    sourceDuration: fixedSourceDuration,
                    rushDuration: rush.duration,
                    anchorCenter: project.touchAnchorIsCenter
                )
            }
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
        passage.isPendingDeletion = true
        touch()
        editingPassageID = nil
        selectionRange = nil
        selectionRushIndex = nil
        undo.schedule(label: "Clip supprimé") {
            if let cached = passage.cachedRangeRelativePath {
                try? FileManager.default.removeItem(
                    at: StorageManager.url(forCachedRangeRelativePath: cached)
                )
            }
            modelContext.delete(passage)
            try? modelContext.save()
        } restore: {
            passage.isPendingDeletion = false
            try? modelContext.save()
        }
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

    /// Le mode « fin du rush » s'applique-t-il à la sélection COURANTE ?
    ///
    /// En création, c'est le réglage du projet. En ÉDITION d'un clip déjà
    /// validé, c'est la nature du clip qui décide : un clip de 1,3 s posé au
    /// milieu d'un rush ne doit pas s'étirer jusqu'à la fin parce que le
    /// réglage a changé depuis. Sans cette distinction, ajuster un ancien clip
    /// d'une image le faisait sauter à toute la durée restante du rush, et
    /// « Mettre à jour » figeait ça en silence.
    private var selectionFollowsRushEnd: Bool {
        guard editingPassageID != nil else { return project.durationToRushEnd }
        guard let index = selectionRushIndex, let range = selectionRange else {
            return project.durationToRushEnd
        }
        let rush = project.orderedRushes[index]
        let fps = rush.nominalFrameRate > 1 ? rush.nominalFrameRate : 30
        // Le clip touche-t-il la fin du rush (à une image près) ?
        return abs(CMTimeRangeGetEnd(range).seconds - rush.duration.seconds) < 1 / fps
    }

    private func handleSelectionDrag(_ deltaSeconds: Double) {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let rush = project.orderedRushes[index]
        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 600)
        // En mode « fin du rush », déplacer le début RACCOURCIT ou RALLONGE la
        // sélection : sa fin reste collée au bout du rush. La déplacer à
        // longueur constante la décollerait de la fin, ce qui contredirait le
        // mode choisi.
        let moved = selectionFollowsRushEnd
            ? SelectionEngine.moveOpenEnd(range, by: delta,
                                          rushDuration: rush.duration,
                                          minimumDuration: minimumSourceDuration(for: rush))
            : SelectionEngine.move(range, by: delta, rushDuration: rush.duration)
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
        if selectionFollowsRushEnd {
            selectionRange = SelectionEngine.moveOpenEnd(
                range,
                by: CMTimeMultiply(frameDuration, multiplier: Int32(frames)),
                rushDuration: rush.duration,
                minimumDuration: minimumSourceDuration(for: rush)
            )
        } else {
            selectionRange = SelectionEngine.nudge(
                range, frames: frames, frameDuration: frameDuration, rushDuration: rush.duration
            )
        }
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
        // Durée finale DÉDUITE de la plage réellement prélevée, jamais recopiée
        // du projet : une sélection étendue « jusqu'à la fin du rush » serait
        // sinon exportée à la durée fixe du projet, donc tronquée. Pour une
        // sélection normale le calcul redonne exactement la valeur du projet.
        passage.finalDurationCentiseconds = TimeMath.finalDuration(
            source: range.duration,
            speed: RationalSpeed(numerator: project.speedNumerator,
                                 denominator: project.speedDenominator)
        ).centiseconds
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
            // La LONGUEUR suit elle aussi : depuis « jusqu'à la fin du rush »,
            // rééditer un clip peut changer sa durée, pas seulement sa
            // position. Ne recopier que le début laisserait un clip dont la
            // boucle affichée et le fichier exporté divergent.
            passage.sourceDurationValue = range.duration.value
            passage.sourceDurationTimescale = range.duration.timescale
            passage.finalDurationCentiseconds = TimeMath.finalDuration(
                source: range.duration,
                speed: RationalSpeed(numerator: passage.speedNumerator,
                                     denominator: passage.speedDenominator)
            ).centiseconds
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
                errorMessage = "Mise en cache de la plage impossible pour ce clip — conservez le rush (l'export utilisera la copie source complète)."
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
                errorMessage = "Un autre clip de ce rush n'a pas encore sa plage cachée — rush conservé."
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
        let pending = project.visiblePassages.filter { $0.rush === rush && $0.cachedRangeRelativePath == nil }
        guard pending.isEmpty else {
            errorMessage = "\(pending.count) clip(s) de ce rush n'ont pas encore leur plage cachée — rush conservé (leur export deviendrait impossible)."
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
        // MISE EN SURSIS, pas suppression : le rush et son fichier restent en
        // place, masqués, le temps qu'un « Annuler » puisse encore les
        // rappeler. Effacer le fichier tout de suite rendrait le retour
        // impossible, quoi qu'on fasse ensuite du modèle.
        rush.isPendingDeletion = true
        touch()
        rebuildSegments()
        playback.load(rush: currentRush)
        undo.schedule(label: "Rush supprimé") {
            if let path = rush.localSourceRelativePath {
                try? FileManager.default.removeItem(
                    at: StorageManager.url(forSourceRelativePath: path))
            }
            modelContext.delete(rush)
            try? modelContext.save()
        } restore: {
            // La sélection courante désigne un rush PAR INDEX dans
            // `orderedRushes`. Réinsérer un rush masqué rallonge cette liste et
            // décale tous les index situés après lui : l'index 2 ne désigne
            // plus le même rush. Sans ce recalage, « Valider » créait un clip
            // sur le rush voisin, au timecode d'un autre, sans la moindre
            // erreur — les images n'avaient simplement rien à voir.
            let aimedRush = selectionRushIndex.flatMap { index -> Rush? in
                let visible = project.orderedRushes
                return index < visible.count ? visible[index] : nil
            }
            rush.isPendingDeletion = false
            try? modelContext.save()
            rebuildSegments()
            // La tête de lecture est un temps GLOBAL : réinsérer un rush
            // décale tous les offsets en aval, donc `playhead` désigne
            // désormais d'autres images. On la ramène sur le rush qu'elle
            // regardait.
            let aimedPlayhead = currentRushIndex.flatMap { index -> (Rush, Double)? in
                let visible = project.orderedRushes
                guard index < visible.count else { return nil }
                return (visible[index], playhead - segmentStart(rushIndex: index))
            }
            if let aimedRush,
               let moved = project.orderedRushes.firstIndex(where: { $0 === aimedRush }) {
                selectionRushIndex = moved
            } else if selectionRushIndex != nil {
                // Le support de la sélection a disparu : on l'abandonne plutôt
                // que de la laisser désigner autre chose.
                selectionRushIndex = nil
                selectionRange = nil
                editingPassageID = nil
            }
            if let (watched, offset) = aimedPlayhead,
               let index = project.orderedRushes.firstIndex(where: { $0 === watched }) {
                playhead = segmentStart(rushIndex: index) + offset
                seekCounter += 1
                seek = ProgrammaticSeek(token: seekCounter, time: playhead)
            }
            playback.load(rush: currentRush)
        }
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
    /// Écrit tous les échantillons restants du lecteur dans l'entrée du
    /// writer, un à la fois. Retourne le nombre écrit.
    ///
    /// Séparée pour que l'appelant puisse annuler writer ET lecteur d'un seul
    /// `catch` : une annulation au milieu de l'écriture laissait sinon un
    /// AVAssetWriter vivant en état `.writing` sur un fichier supprimé.
    nonisolated private static func appendAll(from output: AVAssetReaderTrackOutput,
                                              to input: AVAssetWriterInput,
                                              writer: AVAssetWriter) async throws -> Int {
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Attente BORNÉE : un encodeur qui n'accepte plus rien figerait la
            // mise en cache indéfiniment, sans message.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || ContinuousClock.now > deadline {
                    throw RemuxError.writerStalled
                }
                try await Task.sleep(for: .milliseconds(4))
            }
            guard input.append(sample) else { throw RemuxError.appendRefused }
            count += 1
        }
        return count
    }

    /// Échecs internes du remux — jamais montrés tels quels : l'appelant
    /// retourne nil et le message utilisateur vient de `cacheSourceRange`.
    private enum RemuxError: Error {
        case writerStalled
        case appendRefused
    }

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

            // DEUX PASSES, MÉMOIRE BORNÉE — ET C'EST INDISPENSABLE.
            //
            // L'écriture exige de connaître le PTS minimal AVANT le premier
            // append (startSession). Or le lecteur passthrough livre en ordre
            // de DÉCODAGE : avec des images B, le premier échantillon livré
            // n'est pas forcément le plus précoce à l'affichage. L'ancienne
            // version retenait donc TOUS les échantillons compressés dans un
            // tableau pour trouver ce minimum — invisible sur un clip de 1,3 s,
            // fatal en mode « jusqu'à la fin du rush » : une plage de trois
            // minutes en 4K60 HEVC, c'est 1 à 2 Go d'échantillons vivants
            // simultanément, donc l'app tuée par le système. Et comme le
            // passage était déjà enregistré, la mise en cache repartait à
            // chaque ouverture du projet : boucle de plantage.
            //
            // Première passe : parcourir pour trouver le minimum, en RELÂCHANT
            // chaque échantillon aussitôt (aucune accumulation). Seconde
            // passe : relire et écrire au fil de l'eau. Le coût est une
            // lecture disque supplémentaire — sans décodage, c'est du transfert
            // pur — contre une empreinte mémoire constante quelle que soit la
            // durée. Aucune hypothèse sur la profondeur de réordonnancement.
            var minPTS = CMTime.positiveInfinity
            var sampleCount = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if pts.isValid, CMTimeCompare(pts, minPTS) < 0 { minPTS = pts }
                sampleCount += 1
                // `sample` meurt à la fin de l'itération : rien ne s'accumule.
            }
            // STATUT DU LECTEUR : `copyNextSampleBuffer` renvoie nil aussi bien
            // à la fin normale du flux QUE sur erreur. Sans ce contrôle, une
            // lecture interrompue produisait une plage cachée TRONQUÉE, promue
            // ensuite source d'export après « Val. + Suppr. » — le rush
            // original ayant été purgé, la perte était définitive et
            // silencieuse.
            guard reader.status == .completed else { return nil }
            guard sampleCount > 0, minPTS != .positiveInfinity else { return nil }

            // Seconde passe : un lecteur neuf sur la même plage.
            let writeReader = try AVAssetReader(asset: asset)
            writeReader.timeRange = CMTimeRange(start: start, end: end)
            let writeOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            writeOutput.alwaysCopiesSampleData = false
            writeReader.add(writeOutput)
            guard writeReader.startReading() else { return nil }

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

            // Écriture AU FIL DE L'EAU : un échantillon vivant à la fois.
            //
            // ANNULATION PROPRE. `retryMissingCaches` tourne dans un `.task`,
            // donc annulé dès qu'on quitte l'éditeur — geste banal. Sans ce
            // bloc, l'annulation remontait au `catch` général et le writer
            // partait en déallocation en état `.writing`, pendant que
            // l'appelant supprimait son fichier de sortie.
            let writtenCount: Int
            do {
                writtenCount = try await appendAll(from: writeOutput, to: input, writer: writer)
            } catch {
                writer.cancelWriting()
                writeReader.cancelReading()
                throw error
            }
            // La seconde passe doit livrer AUTANT d'échantillons que la
            // première : sinon la plage cachée est tronquée, et elle servira
            // de source d'export après « Val. + Suppr. ».
            guard writeReader.status == .completed, writtenCount == sampleCount else {
                writer.cancelWriting()
                return nil
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

    // MARK: - Espace disque

    /// Libère les copies sources SANS confirmation : l'action est explicite
    /// (le bouton annonce déjà le nombre d'octets libérables), et les originaux
    /// dans Photos ne sont jamais touchés — rien d'irréversible à protéger.
    ///
    /// Le seul garde-fou conservé est technique : supprimer un fichier pendant
    /// qu'un rendu le lit casserait l'export en cours.
    private func releaseSourcesNow() {
        // Garde UNIFIÉ : couvre la file clip-par-clip ET l'export du montage.
        if let reason = MediaAvailabilityService.blockingReason() {
            errorMessage = reason
            return
        }
        let freed = MediaAvailabilityService.releaseSources(in: project)
        try? modelContext.save()
        rebuildSegments()
        errorMessage = "Espace libéré : \(StorageManager.formatBytes(freed)). Les originaux restent intacts dans Photos."
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

// MARK: - Mode de durée

/// Choix de durée d'une sélection : longueur fixe, ou « jusqu'à la fin du
/// rush ».
///
/// Modélisé comme un vrai choix unique (et non un booléen à côté d'un entier)
/// pour que le menu puisse le présenter en liste cochée : les deux options
/// s'excluent, l'interface doit le montrer.
enum DurationMode: Hashable {
    case fixed(Int)     // centièmes de seconde
    case toRushEnd
}
