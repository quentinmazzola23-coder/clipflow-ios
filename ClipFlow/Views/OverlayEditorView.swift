//
//  OverlayEditorView.swift
//  ClipFlow
//
//  POSE DES INCRUSTATIONS : logo, filigrane ou texte, placés à la main sur
//  une image du montage.
//
//  Étape POSTÉRIEURE au montage musical : on ne décore pas une vidéo qu'on
//  n'a pas encore construite. L'écran s'ouvre depuis le montage, une fois les
//  clips placés.
//
//  Placement PAR ANCRAGE (neuf points) ou par glissement direct sur l'aperçu,
//  taille AU CURSEUR. Le pincement a été retiré : il se disputait le geste
//  avec le glissement. La vignette de fond est une vraie image du montage,
//  donc le cadrage est jugé sur le contenu réel.
//
//  LA MISE EN PAGE NE BOUGE PAS PENDANT UN GESTE. La zone de réglages a une
//  hauteur réservée et la sélection n'a lieu qu'au relâchement : faire
//  apparaître le panneau en plein glissement retirait ~190 pt au cadre de
//  pose, et `.position(canvasSize.height × centerY)` téléportait l'incrustation
//  loin du doigt — en changeant au passage le gain de la translation.
//

import SwiftUI
import SwiftData
import PhotosUI
import AVFoundation
import CoreMedia

struct OverlayEditorView: View {
    @Bindable var project: ClipProject
    /// Plan courant : donne le nombre de clips et leur découpe temporelle.
    var plan: MontagePlan
    /// Une image du montage, pour juger le placement sur du contenu réel.
    var backdrop: UIImage?
    /// Rapport largeur/hauteur du RENDU réel, lu dans les métadonnées de la
    /// piste. Il vaut même quand l'extraction de vignette échoue.
    var videoRatio: CGFloat?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Calque sélectionné, retenu PAR RÉFÉRENCE.
    ///
    /// Un `PersistentIdentifier` relevé juste après un `insert` est
    /// TEMPORAIRE : SwiftData le remplace à l'enregistrement, et la sélection
    /// devenait introuvable — les réglages disparaissaient tout seuls après
    /// l'ajout. La vue vit sur l'acteur principal, garder l'objet est sûr.
    @State private var selectedLayer: OverlayLayer?
    @State private var photoItem: PhotosPickerItem?
    @State private var showTextField = false
    @State private var draftText = ""
    @State private var message: String?
    /// Position au DÉBUT du glissement, en fractions, PAR CALQUE.
    ///
    /// C'était un état unique : deux doigts sur deux incrustations et la
    /// seconde partait de l'origine de la première, donc se téléportait. Le
    /// point de départ du doigt est mémorisé avec — si SwiftUI rapporte un
    /// autre `startLocation`, c'est un nouveau geste, ce qui purge une origine
    /// laissée par un glissement interrompu sans `onEnded`.
    @State private var dragOrigins: [ObjectIdentifier: (x: Double, y: Double, start: CGPoint)] = [:]
    /// Images déjà lues, gardées en mémoire : les relire du disque à chaque
    /// évaluation de la vue saccadait le glissement.
    @State private var imageCache: [String: UIImage] = [:]

    private var layers: [OverlayLayer] {
        project.overlays.sorted { $0.stackOrder < $1.stackOrder }
    }

    /// Sélection encore valide ? Un calque supprimé ne doit plus piloter les
    /// réglages.
    private var selected: OverlayLayer? {
        guard let selectedLayer, selectedLayer.modelContext != nil else { return nil }
        return selectedLayer
    }

    /// Forme du montage CONNUE ? Tant qu'elle ne l'est pas, on ne laisse pas
    /// régler la position : un ancrage calculé sur une forme supposée grave un
    /// centre faux dans le modèle, et il y survit.
    private var shapeIsKnown: Bool { backdrop != nil || videoRatio != nil }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .navigationTitle("Incrustations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.down") }
                    .accessibilityLabel("Fermer")
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await addImage(from: item) }
        }
        .alert("Incrustations", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - Zone de pose

    private var canvas: some View {
        GeometryReader { geometry in
            // Le cadre de pose respecte le RAPPORT de la vidéo : poser dans
            // un cadre d'une autre forme décalerait tout à l'export.
            let size = fittedSize(in: geometry.size, ratio: backdropRatio)

            ZStack {
                Color.black
                if let backdrop {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else if !shapeIsKnown {
                    Text("Préparation de l'aperçu…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(layers) { layer in
                    overlayHandle(layer, canvasSize: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Taper à côté désélectionne : sinon un réglage s'appliquerait au
            // dernier calque touché, sans qu'on sache lequel.
            .onTapGesture { selectedLayer = nil }
        }
    }

    private func overlayHandle(_ layer: OverlayLayer, canvasSize: CGSize) -> some View {
        let isSelected = selected === layer
        let width = canvasSize.width * layer.relativeWidth

        return Group {
            if layer.kind == .image, let image = cachedImage(for: layer) {
                // Hauteur DÉDUITE de la largeur, comme le moteur d'export : la
                // laisser à la proposition du parent faisait rétrécir
                // l'incrustation par ajustement automatique dès qu'elle
                // dépassait le cadre — alors que le fichier, lui, la rogne.
                let ratio = image.size.height / max(image.size.width, 1)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: width, height: width * ratio)
            } else if layer.kind == .text {
                // MÊME FORMULE que le moteur d'export, SANS plancher : un
                // `max(8, …)` rendait le texte lisible dans l'éditeur et
                // jusqu'à trois fois plus petit dans le fichier.
                Text(layer.text)
                    .font(.system(size: width * 0.22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.accent, lineWidth: 2)
                    .padding(-6)
            }
        }
        // PRISE TACTILE PLANCHER, indépendante de la taille réglée. À 5 % de
        // largeur le dessin ne fait plus qu'une quinzaine de points, alors
        // qu'il est la SEULE voie de sélection : il n'existe pas de liste de
        // calques, et le bouton Supprimer lui-même n'apparaît qu'une fois
        // quelque chose de sélectionné. Sans ce plancher, réduire une
        // incrustation au minimum puis la désélectionner la rendait
        // irrécupérable. Le contenu reste centré : rien ne bouge à l'écran.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .position(x: canvasSize.width * layer.centerX,
                  y: canvasSize.height * layer.centerY)
        .gesture(
            // GLISSEMENT PAR TRANSLATION depuis la position de départ. Le
            // pincement a été retiré : il se disputait ce geste — SwiftUI
            // rapporte le point milieu des deux doigts et l'incrustation
            // sautait sous la main. La taille se règle au curseur.
            DragGesture()
                .onChanged { value in
                    // SÉLECTION VOLONTAIREMENT PAS ICI : elle ferait
                    // apparaître le panneau de réglages, donc rétrécirait le
                    // cadre de pose en plein geste.
                    let key = ObjectIdentifier(layer)
                    let origin: (x: Double, y: Double, start: CGPoint)
                    if let known = dragOrigins[key], known.start == value.startLocation {
                        origin = known
                    } else {
                        origin = (layer.centerX, layer.centerY, value.startLocation)
                        dragOrigins[key] = origin
                    }
                    // Poser au doigt annule l'ancrage : sinon le prochain
                    // changement de taille ramènerait l'incrustation dans son
                    // coin, effaçant le placement qu'on vient de faire.
                    layer.anchorIndex = -1
                    // Position en FRACTIONS, bornée au cadre : une
                    // incrustation posée hors champ serait invisible à
                    // l'export sans que rien ne le dise.
                    layer.centerX = min(max(0,
                        origin.x + value.translation.width / canvasSize.width), 1)
                    layer.centerY = min(max(0,
                        origin.y + value.translation.height / canvasSize.height), 1)
                }
                .onEnded { _ in
                    dragOrigins[ObjectIdentifier(layer)] = nil
                    selectedLayer = layer // après le geste, plus pendant
                    try? modelContext.save()
                }
        )
        .onTapGesture { selectedLayer = layer }
    }

    // MARK: - Commandes

    private var controls: some View {
        VStack(spacing: 10) {
            // HAUTEUR RÉSERVÉE, pas conditionnelle : sans elle, faire
            // apparaître ou disparaître le panneau retaille le cadre de pose
            // (la pile racine n'a pas de zone défilante, le cadre encaisse) et
            // toutes les incrustations se déplacent à l'écran.
            ZStack(alignment: .top) {
                if let selected, shapeIsKnown {
                    OverlayInspector(
                        layer: selected,
                        clipCount: plan.placements.count,
                        relativeHeight: relativeHeight(of: selected),
                        relativeSpan: relativeSpan(of: selected),
                        // Fermeture, pas une chaîne déjà calculée : le libellé
                        // demande la résolution des portées, inutile de la
                        // refaire à chaque image d'un glissement.
                        durationLabel: { durationLabel(selected) },
                        onChange: { try? modelContext.save() }
                    )
                } else if selected != nil {
                    Text("Préparation de l'aperçu…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if !layers.isEmpty {
                    Text("Touchez une incrustation pour régler sa position, sa taille et sa durée.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 250, alignment: .top)

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("Ajouter une image")

                Button {
                    draftText = ""
                    showTextField = true
                } label: {
                    Image(systemName: "textformat")
                }
                .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
                .accessibilityLabel("Ajouter un texte")

                Spacer()

                if let selected {
                    Button(role: .destructive) {
                        remove(selected)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(GlassIconButtonStyle(tint: .red, diameter: 46))
                    .accessibilityLabel("Supprimer l'incrustation")
                }

                Button {
                    dismiss()
                } label: {
                    Label("Terminé", systemImage: "checkmark")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Posée ICI et non à côté de l'alerte des erreurs : deux `.alert` sur
        // la même vue se disputent la présentation, une seule s'affiche.
        .alert("Texte", isPresented: $showTextField) {
            TextField("Votre texte", text: $draftText)
            Button("Ajouter") { addText() }
            Button("Annuler", role: .cancel) { draftText = "" }
        } message: {
            Text("Le texte s'affiche en blanc, sans effet ni contour.")
        }
    }

    // MARK: - Encombrement réel

    /// Hauteur de l'incrustation en fraction de la HAUTEUR de l'image.
    ///
    /// Sert aux marges d'ancrage : une marge verticale fixe coupait le haut
    /// d'un logo carré posé en haut d'un montage 16:9 — à 30 % de largeur, sa
    /// demi-hauteur vaut 0,27, bien plus que la marge de 0,12 d'alors.
    private func relativeHeight(of layer: OverlayLayer) -> Double {
        let ratio = Double(backdropRatio) // largeur / hauteur de l'image
        switch layer.kind {
        case .image:
            guard let image = cachedImage(for: layer), image.size.width > 0 else {
                return layer.relativeWidth * ratio
            }
            return layer.relativeWidth * Double(image.size.height / image.size.width) * ratio
        case .text:
            // Même formule que le rendu : corps = largeur × 0,22, interligne 1,2.
            return layer.relativeWidth * 0.22 * 1.2 * ratio
        }
    }

    /// Largeur RÉELLEMENT occupée, en fraction de la largeur de l'image.
    ///
    /// Pour un texte, `relativeWidth` ne pilote que le CORPS de police : la
    /// largeur dépend du nombre de caractères et doit être MESURÉE. Sans cela
    /// l'ancrage visait une marge sans rapport avec ce qui est dessiné — un
    /// titre de vingt-cinq lettres ancré à gauche débordait de la moitié de
    /// l'image, et un « GO » ancré à gauche se retrouvait presque centré.
    private func relativeSpan(of layer: OverlayLayer) -> Double {
        switch layer.kind {
        case .image:
            return layer.relativeWidth
        case .text:
            let trimmed = layer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            // Mesure à une largeur de référence : la formule du rendu est
            // linéaire en largeur d'image, le RAPPORT ne dépend donc pas de la
            // définition de sortie.
            let reference: CGFloat = 1000
            let font = UIFont.systemFont(
                ofSize: reference * CGFloat(layer.relativeWidth) * 0.22,
                weight: .semibold
            )
            let measured = (trimmed as NSString).size(withAttributes: [.font: font])
            return Double(measured.width / reference)
        }
    }

    private func durationLabel(_ layer: OverlayLayer) -> String {
        let resolved = OverlayStore.resolve([layer],
                                            placements: plan.placements,
                                            totalDuration: plan.totalDuration)
        guard let first = resolved.first else { return "—" }
        return String(format: "Visible de %.1f s à %.1f s (%.1f s)",
                      first.start.seconds,
                      first.start.seconds + first.duration.seconds,
                      first.duration.seconds)
    }

    /// Image du calque, lue une seule fois du disque.
    private func cachedImage(for layer: OverlayLayer) -> UIImage? {
        guard let filename = layer.imageFilename else { return nil }
        if let cached = imageCache[filename] { return cached.size.width > 0 ? cached : nil }
        guard let url = layer.imageURL,
              let image = UIImage(contentsOfFile: url.path) else {
            // Fichier manquant ou illisible : on note l'échec avec une image
            // vide, sinon chaque passage de la vue retente une lecture disque.
            Task { @MainActor in
                if imageCache[filename] == nil { imageCache[filename] = UIImage() }
            }
            return nil
        }
        // Mutation d'état pendant l'évaluation de la vue : différée au tour
        // suivant, sinon SwiftUI s'en plaint (et boucle).
        Task { @MainActor in imageCache[filename] = image }
        return image
    }

    // MARK: - Ajout et suppression

    private func addImage(from item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            message = "Cette image n'a pas pu être lue. Choisissez une photo ou un PNG."
            return
        }
        do {
            let filename = try OverlayStore.saveImage(image)
            let layer = OverlayLayer()
            layer.kind = .image
            layer.imageFilename = filename
            layer.relativeWidth = 0.22
            layer.anchorIndex = 8 // bas droite : la place d'un filigrane
            // Cache amorcé AVANT tout calcul : `relativeHeight` doit rendre la
            // bonne valeur dès le premier passage de la vue, sinon l'ancrage
            // se recalcule et le logo saute.
            imageCache[filename] = image
            let ratio = Double(image.size.height / max(image.size.width, 1))
            // Position DÉDUITE de l'ancrage, jamais écrite en dur : une
            // constante 0,86 contredisait la règle du même ancrage, si bien
            // que le logo naissait déjà coupé en bas d'un montage large et
            // sautait au premier effleurement du curseur de taille.
            if let center = OverlayLayer.anchoredCenter(
                anchorIndex: layer.anchorIndex,
                relativeSpan: layer.relativeWidth,
                relativeHeight: layer.relativeWidth * ratio * Double(backdropRatio)
            ) {
                layer.centerX = center.x
                layer.centerY = center.y
            }
            layer.stackOrder = (layers.map(\.stackOrder).max() ?? -1) + 1
            // insert AVANT le rattachement : relier un objet non suivi à un
            // projet suivi laisse SwiftData réconcilier après coup.
            modelContext.insert(layer)
            layer.project = project
            try? modelContext.save()
            selectedLayer = layer
        } catch {
            message = error.localizedDescription
        }
    }

    private func addText() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        draftText = ""
        guard !trimmed.isEmpty else { return }
        let layer = OverlayLayer()
        layer.kind = .text
        layer.text = trimmed
        layer.relativeWidth = 0.5
        layer.anchorIndex = 1 // haut centre : la place d'un titre
        if let center = OverlayLayer.anchoredCenter(
            anchorIndex: layer.anchorIndex,
            relativeSpan: relativeSpan(of: layer),
            relativeHeight: relativeHeight(of: layer)
        ) {
            layer.centerX = center.x
            layer.centerY = center.y
        }
        layer.stackOrder = (layers.map(\.stackOrder).max() ?? -1) + 1
        modelContext.insert(layer)
        layer.project = project
        try? modelContext.save()
        selectedLayer = layer
    }

    private func remove(_ layer: OverlayLayer) {
        if let filename = layer.imageFilename {
            OverlayStore.deleteImage(filename: filename)
        }
        modelContext.delete(layer)
        try? modelContext.save()
        selectedLayer = nil
    }

    // MARK: - Géométrie

    private var backdropRatio: CGFloat {
        if let backdrop, backdrop.size.width > 0, backdrop.size.height > 0 {
            return backdrop.size.width / backdrop.size.height
        }
        // Repli sur la forme RÉELLE du rendu, jamais sur une valeur arbitraire :
        // un 9:16 supposé sur un montage 16:9 fausse le cadre de pose ET les
        // marges d'ancrage, et la position fausse est enregistrée.
        if let videoRatio, videoRatio > 0 { return videoRatio }
        return 9.0 / 16.0
    }

    /// Plus grand cadre du rapport voulu tenant dans l'espace disponible.
    private func fittedSize(in available: CGSize, ratio: CGFloat) -> CGSize {
        guard available.width > 0, available.height > 0, ratio > 0 else { return available }
        let byWidth = CGSize(width: available.width, height: available.width / ratio)
        return byWidth.height <= available.height
            ? byWidth
            : CGSize(width: available.height * ratio, height: available.height)
    }
}
