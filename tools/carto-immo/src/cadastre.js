import fs from 'node:fs';
import path from 'node:path';
import { gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { log } from './log.js';

/**
 * Plan cadastral d'une commune : contour exact des parcelles et emprise des
 * bâtiments, depuis le cadastre Etalab.
 *
 * C'est ce qui permet de montrer *le terrain* d'un bien et non un simple point,
 * et de lire ce terrain dans son voisinage plutôt que sur un aplat.
 *
 * Les fichiers sont figés et volumineux : ils sont mis en cache sur disque.
 */

const BASE = 'https://cadastre.data.gouv.fr/data/etalab-cadastre/latest/geojson/communes';

async function telecharger(url, essais = 5) {
  let derniere;
  for (let i = 0; i < essais; i++) {
    try {
      const r = await fetch(url);
      if (r.ok) return Buffer.from(await r.arrayBuffer());
      derniere = new Error(`${r.status}`);
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) {
      derniere = e;
    }
    // Ces serveurs répondent 503 sous rafale : on patiente franchement.
    await new Promise((r) => setTimeout(r, 2500 * 2 ** i));
  }
  throw derniere;
}

export async function enCache(url, dossier, { sansCache = false } = {}) {
  const f = path.join(dossier, createHash('sha1').update(url).digest('hex').slice(0, 16));
  if (!sansCache && fs.existsSync(f)) return fs.readFileSync(f);
  const buf = await telecharger(url);
  fs.mkdirSync(dossier, { recursive: true });
  fs.writeFileSync(f, buf);
  return buf;
}

// ── Géométrie ─────────────────────────────────────────────────────────────

// Six décimales : environ 10 cm. Assez fin pour que l'arrondi ne déplace jamais
// une limite de parcelle, assez grossier pour alléger la page.
const PRECISION = 6;

const arrondir = (polygone) =>
  polygone.map((anneau) => anneau.map(([x, y]) => [Number(x.toFixed(PRECISION)), Number(y.toFixed(PRECISION))]));

/**
 * Polygones d'une géométrie GeoJSON, anneaux intérieurs compris.
 *
 * Les trous comptent : une parcelle en U ne contient pas ce qu'elle enserre,
 * et Leaflet sait les dessiner si on les lui donne.
 *
 * @returns {number[][][][]} liste de polygones, chacun [extérieur, ...trous]
 */
export function polygones(geom) {
  if (!geom) return [];
  if (geom.type === 'Polygon') return [geom.coordinates];
  if (geom.type === 'MultiPolygon') return geom.coordinates;
  return [];
}

/** Point dans anneau, par lancer de rayon. Anneau en [lon, lat]. */
export function dansAnneau(lon, lat, anneau) {
  let dedans = false;
  for (let i = 0, j = anneau.length - 1; i < anneau.length; j = i++) {
    const [xi, yi] = anneau[i];
    const [xj, yj] = anneau[j];
    if ((yi > lat) !== (yj > lat) && lon < ((xj - xi) * (lat - yi)) / (yj - yi) + xi) dedans = !dedans;
  }
  return dedans;
}

/** Point dans polygone : dans l'extérieur, hors de tout trou. */
export function dansPolygone(lon, lat, polygone) {
  if (!polygone.length || !dansAnneau(lon, lat, polygone[0])) return false;
  for (let i = 1; i < polygone.length; i++) if (dansAnneau(lon, lat, polygone[i])) return false;
  return true;
}

const dansGeometrie = (lon, lat, polys) => polys.some((p) => dansPolygone(lon, lat, p));

/** Aire signée d'un anneau en m², par la formule du lacet en projection locale. */
function aireSignee(anneau) {
  if (anneau.length < 4) return 0;
  const lat0 = anneau.reduce((a, p) => a + p[1], 0) / anneau.length;
  const kx = 111320 * Math.cos((lat0 * Math.PI) / 180);
  const ky = 110540;
  let s2 = 0;
  for (let i = 0, j = anneau.length - 1; i < anneau.length; j = i++) {
    s2 += anneau[j][0] * kx * (anneau[i][1] * ky) - anneau[i][0] * kx * (anneau[j][1] * ky);
  }
  return s2 / 2;
}

/** Aire d'une géométrie en m², trous déduits. */
export function aire(polys) {
  let total = 0;
  for (const p of polys) {
    total += Math.abs(aireSignee(p[0]));
    for (let i = 1; i < p.length; i++) total -= Math.abs(aireSignee(p[i]));
  }
  return Math.max(0, total);
}

/**
 * Centroïde pondéré par l'aire.
 *
 * La moyenne des sommets se déplace vers les portions les plus découpées du
 * contour : sur une parcelle allongée, elle sort du terrain. Le centroïde
 * géométrique, lui, reste représentatif.
 */
export function centroide(polys) {
  // Le calcul se fait en unités brutes : mélanger des moments en degrés à une
  // aire en mètres annule le résultat.
  let sx = 0, sy = 0, poidsTotal = 0;
  for (const p of polys) {
    const anneau = p[0];
    let a2 = 0, cx = 0, cy = 0;
    for (let i = 0, j = anneau.length - 1; i < anneau.length; j = i++) {
      const f = anneau[j][0] * anneau[i][1] - anneau[i][0] * anneau[j][1];
      a2 += f;
      cx += (anneau[j][0] + anneau[i][0]) * f;
      cy += (anneau[j][1] + anneau[i][1]) * f;
    }
    if (!a2) continue;
    const poids = Math.abs(a2 / 2);
    sx += (cx / (3 * a2)) * poids;
    sy += (cy / (3 * a2)) * poids;
    poidsTotal += poids;
  }
  if (poidsTotal) return [sx / poidsTotal, sy / poidsTotal];

  // Contour dégénéré : la moyenne des sommets reste préférable à rien.
  const tous = polys.flat(2);
  if (!tous.length) return [0, 0];
  return [
    tous.reduce((s, p) => s + p[0], 0) / tous.length,
    tous.reduce((s, p) => s + p[1], 0) / tous.length,
  ];
}

/** Distance approchée en mètres, suffisante pour un filtre de voisinage. */
export function metres(lat1, lon1, lat2, lon2) {
  const k = Math.cos((lat1 * Math.PI) / 180);
  return Math.hypot((lat2 - lat1) * 111320, (lon2 - lon1) * 111320 * k);
}

/** Distance d'un point au bord d'un polygone, en mètres. */
export function distanceAuBord(lat, lon, polys) {
  const k = Math.cos((lat * Math.PI) / 180);
  let min = Infinity;
  for (const p of polys) {
    for (const anneau of p) {
      for (let i = 0, j = anneau.length - 1; i < anneau.length; j = i++) {
        const ax = (anneau[j][0] - lon) * 111320 * k, ay = (anneau[j][1] - lat) * 111320;
        const bx = (anneau[i][0] - lon) * 111320 * k, by = (anneau[i][1] - lat) * 111320;
        const dx = bx - ax, dy = by - ay;
        const n2 = dx * dx + dy * dy;
        const t = n2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / n2)) : 0;
        min = Math.min(min, Math.hypot(ax + t * dx, ay + t * dy));
      }
    }
  }
  return min;
}

// ── Chargement ────────────────────────────────────────────────────────────

/**
 * Charge parcelles et bâtiments d'une commune.
 *
 * @param {string} insee code commune, les deux premiers chiffres donnant le département
 */
export async function chargerCommune(insee, cacheDir, opts = {}) {
  const dep = insee.slice(0, 2);
  const lire = async (quoi) => {
    const url = `${BASE}/${dep}/${insee}/cadastre-${insee}-${quoi}.json.gz`;
    try {
      const buf = await enCache(url, cacheDir, opts);
      return JSON.parse(gunzipSync(buf).toString('utf8')).features ?? [];
    } catch (e) {
      log.warn(`  cadastre ${quoi} ${insee} indisponible (${e.message})`);
      return [];
    }
  };

  // En série : deux téléchargements simultanés suffisent à déclencher un 503.
  const fParcelles = await lire('parcelles');
  const fBatiments = await lire('batiments');

  const parcelles = new Map();
  const listeParcelles = [];
  const listeBatiments = [];

  for (const f of fParcelles) {
    const polys = arrondir2(polygones(f.geometry));
    if (!polys.length) continue;
    const entree = {
      id: f.properties.id,
      polys,
      centre: centroide(polys),
      contenance: f.properties.contenance ?? Math.round(aire(polys)),
    };
    parcelles.set(entree.id, entree);
    listeParcelles.push(entree);
  }
  for (const f of fBatiments) {
    const polys = arrondir2(polygones(f.geometry));
    if (!polys.length) continue;
    listeBatiments.push({ polys, centre: centroide(polys) });
  }

  /**
   * Parcelle d'un bien situé en (lat, lon).
   *
   * Le registre des DPE donne une adresse, que la BAN place au bord de la voie
   * ou sur le bâti — rarement au centre du terrain. Prendre la parcelle sous le
   * point désigne donc souvent la rue ou le voisin.
   *
   * On passe par le bâtiment : c'est la partie la plus sûrement identifiée
   * d'une adresse, et c'est lui qui désigne la parcelle. Le terrain annoncé
   * sert de contrôle final.
   */
  function localiserParcelle(lat, lon, { terrain = null } = {}) {
    // 1. Le bâtiment sous le point, sinon le plus proche à portée d'une adresse.
    let batiment = listeBatiments.find((b) => dansGeometrie(lon, lat, b.polys)) ?? null;
    const dansLeBati = !!batiment;
    if (!batiment) {
      let meilleur = null;
      for (const b of listeBatiments) {
        const d = distanceAuBord(lat, lon, b.polys);
        if (d <= 25 && (!meilleur || d < meilleur.d)) meilleur = { b, d };
      }
      batiment = meilleur?.b ?? null;
    }

    // 2. La parcelle qui porte ce bâtiment, à défaut celle sous le point.
    let candidates = [];
    let motif = null;
    if (batiment) {
      candidates = listeParcelles.filter((g) => dansGeometrie(batiment.centre[0], batiment.centre[1], g.polys));
      if (candidates.length) motif = 'parcelle du bâtiment';
    }
    if (!candidates.length) {
      candidates = listeParcelles.filter((g) => dansGeometrie(lon, lat, g.polys));
      if (candidates.length) motif = 'parcelle sous l’adresse';
    }

    let parProximite = false;
    if (!candidates.length) {
      // 3. Dernier recours : la parcelle dont le bord est le plus proche.
      let meilleur = null;
      for (const g of listeParcelles) {
        if (metres(lat, lon, g.centre[1], g.centre[0]) > 300) continue;
        const d = distanceAuBord(lat, lon, g.polys);
        if (d <= 40 && (!meilleur || d < meilleur.d)) meilleur = { g, d };
      }
      if (!meilleur) return null;
      candidates = [meilleur.g];
      parProximite = true;
      motif = 'parcelle la plus proche';
    }

    // Un point sur une limite peut tomber dans deux parcelles : la plus petite
    // est la plus spécifique, donc la plus probable pour une habitation.
    candidates.sort((a, b) => a.contenance - b.contenance);
    const choisie = candidates[0];

    // Le bâtiment retenu ne vaut d'être affiché que s'il est bien sur la parcelle.
    const batimentSurParcelle =
      batiment && dansGeometrie(batiment.centre[0], batiment.centre[1], choisie.polys) ? batiment : null;

    // 3. Contrôle par le terrain annoncé. Une parcelle bien plus grande que lui
    //    trahit un point tombé sur une pièce agricole. L'inverse est banal : à
    //    la campagne une propriété s'étend sur plusieurs parcelles, dont celle
    //    du bâti est la plus petite.
    let ecartTerrainPct = null;
    let terrainIncoherent = false;
    let plusieursParcelles = false;
    if (terrain && choisie.contenance) {
      ecartTerrainPct = Math.round(((choisie.contenance - terrain) / terrain) * 100);
      terrainIncoherent = choisie.contenance > terrain * 4;
      plusieursParcelles = choisie.contenance < terrain / 2;
    }

    let confiance;
    if (parProximite) confiance = 'faible';
    else if (dansLeBati && batimentSurParcelle) confiance = 'élevée';
    else if (batimentSurParcelle) confiance = 'bonne';
    else confiance = 'moyenne';
    if (terrainIncoherent && confiance !== 'faible') confiance = 'moyenne';

    return {
      id: choisie.id,
      polys: choisie.polys,
      contenance: choisie.contenance,
      batiment: batimentSurParcelle?.polys ?? null,
      confiance,
      motif,
      ecartTerrainPct,
      terrainIncoherent,
      plusieursParcelles,
      candidats: candidates.length,
    };
  }

  return {
    parcelles,
    localiserParcelle,
    autour: (lat, lon, rayon) => {
      const proche = (g) => metres(lat, lon, g.centre[1], g.centre[0]) <= rayon;
      return [
        ...listeParcelles.filter(proche).map((g) => ({ polys: g.polys, centre: g.centre, batiment: false })),
        ...listeBatiments.filter(proche).map((g) => ({ polys: g.polys, centre: g.centre, batiment: true })),
      ];
    },
  };
}

function arrondir2(polys) {
  return polys.map(arrondir);
}

/**
 * Complète des fiches avec le contour de leur parcelle, et rassemble le
 * voisinage cadastral à dessiner autour d'elles.
 *
 * Les communes sont chargées une seule fois chacune, quel que soit le nombre
 * de biens qu'elles portent.
 */
export async function enrichirParcelles(fiches, cacheDir, { rayon = 200, sansCache = false } = {}) {
  const parCommune = new Map();
  for (const f of fiches) {
    if (!f.codeInsee) continue;
    // Une fiche déjà tracée n'est pas recalculée : le pipeline qui l'a produite
    // en savait davantage que nous ici.
    if (f.parcelleGeom) continue;
    if (!f.parcelle && (f.latitude == null || f.longitude == null)) continue;
    if (!parCommune.has(f.codeInsee)) parCommune.set(f.codeInsee, []);
    parCommune.get(f.codeInsee).push(f);
  }

  const contexte = { parcelles: [], batiments: [] };
  // Des biens voisins partagent leur voisinage : sans déduplication, le même
  // pâté de maisons serait embarqué autant de fois qu'il y a de biens autour.
  const dejaVues = new Set();
  let trouvees = 0;

  for (const [insee, lot] of parCommune) {
    const commune = await chargerCommune(insee, cacheDir, { sansCache });
    if (!commune.parcelles.size) continue;

    for (const f of lot) {
      let p = f.parcelle ? commune.parcelles.get(f.parcelle) : null;
      if (p) {
        f.parcelleConfiance = 'certaine';
        f.parcelleMotif = 'identifiant cadastral fourni';
      } else if (f.latitude != null && f.longitude != null) {
        const trouvee = commune.localiserParcelle(f.latitude, f.longitude, { terrain: f.terrain });
        if (trouvee) {
          p = trouvee;
          f.parcelle = trouvee.id;
          f.parcelleConfiance = trouvee.confiance;
          f.parcelleMotif = trouvee.motif;
          f.batimentGeom = trouvee.batiment;
          f.ecartTerrainPct = trouvee.ecartTerrainPct;
          f.plusieursParcelles = trouvee.plusieursParcelles;
        }
      }
      if (!p) continue;
      f.parcelleGeom = p.polys;
      f.contenance = p.contenance;
      trouvees++;

      if (f.latitude == null || f.longitude == null) continue;
      for (const g of commune.autour(f.latitude, f.longitude, rayon)) {
        const cle = (g.batiment ? 'b' : 'p') + g.centre.join(',');
        if (dejaVues.has(cle)) continue;
        dejaVues.add(cle);
        (g.batiment ? contexte.batiments : contexte.parcelles).push(g.polys);
      }
    }
  }

  return { trouvees, contexte };
}
