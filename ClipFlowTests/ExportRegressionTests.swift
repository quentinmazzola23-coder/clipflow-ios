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

/// Détecteur d'anomalies du FICHIER PRODUIT (luma + chrominance, grille 8×8) :
/// c'est lui qui rend un artefact impossible à livrer — l'export est ré-rendu
/// tant qu'une image aberrante subsiste.
struct OutputAnomalyDetectorTests {

    /// Image unie : moyenne, max et min confondus sur chaque tuile.
    private func signature(luma: Double, cb: Double = 128, cr: Double = 128) -> VideoRenderPipeline.FrameSignature {
        let count = VideoRenderPipeline.outputGrid * VideoRenderPipeline.outputGrid
        return VideoRenderPipeline.FrameSignature(
            luma: Array(repeating: luma, count: count),
            lumaMax: Array(repeating: luma, count: count),
            lumaMin: Array(repeating: luma, count: count),
            cb: Array(repeating: cb, count: count),
            cbMax: Array(repeating: cb, count: count),
            cbMin: Array(repeating: cb, count: count),
            cr: Array(repeating: cr, count: count),
            crMax: Array(repeating: cr, count: count),
            crMin: Array(repeating: cr, count: count)
        )
    }

    /// Mouvement continu (panoramique) : aucune image n'est aberrante.
    @Test func smoothMotionHasNoAnomaly() {
        let score = VideoRenderPipeline.anomalyScore(
            previous: signature(luma: 60), candidate: signature(luma: 110), next: signature(luma: 160)
        )
        #expect(score == 0)
    }

    /// Flash blanc d'une seule image entre deux images sombres.
    @Test func singleWhiteFlashIsDetected() {
        let score = VideoRenderPipeline.anomalyScore(
            previous: signature(luma: 70), candidate: signature(luma: 245), next: signature(luma: 72)
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// Trou noir d'une seule image.
    @Test func singleBlackFrameIsDetected() {
        let score = VideoRenderPipeline.anomalyScore(
            previous: signature(luma: 120), candidate: signature(luma: 4), next: signature(luma: 118)
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// FLASH COLORÉ à LUMA CONSTANTE : invisible pour l'ancien détecteur
    /// (purement luma), détecté ici par la chrominance. C'est le cas des
    /// teintes bleues/roses constatées sur exports réels.
    @Test func colorFlashAtConstantLumaIsDetected() {
        let previous = signature(luma: 120, cb: 128, cr: 128)
        let candidate = signature(luma: 120, cb: 210, cr: 96)   // forte dérive bleue
        let next = signature(luma: 120, cb: 129, cr: 127)
        let score = VideoRenderPipeline.anomalyScore(previous: previous, candidate: candidate, next: next)
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
        // Preuve de l'angle mort comblé : sur la luma seule, l'écart est nul.
        #expect(VideoRenderPipeline.envelopeOvershoot(
            previous: previous.luma, next: next.luma, candidate: candidate.luma
        ) == 0)
    }

    /// Flash LOCALISÉ (une tuile sur 64) : la grille 8×8 le voit là où une
    /// moyenne globale le noierait.
    @Test func localizedFlashIsDetected() {
        let previous = signature(luma: 100)
        var candidate = signature(luma: 100)
        candidate.luma[27] = 250
        let next = signature(luma: 101)
        let score = VideoRenderPipeline.anomalyScore(previous: previous, candidate: candidate, next: next)
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// PREMIÈRE image du clip : sans voisine à gauche, elle échappait au
    /// contrôle — un flash en tête de clip est pourtant le plus visible.
    @Test func flashOnFirstFrameIsDetected() {
        let score = VideoRenderPipeline.edgeAnomalyScore(
            neighbour: signature(luma: 80), secondNeighbour: signature(luma: 84),
            candidate: signature(luma: 250)
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// Mouvement régulier au bord : l'extrapolation linéaire l'accepte
    /// (première image d'un panoramique, pas un artefact).
    @Test func linearMotionAtEdgeIsAccepted() {
        // Progression régulière 90 → 100 → 110 vue à l'envers depuis le bord.
        let score = VideoRenderPipeline.edgeAnomalyScore(
            neighbour: signature(luma: 100), secondNeighbour: signature(luma: 110),
            candidate: signature(luma: 90)
        )
        #expect(score == 0)
    }

    /// ANGLE MORT HISTORIQUE, mesuré par le banc d'essai : en ralenti 0,5×, un
    /// flash d'UNE image du rush devient 2 à 4 images dans le fichier produit.
    /// Chaque image du flash a alors une voisine elle-même flashée, donc le
    /// test contre les voisines IMMÉDIATES ne voit rien. La médiane de 5
    /// images de chaque côté, elle, n'est pas déplacée par un flash court.
    @Test func twoFrameFlashEscapesImmediateNeighboursButNotMedians() {
        let normal = signature(luma: 100)
        let flash = signature(luma: 250)
        // Voisines immédiates : l'une est flashée → enveloppe [100, 250] →
        // le flash est « dedans » → invisible.
        #expect(VideoRenderPipeline.anomalyScore(previous: normal, candidate: flash, next: flash) == 0)
        // Médianes de 5 images dont au plus 1 flashée → références saines.
        let leftMedian = try! #require(VideoRenderPipeline.medianSignature(
            of: [normal, normal, normal, normal, normal]
        ))
        let rightMedian = try! #require(VideoRenderPipeline.medianSignature(
            of: [flash, normal, normal, normal, normal]
        ))
        let score = VideoRenderPipeline.medianEnvelopeScore(
            left: leftMedian, right: rightMedian, candidate: flash
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// La médiane ignore un intrus isolé (c'est tout son intérêt ici).
    @Test func medianIgnoresSingleOutlier() {
        let normal = signature(luma: 100)
        let flash = signature(luma: 250)
        let median = try! #require(VideoRenderPipeline.medianSignature(
            of: [normal, flash, normal, normal, normal]
        ))
        #expect(abs(median.luma[0] - 100) < 0.5)
    }

    /// Un PALIER d'exposition (contenu source réel, changement durable) ne doit
    /// PAS être signalé : l'image est égale à la référence d'un des deux côtés.
    @Test func lastingExposureStepIsNotFlagged() {
        let before = signature(luma: 60)
        let after = signature(luma: 190)
        let leftMedian = try! #require(VideoRenderPipeline.medianSignature(
            of: [before, before, before, before, before]
        ))
        let rightMedian = try! #require(VideoRenderPipeline.medianSignature(
            of: [after, after, after, after, after]
        ))
        let score = VideoRenderPipeline.medianEnvelopeScore(
            left: leftMedian, right: rightMedian, candidate: after
        )
        #expect(score == 0)
    }

    /// Bruit de compression : sous le seuil, aucun faux positif (sinon chaque
    /// export déclencherait des re-rendus inutiles).
    @Test func compressionNoiseIsNotFlagged() {
        let score = VideoRenderPipeline.anomalyScore(
            previous: signature(luma: 100, cb: 130, cr: 126),
            candidate: signature(luma: 112, cb: 141, cr: 137),
            next: signature(luma: 101, cb: 131, cr: 127)
        )
        #expect(score <= VideoRenderPipeline.outputAnomalyThreshold)
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

    /// La source porte des attachements : ils sont recopiés, rien n'est compté
    /// comme non étiqueté.
    @Test func taggingCopiesSourceAttachments() throws {
        let source = try makeBuffer()
        let destination = try makeBuffer()
        CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        var untagged = 0
        VideoRenderPipeline.tagInterpolatedBuffer(destination, from: source, untagged: &untagged)
        let value = CVBufferCopyAttachment(destination, kCVImageBufferYCbCrMatrixKey, nil)
        #expect((value as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String))
        #expect(untagged == 0)
    }

    /// SOURCE SANS ATTACHEMENT : l'ancienne version laissait l'image
    /// interpolée NUE — l'encodeur la traitait en 709 sans conversion, entre
    /// des copies étiquetées et converties : une image sur deux teintée.
    /// Désormais 709 EXPLICITE, et l'événement est COMPTÉ.
    @Test func untaggedSourceFallsBackTo709AndIsCounted() throws {
        let source = try makeBuffer()
        let destination = try makeBuffer()
        var untagged = 0
        VideoRenderPipeline.tagInterpolatedBuffer(destination, from: source, untagged: &untagged)
        let matrix = CVBufferCopyAttachment(destination, kCVImageBufferYCbCrMatrixKey, nil)
        #expect((matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))
        let primaries = CVBufferCopyAttachment(destination, kCVImageBufferColorPrimariesKey, nil)
        #expect((primaries as? String) == (kCVImageBufferColorPrimaries_ITU_R_709_2 as String))
        #expect(untagged == 1, "Un défaut d'étiquetage doit être compté, jamais silencieux")
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

/// TEST DE RECEVABILITÉ DU DÉTECTEUR (§D du paquet de correction).
///
/// Tant que le détecteur ne voit pas un flash localisé, AUCUNE mesure de taux
/// d'artefact n'a de valeur — et c'est exactement ce qui a permis de livrer
/// pendant des semaines des exports défectueux avec un « contrôle OK ».
///
/// Chiffres de l'ancien détecteur : moyenne de tuile, seuil 40 niveaux,
/// 0,2 % des pixels lus. Un flash plein pot couvrant 5 % de l'image déplaçait
/// la moyenne d'une tuile de ~13 niveaux : jamais déclenché.
struct DetectorAcceptanceTests {

    /// Image NV12 unie, avec optionnellement un carré « flash » couvrant
    /// `coverage` de la surface.
    private func makeFrame(base: UInt8, flash: UInt8? = nil,
                           coverage: Double = 0, size: Int = 512) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, size, size,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "test", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            memset(lumaBase, Int32(base), stride * height)
            if let flash, coverage > 0 {
                // Carré centré dont l'aire vaut `coverage` de l'image.
                let side = max(Int((Double(size * size) * coverage).squareRoot().rounded()), 1)
                let origin = (size - side) / 2
                let pointer = lumaBase.assumingMemoryBound(to: UInt8.self)
                for y in origin..<(origin + side) {
                    memset(pointer + y * stride + origin, Int32(flash), side)
                }
            }
        }
        // Chrominance neutre : le test porte sur la luminance.
        if let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(chromaBase, 128, stride * height)
        }
        return buffer
    }

    /// Le contrat : un flash blanc doit être détecté qu'il couvre toute
    /// l'image ou un millième de sa surface.
    @Test(arguments: [1.0, 0.25, 0.05, 0.01, 0.001])
    func flashIsDetectedAtEveryCoverage(coverage: Double) throws {
        let calm = try makeFrame(base: 90)
        let flashed = try makeFrame(base: 90, flash: 250, coverage: coverage)

        let reference = try #require(VideoRenderPipeline.frameSignature(of: calm))
        let candidate = try #require(VideoRenderPipeline.frameSignature(of: flashed))

        let score = VideoRenderPipeline.anomalyScore(
            previous: reference, candidate: candidate, next: reference
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold,
                "Flash couvrant \(coverage * 100) % non détecté (score \(score))")

        // Et il doit franchir le VERDICT complet, pas seulement le seuil par
        // tuile : étendu (beaucoup de tuiles) ou extrême (saturation).
        let detail = VideoRenderPipeline.anomalyDetail(
            previous: reference, candidate: candidate, next: reference, spread: nil
        )
        #expect(VideoRenderPipeline.isAnomalous(score: detail.score,
                                                deviatingTiles: detail.deviatingTiles),
                "Flash de \(coverage * 100) % non retenu : score \(detail.score), \(detail.deviatingTiles) tuile(s)")
    }

    /// Symétrique : un trou NOIR localisé, que seul le minimum par tuile voit.
    @Test func localizedBlackHoleIsDetected() throws {
        let calm = try makeFrame(base: 140)
        let holed = try makeFrame(base: 140, flash: 4, coverage: 0.005)
        let reference = try #require(VideoRenderPipeline.frameSignature(of: calm))
        let candidate = try #require(VideoRenderPipeline.frameSignature(of: holed))
        let score = VideoRenderPipeline.anomalyScore(
            previous: reference, candidate: candidate, next: reference
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// Contre-épreuve indispensable : deux images IDENTIQUES ne déclenchent
    /// rien. Un détecteur qui crie sur tout ne mesure pas davantage qu'un
    /// détecteur aveugle — il déclencherait un repli sur chaque clip.
    @Test func identicalFramesRaiseNothing() throws {
        let calm = try makeFrame(base: 120)
        let signature = try #require(VideoRenderPipeline.frameSignature(of: calm))
        let score = VideoRenderPipeline.anomalyScore(
            previous: signature, candidate: signature, next: signature
        )
        #expect(score == 0)
    }
}

/// TOLÉRANCE ADAPTATIVE — la tension centrale du détecteur.
///
/// Il doit être assez sensible pour voir un flash minuscule sur une scène
/// calme, et assez tolérant pour ne pas crier sur un panoramique rapide où les
/// statistiques d'une tuile changent LÉGITIMEMENT de plus de 100 niveaux. Un
/// seuil fixe ne peut pas tenir les deux : mesuré par le banc, il signalait une
/// image sur quatre d'un rendu SANS un seul pixel inventé.
struct AdaptiveToleranceTests {

    private func uniform(_ value: Double) -> VideoRenderPipeline.FrameSignature {
        let count = VideoRenderPipeline.outputGrid * VideoRenderPipeline.outputGrid
        let array = Array(repeating: value, count: count)
        return VideoRenderPipeline.FrameSignature(
            luma: array, lumaMax: array, lumaMin: array,
            cb: array, cbMax: array, cbMin: array,
            cr: array, crMax: array, crMin: array
        )
    }

    /// L'agitation se mesure par un ÉCART ABSOLU MÉDIAN, pas par l'amplitude
    /// totale : un flash occupe jusqu'à 30 % de la fenêtre de référence, et
    /// l'amplitude totale l'engloberait — rendant le détecteur aveugle au
    /// flash même (mesuré : écart max tombé à 0).
    /// [100, 160, 120] → médiane 120, écarts {20, 40, 0} → médian 20 → ×4.
    @Test func spreadUsesRobustDeviation() throws {
        let spread = try #require(VideoRenderPipeline.spreadSignature(
            of: [uniform(100), uniform(160), uniform(120)]
        ))
        #expect(abs(spread.luma[0] - 20 * VideoRenderPipeline.spreadRobustFactor) < 0.001)
    }

    /// Le point décisif : une minorité d'images FLASHÉES parmi les références
    /// ne doit pas gonfler la tolérance, sinon le flash se cache lui-même.
    @Test func minorityOfFlashedReferencesDoesNotInflateTolerance() throws {
        // 7 images calmes, 3 flashées — la situation exacte d'un flash d'une
        // image du rush étalé sur 4 images de sortie.
        let references = [uniform(100), uniform(102), uniform(98), uniform(101),
                          uniform(99), uniform(100), uniform(103),
                          uniform(250), uniform(250), uniform(250)]
        let spread = try #require(VideoRenderPipeline.spreadSignature(of: references))
        #expect(spread.luma[0] < 40,
                "Les images flashées ont gonflé la tolérance (\(spread.luma[0]))")
        let score = VideoRenderPipeline.medianEnvelopeScore(
            left: uniform(100), right: uniform(101), candidate: uniform(250), spread: spread
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }

    /// Références identiques → amplitude nulle → aucune indulgence.
    @Test func calmSceneKeepsFullSensitivity() throws {
        let calm = [uniform(100), uniform(100), uniform(100)]
        let spread = try #require(VideoRenderPipeline.spreadSignature(of: calm))
        let score = VideoRenderPipeline.medianEnvelopeScore(
            left: uniform(100), right: uniform(100), candidate: uniform(130), spread: spread
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold,
                "Un écart de 30 niveaux sur une scène immobile doit être signalé")
    }

    /// Voisinage agité de 120 niveaux : une image qui s'en écarte d'autant
    /// reste dans l'ordinaire — c'est du mouvement, pas un artefact.
    @Test func agitatedNeighbourhoodAbsorbsLegitimateMotion() throws {
        let agitated = [uniform(40), uniform(160), uniform(90), uniform(150), uniform(60)]
        let spread = try #require(VideoRenderPipeline.spreadSignature(of: agitated))
        let score = VideoRenderPipeline.medianEnvelopeScore(
            left: uniform(90), right: uniform(100), candidate: uniform(200), spread: spread
        )
        #expect(score == 0, "Mouvement rapide signalé comme artefact (score \(score))")
    }

    /// Mais un flash qui dépasse DE LOIN l'agitation locale reste vu.
    @Test func flashBeyondLocalAgitationIsStillDetected() throws {
        let agitated = [uniform(90), uniform(120), uniform(100), uniform(110), uniform(95)]
        let spread = try #require(VideoRenderPipeline.spreadSignature(of: agitated))
        let score = VideoRenderPipeline.medianEnvelopeScore(
            left: uniform(100), right: uniform(105), candidate: uniform(250), spread: spread
        )
        #expect(score > VideoRenderPipeline.outputAnomalyThreshold)
    }
}

/// VERDICT : étendu OU extrême — calibré sur rush réel, pas au jugé.
///
/// Le critère « une seule tuile dépasse le seuil » condamnait une image sur
/// quatre d'un export SANS interpolation (mesuré le 14/08/2026 : indices 23,
/// 24, 27, 28, 31, 32, 39, 40, écart max 68, espacement de 4 = frontières
/// d'images source). Sans un pixel inventé, ces images ne pouvaient PAS être
/// des artefacts : c'étaient des bords d'objets traversant des tuiles.
struct AnomalyVerdictTests {

    private func tiles(_ values: [Int: Double], base: Double) -> VideoRenderPipeline.FrameSignature {
        let count = VideoRenderPipeline.outputGrid * VideoRenderPipeline.outputGrid
        var array = Array(repeating: base, count: count)
        for (index, value) in values where index < count { array[index] = value }
        return VideoRenderPipeline.FrameSignature(
            luma: array, lumaMax: array, lumaMin: array,
            cb: Array(repeating: 128, count: count),
            cbMax: Array(repeating: 128, count: count),
            cbMin: Array(repeating: 128, count: count),
            cr: Array(repeating: 128, count: count),
            crMax: Array(repeating: 128, count: count),
            crMin: Array(repeating: 128, count: count)
        )
    }

    /// LE CAS MESURÉ : deux tuiles qui sautent de 68 niveaux — un bord en
    /// mouvement. Ne doit PAS écarter le flux optique.
    @Test func movingEdgeIsNotAnAnomaly() {
        let calm = tiles([:], base: 100)
        let edge = tiles([40: 176, 41: 176], base: 100)   // 176 - (100+8) = 68
        let detail = VideoRenderPipeline.anomalyDetail(
            previous: calm, candidate: edge, next: calm, spread: nil
        )
        #expect(detail.score > 60, "Le dépassement mesuré doit bien être vu…")
        #expect(!VideoRenderPipeline.isAnomalous(score: detail.score,
                                                 deviatingTiles: detail.deviatingTiles),
                "…mais ne pas condamner l'image (score \(detail.score), \(detail.deviatingTiles) tuiles)")
    }

    /// Flash ÉTENDU d'amplitude pourtant modérée : condamné par le nombre.
    @Test func widespreadDeviationIsAnAnomaly() {
        let calm = tiles([:], base: 100)
        var spread: [Int: Double] = [:]
        for index in 0..<VideoRenderPipeline.outputMinDeviatingTiles { spread[index] = 150 }
        let flashed = tiles(spread, base: 100)
        let detail = VideoRenderPipeline.anomalyDetail(
            previous: calm, candidate: flashed, next: calm, spread: nil
        )
        #expect(VideoRenderPipeline.isAnomalous(score: detail.score,
                                                deviatingTiles: detail.deviatingTiles))
    }

    /// Flash MINUSCULE mais saturant : une seule tuile suffit si l'amplitude
    /// est extrême. C'est ce qui préserve la détection d'un flash de 0,1 %.
    @Test func singleExtremeTileIsAnAnomaly() {
        let calm = tiles([:], base: 90)
        let flashed = tiles([120: 250], base: 90)   // 250 - 98 = 152 > 120
        let detail = VideoRenderPipeline.anomalyDetail(
            previous: calm, candidate: flashed, next: calm, spread: nil
        )
        #expect(detail.deviatingTiles == 1)
        #expect(VideoRenderPipeline.isAnomalous(score: detail.score,
                                                deviatingTiles: detail.deviatingTiles))
    }
}
