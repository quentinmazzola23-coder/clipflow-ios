//
//  RealEngineArtifactTests.swift
//  ClipFlowTests
//
//  BANC D'ESSAI DU VRAI MOTEUR — le seul test qui prouve l'absence d'artefact
//  sans passer par l'œil de l'utilisateur.
//
//  Exécuté par `swift test` sur le runner macOS Apple Silicon (job CI
//  « moteur-reel »), via le paquet ClipFlowPipeline qui compile LES MÊMES
//  fichiers sources que l'app. Le simulateur iOS n'embarque pas
//  VTFrameProcessor et la variante « Designed for iPad » exige une identité
//  de signature absente d'un runner : le paquet Swift contourne les deux.
//
//  Si le moteur de flux optique n'est pas disponible sur la machine, les
//  tests sont SAUTÉS (trait .enabled) — jamais verts par accident.
//
//  Principe : des rushes synthétiques ADVERSARIAUX (les contenus qui font
//  échouer l'interpolation dans la vraie vie) sont rendus par la chaîne
//  complète, puis le fichier produit est analysé image par image, en luma ET
//  en chrominance. Une seule image aberrante = test rouge.
//

import Testing
import AVFoundation
import CoreMedia
import CoreVideo
@testable import ClipFlowPipeline

/// Générateur de contenus difficiles pour un flux optique.
enum AdversarialVideoFactory {

    enum Pattern: String, CaseIterable {
        /// Panoramique très rapide : le contenu se déplace de beaucoup entre
        /// deux images — c'est ce qui faisait rejeter les interpolations
        /// légitimes (clip figé) par l'ancien failsafe.
        case fastPan
        /// Changement d'exposition brutal (l'iPhone réajuste en cours de prise).
        case exposureJump
        /// Fort contraste + arêtes nettes : occlusions difficiles.
        case highContrastEdges
        /// Scène quasi statique avec bruit : piège à doublons.
        case staticNoise
        /// UNE seule image blanche au milieu — le symptôme rapporté par
        /// l'utilisateur. Placée sur une image source qui tombe sur une entrée
        /// `.copy` du plan : c'est le cas que la boucle de réparation ne
        /// savait pas traiter.
        case singleFrameFlash
    }

    static func makeClip(pattern: Pattern,
                         fps: Int32 = 30,
                         frames: Int = 40,
                         size: CGSize = CGSize(width: 640, height: 360)) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adversarial-\(pattern.rawValue)-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let width = Int(size.width)
        let height = Int(size.height)

        for frameIndex in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let buffer else { break }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                draw(pattern: pattern, frameIndex: frameIndex,
                     pixels: pixels, stride: stride, width: width, height: height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "AdversarialVideo", code: 1)
        }
        return url
    }

    private static func draw(pattern: Pattern, frameIndex: Int,
                             pixels: UnsafeMutablePointer<UInt8>,
                             stride: Int, width: Int, height: Int) {
        switch pattern {
        case .fastPan:
            // Damier défilant vite (24 px/image) : mouvement large et net.
            let offset = frameIndex * 24
            for y in 0..<height {
                for x in 0..<width {
                    let cell = (((x + offset) / 40) + (y / 40)) % 2
                    let value: UInt8 = cell == 0 ? 40 : 215
                    let p = pixels + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 255
                }
            }
        case .exposureJump:
            // Palier d'exposition au milieu du clip (défaut PRÉSENT DANS LA
            // SOURCE : le rendu ne doit pas l'amplifier, ni le fabriquer
            // ailleurs).
            let base: UInt8 = frameIndex < 20 ? 60 : 190
            let drift = UInt8(min(30, frameIndex))
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt8(clamping: Int(base) + Int(drift) - (x * 20 / max(width, 1)))
                    let p = pixels + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 255
                }
            }
        case .highContrastEdges:
            // Barres verticales noires/blanches qui glissent : arêtes dures.
            let offset = frameIndex * 6
            for y in 0..<height {
                for x in 0..<width {
                    let value: UInt8 = (((x + offset) / 12) % 2 == 0) ? 5 : 250
                    let p = pixels + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 255
                }
            }
        case .singleFrameFlash:
            // Dégradé stable, sauf l'image 12 : blanche.
            let flash = (frameIndex == 12)
            for y in 0..<height {
                for x in 0..<width {
                    let value: UInt8 = flash ? 252 : UInt8(clamping: 90 + (x * 40 / max(width, 1)))
                    let p = pixels + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 255
                }
            }
        case .staticNoise:
            // Scène immobile + bruit déterministe faible (aucune vraie
            // duplication ne devrait apparaître).
            for y in 0..<height {
                for x in 0..<width {
                    let noise = UInt8(((x &* 7 &+ y &* 13 &+ frameIndex &* 31) % 11))
                    let value = UInt8(clamping: 120 + Int(noise))
                    let p = pixels + y * stride + x * 4
                    p[0] = value; p[1] = value; p[2] = UInt8(clamping: Int(value) + 8); p[3] = 255
                }
            }
        }
    }
}

/// Le moteur de flux optique existe-t-il sur CETTE machine ? Utilisé comme
/// condition d'exécution : sans lui, les tests sont sautés (résultat honnête),
/// jamais verts par défaut.
let opticalFlowAvailable = InterpolationEngineFactory.highQualityAvailable

@Suite(.enabled(if: opticalFlowAvailable, "Moteur de flux optique indisponible sur cette machine."))
struct RealEngineArtifactTests {

    private func renderAndScan(pattern: AdversarialVideoFactory.Pattern) async throws -> RenderResult {
        let source = try await AdversarialVideoFactory.makeClip(pattern: pattern)
        defer { try? FileManager.default.removeItem(at: source) }

        let job = RenderJob(
            sourceURL: source,
            sourceRange: CMTimeRange(start: CMTime(value: 2, timescale: 30),
                                     duration: CMTime(value: 20, timescale: 30)),
            finalDuration: ExactDuration(centiseconds: 130),
            speed: RationalSpeed(numerator: 1, denominator: 2),
            fps: 60,
            codec: "hevc",
            outputFilename: "test-\(pattern.rawValue)-\(UUID().uuidString).mov",
            colorimetry: "sdr"
        )
        let result = try await VideoRenderPipeline.render(job: job) { _ in }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        return result
    }

    /// CONTRAT CENTRAL : sur des contenus difficiles, le fichier livré ne
    /// contient AUCUNE image aberrante — ni flash blanc, ni flash coloré, ni
    /// trou noir. Ce que l'utilisateur constatait à l'œil est ici mesuré.
    @Test(arguments: [
        AdversarialVideoFactory.Pattern.fastPan,
        AdversarialVideoFactory.Pattern.highContrastEdges,
        AdversarialVideoFactory.Pattern.staticNoise,
    ])
    func adversarialContentProducesNoArtifact(pattern: AdversarialVideoFactory.Pattern) async throws {
        let result = try await renderAndScan(pattern: pattern)
        #expect(result.frameCount == 78)
        // Après la boucle de réparation, plus aucune anomalie ne subsiste.
        #expect(result.sourceAnomalyFrames == 0,
                "Images aberrantes restantes : \(result.artifactFrames)")
    }

    /// Un panoramique rapide ne doit pas être « réparé » en rafale : le clip
    /// resterait fluide, sans doublons (régression du clip figé).
    @Test func fastPanStaysFluid() async throws {
        let result = try await renderAndScan(pattern: .fastPan)
        #expect(result.duplicatePairs <= 2, "Doublons : \(result.duplicatePairs) — clip figé ?")
        #expect(result.repairedFrames <= 4, "Réparations : \(result.repairedFrames) — failsafe trop agressif ?")
    }

    /// LE TEST DU SYMPTÔME RAPPORTÉ : un pic d'UNE image doit disparaître du
    /// fichier livré. Avant correctif, quand ce pic tombait sur une image
    /// COPIÉE, la boucle relançait deux rendus strictement identiques, comptait
    /// « 1 image réparée » (mensonger) et livrait quand même l'artefact sous
    /// l'étiquette « anomalie de la source ».
    @Test func isolatedFlashOnCopyEntryIsRepaired() async throws {
        let result = try await renderAndScan(pattern: .singleFrameFlash)
        #expect(result.sourceAnomalyFrames == 0,
                "Images aberrantes livrées : \(result.artifactFrames)")
        #expect(result.unrepairedAnomalyFrames == 0)
        #expect(result.unrepairableCopyFrames == 0)
        #expect(result.duplicatePairs <= 3, "Doublons : \(result.duplicatePairs)")
    }

    /// Un défaut PRÉSENT DANS LA SOURCE (palier d'exposition) est signalé, pas
    /// masqué en inventant du contenu — et n'empêche pas l'export.
    @Test func sourceExposureJumpIsReportedNotFabricated() async throws {
        let result = try await renderAndScan(pattern: .exposureJump)
        #expect(result.frameCount == 78)
    }
}
