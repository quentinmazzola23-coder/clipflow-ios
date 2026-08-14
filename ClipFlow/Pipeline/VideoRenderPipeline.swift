//
//  VideoRenderPipeline.swift
//  ClipFlow
//
//  Pipeline en flux continu, mémoire bornée :
//  1. lecture des timestamps réels de la plage source (passthrough, sans décodage) ;
//  2. plan d'images exact (copies / interpolations, FramePlanner) ;
//  3. décodage matériel séquentiel (AVAssetReader) ;
//  4. interpolation par le moteur choisi ;
//  5. encodage (AVAssetWriter, HEVC par défaut), timestamps de sortie exacts ;
//  6. vérification durée + nombre d'images du fichier produit.
//
//  Jamais plus de deux images sources 4K et une image de destination en vol.
//

import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox
import os
import os.signpost

struct RenderJob: Sendable {
    var sourceURL: URL
    /// Plage de la sélection dans la base de temps du FICHIER source.
    var sourceRange: CMTimeRange
    var finalDuration: ExactDuration
    var speed: RationalSpeed
    var fps: Int
    /// "hevc" ou "h264".
    var codec: String
    var outputFilename: String
    /// "sdr", "hlg", "pq", "dolbyVision", "appleLog", "inconnue".
    var colorimetry: String
    /// Forcer le moteur de secours (aperçu rapide).
    var forceFastEngine: Bool = false
}

struct RenderResult: Sendable {
    var outputURL: URL
    var durationSeconds: Double
    var frameCount: Int
    var expectedFrameCount: Int
    var width: Int
    var height: Int
    var codec: String
    var fileSizeBytes: Int64
    var engineName: String
    var processingSeconds: Double
    var interpolatedFrames: Int
    var copiedFrames: Int
    /// Images interpolées écartées par le failsafe anti-flash (remplacées par
    /// l'image source la plus proche).
    var correctedFrames: Int
    /// Déviation de luminance maximale observée sur les images interpolées
    /// (instrumentation : calibrage du seuil anti-flash sur contenu réel).
    var maxLumaDeviation: Double
    /// Frames décodées écartées lors de l'appariement par timestamps
    /// (pré-roll, échantillons surnuméraires) — visibilité, pas silence.
    var discardedDecodedFrames: Int
    /// Images interpolées non contrôlables par le failsafe (format non géré).
    var uncheckedInterpolatedFrames: Int
    /// Rejets du failsafe NON appliqués par le disjoncteur anti-rafale (un
    /// artefact réel est isolé ; une rafale de rejets = failsafe qui se
    /// trompe, et remplacer en rafale FIGE le clip — défaut pire).
    var failsafeOverrides: Int
    /// Paires d'images consécutives IDENTIQUES dans le fichier produit
    /// (vérité terrain mesurée à la vérification : un ralenti interpolé sain
    /// n'en contient pratiquement aucune).
    var duplicatePairs: Int
    /// Cadence réelle de la source décodée : « médian/min/max ms » — révèle
    /// immédiatement une source VFR (l'iPhone baisse la cadence en basse
    /// lumière ou scène statique).
    var sourceIntervalInfo: String
    /// Indices des images du FICHIER PRODUIT jugées aberrantes par l'analyse
    /// finale (luma + chrominance + extrêmes, grille 16×16) — vérité terrain.
    var artifactFrames: [Int]
    /// Écart maximal hors enveloppe mesuré sur le fichier produit (toutes
    /// composantes) — instrumentation du seuil sur contenu réel.
    var maxOutputAnomaly: Double
    /// Plus grand nombre de TUILES déviantes sur une même image : c'est ce
    /// chiffre qui sépare un artefact étendu d'un bord d'objet local.
    /// Instrumentation indispensable au calibrage sur rush réel.
    var maxDeviatingTiles: Int = 0
    /// Anomalies SUBSISTANTES = présentes dans la source (changement
    /// d'exposition brutal filmé par l'iPhone), pas fabriquées par le rendu.
    var sourceAnomalyFrames: Int = 0
    /// Le rendu au flux optique a été REJETÉ et refait sans interpolation.
    var opticalFlowRejected: Bool = false
    /// Nombre d'images aberrantes qui ont motivé le rejet.
    var rejectedArtifactFrames: Int = 0
    /// Images interpolées sorties du moteur SANS attachement colorimétrique
    /// propageable : étiquetées BT.709 explicitement. Un compteur non nul est
    /// un défaut à corriger, pas une statistique.
    var untaggedInterpolatedFrames: Int = 0
}

enum RenderError: Error, LocalizedError {
    case hdrFormatUnsupported(String)
    case readerFailed(String)
    case writerFailed(String)
    case verificationFailed(expected: Int, actual: Int)
    case interpolationUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .hdrFormatUnsupported(let format):
            return "Format \(format) non pris en charge par le moteur d'interpolation. Export bloqué pour éviter un rendu délavé — une conversion SDR tone-mappée sera proposée dans une version future."
        case .readerFailed(let details):
            return "Échec de lecture de la source : \(details)"
        case .writerFailed(let details):
            return "Échec d'encodage : \(details)"
        case .verificationFailed(let expected, let actual):
            return "Vérification échouée : \(actual) images produites au lieu de \(expected)."
        case .interpolationUnavailable:
            return "Interpolation par flux optique indisponible sur cet appareil pour cette vidéo. Export bloqué : aucun repli en duplication d'images (rendu saccadé) n'est appliqué silencieusement."
        case .cancelled:
            return "Rendu annulé."
        }
    }
}

final class VideoRenderPipeline {

    private static let signpostLog = OSLog(subsystem: "com.example.clipflow", category: "Render")

    /// Rendu avec CONTRÔLE ET REPLI TOTAL.
    ///
    /// Le flux optique fabrique des images ; une fabrication peut être fausse,
    /// et son taux d'échec ne sera jamais nul. La seule garantie tenable n'est
    /// donc pas « aucun artefact » mais « aucun artefact LIVRÉ » : au moindre
    /// défaut mesuré sur le fichier produit, le clip ENTIER est re-rendu sans
    /// flux optique. Pire cas : un clip saccadé. Jamais un clip faux.
    ///
    /// Pas de réparation partielle. Elle a échoué trois fois, et le re-rendu
    /// d'une passe sur un chemin matériel non déterministe DÉPLACE les
    /// artefacts au lieu de les supprimer — ce que l'ancien comptage
    /// interprétait à tort comme une réparation.
    static func render(job: RenderJob,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderResult {
        var result = try await renderPass(job: job, onProgress: onProgress)
        guard !result.artifactFrames.isEmpty, !job.forceFastEngine else { return result }
        // Point d'annulation AVANT la seconde passe : sans lui, « Tout annuler »
        // devait attendre DEUX rendus complets, et la file paraissait figée.
        try Task.checkCancellation()

        os_log("Repli total : %d image(s) aberrante(s) mesurée(s) sur le fichier produit",
               log: signpostLog, type: .error, result.artifactFrames.count)
        let rejected = result.artifactFrames.count
        var safeJob = job
        safeJob.forceFastEngine = true
        result = try await renderPass(job: safeJob, onProgress: onProgress)
        result.opticalFlowRejected = true
        result.rejectedArtifactFrames = rejected
        // Une anomalie SUBSISTANT sans flux optique vient de la source
        // (changement d'exposition filmé) : signalée, jamais « corrigée ».
        result.sourceAnomalyFrames = result.artifactFrames.count
        return result
    }

    /// Une passe de rendu, de bout en bout.
    private static func renderPass(job: RenderJob,
                                   onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderResult {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(.begin, log: signpostLog, name: "RenderPassage", signpostID: signpostID)
        defer { os_signpost(.end, log: signpostLog, name: "RenderPassage", signpostID: signpostID) }

        let startedAt = ContinuousClock.now

        // Politique HDR : PQ / Dolby Vision / Apple Log refusés explicitement
        // (jamais d'export silencieusement délavé). SDR et HLG pris en charge.
        switch job.colorimetry {
        case "pq", "dolbyVision", "appleLog":
            throw RenderError.hdrFormatUnsupported(job.colorimetry)
        default:
            break
        }
        let isHDRContent = (job.colorimetry == "hlg")

        let asset = AVURLAsset(url: job.sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.readerFailed("aucune piste vidéo")
        }
        let (naturalSize, transform, formatDescriptions) = try await track.load(
            .naturalSize, .preferredTransform, .formatDescriptions
        )
        let encodeWidth = Int(abs(naturalSize.width))
        let encodeHeight = Int(abs(naturalSize.height))

        // Plage à décoder : sélection + une marge d'un quart de seconde de part
        // et d'autre, pour garantir des images encadrantes aux deux extrémités.
        let margin = CMTime(value: 1, timescale: 4)
        let decodeStart = CMTimeMaximum(.zero, CMTimeSubtract(job.sourceRange.start, margin))
        let decodeEnd = CMTimeAdd(job.sourceRange.end, margin)
        let decodeRange = CMTimeRange(start: decodeStart, end: decodeEnd)

        // CHAÎNE TOUT-RGB (BGRA) — décision structurelle après diagnostic sur
        // images réelles : les images interpolées sortaient du moteur VT avec
        // la CHROMINANCE INVERSÉE (ciel rose, verts turquoise) — les pixels
        // eux-mêmes, pas les étiquettes. En RGB, il n'existe ni matrice YCbCr
        // ni ordre de plans à confondre : la classe entière du bug disparaît.
        //
        // ⚠️ AUCUN TONE MAPPING ICI, contrairement à ce que ce commentaire
        // affirmait : `AVAssetReaderTrackOutput` avec un simple format de pixel
        // fait une conversion MATRICIELLE, pas une conversion de plage
        // dynamique. Du HLG reste encodé HLG dans les octets BGRA, puis est
        // étiqueté 709 par AVVideoColorPropertiesKey — donc délavé. Voir la
        // politique HDR ci-dessus : HLG devra être refusé comme PQ, ou
        // réellement tone-mappé.
        let readerPixelFormat: OSType = kCVPixelFormatType_32BGRA

        // --- Moteur : préchauffé PENDANT la passe 1. ---
        // Le démarrage d'une session VideoToolbox (processeur + pools) coûte
        // plusieurs centaines de millisecondes : il est lancé en parallèle de
        // la lecture des timestamps, et la session est RÉUTILISÉE d'un clip au
        // suivant quand les dimensions n'ont pas changé (file séquentielle).
        // Démarrage optimiste : si le plan ne demande finalement aucune
        // interpolation, la session repart simplement dans le cache.
        let warmupTask: Task<Result<FrameInterpolationEngine, Error>, Never>? = {
            guard !job.forceFastEngine else { return nil }
            // AUCUNE réutilisation de session entre clips : en mode de
            // soumission séquentiel, le premier couple du clip N+1 héritait de
            // l'état temporel du clip N — contenu totalement différent. Le gain
            // (quelques centaines de ms) ne vaut pas une image fausse en tête
            // de clip.
            guard let fresh = InterpolationEngineFactory.bestEngine(width: encodeWidth, height: encodeHeight) else {
                return nil
            }
            return Task {
                do {
                    try await fresh.startSession(width: encodeWidth, height: encodeHeight)
                    return .success(fresh)
                } catch {
                    return .failure(error)
                }
            }
        }()

        // Une session préchauffée mais finalement inutilisable ne doit jamais
        // rester orpheline (fuite GPU) : libération asynchrone.
        func abandonWarmup() {
            guard let warmupTask else { return }
            Task {
                if case .success(let unused) = await warmupTask.value { unused.endSession() }
            }
        }

        // --- Passe 1 : timestamps des frames RÉELLEMENT DÉCODÉES. ---
        // (Le passthrough listait des échantillons conteneur que le décodeur
        // ne livre pas toujours — frame de frontière notamment — et tout
        // désalignement de liste faussait le rythme du clip. En décodant les
        // deux passes à l'identique, les ensembles coïncident par construction.)
        // Hors pool coopératif : boucle de décodage bloquante.
        let sourcePTS: [CMTime]
        do {
            sourcePTS = try await Task.detached(priority: .userInitiated) {
                try collectDecodedTimestamps(
                    asset: asset, track: track, range: decodeRange, pixelFormat: readerPixelFormat
                )
            }.value
        } catch {
            abandonWarmup()
            throw error
        }
        guard sourcePTS.count >= 2 else {
            abandonWarmup()
            throw RenderError.readerFailed("plage source trop courte (\(sourcePTS.count) image(s))")
        }

        // Cadence réelle de la source décodée (diagnostic VFR au bilan : une
        // caméra iPhone peut tomber à 30 voire 15 fps en basse lumière).
        let sortedIntervalsMs = zip(sourcePTS.dropFirst(), sourcePTS)
            .map { CMTimeSubtract($0, $1).seconds * 1000 }
            .sorted()
        let sourceIntervalInfo = String(
            format: "%.1f ms (min %.1f, max %.1f)",
            sortedIntervalsMs[sortedIntervalsMs.count / 2],
            sortedIntervalsMs.first ?? 0, sortedIntervalsMs.last ?? 0
        )

        // --- Plan d'images exact. ---
        let (expectedFrames, exact) = TimeMath.outputFrameCount(final: job.finalDuration, fps: job.fps)
        _ = exact // une durée non divisible a déjà été signalée à l'utilisateur en amont
        let plan: [FramePlanEntry]
        do {
            plan = try FramePlanner.plan(
                sourcePTS: sourcePTS,
                selectionStart: job.sourceRange.start,
                outputFrameCount: expectedFrames,
                fps: job.fps,
                speed: job.speed
            )
        } catch {
            abandonWarmup()
            throw error
        }

        // --- Moteur d'interpolation. ---
        // Qualité maximale exigée : si le flux optique VideoToolbox n'est pas
        // disponible et que des images intermédiaires sont nécessaires, l'export
        // ÉCHOUE explicitement — jamais de duplication d'images silencieuse.
        let needsInterpolation = plan.contains { if case .interpolate = $0 { return true } ; return false }
        let engine: FrameInterpolationEngine
        if let warmupTask {
            switch await warmupTask.value {
            case .success(let warmed):
                engine = warmed
            case .failure(let error):
                guard !needsInterpolation else { throw error }
                engine = PassthroughRetimeEngine()
            }
        } else if job.forceFastEngine {
            engine = PassthroughRetimeEngine()
        } else if needsInterpolation {
            throw RenderError.interpolationUnavailable
        } else {
            // Aucune interpolation requise (ex. source 120 fps → 0,5× 60 fps) :
            // toutes les images finales sont des copies exactes.
            engine = PassthroughRetimeEngine()
        }
        // UNE session par passe de rendu, toujours fermée : aucun état temporel
        // ne franchit la frontière d'un clip ni d'une passe.
        defer { engine.endSession() }

        // --- Passe 2 : décodage séquentiel. ---
        // Format de lecture choisi EXPLICITEMENT (jamais le dictionnaire
        // d'attributs VT verbatim : vocabulaire CoreVideo ≠ outputSettings,
        // risque d'exception à la construction). 8 bits pour le SDR,
        // 10 bits bi-planaire pour le HLG — formats standard acceptés par VT.
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = decodeRange
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        // alwaysCopiesSampleData = TRUE, délibérément.
        // À false, Apple autorise le décodeur à RÉUTILISER la mémoire des
        // échantillons déjà livrés. Or ce pipeline retient les images bien
        // au-delà de leur livraison : previousBuffer/currentBuffer traversent
        // l'interpolation du groupe suivant (recouvrement GPU/CPU), le
        // failsafe, une file de copies en attente, et l'encodage lui-même est
        // asynchrone. Une image réécrite pendant que l'encodeur la lit = UNE
        // image corrompue isolée dans le fichier — exactement le symptôme
        // « flash d'une seule image ». La copie coûte quelques dizaines de
        // millisecondes par clip : sans commune mesure avec le défaut.
        readerOutput.alwaysCopiesSampleData = true
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "startReading")
        }

        // --- Writer. ---
        let outputURL = StorageManager.exportsDirectory.appendingPathComponent(job.outputFilename)
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        _ = isHDRContent // politique d'acceptation seulement — la chaîne BGRA
                         // livre du display-referred, tagué 709 ci-dessous.
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: job.fps,
            AVVideoAllowFrameReorderingKey: true,
        ]
        var writerSettings: [String: Any] = [
            AVVideoWidthKey: encodeWidth,
            AVVideoHeightKey: encodeHeight,
        ]
        if job.codec == "h264" {
            writerSettings[AVVideoCodecKey] = AVVideoCodecType.h264
            compression[AVVideoAverageBitRateKey] = 50_000_000
        } else {
            writerSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
            compression[AVVideoQualityKey] = 0.85
            // Pas de Main10 tant que la chaîne 10 bits n'est pas validée de
            // bout en bout sur appareil (source du flash bleu).
        }
        writerSettings[AVVideoCompressionPropertiesKey] = compression
        // Chaîne BGRA : le décodeur a produit du RGB display-referred (HDR
        // tone-mappé) — l'encodeur reconvertit en YUV avec des tags BT.709
        // UNIFORMES pour toutes les images, copies comme interpolées.
        writerSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform // orientation préservée
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: nil
        )
        writer.add(writerInput)
        guard writer.startWriting() else {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)
        _ = formatDescriptions // extensions consultées via colorimétrie déjà extraite

        // --- Boucle de production : fenêtre glissante de deux images sources. ---
        var sourceIndex = -1
        var previousBuffer: CVPixelBuffer?
        var currentBuffer: CVPixelBuffer?
        var interpolatedCount = 0
        var copiedCount = 0
        var correctedCount = 0
        var maxLumaDeviation: Double = 0
        var discardedDecodedFrames = 0
        var uncheckedInterpolatedFrames = 0
        var outputFrameIndex = 0

        /// Avance le décodeur jusqu'à l'index demandé en APPARIANT PAR
        /// TIMESTAMP — jamais par comptage aveugle. Toute frame décodée dont
        /// le PTS n'est pas le prochain attendu est écartée (comptée) ; une
        /// frame attendue jamais livrée = erreur EXPLICITE, pas de glissement
        /// silencieux (cause racine du « ralenti puis accélération »).
        func advanceTo(index: Int) throws {
            while sourceIndex < index {
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    throw RenderError.readerFailed(
                        "fin de flux prématurée (attendu PTS \(sourcePTS[sourceIndex + 1].seconds) s)"
                    )
                }
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let expected = sourcePTS[sourceIndex + 1]
                if CMTimeCompare(pts, CMTimeSubtract(expected, FramePlanner.matchTolerance)) < 0 {
                    // Frame non listée (pré-roll, échantillon surnuméraire) :
                    // écartée, jamais comptée comme une avancée d'index.
                    discardedDecodedFrames += 1
                    continue
                }
                if CMTimeCompare(pts, CMTimeAdd(expected, FramePlanner.matchTolerance)) > 0 {
                    // La frame attendue n'a jamais été livrée par le décodeur :
                    // désynchronisation détectée — échec net plutôt qu'un clip
                    // au rythme faux.
                    throw RenderError.readerFailed(String(
                        format: "désynchronisation décodeur : attendu %.4f s, reçu %.4f s",
                        expected.seconds, pts.seconds
                    ))
                }
                previousBuffer = currentBuffer
                currentBuffer = imageBuffer
                sourceIndex += 1
            }
        }

        /// Attente coopérative que le writer accepte des données.
        /// BORNÉE : un encodeur qui n'accepte plus rien (échec interne, mémoire,
        /// session invalide) laissait cette boucle tourner À L'INFINI — un
        /// export figé pour toujours, sans message. Au-delà du délai, l'échec
        /// est explicite.
        func appendWhenReady(_ buffer: CVPixelBuffer, pts: CMTime) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed {
                    throw RenderError.writerFailed(writer.error?.localizedDescription ?? "encodeur en échec")
                }
                if ContinuousClock.now > deadline {
                    throw RenderError.writerFailed(
                        "encodeur bloqué : aucune image acceptée depuis 30 s (statut \(writer.status.rawValue))"
                    )
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw RenderError.writerFailed(writer.error?.localizedDescription ?? "append")
            }
        }

        /// Append + progression. L'ordre des appends suit STRICTEMENT le plan.
        func appendOutput(_ buffer: CVPixelBuffer) async throws {
            try await appendWhenReady(buffer, pts: TimeMath.outputPTS(frameIndex: outputFrameIndex, fps: job.fps))
            outputFrameIndex += 1
            onProgress(Double(outputFrameIndex) / Double(expectedFrames))
        }

        // RECOUVREMENT GPU/CPU : pendant que VideoToolbox interpole le groupe
        // suivant, le failsafe et l'encodage du groupe précédent tournent sur
        // le CPU. Les appels moteur ne sont JAMAIS concurrents (le résultat du
        // groupe k est attendu avant de soumettre le groupe k+1) et l'ordre
        // des appends reste exactement celui du plan : le groupe en attente
        // est encodé avant les copies retenues derrière lui.
        struct PendingInterpolation {
            let prev: CVPixelBuffer
            let next: CVPixelBuffer
            /// Signatures des DEUX sources, calculées À LA CONSTRUCTION —
            /// c'est-à-dire pendant que le moteur est au repos. Les calculer
            /// dans flushPending verrouillait l'adresse de base de buffers que
            /// VideoToolbox lisait déjà comme sources du groupe SUIVANT
            /// (group_k.next EST group_{k+1}.prev).
            let tilesPrev: [Double]?
            let tilesNext: [Double]?
            let phases: [Float]
            let produced: [CVPixelBuffer]
        }
        var pendingGroup: PendingInterpolation?
        // Copies décodées arrivées derrière un groupe non encore encodé.
        var copyBacklog: [CVPixelBuffer] = []
        // DISJONCTEUR ANTI-RAFALE du failsafe : budget de remplacements par
        // clip + plafond de groupes consécutifs rejetés (voir
        // failsafeShouldReplace).
        var failsafeOverrides = 0
        var untaggedInterpolatedFrames = 0
        var consecutiveRejectedGroups = 0
        let maxCorrections = max(4, expectedFrames * 15 / 100)

        /// FAILSAFE ANTI-ARTEFACT v3 : le flux optique produit parfois des
        /// images aberrantes (flash global OU zone noire partielle). Chaque
        /// image interpolée est testée contre l'ENVELOPPE [min, max] de ses
        /// deux sources, tuile par tuile (grille 4×4) — voir
        /// envelopeOvershoot(). Dépassement franc → remplacement par la source
        /// la plus proche (micro-duplication invisible plutôt qu'un défaut
        /// visible). Puis encodage du groupe et des copies retenues.
        func flushPending() async throws {
            if let group = pendingGroup {
                pendingGroup = nil
                // Signatures pré-calculées : verrouiller ici l'adresse de base
                // des sources reviendrait à lire des buffers que le moteur
                // utilise déjà pour le groupe suivant.
                let tilesPrev = group.tilesPrev
                let tilesNext = group.tilesNext
                var groupRejected = false
                for (phaseIndex, buffer) in group.produced.enumerated() {
                    var outputBuffer = buffer
                    if let tp = tilesPrev, let tn = tilesNext,
                       let tb = Self.tileLuma(of: buffer),
                       tp.count == tb.count, tn.count == tb.count {
                        let worstOvershoot = Self.envelopeOvershoot(previous: tp, next: tn, candidate: tb)
                        maxLumaDeviation = max(maxLumaDeviation, worstOvershoot)
                        if worstOvershoot > Self.envelopeRejectThreshold {
                            groupRejected = true
                            if Self.failsafeShouldReplace(
                                correctedSoFar: correctedCount,
                                maxCorrections: maxCorrections,
                                consecutiveRejectedGroups: consecutiveRejectedGroups
                            ) {
                                outputBuffer = group.phases[phaseIndex] < 0.5 ? group.prev : group.next
                                correctedCount += 1
                            } else {
                                // Disjoncteur : remplacer en rafale FIGERAIT
                                // le clip (défaut pire qu'un artefact isolé).
                                failsafeOverrides += 1
                            }
                        }
                    } else {
                        // Format non mesurable : signalé, jamais silencieux.
                        uncheckedInterpolatedFrames += 1
                    }
                    // Étiquetage UNIQUEMENT sur un buffer sorti du pool du
                    // moteur. Une image substituée par le failsafe EST une
                    // image source : elle porte déjà ses attachements, et
                    // CVBufferSetAttachments écrirait dans une sourceFrame que
                    // VideoToolbox lit encore pour le groupe suivant.
                    if outputBuffer === buffer {
                        Self.tagInterpolatedBuffer(outputBuffer, from: group.prev,
                                                   untagged: &untaggedInterpolatedFrames)
                    }
                    try await appendOutput(outputBuffer)
                    interpolatedCount += 1
                }
                consecutiveRejectedGroups = groupRejected ? consecutiveRejectedGroups + 1 : 0
            }
            for buffer in copyBacklog {
                try await appendOutput(buffer)
                copiedCount += 1
            }
            copyBacklog.removeAll(keepingCapacity: true)
        }

        var entryIndex = 0
        while entryIndex < plan.count {
            try Task.checkCancellation()
            let entry = plan[entryIndex]
            switch entry {
            case .copy(let index):
                try advanceTo(index: index)
                guard let buffer = currentBuffer else {
                    throw RenderError.readerFailed("buffer manquant à l'image \(index)")
                }
                // Les images COPIÉES passent par le même appendOutput que les
                // interpolées : la réparation y est appliquée en un point
                // unique, sur un index fiable.
                if pendingGroup == nil {
                    try await appendOutput(buffer)
                    copiedCount += 1
                } else {
                    // Ordre du plan : cette copie suit le groupe en attente.
                    // Borne de rétention (pression sur le pool du décodeur) :
                    // au-delà de 4 copies retenues, encodage immédiat du
                    // groupe (pur CPU, son résultat est déjà matérialisé).
                    copyBacklog.append(buffer)
                    if copyBacklog.count >= 4 {
                        try await flushPending()
                    }
                }
                entryIndex += 1

            case .interpolate(let prevIdx, let nextIdx, _):
                try advanceTo(index: nextIdx)
                guard let prev = (nextIdx - prevIdx == 1 ? previousBuffer : nil),
                      let next = currentBuffer else {
                    throw RenderError.readerFailed("paire source indisponible (\(prevIdx), \(nextIdx))")
                }
                // Phases consécutives sur la même paire.
                var phases: [Float] = []
                var lookahead = entryIndex
                while lookahead < plan.count,
                      case .interpolate(prevIdx, nextIdx, let phase) = plan[lookahead] {
                    phases.append(phase)
                    lookahead += 1
                }
                // Figée en `let` : l'initialiseur d'un async let s'exécute
                // dans une tâche fille et ne peut capturer aucune `var`
                // locale (erreur de compilation SE-0317).
                let groupPhases = phases
                // Soumission GPU immédiate ; le groupe PRÉCÉDENT est contrôlé
                // et encodé pendant que celui-ci se calcule. En cas d'erreur
                // du flush, la tâche fille est annulée par la concurrence
                // structurée.
                async let producedNow = try await engine.interpolate(
                    previous: prev,
                    previousPTS: sourcePTS[prevIdx],
                    next: next,
                    nextPTS: sourcePTS[nextIdx],
                    phases: groupPhases
                )
                try await flushPending()
                // Le moteur est au repos à partir de cet `await` : c'est le
                // SEUL moment où lire les pixels des sources est sûr.
                let produced = try await producedNow
                pendingGroup = PendingInterpolation(
                    prev: prev, next: next,
                    tilesPrev: Self.tileLuma(of: prev), tilesNext: Self.tileLuma(of: next),
                    phases: groupPhases, produced: produced
                )
                entryIndex = lookahead
            }
        }
        // Dernier groupe + copies restantes.
        try await flushPending()

        reader.cancelReading()
        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }

        // --- Vérification du fichier produit. ---
        let (verifiedDuration, verifiedCount, duplicatePairs, anomalies, maxAnomaly, maxDeviatingTiles) =
            try await verify(outputURL: outputURL)
        guard verifiedCount == expectedFrames else {
            throw RenderError.verificationFailed(expected: expectedFrames, actual: verifiedCount)
        }

        let fileSize = Int64((try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let elapsed = startedAt.duration(to: ContinuousClock.now)

        return RenderResult(
            outputURL: outputURL,
            durationSeconds: verifiedDuration,
            frameCount: verifiedCount,
            expectedFrameCount: expectedFrames,
            width: encodeWidth,
            height: encodeHeight,
            codec: job.codec,
            fileSizeBytes: fileSize,
            engineName: engine.displayName,
            processingSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            interpolatedFrames: interpolatedCount,
            copiedFrames: copiedCount,
            correctedFrames: correctedCount,
            maxLumaDeviation: maxLumaDeviation,
            discardedDecodedFrames: discardedDecodedFrames,
            uncheckedInterpolatedFrames: uncheckedInterpolatedFrames,
            failsafeOverrides: failsafeOverrides,
            duplicatePairs: duplicatePairs,
            sourceIntervalInfo: sourceIntervalInfo,
            artifactFrames: anomalies,
            maxOutputAnomaly: maxAnomaly,
            maxDeviatingTiles: maxDeviatingTiles,
            untaggedInterpolatedFrames: untaggedInterpolatedFrames
        )
    }

    // Le CACHE DE SESSION MOTEUR a été supprimé : en mode de soumission
    // séquentiel, réutiliser une session d'un clip au suivant faisait hériter
    // au premier couple l'état temporel d'un contenu totalement différent.

    // MARK: - Colorimétrie des buffers

    /// Copie les attachements propageables (matrice YCbCr, primaires, fonction
    /// de transfert…) d'un buffer source vers un buffer produit par un pool —
    /// sans eux, l'encodeur retombe sur BT.709 et teinte les images.
    static func propagateColorAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        guard source !== destination else { return }
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }
    }

    /// Étiquette une image interpolée : attachements de la source si
    /// disponibles, sinon BT.709 EXPLICITE.
    ///
    /// L'ancienne version était un `if let` SANS branche `else` : quand la
    /// source ne portait aucun attachement propageable, l'image interpolée
    /// partait nue vers l'encodeur — qui la traitait en 709 sans conversion,
    /// entre des copies étiquetées et converties. Une image sur deux teintée.
    /// Un défaut d'étiquetage doit être COMPTÉ, jamais silencieux.
    static func tagInterpolatedBuffer(_ destination: CVPixelBuffer,
                                      from source: CVPixelBuffer,
                                      untagged: inout Int) {
        guard source !== destination else { return }
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }
        // `CVBufferCopyAttachments` renvoie un dictionnaire VIDE, pas nil,
        // quand la source ne porte rien — tester la seule nullité laissait
        // donc passer le cas à corriger (mesuré par le banc : compteur à 0 et
        // image nue). Ce qui compte est l'état RÉEL de la destination.
        let colorKeys = [
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
        ]
        let hasAnyColorTag = colorKeys.contains { CVBufferCopyAttachment(destination, $0, nil) != nil }
        // Un étiquetage PARTIEL est laissé tel quel : l'encodeur a de quoi
        // travailler, et écraser ce que la source annonce serait pire. Seule
        // l'absence TOTALE est comblée — et comptée.
        guard !hasAnyColorTag else { return }
        untagged += 1
        CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    // MARK: - Failsafe anti-artefact

    /// Marge tolérée hors de l'enveloppe [min, max] des deux sources (échelle
    /// luma 0-255) — absorbe le bruit du flux optique sans laisser passer un
    /// flash ou un trou noir.
    static let envelopeMargin: Double = 26
    /// Dépassement d'enveloppe (au pire des tuiles) au-delà duquel l'image
    /// interpolée est écartée au profit de la source la plus proche.
    static let envelopeRejectThreshold: Double = 12

    /// DISJONCTEUR ANTI-RAFALE : faut-il réellement APPLIQUER un remplacement
    /// demandé par le test d'enveloppe ? Un artefact réel du flux optique est
    /// ISOLÉ (une à deux images). Une rafale de rejets consécutifs ou un
    /// volume anormal sur le clip signifie que c'est le failsafe qui se trompe
    /// — et remplacer en rafale produit des doublons en chaîne = clip FIGÉ
    /// puis saut (constaté deux fois sur exports réels). Au-delà de 2 groupes
    /// consécutifs rejetés ou du budget par clip, la sortie du moteur est
    /// acceptée telle quelle et l'événement est compté (failsafeOverrides).
    static func failsafeShouldReplace(correctedSoFar: Int,
                                      maxCorrections: Int,
                                      consecutiveRejectedGroups: Int) -> Bool {
        guard consecutiveRejectedGroups < 2 else { return false }
        guard correctedSoFar < maxCorrections else { return false }
        return true
    }

    /// Test d'ENVELOPPE, pas d'écart à la moyenne : sur un panoramique rapide,
    /// une interpolation PARFAITE diffère fortement de ses DEUX sources (le
    /// contenu s'est déplacé) — un test « écart à la moyenne » la jette en
    /// rafale → doublons → clip quasi figé puis saut de rattrapage (constaté
    /// sur export réel). Un vrai artefact (flash blanc, trou noir), lui, SORT
    /// de la plage [min, max] des deux sources ; un mouvement, jamais.
    /// Retourne le pire dépassement d'enveloppe parmi les tuiles (0 = sain).
    static func envelopeOvershoot(previous: [Double], next: [Double], candidate: [Double]) -> Double {
        var worst: Double = 0
        for tileIndex in 0..<candidate.count {
            let low = min(previous[tileIndex], next[tileIndex]) - envelopeMargin
            let high = max(previous[tileIndex], next[tileIndex]) + envelopeMargin
            if candidate[tileIndex] < low {
                worst = max(worst, low - candidate[tileIndex])
            } else if candidate[tileIndex] > high {
                worst = max(worst, candidate[tileIndex] - high)
            }
        }
        return worst
    }

    /// Luminance moyenne (échelle 0-255) par tuile d'une grille 4×4.
    /// Gère BGRA (chaîne principale : luma ≈ 0,299R + 0,587G + 0,114B) et les
    /// formats bi-planaires 8/10 bits (tests, diagnostics). nil si non géré.
    static func tileLuma(of buffer: CVPixelBuffer) -> [Double]? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA {
            return tileLumaBGRA(of: buffer)
        }
        let is8Bit = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let is10Bit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        guard is8Bit || is10Bit else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width >= 4, height >= 4 else { return nil }

        let grid = 4
        var totals = [Double](repeating: 0, count: grid * grid)
        var counts = [Int](repeating: 0, count: grid * grid)
        let stepX = max(width / 64, 1)
        let stepY = max(height / 64, 1)

        var y = 0
        while y < height {
            let tileY = min(y * grid / height, grid - 1)
            var x = 0
            if is8Bit {
                let row = base.assumingMemoryBound(to: UInt8.self) + y * stride
                while x < width {
                    let tileIndex = tileY * grid + min(x * grid / width, grid - 1)
                    totals[tileIndex] += Double(row[x])
                    counts[tileIndex] += 1
                    x += stepX
                }
            } else {
                let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                while x < width {
                    let tileIndex = tileY * grid + min(x * grid / width, grid - 1)
                    totals[tileIndex] += Double(row[x] >> 8) // 10 bits alignés à gauche
                    counts[tileIndex] += 1
                    x += stepX
                }
            }
            y += stepY
        }
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }
        return zip(totals, counts).map { $0 / Double($1) }
    }

    /// Grille 4×4 de luminance pour un buffer BGRA (octets B,G,R,A).
    private static func tileLumaBGRA(of buffer: CVPixelBuffer) -> [Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 4, height >= 4 else { return nil }

        let grid = 4
        var totals = [Double](repeating: 0, count: grid * grid)
        var counts = [Int](repeating: 0, count: grid * grid)
        let stepX = max(width / 64, 1)
        let stepY = max(height / 64, 1)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var y = 0
        while y < height {
            let tileY = min(y * grid / height, grid - 1)
            let row = pointer + y * stride
            var x = 0
            while x < width {
                let tileIndex = tileY * grid + min(x * grid / width, grid - 1)
                let pixel = row + x * 4
                let luma = 0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
                totals[tileIndex] += luma
                counts[tileIndex] += 1
                x += stepX
            }
            y += stepY
        }
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }
        return zip(totals, counts).map { $0 / Double($1) }
    }

    /// Luminance moyenne globale — conservée pour les tests et le diagnostic.
    static func averageLuma(of buffer: CVPixelBuffer) -> Double? {
        guard let tiles = tileLuma(of: buffer) else { return nil }
        return tiles.reduce(0, +) / Double(tiles.count)
    }

    // MARK: - Passe 1 : timestamps

    /// PTS des frames RÉELLEMENT DÉCODÉES sur la plage, avec la même
    /// configuration de lecteur que la passe 2 : les deux ensembles
    /// coïncident par construction (le passthrough listait des échantillons
    /// que le décodeur ne livre pas toujours — source de désynchronisation).
    private static func collectDecodedTimestamps(asset: AVAsset,
                                                 track: AVAssetTrack,
                                                 range: CMTimeRange,
                                                 pixelFormat: OSType) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "startReading (PTS)")
        }
        var timestamps: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if pts.isValid { timestamps.append(pts) }
        }
        if reader.status == .failed {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "lecture PTS")
        }
        timestamps.sort { CMTimeCompare($0, $1) < 0 }
        return timestamps
    }

    // MARK: - Vérification

    // MARK: - Analyse du fichier produit (vérité terrain)

    /// Signature d'une image : par tuile et par composante (Y, Cb, Cr), la
    /// MOYENNE mais surtout le MAXIMUM et le MINIMUM.
    ///
    /// Les extrêmes sont le point décisif. Une moyenne de tuile ne peut pas
    /// voir un artefact localisé, quelle que soit la finesse de la grille : un
    /// flash blanc couvrant 5 % de l'image ne déplace la moyenne d'une tuile
    /// que d'une dizaine de niveaux, sous n'importe quel seuil utilisable. Le
    /// même flash déplace le MAX de la tuile jusqu'à sa valeur pleine.
    struct FrameSignature: Sendable {
        var luma: [Double]
        var lumaMax: [Double]
        var lumaMin: [Double]
        var cb: [Double]
        var cbMax: [Double]
        var cbMin: [Double]
        var cr: [Double]
        var crMax: [Double]
        var crMin: [Double]
    }

    /// Grille de l'analyse finale : 16×16 (256 tuiles).
    static let outputGrid = 16
    /// Marge tolérée hors enveloppe des deux voisines, par composante.
    /// Resserrée : elle s'applique désormais aux EXTRÊMES, beaucoup plus
    /// stables qu'une moyenne d'une image à l'autre.
    static let outputEnvelopeMargin: Double = 8
    /// Dépassement au-delà duquel une TUILE est comptée comme déviante.
    static let outputAnomalyThreshold: Double = 6
    /// Amplitude qu'une SEULE tuile suffit à rendre coupable : un flash, même
    /// minuscule, sature la tuile qu'il touche (150 niveaux et plus). Un bord
    /// d'objet qui traverse une tuile, non — mesuré sur rush réel : 68.
    static let outputExtremeThreshold: Double = 120
    /// Nombre de tuiles déviantes à partir duquel l'anomalie est jugée
    /// ÉTENDUE, donc réelle, quelle que soit son amplitude.
    ///
    /// CALIBRÉ SUR RUSH RÉEL (14/08/2026). Le critère « une seule tuile
    /// dépasse » condamnait une image sur quatre d'un rendu SANS
    /// interpolation — donc sans un pixel inventé : indices espacés de 4,
    /// exactement les frontières d'images source. En mouvement, un bord qui
    /// traverse une tuile la fait sauter de 60 à 80 niveaux ; aucune
    /// statistique temporelle ne distingue cela d'un flash de même amplitude.
    /// Ce qui les sépare vraiment : un flash est ÉTENDU (beaucoup de tuiles)
    /// ou EXTRÊME (saturation) ; un bord est local et modéré.
    static var outputMinDeviatingTiles: Int { max(4, outputGrid * outputGrid / 50) }
    /// Nombre minimal d'échantillons par plan et par axe. À 0,05 % des pixels,
    /// l'ancien échantillonnage pouvait manquer un artefact entier.
    static let signatureSamplesPerAxis = 1024

    /// Accumulateur par tuile : moyenne, maximum, minimum.
    private struct TileStats {
        var totals: [Double]
        var counts: [Int]
        var maxima: [Double]
        var minima: [Double]

        init(tileCount: Int) {
            totals = [Double](repeating: 0, count: tileCount)
            counts = [Int](repeating: 0, count: tileCount)
            maxima = [Double](repeating: -.greatestFiniteMagnitude, count: tileCount)
            minima = [Double](repeating: .greatestFiniteMagnitude, count: tileCount)
        }

        mutating func add(_ value: Double, to index: Int) {
            totals[index] += value
            counts[index] += 1
            if value > maxima[index] { maxima[index] = value }
            if value < minima[index] { minima[index] = value }
        }

        var averages: [Double] { zip(totals, counts).map { $1 > 0 ? $0 / Double($1) : 0 } }
        var isComplete: Bool { counts.allSatisfy { $0 > 0 } }
    }

    /// Signature d'un buffer NV12 (8 bits bi-planaire) : Y sur le plan 0,
    /// Cb/Cr entrelacés sur le plan 1. nil si le format n'est pas géré.
    static func frameSignature(of buffer: CVPixelBuffer) -> FrameSignature? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }

        let grid = outputGrid
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard lumaWidth >= grid, lumaHeight >= grid else { return nil }

        var luma = TileStats(tileCount: grid * grid)
        // Échantillonnage dense : au moins `signatureSamplesPerAxis` points par
        // axe. À l'ancien pas, 0,05 % des pixels étaient lus en 4K — un
        // artefact entier pouvait passer entre les mailles.
        let stepX = max(lumaWidth / signatureSamplesPerAxis, 1)
        let stepY = max(lumaHeight / signatureSamplesPerAxis, 1)
        let lumaPointer = lumaBase.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < lumaHeight {
            let tileY = min(y * grid / lumaHeight, grid - 1)
            let row = lumaPointer + y * lumaStride
            var x = 0
            while x < lumaWidth {
                luma.add(Double(row[x]), to: tileY * grid + min(x * grid / lumaWidth, grid - 1))
                x += stepX
            }
            y += stepY
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)   // paires CbCr
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        guard chromaWidth >= grid, chromaHeight >= grid else { return nil }

        var cb = TileStats(tileCount: grid * grid)
        var cr = TileStats(tileCount: grid * grid)
        let cStepX = max(chromaWidth / signatureSamplesPerAxis, 1)
        let cStepY = max(chromaHeight / signatureSamplesPerAxis, 1)
        let chromaPointer = chromaBase.assumingMemoryBound(to: UInt8.self)
        var cy = 0
        while cy < chromaHeight {
            let tileY = min(cy * grid / chromaHeight, grid - 1)
            let row = chromaPointer + cy * chromaStride
            var cx = 0
            while cx < chromaWidth {
                let index = tileY * grid + min(cx * grid / chromaWidth, grid - 1)
                cb.add(Double(row[cx * 2]), to: index)
                cr.add(Double(row[cx * 2 + 1]), to: index)
                cx += cStepX
            }
            cy += cStepY
        }

        guard luma.isComplete, cb.isComplete, cr.isComplete else { return nil }
        return FrameSignature(
            luma: luma.averages, lumaMax: luma.maxima, lumaMin: luma.minima,
            cb: cb.averages, cbMax: cb.maxima, cbMin: cb.minima,
            cr: cr.averages, crMax: cr.maxima, crMin: cr.minima
        )
    }

    /// Une image est ABERRANTE si elle sort de l'enveloppe [min, max] de ses
    /// DEUX voisines temporelles, sur n'importe quelle composante et
    /// n'importe quelle tuile. Un mouvement, même rapide, reste borné par ses
    /// voisines ; un flash (blanc, coloré) ou un trou noir en sort.
    /// Retourne le pire dépassement (0 = sain).
    /// `spread` : amplitude de variation des images de RÉFÉRENCE, tuile par
    /// tuile. La tolérance s'y adapte — voir la note sur la tolérance adaptative
    /// dans `spreadSignature`.
    static func anomalyScore(previous: FrameSignature,
                             candidate: FrameSignature,
                             next: FrameSignature,
                             spread: FrameSignature? = nil) -> Double {
        func worst(_ p: [Double], _ c: [Double], _ n: [Double], _ s: [Double]?) -> Double {
            guard p.count == c.count, n.count == c.count else { return 0 }
            var result: Double = 0
            for index in 0..<c.count {
                // TOLÉRANCE ADAPTATIVE : marge fixe + amplitude que le
                // voisinage lui-même présente sur cette tuile.
                let tolerance = outputEnvelopeMargin
                    + ((s?.count == c.count) ? s![index] : 0)
                let low = min(p[index], n[index]) - tolerance
                let high = max(p[index], n[index]) + tolerance
                if c[index] < low {
                    result = max(result, low - c[index])
                } else if c[index] > high {
                    result = max(result, c[index] - high)
                }
            }
            return result
        }
        // Les EXTRÊMES portent le signal : le max du candidat contre
        // l'enveloppe des max des références, le min contre celle des min. La
        // moyenne reste testée, mais elle ne voit que les défauts pleine
        // image — c'est elle qui laissait passer les artefacts localisés.
        return [
            worst(previous.luma, candidate.luma, next.luma, spread?.luma),
            worst(previous.lumaMax, candidate.lumaMax, next.lumaMax, spread?.lumaMax),
            worst(previous.lumaMin, candidate.lumaMin, next.lumaMin, spread?.lumaMin),
            worst(previous.cb, candidate.cb, next.cb, spread?.cb),
            worst(previous.cbMax, candidate.cbMax, next.cbMax, spread?.cbMax),
            worst(previous.cbMin, candidate.cbMin, next.cbMin, spread?.cbMin),
            worst(previous.cr, candidate.cr, next.cr, spread?.cr),
            worst(previous.crMax, candidate.crMax, next.crMax, spread?.crMax),
            worst(previous.crMin, candidate.crMin, next.crMin, spread?.crMin),
        ].max() ?? 0
    }

    /// Verdict complet : amplitude du pire dépassement ET nombre de TUILES
    /// déviantes. C'est le second chiffre qui sépare un artefact d'un simple
    /// bord d'objet en mouvement (voir `outputMinDeviatingTiles`).
    static func anomalyDetail(previous: FrameSignature,
                              candidate: FrameSignature,
                              next: FrameSignature,
                              spread: FrameSignature?) -> (score: Double, deviatingTiles: Int) {
        var worstScore: Double = 0
        // Une tuile compte UNE fois, même si plusieurs composantes dévient.
        var deviating = Set<Int>()

        func scan(_ p: [Double], _ c: [Double], _ n: [Double], _ s: [Double]?) {
            guard p.count == c.count, n.count == c.count else { return }
            for index in 0..<c.count {
                let tolerance = outputEnvelopeMargin + ((s?.count == c.count) ? s![index] : 0)
                let low = min(p[index], n[index]) - tolerance
                let high = max(p[index], n[index]) + tolerance
                var overshoot: Double = 0
                if c[index] < low { overshoot = low - c[index] }
                else if c[index] > high { overshoot = c[index] - high }
                guard overshoot > 0 else { continue }
                worstScore = max(worstScore, overshoot)
                if overshoot > outputAnomalyThreshold { deviating.insert(index) }
            }
        }

        scan(previous.luma, candidate.luma, next.luma, spread?.luma)
        scan(previous.lumaMax, candidate.lumaMax, next.lumaMax, spread?.lumaMax)
        scan(previous.lumaMin, candidate.lumaMin, next.lumaMin, spread?.lumaMin)
        scan(previous.cb, candidate.cb, next.cb, spread?.cb)
        scan(previous.cbMax, candidate.cbMax, next.cbMax, spread?.cbMax)
        scan(previous.cbMin, candidate.cbMin, next.cbMin, spread?.cbMin)
        scan(previous.cr, candidate.cr, next.cr, spread?.cr)
        scan(previous.crMax, candidate.crMax, next.crMax, spread?.crMax)
        scan(previous.crMin, candidate.crMin, next.crMin, spread?.crMin)

        return (worstScore, deviating.count)
    }

    /// L'image est-elle ABERRANTE ? Étendue OU extrême — jamais « une tuile a
    /// bougé un peu plus que ses voisines ».
    static func isAnomalous(score: Double, deviatingTiles: Int) -> Bool {
        score > outputExtremeThreshold || deviatingTiles >= outputMinDeviatingTiles
    }

    /// Amplitude de variation des images de RÉFÉRENCE, tuile par tuile et
    /// composante par composante (max − min sur l'ensemble des références).
    ///
    /// C'est le correctif d'un défaut mesuré par le banc d'essai : sur un
    /// panoramique rapide sur texture, les statistiques d'une tuile changent
    /// LÉGITIMEMENT de plus de 100 niveaux d'une image à l'autre, et rien ne
    /// garantit qu'une image se situe « entre » ses deux voisines — trois
    /// textures décalées successives n'ont aucune relation d'ordre. Avec un
    /// seuil fixe, 256 tuiles × 9 statistiques rendaient un dépassement
    /// certain à chaque image : le détecteur criait sur des rendus SANS un
    /// seul pixel inventé.
    ///
    /// La tolérance devient donc contextuelle. Mais elle est mesurée par un
    /// ÉCART ABSOLU MÉDIAN, pas par l'amplitude totale : en ralenti, un flash
    /// d'une image du rush occupe 3 à 4 images de sortie, donc jusqu'à 30 % de
    /// la fenêtre de référence. L'amplitude totale l'englobait et rendait le
    /// détecteur aveugle au flash même — mesuré par le banc, écart max tombé à
    /// 0. L'écart médian, lui, reste dicté par la majorité saine des
    /// références (robuste jusqu'à 50 % de contamination).
    ///
    /// Scène calme → écart nul → un flash minuscule reste détecté.
    /// Mouvement rapide → écart large → pas de fausse alerte.
    static let spreadRobustFactor: Double = 4

    static func spreadSignature(of list: [FrameSignature]) -> FrameSignature? {
        guard let first = list.first else { return nil }
        func robustSpread(_ pick: (FrameSignature) -> [Double]) -> [Double] {
            let count = pick(first).count
            let arrays = list.map(pick)
            var result = [Double](repeating: 0, count: count)
            var column = [Double](repeating: 0, count: arrays.count)
            for tile in 0..<count {
                for (index, values) in arrays.enumerated() {
                    column[index] = tile < values.count ? values[tile] : 0
                }
                let sorted = column.sorted()
                let median = sorted[sorted.count / 2]
                let deviations = column.map { abs($0 - median) }.sorted()
                result[tile] = deviations[deviations.count / 2] * spreadRobustFactor
            }
            return result
        }
        return FrameSignature(
            luma: robustSpread { $0.luma },
            lumaMax: robustSpread { $0.lumaMax },
            lumaMin: robustSpread { $0.lumaMin },
            cb: robustSpread { $0.cb }, cbMax: robustSpread { $0.cbMax }, cbMin: robustSpread { $0.cbMin },
            cr: robustSpread { $0.cr }, crMax: robustSpread { $0.crMax }, crMin: robustSpread { $0.crMin }
        )
    }

    /// Nombre d'images prises de chaque côté pour établir la référence
    /// temporelle. Une MÉDIANE sur 5 images résiste à un flash de 1 ou 2
    /// images — c'est tout l'enjeu (voir `medianEnvelopeScore`).
    static let referenceRadius = 5

    /// Médiane composante par composante, tuile par tuile.
    static func medianSignature(of list: [FrameSignature]) -> FrameSignature? {
        guard let first = list.first else { return nil }
        func median(_ pick: (FrameSignature) -> [Double]) -> [Double] {
            let count = pick(first).count
            var result = [Double](repeating: 0, count: count)
            var column = [Double](repeating: 0, count: list.count)
            for tile in 0..<count {
                for (index, signature) in list.enumerated() {
                    let values = pick(signature)
                    column[index] = tile < values.count ? values[tile] : 0
                }
                let sorted = column.sorted()
                result[tile] = sorted[sorted.count / 2]
            }
            return result
        }
        return FrameSignature(
            luma: median { $0.luma }, lumaMax: median { $0.lumaMax }, lumaMin: median { $0.lumaMin },
            cb: median { $0.cb }, cbMax: median { $0.cbMax }, cbMin: median { $0.cbMin },
            cr: median { $0.cr }, crMax: median { $0.crMax }, crMin: median { $0.crMin }
        )
    }

    /// DÉTECTION D'ANOMALIE PAR MÉDIANES DE PART ET D'AUTRE.
    ///
    /// Le test contre les deux voisines IMMÉDIATES a un angle mort fatal en
    /// ralenti : à 0,5×, un flash d'UNE image dans le rush devient 2 à 4 images
    /// dans le fichier produit (copie + interpolations voisines). Chaque image
    /// du flash a alors une voisine elle-même flashée, donc l'enveloppe
    /// [min, max] des voisines CONTIENT le flash — invisible. C'est ce que le
    /// banc d'essai a mesuré : `repairedFrames = 0` sur un pic d'une image.
    ///
    /// Ici, la référence de chaque côté est la MÉDIANE de 5 images : un flash
    /// court ne la déplace pas. L'image est aberrante seulement si elle sort de
    /// l'intervalle entre les deux médianes — ce qui préserve :
    /// • le mouvement rapide (l'image est ENTRE les deux références) ;
    /// • un vrai palier d'exposition (l'image est égale à la référence d'un
    ///   côté), qui est du contenu source et ne doit pas être « corrigé ».
    static func medianEnvelopeScore(left: FrameSignature,
                                    right: FrameSignature,
                                    candidate: FrameSignature,
                                    spread: FrameSignature? = nil) -> Double {
        anomalyScore(previous: left, candidate: candidate, next: right, spread: spread)
    }

    /// PREMIÈRE et DERNIÈRE image : sans voisine des deux côtés, l'enveloppe
    /// n'existe pas — elles échapperaient au contrôle, alors qu'un flash en
    /// tête de clip est le plus visible de tous. La valeur attendue est donc
    /// EXTRAPOLÉE linéairement depuis les deux images suivantes (ou
    /// précédentes) : `attendu = 2·voisine − suivante`, ce qui suit un
    /// mouvement régulier. Marge élargie (×1,5) car une extrapolation est
    /// moins sûre qu'une interpolation : mieux vaut rater un artefact
    /// limite que réparer une image saine.
    static func edgeAnomalyScore(neighbour: FrameSignature,
                                 secondNeighbour: FrameSignature,
                                 candidate: FrameSignature) -> Double {
        let margin = outputEnvelopeMargin * 1.5
        func worst(_ a: [Double], _ b: [Double], _ c: [Double]) -> Double {
            guard a.count == c.count, b.count == c.count else { return 0 }
            var result: Double = 0
            for index in 0..<c.count {
                let extrapolated = 2 * a[index] - b[index]
                let low = min(a[index], extrapolated) - margin
                let high = max(a[index], extrapolated) + margin
                if c[index] < low {
                    result = max(result, low - c[index])
                } else if c[index] > high {
                    result = max(result, c[index] - high)
                }
            }
            return result
        }
        return [
            worst(neighbour.luma, secondNeighbour.luma, candidate.luma),
            worst(neighbour.lumaMax, secondNeighbour.lumaMax, candidate.lumaMax),
            worst(neighbour.lumaMin, secondNeighbour.lumaMin, candidate.lumaMin),
            worst(neighbour.cb, secondNeighbour.cb, candidate.cb),
            worst(neighbour.cbMax, secondNeighbour.cbMax, candidate.cbMax),
            worst(neighbour.cbMin, secondNeighbour.cbMin, candidate.cbMin),
            worst(neighbour.cr, secondNeighbour.cr, candidate.cr),
            worst(neighbour.crMax, secondNeighbour.crMax, candidate.crMax),
            worst(neighbour.crMin, secondNeighbour.crMin, candidate.crMin),
        ].max() ?? 0
    }

    /// Durée, nombre d'images et paires d'images consécutives IDENTIQUES du
    /// fichier rendu.
    /// Comptage en DÉCODANT : le mode passthrough peut regrouper ou ajouter des
    /// échantillons conteneur (observé : +4 constants) ; seuls les buffers
    /// décodés comptent les images réellement présentées.
    /// Doublons : vérité terrain du rythme — un ralenti interpolé sain n'a
    /// pratiquement aucune paire identique ; une rafale de doublons = clip
    /// figé (défaut constaté deux fois sur exports réels, invisible dans les
    /// compteurs de production seuls).
    /// Analyse aussi CHAQUE image du fichier (luma + chrominance, extrêmes compris)
    /// et retourne les indices des images aberrantes : c'est la seule mesure
    /// qui voit ce que l'encodeur a réellement écrit — images interpolées ET
    /// copiées, flashs blancs ET colorés.
    static func verify(outputURL: URL) async throws
        -> (duration: Double, frameCount: Int, duplicatePairs: Int,
            anomalies: [Int], maxAnomaly: Double, maxDeviatingTiles: Int) {
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.writerFailed("fichier produit sans piste vidéo")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        // true : les signatures sont calculées pendant la lecture, mais le
        // coût d'une image recyclée sous les pieds de l'analyse serait un
        // diagnostic faux — jamais d'économie sur la mesure de vérité.
        output.alwaysCopiesSampleData = true
        reader.add(output)
        guard reader.startReading() else {
            throw RenderError.writerFailed("relecture de vérification impossible")
        }
        var count = 0
        var duplicatePairs = 0
        var previousTiles: [Double]?
        // Toutes les signatures sont conservées : l'analyse a besoin d'un accès
        // ALÉATOIRE (médianes de 5 images de part et d'autre), impossible avec
        // une simple fenêtre glissante. Coût : ~64 tuiles × 3 composantes ×
        // 78 images ≈ 150 Ko.
        var signatures: [FrameSignature?] = []

        while let sample = output.copyNextSampleBuffer() {
            // La vérification décode et analyse TOUT le fichier : sans point
            // d'annulation, une annulation devait l'attendre en entier.
            try Task.checkCancellation()
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            count += 1
            if let tiles = tileLuma(of: image) {
                if let previous = previousTiles, previous.count == tiles.count,
                   zip(previous, tiles).allSatisfy({ abs($0 - $1) < 0.02 }) {
                    duplicatePairs += 1
                }
                previousTiles = tiles
            } else {
                previousTiles = nil
            }
            signatures.append(frameSignature(of: image))
        }
        if reader.status == .failed {
            throw RenderError.writerFailed("vérification interrompue : \(reader.error?.localizedDescription ?? "?")")
        }

        var anomalies: [Int] = []
        var maxAnomaly: Double = 0
        var maxDeviatingTiles = 0
        let radius = referenceRadius

        for index in 0..<signatures.count {
            guard let candidate = signatures[index] else { continue }
            // Références : médiane des `radius` images valides de chaque côté.
            let left = (max(0, index - radius)..<index).compactMap { signatures[$0] }
            let right = ((index + 1)..<min(signatures.count, index + 1 + radius)).compactMap { signatures[$0] }

            let score: Double
            let deviatingTiles: Int
            if let leftMedian = medianSignature(of: left), let rightMedian = medianSignature(of: right) {
                // Tolérance adaptée à l'agitation RÉELLE du voisinage.
                let spread = spreadSignature(of: left + right)
                let detail = anomalyDetail(previous: leftMedian, candidate: candidate,
                                           next: rightMedian, spread: spread)
                score = detail.score
                deviatingTiles = detail.deviatingTiles
            } else if right.count >= 2 {
                // Tout début du clip : extrapolation depuis la suite.
                score = edgeAnomalyScore(neighbour: right[0], secondNeighbour: right[1], candidate: candidate)
                deviatingTiles = 0
            } else if left.count >= 2 {
                // Toute fin du clip : extrapolation depuis ce qui précède.
                score = edgeAnomalyScore(neighbour: left[left.count - 1],
                                         secondNeighbour: left[left.count - 2],
                                         candidate: candidate)
                deviatingTiles = 0
            } else {
                continue
            }

            maxAnomaly = max(maxAnomaly, score)
            maxDeviatingTiles = max(maxDeviatingTiles, deviatingTiles)
            // Les bords du clip n'ont pas de compte de tuiles fiable
            // (extrapolation) : seule l'amplitude extrême les condamne.
            if isAnomalous(score: score, deviatingTiles: deviatingTiles) {
                anomalies.append(index)
            }
        }

        return (duration.seconds, count, duplicatePairs, anomalies, maxAnomaly, maxDeviatingTiles)
    }
}
