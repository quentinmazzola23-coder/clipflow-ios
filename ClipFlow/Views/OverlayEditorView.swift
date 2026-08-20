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
//  Placement PAR GLISSEMENT direct sur l'aperçu, taille PAR PINCEMENT — pas
//  de curseurs, pas de champs de coordonnées : on pose son logo là où on le
//  veut, comme sur une photo. La vignette de fond est une vraie image du
//  montage, donc le cadrage est jugé sur le contenu réel.
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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: PersistentIdentifier?
    @State private var photoItem: PhotosPickerItem?
    @State private var showTextField = false
    @State private var draftText = ""
    @State private var message: String?
    /// Échelle en cours de pincement, appliquée par-dessus la taille figée.
    @State private var pinchScale: CGFloat = 1
    /// Position au DÉBUT du glissement, en fractions. Le déplacement se
    /// calcule par rapport à elle.
    @State private var dragOrigin: (x: Double, y: Double)?
    /// Images déjà lues, gardées en mémoire : les relire du disque à chaque
    /// évaluation de la vue saccadait le glissement.
    @State private var imageCache: [String: UIImage] = [:]

    private var layers: [OverlayLayer] {
        project.overlays.sorted { $0.stackOrder < $1.stackOrder }
    }

    private var selected: OverlayLayer? {
        layers.first { $0.persistentModelID == selectedID }
    }

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
        .alert("Texte", isPresented: $showTextField) {
            TextField("Votre texte", text: $draftText)
            Button("Ajouter") { addText() }
            Button("Annuler", role: .cancel) { draftText = "" }
        } message: {
            Text("Le texte s'affiche en blanc, sans effet ni contour.")
        }
    }

    // MARK: - Zone de pose

    private var canvas: some View {
        GeometryReader { geometry in
            // Le cadre de pose respecte le RAPPORT de la vidéo : poser dans
            // un cadre d'une autre forme décalerait tout à l'export.
            let videoRatio = backdropRatio
            let size = fittedSize(in: geometry.size, ratio: videoRatio)

            ZStack {
                Color.black
                if let backdrop {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Text("Aperçu indisponible")
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
            .onTapGesture { selectedID = nil }
        }
    }

    private func overlayHandle(_ layer: OverlayLayer, canvasSize: CGSize) -> some View {
        let isSelected = layer.persistentModelID == selectedID
        let scale = isSelected ? pinchScale : 1
        let width = canvasSize.width * layer.relativeWidth * scale

        return Group {
            if layer.kind == .image, let image = cachedImage(for: layer) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
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
        .position(x: canvasSize.width * layer.centerX,
                  y: canvasSize.height * layer.centerY)
        .gesture(
            // TRANSLATION depuis la position de départ, jamais la position
            // absolue du doigt. Avec `location`, un pincement — dont SwiftUI
            // rapporte le point MILIEU des deux doigts — téléportait
            // l'incrustation sous la main au moment du redimensionnement.
            DragGesture()
                .onChanged { value in
                    selectedID = layer.persistentModelID
                    if dragOrigin == nil {
                        dragOrigin = (layer.centerX, layer.centerY)
                    }
                    guard let origin = dragOrigin else { return }
                    // Position en FRACTIONS, bornée au cadre : une
                    // incrustation posée hors champ serait invisible à
                    // l'export sans que rien ne le dise.
                    layer.centerX = min(max(0,
                        origin.x + value.translation.width / canvasSize.width), 1)
                    layer.centerY = min(max(0,
                        origin.y + value.translation.height / canvasSize.height), 1)
                }
                .onEnded { _ in
                    dragOrigin = nil
                    try? modelContext.save()
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    selectedID = layer.persistentModelID
                    pinchScale = value.magnification
                }
                .onEnded { value in
                    // Bornes : sous 3 % l'incrustation devient un point, au
                    // delà de 100 % elle déborde du cadre.
                    layer.relativeWidth = min(max(0.03,
                        layer.relativeWidth * value.magnification), 1.0)
                    pinchScale = 1
                    dragOrigin = nil // le pincement a pu déclencher un glissement
                    try? modelContext.save()
                }
        )
        .onTapGesture { selectedID = layer.persistentModelID }
    }

    // MARK: - Commandes

    private var controls: some View {
        VStack(spacing: 10) {
            if let selected {
                scopeControls(selected)
            } else if !layers.isEmpty {
                Text("Touchez une incrustation pour régler sa durée.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

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
    }

    /// Portée temporelle : toute la vidéo, ou une plage de clips.
    private func scopeControls(_ layer: OverlayLayer) -> some View {
        let clipCount = plan.placements.count
        return VStack(spacing: 8) {
            Picker("Durée", selection: Binding(
                get: { layer.spansWholeMontage },
                set: { whole in
                    layer.spansWholeMontage = whole
                    if !whole, layer.lastClipIndex <= layer.firstClipIndex {
                        // Première limitation : une plage d'un clip, à étendre.
                        layer.lastClipIndex = layer.firstClipIndex
                    }
                    try? modelContext.save()
                }
            )) {
                Text("Toute la vidéo").tag(true)
                Text("Certains clips").tag(false)
            }
            .pickerStyle(.segmented)

            if !layer.spansWholeMontage, clipCount > 0 {
                HStack(spacing: 12) {
                    clipStepper("Du clip", value: Binding(
                        get: { layer.firstClipIndex },
                        set: { newValue in
                            layer.firstClipIndex = min(max(0, newValue), clipCount - 1)
                            if layer.lastClipIndex < layer.firstClipIndex {
                                layer.lastClipIndex = layer.firstClipIndex
                            }
                            try? modelContext.save()
                        }
                    ), bound: clipCount)
                    clipStepper("au clip", value: Binding(
                        get: { layer.lastClipIndex },
                        set: { newValue in
                            layer.lastClipIndex = min(max(layer.firstClipIndex, newValue),
                                                      clipCount - 1)
                            try? modelContext.save()
                        }
                    ), bound: clipCount)
                }
                // La durée réelle, en clair : des rangs de clips ne parlent
                // pas d'eux-mêmes.
                Text(durationLabel(layer))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func clipStepper(_ title: String, value: Binding<Int>, bound: Int) -> some View {
        Stepper(value: value, in: 0...(max(bound, 1) - 1)) {
            Text("\(title) \(value.wrappedValue + 1)")
                .font(.caption.monospacedDigit())
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
        if let cached = imageCache[filename] { return cached }
        guard let url = layer.imageURL,
              let image = UIImage(contentsOfFile: url.path) else { return nil }
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
            // Coin bas-droit par défaut : la place d'un filigrane.
            layer.centerX = 0.80
            layer.centerY = 0.86
            layer.relativeWidth = 0.22
            layer.stackOrder = (layers.map(\.stackOrder).max() ?? -1) + 1
            layer.project = project
            modelContext.insert(layer)
            try? modelContext.save()
            selectedID = layer.persistentModelID
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
        layer.centerX = 0.5
        layer.centerY = 0.18 // haut de l'image : la place d'un titre
        layer.relativeWidth = 0.5
        layer.stackOrder = (layers.map(\.stackOrder).max() ?? -1) + 1
        layer.project = project
        modelContext.insert(layer)
        try? modelContext.save()
        selectedID = layer.persistentModelID
    }

    private func remove(_ layer: OverlayLayer) {
        if let filename = layer.imageFilename {
            OverlayStore.deleteImage(filename: filename)
        }
        modelContext.delete(layer)
        try? modelContext.save()
        selectedID = nil
    }

    // MARK: - Géométrie

    private var backdropRatio: CGFloat {
        guard let backdrop, backdrop.size.width > 0 else { return 9.0 / 16.0 }
        return backdrop.size.width / backdrop.size.height
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
