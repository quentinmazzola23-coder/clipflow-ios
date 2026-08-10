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
    private var vtInputPool: CVPixelBufferPool?
    private var vtDestinationPool: CVPixelBufferPool?
    private var bgraOutputPool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

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

    /// Formats de pixel acceptés en SOURCE par la configuration (la clé peut
    /// porter un nombre unique ou une liste).
    private static func supportedSourceFormats(
        of configuration: VTFrameRateConversionConfiguration
    ) -> [OSType] {
        guard let attributes = configuration.sourcePixelBufferAttributes as? [String: Any],
              let value = attributes[kCVPixelBufferPixelFormatTypeKey as String] else { return [] }
        if let number = value as? NSNumber { return [number.uint32Value] }
        if let list = value as? [NSNumber] { return list.map { $0.uint32Value } }
        return []
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

        // NÉGOCIATION du format de travail.
        let supported = Self.supportedSourceFormats(of: configuration)
        if supported.isEmpty || supported.contains(kCVPixelFormatType_32BGRA) {
            usesDirectBGRA = true
            vtFormat = kCVPixelFormatType_32BGRA
        } else {
            // La configuration impose son format : conversions aux frontières.
            usesDirectBGRA = false
            vtFormat = supported[0]
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session
            )
            guard status == noErr, let session else {
                throw InterpolationError.processingFailed("VTPixelTransferSession indisponible (\(status)).")
            }
            transferSession = session
            vtInputPool = try Self.makePool(
                width: width, height: height, format: vtFormat,
                base: configuration.sourcePixelBufferAttributes as? [String: Any]
            )
            bgraOutputPool = try Self.makePool(
                width: width, height: height,
                format: kCVPixelFormatType_32BGRA, base: nil
            )
        }
        vtDestinationPool = try Self.makePool(
            width: width, height: height, format: vtFormat,
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
        let interval = CMTimeSubtract(nextPTS, previousPTS)
        for phase in phases {
            guard let buffer = buffer(from: vtDestinationPool) else {
                throw InterpolationError.bufferAllocationFailed
            }
            let offsetSeconds = interval.seconds * Double(phase)
            let pts = CMTimeAdd(previousPTS, CMTime(seconds: offsetSeconds, preferredTimescale: interval.timescale))
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

        // Frontière de SORTIE : retour en BGRA uniforme si nécessaire.
        if usesDirectBGRA {
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
