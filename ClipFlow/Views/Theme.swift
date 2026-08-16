//
//  Theme.swift
//  ClipFlow
//
//  Système de design minimal — Liquid Glass iOS 26, sobre et fonctionnel.
//  Un accent unique (jaune sélection), fonds sombres, verre natif partout où
//  le contrôle flotte au-dessus du contenu vidéo. Rien de décoratif.
//

import SwiftUI

enum Theme {
    /// Accent unique de l'app — la couleur de la sélection sur la timeline.
    static let accent = Color(red: 1.0, green: 0.8, blue: 0.0)
    /// Fond profond derrière la vidéo.
    static let surface = Color(red: 0.04, green: 0.05, blue: 0.08)
}

/// Bouton-icône rond en verre liquide interactif (transport, utilitaires).
/// Cible tactile 44 pt, retour d'appui par ressort discret.
struct GlassIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var diameter: CGFloat = 44
    /// Taille du glyphe. Par défaut celle des boutons de transport ; un bouton
    /// d'action principale plus large mérite un symbole à l'avenant.
    var glyphSize: CGFloat = 17
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: glyphSize, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
