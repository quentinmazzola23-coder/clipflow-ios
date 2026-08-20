//
//  BeatMap.swift
//  ClipFlow
//
//  CARTE DE RYTHME d'une musique : les beats, leur énergie, leur rôle dans le
//  morceau (drop / build / verse / break), et les créneaux de montage qui en
//  découlent.
//
//  Les seuils et les multiplicateurs ne sortent pas d'un chapeau : ils sont
//  repris du script `beat_edit_pov.py`, calibré sur les musiques réellement
//  utilisées (hardstyle, POV moto). Ce script est la SPÉCIFICATION de ce
//  fichier — les tests du banc comparent ce code à son comportement.
//
//  Logique PURE : aucun média, aucun appareil. Tout se vérifie en CI.
//

import Foundation

/// Rôle d'un beat dans le morceau. Vocabulaire du script d'origine.
enum BeatSection: String, Codable, Sendable, CaseIterable {
    case drop
    case build
    case verse
    /// « break » est un mot réservé Swift — la valeur brute reste "break"
    /// pour que les cartes sérialisées parlent le même langage que le script.
    case breakdown = "break"
}

/// Carte de rythme complète d'un fichier musical, sérialisable (cache disque).
struct BeatMap: Codable, Sendable, Equatable {
    /// Version du SCHÉMA d'analyse : toute modification des seuils ou du
    /// détecteur périme les cartes en cache — incrémenter alors cette valeur.
    static let schemaVersion = 1

    var bpm: Double
    /// Instants des beats, en secondes depuis le début du fichier, croissants.
    var beatTimes: [Double]
    /// Énergie normalisée 0-1 à chaque beat (même longueur que beatTimes).
    var energies: [Double]
    /// Rôle de chaque beat (même longueur que beatTimes).
    var sections: [BeatSection]
    /// Durée totale du fichier analysé, en secondes.
    var duration: Double
    /// Départ de fenêtre SUGGÉRÉ : le cluster de drops le plus énergique.
    /// L'utilisateur peut le déplacer — ce n'est qu'un point de départ.
    var suggestedWindowStart: Double

    /// Enveloppe d'énergie réduite pour l'affichage de la forme d'onde
    /// (quelques centaines de points, pas les échantillons audio).
    var waveform: [Float]
}

/// Un créneau de montage : un intervalle exact entre deux beats, portant le
/// rôle du beat qui l'ouvre. Les coupes tombent sur les beats PAR CONSTRUCTION
/// — la durée est la différence de deux instants de beat, jamais un arrondi.
struct BeatSlot: Equatable, Sendable {
    /// Début du créneau (temps musique, secondes).
    var start: Double
    /// Durée exacte jusqu'au beat de fin.
    var duration: Double
    var section: BeatSection
    /// Index du beat d'ouverture dans la carte (diagnostic, tests).
    var beatIndex: Int
}

extension BeatMap {

    /// Beats par créneau selon la section — valeurs du script d'origine :
    /// drop et build coupent à CHAQUE beat (l'intensité se ressent),
    /// verse respire sur 2, break sur 3.
    static let beatsPerSlot: [BeatSection: Int] = [
        .drop: 1, .build: 1, .verse: 2, .breakdown: 3,
    ]

    /// Durée minimale d'un créneau exploitable. Sous ce seuil (deux beats
    /// confondus, fin de fichier), le créneau est ignoré : un plan de 80 ms
    /// n'est pas une coupe, c'est un défaut d'affichage.
    static let minimumSlotDuration = 0.10

    /// Construit les créneaux de montage à partir d'un instant donné.
    ///
    /// Parcours contigu : chaque créneau commence là où le précédent finit
    /// (sur un beat), la durée est l'intervalle EXACT jusqu'au beat de fin.
    func slots(from startTime: Double) -> [BeatSlot] {
        guard beatTimes.count >= 2,
              beatTimes.count == sections.count else { return [] }

        var result: [BeatSlot] = []
        // Premier beat à partir du point de départ demandé.
        guard var index = beatTimes.firstIndex(where: { $0 >= startTime }) else { return [] }

        while index < beatTimes.count - 1 {
            let section = sections[index]
            let multiplier = Self.beatsPerSlot[section] ?? 1
            let endIndex = min(index + multiplier, beatTimes.count - 1)
            let duration = beatTimes[endIndex] - beatTimes[index]
            if duration >= Self.minimumSlotDuration {
                result.append(BeatSlot(start: beatTimes[index],
                                       duration: duration,
                                       section: section,
                                       beatIndex: index))
            }
            // Avancer AU BEAT DE FIN : jamais de chevauchement, jamais de trou.
            index = endIndex
        }
        return result
    }
}
