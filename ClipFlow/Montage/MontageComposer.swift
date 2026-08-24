//
//  MontageComposer.swift
//  ClipFlow
//
//  Du PLAN DE MONTAGE au fichier : composition AVFoundation (jouable telle
//  quelle pour l'aperçu) puis export.
//
//  Les clips sont insérés depuis leurs PLAGES CACHÉES (fichiers compressés,
//  aucun réencodage à la construction) et ralentis par `scaleTimeRange` —
//  résultat identique au moteur « images réelles répétées » du pipeline
//  d'export : chaque image affichée est une vraie image du rush, tenue plus
//  longtemps. Aucun pixel inventé.
//
//  L'aperçu et l'export partagent LA MÊME composition : ce que l'utilisateur
//  voit avant d'exporter est ce que le fichier contiendra.
//

import Foundation
import AVFoundation

enum MontageComposerError: Error, LocalizedError {
    case missingSource(clipID: Int)
    case noVideoTrack(clipID: Int)
    case compositionFailed(String)
    case exportFailed(String)
    case emptyPlan

    var errorDescription: String? {
        switch self {
        case .missingSource(let id):
            return "Fichier source introuvable pour le clip \(id + 1)."
        case .noVideoTrack(let id):
            return "Le clip \(id + 1) n'a pas de piste vidéo."
        case .compositionFailed(let details):
            return "Assemblage impossible : \(details)"
        case .exportFailed(let details):
            return "Export du montage impossible : \(details)"
        case .emptyPlan:
            return "Aucun clip à monter — validez des clips d'abord."
        }
    }
}

/// Composition prête : à donner telle quelle à AVPlayer (aperçu) ou à
/// l'exporteur.
struct MontageComposition {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition
    /// Taille de l'image rendue — l'aperçu s'en sert pour retrouver le cadre
    /// réel de la vidéo dans le lecteur (qui la met en boîte aux lettres).
    var renderSize: CGSize
    /// Taille FINALE visée, dans le format que cette composition a réellement
    /// retenu.
    ///
    /// Égale à `renderSize` en une seule passe. En deux passes, `renderSize`
    /// est la taille native et celle-ci la cible 4K : l'agrandisseur doit
    /// prendre CELLE-CI, et surtout pas la recalculer de son côté. Les deux
    /// calculs partaient d'orientations différentes — le contrôleur depuis le
    /// rush du premier clip, le composeur depuis le fichier réellement inséré —
    /// et un rush supprimé suffisait à les faire diverger. L'agrandisseur
    /// étirait alors tout le montage à un rapport faux.
    var outputSize: CGSize
}

enum MontageComposer {

    /// Construit la composition complète : vidéo (clips ralentis, coupes sur
    /// les beats) + piste musicale calée sur la fenêtre.
    ///
    /// - `sources` : URL du fichier de chaque clip, par identifiant.
    static func build(plan: MontagePlan,
                      sources: [Int: URL],
                      crops: [Int: CGPoint] = [:],
                      musicURL: URL,
                      overlays: [ResolvedOverlay] = [],
                      outputFormat: MontageOutputFormat = .auto,
                      cropToFill: Bool = true,
                      /// Colorimétrie COMMUNE des clips ("sdr" si tous le sont).
                      /// Sert uniquement à déclarer l'espace de la composition.
                      colorimetry: String = "inconnue",
                      renderAtNativeSize: Bool = false,
                      forExport: Bool = false) async throws -> MontageComposition {
        guard !plan.placements.isEmpty else { throw MontageComposerError.emptyPlan }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MontageComposerError.compositionFailed("piste vidéo") }

        // Une instruction unique sur toute la durée, avec une transformation
        // par segment : c'est le mécanisme prévu pour une piste séquentielle
        // dont les segments n'ont pas tous la même orientation.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

        // Les fichiers sont ouverts UNE fois chacun, même utilisés plusieurs
        // fois. L'ASSET EST RETENU DANS LE CACHE, et c'est capital :
        // AVAssetTrack ne retient PAS son AVAsset (référence faible). Ne
        // garder que la piste laissait l'asset se libérer à la sortie du
        // bloc — piste pendante, et le premier insertTimeRange échouait en
        // « Opération impossible » dès le clip 1, systématiquement.
        var loadedTracks: [URL: (asset: AVURLAsset, track: AVAssetTrack,
                                 range: CMTimeRange, size: CGSize,
                                 transform: CGAffineTransform)] = [:]
        var renderSize = CGSize.zero
        var outputSize = CGSize.zero
        var cursor = CMTime.zero

        for placement in plan.placements {
            // ANNULATION EFFECTIVE. Sans ce point de contrôle, une
            // construction abandonnée — l'écran s'est fermé, une feuille s'est
            // ouverte, le plan a changé — allait quand même jusqu'au bout de
            // ses cent cinquante insertions, monopolisant l'appareil pour un
            // résultat que personne n'installera. Le `CancellationError` levé
            // ici est déjà traité par l'appelant, qui n'en fait pas une erreur
            // visible.
            try Task.checkCancellation()
            guard let url = sources[placement.clipID] else {
                throw MontageComposerError.missingSource(clipID: placement.clipID)
            }
            let info: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange,
                       size: CGSize, transform: CGAffineTransform)
            if let cached = loadedTracks[url] {
                info = cached
            } else {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw MontageComposerError.noVideoTrack(clipID: placement.clipID)
                }
                let (naturalSize, transform, trackRange) = try await track.load(
                    .naturalSize, .preferredTransform, .timeRange
                )
                info = (asset, track, trackRange, naturalSize, transform)
                loadedTracks[url] = info
            }

            // TAILLE DE RENDU : 4K dans le format CHOISI, jamais celle du
            // premier clip. Elle se déduisait de lui, ce qui allait tant que
            // tous les rushes partageaient une orientation — dès qu'on en
            // mélange, le format du fichier dépendait de quel clip la musique
            // avait mis en tête. Le premier clip ne sert plus qu'à trancher le
            // mode automatique.
            let oriented = info.size.applying(info.transform)
            let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            if renderSize == .zero {
                // Cible finale RETENUE ICI, au même instant et depuis la même
                // orientation que la taille de composition.
                outputSize = outputFormat.renderSize(sourceOriented: orientedSize)
                // Taille NATIVE quand une seconde passe agrandira : composer
                // directement en 4K laisserait AVFoundation agrandir au filtre
                // bilinéaire, et le suréchantillonnage n'aurait plus qu'un flou
                // à lisser.
                renderSize = renderAtNativeSize
                    ? outputFormat.nativeRenderSize(sourceOriented: orientedSize,
                                                    cropToFill: cropToFill)
                    : outputFormat.renderSize(sourceOriented: orientedSize)
            }

            // Trou entre le curseur et le créneau (créneau dégénéré filtré en
            // amont) : comblé par du vide plutôt qu'un désalignement — les
            // beats SUIVANTS restent calés sur la musique.
            if CMTimeCompare(placement.timelineStart, cursor) > 0 {
                videoTrack.insertEmptyTimeRange(
                    CMTimeRange(start: cursor, end: placement.timelineStart)
                )
            }

            // BORNAGE À LA PISTE avant insertion : la durée du CONTENEUR peut
            // dépasser celle de la piste vidéo, et une plage qui sort de la
            // piste fait échouer l'insertion avec un message générique.
            // Un dépassement d'une demi-image est absorbé en silence ; au-delà
            // c'est un vrai défaut, expliqué chiffres à l'appui.
            var sourceRange = placement.sourceRange
            let trackEnd = info.range.end
            let overshoot = CMTimeSubtract(sourceRange.end, trackEnd).seconds
            if overshoot > 0 {
                if overshoot <= 0.05 {
                    sourceRange = CMTimeRange(start: sourceRange.start,
                                              end: trackEnd)
                } else {
                    throw MontageComposerError.compositionFailed(String(
                        format: "clip %d : la plage demandée (%.2f–%.2f s) dépasse la piste vidéo de son fichier (fin à %.2f s). C'est un défaut de l'app, pas une erreur d'utilisation — signalez-le.",
                        placement.clipID + 1, sourceRange.start.seconds,
                        sourceRange.end.seconds, trackEnd.seconds
                    ))
                }
            }
            if CMTimeCompare(sourceRange.start, info.range.start) < 0 {
                sourceRange = CMTimeRange(start: info.range.start, end: sourceRange.end)
            }
            do {
                try videoTrack.insertTimeRange(sourceRange,
                                               of: info.track,
                                               at: placement.timelineStart)
            } catch {
                let nsError = error as NSError
                throw MontageComposerError.compositionFailed(String(
                    format: "clip %d : insertion refusée (plage %.2f–%.2f s, piste %.2f–%.2f s, erreur %@ %d). C'est un défaut de l'app, pas une erreur d'utilisation — signalez-le avec ces chiffres.",
                    placement.clipID + 1, sourceRange.start.seconds, sourceRange.end.seconds,
                    info.range.start.seconds, info.range.end.seconds,
                    nsError.domain, nsError.code
                ))
            }
            // RALENTI : la plage source (durée × vitesse) est étirée à la
            // durée exacte du créneau. 0,5× → chaque image tenue deux fois.
            // La durée INSÉRÉE (éventuellement bornée à la piste) est celle
            // qu'on étire — jamais la durée théorique du plan.
            videoTrack.scaleTimeRange(
                CMTimeRange(start: placement.timelineStart, duration: sourceRange.duration),
                toDuration: placement.timelineDuration
            )

            layerInstruction.setTransform(
                fillTransform(size: info.size, transform: info.transform,
                              into: renderSize, cropToFill: cropToFill,
                              cropCenter: crops[placement.clipID] ?? CropGeometry.centered),
                at: placement.timelineStart
            )
            cursor = CMTimeAdd(placement.timelineStart, placement.timelineDuration)
        }

        // Piste musicale : la fenêtre exacte du montage, à partir du beat de
        // départ. C'est TOUT l'audio du montage — les rushes sont muets ici.
        let musicAsset = AVURLAsset(url: musicURL)
        guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first,
              let audioTrack = composition.addMutableTrack(
                  withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw MontageComposerError.compositionFailed("piste musicale introuvable")
        }
        // Borne de la PISTE, pas du conteneur : sur certains fichiers la piste
        // audio est plus courte que la durée déclarée de l'asset, et viser
        // au-delà fait échouer l'insertion.
        let musicRange = try await musicTrack.load(.timeRange)
        let available = CMTimeSubtract(musicRange.end, plan.musicStart)
        let wanted = CMTimeMinimum(plan.totalDuration, available)
        if CMTimeCompare(wanted, .zero) > 0 {
            do {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: plan.musicStart, duration: wanted),
                    of: musicTrack, at: .zero
                )
            } catch {
                // Un montage MUET exporté en silence serait un mensonge :
                // la musique est le cœur du produit, son absence est une erreur.
                throw MontageComposerError.compositionFailed(
                    "musique : \(error.localizedDescription)"
                )
            }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: plan.totalDuration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        // ESPACE DÉCLARÉ EXPLICITEMENT EN SDR, comme au recadrage clip par clip.
        //
        // À nil, AVFoundation propage celui des pistes — correct, mais implicite,
        // et la piste réunit des segments venus de fichiers différents (plage
        // cachée, version lissée, copie source). Le déclarer supprime cette
        // inconnue là où elle n'a pas lieu d'être.
        //
        // EN HDR, RIEN N'EST FORCÉ : les combinaisons acceptées sont limitées, et
        // un montage HDR n'a jamais été signalé comme fautif.
        if colorimetry == "sdr" {
            videoComposition.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            videoComposition.colorTransferFunction = kCVImageBufferTransferFunction_ITU_R_709_2 as String
            videoComposition.colorYCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        }
        // 60 i/s, demandé explicitement, avec la conséquence assumée : un clip
        // ralenti 0,5× depuis une source 60 i/s ne produit une image NOUVELLE
        // qu'une fois sur deux, et l'encodeur duplique l'autre. Le fichier est
        // donc plus lourd sans être plus fluide sur ces passages-là — mais il
        // sort en 60 i/s partout, ce qu'attendent les plateformes, et les
        // passages non ralentis y gagnent réellement.
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)

        // INCRUSTATIONS — UNIQUEMENT sur le chemin d'EXPORT.
        //
        // `AVVideoCompositionCoreAnimationTool` est documenté par Apple comme
        // un outil de rendu HORS LIGNE. Attaché à la composition d'un
        // AVPlayerItem, il est au mieux ignoré (aperçu sans incrustation), au
        // pire il invalide l'élément et le lecteur reste noir. L'aperçu
        // dessine donc ses incrustations en SwiftUI par-dessus le lecteur
        // (voir OverlayPreviewLayer), avec la même géométrie fractionnaire.
        if forExport {
            OverlayRenderer.attach(overlays, to: videoComposition,
                                   renderSize: renderSize,
                                   totalDuration: plan.totalDuration)
        }

        return MontageComposition(composition: composition,
                                  videoComposition: videoComposition,
                                  renderSize: renderSize,
                                  outputSize: outputSize)
    }

    /// Transformation « remplir le cadre » : orientation native appliquée,
    /// mise à l'échelle au REMPLISSAGE (jamais de bandes noires), centrage.
    /// - `cropToFill` : vrai = REMPLIR le cadre en rognant les bords ; faux =
    ///   CONTENIR l'image entière, donc des bandes noires. Le remplissage est
    ///   le défaut : sur un montage vertical fait de rushes 16:9, contenir
    ///   laisse deux bandes qui occupent plus de la moitié de la hauteur.
    /// - `cropCenter` : centre de la portion gardée, en fractions de l'image
    ///   orientée (voir `CropGeometry`). La valeur par défaut redonne
    ///   EXACTEMENT le centrage d'origine — condition pour qu'aucun montage
    ///   déjà réglé ne change de cadrage.
    static func fillTransform(size: CGSize,
                              transform: CGAffineTransform,
                              into renderSize: CGSize,
                              cropToFill: Bool = true,
                              cropCenter: CGPoint = CropGeometry.centered) -> CGAffineTransform {
        let oriented = size.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return transform }

        let scale = CropGeometry.scale(orientedSize: orientedSize,
                                       renderSize: renderSize,
                                       cropToFill: cropToFill)
        // 1. Orientation native. 2. Recalage de l'origine (une rotation met
        //    des coordonnées négatives). 3. Échelle. 4. Cadrage.
        var result = transform
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        result = result.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        result = result.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaledSize = CGSize(width: orientedSize.width * scale,
                                height: orientedSize.height * scale)
        // CADRAGE APRÈS L'ÉCHELLE, et l'ordre n'est pas indifférent : glissé
        // avant, le décalage serait multiplié par `scale` — jusqu'à trois fois
        // et demie de trop — et l'erreur resterait invisible sur un montage
        // 16:9 vers 16:9, où l'échelle vaut 1.
        let safe = CropGeometry.clamp(cropCenter,
                                      orientedSize: orientedSize,
                                      renderSize: renderSize,
                                      cropToFill: cropToFill)
        result = result.concatenating(CGAffineTransform(
            translationX: renderSize.width / 2 - safe.x * scaledSize.width,
            y: renderSize.height / 2 - safe.y * scaledSize.height
        ))
        return result
    }

    /// Exporte la composition en fichier .mov (HEVC, qualité maximale).
    /// `onProgress` est appelé régulièrement avec 0…1.
    static func export(_ montage: MontageComposition,
                       outputFilename: String,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let outputURL = StorageManager.exportsDirectory.appendingPathComponent(outputFilename)
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: montage.composition,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw MontageComposerError.exportFailed("session d'export indisponible")
        }
        session.videoComposition = montage.videoComposition

        // Suivi de progression pendant l'export (l'API states(updateInterval:)
        // publie l'avancement ; l'export lui-même court en parallèle).
        let progressTask = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await session.export(to: outputURL, as: .mov)
        } catch {
            throw MontageComposerError.exportFailed(error.localizedDescription)
        }
        onProgress(1)
        return outputURL
    }
}
