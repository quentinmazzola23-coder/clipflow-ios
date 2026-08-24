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
import CoreVideo
import CoreGraphics
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
        // COLORIMÉTRIE LUE SUR LA PISTE, jamais supposée.
        //
        // Cette passe posait 709 en quatre endroits — espace de travail, espace
        // de sortie, attachements du tampon, réglages de l'écrivain — sans
        // jamais regarder ce que l'intermédiaire portait vraiment. Tant qu'il
        // est en 709 l'aller-retour est neutre ; dès qu'il ne l'est pas, la
        // passe grave l'étiquette fausse dans le fichier final et rend le
        // défaut indétectable en aval. Conserver vaut mieux qu'affirmer.
        let sourceColor = ColorTags(track: try? await track.load(.formatDescriptions))
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

        // LECTEUR AUDIO SÉPARÉ, et c'est délibéré. Un même AVAssetReader dont on
        // vide entièrement une sortie avant de toucher à l'autre se bloque :
        // il ne décode pas plus loin tant que toutes ses sorties n'avancent
        // pas. Deux lecteurs indépendants lisent le même fichier sans se gêner.
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack, let second = try? AVAssetReader(asset: asset) {
            // Passthrough : la musique n'a aucune raison d'être réencodée.
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if second.canAdd(out) {
                second.add(out)
                audioReader = second
                audioOutput = out
            }
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
                // FICHIER ÉTIQUETÉ COMME LA SOURCE. Sans ces clés, le .mov
                // sort sans description de couleur et le lecteur retombe sur
                // une convention. Avec une valeur choisie plutôt que lue, il
                // sort avec une description FAUSSE — bien pire.
                AVVideoColorPropertiesKey: sourceColor.writerProperties,
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
        if let audioReader, !audioReader.startReading() {
            throw MontageUpscalerError.readerFailed(
                audioReader.error?.localizedDescription ?? "démarrage audio refusé")
        }
        guard writer.startWriting() else {
            throw MontageUpscalerError.writerFailed(
                writer.error?.localizedDescription ?? "démarrage refusé")
        }
        writer.startSession(atSourceTime: .zero)

        // ESPACE DE COREIMAGE ACCORDÉ SUR LA SOURCE.
        //
        // Sans espace déclaré, CoreImage rendait dans le sien — du sRGB — sur un
        // tampon nu, pendant que l'écrivain déclarait autre chose. sRGB et
        // Rec.709 partageant leurs primaires et leur blanc, l'écart était
        // purement une courbe de transfert, donc ACHROMATIQUE : quelques pour
        // cent de contraste, jamais une dominante de couleur. La corriger était
        // juste ; y voir la cause d'un voile rougeâtre était une erreur, et ce
        // commentaire existe pour ne pas la refaire.
        //
        // En accordant l'espace de travail ET celui de sortie sur ce que porte
        // la source, la passe devient l'IDENTITÉ colorimétrique : les octets la
        // traversent sans conversion, quelle que soit l'étiquette d'origine.

        var contextOptions: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        contextOptions[.workingColorSpace] = sourceColor.colorSpace
        contextOptions[.outputColorSpace] = sourceColor.colorSpace
        let context = CIContext(options: contextOptions)
        let overlayCache = OverlayImageCache(overlays: overlays, size: targetSize)
        let total = max(duration.seconds, 0.001)

        // MARK: Passe vidéo
        //
        // TROIS PIÈGES, tous corrigés ici après relecture :
        //
        // 1. Le bloc de `requestMediaDataWhenReady` est rappelé plusieurs fois
        //    par AVFoundation. Reprendre la continuation deux fois fait planter
        //    Swift, sans rattrapage possible — d'où le verrou et le drapeau.
        // 2. `Task.isCancelled` lu DANS ce bloc vaut toujours faux : le bloc
        //    court sur une file GCD, hors du contexte de la tâche Swift.
        //    L'annulation passe donc par un drapeau posé de l'extérieur.
        // 3. `append` rend un booléen. L'ignorer laissait la boucle tourner
        //    contre un écrivain mort et produire un fichier tronqué présenté
        //    comme réussi.
        let state = UpscaleState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "clipflow.upscale.video")
                videoInput.requestMediaDataWhenReady(on: queue) {
                    while videoInput.isReadyForMoreMediaData {
                        if state.isCancelled {
                            reader.cancelReading()
                            videoInput.markAsFinished()
                            state.finish(cont, throwing: CancellationError())
                            return
                        }
                        guard let sample = videoOutput.copyNextSampleBuffer(),
                              let buffer = CMSampleBufferGetImageBuffer(sample) else {
                            videoInput.markAsFinished()
                            // Fin de piste OU échec de lecture : seul le statut
                            // du lecteur les distingue. Sans ce test, une
                            // lecture interrompue rendait un fichier partiel
                            // sans que rien ne le signale.
                            if reader.status == .failed {
                                state.finish(cont, throwing: MontageUpscalerError.readerFailed(
                                    reader.error?.localizedDescription ?? "lecture interrompue"))
                            } else {
                                state.finish(cont, throwing: nil)
                            }
                            return
                        }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)

                        var image = CIImage(cvPixelBuffer: buffer)
                        // LANCZOS : le filtre d'agrandissement, et la seule
                        // raison d'être de cette passe.
                        let source = image.extent
                        if source.width > 0, source.height > 0 {
                            let scale = targetSize.height / source.height
                            if abs(scale - 1) > 0.001,
                               let filter = CIFilter(name: "CILanczosScaleTransform") {
                                filter.setValue(image, forKey: kCIInputImageKey)
                                filter.setValue(scale, forKey: kCIInputScaleKey)
                                filter.setValue(targetSize.width / (source.width * scale),
                                                forKey: kCIInputAspectRatioKey)
                                if let scaled = filter.outputImage { image = scaled }
                            }
                        }
                        // L'ORIGINE EST RAMENÉE À ZÉRO. `render(_:to:)` fait
                        // correspondre l'origine de l'extent au coin du tampon :
                        // un extent décalé d'une fraction de pixel après mise à
                        // l'échelle décalerait toute l'image.
                        if image.extent.origin != .zero {
                            image = image.transformed(by: CGAffineTransform(
                                translationX: -image.extent.origin.x,
                                y: -image.extent.origin.y))
                        }

                        if let overlayImage = overlayCache.image(at: time.seconds) {
                            image = overlayImage.composited(over: image)
                        }

                        guard let pool = adaptor.pixelBufferPool else {
                            reader.cancelReading(); videoInput.markAsFinished()
                            state.finish(cont, throwing: MontageUpscalerError.writerFailed(
                                "réserve de tampons indisponible"))
                            return
                        }
                        var out: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                        guard let outBuffer = out else {
                            reader.cancelReading(); videoInput.markAsFinished()
                            state.finish(cont, throwing: MontageUpscalerError.writerFailed(
                                "tampon de sortie indisponible"))
                            return
                        }
                        // ÉTIQUETTES RECOPIÉES DE LA SOURCE sur le tampon :
                        // l'encodeur lit d'abord celles-ci, et un tampon nu le
                        // laisse deviner. Elles disent la même chose que
                        // l'espace du contexte et que les réglages de
                        // l'écrivain — les trois s'accordent, sur la valeur
                        // lue et non sur une valeur choisie.
                        sourceColor.apply(to: outBuffer)
                        context.render(image, to: outBuffer)
                        guard adaptor.append(outBuffer, withPresentationTime: time) else {
                            reader.cancelReading(); videoInput.markAsFinished()
                            state.finish(cont, throwing: MontageUpscalerError.writerFailed(
                                writer.error?.localizedDescription ?? "image refusée par l'écrivain"))
                            return
                        }
                        onProgress(min(0.99, time.seconds / total))
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }

        // MARK: Passe audio
        if let audioInput, let audioOutput {
            let audioState = UpscaleState()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let queue = DispatchQueue(label: "clipflow.upscale.audio")
                audioInput.requestMediaDataWhenReady(on: queue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let sample = audioOutput.copyNextSampleBuffer(),
                              audioInput.append(sample) else {
                            audioInput.markAsFinished()
                            audioState.finish(cont)
                            return
                        }
                    }
                }
            }
            // LE STATUT DU LECTEUR FAIT FOI, pas la fin de la boucle.
            //
            // `copyNextSampleBuffer` rend nil aussi bien à la fin de la piste
            // qu'à la première défaillance. Le lecteur audio est démarré avant
            // la passe vidéo et attend pendant tout l'agrandissement — plusieurs
            // minutes — ce qui laisse largement le temps à une réinitialisation
            // des services média de le tuer. Sans ce test, l'écriture
            // réussissait, le montage était déposé dans Photos et annoncé
            // réussi : SANS MUSIQUE. Sur une app dont la musique est le cœur,
            // c'est un échec qu'il vaut mieux dire.
            if let audioReader, audioReader.status == .failed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                throw MontageUpscalerError.readerFailed(
                    audioReader.error?.localizedDescription
                        ?? "lecture de la musique interrompue")
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

/// Les étiquettes de couleur d'une piste, telles qu'elle les porte.
///
/// LUES, JAMAIS CHOISIES. La seconde passe du montage décode, redimensionne et
/// réencode : c'est un aller-retour, pas une conversion. Tout ce qu'elle a à
/// faire, c'est rendre les octets là où elle les a pris — et pour cela il faut
/// savoir ce qu'ils disent, pas décider à leur place.
///
/// Le repli est le Rec.709, qui est ce qu'un lecteur suppose déjà devant une
/// piste haute définition sans description. Il ne change donc rien à
/// l'interprétation ; il la rend seulement explicite.
private struct ColorTags {
    var primaries: String
    var transferFunction: String
    var yCbCrMatrix: String

    init(track formatDescriptions: [CMFormatDescription]?) {
        func extension_(_ key: CFString) -> String? {
            guard let description = formatDescriptions?.first,
                  let value = CMFormatDescriptionGetExtension(description, extensionKey: key)
            else { return nil }
            return value as? String
        }
        primaries = extension_(kCMFormatDescriptionExtension_ColorPrimaries)
            ?? (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        transferFunction = extension_(kCMFormatDescriptionExtension_TransferFunction)
            ?? (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        yCbCrMatrix = extension_(kCMFormatDescriptionExtension_YCbCrMatrix)
            ?? (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    /// Espace à donner à CoreImage pour que la passe soit l'identité.
    var colorSpace: CGColorSpace {
        let attachments: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: primaries as CFString,
            kCVImageBufferTransferFunctionKey: transferFunction as CFString,
            kCVImageBufferYCbCrMatrixKey: yCbCrMatrix as CFString,
        ]
        if let space = CVImageBufferCreateColorSpaceFromAttachments(
            attachments as CFDictionary
        )?.takeRetainedValue() {
            return space
        }
        // Espace introuvable (combinaison exotique) : le Rec.709 est la
        // convention que le lecteur appliquerait de toute façon.
        return CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Ce que l'écrivain doit déclarer sur le fichier produit.
    var writerProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transferFunction,
            AVVideoYCbCrMatrixKey: yCbCrMatrix,
        ]
    }

    /// Recopie les étiquettes sur un tampon de sortie.
    ///
    /// Reposées à CHAQUE image : un tampon recyclé par le pool garde les
    /// siennes, mais un tampon neuf sort nu, et l'encodeur lit d'abord celles-ci.
    func apply(to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              primaries as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              transferFunction as CFString, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              yCbCrMatrix as CFString, .shouldPropagate)
    }
}

/// Reprise de continuation à UN SEUL COUP, et annulation lisible depuis une
/// file GCD.
///
/// `requestMediaDataWhenReady` rappelle son bloc autant de fois qu'il le faut,
/// et rien n'empêche deux chemins d'y conclure. Reprendre une
/// `CheckedContinuation` deux fois fait planter le programme, sans rattrapage
/// possible : le drapeau et le verrou sont la seule protection.
private final class UpscaleState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    /// Reprend la continuation si personne ne l'a déjà fait.
    func finish(_ cont: CheckedContinuation<Void, Error>, throwing error: Error?) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        if let error { cont.resume(throwing: error) } else { cont.resume() }
    }

    func finish(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        cont.resume()
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
            // SEULE LA POSITION EST MIROITÉE, jamais le contenu.
            //
            // `OverlayRenderer.frame` place ses calques pour Core Animation,
            // dont l'origine est en BAS à gauche (d'où son `1 - centerY`).
            // `CALayer.render(in:)` dans un contexte UIGraphics dessine, lui,
            // depuis le HAUT — mais il dessine le contenu à l'endroit, c'est
            // l'idiome ordinaire de capture d'une vue.
            //
            // Retourner le CONTEXTE corrigeait bien la position, et miroitait
            // le contenu avec : un titre atterrissait au bon endroit, tête en
            // bas. Renverser le seul cadre remet chaque calque à sa place sans
            // toucher à ce qu'il dessine.
            layer.frame.origin.y = size.height - layer.frame.maxY
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
