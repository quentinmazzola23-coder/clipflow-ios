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
    /// Cadrage de chaque clip, gelé en même temps que le plan.
    ///
    /// Relire les Passage plus tard rouvrirait la porte au décalage d'index
    /// que `passageIDs` ferme déjà à l'export : `clipID` est une POSITION dans
    /// `orderedPassages`, et supprimer un clip décale tous les suivants.
    @State private var clipCrops: [Int: CGPoint] = [:]
    @State private var showClips = false
    /// Vrai tant qu'une reconstruction de plan est en vol.
    ///
    /// Le plan, les sources, les cadrages et les requêtes de lissage sont
    /// publiés ENSEMBLE, à la fin. Exporter entre-temps partait sur l'ancien
    /// plan : le montage ignorait le réordonnancement, et les fichiers lissés
    /// s'écrivaient sur les identités du NOUVEL ordre — un clip recevait les
    /// images d'un autre, définitivement.
    ///
    /// `rebuildTask` ne pouvait pas servir de témoin : il n'est jamais remis à
    /// nil, le bouton serait resté grisé à vie.
    @State private var isRebuilding = false
    /// Identités des passages TELLES QUE LE PLAN COURANT les numérote.
    /// `clipID` est l'index dans CE tableau, jamais dans une liste relue plus tard.
    @State private var planPassageIDs: [PersistentIdentifier] = []
    /// Clips qui gagneraient à être lissés à 60 i/s, par identifiant de clip.
    ///
    /// Rempli à la construction du plan parce que la piste vidéo y est DÉJÀ
    /// chargée : la refaire à l'export coûterait un aller-retour disque par
    /// clip juste pour relire une durée.
    @State private var smoothingRequests: [Int: MontageSmoothingRequest] = [:]
    @State private var windowStart: Double = 0
    @State private var showFileImporter = false
    @State private var showLibrary = false
    @State private var showOverlays = false
    /// Les chiffres de planification sont-ils dépliés ?
    ///
    /// L'en-tête portait cinq informations en permanence (BPM, clips, durée,
    /// écarts de coupe, rush requis) au-dessus d'un aperçu, d'une forme d'onde
    /// et de dix boutons. À force, plus rien ne ressortait. Les deux chiffres
    /// qu'on consulte pour CHOISIR une musique restent accessibles d'un tap
    /// sur le BPM, et se referment ensuite.
    @State private var showPlanningDetail = false
    /// Motif de fermeture forcée de l'écran d'incrustations, remis à
    /// l'utilisateur UNE FOIS LA FEUILLE REFERMÉE.
    ///
    /// Poser l'alerte au moment où l'on ferme la feuille la fait avaler :
    /// UIKit refuse de présenter par-dessus une vue en cours de disparition.
    /// Et comme rien ne remettait alors `errorMessage` à nil — le seul chemin
    /// de remise à zéro est le bouton OK d'une alerte qui ne s'est jamais
    /// affichée — la liaison restait bloquée à « vrai » et TOUTES les alertes
    /// suivantes de l'écran devenaient muettes : échec d'export, échec
    /// d'import de musique, bilan de rendu. Un défaut silencieux qui survivait
    /// à toute la session.
    @State private var pendingOverlayMessage: String?

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
        .onChange(of: showClips) { _, presented in if presented { silence() } }
        .onChange(of: showOverlays) { _, presented in if presented { silence() } }
        .onChange(of: showLibrary) { _, presented in if presented { silence() } }
        .onChange(of: showFileImporter) { _, presented in if presented { silence() } }
        // INCRUSTATIONS : étape POSTÉRIEURE au montage — on ne décore pas une
        // vidéo qu'on n'a pas encore construite.
        .sheet(isPresented: $showOverlays, onDismiss: {
            refreshOverlays()
            // La feuille est REFERMÉE : l'alerte peut enfin se présenter.
            if let pendingOverlayMessage {
                errorMessage = pendingOverlayMessage
                self.pendingOverlayMessage = nil
            }
        }) {
            NavigationStack {
                if let plan {
                    OverlayEditorView(project: project, plan: plan,
                                      backdrop: overlayBackdrop,
                                      videoRatio: overlayVideoRatio)
                }
            }
        }
        .sheet(isPresented: $showClips) {
            MontageClipsSheet(project: project) {
                // L'ordre ou le contenu a changé : le plan décrit un montage
                // qui n'existe plus.
                rebuildTask?.cancel()
                rebuildTask = Task { await rebuildPlan() }
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
                Text("Le rythme de la musique découpera vos \(project.visiblePassages.count) clips automatiquement.")
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
                        // NUMÉRO DU PLAN EN COURS, discret mais toujours là.
                        //
                        // Sans lui, repérer un plan raté ne menait à rien : on
                        // le voyait passer sans pouvoir le nommer. C'est le
                        // même numéro que celui de la liste des clips — c'est
                        // toute son utilité.
                        if let number = currentClipNumber {
                            VStack {
                                HStack {
                                    Spacer()
                                    Text("\(number)")
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.black.opacity(0.45), in: Capsule())
                                        .padding(8)
                                }
                                Spacer()
                            }
                            .allowsHitTesting(false)
                        }
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
            Button {
                withAnimation(.snappy(duration: 0.2)) { showPlanningDetail.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Label(String(format: "%.0f BPM", map.bpm), systemImage: "metronome")
                    if let plan {
                        Label("\(plan.placements.count)/\(project.visiblePassages.count) clips",
                              systemImage: "film.stack")
                        Label(formatDuration(plan.totalDuration.seconds), systemImage: "timer")
                    }
                    // Chevron DISCRET : il signale que la ligne se déplie sans
                    // ajouter un bouton de plus à un écran déjà chargé.
                    Image(systemName: showPlanningDetail ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .font(.footnote.monospacedDigit())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Le bouton avale les libellés de ses enfants pour VoiceOver :
            // sans les redire ici, le BPM, le nombre de clips et la durée
            // devenaient inaudibles — l'en-tête ne se lisait plus du tout.
            .accessibilityElement(children: .combine)
            .accessibilityHint(showPlanningDetail
                               ? "Masquer les écarts de coupe"
                               : "Afficher les écarts de coupe")
            // L'INFORMATION DE PLANIFICATION : la durée de chaque clip au cran
            // choisi, et la longueur de rush nécessaire (à 0,5×, le double est
            // prélevé… non : la moitié est prélevée — durée finale × vitesse).
            // C'est ce qui permet de choisir la musique AVANT de dérusher.
            if showPlanningDetail, let range = slotRangeMilliseconds {
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
        if project.visiblePassages.isEmpty {
            return "Aucun clip validé dans ce projet — revenez au dérushage pour en valider."
        }
        guard let range = slotRangeMilliseconds else {
            return "Aucun créneau à cette position — déplacez la fenêtre vers le début du morceau."
        }
        if plan.skippedClipIDs.isEmpty {
            // LE REJET D'ABORD : un clip rejeté n'entre jamais dans les
            // candidats, donc ni dans les placements ni dans les écartés. Sans
            // ce test, l'écran accusait les fichiers d'un projet dont tous les
            // clips étaient simplement mis de côté — et rien n'indiquait où
            // les reprendre.
            let visible = project.orderedPassages
            if !visible.isEmpty, visible.allSatisfy({ $0.status == .rejete }) {
                return "Tous vos clips sont rejetés : ouvrez la liste des clips "
                    + "et balayez vers la droite pour en reprendre."
            }
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
              let url = clipSources[first.clipID] else {
            // AUCUN CLIP À DÉCORER. Sortir en silence laissait la feuille
            // ouverte sur « Préparation de l'aperçu… » pour toujours : rien ne
            // rappelle cette fonction une fois la feuille présentée, et les
            // deux boutons d'ajout restaient grisés sans explication. Le cas
            // s'atteint en tapant un cran de densité trop lent puis, sans
            // attendre, le bouton d'incrustations — le plan encore affiché
            // n'est pas vide, donc rien ne bloque l'ouverture.
            if showOverlays {
                pendingOverlayMessage = "Ce cran de densité ne place aucun clip : "
                    + "il n'y a rien à décorer. Choisissez un cran plus rapide, "
                    + "puis rouvrez les incrustations."
                showOverlays = false
            }
            return
        }
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
                    // LE RAPPORT QUI COMPTE EST CELUI DU FICHIER EXPORTÉ, pas
                    // celui du rush.
                    //
                    // Les incrustations sont posées en fractions du CADRE DE
                    // RENDU. Les ancrer sur la forme de la source donnait, dès
                    // que le format de sortie en différait — rushes verticaux
                    // exportés en 16:9, par exemple — une hauteur calculée à
                    // partir d'un rapport trois fois trop petit : un logo ancré
                    // « bas centre » débordait du cadre à l'export alors que
                    // l'éditeur le montrait entier.
                    let exported = project.outputFormat.aspect(
                        sourceOriented: CGSize(width: width, height: height))
                    overlayVideoRatio = CGFloat(exported)
                    reanchorOverlays(videoRatio: exported)
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
            // Ni rapport ni vignette : le fichier source a disparu entre la
            // construction du plan et l'extraction, et les deux échecs sont
            // avalés par leurs `try?`. Sans ce filet, la feuille resterait
            // ouverte sur un écran de préparation qui n'aboutira jamais.
            guard !Task.isCancelled, generation == planGeneration else { return }
            if overlayVideoRatio == nil, overlayBackdrop == nil, showOverlays {
                pendingOverlayMessage = "Le premier clip du montage n'a pas pu être lu : "
                    + "son fichier a peut-être été déplacé ou supprimé. "
                    + "Reconstruisez le montage avant d'ajouter une incrustation."
                showOverlays = false
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
            // Rapport d'image JAMAIS RELEVÉ : on ne touche à rien. La hauteur
            // serait inventée, et le centre enregistré par-dessus une valeur
            // juste. L'éditeur relèvera le rapport à la première lecture de
            // l'image et recalera lui-même.
            if layer.kind == .image, layer.imageAspect <= 0 { continue }
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
            // SOURCE & HABILLAGE réunis sous un seul bouton. La barre
            // portait cinq entrées de front, dont trois qu'on ne touche
            // qu'une fois par montage — choisir la musique, aller la chercher
            // dans un fichier, poser un logo. Les regrouper rend visible ce
            // qu'on fait vraiment en boucle : écouter, puis exporter.
            Menu {
                Button {
                    showLibrary = true
                } label: {
                    Label("Choisir une musique", systemImage: "music.note.list")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Importer un fichier audio", systemImage: "folder")
                }
                // MONTAGES ENREGISTRÉS : une version 16:9, une 9:16, chacune
                // avec sa musique, sa fenêtre et sa densité.
                Section("Montages de ce projet") {
                    Button {
                        let name = MontageVariantStore.suggestedName(
                            for: project, existing: project.montageVariants)
                        MontageVariantStore.capture(from: project, name: name,
                                                    in: modelContext)
                    } label: {
                        Label("Enregistrer ce montage", systemImage: "square.and.arrow.down")
                    }
                    .disabled(project.musicFilename == nil)
                    ForEach(project.orderedVariants) { variant in
                        Button {
                            applyVariant(variant)
                        } label: {
                            Label("\(variant.name) — \(variant.summary)",
                                  systemImage: "rectangle.stack")
                        }
                    }
                    if !project.montageVariants.isEmpty {
                        Menu {
                            ForEach(project.orderedVariants) { variant in
                                Button(role: .destructive) {
                                    MontageVariantStore.delete(variant, in: modelContext)
                                } label: {
                                    Label(variant.name, systemImage: "trash")
                                }
                            }
                        } label: {
                            Label("Supprimer un montage enregistré", systemImage: "trash")
                        }
                    }
                }

                Button {
                    prepareOverlayShape(imageToo: true)
                    showOverlays = true
                } label: {
                    Label(overlayCount > 0
                          ? "Incrustations (\(overlayCount))"
                          : "Ajouter un logo ou un texte",
                          systemImage: "textformat")
                }
                .disabled(plan?.placements.isEmpty ?? true)
            } label: {
                // Note de musique : c'est le contenu principal du menu, et
                // l'écran s'ouvre en proposant la bibliothèque — l'icône doit
                // rappeler par où on revient changer de morceau.
                Image(systemName: "music.note.list")
                    .font(.title3)
                    .foregroundStyle(overlayCount > 0 ? Theme.accent : .secondary)
                    .frame(width: 46, height: 46)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Musique et habillage")
            .disabled(isExporting)
            // Un Menu désactivé ne se grise pas tout seul : le bouton paraissait
            // actif et ne répondait pas, ce qui se lit comme une panne.
            .opacity(isExporting ? 0.35 : 1)

            // LES CLIPS DU MONTAGE : leur ordre, leur numéro, leur retrait.
            //
            // L'écran montrait le résultat sans jamais donner accès à la
            // matière : on voyait bien qu'un plan tombait mal, sans pouvoir
            // dire lequel ni le retirer sans ressortir vers le dérushage.
            Button {
                showClips = true
            } label: {
                Image(systemName: "square.grid.3x3")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            .accessibilityLabel("Clips du montage (\(project.orderedPassages.count))")
            .disabled(isExporting || project.orderedPassages.isEmpty)

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
            .disabled(isExporting || isBuildingPreview || isRebuilding
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
                    exportMontage()
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                // GRISÉ PENDANT LA RECONSTRUCTION : le plan affiché n'est pas
                // encore celui qui partirait.
                .disabled(isRebuilding || (plan?.placements.isEmpty ?? true))
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
    /// Rappelle un montage enregistré.
    ///
    /// La musique n'est réanalysée QUE si elle change : relancer l'analyse pour
    /// un simple changement de format coûterait plusieurs secondes et jetterait
    /// la fenêtre de départ qu'on vient justement de rappeler.
    private func applyVariant(_ variant: MontageVariant) {
        guard !isExporting else {
            errorMessage = "Export du montage en cours — rappelez un montage une fois l'export terminé."
            return
        }
        silence()
        switch MontageVariantStore.apply(variant, to: project, in: modelContext) {
        case .musicMissing:
            errorMessage = "La musique de ce montage n'est plus sur l'appareil — "
                + "vos réglages actuels sont conservés. Réimportez-la, "
                + "ou enregistrez ce montage à nouveau avec une autre musique."
            return
        case .applied(let musicChanged):
            if musicChanged, let filename = variant.musicFilename {
                startAnalysis(filename: filename)
                return
            }
        }
        // Même musique : la grille rythmique reste valable, seul le plan est à
        // refaire — départ, densité et format ont pu changer.
        if let map = beatMap {
            let restored = project.montageStartCentiseconds.map { Double($0) / 100 }
                ?? map.suggestedWindowStart
            windowStart = map.beatTimes.min(by: {
                abs($0 - restored) < abs($1 - restored)
            }) ?? restored
        }
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuildPlan() }
    }

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

        isRebuilding = true
        // CAPTURE UNIQUE de la liste : la boucle saute les passages sans média
        // (`continue`), donc `index` numérote TOUS les passages, sautés compris.
        // Relire `orderedPassages` plus tard donnerait une autre numérotation.
        let passages = project.orderedPassages

        var candidates: [MontageClipCandidate] = []
        var sources: [Int: URL] = [:]
        var crops: [Int: CGPoint] = [:]
        var smoothing: [Int: MontageSmoothingRequest] = [:]

        for (index, passage) in passages.enumerated() {
            // CLIP REJETÉ : écarté du montage, mais IL GARDE SON RANG.
            //
            // Le statut existait dans le modèle et excluait déjà le clip de
            // l'export un par un ; le montage, lui, ne l'a jamais consulté — on
            // pouvait rejeter un plan et le retrouver dans le fichier final.
            //
            // Le `continue` est posé APRÈS que `index` a été attribué, comme
            // pour un clip sans média : `clipID` reste la position du clip dans
            // la liste complète, donc le numéro lu à l'écran désigne toujours
            // la même ligne. Filtrer la liste en amont aurait décalé tous les
            // numéros suivants.
            guard passage.status != .rejete else { continue }

            // VERSION LISSÉE D'ABORD si elle existe, plage cachée ensuite
            // (autonome), copie source en dernier recours.
            //
            // Le fichier lissé COMMENCE au point d'entrée du clip : il ne
            // couvre qu'une fenêtre de la plage cachée, pas toute la plage.
            // Son point d'entrée est donc zéro, et non celui du cache.
            let url: URL
            let startInFile: CMTime
            // Vrai seulement pour la plage cachée nue — la seule qu'il reste
            // quelque chose à lisser.
            let mayNeedSmoothing: Bool
            if let smoothedPath = passage.smoothedRangeRelativePath,
               FileManager.default.fileExists(
                   atPath: StorageManager.url(forCachedRangeRelativePath: smoothedPath).path) {
                url = StorageManager.url(forCachedRangeRelativePath: smoothedPath)
                startInFile = .zero
                mayNeedSmoothing = false
            } else if let cachedPath = passage.cachedRangeRelativePath {
                url = StorageManager.url(forCachedRangeRelativePath: cachedPath)
                startInFile = CMTimeSubtract(passage.start, passage.cachedRangeOffset)
                mayNeedSmoothing = true
            } else if let sourcePath = passage.rush?.localSourceRelativePath {
                // PAS DE LISSAGE SANS PLAGE CACHÉE : il faudrait rendre le rush
                // entier pour en tirer deux secondes.
                url = StorageManager.url(forSourceRelativePath: sourcePath)
                startInFile = passage.start
                mayNeedSmoothing = false
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
            crops[index] = passage.cropCenter

            // LISSAGE SUR UNE FENÊTRE BORNÉE, à partir du point d'entrée du
            // clip.
            //
            // Rendre toute la plage cachée paraissait plus simple et plus
            // durable. En mode « jusqu'à la fin du rush », cette plage court
            // jusqu'au bout du rush : la phase 0 rendait des minutes entières
            // au flux optique, et déposait plus d'un gigaoctet, pour un clip
            // dont le montage n'utilise qu'une seconde.
            //
            // La fenêtre part du point d'entrée — c'est de là que tout créneau
            // prélève — et ne dépend d'aucun plan : elle survit donc aux
            // changements de densité et de fenêtre musicale, ce qui était la
            // qualité recherchée au départ.
            let entry = CMTimeMaximum(startInFile, trackRange.start)
            let available = CMTimeSubtract(trackRange.end, entry)
            let span = CMTimeMinimum(
                available,
                CMTime(seconds: MontageSmoothing.maxSmoothedSpan, preferredTimescale: 600)
            )
            if mayNeedSmoothing, span.seconds > 0.05,
               MontageSmoothing.needsSmoothing(
                   sourceFrameRate: passage.sourceNominalFrameRate,
                   speedNumerator: passage.speedNumerator,
                   speedDenominator: passage.speedDenominator,
                   colorimetry: passage.colorimetry) {
                // ARRONDI PAR EXCÈS au centième : un fichier plus COURT que la
                // fenêtre priverait le montage d'images que le plan croit
                // disponibles, tandis que le dépassement inverse tient dans la
                // tolérance de fin du planificateur d'images.
                let centiseconds = max(1, Int((span.seconds * 100).rounded(.up)))
                smoothing[index] = MontageSmoothingRequest(
                    clipID: index,
                    sourceURL: url,
                    sourceRange: CMTimeRange(start: entry, duration: span),
                    finalDuration: ExactDuration(centiseconds: centiseconds),
                    colorimetry: passage.colorimetry,
                    filename: "smooth-" + UUID().uuidString + ".mov"
                )
            }
        }

        // Deux reconstructions peuvent être en vol : celle qui n'est plus la
        // dernière se jette au lieu d'écraser le bon plan.
        guard !Task.isCancelled, generation == planGeneration else { return }
        let slots = map.slots(from: start, density: cutDensity)
        plan = MontagePlanner.plan(slots: slots, clips: candidates, windowStart: start)
        clipSources = sources
        clipCrops = crops
        smoothingRequests = smoothing
        planPassageIDs = passages.map { $0.persistentModelID }
        isRebuilding = false
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
        // `imageToo` seulement si la feuille est ouverte : elle attendrait
        // sinon une vignette que la reconstruction vient d'annuler, et
        // resterait sur « Préparation de l'aperçu… » jusqu'à sa fermeture.
        prepareOverlayShape(imageToo: showOverlays)
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
        // JAMAIS PENDANT UNE RECONSTRUCTION : le plan affiché n'est pas encore
        // celui qui sera exporté.
        guard let plan, !isRebuilding, let filename = project.musicFilename else { return }
        let generation = planGeneration
        let sources = clipSources
        let crops = clipCrops
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
                    crops: crops,
                    musicURL: MusicStore.url(forMusicFilename: filename),
                    overlays: resolvedOverlays, // dessinées par-dessus, pas incrustées ici
                    outputFormat: project.outputFormat,
                    cropToFill: project.cropToFillOutput
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

    /// Numéro du clip actuellement à l'écran, tel qu'il apparaît dans la liste.
    ///
    /// C'EST `clipID + 1`, c'est-à-dire le rang du PASSAGE — jamais le rang du
    /// placement dans le montage. Les deux coïncident tant que tous les clips
    /// sont placés, et divergent dès qu'un seul est écarté faute de matière
    /// (l'en-tête l'annonce : « 39/40 clips »). On lisait alors 8 à l'écran, on
    /// supprimait la ligne 8, et c'était le clip 9 qu'il fallait retirer : le
    /// numéro désignait la mauvaise ligne, ce qui est pire que pas de numéro.
    ///
    /// Un clip posé deux fois porte donc le même numéro à ses deux passages —
    /// c'est la vérité : c'est le même clip.
    /// Numéro du clip actuellement à l'écran, tel qu'il apparaît dans la liste.
    ///
    /// C'EST `clipID + 1`, c'est-à-dire le rang du PASSAGE — jamais le rang du
    /// placement dans le montage. Les deux coïncident tant que tous les clips
    /// sont placés, et divergent dès qu'un seul est écarté faute de matière
    /// (l'en-tête l'annonce : « 39/40 clips »). On lisait alors 8 à l'écran, on
    /// supprimait la ligne 8, et c'était le clip 9 qu'il fallait retirer : le
    /// numéro désignait la mauvaise ligne, ce qui est pire que pas de numéro.
    ///
    /// Un clip posé deux fois porte donc le même numéro à ses deux passages —
    /// c'est la vérité : c'est le même clip.
    /// Colorimétrie COMMUNE du montage, ou "inconnue" si les clips diffèrent.
    ///
    /// Un montage tout SDR peut déclarer son espace sans rien supposer. Dès
    /// qu'un clip HDR s'y mêle, plus aucune valeur unique n'est vraie : on
    /// laisse alors AVFoundation propager, comme avant.
    private var montageColorimetry: String {
        // SUR LES CLIPS RÉELLEMENT PLACÉS, comme à l'export : un clip écarté du
        // plan ne doit pas décider de l'espace d'un montage où il ne figure pas.
        let ordered = project.orderedPassages
        let population: [Passage]
        if let plan {
            population = Set(plan.placements.map { $0.clipID }).sorted()
                .compactMap { $0 >= 0 && $0 < ordered.count ? ordered[$0] : nil }
        } else {
            population = ordered
        }
        let all = Set(population.map { $0.colorimetry })
        return all.count == 1 ? (all.first ?? "inconnue") : "inconnue"
    }

    private var currentClipNumber: Int? {
        guard let plan, !plan.placements.isEmpty else { return nil }
        let now = CMTime(seconds: previewTime, preferredTimescale: 600)
        // Recherche à rebours : le dernier placement commencé est celui qu'on
        // regarde. Les vides entre deux créneaux gardent le numéro précédent,
        // ce qui vaut mieux qu'un affichage qui clignote.
        for placement in plan.placements.reversed() {
            if CMTimeCompare(placement.timelineStart, now) <= 0 {
                return placement.clipID + 1
            }
        }
        return plan.placements.first.map { $0.clipID + 1 }
    }

    /// Taille orientée du rush qui fournit le PREMIER clip placé — celle qui
    /// décide du cadre en mode automatique et du facteur d'agrandissement.
    ///
    /// `clipID` est l'INDEX dans `orderedPassages` : c'est ainsi que les
    /// candidats sont numérotés à la construction du plan.
    private var firstPlacedRushSize: CGSize {
        let fallback = project.orderedRushes.first?.orientedSize ?? .zero
        guard let first = plan?.placements.first else { return fallback }
        let passages = project.orderedPassages
        guard first.clipID >= 0, first.clipID < passages.count,
              let rush = passages[first.clipID].rush else { return fallback }
        let size = rush.orientedSize
        return size.width > 0 && size.height > 0 ? size : fallback
    }

    private func exportMontage() {
        guard let plan, let filename = project.musicFilename else { return }
        stopPreview()
        stopAudition()
        // LISSAGE DEMANDÉ POUR LES SEULS CLIPS RÉELLEMENT PLACÉS, et une seule
        // fois chacun : un clip repris à deux endroits du montage se rendrait
        // sinon deux fois, pour le même fichier.
        var requested = Set<Int>()
        let smoothing = plan.placements.compactMap { placement -> MontageSmoothingRequest? in
            guard requested.insert(placement.clipID).inserted else { return nil }
            return smoothingRequests[placement.clipID]
        }
        // IDENTITÉS FIGÉES MAINTENANT, pas relues au retour. L'export survit à
        // la fermeture de l'écran : supprimer un clip pendant qu'il tourne
        // décalerait les index, et le fichier lissé d'un clip atterrirait sur
        // un autre — un contenu faux, présenté comme valide.
        let passageIDs = planPassageIDs
        // LES CLIPS RÉELLEMENT MONTÉS, et eux seuls.
        //
        // Un clip écarté du plan — trop court pour son créneau, média absent —
        // n'a pas à peser sur des décisions qui portent sur le montage :
        // décider du suréchantillonnage ou de l'espace colorimétrique sur un
        // clip qui n'y figure pas revenait à laisser un absent trancher.
        let placedPassages = Set(plan.placements.map { $0.clipID })
            .sorted()
            .compactMap { index -> Passage? in
                let ordered = project.orderedPassages
                return index >= 0 && index < ordered.count ? ordered[index] : nil
            }
        let placedColorimetry: String = {
            let all = Set(placedPassages.map { $0.colorimetry })
            return all.count == 1 ? (all.first ?? "inconnue") : "inconnue"
        }()
        // CLIPS À ENFILER : ni ceux déjà dans Photos, ni les rejetés — le même
        // filtre que le bouton d'export manuel. Sans lui, chaque montage
        // déposait une seconde copie de chaque clip déjà exporté.
        let clipsToQueue = project.exportClipsWithMontage
            ? placedPassages
                .filter { $0.exportState != .exported && $0.status != .rejete }
                .map { $0.persistentModelID }
            : []
        MontageExportController.shared.start(
            plan: plan,
            sources: clipSources,
            crops: clipCrops,
            // TOUT EXPORTER D'UN COUP : le montage fini, puis les clips isolés.
            // La file part d'elle-même une fois le montage enregistré.
            clipsAfterwards: clipsToQueue,
            musicURL: MusicStore.url(forMusicFilename: filename),
            overlays: resolvedOverlays,
            outputFormat: project.outputFormat,
            cropToFill: project.cropToFillOutput,
            colorimetry: placedColorimetry,
            // SECONDE PASSE RÉSERVÉE AU SDR.
            //
            // L'agrandisseur décode en BGRA 8 bits et réécrit en Rec.709 : sur
            // un montage HLG ou 10 bits, il écraserait la profondeur et
            // décalerait le gamma — bandes franches dans les ciels, couleurs
            // ternes — pour gagner de la définition. Mieux vaut laisser
            // AVFoundation agrandir en une passe et garder la plage dynamique
            // intacte, sans rien demander à l'utilisateur.
            // `allSatisfy` vaut VRAI sur une collection vide : sans le test
            // d'existence, un plan dont plus aucun clip ne se résout aurait
            // activé la seconde passe sur une composition non étiquetée.
            upscale: project.upscaleOnExport
                && !placedPassages.isEmpty
                && placedPassages.allSatisfy { $0.colorimetry == "sdr" },
            sourceOriented: firstPlacedRushSize,
            smoothing: smoothing,
            onSmoothed: { produced in
                for (clipID, name) in produced {
                    guard clipID >= 0, clipID < passageIDs.count,
                          let passage = modelContext.model(
                            for: passageIDs[clipID]) as? Passage,
                          !passage.isDeleted else {
                        // Clip disparu pendant l'export : plus personne pour
                        // réclamer ce fichier, et rien ne le retrouverait.
                        try? FileManager.default.removeItem(
                            at: StorageManager.url(forCachedRangeRelativePath: name))
                        continue
                    }
                    // Un fichier lissé PLUS ANCIEN pour ce même clip n'a plus
                    // aucune référence une fois le chemin réécrit : sans cette
                    // suppression il resterait dans les plages cachées,
                    // introuvable et impurgeable autrement qu'en vidant tout.
                    if let previous = passage.smoothedRangeRelativePath, previous != name {
                        try? FileManager.default.removeItem(
                            at: StorageManager.url(forCachedRangeRelativePath: previous))
                    }
                    passage.smoothedRangeRelativePath = name
                }
                try? modelContext.save()
            },
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
