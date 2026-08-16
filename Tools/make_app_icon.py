#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Génère l'icône de ClipFlow (1024x1024) en style « liquid glass ».

Pourquoi un générateur plutôt qu'un PNG posé là : l'icône est décrite par des
paramètres (angles, opacités, dégradé), donc relisible et modifiable — un
fichier binaire opaque ne se corrige pas.

Ce que l'ancienne icône faisait de travers, et qui est corrigé ici :
  - une tuile arrondie DANS l'icône : iOS arrondit déjà, le résultat donnait
    une icône dans une icône, bordée de vide ;
  - le mot « ClipFlow » gravé dans l'image : le système affiche déjà le nom
    sous l'icône, et à 60 px le texte n'était qu'une tache ;
  - un fond quasi noir : illisible sur un fond d'écran sombre.

Le sujet : une lame de lecture en verre, précédée de deux lames fantômes —
la lecture ralentie, qui est tout le propos de l'app. Aucun texte, plein cadre.

    python Tools/make_app_icon.py

Écrit ClipFlow/Assets.xcassets/AppIcon.appiconset/icon1024.png
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# Rendu en suréchantillonnage 4x : les diagonales du triangle sont la partie
# la plus fragile de l'image, un rendu direct en 1024 les crénellerait.
SCALE = 4
SIZE = 1024
S = SIZE * SCALE

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "ClipFlow" / "Assets.xcassets" / "AppIcon.appiconset" / "icon1024.png"

# Accent de l'app (Theme.accent = 1.0, 0.8, 0.0).
ACCENT = (255, 204, 0)


def linear_gradient(top: tuple[int, int, int], bottom: tuple[int, int, int],
                    tilt: float = 0.35) -> Image.Image:
    """Dégradé linéaire incliné, du coin haut-gauche vers le bas-droite."""
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32) / (S - 1)
    t = np.clip(ys * (1 - tilt) + xs * tilt, 0, 1)[..., None]
    a = np.array(top, dtype=np.float32)
    b = np.array(bottom, dtype=np.float32)
    return Image.fromarray((a + (b - a) * t).astype(np.uint8), "RGB")


def radial_glow(center: tuple[float, float], radius: float,
                colour: tuple[int, int, int], strength: float) -> Image.Image:
    """Halo radial doux, en RGBA — la source lumineuse de la scène."""
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32) / (S - 1)
    d = np.sqrt((xs - center[0]) ** 2 + (ys - center[1]) ** 2) / radius
    # Chute en cosinus : pas d'arête visible en limite de halo.
    falloff = np.clip(1 - d, 0, 1) ** 2
    alpha = (falloff * strength * 255).astype(np.uint8)
    rgb = np.empty((S, S, 3), dtype=np.uint8)
    rgb[..., 0], rgb[..., 1], rgb[..., 2] = colour
    return Image.fromarray(np.dstack([rgb, alpha]), "RGBA")


def blade_points(offset: float, width: float, height: float) -> list[tuple[float, float]]:
    """Triangle de lecture, en coordonnées normalisées puis mises à l'échelle.

    `offset` décale la lame vers la gauche (les fantômes de la traînée).
    """
    apex_x = 0.775 - offset
    left_x = apex_x - width
    top_y = 0.5 - height / 2
    bottom_y = 0.5 + height / 2
    return [(left_x * S, top_y * S), (apex_x * S, 0.5 * S), (left_x * S, bottom_y * S)]


def rounded_mask(points: list[tuple[float, float]], radius: float) -> Image.Image:
    """Masque du polygone à coins ARRONDIS.

    Le flou puis le seuillage arrondissent les angles d'un rayon égal au flou :
    ImageDraw ne sait pas tracer un polygone à coins ronds, et des pointes
    vives jureraient avec une matière de verre.
    """
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius))
    return mask.point(lambda v: 255 if v > 140 else 0)


def glass_fill(mask: Image.Image,
               top: tuple[int, int, int, int],
               bottom: tuple[int, int, int, int]) -> Image.Image:
    """Corps de verre : dégradé vertical translucide, découpé par le masque."""
    ys = (np.mgrid[0:S, 0:S][0].astype(np.float32) / (S - 1))[..., None]
    a = np.array(top, dtype=np.float32)
    b = np.array(bottom, dtype=np.float32)
    body = Image.fromarray((a + (b - a) * ys).astype(np.uint8), "RGBA")
    alpha = np.array(body)[..., 3] * (np.array(mask, dtype=np.float32) / 255)
    out = np.array(body)
    out[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def rim_light(mask: Image.Image, dx: int, dy: int, thickness: int,
              colour: tuple[int, int, int], strength: float) -> Image.Image:
    """Liseré spéculaire : la différence entre le masque et le masque décalé.

    C'est ce qui fait lire « verre » plutôt que « aplat coloré » — une arête
    éclairée d'un seul côté, celui de la lumière.
    """
    shifted = mask.transform(mask.size, Image.AFFINE, (1, 0, dx, 0, 1, dy),
                             resample=Image.BILINEAR, fillcolor=0)
    edge = np.clip(np.array(mask, dtype=np.int16) - np.array(shifted, dtype=np.int16), 0, 255)
    edge_img = Image.fromarray(edge.astype(np.uint8), "L")
    edge_img = edge_img.filter(ImageFilter.GaussianBlur(thickness))
    alpha = (np.array(edge_img, dtype=np.float32) * strength).clip(0, 255).astype(np.uint8)
    rgb = np.empty((S, S, 3), dtype=np.uint8)
    rgb[..., 0], rgb[..., 1], rgb[..., 2] = colour
    return Image.fromarray(np.dstack([rgb, alpha]), "RGBA")


def drop_shadow(mask: Image.Image, dy: int, blur: int, strength: float) -> Image.Image:
    """Ombre portée : détache la lame du fond, sans quoi tout reste à plat."""
    shifted = mask.transform(mask.size, Image.AFFINE, (1, 0, 0, 0, 1, -dy),
                             resample=Image.BILINEAR, fillcolor=0)
    shadow = shifted.filter(ImageFilter.GaussianBlur(blur))
    alpha = (np.array(shadow, dtype=np.float32) * strength).clip(0, 255).astype(np.uint8)
    rgb = np.zeros((S, S, 3), dtype=np.uint8)
    return Image.fromarray(np.dstack([rgb, alpha]), "RGBA")


def build() -> Image.Image:
    # 1. Fond : ardoise profonde virant au bleu nuit, jamais noir — une icône
    #    noire disparaît sur un fond d'écran sombre.
    canvas = linear_gradient((34, 38, 56), (10, 11, 18)).convert("RGBA")

    # 2. Source lumineuse chaude, en haut à gauche : elle justifie tous les
    #    reflets posés ensuite (une lumière unique, cohérente).
    canvas.alpha_composite(radial_glow((0.24, 0.16), 0.90, (255, 220, 150), 0.30))
    # Contre-jour accent en bas à droite : donne sa couleur au verre.
    canvas.alpha_composite(radial_glow((0.88, 0.90), 0.70, ACCENT, 0.26))

    # 3. Traînée : deux lames fantômes, de plus en plus effacées vers la
    #    gauche — la même image saisie quelques centièmes plus tôt.
    #    Elles s'amenuisent en largeur ET en hauteur : une traînée qui garderait
    #    la même taille lirait comme trois objets empilés, pas comme un mouvement.
    ghosts = [
        # (décalage, largeur, hauteur, opacité du corps, opacité du liseré)
        (0.270, 0.30, 0.40, 34, 0.42),
        (0.145, 0.36, 0.51, 62, 0.72),
    ]
    for offset, width, height, body_alpha, rim in ghosts:
        mask = rounded_mask(blade_points(offset, width, height), 26 * SCALE)
        canvas.alpha_composite(glass_fill(mask,
                                          (255, 252, 240, body_alpha),
                                          (255, 206, 90, int(body_alpha * 0.85))))
        canvas.alpha_composite(rim_light(mask, -7 * SCALE, -7 * SCALE,
                                         2 * SCALE, (255, 240, 205), rim))

    # 4. Lame principale, pleine matière.
    main = rounded_mask(blade_points(0.0, 0.42, 0.62), 30 * SCALE)
    canvas.alpha_composite(drop_shadow(main, 14 * SCALE, 26 * SCALE, 0.55))
    canvas.alpha_composite(glass_fill(main, (255, 249, 232, 235), (255, 196, 0, 220)))
    # Reflet de surface : un voile clair sur la moitié haute seulement.
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse(
        [0.18 * S, -0.34 * S, 0.95 * S, 0.50 * S], fill=120
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(20 * SCALE))
    sheen_alpha = (np.array(sheen, dtype=np.float32)
                   * (np.array(main, dtype=np.float32) / 255)).astype(np.uint8)
    canvas.alpha_composite(Image.fromarray(
        np.dstack([np.full((S, S, 3), 255, dtype=np.uint8), sheen_alpha]), "RGBA"))
    # Arête éclairée en haut à gauche, ombre interne en bas à droite.
    canvas.alpha_composite(rim_light(main, -7 * SCALE, -7 * SCALE,
                                     3 * SCALE, (255, 255, 255), 0.95))
    canvas.alpha_composite(rim_light(main, 7 * SCALE, 7 * SCALE,
                                     4 * SCALE, (120, 70, 0), 0.45))

    return canvas.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    icon = build()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT, "PNG")
    print(f"écrit : {OUTPUT} ({icon.width}x{icon.height})")


if __name__ == "__main__":
    main()
