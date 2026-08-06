//
//  VideoToolboxFrameInterpolationEngine.swift
//  ClipFlow
//
//  Moteur principal : VTFrameProcessor + VTFrameRateConversionConfiguration
//  (iOS 26+). Flux optique calculé à la volée par VideoToolbox,
//  qualityPrioritization = .quality, soumission séquentielle.
//
//  ⚠️ IMPORTANT — à vérifier sur Mac : ce fichier suit la documentation Apple
//  (VTFrameRateConversionConfiguration, VTFrameProcessorFrame,
//  VTFrameRateConversionParameters). Ce projet a été généré hors macOS ;
//  confronter chaque signature aux interfaces réelles du SDK iOS 26 dans Xcode
//  avant la première compilation (voir README, section « Vérification API »).
//

import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox

@available(iOS 26.0, *)
final class VideoToolboxFrameInterpolationEngine: FrameInterpolationEngine {

    let displayName = "VideoToolbox — flux optique (qualité maximale)"

    private var processor: VTFrameProcessor?
    private var configuration: VTFrameRateConversionConfiguration?
    private var destinationPool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    // MARK: - Compatibilité

    /// Vérifie la prise en charge réelle : classe disponible + configuration
    /// constructible pour ces dimensions. Aucune supposition.
    static func isSupported(width: Int, height: Int) -> Bool {
        guard VTFrameRateConversionConfiguration.isSupported else { return false }
        // La construction échoue (nil) si les dimensions sont hors bornes.
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
        // Exiger le format que la configuration accepte. Renseigné au démarrage
        // de session ; avant cela, nil.
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

        // Pool de destination construit d'après les attributs EXIGÉS par la
        // configuration — jamais supposés.
        var poolAttributes = configuration.destinationPixelBufferAttributes as? [String: Any] ?? [:]
        poolAttributes[kCVPixelBufferWidthKey as String] = width
        poolAttributes[kCVPixelBufferHeightKey as String] = height

        var pool: CVPixelBufferPool?
        let poolOptions: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolOptions as CFDictionary,
            poolAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw InterpolationError.bufferAllocationFailed
        }

        self.configuration = configuration
        self.processor = processor
        self.destinationPool = pool
        self.width = width
        self.height = height
    }

    func interpolate(previous: CVPixelBuffer,
                     previousPTS: CMTime,
                     next: CVPixelBuffer,
                     nextPTS: CMTime,
                     phases: [Float]) async throws -> [CVPixelBuffer] {
        guard let processor, destinationPool != nil else {
            throw InterpolationError.sessionNotStarted
        }
        guard !phases.isEmpty else { return [] }

        guard let sourceFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousPTS),
              let nextFrame = VTFrameProcessorFrame(buffer: next, presentationTimeStamp: nextPTS) else {
            throw InterpolationError.processingFailed("Création des VTFrameProcessorFrame impossible.")
        }

        // Une image de destination par phase, PTS interpolé linéairement
        // (le PTS exact de sortie est réécrit par le pipeline d'encodage).
        var destinationFrames: [VTFrameProcessorFrame] = []
        destinationFrames.reserveCapacity(phases.count)
        let interval = CMTimeSubtract(nextPTS, previousPTS)
        for phase in phases {
            guard let buffer = makeDestinationBuffer() else {
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
            opticalFlow: nil,                   // calculé à la volée par la configuration
            interpolationPhase: phases,
            submissionMode: .sequential,        // traitement séquentiel — mémoire maîtrisée
            destinationFrames: destinationFrames
        ) else {
            throw InterpolationError.processingFailed("Paramètres de conversion invalides (phases : \(phases)).")
        }

        do {
            try await processor.process(parameters: parameters)
        } catch {
            throw InterpolationError.processingFailed(String(describing: error))
        }

        return destinationFrames.map { $0.buffer }
    }

    func endSession() {
        processor?.endSession()
        processor = nil
        configuration = nil
        destinationPool = nil
    }

    // MARK: - Buffers

    private func makeDestinationBuffer() -> CVPixelBuffer? {
        guard let destinationPool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, destinationPool, &buffer)
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }
}
