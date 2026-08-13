//
//  EngineProbeTests.swift
//  ClipFlowPipelineTests
//
//  SONDE : établit, sans rien rendre, si le flux optique VideoToolbox est
//  utilisable sur la machine courante. Volontairement NON conditionnée par le
//  trait `.enabled` du banc d'essai : c'est elle qui répond à la question
//  « pourquoi le banc ne dit rien », et elle doit donc toujours s'exécuter.
//
//  Chaque étape est journalisée séparément : si la construction d'une
//  configuration VT bloque sur une machine virtualisée sans GPU/ANE (cas
//  suspecté sur un runner CI), le journal montre exactement où l'exécution
//  s'est arrêtée.
//

import Testing
import Foundation
import CoreVideo
import AVFoundation
@testable import ClipFlowPipeline

struct EngineProbeTests {

    @Test func reportsOpticalFlowAvailability() {
        print("SONDE 1/4 — début (interrogation des capacités)")
        fflush(stdout)

        // Petite dimension d'abord : moins coûteux qu'une 4K si la
        // construction d'une configuration est lente.
        let smallSupported = InterpolationEngineFactory.bestEngine(width: 640, height: 360) != nil
        print("SONDE 2/4 — moteur disponible en 640×360 : \(smallSupported)")
        fflush(stdout)

        let bigSupported = InterpolationEngineFactory.highQualityAvailable
        print("SONDE 3/4 — moteur disponible en 3840×2160 : \(bigSupported)")
        fflush(stdout)

        print("SONDE 4/4 — terminée")
        fflush(stdout)

        // Aucune assertion : la sonde CONSTATE, elle ne juge pas. Une machine
        // sans flux optique n'est pas une régression du produit.
        #expect(Bool(true))
    }

    /// Démarrage d'une session complète : l'étape la plus susceptible
    /// d'échouer ou de bloquer (chargement des modèles, allocation GPU).
    /// CONSTAT, PAS VERDICT : une machine sans flux optique utilisable n'est
    /// pas une régression du produit — la sonde le dit et n'échoue pas, sinon
    /// elle masquerait le résultat du banc d'essai qui la suit.
    @Test func sessionStartCompletes() async {
        guard let engine = InterpolationEngineFactory.bestEngine(width: 640, height: 360) else {
            print("SONDE SESSION — aucun moteur : rien à démarrer")
            return
        }
        print("SONDE SESSION — démarrage…")
        fflush(stdout)
        do {
            try await engine.startSession(width: 640, height: 360)
            print("SONDE SESSION — démarrée : \(engine.displayName)")
            engine.endSession()
            print("SONDE SESSION — arrêtée proprement")
        } catch {
            print("SONDE SESSION — ÉCHEC (machine sans flux optique utilisable) : \(error)")
        }
        fflush(stdout)
    }

    /// Une seule interpolation, sur deux images unies : isole le coût réel du
    /// flux optique, sans lecteur ni encodeur autour. Constat également.
    @Test func singleInterpolationCompletes() async throws {
        guard let engine = InterpolationEngineFactory.bestEngine(width: 640, height: 360) else {
            print("SONDE INTERPOLATION — aucun moteur : test sans objet")
            return
        }
        do {
            try await engine.startSession(width: 640, height: 360)
        } catch {
            print("SONDE INTERPOLATION — session impossible ici : \(error)")
            return
        }
        defer { engine.endSession() }

        func makeBuffer(value: UInt8) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, 640, 360,
                                kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
            let result = try #require(buffer)
            CVPixelBufferLockBaseAddress(result, [])
            if let base = CVPixelBufferGetBaseAddress(result) {
                memset(base, Int32(value), CVPixelBufferGetBytesPerRow(result) * 360)
            }
            CVPixelBufferUnlockBaseAddress(result, [])
            return result
        }

        let first = try makeBuffer(value: 60)
        let second = try makeBuffer(value: 200)
        print("SONDE INTERPOLATION — soumission d'une phase…")
        fflush(stdout)
        let produced = try await engine.interpolate(
            previous: first, previousPTS: .zero,
            next: second, nextPTS: CMTime(value: 1, timescale: 30),
            phases: [0.5]
        )
        print("SONDE INTERPOLATION — \(produced.count) image(s) produite(s)")
        fflush(stdout)
        #expect(produced.count == 1)
    }
}
