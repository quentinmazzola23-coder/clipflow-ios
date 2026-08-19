//
//  ColorProfileTests.swift
//  ClipFlowPipelineTests
//
//  Profil colorimétrique du rendu. Logique PURE : aucun média décodé, donc
//  exécutée à chaque poussée sur le runner macOS.
//
//  Ce que ces tests protègent : un rush HLG était décodé en BGRA 8 bits puis
//  ÉTIQUETÉ BT.709. Les valeurs restaient codées en HLG, le lecteur appliquait
//  la mauvaise courbe, et l'export sortait délavé — hautes lumières écrasées,
//  couleurs ternes. Le défaut ne tenait pas à un pixel mal calculé mais à une
//  INCOHÉRENCE ENTRE CE QU'ON ÉCRIT ET CE QU'ON DÉCLARE. C'est exactement ce
//  qu'on vérifie ici.
//

import Testing
import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox
@testable import ClipFlowPipeline

struct ColorProfileTests {

    // MARK: - HDR conservé

    /// HLG (le mode HDR de l'iPhone) : décodé dans son format natif 10 bits,
    /// écrit en Main10, déclaré BT.2020 + HLG. Aucune conversion nulle part.
    @Test func hlgIsPreservedEndToEnd() {
        let profile = RenderColorProfile.resolve(colorimetry: "hlg", requestedCodec: "hevc")
        #expect(profile.readerPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(profile.primaries == AVVideoColorPrimaries_ITU_R_2020)
        #expect(profile.transferFunction == AVVideoTransferFunction_ITU_R_2100_HLG)
        #expect(profile.yCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
        #expect(profile.hevcProfileLevel == kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        #expect(profile.isHDR)
        #expect(profile.label == "hlg")
    }

    /// PQ était REFUSÉ à l'export. Le chemin 10 bits le rend possible : seule
    /// la courbe de transfert change par rapport au HLG.
    @Test func pqIsPreservedEndToEnd() {
        let profile = RenderColorProfile.resolve(colorimetry: "pq", requestedCodec: "hevc")
        #expect(profile.readerPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(profile.transferFunction == AVVideoTransferFunction_SMPTE_ST_2084_PQ)
        #expect(profile.primaries == AVVideoColorPrimaries_ITU_R_2020)
        #expect(profile.isHDR)
        #expect(profile.label == "pq")
    }

    /// Un fichier déclaré HDR mais encodé en 8 bits serait le même mensonge
    /// dans l'autre sens : le profil 10 bits n'est pas optionnel.
    @Test func hdrAlwaysDemandsTenBits() {
        for colorimetry in ["hlg", "pq"] {
            let profile = RenderColorProfile.resolve(colorimetry: colorimetry, requestedCodec: "hevc")
            #expect(profile.hevcProfileLevel != nil, "Profil 10 bits manquant sur une source HDR")
            #expect(profile.readerPixelFormat != kCVPixelFormatType_32BGRA,
                    "Une source HDR ne doit jamais passer par la chaîne 8 bits")
        }
    }

    // MARK: - Codec

    /// Le réglage H.264 du projet est IGNORÉ en HDR : l'encodeur H.264 ne
    /// produit pas de flux 10 bits BT.2020 exploitable.
    @Test func h264IsOverriddenForHDR() {
        for colorimetry in ["hlg", "pq"] {
            let profile = RenderColorProfile.resolve(colorimetry: colorimetry, requestedCodec: "h264")
            #expect(profile.codec == "hevc", "H.264 retenu sur une source HDR")
        }
    }

    /// Hors HDR, le réglage du projet est respecté à la lettre.
    @Test func sdrKeepsTheRequestedCodec() {
        #expect(RenderColorProfile.resolve(colorimetry: "sdr", requestedCodec: "h264").codec == "h264")
        #expect(RenderColorProfile.resolve(colorimetry: "sdr", requestedCodec: "hevc").codec == "hevc")
    }

    // MARK: - SDR inchangé

    /// La chaîne BGRA du SDR n'est pas touchée : c'est elle qui avait résolu
    /// l'inversion de chrominance du moteur d'interpolation.
    @Test func sdrKeepsTheBGRAChain() {
        let profile = RenderColorProfile.resolve(colorimetry: "sdr", requestedCodec: "hevc")
        #expect(profile.readerPixelFormat == kCVPixelFormatType_32BGRA)
        #expect(profile.primaries == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(profile.transferFunction == AVVideoTransferFunction_ITU_R_709_2)
        #expect(profile.yCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_709_2)
        #expect(profile.hevcProfileLevel == nil)
        #expect(profile.isHDR == false)
    }

    /// Colorimétrie inconnue = traitée en SDR, jamais en HDR par optimisme :
    /// étiqueter du 709 en BT.2020 délaverait un export parfaitement sain.
    @Test func unknownColorimetryFallsBackToSDR() {
        for colorimetry in ["inconnue", "", "rec709"] {
            let profile = RenderColorProfile.resolve(colorimetry: colorimetry, requestedCodec: "hevc")
            #expect(profile.isHDR == false, "Colorimétrie inconnue promue en HDR")
            #expect(profile.readerPixelFormat == kCVPixelFormatType_32BGRA)
        }
    }

    // MARK: - Cohérence en-tête / images

    /// LE TEST QUI COMPTE. Les étiquettes posées sur chaque image (CoreVideo)
    /// doivent désigner la même colorimétrie que celle écrite dans l'en-tête
    /// du fichier (AVFoundation). Une divergence entre les deux est
    /// exactement le défaut d'origine, en pire : une image délavée isolée au
    /// milieu d'un clip correct.
    @Test func bufferTagsMatchTheFileHeader() {
        let cases: [(String, CFString, CFString, CFString)] = [
            ("sdr", kCVImageBufferColorPrimaries_ITU_R_709_2,
             kCVImageBufferTransferFunction_ITU_R_709_2,
             kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            ("hlg", kCVImageBufferColorPrimaries_ITU_R_2020,
             kCVImageBufferTransferFunction_ITU_R_2100_HLG,
             kCVImageBufferYCbCrMatrix_ITU_R_2020),
            ("pq", kCVImageBufferColorPrimaries_ITU_R_2020,
             kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
             kCVImageBufferYCbCrMatrix_ITU_R_2020),
        ]
        for (colorimetry, primaries, transfer, matrix) in cases {
            let profile = RenderColorProfile.resolve(colorimetry: colorimetry, requestedCodec: "hevc")
            #expect(profile.bufferPrimaries == primaries as String,
                    "Primaires image ≠ primaires fichier")
            #expect(profile.bufferTransferFunction == transfer as String,
                    "Courbe image ≠ courbe fichier")
            #expect(profile.bufferYCbCrMatrix == matrix as String,
                    "Matrice image ≠ matrice fichier")
        }
    }
}
