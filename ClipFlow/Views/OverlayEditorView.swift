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
//  LA MISE EN PAGE NE BOUGE JAMAIS. La zone de réglages a une hauteur
//  VERROUILLÉE (pas un plancher : un panneau de texte en portée par clips
//  dépasse 290 pt et poussait quand même) et son surplus défile. La sélection
//  n'a lieu qu'au relâchement. Faire apparaître le panneau pendant un
//  glissement retirait ~190 pt au cadre de pose, et
//  `.position(canvasSize.height × centerY)` téléportait l'incrustation loin du
//  doigt — en changeant au passage le gain de la translation.
//
//  En PAYSAGE la réserve verticale n'a pas de sens : elle ne laissait qu'une
//  vingtaine de points au cadre de pose et poussait « Terminé » hors écran.
//  Les réglages passent alors dans une colonne latérale défilante.
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Paysage sur iPhone. L'app le déclare, et l'écran de montage s'y adapte
    /// déjà : cet écran-ci réservait une hauteur fixe, ce qui écrasait le
    /// cadre de pose à une vingtaine de points et poussait « Terminé » sous le
    /// bord de l'écran. En hauteur compacte, la réserve devient une COLONNE.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

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
        Group {
            if isCompactHeight {
                HStack(spacing: 0) {
                    canvas
                    ScrollView { controls }
                        .frame(width: 340)
                }
            } else {
                VStack(spacing: 0) {
                    canvas
                    controls
                }
            }
        }
        // Le clavier ne RETRANCHE PLUS la zone sûre : sans cela, saisir le
        // texte d'une incrustation écrasait le cadre de pose à zéro — on
        // écrivait sans plus voir où le texte est posé, ce qui est la seule
        // raison d'avoir mis ce champ ici — et poussait la rangée d'actions
        // sous le clavier. La sortie se fait par le bouton « Terminé » de la
        // barre de clavier, posé dans l'inspecteur.
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
        // Filet de sécurité : la saisie de texte n'enregistre pas à chaque
        // frappe. Fermer l'écran sans valider ne doit pas perdre la retouche.
        // Et un calque de texte laissé VIDE ne se dessinerait nulle part : il
        // resterait une case invisible dans le projet. L'ajout refuse déjà le
        // vide, la retouche s'aligne dessus.
        .onDisappear {
            for layer in project.overlays where layer.kind == .text
                && layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if selectedLayer === layer { selectedLayer = nil }
                modelContext.delete(layer)
            }
            try? modelContext.save()
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
                if layer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // REPÈRE D'ÉDITION SEULEMENT : il n'entre pas dans le
                    // rendu — le calque reste écarté tant qu'il est vide. Sans
                    // lui, effacer le texte laissait un carré invisible qu'on
                    // ne pouvait plus ni retrouver ni supprimer.
                    Image(systemName: "textformat")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(6)
                        .background(.black.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 4))
                } else {
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
                    // DÉFILANT : un panneau de texte en portée par clips fait
                    // près de 290 pt. Un `minHeight` l'aurait laissé pousser,
                    // et le cadre de pose aurait rétréci AU MOMENT du
                    // relâchement du doigt — le saut n'aurait été que déplacé
                    // de « pendant le geste » à « juste après ».
                    ScrollView {
                        OverlayInspector(
                            layer: selected,
                            clipCount: plan.placements.count,
                            videoRatio: Double(backdropRatio),
                            // Fermeture, pas une chaîne déjà calculée : le
                            // libellé demande la résolution des portées,
                            // inutile de la refaire à chaque image d'un
                            // glissement.
                            durationLabel: { durationLabel(selected) },
                            onChange: { try? modelContext.save() }
                        )
                        .padding(.bottom, 4)
                    }
                    .scrollBounceBehavior(.basedOnSize)
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
            // VERROU, pas plancher — et libre en paysage, où la réserve est
            // une colonne défilante.
            .frame(height: isCompactHeight ? nil : 250, alignment: .top)

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .contentShape(Circle())
                }
                .disabled(!shapeIsKnown)
                .accessibilityLabel("Ajouter une image")

                Button {
                    draftText = ""
                    showTextField = true
                } label: {
                    Image(systemName: "textformat")
                }
                .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
                // Tant que la forme du montage est inconnue, créer graverait
                // un centre ancré calculé sur un 9:16 supposé — l'écran refuse
                // déjà de régler dans ces conditions, il doit refuser de créer.
                .disabled(!shapeIsKnown)
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

    private func relativeHeight(of layer: OverlayLayer) -> Double {
        OverlayGeometry.height(of: layer, videoRatio: Double(backdropRatio))
    }

    private func relativeSpan(of layer: OverlayLayer) -> Double {
        OverlayGeometry.span(of: layer)
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
        Task { @MainActor in
            imageCache[filename] = image
            // Rattrapage des calques posés avant que le rapport ne soit
            // mémorisé : sans lui, ils garderaient un carré supposé.
            let aspect = Double(image.size.height / max(image.size.width, 1))
            if abs(layer.imageAspect - aspect) > 0.0001, layer.modelContext != nil {
                layer.imageAspect = aspect
                try? modelContext.save()
            }
        }
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
            // RAPPORT MÉMORISÉ sur le calque : toute la géométrie se calcule
            // ensuite sans rouvrir le fichier, y compris depuis l'écran de
            // montage quand il faut recoller les ancrages.
            layer.imageAspect = Double(image.size.height / max(image.size.width, 1))
            // Cache amorcé AVANT tout calcul : la vue doit dessiner la bonne
            // taille dès son premier passage.
            imageCache[filename] = image
            // Position DÉDUITE de l'ancrage, jamais écrite en dur : une
            // constante 0,86 contredisait la règle du même ancrage, si bien
            // que le logo naissait déjà coupé en bas d'un montage large et
            // sautait au premier effleurement du curseur de taille.
            applyAnchorAtCreation(layer)
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
        // Taille DÉDUITE du texte saisi. À 0,5 en dur, tout titre de plus
        // d'une douzaine de capitales naissait plus large que l'image, coupé
        // des deux côtés à l'aperçu comme à l'export — et les trois colonnes
        // d'ancrage donnaient alors le même centre, sans que rien ne le dise.
        layer.relativeWidth = OverlayGeometry.initialTextWidth(for: trimmed)
        layer.anchorIndex = 1 // haut centre : la place d'un titre
        applyAnchorAtCreation(layer)
        layer.stackOrder = (layers.map(\.stackOrder).max() ?? -1) + 1
        modelContext.insert(layer)
        layer.project = project
        try? modelContext.save()
        selectedLayer = layer
    }

    /// Pose le centre d'un calque neuf d'après son ancrage, avec la MÊME règle
    /// que le panneau de réglages.
    private func applyAnchorAtCreation(_ layer: OverlayLayer) {
        guard let center = OverlayLayer.anchoredCenter(
            anchorIndex: layer.anchorIndex,
            relativeSpan: relativeSpan(of: layer),
            relativeHeight: relativeHeight(of: layer)
        ) else { return }
        layer.centerX = center.x
        layer.centerY = center.y
        layer.anchorVideoRatio = Double(backdropRatio)
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
