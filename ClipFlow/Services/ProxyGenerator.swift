//
//  ProxyGenerator.swift
//  ClipFlow
//
//  Génère les proxys ultra-légers : 144p (ou 240p), sans audio, tout-intra
//  (une image clé par image → scrubbing instantané), timestamps préservés.
//  Les proxys ne servent JAMAIS aux exports finaux.
//
//  Acteur : une seule génération à la fois, file FIFO, l'utilisateur peut
//  travailler sur les premiers rushes pendant que les suivants se génèrent.
//

import Foundation
import AVFoundation

/// État de génération publié vers l'interface.
struct ProxyGenerationStatus: Sendable {
    var totalQueued: Int
    var completed: Int
    var currentFilename: String?
    var lastError: String?
}

actor ProxyGenerator {

    static let shared = ProxyGenerator()

    private var queue: [ProxyJob] = []
    private var isRunning = false
    private var statusContinuations: [UUID: AsyncStream<ProxyGenerationStatus>.Continuation] = [:]
    private var completedCount = 0
    private var lastError: String?
    private var currentFilename: String?

    struct ProxyJob: Sendable {
        var sourceURL: URL
        var proxyFilename: String
        var use240p: Bool
        /// Rappel de fin (chemin relatif du proxy, ou nil si échec).
        var onFinish: @Sendable (String?) async -> Void
    }

    /// Flux d'état pour l'interface (progression en arrière-plan).
    func statusStream() -> AsyncStream<ProxyGenerationStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            statusContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        statusContinuations[id] = nil
    }

    private func publishStatus() {
        let status = ProxyGenerationStatus(
            totalQueued: queue.count + (isRunning ? 1 : 0) + completedCount,
            completed: completedCount,
            currentFilename: currentFilename,
            lastError: lastError
        )
        for continuation in statusContinuations.values {
            continuation.yield(status)
        }
    }

    func enqueue(_ job: ProxyJob) {
        queue.append(job)
        publishStatus()
        if !isRunning {
            Task { await self.runLoop() }
        }
    }

    private func runLoop() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while !queue.isEmpty {
            let job = queue.removeFirst()
            currentFilename = job.sourceURL.lastPathComponent
            publishStatus()
            do {
                let relativePath = try await Self.generateProxy(
                    sourceURL: job.sourceURL,
                    proxyFilename: job.proxyFilename,
                    use240p: job.use240p
                )
                completedCount += 1
                await job.onFinish(relativePath)
            } catch {
                lastError = "\(job.sourceURL.lastPathComponent) : \(error.localizedDescription)"
                await job.onFinish(nil)
            }
            currentFilename = nil
            publishStatus()
        }
    }

    // MARK: - Génération

    /// AVAssetReader → AVAssetWriter, hors MainActor. Retourne le chemin relatif.
    static func generateProxy(sourceURL: URL,
                              proxyFilename: String,
                              use240p: Bool) async throws -> String {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        let (naturalSize, transform, frameRate) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate
        )

        // Dimensions cibles : hauteur 144 (ou 240), largeur au ratio, multiples de 2.
        let targetHeight: CGFloat = use240p ? 240 : 144
        let displaySize = naturalSize.applying(transform)
        let sourceW = abs(displaySize.width)
        let sourceH = abs(displaySize.height)
        let scale = targetHeight / max(sourceH, 1)
        let outW = (Int(sourceW * scale) / 2) * 2
        let outH = (Int(targetHeight) / 2) * 2

        let outputURL = StorageManager.proxiesDirectory.appendingPathComponent(proxyFilename)
        try? FileManager.default.removeItem(at: outputURL)

        let reader = try AVAssetReader(asset: asset)
        // Décodage matériel + redimensionnement fait par la composition writer ;
        // ici on lit en pleine résolution NV12 puis on laisse l'encodeur réduire.
        // Plus économe : demander directement la sortie réduite au reader.
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Tout-intra : MaxKeyFrameInterval = 1 → n'importe quelle image décodable seule.
        // Débit très bas : la qualité des proxys est secondaire.
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: use240p ? 800_000 : 400_000,
            AVVideoMaxKeyFrameIntervalKey: 1,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let writerSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        // Appliquer la rotation au proxy pour un affichage direct.
        writerInput.transform = transform
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "ClipFlow.Proxy", code: 1)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Pompage des échantillons — timestamps source préservés tels quels.
        // ATTENTION : le système peut rappeler ce bloc APRÈS la fin du flux ;
        // `finished` (sérialisé par pumpQueue) garantit une reprise UNIQUE de la
        // continuation — sans lui, double resume = crash immédiat.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pumpQueue = DispatchQueue(label: "clipflow.proxy.pump")
            var finished = false
            writerInput.requestMediaDataWhenReady(on: pumpQueue) {
                guard !finished else { return }
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sample) {
                            finished = true
                            reader.cancelReading()
                            writerInput.markAsFinished()
                            continuation.resume(throwing: writer.error ?? NSError(domain: "ClipFlow.Proxy", code: 2))
                            return
                        }
                    } else {
                        finished = true
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "ClipFlow.Proxy", code: 3)
        }
        _ = frameRate // cadence conservée implicitement par les timestamps
        return proxyFilename
    }
}
