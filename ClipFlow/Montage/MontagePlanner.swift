//
//  MontagePlanner.swift
//  ClipFlow
//
//  PLACEMENT des passages validés sur les créneaux de rythme.
//
//  Principe : l'utilisateur a déjà choisi le DÉBUT de chaque clip (le point
//  d'entrée validé au dérushage). La musique décide de la DURÉE : chaque
//  passage occupe le prochain créneau, dans l'ordre de validation, et sa fin
//  tombe sur le beat de fin du créneau. Aucune décision créative ici — de
//  l'arithmétique de temps rationnelle, entièrement testable.
//
//  Toute la chaîne travaille sur UNE SEULE conversion des instants de beat en
//  CMTime (timescale 600) : les durées sont des différences de ces valeurs
//  arrondies, donc leur somme retombe EXACTEMENT sur les bornes — aucun
//  cumul d'erreur d'arrondi possible, quel que soit le nombre de clips.
//

import Foundation
import CoreMedia

/// Un passage candidat au montage, réduit à ce que le placement doit savoir.
struct MontageClipCandidate: Sendable, Equatable {
    /// Identifiant opaque (index du passage) — restitué dans le placement.
    var id: Int
    /// Début du clip DANS SON FICHIER (plage cachée ou copie source).
    var startInFile: CMTime
    /// Durée totale du fichier — borne ce qu'on peut y prélever.
    var fileDuration: CMTime
    /// Vitesse de lecture du passage (1/2 = ralenti 0,5×).
    var speed: RationalSpeed
}

/// Un clip posé sur un créneau.
struct MontagePlacement: Sendable, Equatable {
    var clipID: Int
    var slotIndex: Int
    /// Plage à prélever dans le fichier du clip (temps source).
    var sourceRange: CMTimeRange
    /// Position et durée dans le MONTAGE (temps composition, zéro = début).
    var timelineStart: CMTime
    var timelineDuration: CMTime
    var section: BeatSection
}

/// Résultat complet du placement — y compris ce qui n'a PAS pu être placé,
/// parce qu'un montage qui tait ses trous ment sur son contenu.
struct MontagePlan: Sendable, Equatable {
    var placements: [MontagePlacement]
    /// Identifiants des clips écartés : leur fichier ne couvre pas la durée
    /// du créneau depuis leur point d'entrée.
    var skippedClipIDs: [Int]
    /// Durée totale du montage (fin du dernier créneau rempli).
    var totalDuration: CMTime
    /// Début de la fenêtre dans la musique (pour caler la piste audio).
    var musicStart: CMTime
}

enum MontagePlanner {

    /// Base de temps commune du montage. 600 divise 24, 30 et 60 i/s.
    static let timescale: CMTimeScale = 600

    /// Place les clips sur les créneaux, dans l'ordre.
    ///
    /// - Un créneau consomme le PROCHAIN clip dont le fichier couvre la durée
    ///   requise ; les clips trop courts sont écartés (jamais tronqués : une
    ///   coupe qui ne tombe pas sur le beat est pire qu'un clip absent).
    /// - Le montage s'arrête quand il n'y a plus de clips — les créneaux
    ///   restants ne produisent rien.
    static func plan(slots: [BeatSlot],
                     clips: [MontageClipCandidate],
                     windowStart: Double) -> MontagePlan {
        // CONVERSION UNIQUE : chaque borne de créneau devient un CMTime une
        // seule fois ; toutes les durées sont des différences de ces valeurs.
        let boundaries: [(start: CMTime, end: CMTime)] = slots.map { slot in
            (CMTime(seconds: slot.start, preferredTimescale: timescale),
             CMTime(seconds: slot.start + slot.duration, preferredTimescale: timescale))
        }
        // ORIGINE = LE PREMIER CRÉNEAU, jamais windowStart brut. Les créneaux
        // démarrent au premier beat ≥ windowStart : la moindre différence
        // entre les deux (fenêtre suggérée entre deux beats, arrondi de
        // persistance) deviendrait une amorce de VIDÉO NOIRE en tête du
        // fichier, musique par-dessus. La musique démarre au même instant —
        // l'alignement est préservé par construction, tout est différence
        // des mêmes CMTime.
        let origin = boundaries.first?.start
            ?? CMTime(seconds: windowStart, preferredTimescale: timescale)

        var placements: [MontagePlacement] = []
        var skipped: [Int] = []
        var clipIterator = clips.makeIterator()
        var pending = clipIterator.next()
        var lastEnd = CMTime.zero

        for (slotIndex, slot) in slots.enumerated() {
            guard pending != nil else { break }
            let slotDuration = CMTimeSubtract(boundaries[slotIndex].end,
                                              boundaries[slotIndex].start)
            guard CMTimeCompare(slotDuration, .zero) > 0 else { continue }

            // Chercher le prochain clip capable de couvrir ce créneau.
            var placed = false
            while let clip = pending {
                // Durée SOURCE requise = durée créneau × vitesse (0,5× → moitié).
                let required = TimeMath.reduce(CMTimeMultiplyByRatio(
                    slotDuration,
                    multiplier: Int32(clip.speed.numerator),
                    divisor: Int32(clip.speed.denominator)
                ))
                let sourceEnd = CMTimeAdd(clip.startInFile, required)
                if CMTimeCompare(sourceEnd, clip.fileDuration) <= 0 {
                    let timelineStart = CMTimeSubtract(boundaries[slotIndex].start, origin)
                    placements.append(MontagePlacement(
                        clipID: clip.id,
                        slotIndex: slotIndex,
                        sourceRange: CMTimeRange(start: clip.startInFile, duration: required),
                        timelineStart: timelineStart,
                        timelineDuration: slotDuration,
                        section: slot.section
                    ))
                    lastEnd = CMTimeAdd(timelineStart, slotDuration)
                    pending = clipIterator.next()
                    placed = true
                    break
                }
                // Fichier trop court pour CE créneau : clip écarté, pas
                // raccourci — le créneau essaie le clip suivant.
                skipped.append(clip.id)
                pending = clipIterator.next()
            }
            _ = placed
        }

        return MontagePlan(placements: placements,
                           skippedClipIDs: skipped,
                           totalDuration: lastEnd,
                           musicStart: origin)
    }
}
