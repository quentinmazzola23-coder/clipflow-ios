//
//  MusicDecoder.swift
//  ClipFlow
//
//  Décodage d'un fichier musical en échantillons mono Float pour l'analyse.
//
//  Couche VOLONTAIREMENT mince : tout ce qui peut être pur est dans
//  OnsetExtractor / TempoEstimator / BeatAnalyzer. Ici, uniquement ce qui
//  exige AVFoundation — et le mixage mono + rééchantillonnage sont délégués
//  à AVAssetReaderAudioMixOutput, qui les fait en une passe matérielle.
//

import Foundation
import AVFoundation

enum MusicDecoderError: Error, LocalizedError {
    case noAudioTrack
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "Ce fichier ne contient aucune piste audio."
        case .readFailed(let details):
            return "Lecture du fichier musical impossible : \(details)"
        }
    }
}

enum MusicDecoder {

    /// Cadence d'analyse. 22 050 Hz suffit : les attaques utiles d'un kick
    /// vivent sous 11 kHz, et diviser la cadence divise le coût de la FFT.
    static let analysisSampleRate = 22_050.0

    /// Décode l'intégralité du fichier en mono à la cadence d'analyse.
    /// Annulable (un MP3 de 5 minutes se décode en quelques secondes, mais
    /// l'utilisateur peut changer de musique avant la fin).
    static func monoSamples(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MusicDecoderError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MusicDecoderError.readFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            let previous = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length,
                    destination: raw.baseAddress! + previous * MemoryLayout<Float>.size
                )
            }
        }
        if reader.status == .failed {
            throw MusicDecoderError.readFailed(reader.error?.localizedDescription ?? "lecture")
        }
        return samples
    }
}
