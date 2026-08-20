//
//  OverlayPreviewLayer.swift
//  ClipFlow
//
//  Incrustations DESSINÉES EN SWIFTUI par-dessus l'aperçu vidéo.
//
//  Pourquoi une seconde implémentation du rendu, alors qu'on tenait à n'en
//  avoir qu'une : `AVVideoCompositionCoreAnimationTool` est documenté par
//  Apple comme un outil de rendu HORS LIGNE. Attaché à la composition d'un
//  `AVPlayerItem`, il est au mieux ignoré — l'aperçu ne montrait alors aucune
//  incrustation — au pire il invalide l'élément et le lecteur reste noir.
//  L'utilisateur aurait posé son logo, lancé l'aperçu, ne l'aurait pas vu, et
//  aurait conclu que la fonction ne marche pas.
//
//  Ce que cette vue garantit à la place : la MÊME géométrie que l'export.
//  Positions et tailles sont en fractions de l'image, la police suit la même
//  formule, et la fenêtre de visibilité lit les mêmes `ResolvedOverlay`. La
//  seule chose qui diffère est la technologie de dessin.
//

import SwiftUI
import CoreMedia

struct OverlayPreviewLayer: View {

    /// Incrustations résolues — exactement celles passées à l'export.
    var overlays: [ResolvedOverlay]
    /// Position de lecture dans le montage, en secondes.
    var currentTime: Double
    /// Rapport largeur/hauteur de la vidéo rendue, pour retrouver le cadre
    /// réel de l'image dans le lecteur (qui la laisse en boîte aux lettres).
    var videoRatio: CGFloat

    var body: some View {
        GeometryReader { geometry in
            // Le lecteur affiche la vidéo en PLEINE VISIBILITÉ dans son cadre :
            // l'image occupe une sous-partie centrée. Poser les incrustations
            // sur tout le cadre les décalerait de la hauteur des bandes noires.
            let videoRect = fittedRect(in: geometry.size, ratio: videoRatio)

            ZStack(alignment: .topLeading) {
                ForEach(visibleOverlays(), id: \.stackOrder) { overlay in
                    content(overlay, videoWidth: videoRect.width)
                        .position(
                            x: videoRect.width * overlay.centerX,
                            y: videoRect.height * overlay.centerY
                        )
                }
            }
            // ROGNAGE AU CADRE DE L'IMAGE, comme à l'export : une incrustation
            // qui déborde doit être coupée par le bord de la vidéo, pas
            // s'étaler sur les bandes noires du lecteur.
            .frame(width: videoRect.width, height: videoRect.height)
            .clipped()
            .offset(x: videoRect.minX, y: videoRect.minY)
            .frame(width: geometry.size.width, height: geometry.size.height,
                   alignment: .topLeading)
            // Purement indicatif : le geste appartient au lecteur en dessous.
            .allowsHitTesting(false)
        }
    }

    /// Incrustations dont la fenêtre couvre l'instant courant.
    private func visibleOverlays() -> [ResolvedOverlay] {
        overlays.filter { overlay in
            let start = overlay.start.seconds
            let end = start + overlay.duration.seconds
            return currentTime >= start - 0.001 && currentTime <= end + 0.001
        }
    }

    @ViewBuilder
    private func content(_ overlay: ResolvedOverlay, videoWidth: CGFloat) -> some View {
        let width = videoWidth * overlay.relativeWidth
        switch overlay.kind {
        case .image:
            if let image = Self.image(at: overlay.imageURL) {
                // MÊME formule que `OverlayRenderer.makeImageLayer` : hauteur
                // calculée, jamais plafonnée par le cadre du lecteur. Avec un
                // ajustement automatique, une incrustation plus haute que
                // l'image rétrécissait à l'écran alors que le fichier, lui, la
                // rogne — l'aperçu montrait 56 % là où l'export écrit 70 %.
                let ratio = image.size.height / max(image.size.width, 1)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: width, height: width * ratio)
            }
        case .text:
            // MÊME FORMULE que le moteur d'export (largeur × 0,22) : sans
            // cela, le texte n'aurait pas la même taille à l'écran et dans
            // le fichier.
            Text(overlay.text)
                .font(.system(size: width * 0.22, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Images gardées en mémoire, partagées par toutes les instances de la vue.
    ///
    /// C'était un `UIImage(contentsOfFile:)` posé dans le corps : le suivi de
    /// lecture reconstruit cette vue vingt fois par seconde, donc vingt
    /// décodages de PNG par seconde et par incrustation, sur le fil principal.
    private static let imageCache = NSCache<NSString, UIImage>()

    private static func image(at url: URL?) -> UIImage? {
        guard let url else { return nil }
        let key = url.path as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Plus grand cadre du rapport voulu tenant dans l'espace, centré.
    private func fittedRect(in available: CGSize, ratio: CGFloat) -> CGRect {
        guard available.width > 0, available.height > 0, ratio > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        var size = CGSize(width: available.width, height: available.width / ratio)
        if size.height > available.height {
            size = CGSize(width: available.height * ratio, height: available.height)
        }
        return CGRect(x: (available.width - size.width) / 2,
                      y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
