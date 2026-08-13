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
    /// finale (luma + chrominance, grille 8×8) — vérité terrain.
    var artifactFrames: [Int]
    /// Écart maximal hors enveloppe mesuré sur le fichier produit (toutes
    /// composantes) — instrumentation du seuil sur contenu réel.
    var maxOutputAnomaly: Double
    /// Images réparées par re-rendu (forcées en copie source).
    var repairedFrames: Int = 0
    /// Anomalies SUBSISTANTES après réparation = présentes dans la source
    /// (changement d'exposition brutal filmé par l'iPhone), pas fabriquées.
    var sourceAnomalyFrames: Int = 0
    /// Images forcées en réparation qui restent aberrantes : ni réparées, ni
    /// prouvées « source ». Interdit d'afficher « réparée » quand rien n'a
    /// changé.
    var unrepairedAnomalyFrames: Int = 0
    /// Images de sortie à réparer mais sans voisine décodée disponible
    /// (image 0 du clip) — signalées, jamais maquillées.
    var unrepairableCopyFrames: Int = 0
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

    /// Nombre maximal de passes de réparation (voir `render`).
    static let maxRepairPasses = 2

    /// Rendu d'un passage AVEC CONTRÔLE ET RÉPARATION EN BOUCLE FERMÉE.
    ///
    /// Le failsafe en ligne (enveloppe de luma pendant la production) est un
    /// filet de sécurité, pas une preuve : il ne voit ni la chrominance, ni
    /// les images copiées, ni ce que l'ENCODEUR a réellement écrit. Ici, le
    /// FICHIER PRODUIT est ré-analysé image par image (luma + chrominance,
    /// grille 8×8) ; toute image aberrante isolée est réparée par un nouveau
    /// rendu où cette image est forcée à l'image source la plus proche — puis
    /// le fichier est ré-analysé. Une anomalie qui SURVIT à cette réparation
    /// vient de la source elle-même (changement d'exposition de l'iPhone) :
    /// elle est signalée, jamais « corrigée » en inventant du contenu.
    ///
    /// Conséquence : un artefact produit par l'app ne peut plus atteindre la
    /// photothèque sans avoir été vu par la machine.
    static func render(job: RenderJob,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderResult {
        var forcedCopies: Set<Int> = []
        var result = try await renderPass(job: job, forcedCopyOutputIndices: forcedCopies, onProgress: onProgress)

        for pass in 1...maxRepairPasses {
            let suspects = result.artifactFrames
            // Rien à réparer, ou toutes les images suspectes sont DÉJÀ des
            // copies (donc du contenu source) : on s'arrête.
            let repairable = suspects.filter { !forcedCopies.contains($0) }
            if repairable.isEmpty { break }
            forcedCopies.formUnion(repairable)
            os_log("Artefacts détectés (%d) — passe de réparation %d",
                   log: signpostLog, type: .info, repairable.count, pass)
            result = try await renderPass(
                job: job, forcedCopyOutputIndices: forcedCopies, onProgress: onProgress
            )
        }

        // COMPTAGE HONNÊTE : « réparée » = image forcée en copie ET DISPARUE du
        // fichier final. Une image forcée qui reste aberrante n'a rien réparé —
        // compter `forcedCopies.count` affichait « 1 image réparée » alors que
        // le second rendu pouvait être strictement identique.
        let remaining = Set(result.artifactFrames)
        result.repairedFrames = forcedCopies.subtracting(remaining).count
        result.unrepairedAnomalyFrames = remaining.intersection(forcedCopies).count
        result.sourceAnomalyFrames = result.artifactFrames.count
        return result
    }

    /// Une passe de rendu. `forcedCopyOutputIndices` : indices d'images de
    /// SORTIE à produire par copie de la source la plus proche au lieu d'une
    /// interpolation (réparation ciblée).
    private static func renderPass(job: RenderJob,
                                   forcedCopyOutputIndices: Set<Int>,
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
        // Le décodeur convertit (et tone-mappe le HDR) vers du RGB écran ;
        // VT interpole des textures RGB ; l'encodeur reconvertit uniformément.
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
            if let reused = takeCachedEngine(width: encodeWidth, height: encodeHeight) {
                return Task { .success(reused) }
            }
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
        var engineIsReusable = false
        if let warmupTask {
            switch await warmupTask.value {
            case .success(let warmed):
                engine = warmed
                engineIsReusable = true
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
        // La session repart dans le cache après un rendu SAIN ; toute erreur
        // (état moteur incertain) la détruit.
        var renderCompleted = false
        defer {
            if engineIsReusable && renderCompleted {
                storeCachedEngine(engine, width: encodeWidth, height: encodeHeight)
            } else {
                engine.endSession()
            }
        }

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
        func appendWhenReady(_ buffer: CVPixelBuffer, pts: CMTime) async throws {
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw RenderError.writerFailed(writer.error?.localizedDescription ?? "append")
            }
        }

        /// Append + progression (l'ordre des appends suit STRICTEMENT le plan).
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
            /// Index de PLAN de la première image du groupe. Le plan contient
            /// exactement une entrée par image de sortie, donc index de plan ==
            /// index d'image de SORTIE : copies et interpolations partagent le
            /// MÊME référentiel que `forcedCopyOutputIndices`.
            let startIndex: Int
            let prev: CVPixelBuffer
            let next: CVPixelBuffer
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
        var unrepairableCopyFrames = 0
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
                let tilesPrev = Self.tileLuma(of: group.prev)
                let tilesNext = Self.tileLuma(of: group.next)
                var groupRejected = false
                for (phaseIndex, buffer) in group.produced.enumerated() {
                    var outputBuffer = buffer
                    // RÉPARATION CIBLÉE (prioritaire, indépendante du failsafe
                    // en ligne) : cette image de sortie a été jugée aberrante
                    // DANS LE FICHIER PRODUIT à la passe précédente — elle est
                    // remplacée par la source la plus proche, contenu réel
                    // garanti sans artefact.
                    if forcedCopyOutputIndices.contains(group.startIndex + phaseIndex) {
                        outputBuffer = group.phases[phaseIndex] < 0.5 ? group.prev : group.next
                        correctedCount += 1
                    } else if let tp = tilesPrev, let tn = tilesNext,
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
                    // CAUSE RACINE DU FLASH BLEU : les buffers de destination
                    // du moteur VT sortent du pool SANS attachements
                    // colorimétriques — l'encodeur les interprète en BT.709
                    // entre des copies étiquetées BT.2020/HLG → teinte bleue
                    // une image sur deux. Propagation systématique des
                    // attachements de la source vers chaque image interpolée.
                    Self.propagateColorAttachments(from: group.prev, to: outputBuffer)
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
                // RÉPARATION CIBLÉE DES COPIES.
                // Sans elle, une image de sortie aberrante produite par une
                // entrée `.copy` est INRÉPARABLE : la boucle relance un rendu
                // strictement identique (plan déterministe, mêmes pixels), puis
                // livre l'artefact étiqueté « anomalie de la source ». Or sur
                // un ralenti 0,5×, 25 à 50 % des images de sortie sont des
                // copies : la boucle fermée était aveugle sur la moitié du
                // fichier. Référentiel : `entryIndex` est l'index de l'image de
                // SORTIE (une entrée de plan = une image) — `outputFrameIndex`
                // serait FAUX ici, il retarde tant que des copies attendent
                // dans copyBacklog.
                var outputBuffer = buffer
                if forcedCopyOutputIndices.contains(entryIndex) {
                    if let replacement = previousBuffer {
                        // Duplication d'une image source RÉELLE voisine : aucun
                        // contenu inventé, un doublon (compté) plutôt qu'un
                        // flash visible.
                        outputBuffer = replacement
                        correctedCount += 1
                    } else {
                        // Première image du clip : pas de voisine gauche
                        // décodée. Signalée, jamais maquillée en « réparée ».
                        unrepairableCopyFrames += 1
                    }
                }
                if pendingGroup == nil {
                    try await appendOutput(outputBuffer)
                    copiedCount += 1
                } else {
                    // Ordre du plan : cette copie suit le groupe en attente.
                    // Borne de rétention (pression sur le pool du décodeur) :
                    // au-delà de 4 copies retenues, encodage immédiat du
                    // groupe (pur CPU, son résultat est déjà matérialisé).
                    copyBacklog.append(outputBuffer)
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
                pendingGroup = PendingInterpolation(
                    startIndex: entryIndex,
                    prev: prev, next: next, phases: groupPhases, produced: try await producedNow
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
        let (verifiedDuration, verifiedCount, duplicatePairs, anomalies, maxAnomaly) =
            try await verify(outputURL: outputURL)
        guard verifiedCount == expectedFrames else {
            throw RenderError.verificationFailed(expected: expectedFrames, actual: verifiedCount)
        }

        let fileSize = Int64((try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let elapsed = startedAt.duration(to: ContinuousClock.now)

        renderCompleted = true
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
            unrepairableCopyFrames: unrepairableCopyFrames
        )
    }

    // MARK: - Cache de session moteur

    /// Session moteur (VT) conservée entre deux clips consécutifs de mêmes
    /// dimensions — le démarrage coûte plusieurs centaines de millisecondes.
    /// La file de rendu est séquentielle, mais le slot est VERROUILLÉ quand
    /// même : une annulation qui draine pendant qu'un nouvel export démarre
    /// ne doit jamais pouvoir provoquer une course mémoire.
    /// (withLockUnchecked : le moteur n'est pas Sendable ; endSession
    /// TOUJOURS hors verrou.)
    private static let cachedEngineLock =
        OSAllocatedUnfairLock<(engine: FrameInterpolationEngine, width: Int, height: Int)?>(uncheckedState: nil)

    private static func takeCachedEngine(width: Int, height: Int) -> FrameInterpolationEngine? {
        let slot = cachedEngineLock.withLockUnchecked { state -> (engine: FrameInterpolationEngine, width: Int, height: Int)? in
            defer { state = nil }
            return state
        }
        guard let slot else { return nil }
        guard slot.width == width, slot.height == height else {
            slot.engine.endSession()
            return nil
        }
        return slot.engine
    }

    private static func storeCachedEngine(_ engine: FrameInterpolationEngine, width: Int, height: Int) {
        let evicted = cachedEngineLock.withLockUnchecked { state -> FrameInterpolationEngine? in
            let old = state?.engine
            state = (engine, width, height)
            return old
        }
        evicted?.endSession()
    }

    /// À appeler quand la file de rendu se vide : libère la session GPU
    /// conservée (mémoire, thermique).
    static func drainCachedEngine() {
        let drained = cachedEngineLock.withLockUnchecked { state -> FrameInterpolationEngine? in
            defer { state = nil }
            return state?.engine
        }
        drained?.endSession()
    }

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

    /// Signature d'une image : moyennes par tuile d'une grille 8×8, sur les
    /// TROIS composantes (Y, Cb, Cr). La chrominance est indispensable : un
    /// flash bleu/rose peut laisser la luma presque inchangée — l'ancien
    /// détecteur, purement luma, ne pouvait pas le voir.
    struct FrameSignature: Sendable {
        var luma: [Double]
        var cb: [Double]
        var cr: [Double]
    }

    /// Grille de l'analyse finale : 8×8 (64 tuiles) — quatre fois plus fine
    /// que le failsafe en ligne, un flash localisé sur ~1/64ᵉ de l'image ne
    /// peut plus se noyer dans une moyenne.
    static let outputGrid = 8
    /// Marge tolérée hors enveloppe des deux voisines, par composante.
    static let outputEnvelopeMargin: Double = 24
    /// Dépassement au-delà duquel l'image est déclarée aberrante.
    static let outputAnomalyThreshold: Double = 16

    /// Signature 8×8 d'un buffer NV12 (8 bits bi-planaire) : Y sur le plan 0,
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

        var lumaTotals = [Double](repeating: 0, count: grid * grid)
        var lumaCounts = [Int](repeating: 0, count: grid * grid)
        let stepX = max(lumaWidth / (grid * 16), 1)
        let stepY = max(lumaHeight / (grid * 16), 1)
        let lumaPointer = lumaBase.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < lumaHeight {
            let tileY = min(y * grid / lumaHeight, grid - 1)
            let row = lumaPointer + y * lumaStride
            var x = 0
            while x < lumaWidth {
                let index = tileY * grid + min(x * grid / lumaWidth, grid - 1)
                lumaTotals[index] += Double(row[x])
                lumaCounts[index] += 1
                x += stepX
            }
            y += stepY
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)   // paires CbCr
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        guard chromaWidth >= grid, chromaHeight >= grid else { return nil }

        var cbTotals = [Double](repeating: 0, count: grid * grid)
        var crTotals = [Double](repeating: 0, count: grid * grid)
        var chromaCounts = [Int](repeating: 0, count: grid * grid)
        let cStepX = max(chromaWidth / (grid * 16), 1)
        let cStepY = max(chromaHeight / (grid * 16), 1)
        let chromaPointer = chromaBase.assumingMemoryBound(to: UInt8.self)
        var cy = 0
        while cy < chromaHeight {
            let tileY = min(cy * grid / chromaHeight, grid - 1)
            let row = chromaPointer + cy * chromaStride
            var cx = 0
            while cx < chromaWidth {
                let index = tileY * grid + min(cx * grid / chromaWidth, grid - 1)
                cbTotals[index] += Double(row[cx * 2])
                crTotals[index] += Double(row[cx * 2 + 1])
                chromaCounts[index] += 1
                cx += cStepX
            }
            cy += cStepY
        }

        guard lumaCounts.allSatisfy({ $0 > 0 }), chromaCounts.allSatisfy({ $0 > 0 }) else { return nil }
        return FrameSignature(
            luma: zip(lumaTotals, lumaCounts).map { $0 / Double($1) },
            cb: zip(cbTotals, chromaCounts).map { $0 / Double($1) },
            cr: zip(crTotals, chromaCounts).map { $0 / Double($1) }
        )
    }

    /// Une image est ABERRANTE si elle sort de l'enveloppe [min, max] de ses
    /// DEUX voisines temporelles, sur n'importe quelle composante et
    /// n'importe quelle tuile. Un mouvement, même rapide, reste borné par ses
    /// voisines ; un flash (blanc, coloré) ou un trou noir en sort.
    /// Retourne le pire dépassement (0 = sain).
    static func anomalyScore(previous: FrameSignature,
                             candidate: FrameSignature,
                             next: FrameSignature) -> Double {
        func worst(_ p: [Double], _ c: [Double], _ n: [Double]) -> Double {
            guard p.count == c.count, n.count == c.count else { return 0 }
            var result: Double = 0
            for index in 0..<c.count {
                let low = min(p[index], n[index]) - outputEnvelopeMargin
                let high = max(p[index], n[index]) + outputEnvelopeMargin
                if c[index] < low {
                    result = max(result, low - c[index])
                } else if c[index] > high {
                    result = max(result, c[index] - high)
                }
            }
            return result
        }
        return max(
            worst(previous.luma, candidate.luma, next.luma),
            max(worst(previous.cb, candidate.cb, next.cb),
                worst(previous.cr, candidate.cr, next.cr))
        )
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
        return max(
            worst(neighbour.luma, secondNeighbour.luma, candidate.luma),
            max(worst(neighbour.cb, secondNeighbour.cb, candidate.cb),
                worst(neighbour.cr, secondNeighbour.cr, candidate.cr))
        )
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
    /// Analyse aussi CHAQUE image du fichier (luma + chrominance, grille 8×8)
    /// et retourne les indices des images aberrantes : c'est la seule mesure
    /// qui voit ce que l'encodeur a réellement écrit — images interpolées ET
    /// copiées, flashs blancs ET colorés.
    static func verify(outputURL: URL) async throws
        -> (duration: Double, frameCount: Int, duplicatePairs: Int, anomalies: [Int], maxAnomaly: Double) {
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
        // Fenêtre glissante de trois signatures pour le test d'enveloppe.
        var window: [(index: Int, signature: FrameSignature?)] = []
        var anomalies: [Int] = []
        var maxAnomaly: Double = 0
        // Les deux premières signatures sont conservées : la toute première
        // image n'a pas de voisine à gauche et se contrôle par extrapolation.
        var firstSignatures: [FrameSignature?] = []

        func record(index: Int, score: Double) {
            maxAnomaly = max(maxAnomaly, score)
            if score > outputAnomalyThreshold, !anomalies.contains(index) {
                anomalies.append(index)
            }
        }

        func evaluateMiddle() {
            guard window.count == 3,
                  let p = window[0].signature,
                  let c = window[1].signature,
                  let n = window[2].signature else { return }
            record(index: window[1].index, score: anomalyScore(previous: p, candidate: c, next: n))
        }

        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let index = count
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
            let signature = frameSignature(of: image)
            if firstSignatures.count < 3 { firstSignatures.append(signature) }
            window.append((index, signature))
            if window.count > 3 { window.removeFirst() }
            evaluateMiddle()
        }
        if reader.status == .failed {
            throw RenderError.writerFailed("vérification interrompue : \(reader.error?.localizedDescription ?? "?")")
        }

        // BORDS DU CLIP : la première et la dernière image n'ont jamais été
        // évaluées par la fenêtre glissante — contrôle par extrapolation.
        if firstSignatures.count >= 3,
           let first = firstSignatures[0], let second = firstSignatures[1], let third = firstSignatures[2] {
            record(index: 0, score: edgeAnomalyScore(
                neighbour: second, secondNeighbour: third, candidate: first
            ))
        }
        if window.count == 3,
           let last = window[2].signature, let before = window[1].signature, let beforeThat = window[0].signature {
            record(index: window[2].index, score: edgeAnomalyScore(
                neighbour: before, secondNeighbour: beforeThat, candidate: last
            ))
        }
        anomalies.sort()

        return (duration.seconds, count, duplicatePairs, anomalies, maxAnomaly)
    }
}
