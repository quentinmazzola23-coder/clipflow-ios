import { enCache } from './cadastre.js';

/**
 * Contours administratifs allégés, pour donner un fond à la carte hors ligne :
 * les départements à l'échelle du pays, les communes à celle du secteur.
 */

const DEPARTEMENTS =
  'https://raw.githubusercontent.com/gregoiredavid/france-geojson/master/departements-version-simplifiee.geojson';

/** Simplification Douglas-Peucker d'une ligne de coordonnées. */
export function simplifier(pts, eps) {
  if (pts.length < 3) return pts;
  const [x1, y1] = pts[0];
  const [x2, y2] = pts[pts.length - 1];
  const dx = x2 - x1, dy = y2 - y1, n2 = dx * dx + dy * dy;
  let imax = 0, dmax = 0;
  for (let i = 1; i < pts.length - 1; i++) {
    const [x, y] = pts[i];
    let d;
    if (n2 === 0) d = Math.hypot(x - x1, y - y1);
    else {
      const t = Math.max(0, Math.min(1, ((x - x1) * dx + (y - y1) * dy) / n2));
      d = Math.hypot(x - (x1 + t * dx), y - (y1 + t * dy));
    }
    if (d > dmax) { imax = i; dmax = d; }
  }
  if (dmax <= eps) return [pts[0], pts[pts.length - 1]];
  return simplifier(pts.slice(0, imax + 1), eps).slice(0, -1).concat(simplifier(pts.slice(imax), eps));
}

function alleger(geom, eps, decimales) {
  const anneaux = geom.type === 'Polygon' ? [geom.coordinates[0]] : geom.coordinates.map((p) => p[0]);
  const rings = [];
  for (const r of anneaux) {
    const s = simplifier(r.map(([x, y]) => [Number(x.toFixed(decimales)), Number(y.toFixed(decimales))]), eps);
    if (String(s[0]) !== String(s[s.length - 1])) s.push(s[0]);
    if (s.length >= 4) rings.push(s);
  }
  return rings;
}

/** Départements de métropole, ~1 km de tolérance : de quoi situer, pas plus. */
export async function departements(cacheDir) {
  const brut = JSON.parse((await enCache(DEPARTEMENTS, cacheDir)).toString('utf8'));
  const out = [];
  for (const f of brut.features ?? []) {
    if (!f.geometry) continue;
    const g = alleger(f.geometry, 0.01, 3);
    if (g.length) out.push({ n: f.properties?.nom, c: f.properties?.code, g });
  }
  return out;
}

/** Communes d'un département, ~80 m de tolérance. */
export async function communes(dep, cacheDir) {
  const url = `https://geo.api.gouv.fr/departements/${dep}/communes?fields=nom,code,contour&format=json`;
  const brut = JSON.parse((await enCache(url, cacheDir)).toString('utf8'));
  const out = [];
  for (const c of brut) {
    if (!c.contour) continue;
    const g = alleger(c.contour, 0.0008, 4);
    if (g.length) out.push({ n: c.nom, c: c.code, g });
  }
  return out;
}
