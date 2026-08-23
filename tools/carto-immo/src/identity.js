/**
 * Reconnaissance d'un même bien d'une annonce à l'autre.
 *
 * Sur leboncoin, un vendeur qui ne vend pas supprime son annonce et la remet
 * en ligne : nouvel identifiant, même maison. Sans ce module, chaque remise en
 * ligne repartirait pour une analyse et serait annoncée comme une nouveauté.
 *
 * Deux niveaux :
 *   — avant analyse, un rapprochement sur les caractéristiques visibles depuis
 *     la page de résultats. C'est ce qui économise les requêtes ;
 *   — après analyse, un rapprochement sur la parcelle cadastrale et les
 *     coordonnées, qui fait autorité.
 *
 * Le doute profite toujours à la nouveauté : rater un doublon coûte une
 * analyse, fusionner à tort masque une vraie annonce.
 */

// Volontairement haut : un doublon manqué coûte une analyse, une fusion à tort
// masque une vraie annonce. Le rattrapage se fait après analyse, sur la parcelle.
const SEUIL_RAPPROCHEMENT = 85;

// ── Outils ────────────────────────────────────────────────────────────────

const sansAccent = (s) =>
  String(s ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase();

const MOTS_VIDES = new Set([
  'a','au','aux','avec','ce','ces','dans','de','des','du','en','et','la','le',
  'les','ou','par','pour','sur','un','une','vend','vente','maison','appartement',
  'terrain','m2','pieces','piece','t1','t2','t3','t4','t5','t6','t7',
]);

/** Jetons signifiants d'un titre d'annonce. */
export function jetons(titre) {
  return new Set(
    sansAccent(titre)
      .replace(/[^a-z0-9]+/g, ' ')
      .split(' ')
      .filter((t) => t.length > 2 && !MOTS_VIDES.has(t))
  );
}

/** Indice de Dice entre deux ensembles de jetons : 0 (rien) à 1 (identiques). */
export function similitudeTitre(a, b) {
  const ja = jetons(a);
  const jb = jetons(b);
  if (!ja.size || !jb.size) return 0;
  let communs = 0;
  for (const t of ja) if (jb.has(t)) communs++;
  return (2 * communs) / (ja.size + jb.size);
}

/** Distance en mètres entre deux points (haversine). */
export function distanceM(lat1, lon1, lat2, lon2) {
  if ([lat1, lon1, lat2, lon2].some((v) => v == null || !Number.isFinite(v))) return null;
  const R = 6371000;
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

const proche = (a, b, tolerance) =>
  a == null || b == null ? null : Math.abs(a - b) <= tolerance;

const normVille = (v) => sansAccent(v).replace(/[^a-z]/g, '');

// ── Empreinte ─────────────────────────────────────────────────────────────

/**
 * Empreinte grossière d'un bien, utilisée comme clé de repli quand aucune
 * parcelle n'est connue. Volontairement tolérante : la surface est arrondie.
 */
export function empreinte(bien) {
  return [
    normVille(bien.ville) || normVille(bien.codePostal) || '?',
    sansAccent(bien.typeBien) || '?',
    bien.surface != null ? Math.round(bien.surface / 5) * 5 : '?',
    bien.pieces ?? '?',
  ].join('|');
}

/** Clé d'identité d'un bien, de la plus fiable à la plus approximative. */
export function cleBien(bien) {
  if (bien.parcelle) return `parcelle:${bien.parcelle}`;
  if (bien.banId) return `ban:${bien.banId}`;
  if (bien.latitude != null && bien.longitude != null && bien.localisationPrecise) {
    return `geo:${bien.latitude.toFixed(5)},${bien.longitude.toFixed(5)}`;
  }
  return `empreinte:${empreinte(bien)}`;
}

// ── Rapprochement avant analyse ───────────────────────────────────────────

/**
 * Note de ressemblance entre une annonce fraîchement collectée et un bien déjà
 * connu. Renvoie `null` dès qu'une caractéristique se contredit franchement.
 *
 * @returns {{note: number, motifs: string[]}|null}
 */
export function noterRapprochement(annonce, bien) {
  const motifs = [];

  // L'URL déjà rattachée au bien, ou repérée par lacquereur comme étant la même
  // offre diffusée ailleurs : identité certaine.
  const urlsConnues = [
    ...(bien.annonces ?? []).map((a) => a.url),
    ...(bien.autresAnnonces ?? []),
  ];
  if (urlsConnues.some((u) => u && u.split('?')[0] === annonce.url.split('?')[0])) {
    return { note: 100, motifs: ['même URL'] };
  }

  // On compare l'annonce à ce que leboncoin disait du bien, pas aux valeurs
  // réécrites par lacquereur : sinon on confronterait deux sources différentes.
  const vu = bien.lbc ?? {};
  const ville = vu.ville ?? bien.ville;
  const codePostal = vu.codePostal ?? bien.codePostal;
  const surface = vu.surface ?? bien.surface;
  const pieces = vu.pieces ?? bien.pieces;
  const terrain = vu.terrain ?? bien.terrain;
  const vendeur = vu.vendeur ?? bien.vendeur;
  // Prix et titre évoluent d'une parution à l'autre : on prend les plus récents.
  const prix = bien.prix ?? vu.prix;
  const titres = [bien.titre, vu.titre, ...(bien.annonces ?? []).map((a) => a.titre)];

  // Deux communes différentes : deux biens différents.
  const villeA = normVille(annonce.ville);
  const villeB = normVille(ville);
  if (villeA && villeB && villeA !== villeB) return null;
  if (!villeA || !villeB) {
    if (!annonce.codePostal || !codePostal || String(annonce.codePostal) !== String(codePostal)) {
      return null;
    }
  }

  // Sans surface des deux côtés, il n'y a pas matière à conclure.
  if (annonce.surface == null || surface == null) return null;
  if (!proche(annonce.surface, surface, Math.max(2, surface * 0.02))) return null;

  // Un nombre de pièces qui se contredit désigne un autre bien.
  if (annonce.pieces != null && pieces != null && annonce.pieces !== pieces) return null;

  let note = 10 + 40; // même commune, même surface
  motifs.push(`${surface} m²`);

  if (annonce.pieces != null && pieces != null) {
    note += 15;
    motifs.push(`${pieces} pièces`);
  }

  // Le terrain discrimine bien deux maisons de même taille dans un même village.
  const terrainOk = proche(annonce.terrain, terrain, Math.max(50, (terrain ?? 0) * 0.05));
  if (terrainOk === true) { note += 20; motifs.push('même terrain'); }
  else if (terrainOk === false) { note -= 15; }

  // Un vendeur identique renforce ; un vendeur différent ne pénalise pas
  // (un même bien peut être confié à plusieurs agences).
  if (annonce.vendeur && vendeur && annonce.vendeur === vendeur) {
    note += 15;
    motifs.push('même vendeur');
  }

  const sim = Math.max(...titres.map((t) => similitudeTitre(annonce.titre, t)));
  if (sim >= 0.65) { note += 18; motifs.push('titre quasi identique'); }
  else if (sim >= 0.45) { note += 10; motifs.push('titre proche'); }

  if (annonce.prix != null && prix != null) {
    const ecart = Math.abs(annonce.prix - prix) / prix;
    if (ecart === 0) { note += 15; motifs.push('prix identique'); }
    else if (ecart <= 0.05) { note += 10; motifs.push('prix voisin'); }
    else if (ecart <= 0.15) { note += 5; }
  }

  // Les coordonnées de leboncoin valent le centre de la commune pour la plupart
  // des annonces : elles ne comptent que face à une position déjà géolocalisée
  // précisément, et à très courte distance.
  if (bien.localisationPrecise) {
    const d = distanceM(annonce.lbcLat, annonce.lbcLon, bien.latitude, bien.longitude);
    if (d != null && d <= 60) { note += 15; motifs.push(`${Math.round(d)} m`); }
  }

  return { note, motifs };
}

/**
 * Cherche parmi les biens connus celui que cette annonce redécrit.
 * @returns {{bien: object, note: number, motifs: string[]}|null}
 */
export function rapprocher(annonce, biens, { seuil = SEUIL_RAPPROCHEMENT } = {}) {
  let meilleur = null;
  for (const bien of biens) {
    const r = noterRapprochement(annonce, bien);
    if (!r || r.note < seuil) continue;
    if (!meilleur || r.note > meilleur.note) meilleur = { bien, ...r };
  }
  return meilleur;
}

// ── Rapprochement après analyse ───────────────────────────────────────────

/**
 * Rapprochement faisant autorité, une fois lacquereur passé : la parcelle
 * cadastrale identifie un bien sans ambiguïté.
 */
export function rapprocherApresAnalyse(fiche, biens) {
  // Les motifs ne se valent pas : la parcelle cadastrale identifie un bien,
  // la proximité seulement le suggère. On retient donc le meilleur, pas le
  // premier venu.
  const NIVEAUX = [
    {
      motif: 'même parcelle cadastrale',
      force: 4,
      test: (b) => fiche.parcelle && b.parcelle && fiche.parcelle === b.parcelle,
    },
    {
      motif: 'même adresse',
      force: 3,
      test: (b) => fiche.banId && b.banId && fiche.banId === b.banId,
    },
    {
      motif: 'annonce déjà diffusée pour ce bien',
      force: 2,
      test: (b) =>
        (b.autresAnnonces ?? []).some(
          (u) => u && u.split('?')[0] === fiche.urlAnnonce.split('?')[0]
        ),
    },
    {
      motif: 'même emplacement et même surface',
      force: 1,
      test: (b) => {
        if (!fiche.localisationPrecise || !b.localisationPrecise) return false;
        const d = distanceM(fiche.latitude, fiche.longitude, b.latitude, b.longitude);
        return d != null && d <= 25 && proche(fiche.surface, b.surface, 3) === true;
      },
    },
  ];

  let meilleur = null;
  for (const bien of biens) {
    if (bien.cle === fiche.cle) continue;
    for (const niveau of NIVEAUX) {
      if (!niveau.test(bien)) continue;
      if (!meilleur || niveau.force > meilleur.force) meilleur = { bien, motif: niveau.motif, force: niveau.force };
      break; // le premier niveau satisfait est le plus fort pour ce bien
    }
    if (meilleur?.force === NIVEAUX[0].force) break; // rien ne bat la parcelle
  }
  return meilleur ? { bien: meilleur.bien, motif: meilleur.motif } : null;
}
