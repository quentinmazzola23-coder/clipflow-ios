//
//  MontageUpscaler.swift
//  ClipFlow
//
//  SURÉCHANTILLONNAGE du montage : seconde passe qui agrandit l'image avec un
//  filtre Lanczos et redessine les incrustations à la taille finale.
//
//  POURQUOI UNE SECONDE PASSE, et non un compositeur sur mesure. Recadrer une
//  source 1080p en 9:16 donne une zone de 608 × 1080 pixels ; la porter en 4K
//  vertical, c'est l'agrandir 3,5 fois. L'agrandissement interne d'AVFoundation
//  est bilinéaire : c'est ce qui donne cet aspect mou. Choisir le filtre
//  imposerait d'écrire un `AVVideoCompositing`, donc de réimplémenter à la main
//  l'orientation, le recadrage et le centrage de chaque clip — tout le chemin
//  de cadrage, qu'on ne touche pas à la légère.
//
//  À la place : la composition rend à sa taille NATIVE (aucun agrandissement,
//  aucun pixel inventé), puis cette passe agrandit une fois, proprement, et
//  dessine les incrustations PAR-DESSUS l'image déjà agrandie. Elles sont donc
//  nettes à 4K au lieu d'être agrandies avec le reste.
//
//  Lanczos et non un modèle d'apprentissage : le filtre interpole, il
//  n'invente rien. C'est la même règle que pour le flux optique, désactivé
//  parce qu'il fabriquait des pixels qu'aucun détecteur ne rattrapait — un
//  agrandissement qui hallucine du détail est un artefact qui s'ignore.
//

import Foundation
import AVFoundation
import CoreImage
import UIKit

enum MontageUpscalerError: Error, LocalizedError {
    case readerFailed(String)
    case writerFailed(String)
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .readerFailed(let d): return "Lecture du montage impossible : \(d)"
        case .writerFailed(let d): return "Écriture du montage agrandi impossible : \(d)"
        case .noVideoTrack: return "Le montage rendu n'a pas de piste vidéo."
        }
    }
}

enum MontageUpscaler {

    /// Faut-il agrandir ? Sous ce facteur, le gain ne vaut pas une seconde
    /// passe d'encodage complète.
    static let minimumUsefulFactor: Double = 1.15

    /// Agrandit `source` à `targetSize` et y incruste les calques.
    ///
    /// - `overlays` : positions en FRACTIONS, donc valables à n'importe quelle
    ///   taille — c'est ce qui permet de les dessiner ici, à la définition
    ///   finale, plutôt que de les laisser subir l'agrandissement.
    static func upscale(source: URL,
                        to targetSize: CGSize,
                        overlays: [ResolvedOverlay],
                        frameRate: Int32,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MontageUpscalerError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let output = source.deletingLastPathComponent()
            .appendingPathComponent("up-" + source.lastPathComponent)
        try? FileManager.default.removeItem(at: output)

        // MARK: Lecture
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw MontageUpscalerError.readerFailed(error.localizedDescription) }

        // BGRA : la chaîne de l'app est en BGRA de bout en bout, et mélanger
        // les espaces de pixels a déjà coûté des inversions de chroma.
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MontageUpscalerError.readerFailed("sortie vidéo refusée")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            // Passthrough : la musique n'a aucune raison d'être réencodée.
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(out) { reader.add(out); audioOutput = out }
        }

        // MARK: Écriture
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: .mov) }
        catch { throw MontageUpscalerError.writerFailed(error.localizedDescription) }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(targetSize.width),
                AVVideoHeightKey: Int(targetSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate(for: targetSize, fps: frameRate),
                    AVVideoExpectedSourceFrameRateKey: Int(frameRate),
                ],
            ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(targetSize.width),
                kCVPixelBufferHeightKey as String: Int(targetSize.height),
            ])
        guard writer.canAdd(videoInput) else {
            throw MontageUpscalerError.writerFailed("entrée vidéo refusée")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        guard reader.startReading() else {
            throw MontageUpscalerError.readerFailed(
                reader.error?.localizedDescription ?? "démarrage refusé")
        }
        guard writer.startWriting() else {
            throw MontageUpscalerError.writerFailed(
                writer.error?.localizedDescription ?? "démarrage refusé")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let overlayCache = OverlayImageCache(overlays: overlays, size: targetSize)
        let total = max(duration.seconds, 0.001)

        // MARK: Passe vidéo
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "clipflow.upscale.video")
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    guard !Task.isCancelled else {
                        reader.cancelReading(); videoInput.markAsFinished()
                        cont.resume(throwing: CancellationError()); return
                    }
                    guard let sample = videoOutput.copyNextSampleBuffer(),
                          let buffer = CMSampleBufferGetImageBuffer(sample) else {
                        videoInput.markAsFinished()
                        cont.resume(); return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)

                    var image = CIImage(cvPixelBuffer: buffer)
                    // LANCZOS : le filtre d'agrandissement, et la seule raison
                    // d'être de cette passe.
                    let scale = targetSize.height / image.extent.height
                    if abs(scale - 1) > 0.001,
                       let filter = CIFilter(name: "CILanczosScaleTransform") {
                        filter.setValue(image, forKey: kCIInputImageKey)
                        filter.setValue(scale, forKey: kCIInputScaleKey)
                        filter.setValue(targetSize.width / (image.extent.width * scale),
                                        forKey: kCIInputAspectRatioKey)
                        if let scaled = filter.outputImage { image = scaled }
                    }

                    if let overlayImage = overlayCache.image(at: time.seconds) {
                        image = overlayImage.composited(over: image)
                    }

                    guard let pool = adaptor.pixelBufferPool else {
                        reader.cancelReading(); videoInput.markAsFinished()
                        cont.resume(throwing: MontageUpscalerError.writerFailed(
                            "réserve de tampons indisponible")); return
                    }
                    var out: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                    guard let outBuffer = out else {
                        reader.cancelReading(); videoInput.markAsFinished()
                        cont.resume(throwing: MontageUpscalerError.writerFailed(
                            "tampon de sortie indisponible")); return
                    }
                    context.render(image, to: outBuffer)
                    adaptor.append(outBuffer, withPresentationTime: time)
                    onProgress(min(0.99, time.seconds / total))
                }
            }
        }

        // MARK: Passe audio
        if let audioInput, let audioOutput {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "clipflow.upscale.audio")
                audioInput.requestMediaDataWhenReady(on: queue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let sample = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished(); cont.resume(); return
                        }
                        audioInput.append(sample)
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw MontageUpscalerError.writerFailed(
                writer.error?.localizedDescription ?? "échec inconnu")
        }
        onProgress(1)
        return output
    }

    /// Débit visé. Un 4K 60 i/s sous-alimenté fait apparaître des blocs dans
    /// les zones de mouvement, ce qui annulerait le bénéfice de l'agrandissement.
    private static func bitrate(for size: CGSize, fps: Int32) -> Int {
        let pixels = Double(size.width * size.height)
        let perPixelPerFrame = 0.09   // HEVC, contenu d'action
        return Int(pixels * Double(fps) * perPixelPerFrame)
    }
}

/// Incrustations rendues UNE FOIS par état de visibilité.
///
/// Les incrustations n'ont aucune animation — elles apparaissent, restent,
/// disparaissent. L'image composée ne change donc qu'aux bornes des portées,
/// c'est-à-dire quelques fois par montage : la redessiner à chaque image
/// coûterait des milliers de rendus de texte pour un résultat identique.
private final class OverlayImageCache {
    private let overlays: [ResolvedOverlay]
    private let size: CGSize
    private var cache: [String: CIImage?] = [:]

    init(overlays: [ResolvedOverlay], size: CGSize) {
        self.overlays = overlays.sorted { $0.stackOrder < $1.stackOrder }
        self.size = size
    }

    func image(at seconds: Double) -> CIImage? {
        let visible = overlays.filter { overlay in
            let start = overlay.start.seconds
            let end = start + overlay.duration.seconds
            return seconds >= start - 0.001 && seconds <= end + 0.001
        }
        guard !visible.isEmpty else { return nil }
        let key = visible.map { String($0.stackOrder) }.joined(separator: ",")
        if let cached = cache[key] { return cached }
        let rendered = render(visible)
        cache[key] = rendered
        return rendered
    }

    private func render(_ visible: [ResolvedOverlay]) -> CIImage? {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = false
        for overlay in visible {
            guard let layer = OverlayRenderer.makeLayer(overlay, renderSize: size) else { continue }
            // Aucune fenêtre de visibilité ici : la sélection par le temps est
            // déjà faite, et une animation Core Animation n'aurait aucun sens
            // dans un rendu hors ligne image par image.
            layer.opacity = Float(max(0, min(1, overlay.opacity)))
            parent.addSublayer(layer)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let uiImage = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            parent.render(in: ctx.cgContext)
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
