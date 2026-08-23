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

const arrondir = (anneaux) =>
  anneaux.map((r) => r.map(([x, y]) => [Number(x.toFixed(5)), Number(y.toFixed(5))]));

/** Anneaux extérieurs d'une géométrie, que ce soit un Polygon ou un MultiPolygon. */
export function anneaux(geom) {
  if (!geom) return [];
  return geom.type === 'Polygon' ? [geom.coordinates[0]] : geom.coordinates.map((p) => p[0]);
}

const centre = (r) => [
  r.reduce((a, p) => a + p[0], 0) / r.length,
  r.reduce((a, p) => a + p[1], 0) / r.length,
];

/** Distance approchée en mètres, suffisante pour un filtre de voisinage. */
export function metres(lat1, lon1, lat2, lon2) {
  const k = Math.cos((lat1 * Math.PI) / 180);
  return Math.hypot((lat2 - lat1) * 111320, (lon2 - lon1) * 111320 * k);
}

/**
 * Charge parcelles et bâtiments d'une commune.
 *
 * @param {string} insee code commune, les deux premiers chiffres donnant le département
 * @returns {Promise<{parcelles: Map, autour: Function}>}
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
  const geometries = [];
  for (const f of fParcelles) {
    const a = anneaux(f.geometry);
    if (!a.length) continue;
    const arr = arrondir(a);
    parcelles.set(f.properties.id, { anneaux: arr, contenance: f.properties.contenance ?? null });
    geometries.push({ anneaux: arr, centre: centre(a[0]), batiment: false });
  }
  for (const f of fBatiments) {
    const a = anneaux(f.geometry);
    if (!a.length) continue;
    geometries.push({ anneaux: arrondir(a), centre: centre(a[0]), batiment: true });
  }

  return {
    parcelles,
    autour: (lat, lon, rayon) =>
      geometries.filter((g) => metres(lat, lon, g.centre[1], g.centre[0]) <= rayon),
  };
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
    if (!f.codeInsee || !f.parcelle) continue;
    if (!parCommune.has(f.codeInsee)) parCommune.set(f.codeInsee, []);
    parCommune.get(f.codeInsee).push(f);
  }

  const contexte = { parcelles: [], batiments: [] };
  let trouvees = 0;

  for (const [insee, lot] of parCommune) {
    const commune = await chargerCommune(insee, cacheDir, { sansCache });
    if (!commune.parcelles.size) continue;

    for (const f of lot) {
      const p = commune.parcelles.get(f.parcelle);
      if (!p) continue;
      f.parcelleGeom = p.anneaux;
      f.contenance = p.contenance;
      trouvees++;
      if (f.latitude == null || f.longitude == null) continue;
      for (const g of commune.autour(f.latitude, f.longitude, rayon)) {
        (g.batiment ? contexte.batiments : contexte.parcelles).push(g.anneaux);
      }
    }
  }

  return { trouvees, contexte };
}
