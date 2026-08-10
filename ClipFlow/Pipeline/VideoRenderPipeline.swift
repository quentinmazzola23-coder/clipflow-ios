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

    /// Rendu complet d'un passage. `onProgress` ∈ [0;1], appelé hors MainActor.
    static func render(job: RenderJob,
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

        // Format de décodage — déterminé AVANT la passe 1 : les deux passes
        // doivent utiliser exactement la même configuration de lecteur.
        // CHAÎNE 8 BITS UNIFORME, y compris HLG : la tentative 10 bits mêlait
        // des copies x420 et des images interpolées au format propre du moteur
        // VT → une image sur deux avec une matrice couleur différente = flash
        // bleu à 60 fps. Tags couleur HLG conservés ; profondeur 10 bits
        // remise à une version validée sur appareil de bout en bout.
        let readerPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        // --- Passe 1 : timestamps des frames RÉELLEMENT DÉCODÉES. ---
        // (Le passthrough listait des échantillons conteneur que le décodeur
        // ne livre pas toujours — frame de frontière notamment — et tout
        // désalignement de liste faussait le rythme du clip. En décodant les
        // deux passes à l'identique, les ensembles coïncident par construction.)
        let sourcePTS = try collectDecodedTimestamps(
            asset: asset, track: track, range: decodeRange, pixelFormat: readerPixelFormat
        )
        guard sourcePTS.count >= 2 else {
            throw RenderError.readerFailed("plage source trop courte (\(sourcePTS.count) image(s))")
        }

        // --- Plan d'images exact. ---
        let (expectedFrames, exact) = TimeMath.outputFrameCount(final: job.finalDuration, fps: job.fps)
        _ = exact // une durée non divisible a déjà été signalée à l'utilisateur en amont
        let plan = try FramePlanner.plan(
            sourcePTS: sourcePTS,
            selectionStart: job.sourceRange.start,
            outputFrameCount: expectedFrames,
            fps: job.fps,
            speed: job.speed
        )

        // --- Moteur d'interpolation. ---
        // Qualité maximale exigée : si le flux optique VideoToolbox n'est pas
        // disponible et que des images intermédiaires sont nécessaires, l'export
        // ÉCHOUE explicitement — jamais de duplication d'images silencieuse.
        let needsInterpolation = plan.contains { if case .interpolate = $0 { return true } ; return false }
        let engine: FrameInterpolationEngine
        if job.forceFastEngine {
            engine = PassthroughRetimeEngine()
        } else if let highQuality = InterpolationEngineFactory.bestEngine(width: encodeWidth, height: encodeHeight) {
            engine = highQuality
        } else if needsInterpolation {
            throw RenderError.interpolationUnavailable
        } else {
            // Aucune interpolation requise (ex. source 120 fps → 0,5× 60 fps) :
            // toutes les images finales sont des copies exactes.
            engine = PassthroughRetimeEngine()
        }
        if needsInterpolation {
            try await engine.startSession(width: encodeWidth, height: encodeHeight)
        }
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
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "startReading")
        }

        // --- Writer. ---
        let outputURL = StorageManager.exportsDirectory.appendingPathComponent(job.outputFilename)
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let isHDR = isHDRContent
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
        // Colorimétrie préservée : primaires, transfert, matrice.
        writerSettings[AVVideoColorPropertiesKey] = isHDR
            ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            : [
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

        // Regroupe les interpolations consécutives partageant la même paire
        // source pour soumettre toutes les phases en un seul appel moteur.
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
                try await appendWhenReady(buffer, pts: TimeMath.outputPTS(frameIndex: outputFrameIndex, fps: job.fps))
                copiedCount += 1
                outputFrameIndex += 1
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
                let produced = try await engine.interpolate(
                    previous: prev,
                    previousPTS: sourcePTS[prevIdx],
                    next: next,
                    nextPTS: sourcePTS[nextIdx],
                    phases: phases
                )
                // FAILSAFE ANTI-ARTEFACT v2 : le flux optique produit parfois
                // des images aberrantes (flash global OU zone noire partielle).
                // Chaque image interpolée est comparée à ses deux sources sur
                // une GRILLE de tuiles 4×4 (détecte les artefacts localisés)
                // + moyenne globale, en 8 comme en 10 bits. Déviation anormale
                // → remplacement par la source la plus proche (micro-duplication
                // invisible plutôt qu'un défaut visible).
                let tilesPrev = Self.tileLuma(of: prev)
                let tilesNext = Self.tileLuma(of: next)
                for (phaseIndex, buffer) in produced.enumerated() {
                    var outputBuffer = buffer
                    if let tp = tilesPrev, let tn = tilesNext,
                       let tb = Self.tileLuma(of: buffer),
                       tp.count == tb.count, tn.count == tb.count {
                        let phase = Double(phases[phaseIndex])
                        var worstTileDeviation: Double = 0
                        var globalExpected: Double = 0
                        var globalActual: Double = 0
                        for tileIndex in 0..<tb.count {
                            let expected = tp[tileIndex] * (1 - phase) + tn[tileIndex] * phase
                            worstTileDeviation = max(worstTileDeviation, abs(tb[tileIndex] - expected))
                            globalExpected += expected
                            globalActual += tb[tileIndex]
                        }
                        let globalDeviation = abs(globalActual - globalExpected) / Double(tb.count)
                        maxLumaDeviation = max(maxLumaDeviation, worstTileDeviation)
                        // Tuile isolée très déviante (artefact local) OU dérive
                        // globale (flash) → image écartée.
                        if worstTileDeviation > 55 || globalDeviation > 40 {
                            outputBuffer = phase < 0.5 ? prev : next
                            correctedCount += 1
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
                    Self.propagateColorAttachments(from: prev, to: outputBuffer)
                    try await appendWhenReady(outputBuffer, pts: TimeMath.outputPTS(frameIndex: outputFrameIndex, fps: job.fps))
                    interpolatedCount += 1
                    outputFrameIndex += 1
                }
                entryIndex = lookahead
            }
            onProgress(Double(outputFrameIndex) / Double(expectedFrames))
        }

        reader.cancelReading()
        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "finishWriting")
        }

        // --- Vérification du fichier produit. ---
        let (verifiedDuration, verifiedCount) = try await verify(outputURL: outputURL)
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
            uncheckedInterpolatedFrames: uncheckedInterpolatedFrames
        )
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

    /// Luminance moyenne (échelle 0-255) par tuile d'une grille 4×4 du plan Y.
    /// Gère les formats bi-planaires 8 bits ET 10 bits (HDR HLG : mots 16 bits
    /// alignés à gauche → 8 bits de poids fort). nil si format non géré.
    static func tileLuma(of buffer: CVPixelBuffer) -> [Double]? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
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

    /// Durée et nombre d'images du fichier rendu.
    /// Comptage en DÉCODANT : le mode passthrough peut regrouper ou ajouter des
    /// échantillons conteneur (observé : +4 constants) ; seuls les buffers
    /// décodés comptent les images réellement présentées.
    static func verify(outputURL: URL) async throws -> (duration: Double, frameCount: Int) {
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.writerFailed("fichier produit sans piste vidéo")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw RenderError.writerFailed("relecture de vérification impossible")
        }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        if reader.status == .failed {
            throw RenderError.writerFailed("vérification interrompue : \(reader.error?.localizedDescription ?? "?")")
        }
        return (duration.seconds, count)
    }
}
