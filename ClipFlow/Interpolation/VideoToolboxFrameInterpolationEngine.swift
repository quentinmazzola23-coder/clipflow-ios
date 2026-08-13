//
//  VideoToolboxFrameInterpolationEngine.swift
//  ClipFlow
//
//  Moteur principal : VTFrameProcessor + VTFrameRateConversionConfiguration
//  (iOS 26+). Flux optique à la volée, qualityPrioritization = .quality.
//
//  CONTRAT : l'extérieur du moteur est TOUJOURS en 32BGRA (chaîne tout-RGB du
//  pipeline). Le format de travail INTERNE est NÉGOCIÉ avec la configuration
//  au démarrage — jamais supposé : fournir à VT un format qu'il n'exige pas
//  réinterprète la mémoire des plans et inverse la chrominance (ciel rose,
//  verts turquoise — constaté sur exports réels). Si la configuration
//  n'accepte pas BGRA, les frontières sont converties par
//  VTPixelTransferSession (conversions couleur gérées par VideoToolbox).
//

import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import os

// Les classes VTFrameProcessor n'existent pas dans le SDK simulateur —
// moteur compilé uniquement pour appareil réel.
#if !targetEnvironment(simulator)

@available(iOS 26.0, *)
final class VideoToolboxFrameInterpolationEngine: FrameInterpolationEngine {

    let displayName = "VideoToolbox — flux optique (qualité maximale)"

    private var processor: VTFrameProcessor?
    private var configuration: VTFrameRateConversionConfiguration?
    /// Format de travail interne négocié (BGRA si accepté, sinon le premier
    /// format exigé par la configuration).
    private var vtFormat: OSType = kCVPixelFormatType_32BGRA
    private var usesDirectBGRA = true
    private var transferSession: VTPixelTransferSession?
    /// Format réel du pool de destination — négocié SÉPARÉMENT du format
    /// d'entrée : VideoToolbox peut parfaitement entrer en RGB et sortir en
    /// YCbCr. Les confondre fait écrire une géométrie de plans dans un buffer
    /// déclaré autrement : aucune erreur, pixels faux.
    private var vtDestinationFormat: OSType = kCVPixelFormatType_32BGRA
    private var vtInputPool: CVPixelBufferPool?
    private var vtDestinationPool: CVPixelBufferPool?
    private var bgraOutputPool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    private static let log = OSLog(subsystem: "com.example.clipflow", category: "Interpolation")

    // MARK: - Compatibilité

    /// Vérifie la prise en charge réelle : classe disponible + configuration
    /// constructible pour ces dimensions. Aucune supposition.
    static func isSupported(width: Int, height: Int) -> Bool {
        guard VTFrameRateConversionConfiguration.isSupported else { return false }
        let probe = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: .quality,
            revision: .revision1
        )
        return probe != nil
    }

    // MARK: - FrameInterpolationEngine

    var sourcePixelBufferAttributes: [String: Any]? {
        configuration?.sourcePixelBufferAttributes as? [String: Any]
    }

    func startSession(width: Int, height: Int) async throws {
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,          // flux optique calculé à la volée
            qualityPrioritization: .quality,    // qualité maximale (hors temps réel)
            revision: .revision1
        ) else {
            throw InterpolationError.unsupportedDimensions(width: width, height: height)
        }

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: configuration)

        // ÉTAPE 0 — INSTRUMENTATION. Rien dans le dépôt ne montrait ce que
        // VideoToolbox demande réellement ; toute la négociation reposait sur
        // des suppositions. À retirer une fois les branches arbitrées.
        os_log("VT config %dx%d — sourcePixelBufferAttributes :\n%{public}@",
               log: Self.log, type: .info, width, height,
               VideoToolboxFormatProbe.describeAttributes(configuration.sourcePixelBufferAttributes))
        os_log("VT config %dx%d — destinationPixelBufferAttributes :\n%{public}@",
               log: Self.log, type: .info, width, height,
               VideoToolboxFormatProbe.describeAttributes(configuration.destinationPixelBufferAttributes))
        let probedSource = VideoToolboxFormatProbe.pixelFormats(in: configuration.sourcePixelBufferAttributes)
        let probedDestination = VideoToolboxFormatProbe.pixelFormats(in: configuration.destinationPixelBufferAttributes)
        os_log("VT formats — source : [%{public}@] / destination : [%{public}@]",
               log: Self.log, type: .info,
               probedSource.map(VideoToolboxFormatProbe.fourCC).joined(separator: ", "),
               probedDestination.map(VideoToolboxFormatProbe.fourCC).joined(separator: ", "))

        // NÉGOCIATION du format d'ENTRÉE. AUCUNE SUPPOSITION : une liste vide
        // signifie que la configuration n'a rien annoncé d'exploitable —
        // supposer BGRA réinterpréterait la mémoire des plans SANS erreur
        // (ciel rose, verts turquoise, constaté sur exports réels). Échec net.
        guard !probedSource.isEmpty else {
            processor.endSession()
            throw InterpolationError.processingFailed(
                "Aucun format de pixel source exploitable annoncé par "
                + "VTFrameRateConversionConfiguration. Attributs bruts : "
                + String(describing: configuration.sourcePixelBufferAttributes)
            )
        }
        if probedSource.contains(kCVPixelFormatType_32BGRA) {
            usesDirectBGRA = true
            vtFormat = kCVPixelFormatType_32BGRA
        } else {
            // La configuration impose son format : conversions aux frontières.
            usesDirectBGRA = false
            vtFormat = probedSource[0]
        }

        // NÉGOCIATION du format de DESTINATION, indépendante de l'entrée.
        guard !probedDestination.isEmpty else {
            processor.endSession()
            throw InterpolationError.processingFailed(
                "Aucun format de pixel destination annoncé. Attributs bruts : "
                + String(describing: configuration.destinationPixelBufferAttributes)
            )
        }
        // Préférence au format d'entrée quand il est aussi proposé en sortie
        // (une conversion de moins), jamais imposition.
        vtDestinationFormat = probedDestination.contains(vtFormat) ? vtFormat : probedDestination[0]

        // La session de transfert sert dès que L'UNE OU L'AUTRE frontière
        // convertit — les lier à la seule branche d'entrée laissait la sortie
        // sans convertisseur.
        let needsInputConversion = !usesDirectBGRA
        let needsOutputConversion = vtDestinationFormat != kCVPixelFormatType_32BGRA
        if needsInputConversion || needsOutputConversion {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session
            )
            guard status == noErr, let session else {
                processor.endSession()
                throw InterpolationError.processingFailed("VTPixelTransferSession indisponible (\(status)).")
            }
            transferSession = session
        }
        if needsInputConversion {
            vtInputPool = try Self.makePool(
                width: width, height: height, format: vtFormat,
                base: configuration.sourcePixelBufferAttributes as? [String: Any]
            )
        }
        if needsOutputConversion {
            bgraOutputPool = try Self.makePool(
                width: width, height: height,
                format: kCVPixelFormatType_32BGRA, base: nil
            )
        }
        vtDestinationPool = try Self.makePool(
            width: width, height: height, format: vtDestinationFormat,
            base: configuration.destinationPixelBufferAttributes as? [String: Any]
        )

        self.configuration = configuration
        self.processor = processor
        self.width = width
        self.height = height
    }

    func interpolate(previous: CVPixelBuffer,
                     previousPTS: CMTime,
                     next: CVPixelBuffer,
                     nextPTS: CMTime,
                     phases: [Float]) async throws -> [CVPixelBuffer] {
        guard let processor, vtDestinationPool != nil else {
            throw InterpolationError.sessionNotStarted
        }
        guard !phases.isEmpty else { return [] }

        // Frontière d'ENTRÉE : conversion vers le format négocié si nécessaire.
        let vtPrevious = usesDirectBGRA ? previous : try convert(previous, using: vtInputPool)
        let vtNext = usesDirectBGRA ? next : try convert(next, using: vtInputPool)

        guard let sourceFrame = VTFrameProcessorFrame(buffer: vtPrevious, presentationTimeStamp: previousPTS),
              let nextFrame = VTFrameProcessorFrame(buffer: vtNext, presentationTimeStamp: nextPTS) else {
            throw InterpolationError.processingFailed("Création des VTFrameProcessorFrame impossible.")
        }

        var destinationFrames: [VTFrameProcessorFrame] = []
        destinationFrames.reserveCapacity(phases.count)
        // Base de temps FIXE et fine (1/90000) : arrondir au timescale SOURCE
        // confondait deux phases dès que celui-ci était grossier (≤ 100 sur les
        // réencodages Photos), produisant des PTS de destination identiques ou
        // décroissants — sans erreur, avec des images fausses.
        let interval = CMTimeSubtract(nextPTS, previousPTS)
        let ptsTimescale: CMTimeScale = 90_000
        let base = CMTimeConvertScale(previousPTS, timescale: ptsTimescale,
                                      method: .roundHalfAwayFromZero)
        let span = CMTimeConvertScale(interval, timescale: ptsTimescale,
                                      method: .roundHalfAwayFromZero)
        var lastPTS = base
        for phase in phases {
            guard let buffer = buffer(from: vtDestinationPool) else {
                throw InterpolationError.bufferAllocationFailed
            }
            let pts = CMTimeAdd(base, CMTimeMultiplyByFloat64(span, multiplier: Float64(phase)))
            // Une phase strictement croissante DOIT donner un PTS strictement
            // croissant. Sinon la soumission est dégénérée : échec net plutôt
            // qu'un groupe d'images fausses.
            guard CMTimeCompare(pts, lastPTS) > 0 else {
                throw InterpolationError.processingFailed(
                    "PTS de destination non monotone (phase \(phase), intervalle "
                    + "\(interval.seconds) s, timescale source \(interval.timescale))."
                )
            }
            lastPTS = pts
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: pts) else {
                throw InterpolationError.processingFailed("Création d'une frame de destination impossible.")
            }
            destinationFrames.append(frame)
        }

        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: sourceFrame,
            nextFrame: nextFrame,
            opticalFlow: nil,
            interpolationPhase: phases,
            submissionMode: .sequential,
            destinationFrames: destinationFrames
        ) else {
            throw InterpolationError.processingFailed("Paramètres de conversion invalides (phases : \(phases)).")
        }

        do {
            try await processor.process(parameters: parameters)
        } catch {
            throw InterpolationError.processingFailed(String(describing: error))
        }

        // Frontière de SORTIE : dépend du format du pool de DESTINATION, pas de
        // la branche d'entrée — les confondre laissait sortir du YCbCr annoncé
        // comme du BGRA.
        if vtDestinationFormat == kCVPixelFormatType_32BGRA {
            return destinationFrames.map { $0.buffer }
        }
        return try destinationFrames.map { try convert($0.buffer, using: bgraOutputPool) }
    }

    func endSession() {
        processor?.endSession()
        processor = nil
        configuration = nil
        transferSession = nil
        vtInputPool = nil
        vtDestinationPool = nil
        bgraOutputPool = nil
        vtDestinationFormat = kCVPixelFormatType_32BGRA
        usesDirectBGRA = true
        vtFormat = kCVPixelFormatType_32BGRA
    }

    // MARK: - Buffers et conversions

    private static func makePool(width: Int, height: Int,
                                 format: OSType,
                                 base: [String: Any]?) throws -> CVPixelBufferPool {
        var attributes = base ?? [:]
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true

        var pool: CVPixelBufferPool?
        let poolOptions: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolOptions as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw InterpolationError.bufferAllocationFailed
        }
        return pool
    }

    private func buffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Conversion de format couleur-sûre (VideoToolbox gère matrices et plages
    /// d'après les attachements des buffers).
    private func convert(_ source: CVPixelBuffer, using pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        guard let transferSession else {
            throw InterpolationError.processingFailed("Session de transfert absente.")
        }
        guard let destination = buffer(from: pool) else {
            throw InterpolationError.bufferAllocationFailed
        }
        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        guard status == noErr else {
            throw InterpolationError.processingFailed("Conversion de format échouée (\(status)).")
        }
        return destination
    }
}

#endif
