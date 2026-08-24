//
//  ClipReframer.swift
//  ClipFlow
//
//  LE FORMAT DE SORTIE APPLIQUÉ AUX EXPORTS CLIP PAR CLIP.
//
//  Le montage respecte le format choisi et le recadrage posé au doigt. L'export
//  rapide, lui, écrivait à la définition native du rush avec sa seule
//  orientation d'origine : on réglait un cadrage, on le voyait sur l'aperçu, et
//  le clip déposé dans Photos sortait au format de la caméra, cadrage ignoré.
//  Deux chemins de sortie qui ne racontaient pas la même chose.
//
//  ELLE RÉUTILISE `MontageComposer.fillTransform`, et c'est tout l'intérêt.
//  Recalculer la géométrie ici aurait donné une seconde règle à tenir
//  d'accord avec la première — et la moindre divergence de repère aurait
//  produit un clip cadré autrement que le montage qui contient le même plan.
//  Une seule fonction décide du cadrage, pour les deux chemins.
//
//  ELLE NE FAIT RIEN QUAND IL N'Y A RIEN À FAIRE. Un rush déjà au bon rapport
//  et cadré au centre ressort par où il est entré, sans réencodage : c'est le
//  cas courant, et il ne doit rien coûter.
//

import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

enum ClipReframer {

    /// Recadre un clip déjà rendu, si le format de sortie l'exige.
    ///
    /// Retourne l'URL du fichier recadré, ou `nil` quand il n'y avait rien à
    /// changer — l'appelant garde alors son fichier d'origine.
    ///
    /// La définition visée n'agrandit JAMAIS : c'est le plus grand cadre du bon
    /// rapport tenant dans la source. Un export rapide sert à voir vite ; le
    /// gonfler en 4K coûterait du temps et de l'espace pour des pixels
    /// inventés.
    static func reframe(source: URL,
                        outputFormat: MontageOutputFormat,
                        cropToFill: Bool,
                        cropCenter: CGPoint) async throws -> URL? {
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }

        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }

        let target = outputFormat.nativeRenderSize(sourceOriented: orientedSize,
                                                   cropToFill: cropToFill)
        guard target.width > 0, target.height > 0 else { return nil }

        // RIEN À FAIRE ? On ne réencode pas.
        //
        // Le rapport colle déjà et le cadrage est au centre : une passe de plus
        // ne changerait pas une image, elle ne ferait que perdre une génération
        // d'encodage.
        let sameShape = abs(orientedSize.width / orientedSize.height
                            - target.width / target.height) < 0.001
        // LE CENTRE BORNÉ, jamais celui du modèle. Un cadrage posé pour un
        // format vertical reste enregistré tel quel si l'on repasse en 16:9 ;
        // il est alors ramené au centre par le bornage, et la transformation
        // appliquée est l'identité. Comparer la valeur brute faisait réencoder
        // tout le clip pour produire un fichier identique au précédent.
        let safe = CropGeometry.clamp(cropCenter,
                                      orientedSize: orientedSize,
                                      renderSize: target,
                                      cropToFill: cropToFill)
        let centred = abs(safe.x - 0.5) < 0.001 && abs(safe.y - 0.5) < 0.001
        if sameShape && centred { return nil }

        let composition = AVMutableVideoComposition()
        composition.renderSize = target
        // La cadence du fichier rendu est déjà la bonne : on la conserve telle
        // quelle plutôt que d'en imposer une seconde.
        let nominal = (try? await track.load(.nominalFrameRate)) ?? 60
        composition.frameDuration = CMTime(
            value: 1, timescale: CMTimeScale(max(1, nominal.rounded()))
        )

        // AUCUN ESPACE FORCÉ, pour la même raison qu'au montage : ces
        // propriétés imposeraient une matrice, et la colorimétrie d'un rush est
        // déduite de sa seule fonction de transfert. Un fichier à matrice non
        // standard serait classé « sdr » puis forcé en 709 — la façon la plus
        // sûre de fabriquer la dominante qu'on cherche à éliminer. On laisse
        // AVFoundation propager celle de la source, qui est étiquetée par le
        // pipeline de rendu une étape plus tôt.

        let instruction = AVMutableVideoCompositionInstruction()
        let duration = try await asset.load(.duration)
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            MontageComposer.fillTransform(size: naturalSize,
                                          transform: transform,
                                          into: target,
                                          cropToFill: cropToFill,
                                          cropCenter: cropCenter),
            at: .zero
        )
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let output = source.deletingLastPathComponent()
            .appendingPathComponent("framed-" + source.lastPathComponent)
        try? FileManager.default.removeItem(at: output)

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality
        ) else { return nil }
        session.videoComposition = composition

        do {
            try await session.export(to: output, as: .mov)
        } catch {
            // ÉCHEC SANS CONSÉQUENCE : l'appelant garde le fichier d'origine.
            // Un clip au mauvais cadrage vaut mieux qu'un export perdu.
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }
}
