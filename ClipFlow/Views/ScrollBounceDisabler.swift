//
//  ScrollBounceDisabler.swift
//  ClipFlow
//
//  Supprime le REBOND (over-scroll élastique) de la zone de défilement qui
//  contient cette vue — y compris quand le contenu est plus long que l'écran.
//
//  Pourquoi ce détour : `.scrollBounceBehavior(.basedOnSize)` ne traite QUE le
//  cas « contenu plus court que l'écran ». Dès qu'il y a assez de projets pour
//  défiler, SwiftUI réactive le rebond et rien dans l'API publique ne permet de
//  l'en empêcher. On atteint donc l'UIScrollView sous-jacente.
//
//  La sonde doit être posée DANS une ligne de la liste : depuis un `.background`
//  appliqué à la List elle-même, la chaîne des vues parentes ne traverse pas
//  forcément la zone de défilement.
//

import SwiftUI
import UIKit

struct ScrollBounceDisabler: UIViewRepresentable {

    func makeUIView(context: Context) -> UIView { BounceProbe() }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Les lignes d'une liste sont recyclées : la zone de défilement peut
        // changer entre deux passages. Nouvelle tentative à chaque mise à jour,
        // l'opération étant idempotente.
        (uiView as? BounceProbe)?.disableBounceInAncestors()
    }

    /// Vue invisible et transparente aux touchers : sa seule fonction est de
    /// remonter la hiérarchie jusqu'à la zone de défilement.
    private final class BounceProbe: UIView {

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            disableBounceInAncestors()
        }

        func disableBounceInAncestors() {
            var ancestor = superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.bounces = false
                    // Sans cela, une liste plus courte que l'écran resterait
                    // élastique verticalement.
                    scrollView.alwaysBounceVertical = false
                    return
                }
                ancestor = current.superview
            }
        }
    }
}
