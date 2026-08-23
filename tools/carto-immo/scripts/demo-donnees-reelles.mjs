/**
 * Génère une carte de démonstration à partir de données publiques réelles.
 *
 * Sert à voir la sortie de l'agent sans avoir de compte lacquereur.fr ni de
 * session leboncoin ouverte. Rien n'est inventé : les biens sont de vraies
 * maisons, localisées par leur DPE et chiffrées par les ventes publiées.
 *
 *   Prix, surfaces, parcelles ..... DVF (files.data.gouv.fr/geo-dvf)
 *   Adresses, coordonnées, DPE .... ADEME (data.ademe.fr)
 *   Parcelles et bâtiments ........ cadastre Etalab (cadastre.data.gouv.fr)
 *   Contours communaux ............ geo.api.gouv.fr
 *
 * Seuls les biens dont l'adresse exacte est retrouvée dans le DPE *et* dont la
 * parcelle est présente au cadastre sont retenus : la carte doit montrer une
 * localisation certaine, pas une approximation à la commune.
 *
 * Ce sont des ventes déjà conclues, pas des annonces en cours : la carte
 * montre la mise en forme, pas un état du marché à l'instant présent.
 *
 *   node scripts/demo-donnees-reelles.mjs [--communes 32233,32256] [--out data-demo]
 *                                         [--par-commune 2] [--filtres] [--sans-cache]
 *
 * Les téléchargements sont mis en cache sur disque : ces API publiques tombent
 * régulièrement en 503, et les fichiers DVF comme cadastraux ne bougent pas.
 */
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { ROOT } from '../src/config.js';
import { writeMap } from '../src/map.js';
import { writeSpreadsheet, writeCsv } from '../src/sheet.js';
import { log } from '../src/log.js';
import { chargerCommune } from '../src/cadastre.js';

// Marciac par défaut. `--communes 32013,32256` élargit au secteur.
const DEFAUT = ['32233'];
const RAYON_CONTEXTE_M = 400; // parcelles voisines dessinées autour de chaque bien
const ANNEES = [2024, 2023];
const DEPARTEMENT = '32';

const args = process.argv.slice(2);
const opt = (nom, def) => {
  const i = args.indexOf(`--${nom}`);
  return i === -1 ? def : args[i + 1];
};
const COMMUNES = opt('communes', DEFAUT.join(',')).split(',');
const OUT = path.resolve(ROOT, opt('out', 'data-demo'));
const PAR_COMMUNE = Number(opt('par-commune', '30'));
const FILTRES = args.includes('--filtres');
const CACHE = path.join(OUT, '.cache');
const SANS_CACHE = args.includes('--sans-cache');

// ── Utilitaires ───────────────────────────────────────────────────────────

/** GET avec quelques reprises : ces API publiques renvoient parfois un 503. */
async function texte(url, essais = 5) {
  return (await enCache(url, () => texteBrut(url, essais).then(Buffer.from))).toString('utf8');
}

async function texteBrut(url, essais = 5) {
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
    await new Promise((r) => setTimeout(r, 2500 * 2 ** i));
  }
  throw derniere;
}

/** Cache disque par URL : évite de retélécharger, et sauve les jours de 503. */
async function enCache(url, telecharger) {
  const f = path.join(CACHE, createHash('sha1').update(url).digest('hex').slice(0, 16));
  if (!SANS_CACHE && fs.existsSync(f)) return fs.readFileSync(f);
  const buf = await telecharger();
  fs.mkdirSync(CACHE, { recursive: true });
  fs.writeFileSync(f, buf);
  return buf;
}

async function binaire(url, essais = 5) {
  return enCache(url, () => binaireBrut(url, essais));
}

async function binaireBrut(url, essais = 5) {
  let derniere;
  for (let i = 0; i < essais; i++) {
    try {
      const r = await fetch(url);
      if (r.ok) return Buffer.from(await r.arrayBuffer());
      derniere = new Error(`${r.status} sur ${url}`);
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) {
      derniere = e;
    }
    await new Promise((r) => setTimeout(r, 2500 * 2 ** i));
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
const contexteParcelles = [];
const contexteBatiments = [];
let totalVentes = 0;
const dejaVues = new Set();

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
  const cadastre = await chargerCommune(insee, CACHE, { sansCache: SANS_CACHE });
  const adressees = ventes.filter((v) => v.voie && v.numero);

  // On ne retient que les biens dont l'adresse est confirmée par un DPE **et**
  // dont la parcelle existe au cadastre : la carte montre une localisation
  // certaine, pas une approximation à la commune.
  let retenus = 0;
  for (const v of adressees) {
    if (retenus >= PAR_COMMUNE) break;
    const dpe = trouverDpe(v, dpes);
    if (!dpe) continue;
    const parcelle = cadastre.parcelles.get(v.parcelle);
    if (!parcelle) continue;

    const [lat, lon] = dpe._geopoint.split(',').map(Number);
    const maintenant = new Date().toISOString();

    // Voisinage cadastral, pour que la parcelle se lise dans son contexte.
    for (const g of cadastre.autour(lat, lon, RAYON_CONTEXTE_M)) {
      const cle = (g.batiment ? 'b' : 'p') + g.centre.join(',');
      if (dejaVues.has(cle)) continue;
      dejaVues.add(cle);
      (g.batiment ? contexteBatiments : contexteParcelles).push(g.anneaux);
    }

    fiches.push({
      id: v.id,
      cle: `parcelle:${v.parcelle}`,
      statut: 'nouveau',
      collecteLe: maintenant,
      premiereApparition: maintenant,
      annonces: [{ id: v.id }],
      titre: `Maison ${v.surface} m²${v.pieces ? ` · ${v.pieces} pièces` : ''} — ${v.commune}`,
      typeBien: 'Maison',
      prix: v.prix,
      prixM2: Math.round(v.pm2),
      surface: v.surface,
      terrain: v.terrain,
      pieces: v.pieces,
      ville: v.commune,
      codePostal: v.cp,
      adresseEstimee: dpe.adresse_ban,
      latitude: lat,
      longitude: lon,
      localisationPrecise: true,
      confianceAdresse: 90,
      sourceAdresse: 'dpe',
      parcelle: v.parcelle,
      parcelleGeom: parcelle.anneaux,
      contenance: parcelle.contenance,
      codeInsee: insee,
      dpe: dpe.etiquette_dpe ?? null,
      ges: dpe.etiquette_ges ?? null,
      consoEnergie: Math.round(nb(dpe.conso_5_usages_par_m2_ep) ?? 0) || null,
      dateDpe: dpe.date_etablissement_dpe ?? null,
      anneeConstruction: nb(dpe.annee_construction),
      publieeLe: v.date,
      joursEnLigne: Math.round((Date.now() - new Date(v.date)) / 86400000),
      ecartMarchePct: Number((((v.pm2 - med) / med) * 100).toFixed(1)),
      medianeSecteurM2: med,
      fourchetteBasse: Math.round(bas * v.surface),
      fourchetteHaute: Math.round(haut * v.surface),
      positionMarche: v.pm2 < bas ? 'Sous le marché'
        : v.pm2 > haut ? 'Au-dessus du marché' : 'Dans le marché',
      nbVentesComparables: ventes.length,
      urlAnnonce: `https://app.dvf.etalab.gouv.fr/?code_commune=${insee}`,
      urlAnalyse: `https://www.geoportail.gouv.fr/carte?c=${lon},${lat}&z=19&l0=CADASTRALPARCELS.PARCELLAIRE_EXPRESS::GEOPORTAIL:OGC:WMTS(1)`,
      urlMaps: `https://www.google.com/maps/search/?api=1&query=${lat},${lon}`,
    });
    retenus++;
    log.ok(`  ${dpe.adresse_ban} · parcelle ${v.parcelle} (${parcelle.contenance ?? '?'} m²)` +
      ` · ${v.prix} € / ${v.surface} m² = ${Math.round(v.pm2)} €/m² · DPE ${dpe.etiquette_dpe ?? '—'}`);
  }

  if (!retenus) log.warn(`  aucun bien avec adresse et parcelle confirmées (médiane ${med} €/m²)`);
  else log.info(`  ${ventes.length} ventes analysées · médiane ${med} €/m²`);
}

if (!fiches.length) {
  log.error('Aucune fiche construite.');
  process.exit(1);
}

const villes = [...new Set(fiches.map((f) => f.ville))];
const ou = villes.length === 1 ? `à ${villes[0]}` : `dans ${villes.length} communes du Gers`;
const note =
  `Données réelles. ${fiches.length} maisons ${ou}, chacune à son adresse exacte et sur sa ` +
  'parcelle cadastrale : adresse et coordonnées confirmées par le DPE ADEME, contour de parcelle ' +
  'issu du cadastre, prix et surfaces des ventes publiées au fichier DVF ' +
  `(${ANNEES.at(-1)}-${ANNEES[0]}), écart au marché calculé sur ${totalVentes} ventes réelles. ` +
  'Ce sont des ventes déjà conclues, pas des annonces en cours — l\'agent, lui, alimente cette ' +
  'même carte avec les annonces leboncoin du matin.';

const titre = villes.length === 1
  ? `Veille immobilière — ${villes[0]}`
  : `Veille immobilière — ${villes.length} communes du Gers`;

log.step('contours communaux');
let communes = [];
try {
  communes = await contours();
  log.ok(`  ${communes.length} communes`);
} catch (e) {
  // Le fond vectoriel est un confort : sans lui, seule la carte OpenStreetMap
  // est produite, et la démonstration reste utilisable. En revanche on efface
  // toute version précédente, qui passerait pour la sortie de cette exécution.
  log.warn(`  indisponible (${e.message}) — carte autonome non générée`);
  fs.rmSync(path.join(OUT, 'carte-demo-autonome.html'), { force: true });
}

// Deux cartes : l'une avec le fond OpenStreetMap comme en production, l'autre
// avec un fond vectoriel embarqué, qui fonctionne sans aucune requête sortante.
const osm = writeMap(fiches, path.join(OUT, 'carte-demo.html'), {
  title: titre, note, filtres: FILTRES,
});
const hors = communes.length
  ? writeMap(fiches, path.join(OUT, 'carte-demo-autonome.html'), {
      title: titre,
      note,
      filtres: FILTRES,
      basemap: {
        communes,
        cadastre: { parcelles: contexteParcelles, batiments: contexteBatiments },
        attribution: 'Cadastre et contours © IGN / Etalab · Prix ' +
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
log.info(`Contexte cadastral    : ${contexteParcelles.length} parcelles, ${contexteBatiments.length} bâtiments`);
