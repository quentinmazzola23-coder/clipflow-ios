//
//  MontageSmoothing.swift
//  ClipFlow
//
//  LISSAGE DES CLIPS À CADENCE BASSE, pour le montage.
//
//  Le montage assemble des plages cachées et les étire par `scaleTimeRange` :
//  il n'interpole jamais. Un clip issu d'une source 30 i/s y est donc DUPLIQUÉ
//  vers 60 i/s, et son mouvement tranche visiblement avec celui des clips
//  60 i/s du même montage — deux rendus de mouvement dans la même vidéo.
//
//  Cette étape rend une fois, par clip concerné, une version à 60 i/s obtenue
//  par flux optique, que le montage insère à la place de la plage cachée.
//
//  ELLE RÉUTILISE `VideoRenderPipeline` PLUTÔT QUE D'INTERPOLER ELLE-MÊME, et
//  c'est le point important. Ce pipeline sait déjà : négocier les formats avec
//  VideoToolbox, conserver la colorimétrie, compter les images fabriquées, et
//  surtout REJETER un rendu dont il mesure des images aberrantes pour le
//  refaire sans flux. Réécrire une interpolation dans la seconde passe du
//  montage aurait signifié un second moteur à faire correspondre, sans aucun
//  de ces garde-fous.
//
//  Le lissage ne s'applique QU'AU RÉGIME FACILE : source à cadence basse, clip
//  NON ralenti, donc deux images vraies séparées d'1/30 s et une seule à
//  fabriquer entre elles. Un clip ralenti depuis du 30 i/s (validé avant le
//  plafond de vitesse) est laissé tel quel : il faudrait y fabriquer trois
//  images sur quatre, ce qui est exactement la configuration qui a fait
//  désactiver le flux optique par défaut dans ce projet.
//

import Foundation
import AVFoundation

/// De quoi rendre la version lissée d'un clip, sans dépendre de SwiftData.
struct MontageSmoothingRequest: Sendable {
    /// Identifiant du clip dans le plan (index dans `orderedPassages`).
    var clipID: Int
    /// Fichier de la plage cachée à lisser.
    var sourceURL: URL
    /// Plage du clip DANS ce fichier.
    var sourceRange: CMTimeRange
    var finalDuration: ExactDuration
    var colorimetry: String
    /// Nom du fichier lissé à produire.
    var filename: String
}

enum MontageSmoothing {

    /// Cadence de sortie du montage. Le lissage n'a de sens qu'en la visant.
    static let targetFPS = 60

    /// Ce clip mérite-t-il un lissage ?
    ///
    /// - Source à 30 i/s ou moins : au-delà, il n'y a rien à combler.
    /// - Clip NON ralenti : voir l'en-tête, le régime ralenti est celui qu'on
    ///   refuse d'interpoler.
    /// - Source SDR : le pipeline n'interpole jamais une source HDR — rendre
    ///   quand même produirait un fichier identique, deux fois plus lentement.
    static func needsSmoothing(sourceFrameRate: Double,
                               speedNumerator: Int,
                               speedDenominator: Int,
                               colorimetry: String) -> Bool {
        guard sourceFrameRate > 1,
              sourceFrameRate <= RationalSpeed.slowMotionFloor else { return false }
        guard speedNumerator >= speedDenominator else { return false }
        return colorimetry == "sdr"
    }

    /// Rend les versions lissées manquantes.
    ///
    /// Retourne, par clip, le NOM DU FICHIER produit. La persistance revient à
    /// l'appelant : cette fonction ne connaît pas SwiftData, et rendre le
    /// résultat plutôt que de rappeler un bloc lui évite d'avoir à traverser
    /// une frontière d'isolation pour toucher au modèle.
    ///
    /// Un échec n'interrompt RIEN. Le clip garde sa plage cachée et sera
    /// dupliqué vers 60 i/s comme avant : moins fluide, jamais faux. Un montage
    /// entier ne doit pas échouer parce qu'un clip n'a pas pu être lissé.
    static func prepare(_ requests: [MontageSmoothingRequest],
                        onProgress: @escaping @Sendable (Double) -> Void)
    async -> [Int: String] {
        guard !requests.isEmpty else { onProgress(1); return [:] }
        let total = Double(requests.count)
        var produced: [Int: String] = [:]

        for (index, request) in requests.enumerated() {
            if Task.isCancelled { return produced }
            let base = Double(index) / total

            let job = RenderJob(
                sourceURL: request.sourceURL,
                sourceRange: request.sourceRange,
                finalDuration: request.finalDuration,
                // VITESSE RÉELLE : on ne ralentit pas, on comble. Le clip garde
                // sa durée, seule sa cadence monte.
                speed: .real,
                fps: targetFPS,
                codec: "hevc",
                outputFilename: request.filename,
                colorimetry: request.colorimetry,
                // Flux optique DEMANDÉ : c'est toute la raison d'être de
                // l'étape. Le pipeline garde son filet — s'il mesure des images
                // aberrantes, il refait la passe sans flux, et le clip reste
                // correct.
                forceFastEngine: false
            )

            guard let result = try? await VideoRenderPipeline.render(job: job, onProgress: { value in
                onProgress(base + value / total)
            }) else {
                onProgress(Double(index + 1) / total)
                continue
            }

            // Le pipeline écrit dans le dossier des exports, qui est PURGÉ au
            // lancement : le fichier lissé doit rejoindre les plages cachées
            // pour survivre à un redémarrage — c'est un cache durable, rendu
            // une fois et réutilisé à chaque export suivant.
            let destination = StorageManager.url(
                forCachedRangeRelativePath: request.filename)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: result.outputURL, to: destination)
                StorageManager.excludeFromBackup(destination)
                produced[request.clipID] = request.filename
            } catch {
                try? FileManager.default.removeItem(at: result.outputURL)
            }
            onProgress(Double(index + 1) / total)
        }
        onProgress(1)
        return produced
    }

    /// Oublie la version lissée d'un passage, fichier compris.
    ///
    /// À APPELER PARTOUT OÙ LA PLAGE CACHÉE CHANGE : le fichier lissé en est
    /// une copie à 60 i/s et partage sa base de temps. Survivre à un
    /// recadrage de la sélection en ferait un contenu faux, pas seulement
    /// périmé — et il est indiscernable d'une plage cachée valide.
    static func discard(_ passage: Passage) {
        guard let path = passage.smoothedRangeRelativePath else { return }
        try? FileManager.default.removeItem(
            at: StorageManager.url(forCachedRangeRelativePath: path))
        passage.smoothedRangeRelativePath = nil
    }
}
