//
//  MusicDecoder.swift
//  ClipFlow
//
//  Décodage d'un fichier musical en échantillons mono Float pour l'analyse.
//
//  RÉÉCRIT sur AVAudioFile après un premier montage non fonctionnel :
//  l'ancienne version passait par AVAssetReaderAudioMixOutput avec des
//  réglages de rééchantillonnage dont le support varie selon le conteneur —
//  un MP3 pouvait échouer là où un M4A passait. AVAudioFile décode MP3, M4A,
//  AAC, WAV et AIFF par le même chemin, éprouvé, sans réglages à négocier.
//
//  Le signal est livré À LA CADENCE NATIVE du fichier (44,1 ou 48 kHz) :
//  aucun rééchantillonnage, donc aucune conversion à rater. L'analyse en
//  aval est paramétrée par la cadence — elle y gagne même en précision
//  temporelle (hop de 5,8 ms au lieu de 11,6).
//
//  Chaque échec porte un message qui dit à l'utilisateur si c'est SON cas
//  d'usage qui est en cause (fichier vidéo, morceau trop long...) ou un
//  vrai défaut à signaler.
//

import Foundation
import AVFoundation

enum MusicDecoderError: Error, LocalizedError {
    case unreadable(String)
    case empty
    case tooLong(minutes: Int)
    case unexpectedFormat

    var errorDescription: String? {
        switch self {
        case .unreadable(let details):
            return "Ce fichier n'a pas pu être lu comme de l'audio. "
                + "Causes habituelles : un fichier vidéo ou une image sélectionnés à la place d'un morceau, "
                + "un fichier protégé (achat iTunes DRM), ou un téléchargement incomplet. "
                + "Détail technique : \(details)"
        case .empty:
            return "Ce fichier audio est vide (durée nulle) — le téléchargement est probablement incomplet. Réessayez de le télécharger."
        case .tooLong(let minutes):
            return "Ce morceau dépasse \(minutes) minutes. L'analyse est prévue pour des morceaux de montage — choisissez un titre plus court ou coupez-le."
        case .unexpectedFormat:
            return "Format d'échantillons inattendu dans ce fichier — ce cas ne devrait pas se produire, signalez-le (ce n'est pas une erreur d'utilisation)."
        }
    }
}

enum MusicDecoder {

    /// Durée maximale acceptée. Au-delà, la mémoire d'analyse dépasse ce
    /// qu'on veut imposer au téléphone (44,1 kHz mono Float ≈ 10 Mo/min).
    static let maximumMinutes = 15

    /// Décode l'intégralité du fichier : échantillons mono + cadence NATIVE.
    /// Annulable entre deux blocs de lecture.
    static func monoSamples(of url: URL) async throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MusicDecoderError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat // Float32 non entrelacé, garanti
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0 else { throw MusicDecoderError.empty }
        guard totalFrames <= AVAudioFramePosition(sampleRate * Double(maximumMinutes) * 60) else {
            throw MusicDecoderError.tooLong(minutes: maximumMinutes)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
            throw MusicDecoderError.unexpectedFormat
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(totalFrames))
        let channels = Int(format.channelCount)

        while true {
            try Task.checkCancellation()
            do {
                try file.read(into: buffer)
            } catch {
                throw MusicDecoderError.unreadable(error.localizedDescription)
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break } // fin de fichier

            guard let data = buffer.floatChannelData else {
                throw MusicDecoderError.unexpectedFormat
            }
            if channels == 1 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            } else {
                // Mono par MOYENNE des canaux — pas le canal gauche seul :
                // certains mixages posent le kick à droite.
                let inverse = 1 / Float(channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[channel][frame] }
                    samples.append(sum * inverse)
                }
            }
        }
        guard !samples.isEmpty else { throw MusicDecoderError.empty }
        return (samples, sampleRate)
    }
}
