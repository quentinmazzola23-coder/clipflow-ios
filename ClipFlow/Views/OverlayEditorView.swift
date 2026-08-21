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
//  LA MISE EN PAGE NE BOUGE PAS TANT QU'IL Y A QUELQUE CHOSE À DÉPLACER.
//  Dès qu'une incrustation existe, la zone de réglages occupe une hauteur
//  VERROUILLÉE — pas un plancher, un panneau chargé la dépassait et poussait
//  quand même — et son surplus défile ; la sélection n'a lieu qu'au
//  relâchement. Sans cela, faire apparaître le panneau pendant un glissement
//  retirait ~190 pt au cadre de pose, et `.position(hauteur × centerY)`
//  téléportait l'incrustation loin du doigt, en changeant au passage le gain
//  de la translation. Tant qu'aucune incrustation n'est posée, la réserve
//  n'existe pas : il n'y a rien à sélectionner, donc rien à faire sauter, et
//  270 pt vides ramenaient le cadre à 139 pt de large sur un petit écran.
//
//  En PAYSAGE la réserve verticale n'a pas de sens : elle ne laissait qu'une
//  vingtaine de points au cadre de pose et poussait « Terminé » hors écran.
//  Les réglages passent alors dans une colonne latérale défilante, dont la
//  rangée d'actions reste ancrée en bas.
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
    /// Calque en cours de RETOUCHE. `nil` = l'alerte crée un nouveau calque.
    @State private var editingTextLayer: OverlayLayer?
    @State private var showPresets = false
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
                    VStack(spacing: 10) {
                        // Les RÉGLAGES défilent, la rangée d'actions NON :
                        // mise dans la zone défilante, elle passait sous le
                        // pli et changeait de place à chaque sélection —
                        // « Terminé » devenait introuvable.
                        //
                        // La zone prend TOUTE la hauteur restante, sélection ou
                        // non : sans cela la rangée d'actions remontait au
                        // milieu de la colonne quand rien n'était sélectionné,
                        // puis redescendait d'une centaine de points au premier
                        // toucher.
                        inspectorZone
                            .frame(maxHeight: .infinity, alignment: .top)
                        actionRow
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: 320)
                }
            } else {
                VStack(spacing: 10) {
                    canvas
                    // RÉSERVE seulement s'il y a quelque chose à régler.
                    //
                    // Elle existe pour que le cadre de pose ne change pas de
                    // taille quand le panneau apparaît — un glissement en
                    // cours verrait sinon l'incrustation sauter sous le doigt.
                    // Sans aucune incrustation posée, il n'y a rien à
                    // sélectionner donc rien à faire sauter : garder 270 pt
                    // vides ramenait le cadre à 139 pt de large sur un petit
                    // écran, pour un montage portrait.
                    if !layers.isEmpty {
                        inspectorZone
                            .frame(height: 270, alignment: .top)
                    }
                    actionRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
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
        // Filet de sécurité : les réglages enregistrent déjà au fil de l'eau,
        // mais fermer l'écran ne doit rien laisser en suspens.
        //
        // AUCUNE SUPPRESSION AUTOMATIQUE ICI. Il y en a eu une, qui effaçait
        // les textes vides à la fermeture : elle détruisait le placement et la
        // portée réglés, sans un mot, juste après un message qui invitait à
        // « retaper un texte ». Le vide ne peut plus arriver — la saisie passe
        // par l'alerte, qui le refuse.
        .onDisappear { try? modelContext.save() }
        .alert("Incrustations", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .sheet(isPresented: $showPresets) {
            NavigationStack {
                OverlayPresetSheet(project: project,
                                   videoRatio: Double(backdropRatio))
            }
        }
        // Poser un préréglage remplace les calques : la sélection courante
        // désignerait alors un objet supprimé.
        .onChange(of: showPresets) { _, presented in
            if !presented { selectedLayer = nil }
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

    /// Zone des RÉGLAGES, hauteur pilotée par l'appelant.
    ///
    /// Séparée de la rangée d'actions : mises ensemble dans une zone
    /// défilante, « Terminé » et la corbeille passaient sous le pli en
    /// paysage et changeaient de place à chaque sélection.
    private var inspectorZone: some View {
        Group {
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
        }
    }

    private var actionRow: some View {
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
            // `PhotosPicker` ne se grise pas tout seul : sans cela le bouton
            // paraissait actif et ne répondait pas, ce qui se lit comme une
            // panne.
            .opacity(shapeIsKnown ? 1 : 0.35)
            .accessibilityLabel("Ajouter une image")

            Button {
                // Un texte SÉLECTIONNÉ se retouche ; sinon on en crée un. Le
                // texte n'était saisissable qu'une fois : une faute de frappe
                // obligeait à supprimer l'incrustation et à refaire tout le
                // placement.
                if let selected, selected.kind == .text {
                    editingTextLayer = selected
                    draftText = selected.text
                } else {
                    editingTextLayer = nil
                    draftText = ""
                }
                showTextField = true
            } label: {
                Image(systemName: selected?.kind == .text
                      ? "character.cursor.ibeam" : "textformat")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            // Tant que la forme du montage est inconnue, créer graverait
            // un centre ancré calculé sur un 9:16 supposé — l'écran refuse
            // déjà de régler dans ces conditions, il doit refuser de créer.
            .disabled(!shapeIsKnown)
            .opacity(shapeIsKnown ? 1 : 0.35)
            .accessibilityLabel(selected?.kind == .text
                                ? "Modifier le texte" : "Ajouter un texte")

            // PRÉRÉGLAGES : reposer une configuration entière — « texte
            // d'intro sur le premier clip, filigrane partout » — sur un
            // nouveau projet, sans tout replacer à la main.
            Button {
                showPresets = true
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .buttonStyle(GlassIconButtonStyle(tint: .secondary, diameter: 46))
            .accessibilityLabel("Préréglages d'incrustations")

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
        // Posée ICI et non à côté de l'alerte des erreurs : deux `.alert` sur
        // la même vue se disputent la présentation, une seule s'affiche.
        //
        // C'est aussi le SEUL chemin de saisie de texte, création comme
        // retouche : un champ posé dans le panneau de réglages ne pouvait
        // coexister avec le clavier sans cacher soit le cadre de pose, soit
        // lui-même. Elle refuse le vide, ce qui supprime du même coup tout
        // l'état « incrustation de texte sans texte ».
        .alert(editingTextLayer == nil ? "Texte" : "Modifier le texte",
               isPresented: $showTextField) {
            TextField("Votre texte", text: $draftText)
            Button(editingTextLayer == nil ? "Ajouter" : "Enregistrer") { submitText() }
            Button("Annuler", role: .cancel) {
                draftText = ""
                editingTextLayer = nil
            }
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
                // Le rapport connu, l'ancrage doit être RECOLLÉ tout de suite :
                // corriger la donnée sans corriger la position laissait le
                // calque là où une hauteur supposée l'avait mis.
                if layer.anchorIndex >= 0 { applyAnchorAtCreation(layer) }
                try? modelContext.save()
            }
        }
        return image
    }

    // MARK: - Ajout et suppression

    private func addImage(from item: PhotosPickerItem) async {
        defer { photoItem = nil }
        // Le BOUTON est désactivé quand la forme est inconnue, mais pas ce
        // rappel : une sélection de photo commencée avant peut aboutir après,
        // et graverait un centre ancré calculé sur un 9:16 supposé.
        guard shapeIsKnown else {
            message = "La forme du montage n'est pas encore connue : "
                + "réessayez dans un instant."
            return
        }
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

    /// Valide l'alerte : retouche le texte du calque visé, ou en crée un.
    ///
    /// Un texte VIDE est refusé dans les deux cas — il ne se dessinerait ni
    /// dans l'aperçu ni dans le fichier, et laisserait une incrustation
    /// invisible qu'on ne pourrait plus retrouver.
    private func submitText() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        draftText = ""
        let target = editingTextLayer
        editingTextLayer = nil
        guard !trimmed.isEmpty else {
            // Différé : présenter une alerte pendant qu'une autre se referme
            // les fait se disputer, et l'une des deux est avalée.
            let explanation = target == nil
                ? "Un texte vide ne s'afficherait nulle part : aucune "
                    + "incrustation n'a été créée."
                : "Un texte vide ne s'afficherait nulle part : l'incrustation "
                    + "garde son texte précédent. Pour la retirer, utilisez "
                    + "la corbeille."
            Task { @MainActor in message = explanation }
            return
        }
        if let target, target.modelContext != nil {
            target.text = trimmed
            // LE DÉBORDEMENT EST RABOTÉ, la taille réglée est GARDÉE.
            //
            // `relativeWidth` ne règle que la taille des lettres : garder
            // celle d'un texte court en le remplaçant par un long donnait un
            // titre plus large que l'image — « GO » remplacé par « MON MONTAGE
            // DU DIMANCHE » passait à 164 % de large, coupé des deux côtés, et
            // `anchoredCenter` saturait alors à 0,5, si bien qu'un titre ancré
            // à gauche se retrouvait centré en silence.
            //
            // Mais la recalculer entièrement était pire : le curseur est le
            // SEUL réglage de taille de l'écran, et corriger une lettre d'un
            // texte réduit à 8 % le renvoyait d'un coup à 50 %. On ne descend
            // donc que si ça ne rentre plus, jamais on ne remonte. 0,94 est le
            // seuil de `anchoredCenter` — au-delà, ses marges de 3 % ne
            // tiennent plus et les trois colonnes d'ancrage se confondent.
            let spanAtFull = OverlayGeometry.textSpan(trimmed, relativeWidth: 1)
            if spanAtFull > 0 {
                let widthThatFits = min(1.0, max(0.05, 0.94 / spanAtFull))
                target.relativeWidth = min(target.relativeWidth, widthThatFits)
            }
            applyAnchorAtCreation(target)
            try? modelContext.save()
            return
        }
        addText(trimmed)
    }

    private func addText(_ trimmed: String) {
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

    /// Rapport largeur/hauteur qui fait FOI pour toute la géométrie.
    ///
    /// Les MÉTADONNÉES d'abord, la vignette seulement en secours — et non
    /// l'inverse. La vignette est plafonnée à 1080 px et arrondie au pixel :
    /// son rapport vaut 1,7763 là où le rendu vaut 1,7778. L'écart est
    /// invisible à l'œil mais il suffisait à faire échouer la comparaison
    /// `anchorVideoRatio`, si bien que chaque reconstruction de plan recalait
    /// toutes les incrustations ancrées — un déplacement gratuit, à répétition,
    /// que personne n'avait demandé.
    private var backdropRatio: CGFloat {
        if let videoRatio, videoRatio > 0 { return videoRatio }
        if let backdrop, backdrop.size.width > 0, backdrop.size.height > 0 {
            return backdrop.size.width / backdrop.size.height
        }
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
