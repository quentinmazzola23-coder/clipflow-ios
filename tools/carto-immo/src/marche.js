import { enCache } from './cadastre.js';
import { log } from './log.js';

/**
 * Repères de marché d'une commune, calculés sur les ventes réellement
 * publiées (DVF). C'est ce qui permet de dire si une annonce est chère : non
 * pas contre une estimation, mais contre ce que les voisins ont payé.
 */

const BASE = 'https://files.data.gouv.fr/geo-dvf/latest/csv';
const ANNEES = [2024, 2023];

function parseCsv(txt) {
  const rows = [];
  let row = [], cur = '', q = false;
  for (let i = 0; i < txt.length; i++) {
    const c = txt[i];
    if (q) {
      if (c === '"') { if (txt[i + 1] === '"') { cur += '"'; i++; } else q = false; }
      else cur += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(cur); cur = ''; }
    else if (c === '\n') { row.push(cur); rows.push(row); row = []; cur = ''; }
    else if (c !== '\r') cur += c;
  }
  if (cur || row.length) { row.push(cur); rows.push(row); }
  const head = rows.shift();
  if (!head) return [];
  return rows.filter((r) => r.length === head.length)
    .map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])));
}

const nb = (v) => { const x = Number(v); return v !== '' && Number.isFinite(x) ? x : null; };
const tri = (a) => [...a].sort((x, y) => x - y);
const mediane = (a) => { const s = tri(a), m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const quantile = (a, p) => tri(a)[Math.min(a.length - 1, Math.floor(a.length * p))];

/**
 * Prix au m² des ventes de la commune, par type de bien.
 * @returns {Promise<{maison:number[], appartement:number[]}>}
 */
async function ventes(insee, cacheDir) {
  const dep = insee.length === 5 && insee.startsWith('97') ? insee.slice(0, 3) : insee.slice(0, 2);
  const parType = { maison: [], appartement: [] };

  for (const an of ANNEES) {
    let lignes;
    try {
      const buf = await enCache(`${BASE}/${an}/communes/${dep}/${insee}.csv`, cacheDir);
      lignes = parseCsv(buf.toString('utf8'));
    } catch {
      continue; // commune sans fichier cette année-là
    }

    const parMutation = new Map();
    for (const l of lignes) {
      if (l.nature_mutation !== 'Vente') continue;
      if (!parMutation.has(l.id_mutation)) parMutation.set(l.id_mutation, []);
      parMutation.get(l.id_mutation).push(l);
    }

    for (const rows of parMutation.values()) {
      for (const type of ['Maison', 'Appartement']) {
        const biens = rows.filter((r) => r.type_local === type);
        // Une seule unité dans la mutation, sinon le prix ne se rapporte pas à un bien.
        if (biens.length !== 1) continue;
        if (rows.some((r) => r.type_local && r.type_local !== type && r.type_local !== 'Dépendance')) continue;
        const prix = nb(biens[0].valeur_fonciere);
        const surface = nb(biens[0].surface_reelle_bati);
        if (!prix || !surface || surface < 20) continue;
        const pm2 = prix / surface;
        if (pm2 < 300 || pm2 > 12000) continue; // aberrations du fichier brut
        parType[type.toLowerCase()].push(pm2);
      }
    }
  }
  return parType;
}

const cacheMemoire = new Map();

/**
 * Repères de marché pour une commune et un type de bien.
 * @returns {Promise<{medianeM2:number, basM2:number, hautM2:number, echantillon:number}|null>}
 */
export async function reperes(insee, typeBien, cacheDir) {
  if (!insee) return null;
  const cle = `${insee}:${typeBien}`;
  if (cacheMemoire.has(cle)) return cacheMemoire.get(cle);

  let res = null;
  try {
    const parType = await ventes(insee, cacheDir);
    const type = typeBien === 'Appartement' ? 'appartement' : 'maison';
    const pm2 = parType[type] ?? [];
    // En dessous de cinq ventes, une médiane ne veut rien dire.
    if (pm2.length >= 5) {
      res = {
        medianeM2: Math.round(mediane(pm2)),
        basM2: Math.round(quantile(pm2, 0.25)),
        hautM2: Math.round(quantile(pm2, 0.75)),
        echantillon: pm2.length,
      };
    }
  } catch (e) {
    log.warn(`  marché ${insee} indisponible (${e.message})`);
  }

  cacheMemoire.set(cle, res);
  return res;
}

/** Situe un prix affiché face aux repères de la commune. */
export function situer(prix, surface, rep) {
  if (!rep || !prix || !surface) return {};
  const pm2 = prix / surface;
  const bas = Math.round(rep.basM2 * surface);
  const haut = Math.round(rep.hautM2 * surface);
  return {
    ecartMarchePct: Number((((pm2 - rep.medianeM2) / rep.medianeM2) * 100).toFixed(1)),
    medianeSecteurM2: rep.medianeM2,
    fourchetteBasse: bas,
    fourchetteHaute: haut,
    nbVentesComparables: rep.echantillon,
    positionMarche: prix < bas ? 'Sous le marché' : prix > haut ? 'Au-dessus du marché' : 'Dans le marché',
  };
}
