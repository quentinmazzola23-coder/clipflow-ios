//
//  MontageView.swift
//  ClipFlow
//
//  ÉCRAN DE MONTAGE : la musique décide des durées, les clips validés se
//  placent tout seuls.
//
//  Philosophie identique au reste de l'app : le moins de gestes possible,
//  tout à portée de pouce, AUCUNE confirmation.
//    - pas de musique → le sélecteur de fichiers s'ouvre TOUT SEUL ;
//    - musique choisie → analyse immédiate, carte de rythme affichée ;
//    - clips placés automatiquement dans l'ordre de validation ;
//    - un glissement sur la forme d'onde déplace la fenêtre (recalée au beat) ;
//    - aperçu et export : la MÊME composition — ce qu'on voit est ce qu'on a.
//

import SwiftUI
import SwiftData
import AVKit
import CoreMedia
import UniformTypeIdentifiers

struct MontageView: View {
    @Bindable var project: ClipProject
    @Environment(\.modelContext) private var modelContext

    /// Étapes de l'écran — une seule à la fois, l'interface suit.
    private enum Stage: Equatable {
        case needsMusic
        case analyzing
        case ready
        case exporting(Double)
    }

    @State private var stage: Stage = .needsMusic
    @State private var beatMap: BeatMap?
    @State private var plan: MontagePlan?
    /// URL du fichier de chaque clip placé (id = index du passage).
    @State private var clipSources: [Int: URL] = [:]
    @State private var windowStart: Double = 0
    @State private var showFileImporter = false
    @State private var autoImporterLaunched = false
    @State private var errorMessage: String?
    @State private var exportToast: String?
    /// Jeton du toast courant : l'effacement différé ne touche que le sien.
    @State private var toastToken = UUID()
    @State private var analysisTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var isPreviewing = false

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .navigationTitle("Montage")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { importMusic(from: url) }
            case .failure(let error):
                errorMessage = "Sélection impossible : \(error.localizedDescription)"
            }
        }
        .onAppear {
            // Musique déjà en place : réanalyse (cache) sans aucun tap.
            if let filename = project.musicFilename {
                startAnalysis(filename: filename)
            } else if !autoImporterLaunched {
                // ZÉRO clic : arriver ici sans musique ouvre le sélecteur.
                autoImporterLaunched = true
                showFileImporter = true
            }
        }
        .onDisappear {
            analysisTask?.cancel()
            player?.pause()
        }
        .alert("Montage", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Contenu par étape

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .needsMusic:
            ContentUnavailableView {
                Label("Choisissez une musique", systemImage: "music.note")
            } description: {
                Text("Le rythme de la musique découpera vos \(project.passages.count) clips automatiquement.")
            } actions: {
                Button {
                    showFileImporter = true
                } label: {
                    Text("Choisir un fichier")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
            }

        case .analyzing:
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Analyse du rythme…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let title = project.musicTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

        case .ready, .exporting:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let map = beatMap {
            VStack(spacing: 12) {
                header(map: map)

                // Aperçu vidéo — la composition elle-même, jouée sur place.
                ZStack {
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.black.opacity(0.6))
                        Text(plan.map { "\($0.placements.count) clips prêts" } ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)

                BeatWaveformView(
                    map: map,
                    windowStart: windowStart,
                    plan: plan,
                    onScrub: { moveWindow(to: $0, commit: false) },
                    onScrubEnd: { moveWindow(to: $0, commit: true) }
                )
                .frame(height: 96)
                .padding(.horizontal, 12)
                // Déplacer la fenêtre pendant un export reconstruirait le plan
                // sous les pieds de la session — verrouillé.
                .allowsHitTesting(!isExporting)

                bottomBar
            }
            .padding(.bottom, 8)
            .overlay(alignment: .top) {
                if let toast = exportToast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 6)
                }
            }
        }
    }

    private func header(map: BeatMap) -> some View {
        HStack(spacing: 14) {
            Label(String(format: "%.0f BPM", map.bpm), systemImage: "metronome")
            if let plan {
                Label("\(plan.placements.count)/\(project.passages.count) clips",
                      systemImage: "film.stack")
                Label(formatDuration(plan.totalDuration.seconds), systemImage: "timer")
            }
            Spacer()
        }
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var isExporting: Bool {
        if case .exporting = stage { return true }
        return false
    }

    /// Barre basse — les trois actions, à portée de pouce, sans confirmation.
    /// TOUT est verrouillé pendant l'export : changer la musique supprimerait
    /// le fichier que la session d'export est en train de lire.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showFileImporter = true
            } label: {
                Image(systemName: "music.note")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            .accessibilityLabel("Changer de musique")
            .disabled(isExporting)

            Button {
                togglePreview()
            } label: {
                Image(systemName: isPreviewing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 52))
            .accessibilityLabel(isPreviewing ? "Pause" : "Aperçu")
            .disabled(isExporting || (plan?.placements.isEmpty ?? true))

            Spacer()

            if case .exporting(let progress) = stage {
                // Style linéaire : sur iOS, le style circulaire avec `value`
                // rend un simple sablier indéterminé — la fraction disparaît.
                ProgressView(value: progress)
                    .frame(width: 90)
                Text("\(Int(progress * 100)) %")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    exportMontage()
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(plan?.placements.isEmpty ?? true)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Musique

    private func importMusic(from url: URL) {
        do {
            // Copier la NOUVELLE musique d'abord ; l'ancienne n'est supprimée
            // qu'après le succès. Dans l'autre ordre, une copie qui échoue
            // (fichier iCloud non téléchargé, disque plein) laissait le
            // projet pointer vers un fichier déjà effacé — musique perdue.
            let filename = try MusicStore.importMusic(from: url)
            if let old = project.musicFilename {
                MusicStore.deleteMusic(filename: old)
            }
            project.musicFilename = filename
            project.musicTitle = url.deletingPathExtension().lastPathComponent
            project.montageStartCentiseconds = nil // nouvelle musique = départ auto
            try? modelContext.save()
            startAnalysis(filename: filename)
        } catch {
            errorMessage = "Import impossible : \(error.localizedDescription)"
        }
    }

    private func startAnalysis(filename: String) {
        stage = .analyzing
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                let map: BeatMap
                if let cached = MusicStore.cachedBeatMap(musicFilename: filename) {
                    map = cached
                } else {
                    let url = MusicStore.url(forMusicFilename: filename)
                    // Décodage + FFT HORS acteur principal : plusieurs
                    // secondes de calcul, l'interface doit rester vivante.
                    let analyzed = try await Task.detached(priority: .userInitiated) {
                        let samples = try await MusicDecoder.monoSamples(of: url)
                        return BeatAnalyzer.analyze(
                            samples: samples, sampleRate: MusicDecoder.analysisSampleRate
                        )
                    }.value
                    guard let analyzed else {
                        throw MusicDecoderError.readFailed("aucune pulsation détectable")
                    }
                    MusicStore.saveBeatMap(analyzed, musicFilename: filename)
                    map = analyzed
                }
                guard !Task.isCancelled else { return }
                beatMap = map
                // RECALAGE AU BEAT, quel que soit le chemin d'arrivée : le
                // départ suggéré tombe entre deux beats (centre − 35 % de la
                // cible), et la valeur persistée est arrondie au centième —
                // 5 ms au-delà du beat suffisent à le faire SAUTER, donc à
                // décaler la fenêtre d'un beat entier à la réouverture.
                let restored = project.montageStartCentiseconds.map { Double($0) / 100 }
                    ?? map.suggestedWindowStart
                windowStart = map.beatTimes.min(by: {
                    abs($0 - restored) < abs($1 - restored)
                }) ?? restored
                await rebuildPlan()
                stage = .ready
            } catch is CancellationError {
                // Écran quitté pendant l'analyse : rien à faire.
            } catch {
                stage = .needsMusic
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Fenêtre et plan

    private func moveWindow(to time: Double, commit: Bool) {
        guard let map = beatMap else { return }
        // Recalage AU BEAT le plus proche : la fenêtre commence toujours sur
        // un beat, sinon tout le montage serait décalé de la musique.
        let snapped = map.beatTimes.min(by: {
            abs($0 - time) < abs($1 - time)
        }) ?? 0
        windowStart = snapped
        guard commit else { return }
        project.montageStartCentiseconds = Int((snapped * 100).rounded())
        try? modelContext.save()
        Task { await rebuildPlan() }
    }

    /// Reconstruit le plan de placement : passages dans l'ordre de validation,
    /// chacun démarrant à SON point d'entrée, durée dictée par son créneau.
    private func rebuildPlan() async {
        guard let map = beatMap else { return }
        stopPreview()
        // La composition affichée ne correspond plus au plan : la garder
        // rejouerait l'ANCIEN montage — pire qu'un écran de veille.
        player = nil

        var candidates: [MontageClipCandidate] = []
        var sources: [Int: URL] = [:]

        for (index, passage) in project.orderedPassages.enumerated() {
            // Plage cachée d'abord (autonome), copie source sinon.
            let url: URL
            let startInFile: CMTime
            if let cachedPath = passage.cachedRangeRelativePath {
                url = StorageManager.url(forCachedRangeRelativePath: cachedPath)
                startInFile = CMTimeSubtract(passage.start, passage.cachedRangeOffset)
            } else if let sourcePath = passage.rush?.localSourceRelativePath {
                url = StorageManager.url(forSourceRelativePath: sourcePath)
                startInFile = passage.start
            } else {
                continue // ni cache ni source : rien à monter pour ce passage
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let duration = try? await AVURLAsset(url: url).load(.duration) else { continue }

            candidates.append(MontageClipCandidate(
                id: index,
                startInFile: startInFile,
                fileDuration: duration,
                speed: RationalSpeed(numerator: passage.speedNumerator,
                                     denominator: passage.speedDenominator)
            ))
            sources[index] = url
        }

        let slots = map.slots(from: windowStart)
        plan = MontagePlanner.plan(slots: slots, clips: candidates, windowStart: windowStart)
        clipSources = sources
    }

    // MARK: - Aperçu

    private func togglePreview() {
        if isPreviewing {
            stopPreview()
            return
        }
        guard let plan, let filename = project.musicFilename else { return }
        Task {
            do {
                let montage = try await MontageComposer.build(
                    plan: plan,
                    sources: clipSources,
                    musicURL: MusicStore.url(forMusicFilename: filename)
                )
                let item = AVPlayerItem(asset: montage.composition)
                item.videoComposition = montage.videoComposition
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer
                newPlayer.play()
                isPreviewing = true
                // Fin de lecture : l'état du bouton suit, sans intervention.
                NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item, queue: .main
                ) { _ in
                    Task { @MainActor in isPreviewing = false }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopPreview() {
        player?.pause()
        isPreviewing = false
    }

    // MARK: - Export

    private func exportMontage() {
        guard let plan, let filename = project.musicFilename else { return }
        stopPreview()
        stage = .exporting(0)
        Task {
            do {
                let montage = try await MontageComposer.build(
                    plan: plan,
                    sources: clipSources,
                    musicURL: MusicStore.url(forMusicFilename: filename)
                )
                let name = "Montage — \(project.name).mov"
                let fileURL = try await MontageComposer.export(montage, outputFilename: name) { progress in
                    Task { @MainActor in
                        if case .exporting = stage { stage = .exporting(progress) }
                    }
                }
                let projectName = project.albumPerProject ? project.name : nil
                _ = try await PhotoExportService.saveToPhotos(fileURL: fileURL,
                                                              projectName: projectName)
                try? FileManager.default.removeItem(at: fileURL)
                if isExporting { stage = .ready }
                let token = UUID()
                toastToken = token
                withAnimation { exportToast = "Montage enregistré dans Photos 🎉" }
                try? await Task.sleep(for: .seconds(3))
                // Un export suivant a pu reposter un toast : seul le SIEN
                // a le droit de l'effacer.
                if toastToken == token {
                    withAnimation { exportToast = nil }
                }
            } catch {
                if isExporting { stage = .ready }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Forme d'onde et carte de rythme

/// Forme d'onde + beats colorés par section + fenêtre de montage.
/// Un GLISSEMENT HORIZONTAL déplace la fenêtre — le geste le plus simple
/// possible, exécutable au pouce, recalé au beat au relâchement.
struct BeatWaveformView: View {
    var map: BeatMap
    var windowStart: Double
    var plan: MontagePlan?
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void

    private func color(for section: BeatSection) -> Color {
        switch section {
        case .drop: return Theme.accent
        case .build: return .orange
        case .verse: return .cyan.opacity(0.8)
        case .breakdown: return .gray
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = width / max(map.duration, 0.001)
            let montageEnd = windowStart + (plan?.totalDuration.seconds ?? 0)

            Canvas { context, size in
                // 1. Forme d'onde (barres, max par seau).
                let buckets = map.waveform
                guard !buckets.isEmpty else { return }
                let barWidth = size.width / CGFloat(buckets.count)
                for (index, value) in buckets.enumerated() {
                    let x = CGFloat(index) * barWidth
                    let barHeight = max(1, CGFloat(value) * size.height * 0.55)
                    let time = Double(index) / Double(buckets.count) * map.duration
                    let inWindow = time >= windowStart && time <= montageEnd
                    context.fill(
                        Path(CGRect(x: x, y: (size.height - barHeight) / 2,
                                    width: max(0.5, barWidth - 0.5), height: barHeight)),
                        with: .color(.white.opacity(inWindow ? 0.85 : 0.25))
                    )
                }
                // 2. Beats : un trait coloré par section, sur la fenêtre.
                for (index, beat) in map.beatTimes.enumerated()
                where beat >= windowStart && beat <= montageEnd {
                    let x = CGFloat(beat) * scale
                    context.fill(
                        Path(CGRect(x: x, y: size.height * 0.82,
                                    width: 2, height: size.height * 0.14)),
                        with: .color(color(for: map.sections[index]))
                    )
                }
                // 3. Bord de fenêtre : la poignée visuelle du glissement.
                let startX = CGFloat(windowStart) * scale
                context.fill(
                    Path(CGRect(x: startX - 1.5, y: 0, width: 3, height: size.height)),
                    with: .color(Theme.accent)
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        onScrub(Double(value.location.x / max(scale, 0.001)))
                    }
                    .onEnded { value in
                        onScrubEnd(Double(value.location.x / max(scale, 0.001)))
                    }
            )
            .frame(width: width, height: height)
        }
        .accessibilityLabel("Fenêtre de montage dans la musique")
        .accessibilityHint("Glissez pour déplacer le départ du montage")
    }
}
