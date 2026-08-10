//
//  SyntheticVideoTests.swift
//  ClipFlowTests
//
//  Vidéos synthétiques générées avec AVAssetWriter : valident le pipeline
//  lecture → plan → écriture sur du contenu à mouvement mesurable.
//  Exécution sur appareil réel ou simulateur (AVFoundation requis).
//

import Testing
import AVFoundation
import CoreMedia
@testable import ClipFlow

enum SyntheticVideoFactory {

    /// Génère un clip de test : barre verticale se déplaçant d'un pas constant
    /// par image (mouvement facilement mesurable), cadence et durée choisies.
    static func makeClip(fps: Int32,
                         frames: Int,
                         size: CGSize = CGSize(width: 320, height: 240)) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-\(fps)fps-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let buffer else { break }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                memset(base, 16, bytesPerRow * Int(size.height))
                // Barre blanche : avance de 4 px par image.
                let barX = (frameIndex * 4) % max(Int(size.width) - 8, 1)
                for row in 0..<Int(size.height) {
                    let rowPointer = base.advanced(by: row * bytesPerRow + barX * 4)
                    memset(rowPointer, 255, 8 * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            adaptor.append(buffer, withPresentationTime: pts)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "SyntheticVideo", code: 1)
        }
        return url
    }
}

struct SyntheticVideoTests {

    @Test func syntheticClipHasExactFrameCountAndDuration() async throws {
        let url = try await SyntheticVideoFactory.makeClip(fps: 30, frames: 30)
        defer { try? FileManager.default.removeItem(at: url) }

        let (duration, frameCount, _) = try await VideoRenderPipeline.verify(outputURL: url)
        #expect(frameCount == 30)
        #expect(abs(duration - 1.0) < 0.05)
    }

    @Test func syntheticClip60fps() async throws {
        let url = try await SyntheticVideoFactory.makeClip(fps: 60, frames: 120)
        defer { try? FileManager.default.removeItem(at: url) }

        let (duration, frameCount, _) = try await VideoRenderPipeline.verify(outputURL: url)
        #expect(frameCount == 120)
        #expect(abs(duration - 2.0) < 0.05)
    }

    /// Rendu de bout en bout avec le moteur de secours (sans flux optique,
    /// disponible partout) : 1,3 s / 78 images / 60 fps depuis une source 60 fps.
    /// Le moteur VideoToolbox est validé séparément SUR APPAREIL RÉEL.
    @Test func endToEndRenderProduces78Frames() async throws {
        let url = try await SyntheticVideoFactory.makeClip(fps: 60, frames: 120)
        defer { try? FileManager.default.removeItem(at: url) }

        let job = RenderJob(
            sourceURL: url,
            sourceRange: CMTimeRange(
                start: CMTime(value: 30, timescale: 60),          // 0,5 s
                duration: TimeMath.sourceDuration(
                    final: ExactDuration(centiseconds: 130), speed: .half
                )                                                  // 0,65 s
            ),
            finalDuration: ExactDuration(centiseconds: 130),
            speed: .half,
            fps: 60,
            codec: "h264",
            outputFilename: "test-render-\(UUID().uuidString).mov",
            colorimetry: "sdr",
            forceFastEngine: true
        )
        let result = try await VideoRenderPipeline.render(job: job) { _ in }
        defer { try? FileManager.default.removeItem(at: result.outputURL) }

        #expect(result.frameCount == 78)
        #expect(abs(result.durationSeconds - 1.3) < 0.02)
        #expect(result.copiedFrames + result.interpolatedFrames == 78)
    }
}
