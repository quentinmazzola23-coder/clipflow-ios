import { enCache } from './cadastre.js';
import { log, sleep } from './log.js';

/**
 * Tuiles d'orthophotographie, embarquées dans la page.
 *
 * Une carte de prospection se lit sur photo aérienne : on voit la maison, la
 * cour, les dépendances, l'accès. Mais une page autonome ne peut rien
 * télécharger — on embarque donc les tuiles utiles autour de chaque bien.
 *
 * Source : orthophotographies de l'IGN, service public de la Géoplateforme.
 */

const WMTS = 'https://data.geopf.fr/wmts';
export const COUCHE_ORTHO = 'ORTHOIMAGERY.ORTHOPHOTOS';

export const urlTuile = (z, x, y, couche = COUCHE_ORTHO) =>
  `${WMTS}?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=${couche}` +
  `&STYLE=normal&TILEMATRIXSET=PM&FORMAT=image/jpeg&TILEMATRIX=${z}&TILEROW=${y}&TILECOL=${x}`;

/** Coordonnées de tuile (schéma « slippy map ») pour un point. */
export function tuileDe(lat, lon, z) {
  const n = 2 ** z;
  const x = Math.floor(((lon + 180) / 360) * n);
  const latRad = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * n);
  return { x, y };
}

/**
 * Tuiles couvrant le voisinage immédiat de chaque point.
 *
 * @param {{latitude:number, longitude:number}[]} points
 * @param {object} opts
 * @param {Record<number, number>} [opts.zooms] zoom → demi-largeur en tuiles
 * @returns {Promise<{tuiles: Record<string,string>, octets: number, zoomMax: number}>}
 */
export async function tuilesAutour(points, { zooms = { 16: 0, 17: 1, 18: 1 }, cacheDir, delaiMs = 60 } = {}) {
  // Une même tuile sert souvent plusieurs biens d'un même bourg.
  const voulues = new Set();
  for (const p of points) {
    if (!Number.isFinite(p.latitude) || !Number.isFinite(p.longitude)) continue;
    for (const [z, marge] of Object.entries(zooms)) {
      const { x, y } = tuileDe(p.latitude, p.longitude, Number(z));
      for (let dx = -marge; dx <= marge; dx++) {
        for (let dy = -marge; dy <= marge; dy++) voulues.add(`${z}/${x + dx}/${y + dy}`);
      }
    }
  }

  const tuiles = {};
  let octets = 0;
  let echecs = 0;
  let n = 0;

  for (const cle of voulues) {
    const [z, x, y] = cle.split('/').map(Number);
    try {
      const buf = await enCache(urlTuile(z, x, y), cacheDir);
      // Une dalle hors emprise revient en vignette quasi vide : inutile à embarquer.
      if (buf.length < 700) continue;
      tuiles[cle] = `data:image/jpeg;base64,${buf.toString('base64')}`;
      octets += buf.length;
    } catch {
      echecs++;
    }
    if (++n % 40 === 0) log.info(`  ${n}/${voulues.size} tuiles`);
    await sleep(delaiMs, 0);
  }

  if (echecs) log.warn(`  ${echecs} tuiles indisponibles`);
  return {
    tuiles,
    octets,
    zoomMax: Math.max(...Object.keys(zooms).map(Number)),
  };
}
