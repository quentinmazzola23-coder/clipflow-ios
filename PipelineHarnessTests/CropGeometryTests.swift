//
//  CropGeometryTests.swift
//
//  LA GÉOMÉTRIE DU RECADRAGE, vérifiée par la machine.
//
//  Elle ne l'était par rien jusqu'ici, et c'est le genre de calcul dont une
//  erreur ne se voit qu'à l'export : un cadre décalé de la moitié de l'image,
//  ou un axe qui glisse alors qu'il devrait être verrouillé et laisse entrer
//  une bande noire dans un montage censé n'en avoir aucune.
//
//  Le cas d'or est le premier test : le centre par défaut doit redonner
//  EXACTEMENT le centrage historique. C'est ce qui garantit qu'aucun montage
//  déjà réglé ne change de cadrage en installant cette version.
//

import Testing
import CoreGraphics
@testable import ClipFlowPipeline

struct CropGeometryTests {

    /// 16:9 dans un cadre 9:16 : c'est la LARGEUR qui déborde.
    private let wide = CGSize(width: 1920, height: 1080)
    private let portraitFrame = CGSize(width: 2160, height: 3840)
    /// 9:16 dans un cadre 16:9 : c'est la HAUTEUR qui déborde.
    private let tall = CGSize(width: 1080, height: 1920)
    private let landscapeFrame = CGSize(width: 3840, height: 2160)

    @Test("Le centre par defaut garde le centre")
    func defaultIsCentred() {
        let kept = CropGeometry.keptRect(center: CropGeometry.centered,
                                         orientedSize: wide,
                                         renderSize: portraitFrame,
                                         cropToFill: true)
        #expect(abs(kept.midX - 0.5) < 1e-9)
        #expect(abs(kept.midY - 0.5) < 1e-9)
    }

    @Test("Une source large ne bouge qu'en largeur")
    func wideSourceMovesHorizontally() {
        let limits = CropGeometry.bounds(orientedSize: wide,
                                         renderSize: portraitFrame,
                                         cropToFill: true)
        // L'axe vertical est celui qui a servi au remplissage : verrouillé.
        #expect(limits.y == 0.5...0.5)
        #expect(limits.x.lowerBound < 0.5)
        #expect(limits.x.upperBound > 0.5)
    }

    @Test("Une source verticale ne bouge qu'en hauteur")
    func tallSourceMovesVertically() {
        let limits = CropGeometry.bounds(orientedSize: tall,
                                         renderSize: landscapeFrame,
                                         cropToFill: true)
        #expect(limits.x == 0.5...0.5)
        #expect(limits.y.lowerBound < 0.5)
        #expect(limits.y.upperBound > 0.5)
    }

    @Test("Le cadre garde reste dans l'image, meme pousse a fond")
    func keptRectNeverLeavesTheImage() {
        for demanded in [-5.0, -0.2, 0.0, 0.5, 1.0, 3.0] {
            for (source, frame) in [(wide, portraitFrame), (tall, landscapeFrame)] {
                let kept = CropGeometry.keptRect(
                    center: CGPoint(x: demanded, y: demanded),
                    orientedSize: source, renderSize: frame, cropToFill: true
                )
                #expect(kept.minX >= -1e-9)
                #expect(kept.minY >= -1e-9)
                #expect(kept.maxX <= 1 + 1e-9)
                #expect(kept.maxY <= 1 + 1e-9)
            }
        }
    }

    @Test("La part gardee vaut le rapport des cadres")
    func visibleFractionMatchesTheRatios() {
        // 1920x1080 rempli dans 2160x3840 : echelle = 3840/1080 = 3,5555…
        // largeur mise a l'echelle = 6826,7 ; part gardee = 2160/6826,7 = 0,3164
        let visible = CropGeometry.visibleFraction(orientedSize: wide,
                                                   renderSize: portraitFrame,
                                                   cropToFill: true)
        #expect(abs(visible.height - 1) < 1e-9)
        #expect(abs(visible.width - 0.31640625) < 1e-6)
    }

    @Test("Rien a regler quand les rapports coincident")
    func nothingToAdjustOnMatchingAspect() {
        #expect(!CropGeometry.isAdjustable(orientedSize: wide,
                                           renderSize: landscapeFrame,
                                           cropToFill: true))
        #expect(CropGeometry.isAdjustable(orientedSize: wide,
                                          renderSize: portraitFrame,
                                          cropToFill: true))
    }

    @Test("Rien a regler en mode ceinturage")
    func nothingToAdjustWhenLetterboxing() {
        // Sans recadrage, l'image entiere est conservee : deplacer le cadre
        // ne retirerait ni n'ajouterait rien.
        #expect(!CropGeometry.isAdjustable(orientedSize: wide,
                                           renderSize: portraitFrame,
                                           cropToFill: false))
        let limits = CropGeometry.bounds(orientedSize: wide,
                                         renderSize: portraitFrame,
                                         cropToFill: false)
        #expect(limits.x == 0.5...0.5)
        #expect(limits.y == 0.5...0.5)
    }

    @Test("Une taille degeneree ne fait pas exploser le calcul")
    func degenerateSizesStaySafe() {
        let limits = CropGeometry.bounds(orientedSize: .zero,
                                         renderSize: portraitFrame,
                                         cropToFill: true)
        #expect(limits.x == 0.5...0.5)
        #expect(limits.y == 0.5...0.5)
        let safe = CropGeometry.clamp(CGPoint(x: .nan, y: .infinity),
                                      orientedSize: wide,
                                      renderSize: portraitFrame,
                                      cropToFill: true)
        #expect(safe.x.isFinite)
        #expect(safe.y.isFinite)
    }
}
