//
//  ExportActivityAttributes.swift
//  ClipFlow
//
//  Attributs de la Live Activity d'export (Dynamic Island + écran verrouillé).
//
//  ⚠️ DUPLIQUÉ À L'IDENTIQUE dans ClipFlowWidgets/ExportActivityAttributes.swift :
//  ActivityKit apparie l'activité entre l'app et l'extension par le NOM du type
//  et la forme Codable de ContentState — les deux copies doivent rester
//  strictement synchronisées.
//

import Foundation
import ActivityKit

struct ExportActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Numéro du clip en cours (1-indexé).
        var clipIndex: Int
        /// Nombre total de clips de la file.
        var totalClips: Int
        /// Progression du clip en cours ∈ [0;1].
        var progress: Double
        /// Nom du fichier en cours d'export.
        var clipName: String
        /// Nombre d'échecs (affiché seulement si > 0).
        var failedClips: Int
    }
}
