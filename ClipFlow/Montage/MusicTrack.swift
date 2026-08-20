//
//  MusicTrack.swift
//  ClipFlow
//
//  BIBLIOTHÈQUE MUSICALE LOCALE : un morceau importé une fois, analysé une
//  fois, réutilisable dans tous les projets.
//
//  Pourquoi cette entité existe. La musique était attachée AU PROJET : chaque
//  nouveau montage imposait de retrouver le fichier dans Fichiers et
//  d'attendre une nouvelle analyse, pour un morceau déjà utilisé dix fois.
//  Ici le morceau est un objet de plein droit : il porte son BPM, sa durée et
//  sa carte de rythme, et un projet ne fait que le DÉSIGNER.
//
//  Conséquence directe sur le montage : choisir une musique devient un tap
//  dans une liste qui affiche déjà « 150 BPM · coupes 400 ms » — donc on
//  choisit en connaissance de cause, avant même de dérusher.
//
//  La recherche en ligne a été retirée en même temps. Mesuré sur le catalogue
//  réel : une fois écartées les licences non commerciales, ce qui restait
//  n'avait rien à voir avec un montage POV. De la musique à la fois gratuite,
//  autorisée en usage commercial et bonne n'existe pas — les bons catalogues
//  (Artlist, Epidemic) réservent leurs API aux plateformes sous contrat.
//  L'app se concentre donc sur ce qu'elle fait bien : gérer TES morceaux.
//

import Foundation
import SwiftData

@Model
final class MusicTrack {

    /// Nom affiché — celui du fichier d'origine, sans extension.
    var title: String = ""
    /// Nom du fichier dans Application Support/Music (UUID + extension).
    var filename: String = ""
    /// Date d'import : la liste montre les derniers arrivés en premier.
    var importedAt: Date = Date.now
    /// Dernier usage : un morceau qui sert souvent remonte.
    var lastUsedAt: Date?
    var fileSizeBytes: Int64 = 0

    // MARK: Résultats d'analyse, figés à l'import

    /// 0 tant que l'analyse n'a pas abouti (import en cours, ou échec).
    var bpm: Double = 0
    var durationSeconds: Double = 0
    /// Vrai quand la carte de rythme est en cache et exploitable.
    var isAnalyzed: Bool = false
    /// Message d'échec d'analyse, affiché dans la liste — un morceau qui
    /// n'a pas pu être analysé doit le DIRE, pas rester muet.
    var analysisError: String?

    init() {}

    var url: URL { MusicStore.url(forMusicFilename: filename) }

    /// Durée d'un clip à une densité donnée, en millisecondes — l'information
    /// qui permet de choisir un morceau AVANT de dérusher.
    func slotMilliseconds(density: CutDensity) -> Int? {
        guard bpm > 0 else { return nil }
        return Int((density.slotDuration(bpm: bpm) * 1000).rounded())
    }

    /// « 3:42 » — durée lisible.
    var durationLabel: String {
        guard durationSeconds > 0 else { return "—" }
        let total = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
