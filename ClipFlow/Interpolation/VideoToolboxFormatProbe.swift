//
//  VideoToolboxFormatProbe.swift
//  ClipFlow
//
//  Lecture ROBUSTE des dictionnaires d'attributs VideoToolbox. Chaque pont
//  Swift raté ici se traduit par une liste de formats vide, donc par une
//  supposition — et une supposition de format ne provoque aucune erreur : VT
//  réinterprète simplement la mémoire des plans.
//
//  Hors `#if !targetEnvironment(simulator)` : le pipeline s'en sert aussi, et
//  la sonde doit compiler partout.
//

import Foundation
import CoreVideo

enum VideoToolboxFormatProbe {

    /// Formats de pixel annoncés par un dictionnaire d'attributs.
    /// Tolère les trois pontages possibles de la valeur : nombre unique,
    /// tableau de NSNumber, tableau hétérogène issu d'un CFArray.
    static func pixelFormats(in attributes: Any?) -> [OSType] {
        guard let dictionary = attributes as? [String: Any],
              let value = dictionary[kCVPixelBufferPixelFormatTypeKey as String] else { return [] }
        if let number = value as? NSNumber { return [number.uint32Value] }
        if let list = value as? [NSNumber] { return list.map { $0.uint32Value } }
        if let list = value as? [Any] { return list.compactMap { ($0 as? NSNumber)?.uint32Value } }
        return []
    }

    /// Rend un OSType lisible : « BGRA (0x42475241) ».
    static func fourCC(_ format: OSType) -> String {
        let bytes = [
            UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
            UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        let ascii = printable ? String(decoding: bytes, as: UTF8.self) : "????"
        return "\(ascii) (0x\(String(format, radix: 16)))"
    }

    /// Description BRUTE d'un dictionnaire d'attributs, type dynamique compris.
    /// Sert l'instrumentation d'étape 0 : c'est elle qui doit établir si le
    /// dictionnaire se ponte réellement en `[String: Any]` — sinon la liste de
    /// formats est vide et tout le reste repose sur une supposition.
    static func describeAttributes(_ raw: Any?) -> String {
        guard let raw else { return "nil" }
        var report = "type dynamique = \(type(of: raw))\n"
        guard let dictionary = raw as? [String: Any] else {
            report += "  NON PONTABLE en [String: Any] — contenu brut : \(raw)"
            return report
        }
        for key in dictionary.keys.sorted() {
            let value = dictionary[key]!
            if key == kCVPixelBufferPixelFormatTypeKey as String {
                report += "  \(key) : type \(type(of: value)) = \(value)\n"
            } else {
                report += "  \(key) = \(value)\n"
            }
        }
        return report
    }
}
