//
//  BeatMap.swift
//  ClipFlow
//
//  CARTE DE RYTHME d'une musique : les beats, leur énergie, leur rôle dans le
//  morceau (drop / build / verse / break), et les créneaux de montage.
//
//  DÉCOUPE SIMPLE ET PRÉVISIBLE, à la CapCut : les créneaux sont RÉGULIERS,
//  au pas choisi par l'utilisateur (sélecteur de densité, 5 crans). Les
//  sections drop/build/verse/break ne pilotent PLUS la découpe — elles ne
//  servent qu'à l'affichage (couleurs) et au choix de la fenêtre suggérée.
//  L'ancienne découpe à multiplicateurs variables rendait les durées
//  imprévisibles : impossible de savoir quelle longueur de rush prévoir.
//
//  Logique PURE : aucun média, aucun appareil. Tout se vérifie en CI.
//

import Foundation

/// Rôle d'un beat dans le morceau — AFFICHAGE uniquement.
enum BeatSection: String, Codable, Sendable, CaseIterable {
    case drop
    case build
    case verse
    /// « break » est un mot réservé Swift — la valeur brute reste "break".
    case breakdown = "break"
}

/// Densité de découpe : le pas de coupe, en beats. Cinq crans réguliers —
/// la durée de CHAQUE clip est identique et connue d'avance.
enum CutDensity: Int, Codable, Sendable, CaseIterable {
    case beats8 = 0
    case beats4 = 1
    case beats2 = 2
    case beat1 = 3
    case half = 4

    /// Pas de coupe en beats. 0,5 = coupe à chaque demi-beat.
    var beatsPerCut: Double {
        switch self {
        case .beats8: return 8
        case .beats4: return 4
        case .beats2: return 2
        case .beat1: return 1
        case .half: return 0.5
        }
    }

    /// Durée d'un clip à ce cran, pour un BPM donné (secondes).
    func slotDuration(bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return 60.0 / bpm * beatsPerCut
    }

    /// Le cran du milieu (1 coupe par beat) : le comportement le plus proche
    /// de la référence CapCut, choisi par défaut.
    static let standard = CutDensity.beat1
}

/// Carte de rythme complète d'un fichier musical, sérialisable (cache disque).
struct BeatMap: Codable, Sendable, Equatable {
    /// Version du SCHÉMA d'analyse : toute modification du détecteur ou de la
    /// structure périme les cartes en cache — incrémenter alors cette valeur.
    /// v2 : grille auto-rattrapante (asservissement de phase) + découpe par
    /// densité régulière.
    static let schemaVersion = 2

    var bpm: Double
    /// Instants des beats, en secondes depuis le début du fichier, croissants.
    /// Grille ASSERVIE : recalée en douceur sur les attaques réelles, donc
    /// capable de suivre un morceau dont une partie est décalée (break,
    /// montage du morceau lui-même, dérive d'encodage).
    var beatTimes: [Double]
    /// Énergie normalisée 0-1 à chaque beat (même longueur que beatTimes).
    var energies: [Double]
    /// Rôle de chaque beat (même longueur que beatTimes) — affichage.
    var sections: [BeatSection]
    /// Durée totale du fichier analysé, en secondes.
    var duration: Double
    /// Départ de fenêtre SUGGÉRÉ : le cluster de drops le plus énergique.
    var suggestedWindowStart: Double
    /// Enveloppe d'énergie réduite pour l'affichage de la forme d'onde.
    var waveform: [Float]
}

/// Un créneau de montage : un intervalle entre deux points de coupe, portant
/// le rôle du beat qui l'ouvre (pour la couleur). Les coupes tombent sur les
/// beats PAR CONSTRUCTION — durées = différences d'instants de beat.
struct BeatSlot: Equatable, Sendable {
    var start: Double
    var duration: Double
    var section: BeatSection
    /// Index du beat d'ouverture dans la carte (diagnostic, tests).
    var beatIndex: Int
}

extension BeatMap {

    /// Durée minimale d'un créneau exploitable.
    static let minimumSlotDuration = 0.10

    /// Construit les créneaux RÉGULIERS à partir d'un instant donné.
    ///
    /// - `.beats8/4/2/1` : une coupe tous les n beats, aux instants EXACTS de
    ///   la grille (les intervalles absorbent le rattrapage de dérive).
    /// - `.half` : une coupe à chaque beat ET à chaque milieu d'intervalle.
    func slots(from startTime: Double, density: CutDensity) -> [BeatSlot] {
        guard beatTimes.count >= 2,
              beatTimes.count == sections.count else { return [] }
        guard let firstIndex = beatTimes.firstIndex(where: { $0 >= startTime }) else { return [] }

        // Points de coupe (temps + index du beat porteur).
        var cuts: [(time: Double, beatIndex: Int)] = []
        if density == .half {
            var index = firstIndex
            while index < beatTimes.count {
                cuts.append((beatTimes[index], index))
                if index + 1 < beatTimes.count {
                    cuts.append(((beatTimes[index] + beatTimes[index + 1]) / 2, index))
                }
                index += 1
            }
        } else {
            let step = Int(density.beatsPerCut)
            var index = firstIndex
            while index < beatTimes.count {
                cuts.append((beatTimes[index], index))
                index += step
            }
        }
        guard cuts.count >= 2 else { return [] }

        var result: [BeatSlot] = []
        for cutIndex in 0..<(cuts.count - 1) {
            let duration = cuts[cutIndex + 1].time - cuts[cutIndex].time
            guard duration >= Self.minimumSlotDuration else { continue }
            result.append(BeatSlot(start: cuts[cutIndex].time,
                                   duration: duration,
                                   section: sections[cuts[cutIndex].beatIndex],
                                   beatIndex: cuts[cutIndex].beatIndex))
        }
        return result
    }

    /// Écarts de coupe d'une liste de créneaux : (minimum, maximum) en
    /// secondes. C'est L'INFORMATION de planification : elle dit la durée de
    /// rush nécessaire par clip AVANT même de dérusher.
    static func slotDurationRange(_ slots: [BeatSlot]) -> (min: Double, max: Double)? {
        guard let first = slots.first else { return nil }
        var minimum = first.duration
        var maximum = first.duration
        for slot in slots.dropFirst() {
            minimum = Swift.min(minimum, slot.duration)
            maximum = Swift.max(maximum, slot.duration)
        }
        return (minimum, maximum)
    }
}
