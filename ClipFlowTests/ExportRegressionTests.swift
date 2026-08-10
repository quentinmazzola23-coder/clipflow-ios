//
//  ExportRegressionTests.swift
//  ClipFlowTests
//
//  Non-régression des deux bugs d'export corrigés :
//  1. « début lent puis accélération » — désalignement de la liste de
//     timestamps (pré-roll passthrough depuis l'image clé précédente) ;
//  2. flashs d'interpolation — mesure de luminance du failsafe anti-flash.
//

import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import ClipFlow

struct AverageLumaTests {

    /// Buffer NV12 dont le plan Y est rempli d'une valeur constante.
    private func makeNV12Buffer(luma: UInt8, width: Int = 128, height: Int = 96) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
            memset(base, Int32(luma), stride * planeHeight)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func measuresDarkAndBrightPlanes() throws {
        let dark = try makeNV12Buffer(luma: 20)
        let bright = try makeNV12Buffer(luma: 200)
        let darkLuma = try #require(VideoRenderPipeline.averageLuma(of: dark))
        let brightLuma = try #require(VideoRenderPipeline.averageLuma(of: bright))
        #expect(abs(darkLuma - 20) < 1)
        #expect(abs(brightLuma - 200) < 1)
        // Le seuil anti-flash (40) doit séparer nettement ces deux mondes :
        // une image « flash » claire au milieu de sombres dévie de ~180.
        #expect(brightLuma - darkLuma > 40)
    }

    @Test func unsupportedFormatReturnsNil() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_422YpCbCr8, nil, &buffer)
        let exotic = try #require(buffer)
        // Format non géré → failsafe désactivé proprement (nil), pas de faux calcul.
        #expect(VideoRenderPipeline.averageLuma(of: exotic) == nil)
    }

    /// Chaîne principale BGRA : luma mesurée sur pixels RGB connus.
    @Test func measuresBGRALuma() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let bgra = try #require(buffer)
        CVPixelBufferLockBaseAddress(bgra, [])
        if let base = CVPixelBufferGetBaseAddress(bgra) {
            // Gris uniforme R=G=B=180 → luma ≈ 180.
            let stride = CVPixelBufferGetBytesPerRow(bgra)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<64 {
                for x in 0..<64 {
                    let p = pointer + y * stride + x * 4
                    p[0] = 180; p[1] = 180; p[2] = 180; p[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])
        let luma = try #require(VideoRenderPipeline.averageLuma(of: bgra))
        #expect(abs(luma - 180) < 2)
    }
}

/// Non-régression du failsafe v3 (test d'ENVELOPPE) : le v2 comparait chaque
/// tuile à la MOYENNE des deux sources et rejetait en rafale les interpolations
/// légitimes des panoramiques rapides → doublons → clip quasi figé puis saut
/// de rattrapage (constaté sur export réel du 2026-08-10).
struct EnvelopeFailsafeTests {

    /// Panoramique rapide : l'interpolée colle à la source suivante (le contenu
    /// s'est déplacé), très loin de la moyenne — elle doit être ACCEPTÉE.
    /// (L'ancien test « écart à la moyenne » : |230 − 140| = 90 > 55 → rejet.)
    @Test func fastPanInterpolationIsAccepted() {
        let previous = Array(repeating: 40.0, count: 16)
        let next = Array(repeating: 240.0, count: 16)
        let candidate = Array(repeating: 230.0, count: 16)
        #expect(VideoRenderPipeline.envelopeOvershoot(previous: previous, next: next, candidate: candidate) == 0)
    }

    /// Bruit d'interpolation léger hors plage : couvert par la marge, accepté.
    @Test func noiseWithinMarginIsAccepted() {
        let previous = Array(repeating: 100.0, count: 16)
        let next = Array(repeating: 120.0, count: 16)
        let candidate = Array(repeating: 138.0, count: 16)   // max + 18 < marge 26
        let overshoot = VideoRenderPipeline.envelopeOvershoot(previous: previous, next: next, candidate: candidate)
        #expect(overshoot <= VideoRenderPipeline.envelopeRejectThreshold)
    }

    /// Flash blanc global : très au-dessus du max des deux sources → rejet.
    @Test func whiteFlashIsRejected() {
        let previous = Array(repeating: 100.0, count: 16)
        let next = Array(repeating: 120.0, count: 16)
        let candidate = Array(repeating: 220.0, count: 16)
        let overshoot = VideoRenderPipeline.envelopeOvershoot(previous: previous, next: next, candidate: candidate)
        #expect(overshoot > VideoRenderPipeline.envelopeRejectThreshold)
    }

    /// Trou noir LOCALISÉ : une seule tuile aberrante suffit à écarter l'image.
    @Test func localizedBlackHoleIsRejected() {
        let previous = Array(repeating: 100.0, count: 16)
        let next = Array(repeating: 90.0, count: 16)
        var candidate = Array(repeating: 95.0, count: 16)
        candidate[5] = 8   // zone noire sur une tuile
        let overshoot = VideoRenderPipeline.envelopeOvershoot(previous: previous, next: next, candidate: candidate)
        #expect(overshoot > VideoRenderPipeline.envelopeRejectThreshold)
    }
}

/// Disjoncteur anti-rafale : un artefact réel est isolé ; remplacer en rafale
/// fige le clip (défaut pire). Constaté deux fois sur exports réels.
struct FailsafeCircuitBreakerTests {

    /// Artefact isolé : remplacement appliqué normalement.
    @Test func isolatedArtifactIsReplaced() {
        #expect(VideoRenderPipeline.failsafeShouldReplace(
            correctedSoFar: 0, maxCorrections: 11, consecutiveRejectedGroups: 0
        ))
        #expect(VideoRenderPipeline.failsafeShouldReplace(
            correctedSoFar: 1, maxCorrections: 11, consecutiveRejectedGroups: 1
        ))
    }

    /// Troisième groupe consécutif rejeté : le failsafe se trompe — sortie
    /// moteur acceptée telle quelle (pas de rafale de doublons).
    @Test func consecutiveBurstIsNeutralized() {
        #expect(!VideoRenderPipeline.failsafeShouldReplace(
            correctedSoFar: 2, maxCorrections: 11, consecutiveRejectedGroups: 2
        ))
        #expect(!VideoRenderPipeline.failsafeShouldReplace(
            correctedSoFar: 2, maxCorrections: 11, consecutiveRejectedGroups: 5
        ))
    }

    /// Budget par clip épuisé (15 % des images) : plus aucun remplacement.
    @Test func perClipBudgetIsEnforced() {
        #expect(!VideoRenderPipeline.failsafeShouldReplace(
            correctedSoFar: 11, maxCorrections: 11, consecutiveRejectedGroups: 0
        ))
    }
}

struct ColorAttachmentPropagationTests {

    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "test", code: Int(status))
        }
        return buffer
    }

    /// NON-RÉGRESSION « flash bleu » : les attachements colorimétriques de la
    /// source (matrice BT.2020…) doivent se propager aux images interpolées —
    /// sans eux, l'encodeur retombe sur BT.709 et teinte une image sur deux.
    @Test func colorAttachmentsPropagateToInterpolatedBuffers() throws {
        let source = try makeBuffer()
        let destination = try makeBuffer()
        CVBufferSetAttachment(
            source,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
        VideoRenderPipeline.propagateColorAttachments(from: source, to: destination)
        let value = CVBufferCopyAttachment(destination, kCVImageBufferYCbCrMatrixKey, nil)
        #expect((value as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String))
    }
}

struct ExportContentRegressionTests {

    /// Position (x) de la barre blanche dans la première image d'une vidéo :
    /// décode l'image 0 et cherche la colonne la plus lumineuse du plan Y.
    private func firstFrameBarX(of url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "test", code: 1)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw NSError(domain: "test", code: 2)
        }
        reader.cancelReading()

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            throw NSError(domain: "test", code: 3)
        }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let row = pointer + (height / 2) * stride
        var bestX = 0
        var bestValue: UInt8 = 0
        for x in 0..<width where row[x] > bestValue {
            bestValue = row[x]
            bestX = x
        }
        return bestX
    }

    /// NON-RÉGRESSION « début lent » : la PREMIÈRE image du fichier exporté
    /// doit montrer le contenu de la source AU DÉBUT DE LA SÉLECTION — pas
    /// une image antérieure amenée par le pré-roll du passthrough.
    /// Vidéo synthétique : barre blanche à x = 4 × index d'image.
    @Test func firstOutputFrameMatchesSelectionStartContent() async throws {
        let url = try await SyntheticVideoFactory.makeClip(fps: 60, frames: 180)
        defer { try? FileManager.default.removeItem(at: url) }

        // Sélection démarrant à 1,0 s = image source 60 → barre attendue à x ≈ 240.
        let job = RenderJob(
            sourceURL: url,
            sourceRange: CMTimeRange(
                start: CMTime(value: 60, timescale: 60),
                duration: TimeMath.sourceDuration(
                    final: ExactDuration(centiseconds: 130), speed: .half
                )
            ),
            finalDuration: ExactDuration(centiseconds: 130),
            speed: .half,
            fps: 60,
            codec: "h264",
            outputFilename: "regression-\(UUID().uuidString).mov",
            colorimetry: "sdr",
            forceFastEngine: true
        )
        let result = try await VideoRenderPipeline.render(job: job) { _ in }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.frameCount == 78)
        let barX = try await firstFrameBarX(of: result.outputURL)
        // Barre de 8 px de large à x = 240 ; l'encodage peut baver d'un ou
        // deux pixels. Une régression pré-roll décalerait de dizaines de px
        // (une image clé antérieure = barre bien plus à gauche).
        #expect(abs(barX - 240) <= 12, "barre trouvée à x=\(barX), attendu ≈240")
    }
}
