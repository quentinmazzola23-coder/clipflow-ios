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
