//
//  OverlayStore.swift
//  ClipFlow
//
//  Fichiers image des incrustations, et RÉSOLUTION des portées.
//
//  Les incrustations sont exprimées en RANGS DE CLIPS (« clips 4 à 12 »), pas
//  en secondes : c'est ainsi que l'utilisateur les pose, et surtout ça résiste
//  au déplacement de la fenêtre musicale — changer le départ du montage
//  décalerait toutes les secondes, pas les rangs.
//
//  La conversion en temps absolu se fait ICI, une seule fois, à partir du plan
//  de montage. L'aperçu et l'export consomment le même résultat : ce qu'on
//  voit est ce qu'on exporte.
//

import Foundation
import CoreMedia
import UIKit

enum OverlayStoreError: Error, LocalizedError {
    case unreadableImage
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Cette image n'a pas pu être lue. Choisissez un PNG ou un JPEG — "
                + "un PNG à fond transparent donne le meilleur résultat pour un logo."
        case .copyFailed(let details):
            return "L'image n'a pas pu être enregistrée : \(details)"
        }
    }
}

enum OverlayStore {

    /// Dossier des images, créé UNE FOIS.
    ///
    /// C'était une propriété calculée qui créait le dossier à chaque accès :
    /// pendant un glissement, la résolution des portées le touchait des
    /// centaines de fois par seconde sur le fil principal.
    static let overlaysDirectory: URL = {
        let url = StorageManager.applicationSupportDirectory
            .appendingPathComponent("Overlays", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(forImageNamed filename: String) -> URL {
        overlaysDirectory.appendingPathComponent(filename)
    }

    /// Enregistre une image choisie dans la photothèque ou dans Fichiers.
    ///
    /// Ré-encodée en PNG : la transparence est conservée (indispensable pour
    /// un logo), et on s'affranchit des formats exotiques (HEIC, TIFF) que la
    /// composition vidéo ne sait pas toujours lire.
    static func saveImage(_ image: UIImage) throws -> String {
        // ORIENTATION APLATIE DANS LES PIXELS. Le PNG n'a pas de champ
        // d'orientation : `pngData()` sérialise l'image brute et PERD
        // l'orientation EXIF. Un logo photographié en portrait était donc
        // stocké couché, définitivement. Redessiner l'image la remet d'aplomb.
        let upright = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = upright.pngData() else { throw OverlayStoreError.unreadableImage }
        let filename = UUID().uuidString + ".png"
        do {
            try data.write(to: url(forImageNamed: filename), options: .atomic)
        } catch {
            throw OverlayStoreError.copyFailed(error.localizedDescription)
        }
        return filename
    }

    static func deleteImage(filename: String) {
        try? FileManager.default.removeItem(at: url(forImageNamed: filename))
    }

    // MARK: - Résolution des portées

    /// Convertit les incrustations d'un projet en plages de temps absolues.
    ///
    /// - `placements` : les clips réellement posés, dans l'ordre du montage.
    ///   Les rangs des incrustations désignent CES clips-là — pas les passages
    ///   du projet, dont certains ont pu être écartés faute de rush assez long.
    /// - `totalDuration` : fin du montage, pour les incrustations qui couvrent
    ///   toute la vidéo.
    static func resolve(_ layers: [OverlayLayer],
                        placements: [MontagePlacement],
                        totalDuration: CMTime) -> [ResolvedOverlay] {
        guard !placements.isEmpty else { return [] }
        let lastIndex = placements.count - 1

        return layers
            .sorted { $0.stackOrder < $1.stackOrder }
            .compactMap { layer -> ResolvedOverlay? in
                // Un texte vide ou une image manquante ne produisent rien —
                // plutôt que d'incruster un rectangle invisible.
                switch layer.kind {
                case .text where layer.text.trimmingCharacters(in: .whitespaces).isEmpty:
                    return nil
                case .image where layer.imageURL == nil:
                    return nil
                default:
                    break
                }

                let start: CMTime
                let duration: CMTime
                if layer.spansWholeMontage {
                    start = .zero
                    duration = totalDuration
                } else {
                    // Rangs BORNÉS au montage réel : un clip écarté peut avoir
                    // raccourci la liste depuis que l'incrustation a été posée.
                    let first = min(max(0, layer.firstClipIndex), lastIndex)
                    let last = min(max(first, layer.lastClipIndex), lastIndex)
                    start = placements[first].timelineStart
                    let end = CMTimeAdd(placements[last].timelineStart,
                                        placements[last].timelineDuration)
                    duration = CMTimeSubtract(end, start)
                }
                guard CMTimeCompare(duration, .zero) > 0 else { return nil }

                return ResolvedOverlay(
                    kind: layer.kind,
                    text: layer.text,
                    imageURL: layer.imageURL,
                    centerX: layer.centerX,
                    centerY: layer.centerY,
                    relativeWidth: layer.relativeWidth,
                    start: start,
                    duration: duration,
                    stackOrder: layer.stackOrder
                )
            }
    }
}
