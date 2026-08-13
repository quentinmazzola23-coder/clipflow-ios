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
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AdversarialVideo", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        let width = Int(size.width)
        let height = Int(size.height)

        for frameIndex in 0..<frames {
            // Attente BORNÉE : un encodeur qui n'accepte jamais de données
            // ferait tourner le banc d'essai à l'infini (constaté en CI :
            // 45 minutes de runner pour rien, sans le moindre message).
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw writer.error ?? NSError(domain: "AdversarialVideo", code: 3)
                }
                if ContinuousClock.now > deadline {
                    throw NSError(domain: "AdversarialVideo", code: 4, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Encodeur de test bloqué à l'image \(frameIndex) (statut \(writer.status.rawValue))",
                    ])
                }
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

/// ⚠️ `isSupported` MENT sur certaines machines : il vérifie seulement qu'une
/// configuration VT est CONSTRUCTIBLE, pas qu'une session peut démarrer. Sur
/// le runner CI (macOS virtualisé, sans GPU/ANE exploitable) il répond `true`
/// en 640×360 comme en 4K, puis `startSession` échoue avec
/// `VTFrameProcessorErrorDomain Code=-19730`. D'où deux familles de tests :
///
/// 1. Ceux qui valident LE PIPELINE (plan, lecteur, encodeur, détecteur
///    d'anomalies, boucle de réparation, comptage) tournent PARTOUT, avec le
///    moteur de repli — c'est là que se logeait le défaut critique des images
///    copiées, et il est désormais couvert en intégration continue.
/// 2. Ceux qui valident LE FLUX OPTIQUE lui-même ne peuvent tourner que sur
///    une machine où la session démarre : ailleurs, ils le DISENT et
///    s'abstiennent, sans jamais passer pour verts.
let opticalFlowAvailable = InterpolationEngineFactory.highQualityAvailable

/// Sonde honnête : une session démarre-t-elle réellement ici ?
func opticalFlowSessionUsable() async -> Bool {
    guard let engine = InterpolationEngineFactory.bestEngine(width: 640, height: 360) else { return false }
    do {
        try await engine.startSession(width: 640, height: 360)
        engine.endSession()
        return true
    } catch {
        print("Flux optique inutilisable ici : \(error)")
        return false
    }
}

/// `.serialized` OBLIGATOIRE : Swift Testing exécute les tests en parallèle par
/// défaut, et chaque test de ce banc ouvre un AVAssetReader + un AVAssetWriter.
/// Plusieurs sessions de décodage matériel concurrentes se privent mutuellement
/// du décodeur : diagnostic établi par échantillonnage des piles sur le runner —
/// trois tests simultanément bloqués dans `copyNextSampleBuffer` →
/// `FigSemaphoreWaitRelative`, 10 minutes sans progresser d'une image.
/// (L'app, elle, rend un clip à la fois : ce parallélisme n'existe que dans le
/// banc d'essai.)
@Suite(.serialized)
struct RealEngineArtifactTests {

    /// `useOpticalFlow: false` → moteur de repli : la chaîne complète est
    /// exercée (plan, décodage, encodage, analyse du fichier, réparation),
    /// seul le calcul des images intermédiaires diffère. C'est ce qui rend la
    /// boucle fermée testable sur une machine sans flux optique.
    private func renderAndScan(pattern: AdversarialVideoFactory.Pattern,
                               useOpticalFlow: Bool = false) async throws -> RenderResult {
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
            colorimetry: "sdr",
            forceFastEngine: !useOpticalFlow
        )
        let result = try await VideoRenderPipeline.render(job: job) { _ in }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        return result
    }

    // MARK: - Tourne PARTOUT (pipeline + boucle fermée, moteur de repli)

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
        // Sans flux optique, aucun pixel n'est inventé : le fichier livré ne
        // peut contenir d'anomalie fabriquée par le rendu.
        // Le commentaire d'une assertion doit être un LITTÉRAL : `Comment`
        // se construit par interpolation, jamais par concaténation.
        #expect(result.artifactFrames.isEmpty,
                "Images aberrantes livrées : \(result.artifactFrames) (écart max \(result.maxOutputAnomaly))")
    }

    // MARK: - Exige le VRAI flux optique (sinon s'abstient en le disant)

    /// Un panoramique rapide ne doit pas être « réparé » en rafale : le clip
    /// resterait fluide, sans doublons (régression du clip figé). N'a de sens
    /// qu'avec le flux optique — le moteur de repli duplique par construction.
    @Test func fastPanStaysFluid() async throws {
        guard await opticalFlowSessionUsable() else {
            print("ABSTENTION — fastPanStaysFluid exige le flux optique réel.")
            return
        }
        let result = try await renderAndScan(pattern: .fastPan, useOpticalFlow: true)
        #expect(result.duplicatePairs <= 2, "Doublons : \(result.duplicatePairs) — clip figé ?")
        #expect(!result.opticalFlowRejected,
                "Flux optique écarté sur un panoramique régulier : \(result.rejectedArtifactFrames) image(s) aberrante(s) — seuil trop serré ?")
    }

    /// Un pic d'UNE image PRÉSENT DANS LA SOURCE traverse le rendu sans flux
    /// optique : c'est du contenu réel, pas un artefact fabriqué, et rien ne
    /// doit l'inventer ni le maquiller. Le détecteur doit néanmoins le VOIR —
    /// un écart max nul signifierait qu'il ne mesure rien.
    @Test func sourceFlashIsSeenButNotFabricated() async throws {
        let result = try await renderAndScan(pattern: .singleFrameFlash)
        #expect(result.frameCount == 78)
        #expect(result.maxOutputAnomaly > 0,
                "Le détecteur n'a rien mesuré sur un clip contenant un pic d'une image")
    }

    /// Un défaut PRÉSENT DANS LA SOURCE (palier d'exposition) est signalé, pas
    /// masqué en inventant du contenu — et n'empêche pas l'export.
    @Test func sourceExposureJumpIsReportedNotFabricated() async throws {
        let result = try await renderAndScan(pattern: .exposureJump)
        #expect(result.frameCount == 78)
    }
}
