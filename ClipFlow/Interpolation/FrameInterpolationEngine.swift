//
//  FrameInterpolationEngine.swift
//  ClipFlow
//
//  Abstraction des moteurs d'interpolation d'images. Permet :
//  1. VideoToolboxFrameInterpolationEngine (iOS 26+, flux optique matériel) ;
//  2. un moteur de secours (duplication d'image la plus proche, clairement
//     nommé « Rapide — sans interpolation avancée ») ;
//  3. plus tard, VisionMetalFrameInterpolationEngine (VNGenerateOpticalFlowRequest
//     .veryHigh + warping Metal) et CoreMLFrameInterpolationEngine.
//

import Foundation
import CoreVideo
import CoreMedia

protocol FrameInterpolationEngine: AnyObject {
    /// Nom affiché à l'utilisateur — doit être honnête sur la qualité.
    var displayName: String { get }

    /// Attributs de pixel buffer exigés par le moteur pour ses entrées,
    /// à passer au décodeur (AVAssetReader). nil = pas d'exigence.
    var sourcePixelBufferAttributes: [String: Any]? { get }

    /// Démarre une session pour des images de dimensions données.
    func startSession(width: Int, height: Int) async throws

    /// Produit les images interpolées entre `previous` et `next` aux phases
    /// demandées (croissantes, dans ]0;1[). Retourne un buffer par phase.
    func interpolate(previous: CVPixelBuffer,
                     previousPTS: CMTime,
                     next: CVPixelBuffer,
                     nextPTS: CMTime,
                     phases: [Float]) async throws -> [CVPixelBuffer]

    /// Termine la session, libère les ressources.
    func endSession()
}

enum InterpolationError: Error, LocalizedError {
    case unsupportedOnThisDevice
    case unsupportedDimensions(width: Int, height: Int)
    case sessionNotStarted
    case processingFailed(String)
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOnThisDevice:
            return "L'interpolation VideoToolbox n'est pas disponible sur cet appareil."
        case .unsupportedDimensions(let w, let h):
            return "Dimensions non prises en charge par le moteur d'interpolation : \(w)×\(h)."
        case .sessionNotStarted:
            return "Session d'interpolation non démarrée."
        case .processingFailed(let details):
            return "Échec du traitement d'interpolation : \(details)"
        case .bufferAllocationFailed:
            return "Allocation de pixel buffer impossible (mémoire insuffisante ?)."
        }
    }
}

enum InterpolationEngineFactory {

    /// Meilleur moteur disponible sur cet appareil pour ces dimensions.
    /// Ordre : VideoToolbox (qualité) → secours (duplication, nommé honnêtement).
    /// Le moteur VideoToolbox n'existe pas dans le SDK simulateur.
    static func bestEngine(width: Int, height: Int) -> FrameInterpolationEngine {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            if VideoToolboxFrameInterpolationEngine.isSupported(width: width, height: height) {
                return VideoToolboxFrameInterpolationEngine()
            }
        }
        #endif
        return PassthroughRetimeEngine()
    }

    /// Le moteur haute qualité est-il disponible ? (pour l'afficher dans l'UI)
    static var highQualityAvailable: Bool {
        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            return VideoToolboxFrameInterpolationEngine.isSupported(width: 3840, height: 2160)
        }
        #endif
        return false
    }
}
