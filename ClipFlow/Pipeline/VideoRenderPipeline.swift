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

        // --- Passe 1 : timestamps réels, sans décodage (passthrough). ---
        let sourcePTS = try collectPresentationTimestamps(asset: asset, track: track, range: decodeRange)
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
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = decodeRange
        var readerSettings: [String: Any] = engine.sourcePixelBufferAttributes ?? [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        readerSettings[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
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

        let isHDR = (job.colorimetry == "hlg")
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
            if isHDR {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            }
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
        var outputFrameIndex = 0

        /// Avance le décodeur jusqu'à l'index demandé (séquentiel strict).
        /// Les images décodées avant le premier timestamp attendu (pré-roll
        /// éventuel du décodeur) sont ignorées pour rester aligné avec la
        /// liste de timestamps de la passe 1.
        let firstExpectedPTS = sourcePTS[0]
        func advanceTo(index: Int) throws {
            while sourceIndex < index {
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    throw RenderError.readerFailed("fin de flux prématurée (image \(index))")
                }
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if CMTimeCompare(pts, CMTimeSubtract(firstExpectedPTS, FramePlanner.matchTolerance)) < 0 {
                    continue // pré-roll : avant la plage attendue
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
                // FAILSAFE ANTI-FLASH : le flux optique produit parfois une
                // image aberrante (flash blanc/noir). Chaque image interpolée
                // est comparée en luminance à ses deux sources ; si elle dévie
                // anormalement, elle est remplacée par la source la plus proche
                // (micro-duplication invisible plutôt qu'un éclair).
                let lumaPrev = Self.averageLuma(of: prev)
                let lumaNext = Self.averageLuma(of: next)
                for (phaseIndex, buffer) in produced.enumerated() {
                    var outputBuffer = buffer
                    if let lp = lumaPrev, let ln = lumaNext,
                       let lb = Self.averageLuma(of: buffer) {
                        let phase = Double(phases[phaseIndex])
                        let expected = lp * (1 - phase) + ln * phase
                        if abs(lb - expected) > 40 {
                            outputBuffer = phase < 0.5 ? prev : next
                            correctedCount += 1
                        }
                    }
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
            correctedFrames: correctedCount
        )
    }

    // MARK: - Failsafe anti-flash

    /// Luminance moyenne (0-255) du plan Y d'un buffer 4:2:0 bi-planaire 8 bits,
    /// échantillonné grossièrement (1 pixel sur 32). nil si format non géré —
    /// dans ce cas le failsafe se désactive silencieusement.
    static func averageLuma(of buffer: CVPixelBuffer) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            let row = pointer + y * stride
            while x < width {
                total += Int(row[x])
                count += 1
                x += 32
            }
            y += 32
        }
        guard count > 0 else { return nil }
        return Double(total) / Double(count)
    }

    // MARK: - Passe 1 : timestamps

    /// Lit les PTS de la plage sans décoder (passthrough). Les échantillons
    /// arrivent en ordre de DÉCODAGE — tri croissant appliqué.
    private static func collectPresentationTimestamps(asset: AVAsset,
                                                      track: AVAssetTrack,
                                                      range: CMTimeRange) throws -> [CMTime] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // passthrough
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw RenderError.readerFailed(reader.error?.localizedDescription ?? "startReading (PTS)")
        }
        var timestamps: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            // FILTRAGE STRICT à la plage : en passthrough, le reader livre
            // aussi les échantillons de pré-roll depuis l'image clé précédant
            // la plage. Sans ce filtre, la liste de timestamps est décalée par
            // rapport à la passe décodée → les premières images de sortie
            // pointaient sur de mauvaises images sources (début « lent » puis
            // accélération brutale).
            if pts.isValid, CMTimeRangeContainsTime(range, time: pts) {
                timestamps.append(pts)
            }
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
