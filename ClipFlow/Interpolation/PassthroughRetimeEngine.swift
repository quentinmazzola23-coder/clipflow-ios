//
//  PassthroughRetimeEngine.swift
//  ClipFlow
//
//  Moteur HONNÊTE : ne fait AUCUNE interpolation. Pour chaque phase, duplique
//  l'image source la plus proche.
//
//  C'est le mode PAR DÉFAUT depuis que le flux optique s'est révélé capable de
//  fabriquer des artefacts visibles sur du contenu réel : aucun pixel n'est
//  inventé ici, donc aucun artefact ne peut naître du rendu. Le mouvement est
//  plus saccadé — compromis assumé, réversible dans le menu ⋯.
//

import Foundation
import CoreVideo
import CoreMedia

final class PassthroughRetimeEngine: FrameInterpolationEngine {

    let displayName = "Images réelles répétées (sans interpolation)"

    var sourcePixelBufferAttributes: [String: Any]? { nil }

    func startSession(width: Int, height: Int) async throws {
        // Rien à préparer.
    }

    func interpolate(previous: CVPixelBuffer,
                     previousPTS: CMTime,
                     next: CVPixelBuffer,
                     nextPTS: CMTime,
                     phases: [Float]) async throws -> [CVPixelBuffer] {
        // Duplication : phase < 0,5 → image précédente, sinon suivante.
        // Les CVPixelBuffer sont immuables dans notre pipeline (lecture seule),
        // le partage de référence est donc sûr.
        phases.map { phase in
            phase < 0.5 ? previous : next
        }
    }

    func endSession() {
        // Rien à libérer.
    }
}
