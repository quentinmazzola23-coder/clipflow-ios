//
//  MusicDecoder.swift
//  ClipFlow
//
//  Décodage d'un fichier musical en échantillons mono Float pour l'analyse.
//
//  DEUX CHEMINS DE DÉCODAGE, dans cet ordre, parce qu'aucun n'est universel :
//
//   1. `AVAudioFile` — simple, rapide, cadence native. Mais il s'appuie sur
//      ExtAudioFile, qui refuse certains MP3 parfaitement valides : un gros
//      tag ID3 (pochette intégrée : 150 Ko et plus, cas courant d'un morceau
//      téléchargé) suffit à le faire échouer avec un `_GenericObjCError 0`,
//      erreur opaque qui ne dit rien de la cause.
//   2. `AVAssetReader` — le parseur média complet d'AVFoundation, celui qui
//      lit ces mêmes fichiers sans broncher. Plus verbeux, donc utilisé en
//      second, mais il rattrape ce que le premier laisse tomber.
//
//  L'ordre importe peu pour l'utilisateur : ce qui compte est qu'un fichier
//  lisible par le téléphone soit lisible par l'app. Un seul chemin, c'était
//  une porte fermée sans explication.
//
//  Avant tout décodage, le fichier est INSPECTÉ : absent, vide, ou page web
//  déguisée en .mp3 (une erreur de téléchargement en renvoie une), chacun a
//  son message — l'utilisateur doit savoir si c'est son fichier, son réseau,
//  ou l'app.
//

import Foundation
import AVFoundation

enum MusicDecoderError: Error, LocalizedError {
    case missing
    case empty
    case notAudioFile
    case tooLong(minutes: Int)
    case bothPathsFailed(first: String, second: String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "Le fichier musical est introuvable — il a peut-être été supprimé depuis. Choisissez-en un autre."
        case .empty:
            return "Ce fichier audio est vide. Le téléchargement est probablement incomplet : réessayez."
        case .notAudioFile:
            return "Ce fichier n'est pas de l'audio : son contenu est une page web ou du texte. "
                + "C'est en général un téléchargement qui a échoué en renvoyant une page d'erreur — "
                + "réessayez, ou choisissez un autre titre."
        case .tooLong(let minutes):
            return "Ce morceau dépasse \(minutes) minutes. L'analyse est prévue pour des morceaux de montage — choisissez un titre plus court."
        case .bothPathsFailed(let first, let second):
            return "Ce fichier n'a pas pu être décodé, par aucun des deux lecteurs de l'app. "
                + "Causes habituelles : fichier vidéo ou image choisi à la place d'un morceau, "
                + "ou fichier protégé (achat iTunes DRM, qui ne peut pas être décodé). "
                + "Si c'est bien un morceau non protégé, c'est un défaut de l'app : signalez-le. "
                + "Détails : [1] \(first) — [2] \(second)"
        }
    }
}

enum MusicDecoder {

    /// Durée maximale acceptée. Au-delà, la mémoire d'analyse dépasse ce
    /// qu'on veut imposer au téléphone (44,1 kHz mono Float ≈ 10 Mo/min).
    static let maximumMinutes = 15

    /// Cadence du chemin de secours. 44,1 kHz couvre tout ce qui compte pour
    /// détecter des attaques ; la conversion est faite par AVFoundation.
    static let fallbackSampleRate = 44_100.0

    /// Décode l'intégralité du fichier : échantillons mono + cadence réelle.
    static func monoSamples(of url: URL) async throws -> (samples: [Float], sampleRate: Double) {
        try inspect(url)

        // Chemin 1 — le plus direct.
        do {
            return try await decodeWithAudioFile(url)
        } catch let error as MusicDecoderError {
            // Vide / trop long : inutile d'essayer l'autre chemin, le verdict
            // ne changera pas.
            switch error {
            case .empty, .tooLong: throw error
            default: break
            }
            return try await decodeWithAssetReader(url, firstFailure: error.localizedDescription)
        } catch {
            return try await decodeWithAssetReader(url, firstFailure: error.localizedDescription)
        }
    }

    // MARK: - Inspection préalable

    /// Vérifie que le fichier existe, n'est pas vide, et ressemble à un
    /// média — avant de laisser un décodeur rendre une erreur opaque.
    static func inspect(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MusicDecoderError.missing
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 1024 else { throw MusicDecoderError.empty }

        // Les 5 premiers octets suffisent à repérer une page web ou du JSON
        // servis à la place d'un morceau (téléchargement en erreur).
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 5), head.count >= 1 else { return }
        let text = String(decoding: head, as: UTF8.self).lowercased()
        if text.hasPrefix("<html") || text.hasPrefix("<!doc") || text.hasPrefix("{") {
            throw MusicDecoderError.notAudioFile
        }
    }

    // MARK: - Chemin 1 : AVAudioFile

    private static func decodeWithAudioFile(_ url: URL) async throws
        -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat // Float32 non entrelacé, garanti
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0 else { throw MusicDecoderError.empty }
        try checkDuration(seconds: Double(totalFrames) / sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            throw MusicDecoderError.bothPathsFailed(first: "tampon indisponible", second: "")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(totalFrames))
        let channels = Int(format.channelCount)

        while true {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break } // fin de fichier
            guard let data = buffer.floatChannelData else { break }
            append(channelData: data, channels: channels, frames: frames, to: &samples)
        }
        guard !samples.isEmpty else { throw MusicDecoderError.empty }
        return (samples, sampleRate)
    }

    // MARK: - Chemin 2 : AVAssetReader

    private static func decodeWithAssetReader(_ url: URL, firstFailure: String) async throws
        -> (samples: [Float], sampleRate: Double) {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MusicDecoderError.bothPathsFailed(
                    first: firstFailure, second: "aucune piste audio dans ce fichier"
                )
            }
            let duration = try await asset.load(.duration)
            if duration.seconds.isFinite, duration.seconds > 0 {
                try checkDuration(seconds: duration.seconds)
            }

            let reader = try AVAssetReader(asset: asset)
            // Mono + cadence imposée : c'est AVFoundation qui mixe et
            // rééchantillonne, pas nous.
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: fallbackSampleRate,
                AVNumberOfChannelsKey: 1,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw MusicDecoderError.bothPathsFailed(
                    first: firstFailure, second: "réglages de lecture refusés pour ce format"
                )
            }
            reader.add(output)
            guard reader.startReading() else {
                throw MusicDecoderError.bothPathsFailed(
                    first: firstFailure,
                    second: reader.error?.localizedDescription ?? "démarrage de lecture refusé"
                )
            }

            var samples: [Float] = []
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length > 0 else { continue }
                let count = length / MemoryLayout<Float>.size
                let previous = samples.count
                samples.append(contentsOf: repeatElement(0, count: count))
                samples.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: length,
                        destination: base + previous * MemoryLayout<Float>.size
                    )
                }
            }
            if reader.status == .failed {
                throw MusicDecoderError.bothPathsFailed(
                    first: firstFailure,
                    second: reader.error?.localizedDescription ?? "lecture interrompue"
                )
            }
            guard !samples.isEmpty else {
                throw MusicDecoderError.bothPathsFailed(
                    first: firstFailure, second: "aucun échantillon décodé"
                )
            }
            return (samples, fallbackSampleRate)
        } catch let error as MusicDecoderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MusicDecoderError.bothPathsFailed(
                first: firstFailure, second: error.localizedDescription
            )
        }
    }

    // MARK: - Outils

    private static func checkDuration(seconds: Double) throws {
        guard seconds <= Double(maximumMinutes) * 60 else {
            throw MusicDecoderError.tooLong(minutes: maximumMinutes)
        }
    }

    /// Ajoute un bloc d'échantillons, en MOYENNANT les canaux — pas le canal
    /// gauche seul : certains mixages posent le kick à droite.
    private static func append(channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
                               channels: Int, frames: Int, to samples: inout [Float]) {
        if channels == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
            return
        }
        let inverse = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += channelData[channel][frame] }
            samples.append(sum * inverse)
        }
    }
}
