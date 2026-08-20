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
import UIKit

struct MontageView: View {
    @Bindable var project: ClipProject
    @Environment(\.modelContext) private var modelContext

    /// Étapes de l'écran — une seule à la fois, l'interface suit.
    private enum Stage: Equatable {
        case needsMusic
        case analyzing
        case ready
    }

    @State private var stage: Stage = .needsMusic
    @State private var beatMap: BeatMap?
    @State private var plan: MontagePlan?
    /// URL du fichier de chaque clip placé (id = index du passage).
    @State private var clipSources: [Int: URL] = [:]
    @State private var windowStart: Double = 0
    @State private var showFileImporter = false
    @State private var showLibrary = false
    @State private var showOverlays = false
    /// Image extraite du montage, fond de la pose d'incrustations.
    @State private var overlayBackdrop: UIImage?
    /// Clip d'où vient la vignette. La taille de rendu du montage est celle du
    /// PREMIER clip placé : si ce clip change (autre densité, autre fenêtre),
    /// une vignette gardée décrirait un cadrage qui n'existe plus.
    @State private var overlayBackdropClipID: Int?
    /// Rapport largeur/hauteur RÉEL du rendu, lu dans les métadonnées de la
    /// piste. Il vaut même quand l'extraction d'image échoue — sans lui,
    /// l'éditeur retombait sur un 9:16 supposé et gravait des positions
    /// calculées sur une forme inventée.
    @State private var overlayVideoRatio: CGFloat?
    /// Position de lecture de l'aperçu — pilote l'affichage des incrustations.
    @State private var previewTime: Double = 0
    /// Observateur de temps du lecteur d'aperçu, retiré avec lui.
    @State private var timeObserver: Any?
    /// Taille de l'image rendue, pour placer les incrustations dans le cadre
    /// réel de la vidéo (le lecteur la met en boîte aux lettres).
    @State private var previewRenderSize: CGSize?
    @State private var autoImporterLaunched = false
    @State private var errorMessage: String?
    @State private var exportToast: String?
    /// Jeton du toast courant : l'effacement différé ne touche que le sien.
    @State private var toastToken = UUID()
    @State private var analysisTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var isPreviewing = false
    /// Tâche de construction de l'aperçu — ANNULABLE.
    ///
    /// Sans ce jeton, fermer l'écran pendant la construction (plusieurs
    /// secondes sur 150 clips) laissait la tâche se réveiller APRÈS la
    /// disparition de la vue : le lecteur s'installait, jouait à plein volume
    /// par-dessus l'écran précédent, et plus aucun bouton ne pouvait
    /// l'arrêter. L'observateur périodique n'était alors jamais retiré.
    @State private var previewTask: Task<Void, Never>?
    /// Numéro de génération du plan. Un aperçu construit sur un plan périmé
    /// se jette au lieu de s'installer derrière le dos de `rebuildPlan`.
    @State private var planGeneration = 0
    /// Vrai pendant `MontageComposer.build` : `isPreviewing` ne devient vrai
    /// qu'à la fin, il ne peut donc pas servir de verrou contre un double
    /// appui qui lancerait deux compositions complètes en parallèle.
    @State private var isBuildingPreview = false
    /// Jeton de la construction COURANTE. Une construction abandonnée qui va
    /// jusqu'à son terme ne doit pas éteindre l'indicateur d'une construction
    /// plus récente — ni le laisser allumé alors que plus rien ne se prépare.
    @State private var previewToken = UUID()
    /// Génération du plan qui a produit le lecteur en place. Au-delà, la
    /// composition mémorisée ne décrit plus le montage affiché.
    @State private var playerGeneration: Int?
    /// Extraction de la vignette de pose — annulable, comme l'aperçu.
    @State private var backdropTask: Task<Void, Never>?
    /// Reconstruction de plan en cours.
    @State private var rebuildTask: Task<Void, Never>?
    /// Jeton d'observation de fin de lecture — retiré avant chaque nouvel
    /// aperçu, sinon un observateur s'accumule par lecture.
    @State private var endObserver: NSObjectProtocol?
    /// Lecteur d'AUDITION : joue la musique seule pendant le glissement de la
    /// fenêtre — on place le départ à l'oreille, pas à l'aveugle.
    @State private var auditionPlayer: AVPlayer?
    @State private var auditionStopTask: Task<Void, Never>?
    /// Limitation des seeks d'audition pendant le glissement (~8/s suffisent).
    @State private var lastAuditionSeek = Date.distantPast

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
            announceExportOutcome()
            // Musique déjà en place : réanalyse (cache) sans aucun tap.
            if let filename = project.musicFilename {
                startAnalysis(filename: filename)
            } else if !autoImporterLaunched {
                // ZÉRO clic : arriver ici sans musique ouvre LA BIBLIOTHÈQUE
                // — devenue le parcours principal. Elle montre les morceaux
                // déjà là, et son écran vide propose l'import. Ouvrir le
                // sélecteur de fichiers directement court-circuitait la
                // banque et pouvait entrer en concurrence avec elle : deux
                // modaux, dont un avalé en silence.
                //
                // Après la transition du fullScreenCover : présenté pendant
                // l'animation, un modal est silencieusement ignoré et l'écran
                // paraît mort.
                autoImporterLaunched = true
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if project.musicFilename == nil { showLibrary = true }
                }
            }
        }
        // TOUTE FEUILLE COUPE LA LECTURE, et le branchement est sur le
        // DRAPEAU, pas sur le bouton : la bibliothèque s'ouvre aussi d'
        // elle-même quand le projet n'a pas encore de musique, et l'aperçu
        // continuait alors sous la feuille — bande-son du montage mêlée aux
        // extraits écoutés. Même patron que ProjectEditorView.
        .onChange(of: showOverlays) { _, presented in if presented { silence() } }
        .onChange(of: showLibrary) { _, presented in if presented { silence() } }
        .onChange(of: showFileImporter) { _, presented in if presented { silence() } }
        // INCRUSTATIONS : étape POSTÉRIEURE au montage — on ne décore pas une
        // vidéo qu'on n'a pas encore construite.
        .sheet(isPresented: $showOverlays, onDismiss: refreshOverlays) {
            NavigationStack {
                if let plan {
                    OverlayEditorView(project: project, plan: plan,
                                      backdrop: overlayBackdrop,
                                      videoRatio: overlayVideoRatio)
                }
            }
        }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                MusicLibraryView(density: density,
                                 currentFilename: project.musicFilename) { track in
                    useTrack(track)
                }
            }
        }
        .onDisappear {
            analysisTask?.cancel()
            rebuildTask?.cancel()
            backdropTask?.cancel()
            // `stopPreview` et non `pause` : il annule aussi la construction
            // en vol, et remet l'indicateur — sans quoi le bouton affichait
            // « pause » au retour alors que rien ne jouait.
            stopPreview()
            stopAudition()
            // Observateur de fin de lecture : retiré à la sortie, sinon un
            // observateur ET son AVPlayer fuyaient à chaque visite de l'écran.
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            releaseTimeObserver()
        }
        // Résultat d'un export terminé pendant l'absence : annoncé au retour.
        .onChange(of: MontageExportController.shared.lastOutcomeToken) { _, _ in
            announceExportOutcome()
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
                VStack(spacing: 10) {
                    Button {
                        showLibrary = true
                    } label: {
                        Label("Ma bibliothèque", systemImage: "music.note.list")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Importer un fichier", systemImage: "folder")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glass)
                }
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

        case .ready:
            readyContent
        }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// En PAYSAGE, la hauteur utile fond : en-tête, forme d'onde, densité et
    /// barre basse à taille fixe ne laissaient qu'une soixantaine de points à
    /// la visionneuse. Les éléments accessoires se compactent.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    @ViewBuilder
    private var readyContent: some View {
        if let map = beatMap {
            VStack(spacing: isCompactHeight ? 6 : 12) {
                header(map: map)

                // Aperçu vidéo — la composition elle-même, jouée sur place.
                ZStack {
                    if let player {
                        VideoPlayer(player: player)
                        // INCRUSTATIONS DE L'APERÇU, dessinées par-dessus.
                        // L'outil Core Animation d'AVFoundation ne fonctionne
                        // qu'à l'export : sans cette couche, l'utilisateur
                        // posait son logo et ne le voyait jamais à l'écran.
                        OverlayPreviewLayer(
                            overlays: resolvedOverlays,
                            currentTime: previewTime,
                            videoRatio: previewVideoRatio
                        )
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.black.opacity(0.6))
                        Text(planSummary)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                // Le commentaire de la barre basse promet que TOUT est
                // verrouillé pendant l'export : le lecteur aussi.
                .allowsHitTesting(!isExporting)

                BeatWaveformView(
                    map: map,
                    windowStart: windowStart,
                    plan: plan,
                    onScrub: { moveWindow(to: $0, commit: false) },
                    onScrubEnd: { moveWindow(to: $0, commit: true) }
                )
                .frame(height: isCompactHeight ? 56 : 96)
                .padding(.horizontal, 12)
                // Déplacer la fenêtre pendant un export reconstruirait le plan
                // sous les pieds de la session — verrouillé.
                .allowsHitTesting(!isExporting)

                if !isCompactHeight { densityBar }

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
        VStack(alignment: .leading, spacing: 3) {
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
            // L'INFORMATION DE PLANIFICATION : la durée de chaque clip au cran
            // choisi, et la longueur de rush nécessaire (à 0,5×, le double est
            // prélevé… non : la moitié est prélevée — durée finale × vitesse).
            // C'est ce qui permet de choisir la musique AVANT de dérusher.
            if let range = slotRangeMilliseconds {
                Text(range.min == range.max
                     ? "coupes : \(range.min) ms · rush requis par clip : ≥ \(range.sourceMin) ms"
                     : "coupes : \(range.min)–\(range.max) ms · rush requis : ≥ \(range.sourceMin)–\(range.sourceMax) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// Ce que contient le plan — et, s'il est VIDE, POURQUOI.
    ///
    /// Sans ce texte, une densité trop lente pour les clips disponibles
    /// affichait « 0/78 clips », un bouton Aperçu grisé et rien d'autre :
    /// l'utilisateur ne pouvait pas deviner qu'il suffisait de resserrer la
    /// densité. Le diagnostic est construit avec des chiffres déjà calculés.
    private var planSummary: String {
        guard let plan else { return "" }
        if !plan.placements.isEmpty {
            return "\(plan.placements.count) clips prêts"
        }
        if project.passages.isEmpty {
            return "Aucun clip validé dans ce projet — revenez au dérushage pour en valider."
        }
        guard let range = slotRangeMilliseconds else {
            return "Aucun créneau à cette position — déplacez la fenêtre vers le début du morceau."
        }
        if plan.skippedClipIDs.isEmpty {
            return "Aucun clip exploitable ici : leurs fichiers n'ont pas pu être ouverts."
        }
        return "\(plan.skippedClipIDs.count) clip(s) écarté(s) : à cette densité, chaque coupe demande "
            + "\(range.sourceMin) ms de rush, plus que ce que contiennent vos clips. "
            + "Choisissez un cran plus rapide (à droite) — ou revalidez des clips plus longs."
    }

    /// Écarts de coupe du plan courant, en millisecondes entières, avec la
    /// durée SOURCE à prélever par clip (durée finale × vitesse du projet).
    private var slotRangeMilliseconds: (min: Int, max: Int, sourceMin: Int, sourceMax: Int)? {
        guard let map = beatMap else { return nil }
        let slots = map.slots(from: windowStart, density: density)
        guard let range = BeatMap.slotDurationRange(slots) else { return nil }
        let speedRatio = Double(project.speedNumerator) / Double(max(project.speedDenominator, 1))
        return (Int((range.min * 1000).rounded()),
                Int((range.max * 1000).rounded()),
                Int((range.min * speedRatio * 1000).rounded(.up)),
                Int((range.max * speedRatio * 1000).rounded(.up)))
    }

    /// Erreurs de PARCOURS UTILISATEUR — chacune dit si c'est un cas d'usage
    /// (et quoi faire) ou un défaut de l'app (et qu'il faut le signaler).
    private enum MontageUserError: Error, LocalizedError {
        case noPulse

        var errorDescription: String? {
            switch self {
            case .noPulse:
                return "Aucune pulsation régulière détectée dans ce morceau. "
                    + "Cela arrive sur les titres sans percussions marquées (ambiance, piano seul) "
                    + "ou si le fichier est en réalité silencieux. "
                    + "Choisissez un titre avec un kick net — le montage se cale dessus."
            }
        }
    }

    /// L'export vit dans un SERVICE PARTAGÉ, pas dans cette vue : fermer
    /// l'écran ne l'arrête pas, et le rouvrir retrouve son état au lieu de
    /// repartir avec tous les verrous ouverts.
    private var isExporting: Bool {
        MontageExportController.shared.isExporting
    }

    private var overlayCount: Int { project.overlays.count }

    /// Rapport largeur/hauteur du rendu. Tant que rien n'a été composé, on
    /// prend celui du premier clip plutôt qu'une valeur arbitraire.
    private var previewVideoRatio: CGFloat {
        if let size = previewRenderSize, size.height > 0 {
            return size.width / size.height
        }
        if let backdrop = overlayBackdrop, backdrop.size.height > 0 {
            return backdrop.size.width / backdrop.size.height
        }
        return 9.0 / 16.0
    }

    /// Incrustations résolues en temps absolu, prêtes pour le rendu.
    /// Aperçu et export consomment la MÊME liste.
    ///
    /// MÉMORISÉES dans un état, pas recalculées dans le corps : les lire ici
    /// ferait dépendre TOUT l'écran de montage des propriétés de chaque
    /// calque, donc reconstruire la feuille d'incrustations à chaque réglage
    /// qu'on y fait — un candidat sérieux au défaut « le sélecteur revient en
    /// arrière tout seul ». La liste est refaite aux moments qui comptent :
    /// changement de plan, et fermeture de l'écran d'incrustations.
    @State private var resolvedOverlays: [ResolvedOverlay] = []

    private func refreshOverlays() {
        guard let plan else { resolvedOverlays = []; return }
        // AUCUNE ÉCRITURE DANS LE MODÈLE ICI, et c'est délibéré.
        //
        // Une version précédente recalait les rangs des portées dans les
        // bornes du plan courant puis enregistrait. C'était une PERTE DE
        // DONNÉES : le nombre de clips varie à chaque déplacement de la
        // fenêtre musicale (`BeatMap.slots` part du beat courant et va
        // jusqu'à la fin du morceau), et il tombe à zéro sur un cran de
        // densité trop lent pour les rushes. Une incrustation posée « du clip
        // 40 au clip 80 » se retrouvait réécrite en 5→5, ou en 0→0, sans
        // aucun moyen de revenir en arrière — alors qu'il suffit de ne rien
        // toucher pour qu'elle redevienne juste dès que la fenêtre revient.
        //
        // Les bornes sont appliquées LÀ OÙ ELLES SERVENT : `OverlayStore
        // .resolve` pour le rendu, et des liaisons bornées pour les
        // compteurs de l'inspecteur.
        resolvedOverlays = OverlayStore.resolve(project.overlays,
                                                placements: plan.placements,
                                                totalDuration: plan.totalDuration)
    }

    /// Extrait une image du montage : on juge le placement d'un logo sur du
    /// contenu réel, pas sur un rectangle noir.
    private func prepareOverlayShape(imageToo: Bool) {
        guard let plan, let first = plan.placements.first,
              let url = clipSources[first.clipID] else { return }
        // Vignette réutilisée UNIQUEMENT si elle vient du clip qui fixe la
        // taille de rendu du plan COURANT.
        let needsImage = imageToo
            && (overlayBackdrop == nil || overlayBackdropClipID != first.clipID)
        let needsRatio = overlayVideoRatio == nil
        guard needsImage || needsRatio else { return }
        let clipID = first.clipID
        // GÉNÉRATION CAPTURÉE, et revérifiée avant CHAQUE écriture. Cette
        // tâche dure de quelques centaines de millisecondes à plusieurs
        // secondes sur un rush 4K : sans ce garde, une extraction lancée avant
        // un changement de densité revenait ensuite écrire le rapport et la
        // vignette d'un clip qui n'était plus le premier, et tout ancrage posé
        // ensuite était calculé — puis enregistré — sur une forme fausse.
        let generation = planGeneration
        backdropTask?.cancel()
        backdropTask = Task {
            let asset = AVURLAsset(url: url)
            // RAPPORT D'ABORD, depuis les métadonnées : aucune image à
            // décoder, donc il aboutit là où l'extraction peut échouer.
            if needsRatio,
               let track = try? await asset.loadTracks(withMediaType: .video).first,
               let natural = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let oriented = natural.applying(transform)
                let width = abs(oriented.width), height = abs(oriented.height)
                guard !Task.isCancelled, generation == planGeneration else { return }
                if width > 0, height > 0 {
                    overlayVideoRatio = width / height
                    reanchorOverlays(videoRatio: Double(width / height))
                }
            }
            guard needsImage else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1080, height: 1080)
            let time = CMTimeAdd(first.sourceRange.start,
                                 CMTimeMultiplyByRatio(first.sourceRange.duration,
                                                       multiplier: 1, divisor: 2))
            if let image = try? await generator.image(at: time).image {
                guard !Task.isCancelled, generation == planGeneration else { return }
                overlayBackdrop = UIImage(cgImage: image)
                overlayBackdropClipID = clipID
            }
        }
    }

    /// Recolle les incrustations ANCRÉES sur la nouvelle forme du montage.
    ///
    /// Changer de cran de densité change la durée des créneaux, donc les clips
    /// écartés, donc le premier clip placé — et c'est lui qui fixe la taille de
    /// rendu. Un montage peut ainsi passer de 9:16 à 16:9 d'un cran à l'autre.
    /// Un ancrage est une PROMESSE de coin : il doit survivre à ça.
    ///
    /// Les calques posés librement (`anchorIndex < 0`) ne sont jamais touchés,
    /// et ceux déjà calculés pour ce rapport non plus — ce n'est pas un
    /// recalage aveugle.
    private func reanchorOverlays(videoRatio: Double) {
        guard videoRatio > 0 else { return }
        var changed = false
        for layer in project.overlays where layer.anchorIndex >= 0 {
            guard abs(layer.anchorVideoRatio - videoRatio) > 0.0001,
                  let center = OverlayLayer.anchoredCenter(
                    anchorIndex: layer.anchorIndex,
                    relativeSpan: OverlayGeometry.span(of: layer),
                    relativeHeight: OverlayGeometry.height(of: layer, videoRatio: videoRatio))
            else { continue }
            layer.centerX = center.x
            layer.centerY = center.y
            layer.anchorVideoRatio = videoRatio
            changed = true
        }
        if changed {
            try? modelContext.save()
            refreshOverlays()
        }
    }

    private var density: CutDensity {
        CutDensity(rawValue: project.montageDensityRaw) ?? .standard
    }

    private func setDensity(_ newDensity: CutDensity) {
        guard newDensity != density else { return }
        project.montageDensityRaw = newDensity.rawValue
        try? modelContext.save()
        // AUCUNE ALERTE. La barre de densité est faite pour être tapée en
        // rafale au pouce : cinq crans essayés donnaient cinq modales à
        // fermer, sur le canal des vraies erreurs en plus. Et il n'y a plus
        // rien à signaler — les portées d'incrustation ne sont plus réécrites
        // (voir refreshOverlays), seulement bornées à l'affichage et au rendu.
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildPlan() }
    }

    /// Barre basse — les trois actions, à portée de pouce, sans confirmation.
    /// TOUT est verrouillé pendant l'export : changer la musique supprimerait
    /// le fichier que la session d'export est en train de lire.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showLibrary = true
            } label: {
                Image(systemName: "music.note.list")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            .accessibilityLabel("Ma bibliothèque")
            .disabled(isExporting)

            Button {
                showFileImporter = true
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            .accessibilityLabel("Fichier local")
            .disabled(isExporting)

            Button {
                togglePreview()
            } label: {
                // La construction prend plusieurs secondes sans rien montrer :
                // l'utilisateur rappuyait, et deux compositions complètes se
                // construisaient en parallèle pour que l'une soit jetée.
                if isBuildingPreview {
                    ProgressView()
                } else {
                    Image(systemName: isPreviewing ? "pause.fill" : "play.fill")
                }
            }
            .buttonStyle(GlassIconButtonStyle(diameter: 52))
            .accessibilityLabel(isBuildingPreview
                                ? "Préparation de l'aperçu"
                                : (isPreviewing ? "Pause" : "Aperçu"))
            .disabled(isExporting || isBuildingPreview
                      || (plan?.placements.isEmpty ?? true))

            Spacer()

            if isExporting {
                // VUE ISOLÉE : la progression change plusieurs fois par
                // seconde. La lire ici reconstruirait tout l'écran de montage
                // à chaque image encodée.
                MontageExportProgressView()
                // SORTIE DE SECOURS. Un export long sans moyen de l'arrêter
                // enferme l'utilisateur : plus de changement de musique, plus
                // de réglage, et rien d'autre à faire qu'attendre.
                Button {
                    MontageExportController.shared.cancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 40))
                .accessibilityLabel("Annuler l'export")
            } else {
                Button {
                    prepareOverlayShape(imageToo: true)
                    showOverlays = true
                } label: {
                    Image(systemName: overlayCount > 0
                          ? "textformat.size.larger" : "textformat")
                }
                .buttonStyle(GlassIconButtonStyle(
                    tint: overlayCount > 0 ? Theme.accent : .secondary, diameter: 46))
                .accessibilityLabel(overlayCount > 0
                                    ? "Incrustations (\(overlayCount))"
                                    : "Ajouter une incrustation")
                .disabled(plan?.placements.isEmpty ?? true)

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

    /// SÉLECTEUR DE DENSITÉ : cinq crans réguliers, du plus posé au plus
    /// nerveux. Chaque cran affiche LA DURÉE RÉELLE de clip qu'il produit à ce
    /// BPM — pas un jargon de beats : des millisecondes.
    private var densityBar: some View {
        HStack(spacing: 6) {
            ForEach(CutDensity.allCases, id: \.rawValue) { candidate in
                Button {
                    setDensity(candidate)
                } label: {
                    VStack(spacing: 1) {
                        Text(densityLabel(candidate))
                            .font(.caption.monospacedDigit().weight(
                                candidate == density ? .bold : .regular))
                        Text(candidate == density ? "ms" : " ")
                            .font(.system(size: 8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .glassEffect(candidate == density
                                 ? .regular.tint(Theme.accent.opacity(0.5)).interactive()
                                 : .regular.interactive(),
                                 in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Coupe toutes les \(densityLabel(candidate)) millisecondes")
            }
        }
        .padding(.horizontal, 16)
        .disabled(isExporting)
    }

    private func densityLabel(_ candidate: CutDensity) -> String {
        guard let map = beatMap else { return "—" }
        return String(Int((candidate.slotDuration(bpm: map.bpm) * 1000).rounded()))
    }

    // MARK: - Audition (placement à l'oreille)

    /// Joue la musique À MESURE que la fenêtre glisse : seek continu pendant
    /// le geste, puis la lecture continue ~10 s après le relâchement — on
    /// entend exactement où le montage démarrera.
    private func audition(at time: Double, released: Bool) {
        guard let filename = project.musicFilename else { return }
        stopPreview()
        auditionStopTask?.cancel()

        if auditionPlayer == nil {
            auditionPlayer = AVPlayer(url: MusicStore.url(forMusicFilename: filename))
        }
        guard let auditionPlayer else { return }

        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        if released {
            auditionPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            auditionPlayer.play()
            auditionStopTask = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                auditionPlayer.pause()
            }
        } else {
            // Pendant le geste : seeks limités (8/s), lecture en continu pour
            // entendre défiler la musique sous le doigt.
            if auditionPlayer.rate == 0 { auditionPlayer.play() }
            if Date().timeIntervalSince(lastAuditionSeek) > 0.12 {
                lastAuditionSeek = Date()
                auditionPlayer.seek(to: target,
                                    toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                                    toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
            }
        }
    }

    private func stopAudition() {
        auditionStopTask?.cancel()
        auditionPlayer?.pause()
    }

    // MARK: - Musique

    /// Morceau choisi dans la BIBLIOTHÈQUE : son fichier est déjà là et son
    /// analyse est en cache. Le projet ne fait que le désigner — aucune copie,
    /// aucune attente. C'est tout l'intérêt de la bibliothèque.
    private func useTrack(_ track: MusicTrack) {
        guard !isExporting else {
            errorMessage = "Export du montage en cours — changez de musique une fois l'export terminé."
            return
        }
        // Le fichier appartient à la BIBLIOTHÈQUE, pas au projet : on ne
        // supprime PAS l'ancien morceau, d'autres projets s'en servent.
        project.musicFilename = track.filename
        project.musicTitle = track.title
        project.montageStartCentiseconds = nil
        try? modelContext.save()
        startAnalysis(filename: track.filename)
    }

    /// Import direct d'un fichier depuis Fichiers : il rejoint la
    /// bibliothèque (donc réutilisable ensuite) et devient la musique du
    /// projet.
    private func importMusic(from url: URL) {
        // L'export lit le fichier musical : le remplacer maintenant le
        // supprimerait sous la session.
        guard !isExporting else {
            errorMessage = "Export du montage en cours — changez de musique une fois l'export terminé."
            return
        }
        stage = .analyzing
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                // UNE seule analyse : le contrôleur importe ET analyse, puis
                // rend le morceau. Passer par la file l'aurait fait décoder
                // une deuxième fois en parallèle, ici et là-bas.
                let track = try await MusicLibraryController.shared
                    .importAndAnalyze(url: url, context: modelContext)
                guard !Task.isCancelled else { return }
                guard track.isAnalyzed else {
                    stage = .needsMusic
                    errorMessage = track.analysisError
                        ?? "Ce morceau n'a pas pu être analysé. Il reste dans la bibliothèque : vous pouvez le relancer depuis la liste."
                    return
                }
                project.musicFilename = track.filename
                project.musicTitle = track.title
                project.montageStartCentiseconds = nil
                try? modelContext.save()
                startAnalysis(filename: track.filename)
            } catch is CancellationError {
                // Écran quitté : rien à signaler.
            } catch {
                stage = .needsMusic
                errorMessage = "Import impossible : \(error.localizedDescription)"
            }
        }
    }

    private func startAnalysis(filename: String) {
        stopAudition()
        auditionPlayer = nil // nouvelle musique = nouveau lecteur
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
                    // Analyse à la CADENCE NATIVE du fichier — aucun
                    // rééchantillonnage à rater.
                    let analyzed = try await Task.detached(priority: .userInitiated) {
                        let decoded = try await MusicDecoder.monoSamples(of: url)
                        return BeatAnalyzer.analyze(
                            samples: decoded.samples, sampleRate: decoded.sampleRate
                        )
                    }.value
                    guard let analyzed else {
                        throw MontageUserError.noPulse
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
                // DÉTACHER la musique du projet : la garder faisait rejouer
                // le même échec à chaque ouverture du montage, sans issue.
                // Le fichier reste dans la bibliothèque, relançable de là.
                project.musicFilename = nil
                project.musicTitle = nil
                try? modelContext.save()
                stage = .needsMusic
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Fenêtre et plan

    private func moveWindow(to time: Double, commit: Bool) {
        guard let map = beatMap else { return }
        // AUDITION : la musique se joue sous le doigt pendant le glissement,
        // et continue ~10 s au relâchement (sur le beat recalé).
        audition(at: commit
                 ? (map.beatTimes.min(by: { abs($0 - time) < abs($1 - time) }) ?? time)
                 : time,
                 released: commit)
        // Recalage AU BEAT le plus proche : la fenêtre commence toujours sur
        // un beat, sinon tout le montage serait décalé de la musique.
        let snapped = map.beatTimes.min(by: {
            abs($0 - time) < abs($1 - time)
        }) ?? 0
        windowStart = snapped
        guard commit else { return }
        project.montageStartCentiseconds = Int((snapped * 100).rounded())
        try? modelContext.save()
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildPlan() }
    }

    /// Reconstruit le plan de placement : passages dans l'ordre de validation,
    /// chacun démarrant à SON point d'entrée, durée dictée par son créneau.
    private func rebuildPlan() async {
        guard let map = beatMap else { return }
        // TRIPLET CAPTURÉ À L'ENTRÉE. La carte de rythme l'était déjà, mais la
        // fenêtre et la densité étaient relues à la FIN, après plusieurs
        // secondes de chargement de pistes : changer de musique entre-temps
        // produisait un plan bâtard — grille rythmique d'un morceau, fenêtre
        // d'un autre — que l'export acceptait sans broncher.
        let start = windowStart
        let cutDensity = density
        stopPreview() // annule aussi la construction en cours
        // Le plan change de génération : un aperçu construit sur l'ANCIEN se
        // jettera au lieu de se réinstaller derrière ce `player = nil`.
        planGeneration &+= 1
        let generation = planGeneration
        // La composition affichée ne correspond plus au plan : la garder
        // rejouerait l'ANCIEN montage — pire qu'un écran de veille.
        releaseTimeObserver() // avant de lâcher le lecteur, jamais après
        player = nil
        playerGeneration = nil

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
            // Borne = la PISTE VIDÉO, pas le conteneur : dans une copie source,
            // la piste audio peut durer plus que la vidéo, et la durée du
            // conteneur promettrait des images qui n'existent pas.
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let trackRange = try? await track.load(.timeRange) else { continue }

            candidates.append(MontageClipCandidate(
                id: index,
                startInFile: CMTimeMaximum(startInFile, trackRange.start),
                fileDuration: trackRange.end,
                speed: RationalSpeed(numerator: passage.speedNumerator,
                                     denominator: passage.speedDenominator)
            ))
            sources[index] = url
        }

        // Deux reconstructions peuvent être en vol : celle qui n'est plus la
        // dernière se jette au lieu d'écraser le bon plan.
        guard !Task.isCancelled, generation == planGeneration else { return }
        let slots = map.slots(from: start, density: cutDensity)
        plan = MontagePlanner.plan(slots: slots, clips: candidates, windowStart: start)
        clipSources = sources
        // Le PREMIER placement peut changer de clip, donc d'orientation : la
        // vignette de pose et la taille de rendu mémorisée décriraient un
        // montage qui n'existe plus.
        backdropTask?.cancel()
        backdropTask = nil
        overlayBackdrop = nil
        overlayBackdropClipID = nil
        overlayVideoRatio = nil
        previewRenderSize = nil
        refreshOverlays()
        // La FORME du montage est réétablie tout de suite, sans attendre que
        // l'écran d'incrustations soit rouvert : c'est elle qui permet de
        // recoller les incrustations ancrées quand le montage change
        // d'orientation. Sans cela, un logo ancré en bas à droite restait à sa
        // place de l'ancien cadrage et partait à l'export ainsi.
        prepareOverlayShape(imageToo: false)
    }

    // MARK: - Aperçu

    private func togglePreview() {
        stopAudition()
        if isPreviewing {
            stopPreview()
            return
        }
        // Verrou posé AVANT la tâche : voir `isBuildingPreview`.
        guard !isBuildingPreview else { return }
        // REPRISE. Le lecteur en place joue déjà la composition du plan
        // courant, et les incrustations de l'aperçu sont dessinées en SwiftUI
        // par-dessus : un réglage d'incrustation ne change rien à cette
        // composition. Rien à reconstruire, et le point de lecture est gardé.
        // Sans cette branche, « pause » n'était pas une pause : reprendre
        // rebâtissait tout le montage et repartait de zéro — plusieurs
        // secondes d'attente pour revoir l'effet du réglage qu'on vient de
        // faire, c'est-à-dire le geste le plus fréquent de cet écran.
        if let player, playerGeneration == planGeneration {
            if let item = player.currentItem, item.duration.isNumeric,
               CMTimeCompare(player.currentTime(), item.duration) >= 0 {
                player.seek(to: .zero) // arrivé au bout : repartir, pas rester figé
            }
            player.play()
            isPreviewing = true
            return
        }
        guard let plan, let filename = project.musicFilename else { return }
        let generation = planGeneration
        let sources = clipSources
        let token = UUID()
        previewToken = token
        isBuildingPreview = true
        previewTask = Task {
            // Ne s'éteint QUE si c'est encore la construction courante.
            defer { if previewToken == token { isBuildingPreview = false } }
            do {
                let montage = try await MontageComposer.build(
                    plan: plan,
                    sources: sources,
                    musicURL: MusicStore.url(forMusicFilename: filename),
                    overlays: resolvedOverlays // dessinées par-dessus, pas incrustées ici
                )
                // La construction dure plusieurs secondes : l'écran a pu être
                // fermé, ou le plan reconstruit, entre-temps. Installer ce
                // lecteur maintenant ferait jouer un montage que plus rien ne
                // décrit à l'écran — et que l'export ne produirait pas.
                guard !Task.isCancelled, generation == planGeneration else { return }
                let item = AVPlayerItem(asset: montage.composition)
                item.videoComposition = montage.videoComposition
                // L'ANCIEN observateur se retire de SON lecteur, jamais du
                // nouveau : `removeTimeObserver` avec un jeton d'une autre
                // instance lève une exception non rattrapée et ferme l'app.
                // Le chemin est banal — lire, ouvrir les incrustations
                // (qui coupe la lecture), revenir, relire.
                releaseTimeObserver()
                let newPlayer = AVPlayer(playerItem: item)
                previewRenderSize = montage.renderSize
                player = newPlayer
                playerGeneration = generation
                // Suivi du temps : les incrustations n'apparaissent que sur
                // leur plage. 20 relevés par seconde suffisent — l'œil ne
                // distingue pas mieux, et c'est autant de reconstructions
                // de vue en moins.
                timeObserver = newPlayer.addPeriodicTimeObserver(
                    forInterval: CMTime(value: 1, timescale: 20), queue: .main
                ) { time in
                    previewTime = time.seconds
                }
                newPlayer.play()
                isPreviewing = true
                // Fin de lecture : l'état du bouton suit, sans intervention.
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
                endObserver = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification,
                    object: item, queue: .main
                ) { _ in
                    Task { @MainActor in isPreviewing = false }
                }
            } catch {
                guard !Task.isCancelled, generation == planGeneration else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func stopPreview() {
        // La construction EN VOL tombe aussi : sinon elle rallumerait le son
        // après coup — feuille ouverte, écran fermé, export lancé.
        //
        // Le jeton change AVANT l'annulation : `MontageComposer.build` va de
        // toute façon à son terme sur les tronçons déjà engagés, et sans cette
        // désolidarisation le bouton restait éteint avec son indicateur qui
        // tournait dans le vide, plusieurs secondes, pour une préparation
        // déjà jetée.
        previewToken = UUID()
        previewTask?.cancel()
        previewTask = nil
        isBuildingPreview = false
        player?.pause()
        isPreviewing = false
    }

    /// Coupe TOUT ce qui produit du son sur cet écran : l'aperçu du montage
    /// et l'écoute de repérage.
    private func silence() {
        stopPreview()
        stopAudition()
    }

    /// Détache l'observateur de temps DE SON lecteur. Passer par ici partout
    /// évite l'exception « observateur ajouté par une autre instance ».
    private func releaseTimeObserver() {
        guard let timeObserver else { return }
        player?.removeTimeObserver(timeObserver)
        self.timeObserver = nil
    }

    // MARK: - Export

    private func exportMontage() {
        guard let plan, let filename = project.musicFilename else { return }
        stopPreview()
        stopAudition()
        MontageExportController.shared.start(
            plan: plan,
            sources: clipSources,
            musicURL: MusicStore.url(forMusicFilename: filename),
            overlays: resolvedOverlays,
            outputFilename: "Montage — \(project.name).mov",
            albumName: project.albumPerProject ? project.name : nil,
            projectName: project.name
        )
    }

    /// Annonce le résultat d'un export — y compris terminé pendant que
    /// l'écran était fermé (le service le conserve jusqu'à consommation).
    private func announceExportOutcome() {
        let controller = MontageExportController.shared
        // Le résultat porte le nom du projet qui l'a lancé : sans ce contrôle,
        // un montage exporté depuis un AUTRE projet aurait été annoncé ici.
        guard let outcome = controller.lastOutcome,
              controller.lastOutcomeProject == project.name else { return }
        controller.consumeOutcome()
        switch outcome {
        case .saved:
            let token = UUID()
            toastToken = token
            withAnimation { exportToast = "Montage enregistré dans Photos 🎉" }
            Task {
                try? await Task.sleep(for: .seconds(3))
                // Un export suivant a pu reposter un toast : seul le SIEN
                // a le droit de l'effacer.
                if toastToken == token {
                    withAnimation { exportToast = nil }
                }
            }
        case .failed(let message):
            errorMessage = message
        case .cancelled:
            break // abandon volontaire : rien à annoncer
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

    /// ZOOM DE PRÉCISION : pendant le glissement, la vue montre une loupe de
    /// ± 5 s autour du point saisi au lieu du morceau entier — au doigt, tout
    /// le morceau sur 360 pt rend 1 px ≈ 0,5 s, poser le départ au beat près
    /// y est impossible. La loupe est ANCRÉE au début du geste : la
    /// correspondance écran → temps ne bouge pas sous le doigt (pas de boucle
    /// de rétroaction), elle se ré-ancre seulement si le doigt sort du cadre.
    @State private var zoomWindow: (start: Double, duration: Double)?
    /// Dernier ré-ancrage de la loupe : borné dans le temps, sinon le
    /// micro-tremblement d'un doigt posé au bord déclenchait un ré-ancrage
    /// par événement tactile (~60/s) — défilement incontrôlable.
    @State private var lastReanchor = Date.distantPast

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
            // Fenêtre visible : tout le morceau au repos, la loupe en geste.
            let visibleStart = zoomWindow?.start ?? 0
            let visibleDuration = zoomWindow?.duration ?? max(map.duration, 0.001)
            let scale = width / CGFloat(visibleDuration)
            let montageEnd = windowStart + (plan?.totalDuration.seconds ?? 0)

            Canvas { context, size in
                // 1. Forme d'onde (barres, max par seau) — seaux recadrés sur
                //    la fenêtre visible.
                let buckets = map.waveform
                guard !buckets.isEmpty, map.duration > 0 else { return }
                let bucketDuration = map.duration / Double(buckets.count)
                let firstBucket = max(0, Int(visibleStart / bucketDuration))
                let lastBucket = min(buckets.count - 1,
                                     Int((visibleStart + visibleDuration) / bucketDuration) + 1)
                guard firstBucket <= lastBucket else { return }
                for index in firstBucket...lastBucket {
                    let bucketTime = Double(index) * bucketDuration
                    let barX = CGFloat(bucketTime - visibleStart) * scale
                    let barWidth = max(0.5, CGFloat(bucketDuration) * scale - 0.5)
                    let barHeight = max(1, CGFloat(buckets[index]) * size.height * 0.55)
                    let inWindow = bucketTime >= windowStart && bucketTime <= montageEnd
                    context.fill(
                        Path(CGRect(x: barX, y: (size.height - barHeight) / 2,
                                    width: barWidth, height: barHeight)),
                        with: .color(.white.opacity(inWindow ? 0.85 : 0.25))
                    )
                }
                // 2. Beats : traits colorés par section. En loupe, TOUS les
                //    beats visibles — c'est la règle graduée sur laquelle on
                //    pose le départ.
                for (index, beat) in map.beatTimes.enumerated()
                where beat >= visibleStart && beat <= visibleStart + visibleDuration {
                    guard index < map.sections.count else { break }
                    let zoomed = zoomWindow != nil
                    guard zoomed || (beat >= windowStart && beat <= montageEnd) else { continue }
                    let beatX = CGFloat(beat - visibleStart) * scale
                    context.fill(
                        Path(CGRect(x: beatX, y: size.height * (zoomed ? 0.66 : 0.82),
                                    width: 2, height: size.height * (zoomed ? 0.30 : 0.14))),
                        with: .color(color(for: map.sections[index]))
                    )
                }
                // 3. Bord de fenêtre : la poignée visuelle du glissement.
                let startX = CGFloat(windowStart - visibleStart) * scale
                if startX >= -2, startX <= size.width + 2 {
                    context.fill(
                        Path(CGRect(x: startX - 1.5, y: 0, width: 3, height: size.height)),
                        with: .color(Theme.accent)
                    )
                }
                // 4. En loupe : graduation (un repère par seconde) — on sait
                //    OÙ on est dans le morceau.
                if zoomWindow != nil {
                    let firstSecond = Int(visibleStart.rounded(.up))
                    let lastSecond = Int((visibleStart + visibleDuration).rounded(.down))
                    if firstSecond <= lastSecond {
                        for second in firstSecond...lastSecond {
                            let tickX = CGFloat(Double(second) - visibleStart) * scale
                            context.fill(
                                Path(CGRect(x: tickX, y: 0, width: 1, height: 6)),
                                with: .color(.white.opacity(0.4))
                            )
                            context.draw(
                                Text(String(format: "%d:%02d", second / 60, second % 60))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.gray),
                                at: CGPoint(x: tickX + 2, y: 8), anchor: .leading
                            )
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if zoomWindow == nil {
                            // Ancrage de la loupe au DÉBUT du geste, centrée
                            // sur le point saisi dans la vue plein-morceau.
                            let grabbed = Double(value.startLocation.x / max(scale, 0.001))
                            let zoomDuration = min(10.0, max(map.duration, 0.001))
                            let zoomStart = min(max(0, grabbed - zoomDuration / 2),
                                                max(0, map.duration - zoomDuration))
                            zoomWindow = (zoomStart, zoomDuration)
                            return // premier événement : on installe la loupe
                        }
                        guard let window = zoomWindow else { return }
                        var t = window.start + Double(value.location.x / max(scale, 0.001))
                        // Doigt au bord : la loupe se ré-ancre pour suivre —
                        // au plus tous les 400 ms. Sans cette borne, chaque
                        // événement tactile re-décalait de 5 s : un morceau
                        // entier traversé en une seconde de tremblement.
                        if Date().timeIntervalSince(lastReanchor) > 0.4 {
                            if t < window.start + window.duration * 0.05 {
                                lastReanchor = Date()
                                zoomWindow = (max(0, window.start - window.duration * 0.5),
                                              window.duration)
                            } else if t > window.start + window.duration * 0.95 {
                                lastReanchor = Date()
                                zoomWindow = (min(max(0, map.duration - window.duration),
                                                  window.start + window.duration * 0.5),
                                              window.duration)
                            }
                        }
                        t = min(max(0, t), map.duration)
                        onScrub(t)
                    }
                    .onEnded { value in
                        let base = zoomWindow?.start ?? 0
                        let t = min(max(0, base + Double(value.location.x / max(scale, 0.001))),
                                    map.duration)
                        zoomWindow = nil
                        onScrubEnd(t)
                    }
            )
            .frame(width: width, height: height)
        }
        .accessibilityLabel("Fenêtre de montage dans la musique")
        .accessibilityHint("Glissez pour déplacer le départ — la vue zoome et la musique se joue sous le doigt")
    }
}
