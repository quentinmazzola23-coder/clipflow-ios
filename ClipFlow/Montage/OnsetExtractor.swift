//
//  OnsetExtractor.swift
//  ClipFlow
//
//  Du signal audio brut aux COURBES D'ANALYSE : enveloppe d'attaques (flux
//  spectral) et énergie (RMS).
//
//  Équivalent maison de `librosa.onset.onset_strength` + `librosa.feature.rms`
//  du script d'origine, sur Accelerate. « Maison » ne veut pas dire « au
//  rabais » : le flux spectral redressé est LA méthode standard de détection
//  d'attaques, et c'est celle dont librosa fait sa valeur par défaut.
//
//  Entrée : échantillons mono Float + cadence. Sortie : tableaux Float.
//  Aucune dépendance média — testable en CI avec des signaux synthétiques.
//

import Foundation
import Accelerate

/// Courbes extraites d'un signal, à cadence constante `hopSeconds`.
struct AnalysisCurves: Sendable, Equatable {
    /// Force d'attaque par trame (flux spectral redressé), normalisée 0-1.
    var onsetEnvelope: [Float]
    /// Énergie RMS par trame, normalisée 0-1.
    var rms: [Float]
    /// Durée d'une trame en secondes (hop / cadence d'échantillonnage).
    var hopSeconds: Double
    /// CONVENTION TEMPORELLE : la trame i mesure la fenêtre
    /// [i·hop ; i·hop + fft), dont l'événement physique est au CENTRE.
    /// L'instant réel de la trame i est donc i·hop + cet offset. Sans cette
    /// compensation, toute la grille de beats serait en avance d'une
    /// demi-fenêtre (~23 ms) sur les kicks — mesuré sur signal fabriqué.
    var frameCenterOffset: Double

    /// Index de trame (fractionnaire) correspondant à un instant réel.
    func frameIndex(at time: Double) -> Double {
        max(0, (time - frameCenterOffset) / hopSeconds)
    }
}

enum OnsetExtractor {

    /// Taille de fenêtre FFT. À 22 050 Hz : 46 ms de signal, résolution
    /// ~21,5 Hz par case — largement assez fin pour des attaques percussives.
    static let fftSize = 1024
    /// Avancée entre deux trames : 256 échantillons ≈ 11,6 ms à 22 050 Hz.
    /// C'est la précision temporelle de TOUTE l'analyse en aval.
    static let hopSize = 256

    /// Extrait les courbes d'analyse d'un signal mono.
    ///
    /// - `samples` : échantillons Float (-1…1), mono.
    /// - `sampleRate` : cadence du signal fourni.
    static func curves(samples: [Float], sampleRate: Double) -> AnalysisCurves {
        let hopSeconds = Double(hopSize) / sampleRate
        let centerOffset = Double(fftSize) / (2 * sampleRate)
        guard samples.count >= fftSize else {
            return AnalysisCurves(onsetEnvelope: [], rms: [], hopSeconds: hopSeconds,
                                  frameCenterOffset: centerOffset)
        }

        let frameCount = (samples.count - fftSize) / hopSize + 1
        let binCount = fftSize / 2

        // Fenêtre de Hann : sans elle, les bords francs de chaque trame
        // fabriquent des attaques fantômes à chaque trame.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return AnalysisCurves(onsetEnvelope: [], rms: [], hopSeconds: hopSeconds,
                                  frameCenterOffset: centerOffset)
        }
        defer { vDSP_destroy_fftsetup(fft) }

        var onsets = [Float](repeating: 0, count: frameCount)
        var rms = [Float](repeating: 0, count: frameCount)
        var previousMagnitudes = [Float](repeating: 0, count: binCount)

        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: binCount)
        var imag = [Float](repeating: 0, count: binCount)
        var magnitudes = [Float](repeating: 0, count: binCount)

        for frame in 0..<frameCount {
            let start = frame * hopSize

            // RMS sur la trame BRUTE (pas fenêtrée) : c'est l'énergie du
            // signal qu'on veut, pas celle du produit signal × fenêtre.
            samples.withUnsafeBufferPointer { buffer in
                vDSP_rmsqv(buffer.baseAddress! + start, 1, &rms[frame], vDSP_Length(fftSize))
            }

            // Trame fenêtrée puis FFT réelle (format split-complex packé).
            samples.withUnsafeBufferPointer { buffer in
                vDSP_vmul(buffer.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                                imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!,
                                  2, &split, 1, vDSP_Length(binCount))
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // Magnitudes. La case 0 (imagp = Nyquist en format packé)
                    // est neutralisée : la composante continue n'est pas une
                    // attaque, et Nyquist n'apporte rien ici.
                    split.imagp[0] = 0
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(binCount))
                }
            }

            // FLUX SPECTRAL REDRESSÉ : somme des hausses de magnitude par
            // case. Les baisses (fin de note) sont ignorées — une attaque est
            // une APPARITION d'énergie, pas une disparition.
            // La trame 0 n'a PAS de spectre précédent : la comparer à zéro
            // compterait le morceau entier comme une attaque géante — qui
            // deviendrait le maximum de normalisation et écraserait toutes
            // les vraies attaques (mesuré : rapport 5-20×).
            if frame > 0 {
                var flux: Float = 0
                for bin in 1..<binCount {
                    let rise = magnitudes[bin] - previousMagnitudes[bin]
                    if rise > 0 { flux += rise }
                }
                onsets[frame] = flux
            }
            swap(&previousMagnitudes, &magnitudes)
        }

        return AnalysisCurves(
            onsetEnvelope: normalizedAndDetrended(onsets, hopSeconds: hopSeconds),
            rms: normalized(rms),
            hopSeconds: hopSeconds,
            frameCenterOffset: centerOffset
        )
    }

    /// Normalisation 0-1 simple (min-max), comme le script d'origine.
    static func normalized(_ values: [Float]) -> [Float] {
        guard let minimum = values.min(), let maximum = values.max(),
              maximum - minimum > 1e-8 else {
            return values.map { _ in 0 }
        }
        let range = maximum - minimum
        return values.map { ($0 - minimum) / range }
    }

    /// L'enveloppe d'attaques subit en plus un DÉTRENDAGE : moyenne glissante
    /// (~0,5 s) soustraite, puis redressement. Sans lui, un morceau dont le
    /// niveau global monte verrait toutes ses trames tardives « en attaque ».
    static func normalizedAndDetrended(_ values: [Float], hopSeconds: Double) -> [Float] {
        guard !values.isEmpty else { return values }
        let half = max(1, Int(0.25 / hopSeconds))

        // Sommes préfixes : chaque moyenne de fenêtre en O(1), code trivial à
        // relire — pas de somme glissante incrémentale à état fragile.
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in 0..<values.count {
            prefix[index + 1] = prefix[index] + Double(values[index])
        }

        var rectified = [Float](repeating: 0, count: values.count)
        for index in 0..<values.count {
            let lower = max(0, index - half)
            let upper = min(values.count - 1, index + half)
            let mean = (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
            // Redressement : seules les trames AU-DESSUS de leur voisinage
            // comptent — une attaque est un dépassement local, pas un niveau.
            rectified[index] = max(0, values[index] - Float(mean))
        }
        return normalized(rectified)
    }
}
