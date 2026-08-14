//
//  MotionAnalyzer.swift
//  ClipFlow
//
//  REPÉRAGE DES MOMENTS FORTS d'un rush.
//
//  Problème réel : trier 25 rushes à la main coûte plus de temps que tout le
//  reste du montage. L'app peut proposer des points de découpe — à condition
//  d'être HONNÊTE sur ce qu'elle mesure.
//
//  Ce qu'on mesure : l'ÉNERGIE DE MOUVEMENT, c'est-à-dire la différence
//  d'image à image, sur une version réduite du rush (analyse rapide, aucun
//  flux optique). Ce n'est PAS de la reconnaissance de contenu : l'app ne sait
//  pas ce qui est intéressant, elle sait où ça bouge PLUS QUE D'HABITUDE.
//
//  Le « plus que d'habitude » est le point clé. Un POV moto bouge partout : une
//  énergie brute élevée ne distingue rien. Ce qui marque un moment, c'est
//  l'écart au régime LOCAL — une accélération, un virage, un passage d'obstacle.
//  D'où un score relatif à une référence médiane glissante, robuste aux pics
//  isolés (même raisonnement que le détecteur d'artefacts : une médiane ne se
//  laisse pas déplacer par la minorité qu'elle doit justement faire ressortir).
//

import Foundation
import AVFoundation
import CoreVideo

/// Énergie de mouvement à un instant du rush.
struct MotionSample: Equatable, Sendable {
    /// Secondes depuis le début du rush.
    var time: Double
    /// Différence moyenne par tuile avec l'image analysée précédente (0-255).
    var energy: Double
}

/// Moment proposé à l'utilisateur.
struct MotionPeak: Equatable, Sendable, Identifiable {
    var time: Double
    /// Écart au régime local, en multiples de l'agitation habituelle.
    /// 1 = deux fois plus agité que d'ordinaire. Sert au classement.
    var score: Double
    var id: Double { time }
}

enum MotionAnalyzerError: Error, LocalizedError {
    case noVideoTrack
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "Aucune piste vidéo à analyser."
        case .readFailed(let details): return "Analyse impossible : \(details)"
        }
    }
}

enum MotionAnalyzer {

    // MARK: - Réglages

    /// Largeur d'analyse : le mouvement se lit parfaitement en vignette, et
    /// décoder en pleine résolution coûterait dix fois plus cher.
    static let analysisWidth = 192
    /// Grille de comparaison entre deux images.
    static let grid = 8
    /// Cadence d'analyse : inutile d'examiner 60 images par seconde pour
    /// repérer un moment ; 12 suffisent et divisent le coût par cinq.
    static let samplesPerSecond: Double = 12

    /// Nombre d'échantillons de chaque côté formant la référence « régime
    /// habituel ». À 12 images/s, 18 couvrent 1,5 s de part et d'autre.
    static let referenceRadius = 18
    /// Score minimal pour proposer un moment, en multiples de l'agitation
    /// ORDINAIRE du voisinage.
    ///
    /// ⚠️ Calibré après échec du banc de tests : à 0,6, un simple frisson de
    /// bruit (excédent 1,1 pour une agitation habituelle de 1,0) obtenait 1,1
    /// et franchissait le seuil. Le vrai pic était bien vu — noyé parmi des
    /// dizaines de propositions vides. Un moment doit sortir NETTEMENT du lot :
    /// 3× l'agitation ordinaire, l'équivalent d'un écart à 3 sigma.
    static let minimumScore: Double = 3.0

    // MARK: - Détection de pics (logique PURE, testable sans média)

    /// Sélectionne les moments forts parmi des échantillons d'énergie.
    ///
    /// - `minimumSpacing` : deux propositions ne doivent pas se chevaucher —
    ///   on passe la durée source d'un clip, sinon l'utilisateur reçoit dix
    ///   suggestions pour le même instant.
    /// - `maximumCount` : au-delà, ce n'est plus une proposition mais une liste
    ///   à trier — ce qu'on cherchait justement à éviter.
    static func peaks(from samples: [MotionSample],
                      minimumSpacing: Double,
                      maximumCount: Int = 12) -> [MotionPeak] {
        guard samples.count > 4 else { return [] }

        var scored: [MotionPeak] = []
        for index in 0..<samples.count {
            let lower = max(0, index - referenceRadius)
            let upper = min(samples.count - 1, index + referenceRadius)
            guard upper - lower >= 4 else { continue }

            // Régime local : médiane des voisins, EXCLUANT l'échantillon jugé.
            var neighbours: [Double] = []
            neighbours.reserveCapacity(upper - lower)
            for other in lower...upper where other != index {
                neighbours.append(samples[other].energy)
            }
            let baseline = median(of: neighbours)
            // Agitation habituelle : écart absolu médian, insensible aux pics.
            let deviation = median(of: neighbours.map { abs($0 - baseline) })
            // Plancher : sur une scène parfaitement immobile, l'écart médian
            // vaut zéro et le score exploserait au moindre frémissement.
            let scale = max(deviation, 1.0)

            let excess = samples[index].energy - baseline
            guard excess > 0 else { continue }

            // MAXIMUM LOCAL STRICT. Sur une montée continue, tous les points
            // dépassent la référence — mais un seul est le moment. Sans cette
            // condition, un même événement produisait une grappe de candidats
            // que seul l'espacement minimal élaguait ensuite, au hasard du
            // classement.
            if index > 0, samples[index].energy <= samples[index - 1].energy { continue }
            if index + 1 < samples.count, samples[index].energy < samples[index + 1].energy { continue }

            scored.append(MotionPeak(time: samples[index].time, score: excess / scale))
        }

        let strong = scored.filter { $0.score >= minimumScore }
        let sorted = strong.sorted { $0.score > $1.score }

        var selected: [MotionPeak] = []
        for candidate in sorted {
            guard selected.allSatisfy({ abs($0.time - candidate.time) >= minimumSpacing }) else { continue }
            selected.append(candidate)
            if selected.count >= maximumCount { break }
        }
        return selected.sorted { $0.time < $1.time }
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Analyse d'un rush

    /// Parcourt le rush et mesure l'énergie de mouvement.
    /// Annulable : un rush long ne doit jamais bloquer l'interface.
    static func samples(for url: URL) async throws -> [MotionSample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MotionAnalyzerError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let width = max(Int(abs(naturalSize.width)), 1)
        let height = max(Int(abs(naturalSize.height)), 1)
        let scale = Double(analysisWidth) / Double(width)
        let outputWidth = analysisWidth
        let outputHeight = max(Int((Double(height) * scale).rounded()), grid)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MotionAnalyzerError.readFailed(reader.error?.localizedDescription ?? "startReading")
        }

        var result: [MotionSample] = []
        var previousTiles: [Double]?
        var nextSampleTime = 0.0
        let interval = 1.0 / samplesPerSecond

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time.isFinite, time >= nextSampleTime else { continue }
            nextSampleTime = time + interval

            guard let tiles = lumaTiles(of: image) else { continue }
            if let previous = previousTiles, previous.count == tiles.count {
                var total = 0.0
                for index in 0..<tiles.count { total += abs(tiles[index] - previous[index]) }
                result.append(MotionSample(time: time, energy: total / Double(tiles.count)))
            }
            previousTiles = tiles
        }
        if reader.status == .failed {
            throw MotionAnalyzerError.readFailed(reader.error?.localizedDescription ?? "lecture")
        }
        return result
    }

    /// Moyennes de luminance par tuile d'une image NV12 réduite.
    private static func lumaTiles(of buffer: CVPixelBuffer) -> [Double]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width >= grid, height >= grid else { return nil }

        var totals = [Double](repeating: 0, count: grid * grid)
        var counts = [Int](repeating: 0, count: grid * grid)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let tileY = min(y * grid / height, grid - 1)
            let row = pointer + y * stride
            for x in 0..<width {
                let index = tileY * grid + min(x * grid / width, grid - 1)
                totals[index] += Double(row[x])
                counts[index] += 1
            }
        }
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }
        return zip(totals, counts).map { $0 / Double($1) }
    }
}
