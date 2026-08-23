/**
 * Génère une carte de démonstration à partir de données publiques réelles.
 *
 * Sert à voir la sortie de l'agent sans avoir de compte lacquereur.fr ni de
 * session leboncoin ouverte. Rien n'est inventé : les biens sont de vraies
 * maisons, localisées par leur DPE et chiffrées par les ventes publiées.
 *
 *   Prix, surfaces, parcelles ..... DVF (files.data.gouv.fr/geo-dvf)
 *   Adresses, coordonnées, DPE .... ADEME (data.ademe.fr)
 *   Contours communaux ............ geo.api.gouv.fr
 *
 * Ce sont des ventes déjà conclues, pas des annonces en cours : la carte
 * montre la mise en forme, pas un état du marché à l'instant présent.
 *
 *   node scripts/demo-donnees-reelles.mjs [--communes 32233,32256] [--out data-demo]
 */
import fs from 'node:fs';
import path from 'node:path';
import { ROOT } from '../src/config.js';
import { writeMap } from '../src/map.js';
import { writeSpreadsheet, writeCsv } from '../src/sheet.js';
import { log } from '../src/log.js';

const DEFAUT = ['32233', '32256', '32344', '32296', '32319']; // Marciac, Mirande, Riscle, Nogaro, Plaisance
const ANNEES = [2024, 2023];
const DEPARTEMENT = '32';

const args = process.argv.slice(2);
const opt = (nom, def) => {
  const i = args.indexOf(`--${nom}`);
  return i === -1 ? def : args[i + 1];
};
const COMMUNES = opt('communes', DEFAUT.join(',')).split(',');
const OUT = path.resolve(ROOT, opt('out', 'data-demo'));

// ── Utilitaires ───────────────────────────────────────────────────────────

/** GET avec quelques reprises : ces API publiques renvoient parfois un 503. */
async function texte(url, essais = 4) {
  let derniere;
  for (let i = 0; i < essais; i++) {
    try {
      const r = await fetch(url);
      if (r.ok) return r.text();
      derniere = new Error(`${r.status} sur ${url}`);
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) {
      derniere = e;
    }
    await new Promise((r) => setTimeout(r, 1500 * 2 ** i));
  }
  throw derniere;
}

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
  return rows.filter((r) => r.length === head.length)
    .map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])));
}

const nb = (v) => { const x = Number(v); return v !== '' && Number.isFinite(x) ? x : null; };
const tri = (a) => [...a].sort((x, y) => x - y);
const mediane = (a) => { const s = tri(a), m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const quantile = (a, p) => tri(a)[Math.min(a.length - 1, Math.floor(a.length * p))];
const cle = (s) => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toUpperCase().replace(/[^A-Z0-9]/g, '');

// ── Sources ───────────────────────────────────────────────────────────────

/** Ventes de maisons d'une commune, une entrée par mutation. */
async function ventesMaisons(insee) {
  const lignes = [];
  for (const an of ANNEES) {
    const url = `https://files.data.gouv.fr/geo-dvf/latest/csv/${an}/communes/${DEPARTEMENT}/${insee}.csv`;
    try {
      lignes.push(...parseCsv(await texte(url)));
    } catch (e) {
      log.warn(`  DVF ${an} indisponible (${e.message})`);
    }
  }

  const parMutation = new Map();
  for (const l of lignes) {
    if (l.nature_mutation !== 'Vente') continue;
    if (!parMutation.has(l.id_mutation)) parMutation.set(l.id_mutation, []);
    parMutation.get(l.id_mutation).push(l);
  }

  const out = [];
  for (const [id, rows] of parMutation) {
    const maisons = rows.filter((r) => r.type_local === 'Maison');
    // Une seule maison dans la mutation, sinon le prix ne se rapporte pas à un bien unique.
    if (maisons.length !== 1) continue;
    if (rows.some((r) => r.type_local && !['Maison', 'Dépendance'].includes(r.type_local))) continue;

    const m = maisons[0];
    const prix = nb(m.valeur_fonciere), surface = nb(m.surface_reelle_bati);
    const lat = nb(m.latitude), lon = nb(m.longitude);
    if (!prix || !surface || surface < 40 || !lat || !lon) continue;
    const pm2 = prix / surface;
    if (pm2 < 300 || pm2 > 6000) continue; // aberrations du fichier brut

    const terrain = [...new Set(rows.map((r) => r.id_parcelle))]
      .reduce((t, p) => t + (nb(rows.find((r) => r.id_parcelle === p)?.surface_terrain) ?? 0), 0);

    out.push({
      id, date: m.date_mutation, prix, surface, pm2,
      pieces: nb(m.nombre_pieces_principales), terrain: terrain || null,
      numero: m.adresse_numero, voie: m.adresse_nom_voie, cp: m.code_postal,
      commune: m.nom_commune, parcelle: m.id_parcelle, lat, lon,
    });
  }
  return out.sort((a, b) => b.date.localeCompare(a.date));
}

async function dpeCommune(insee) {
  const champs = [
    'adresse_ban', 'identifiant_ban', 'etiquette_dpe', 'etiquette_ges', '_geopoint',
    'numero_voie_ban', 'nom_rue_ban', 'surface_habitable_logement', 'annee_construction',
    'date_etablissement_dpe', 'conso_5_usages_par_m2_ep', 'numero_dpe',
  ].join(',');
  const qs = encodeURIComponent(`code_insee_ban:${insee} AND type_batiment:maison`);
  try {
    const r = await fetch(
      `https://data.ademe.fr/data-fair/api/v1/datasets/dpe03existant/lines?size=1000&qs=${qs}&select=${champs}`
    );
    return r.ok ? (await r.json()).results ?? [] : [];
  } catch {
    return [];
  }
}

/** Rapproche une vente d'un DPE : même rue, même numéro, surface cohérente. */
function trouverDpe(vente, dpes) {
  const rue = cle(vente.voie), num = String(vente.numero ?? '');
  let best = null;
  for (const d of dpes) {
    if (!d.nom_rue_ban || cle(d.nom_rue_ban) !== rue) continue;
    if (num && String(d.numero_voie_ban ?? '') !== num) continue;
    const s = nb(d.surface_habitable_logement);
    const ecart = s ? Math.abs(s - vente.surface) / vente.surface : 1;
    if (ecart > 0.25) continue;
    if (!best || ecart < best.ecart) best = { d, ecart };
  }
  return best?.d ?? null;
}

/** Simplification Douglas-Peucker d'une ligne de coordonnées. */
function simplifier(pts, eps) {
  if (pts.length < 3) return pts;
  const [x1, y1] = pts[0], [x2, y2] = pts[pts.length - 1];
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

/** Contours communaux du département, allégés pour tenir dans la page. */
async function contours() {
  const url = `https://geo.api.gouv.fr/departements/${DEPARTEMENT}/communes?fields=nom,code,contour&format=json`;
  const brut = JSON.parse(await texte(url));
  const EPS = 0.0008; // ~80 m, suffisant pour un fond de carte départemental
  const out = [];
  for (const c of brut) {
    const g = c.contour;
    if (!g) continue;
    const anneaux = g.type === 'Polygon' ? [g.coordinates[0]] : g.coordinates.map((p) => p[0]);
    const rings = [];
    for (const r of anneaux) {
      const s = simplifier(r.map(([x, y]) => [Number(x.toFixed(4)), Number(y.toFixed(4))]), EPS);
      if (String(s[0]) !== String(s[s.length - 1])) s.push(s[0]);
      if (s.length >= 4) rings.push(s);
    }
    if (rings.length) out.push({ n: c.nom, c: c.code, g: rings });
  }
  return out;
}

// ── Assemblage ────────────────────────────────────────────────────────────

fs.mkdirSync(OUT, { recursive: true });
const fiches = [];
let totalVentes = 0;

for (const insee of COMMUNES) {
  log.step(`commune ${insee}`);
  const ventes = await ventesMaisons(insee);
  if (!ventes.length) { log.warn('  aucune vente exploitable'); continue; }
  totalVentes += ventes.length;

  const pm2s = ventes.map((v) => v.pm2);
  const med = Math.round(mediane(pm2s));
  const bas = Math.round(quantile(pm2s, 0.25));
  const haut = Math.round(quantile(pm2s, 0.75));

  const dpes = await dpeCommune(insee);
  const adressees = ventes.filter((v) => v.voie && v.numero);

  // On privilégie une vente rapprochable d'un DPE réel : c'est ce qui donne
  // l'adresse exacte et les coordonnées, comme le fait lacquereur.fr.
  let choisie = null, dpe = null;
  for (const v of adressees) {
    const d = trouverDpe(v, dpes);
    if (d) { choisie = v; dpe = d; break; }
  }
  choisie ??= adressees[0] ?? ventes[0];

  const geo = dpe?._geopoint?.split(',').map(Number);
  const lat = geo?.[0] ?? choisie.lat;
  const lon = geo?.[1] ?? choisie.lon;
  const adresse = dpe?.adresse_ban
    ?? [choisie.numero, choisie.voie, choisie.cp, choisie.commune].filter(Boolean).join(' ');
  const maintenant = new Date().toISOString();

  fiches.push({
    id: choisie.id,
    cle: `parcelle:${choisie.parcelle}`,
    statut: 'nouveau',
    collecteLe: maintenant,
    premiereApparition: maintenant,
    annonces: [{ id: choisie.id }],
    titre: `Maison ${choisie.surface} m²${choisie.pieces ? ` · ${choisie.pieces} pièces` : ''} — ${choisie.commune}`,
    typeBien: 'Maison',
    prix: choisie.prix,
    prixM2: Math.round(choisie.pm2),
    surface: choisie.surface,
    terrain: choisie.terrain,
    pieces: choisie.pieces,
    ville: choisie.commune,
    codePostal: choisie.cp,
    adresseEstimee: adresse,
    latitude: lat,
    longitude: lon,
    localisationPrecise: !!dpe,
    confianceAdresse: dpe ? 90 : 70,
    sourceAdresse: dpe ? 'dpe' : 'dvf',
    parcelle: choisie.parcelle,
    codeInsee: insee,
    dpe: dpe?.etiquette_dpe ?? null,
    ges: dpe?.etiquette_ges ?? null,
    consoEnergie: Math.round(nb(dpe?.conso_5_usages_par_m2_ep) ?? 0) || null,
    dateDpe: dpe?.date_etablissement_dpe ?? null,
    anneeConstruction: nb(dpe?.annee_construction),
    publieeLe: choisie.date,
    joursEnLigne: Math.round((Date.now() - new Date(choisie.date)) / 86400000),
    ecartMarchePct: Number((((choisie.pm2 - med) / med) * 100).toFixed(1)),
    medianeSecteurM2: med,
    fourchetteBasse: Math.round(bas * choisie.surface),
    fourchetteHaute: Math.round(haut * choisie.surface),
    positionMarche: choisie.pm2 < bas ? 'Sous le marché'
      : choisie.pm2 > haut ? 'Au-dessus du marché' : 'Dans le marché',
    nbVentesComparables: ventes.length,
    urlAnnonce: `https://app.dvf.etalab.gouv.fr/?code_commune=${insee}`,
    urlAnalyse: `https://www.geoportail.gouv.fr/carte?c=${lon},${lat}&z=18&l0=CADASTRALPARCELS.PARCELLAIRE_EXPRESS::GEOPORTAIL:OGC:WMTS(1)`,
    urlMaps: `https://www.google.com/maps/search/?api=1&query=${lat},${lon}`,
  });

  log.ok(`  ${ventes.length} ventes · médiane ${med} €/m² · retenue : ${adresse}` +
    ` · ${choisie.prix} € / ${choisie.surface} m² · DPE ${dpe?.etiquette_dpe ?? '—'}`);
}

if (!fiches.length) {
  log.error('Aucune fiche construite.');
  process.exit(1);
}

const note =
  `Test sur données réelles. Les ${fiches.length} biens sont de véritables maisons du Gers : ` +
  'adresse et coordonnées issues du DPE ADEME, prix et surfaces des ventes publiées au fichier ' +
  `DVF (${ANNEES.at(-1)}-${ANNEES[0]}), écart au marché calculé sur ${totalVentes} ventes réelles ` +
  'des communes retenues. Ce sont des ventes déjà conclues, pas des annonces en cours — l\'agent, ' +
  'lui, alimente cette même carte avec les annonces leboncoin du matin.';

log.step('contours communaux');
let communes = [];
try {
  communes = await contours();
  log.ok(`  ${communes.length} communes`);
} catch (e) {
  // Le fond vectoriel est un confort : sans lui, seule la carte OpenStreetMap
  // est produite, et la démonstration reste utilisable.
  log.warn(`  indisponible (${e.message}) — carte autonome non générée`);
}

// Deux cartes : l'une avec le fond OpenStreetMap comme en production, l'autre
// avec un fond vectoriel embarqué, qui fonctionne sans aucune requête sortante.
const osm = writeMap(fiches, path.join(OUT, 'carte-demo.html'), {
  title: 'Veille immobilière — Gers', note,
});
const hors = communes.length
  ? writeMap(fiches, path.join(OUT, 'carte-demo-autonome.html'), {
      title: 'Veille immobilière — Gers',
      note,
      basemap: {
        communes,
        attribution: 'Contours communaux © IGN / Etalab · Prix ' +
          '<a href="https://app.dvf.etalab.gouv.fr/">DVF</a> · DPE ' +
          '<a href="https://data.ademe.fr/">ADEME</a>',
      },
    })
  : null;

await writeSpreadsheet(fiches, path.join(OUT, 'annonces-demo.xlsx'));
writeCsv(fiches, path.join(OUT, 'annonces-demo.csv'));

log.ok(`Carte (OpenStreetMap) : ${osm.file}`);
if (hors) {
  log.ok(`Carte (autonome)      : ${hors.file}  ${(fs.statSync(hors.file).size / 1024).toFixed(0)} Ko`);
}
log.ok(`Tableur               : ${path.join(OUT, 'annonces-demo.xlsx')}`);
