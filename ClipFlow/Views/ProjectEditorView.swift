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

struct ProjectEditorView: View {
    @Bindable var project: ClipProject
    @Environment(\.modelContext) private var modelContext

    // Importation.
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importProgress: ImportProgress?
    @State private var importTask: Task<Void, Never>?

    // Proxys.
    @State private var proxyStatus: ProxyGenerationStatus?

    // Navigation temporelle.
    @State private var playhead: Double = 0
    @State private var programmaticTime: Double?

    // Sélection courante (temps LOCAL au rush, base source).
    @State private var selectionRushIndex: Int?
    @State private var selectionRange: CMTimeRange?

    // UI.
    @State private var playback = ProxyPlaybackEngine()
    @State private var showCategories = false
    @State private var showReview = false
    @State private var showExports = false
    @State private var pendingCategories: Set<String> = []
    @State private var errorMessage: String?

    private let validateHaptic = UINotificationFeedbackGenerator()

    // MARK: - Modèle de timeline

    private var segments: [TimelineSegment] {
        var offset: Double = 0
        return project.orderedRushes.enumerated().map { index, rush in
            let segment = TimelineSegment(
                rushIndex: index,
                title: "\(index + 1) · \(rush.originalFilename)",
                proxyPath: rush.proxyRelativePath,
                startOffset: offset,
                duration: rush.duration.seconds
            )
            offset += rush.duration.seconds
            return segment
        }
    }

    private func segmentStart(rushIndex: Int) -> Double {
        segments.first(where: { $0.rushIndex == rushIndex })?.startOffset ?? 0
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
                    .frame(maxHeight: isLandscape ? .infinity : geometry.size.height * 0.45)
                statusBar
                TimelineView(
                    segments: segments,
                    overlays: overlays,
                    programmaticTime: programmaticTime,
                    onScrub: handleScrub,
                    onTap: handleTap,
                    onSelectionDrag: handleSelectionDrag,
                    onSelectionDragEnded: persistAfterMove
                )
                .frame(height: isLandscape ? 120 : 150)
                controlBar
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showCategories) {
            CategoryPanelView(groups: project.categoryGroups, selected: $pendingCategories)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showReview) {
            NavigationStack { ReviewView(project: project) }
        }
        .sheet(isPresented: $showExports) {
            NavigationStack { RenderQueueView(project: project) }
        }
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await observeProxyStatus() }
        .onAppear {
            RenderQueueController.shared.configure(container: modelContext.container)
        }
    }

    // MARK: - Sous-vues

    private var playerArea: some View {
        ZStack {
            PlayerLayerView(player: playback.player)
            if project.rushes.isEmpty {
                ContentUnavailableView(
                    "Aucun rush",
                    systemImage: "photo.badge.plus",
                    description: Text("Importez des vidéos avec le bouton +.")
                )
            }
        }
        .onChange(of: currentRushIndex) { _, _ in
            playback.load(proxyPath: currentRush?.proxyRelativePath)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let rush = currentRush, let index = currentRushIndex {
                Text("Rush \(index + 1)/\(project.rushes.count) — \(rush.originalFilename)")
                    .font(.caption)
                    .lineLimit(1)
                availabilityBadge(rush.availability)
            }
            Spacer()
            if let progress = importProgress, progress.completed < progress.total {
                HStack(spacing: 4) {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .frame(width: 70)
                    Text("Import \(progress.completed)/\(progress.total)").font(.caption2)
                    Button("Annuler") { importTask?.cancel() }.font(.caption2)
                }
            } else if let status = proxyStatus, status.completed < status.totalQueued {
                Text("Proxys \(status.completed)/\(status.totalQueued)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.85))
        .foregroundStyle(.white)
    }

    private func availabilityBadge(_ availability: RushAvailability) -> some View {
        let (text, color): (String, Color) = switch availability {
        case .offlineReady: ("hors ligne ✓", .green)
        case .localReady: ("local", .blue)
        case .importing: ("import…", .orange)
        case .needsICloudDownload: ("iCloud requis", .red)
        case .unavailable: ("indisponible", .red)
        case .unknown: ("?", .gray)
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            // Image par image sur la sélection.
            Button { nudgeSelection(frames: -1) } label: { Image(systemName: "backward.frame") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button {
                playback.isPlaying ? playback.pause() : playback.play()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { nudgeSelection(frames: 1) } label: { Image(systemName: "forward.frame") }
                .keyboardShortcut(.rightArrow, modifiers: [])

            Button {
                playSelectionLoop()
            } label: {
                Image(systemName: "repeat")
            }
            .disabled(selectionRange == nil)

            Spacer()

            Button {
                showCategories = true
            } label: {
                Image(systemName: "tag")
                    .overlay(alignment: .topTrailing) {
                        if !pendingCategories.isEmpty {
                            Circle().fill(.blue).frame(width: 8, height: 8).offset(x: 4, y: -4)
                        }
                    }
            }

            Button("Rejeter", role: .destructive) {
                selectionRange = nil
                selectionRushIndex = nil
            }
            .disabled(selectionRange == nil)

            Button("Valider") { validateSelection() }
                .buttonStyle(.borderedProminent)
                .disabled(selectionRange == nil)
                .keyboardShortcut(.return, modifiers: [])
        }
        .font(.title3)
        .padding(10)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            PhotosPicker(
                selection: $pickerItems,
                selectionBehavior: .ordered,     // ordre de sélection visible
                matching: .videos,               // vidéos uniquement
                preferredItemEncoding: .current  // encodage original privilégié
            ) {
                Image(systemName: "plus")
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                startImport(items)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                durationMenu
                Toggle("Toucher = centre de la sélection", isOn: $project.touchAnchorIsCenter)
                Toggle("Proxys 240p", isOn: $project.proxy240p)
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
        playhead = globalTime
        programmaticTime = nil
        guard let index = rushIndex(atGlobalTime: globalTime) else { return }
        let local = globalTime - segmentStart(rushIndex: index)
        playback.load(proxyPath: project.orderedRushes[index].proxyRelativePath)
        playback.seek(to: CMTime(seconds: local, preferredTimescale: 600))
    }

    private func handleTap(_ globalTime: Double) {
        guard let index = rushIndex(atGlobalTime: globalTime) else { return }
        let rush = project.orderedRushes[index]
        let local = CMTime(seconds: globalTime - segmentStart(rushIndex: index), preferredTimescale: 600)
        do {
            let range = try SelectionEngine.makeSelection(
                touchTime: local,
                sourceDuration: fixedSourceDuration,
                rushDuration: rush.duration,
                anchorCenter: project.touchAnchorIsCenter
            )
            selectionRushIndex = index
            selectionRange = range
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleSelectionDrag(_ deltaSeconds: Double) {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let rush = project.orderedRushes[index]
        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 600)
        selectionRange = SelectionEngine.move(range, by: delta, rushDuration: rush.duration)
    }

    private func persistAfterMove() {
        // La sélection courante n'est persistée qu'à la validation ;
        // rien à sauvegarder ici, mais l'appui long a pu activer le mode fin.
    }

    private func nudgeSelection(frames: Int) {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let rush = project.orderedRushes[index]
        let fps = rush.nominalFrameRate > 1 ? rush.nominalFrameRate : 30
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        selectionRange = SelectionEngine.nudge(
            range, frames: frames, frameDuration: frameDuration, rushDuration: rush.duration
        )
    }

    private func playSelectionLoop() {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        playback.load(proxyPath: project.orderedRushes[index].proxyRelativePath)
        playback.playLoop(range: range)
    }

    // MARK: - Validation

    private func validateSelection() {
        guard let index = selectionRushIndex, let range = selectionRange else { return }
        let rush = project.orderedRushes[index]

        let passage = Passage()
        passage.validationIndex = (project.passages.map(\.validationIndex).max() ?? -1) + 1
        passage.setStart(range.start)
        passage.sourceDurationValue = range.duration.value
        passage.sourceDurationTimescale = range.duration.timescale
        passage.finalDurationCentiseconds = project.finalDurationCentiseconds
        passage.speedNumerator = project.speedNumerator
        passage.speedDenominator = project.speedDenominator
        passage.categories = pendingCategories.sorted()
        passage.rush = rush
        passage.project = project
        modelContext.insert(passage)
        touch()

        validateHaptic.notificationOccurred(.success)
        selectionRange = nil
        selectionRushIndex = nil
        pendingCategories = []

        // Mise en cache de la plage source pleine qualité (export hors-ligne).
        cacheSourceRange(for: passage, rush: rush)

        // Passage au rush suivant.
        if index + 1 < project.orderedRushes.count {
            let nextStart = segmentStart(rushIndex: index + 1)
            playhead = nextStart
            programmaticTime = nextStart
        }
    }

    /// Copie passthrough (sans réencodage) de la plage sélectionnée + marge,
    /// pour garantir l'export même si la source complète est libérée ensuite.
    private func cacheSourceRange(for passage: Passage, rush: Rush) {
        guard let sourcePath = rush.localSourceRelativePath else { return }
        let sourceURL = StorageManager.url(forSourceRelativePath: sourcePath)
        let margin = MediaAvailabilityService.cacheMargin(for: rush)
        let start = CMTimeMaximum(.zero, CMTimeSubtract(passage.start, margin))
        let end = CMTimeMinimum(rush.duration, CMTimeAdd(passage.sourceRange.end, margin))
        let cacheRange = CMTimeRange(start: start, end: end)
        let filename = "range-\(UUID().uuidString).mov"
        let destination = StorageManager.url(forCachedRangeRelativePath: filename)
        let passageID = passage.persistentModelID

        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: sourceURL)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
            export.timeRange = cacheRange
            do {
                try await export.export(to: destination, as: .mov)
                StorageManager.excludeFromBackup(destination)
                await MainActor.run {
                    // Le start du passage reste en temps RUSH ; seul le décalage
                    // du fichier caché est mémorisé (rebasage fait à l'export).
                    if let saved = self.modelContext.model(for: passageID) as? Passage {
                        saved.cachedRangeRelativePath = filename
                        saved.cachedRangeOffsetValue = start.value
                        saved.cachedRangeOffsetTimescale = start.timescale
                        try? self.modelContext.save()
                    }
                }
            } catch {
                // Échec non bloquant : l'export utilisera la copie source complète.
            }
        }
    }

    // MARK: - Importation

    private func startImport(_ items: [PhotosPickerItem]) {
        pickerItems = []
        importTask = Task {
            do {
                let imported = try await PhotoImporter.importItems(items) { progress in
                    importProgress = progress
                }
                await integrate(imported)
            } catch {
                errorMessage = "Importation interrompue : \(error.localizedDescription)"
            }
            importProgress = nil
            importTask = nil
        }
    }

    @MainActor
    private func integrate(_ imported: [ImportedRushInfo]) async {
        // Tri chronologique par cascade de replis.
        let keys = imported.map {
            RushSortKey(
                assetCreationDate: $0.captureDate,
                fileCreationDate: $0.fileCreationDate,
                timecodeSeconds: nil,
                filename: $0.originalFilename,
                pickOrder: $0.pickOrder
            )
        }
        let order = ChronoSort.sortedIndices(keys)
        var nextIndex = (project.rushes.map(\.orderIndex).max() ?? -1) + 1

        for position in order {
            let info = imported[position]
            let rush = Rush()
            rush.orderIndex = nextIndex
            nextIndex += 1
            rush.assetIdentifier = info.assetIdentifier
            rush.originalFilename = info.originalFilename
            rush.captureDate = info.captureDate
            rush.fileCreationDate = info.fileCreationDate
            rush.pickOrder = info.pickOrder
            rush.durationValue = info.duration.value
            rush.durationTimescale = info.duration.timescale
            rush.width = info.width
            rush.height = info.height
            rush.nominalFrameRate = info.nominalFrameRate
            rush.codec = info.codec
            rush.rotationDegrees = info.rotationDegrees
            rush.colorimetry = info.colorimetry
            rush.is10Bit = info.is10Bit
            rush.localSourceRelativePath = info.localRelativePath
            rush.availability = .localReady
            rush.project = project
            modelContext.insert(rush)

            // Proxy en arrière-plan — travail possible dès les premiers rushes.
            let sourceURL = StorageManager.url(forSourceRelativePath: info.localRelativePath)
            let proxyName = "proxy-\(UUID().uuidString).mp4"
            let rushID = rush.persistentModelID
            let use240p = project.proxy240p
            await ProxyGenerator.shared.enqueue(ProxyGenerator.ProxyJob(
                sourceURL: sourceURL,
                proxyFilename: proxyName,
                use240p: use240p
            ) { relativePath in
                await MainActor.run {
                    if let saved = self.modelContext.model(for: rushID) as? Rush {
                        saved.proxyRelativePath = relativePath
                        saved.availability = MediaAvailabilityService.evaluate(rush: saved)
                        try? self.modelContext.save()
                    }
                }
            })
        }
        touch()
    }

    private func observeProxyStatus() async {
        for await status in await ProxyGenerator.shared.statusStream() {
            proxyStatus = status
        }
    }

    /// Sauvegarde automatique après chaque modification importante.
    private func touch() {
        project.updatedAt = .now
        try? modelContext.save()
    }
}
