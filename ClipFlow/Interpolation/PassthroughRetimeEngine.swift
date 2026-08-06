//
//  PassthroughRetimeEngine.swift
//  ClipFlow
//
//  Moteur de secours HONNÊTE : ne fait AUCUNE interpolation. Pour chaque phase,
//  duplique l'image source la plus proche. Nommé explicitement pour que
//  l'utilisateur sache qu'il n'obtient pas de flux optique.
//
//  Utilisé uniquement quand VideoToolbox n'est pas disponible, ou choisi
//  volontairement pour un aperçu rapide.
//

import Foundation
import CoreVideo
import CoreMedia

final class PassthroughRetimeEngine: FrameInterpolationEngine {

    let displayName = "Rapide — sans interpolation avancée"

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
