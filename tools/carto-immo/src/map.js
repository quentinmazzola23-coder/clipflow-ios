import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

/** Leaflet est embarqué dans le fichier : la carte s'ouvre sans dépendance réseau
 *  (seules les tuiles de fond sont chargées en ligne). */
function inlineLeaflet() {
  const dir = path.dirname(require.resolve('leaflet/package.json'));
  const css = fs
    .readFileSync(path.join(dir, 'dist', 'leaflet.css'), 'utf8')
    // Les images de Leaflet sont relatives à son CSS : on neutralise les
    // références cassées, les marqueurs étant dessinés en CSS pur.
    .replace(/url\((?!data:)[^)]+\)/g, 'none');
  const js = fs.readFileSync(path.join(dir, 'dist', 'leaflet.js'), 'utf8');
  return { css, js };
}

const ATTRIBUTION_OSM =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';

const FOND_OSM = `L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);`;

// Fond vectoriel embarqué : la page reste lisible sans aucune requête sortante.
//
// Trois échelles, chacune prenant le relais de la précédente : la France par
// départements, les communes du secteur, puis le plan cadastral. Sans cela, la
// carte se viderait dès qu'on s'éloigne du périmètre cherché.
const FOND_VECTORIEL = `document.querySelector('.leaflet-container').style.background = '#eef2f5';
const renduFond = L.canvas({ pane: 'tilePane', padding: .3 });
const ZOOM_COMMUNES = 9;

for (const dep of (BASEMAP.departements ?? [])) {
  L.polygon(dep.g.map(r => r.map(([x, y]) => [y, x])), {
    renderer: renduFond, pane: 'tilePane',
    color: '#d3ccbe', weight: .8, fillColor: '#f2efe8', fillOpacity: 1, interactive: false,
  }).addTo(map);
}

const communesLayer = L.layerGroup();
const avecBien = new Set(BASEMAP.communesAvecBien || []);
const communesPolys = [];
for (const com of (BASEMAP.communes ?? [])) {
  const marque = avecBien.has(com.c);
  const poly = L.polygon(com.g.map(r => r.map(([x, y]) => [y, x])), {
    renderer: marque ? undefined : renduFond,
    pane: 'tilePane',
    color: marque ? '#8fa9cd' : '#dcd7cc',
    weight: marque ? 1.5 : 0.6,
    fillColor: marque ? '#ece7db' : '#f2efe8',
    fillOpacity: 1,
    interactive: marque,
  }).addTo(communesLayer);
  communesPolys.push({ poly, marque });
  if (marque) poly.bindTooltip(com.n, { direction: 'top', sticky: true });
}

function majCommunes() {
  const veut = map.getZoom() >= ZOOM_COMMUNES;
  if (veut && !map.hasLayer(communesLayer)) communesLayer.addTo(map);
  else if (!veut && map.hasLayer(communesLayer)) map.removeLayer(communesLayer);
}
map.on('zoomend', majCommunes);
majCommunes();

map.attributionControl.addAttribution(BASEMAP.attribution || '');`;

/**
 * Plan cadastral : parcelles et bâtiments autour de chaque bien. Il n'apparaît
 * qu'au zoom parcelle, où le maillage communal ne dit plus rien.
 */
const FOND_CADASTRE = `const cadastre = L.layerGroup();
const ZOOM_CADASTRE = 15;
// Canvas plutôt que SVG : le plan cadastral compte des milliers de polygones,
// que le DOM ne suit pas, en particulier sur mobile.
const renduCadastre = L.canvas({ pane: 'tilePane', padding: .4 });
for (const poly of (BASEMAP.cadastre?.parcelles ?? [])) {
  L.polygon(poly.map(r => r.map(([x, y]) => [y, x])), {
    renderer: renduCadastre, pane: 'tilePane', color: '#cfc8ba', weight: 0.7,
    fillColor: '#f6f3ec', fillOpacity: 1, interactive: false,
  }).addTo(cadastre);
}
for (const poly of (BASEMAP.cadastre?.batiments ?? [])) {
  L.polygon(poly.map(r => r.map(([x, y]) => [y, x])), {
    renderer: renduCadastre, pane: 'tilePane', color: '#b9b0a0', weight: 0.6,
    fillColor: '#ddd6c8', fillOpacity: 1, interactive: false,
  }).addTo(cadastre);
}
function majFondCadastre() {
  const veut = map.getZoom() >= ZOOM_CADASTRE;
  if (veut && !map.hasLayer(cadastre)) cadastre.addTo(map);
  else if (!veut && map.hasLayer(cadastre)) map.removeLayer(cadastre);
  for (const { poly, marque } of communesPolys) {
    poly.setStyle(veut
      ? { fillOpacity: 0, weight: marque ? 1.2 : 0, color: '#c9c1b2' }
      : { fillOpacity: 1, weight: marque ? 1.5 : 0.6, color: marque ? '#8fa9cd' : '#dcd7cc' });
  }
}
map.on('zoomend', majFondCadastre);
majFondCadastre();`;

const BLOC_FILTRES = `<div class="filters">
      <input type="search" id="q" placeholder="Filtrer par ville, titre, adresse…">
      <div class="row"><label for="pmin">Prix</label>
        <input type="number" id="pmin" placeholder="min €"><input type="number" id="pmax" placeholder="max €"></div>
      <div class="row"><label for="smin">Surface</label>
        <input type="number" id="smin" placeholder="min m²"><input type="number" id="smax" placeholder="max m²"></div>
      <div class="chips">
        <button class="chip" id="f-new" aria-pressed="false">Nouveaux</button>
        <button class="chip" id="f-again" aria-pressed="false">Remis en ligne</button>
        <button class="chip" id="f-under" aria-pressed="false">Sous le marché</button>
        <button class="chip" id="f-drop" aria-pressed="false">Prix baissé</button>
        <button class="chip" id="f-exact" aria-pressed="false">Adresse exacte</button>
      </div>
    </div>`;

const escapeJson = (obj) =>
  JSON.stringify(obj).replace(/</g, '\\u003c').replace(/-->/g, '--\\u003e');

/**
 * @param {object[]} records
 * @param {string} file
 * @param {object} [opts]
 * @param {string} [opts.title]
 * @param {string} [opts.note] Ligne de contexte affichée sous l'en-tête.
 * @param {object} [opts.basemap] Fond vectoriel autonome, à la place des tuiles
 *   OpenStreetMap : `{ communes: [{ n, c, g }], cadastre: { parcelles, batiments },
 *   attribution }`. Utile quand la page doit fonctionner sans accès réseau.
 * @param {boolean} [opts.filtres] Affiche le bloc de recherche et de filtres.
 *   À `false`, la carte va droit aux biens et à leur localisation exacte.
 */
export function writeMap(
  records,
  file,
  { title = 'Veille immobilière', note = null, basemap = null, filtres = true } = {}
) {
  const points = records
    .filter((r) => Number.isFinite(r.latitude) && Number.isFinite(r.longitude))
    .map((r) => ({
      id: r.id,
      t: r.titre,
      ty: r.typeBien,
      p: r.prix,
      m2: r.prixM2,
      s: r.surface,
      te: r.terrain,
      pc: r.pieces,
      ch: r.chambres,
      v: r.ville,
      cp: r.codePostal,
      ad: r.adresseEstimee,
      cf: r.niveauConfiance ?? null,
      pr: r.localisationPrecise,
      pcl: r.parcelle ?? null,
      pg: r.parcelleGeom ?? null,
      ct: r.contenance ?? null,
      la: r.latitude,
      lo: r.longitude,
      dpe: r.dpe,
      ges: r.ges,
      an: r.anneeConstruction,
      j: r.joursEnLigne,
      nb: r.nbBaisses,
      bp: r.baissePct,
      ec: r.ecartMarchePct,
      fb: r.fourchetteBasse,
      fh: r.fourchetteHaute,
      pm: r.positionMarche,
      dv: r.delaiVenteCommuneJours,
      st: r.statut ?? 'connu',
      pa: r.annonces?.length ?? 1,
      d1: r.premiereApparition ?? null,
      pv: r.prixModifie ?? null,
      ph: r.photo,
      ua: r.urlAnnonce,
      ul: r.urlAnalyse,
      um: r.urlMaps,
    }));

  // En mode autonome la page ne doit émettre aucune requête : les photos, qui
  // sont hébergées par le site d'annonces, laisseraient des cadres vides.
  if (basemap) for (const p of points) p.ph = null;

  const sansCoords = records.length - points.length;
  const { css, js } = inlineLeaflet();

  if (basemap?.communes) {
    basemap = {
      ...basemap,
      communesAvecBien: [...new Set(records.map((r) => r.codeInsee).filter(Boolean))],
    };
  }

  const html = `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${css}</style>
<style>
:root{
  --bg:#f6f5f2; --panel:#fff; --line:#e4e1da; --ink:#15171c; --muted:#6b6f76;
  --accent:#1f3a5f; --green:#1e7a46; --amber:#a06a00; --red:#b3261e; --grey:#8b9099;
}
*{box-sizing:border-box}
html,body{height:100%;margin:0;overflow:hidden;overscroll-behavior:none}
body{font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--bg)}
.card .price,.pop .p,.pop dd,.pill{font-variant-numeric:tabular-nums}
#app{display:flex;height:100%}
#side{width:370px;flex:none;background:var(--panel);border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0}
#map{flex:1;min-width:0}
header{padding:16px 18px 12px;border-bottom:1px solid var(--line)}
header h1{margin:0 0 2px;font-size:16px;font-weight:650;letter-spacing:-.01em}
header .sub{color:var(--muted);font-size:12.5px}
header .note{margin:9px 0 0;padding:8px 10px;border-radius:8px;background:#f4f1ea;border:1px solid var(--line);color:var(--muted);font-size:12px;line-height:1.45}
header .note a{color:var(--accent)}
.filters{padding:12px 18px;border-bottom:1px solid var(--line);display:grid;gap:9px}
.row{display:flex;gap:8px;align-items:center}
.row label{font-size:12px;color:var(--muted);min-width:64px}
input[type=number],select,input[type=search]{width:100%;padding:7px 9px;border:1px solid var(--line);border-radius:8px;font:inherit;font-size:13px;background:#fff;color:var(--ink)}
input[type=search]{padding-left:10px}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{border:1px solid var(--line);background:#fff;border-radius:999px;padding:5px 11px;font-size:12.5px;cursor:pointer;color:var(--muted);user-select:none}
.chip[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff}
#count{padding:9px 18px;font-size:12.5px;color:var(--muted);border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:center}
#count .actions{display:flex;gap:14px}
#count button{border:none;background:none;color:var(--accent);font:inherit;font-size:12.5px;cursor:pointer;text-decoration:underline;padding:0}
#list{overflow:auto;flex:1;min-height:0}
.card{display:block;padding:11px 18px;border-bottom:1px solid var(--line);cursor:pointer;-webkit-tap-highlight-color:transparent}
.card .head{display:flex;gap:11px}
.card:hover{background:#faf9f6}
.card.sel{background:#eef2f8;box-shadow:inset 3px 0 0 var(--accent)}
.card .detail{margin-top:11px;padding-top:11px;border-top:1px solid var(--line)}
.card img{width:74px;height:56px;object-fit:cover;border-radius:7px;background:#e9e7e1;flex:none}
.card .noimg{width:74px;height:56px;border-radius:7px;background:#e9e7e1;flex:none}
.card h3{margin:0 0 3px;font-size:13px;font-weight:600;line-height:1.3;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.card .meta{font-size:12px;color:var(--muted)}
.card .price{font-size:13.5px;font-weight:680;margin-top:2px}
.tag{display:inline-block;font-size:11px;padding:1px 6px;border-radius:5px;margin-left:5px;vertical-align:1px}
.tag.new{background:#fff3d6;color:var(--amber)}
.tag.again{background:#e8eefb;color:#0b57d0}
.tag.under{background:#e3f4ea;color:var(--green)}
.tag.over{background:#fdeceb;color:var(--red)}
.marker{position:absolute;left:0;top:0;width:max-content;transform:translate(-50%,-50%)}
.pin{width:13px;height:13px;border-radius:50%;border:2.5px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)}
.pill{width:max-content;white-space:nowrap;color:#fff;font-size:11.5px;font-weight:650;padding:3px 8px;border-radius:999px;border:1.5px solid #fff;box-shadow:0 1px 5px rgba(0,0,0,.35)}
.marker.on{outline:3px solid rgba(31,58,95,.35);outline-offset:2px;border-radius:999px}
.g{background:var(--green)} .a{background:var(--amber)} .r{background:var(--red)} .n{background:var(--grey)}
.leaflet-popup-content{margin:0;width:296px!important}
.leaflet-popup-content-wrapper{border-radius:12px;padding:0;overflow:hidden}
.pop img{width:100%;height:132px;object-fit:cover;display:block;background:#e9e7e1}
.pop .body{padding:11px 13px 13px}
.pop h3{margin:0 0 6px;font-size:13.5px;line-height:1.35}
.pop .p{font-size:19px;font-weight:700;letter-spacing:-.02em}
.pop .p small{font-size:12px;font-weight:500;color:var(--muted);margin-left:6px}
.pop dl{margin:9px 0 0;display:grid;grid-template-columns:auto 1fr;gap:3px 10px;font-size:12.5px}
.pop dt{color:var(--muted)}
.pop dd{margin:0}
.pop .links{margin-top:11px;display:flex;gap:7px;flex-wrap:wrap}
.pop .links a{font-size:12px;text-decoration:none;border:1px solid var(--line);border-radius:7px;padding:5px 9px;color:var(--accent)}
.pop .links a:hover{background:#f2f5f9}
.badge{display:inline-block;width:19px;height:19px;line-height:19px;text-align:center;border-radius:4px;font-weight:700;font-size:11.5px;color:#fff}
.dA{background:#008040}.dB{background:#39a24a}.dC{background:#a8c94a}.dD{background:#f5d800}.dE{background:#f0a000}.dF{background:#e06000}.dG{background:#d02020}.dX{background:#b0b0b0}
.empty{padding:34px 18px;text-align:center;color:var(--muted);font-size:13px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
#poignee{display:none}
#credits{display:none;margin:0;padding:12px 18px 18px;font-size:11px;line-height:1.5;color:var(--muted);border-top:1px solid var(--line)}
#credits a{color:var(--muted)}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important}}
@media (max-width:820px){
  #app{display:block;position:relative}
  #map{position:absolute;inset:0;height:100%;width:100%}
  /* Panneau glissant : la carte reste visible, la liste vient par-dessus. */
  #side{
    position:absolute;left:0;right:0;bottom:0;width:auto;height:90%;
    border-right:none;border-top:1px solid var(--line);
    border-radius:20px 20px 0 0;box-shadow:0 -8px 32px rgba(0,0,0,.18);
    transform:translateY(var(--pos,70%));
    transition:transform .3s cubic-bezier(.22,.61,.36,1);
    z-index:1000;overscroll-behavior:contain;
  }
  #side.glisse{transition:none}
  #poignee{
    display:flex;align-items:center;justify-content:center;
    height:30px;flex:none;cursor:grab;touch-action:none;
    background:var(--panel);border-radius:20px 20px 0 0;
  }
  #poignee::before{content:'';width:40px;height:4px;border-radius:2px;background:#cfcac0}
  #poignee:active{cursor:grabbing}
  header{padding:2px 18px 12px;touch-action:none}
  header h1{font-size:15px}
  header .note{font-size:11.5px;max-height:0;padding:0 10px;border-width:0;overflow:hidden;transition:max-height .3s,padding .3s}
  #side.ouvert header .note{max-height:280px;padding:8px 10px;border-width:1px}
  #list{overscroll-behavior:contain;-webkit-overflow-scrolling:touch}
  .card{padding:13px 18px}
  .card img,.card .noimg{width:88px;height:66px}
  .card h3{font-size:14px}
  .chip{padding:9px 14px;font-size:13px}
  #count{padding:11px 18px}
  #count button{padding:6px 2px}
  .leaflet-control-zoom{display:none}
  /* Le contrôle Leaflet se retrouverait derrière le panneau. */
  .leaflet-control-attribution{display:none}
  #credits{display:block}
}
</style>
</head>
<body>
<div id="app">
  <aside id="side">
    <div id="poignee" role="button" tabindex="0" aria-label="Déplier ou replier la liste" aria-expanded="false"></div>
    <header>
      <h1>${title}</h1>
      <div class="sub" id="stamp"></div>
      ${note ? `<p class="note">${note}</p>` : ''}
    </header>
    ${filtres ? BLOC_FILTRES : ''}
    <div id="count"><span></span><span class="actions"><button id="voirtout">Tout voir</button>${filtres ? '<button id="reset">Réinitialiser</button>' : ''}</span></div>
    <div id="list"></div>
    <p id="credits"></p>
  </aside>
  <div id="map"></div>
</div>
<script>${js}</script>
<script>
const DATA = ${escapeJson(points)};
const GENERATED = ${escapeJson(new Date().toISOString())};
const SANS_COORDS = ${sansCoords};
const AVEC_FILTRES = ${filtres};
const AVEC_PHOTOS = ${!basemap};
const ATTRIBUTION = ${escapeJson(basemap?.attribution ?? '© OpenStreetMap')};
const BASEMAP = ${basemap ? escapeJson(basemap) : 'null'};

const eur = n => n == null ? '—' : new Intl.NumberFormat('fr-FR').format(Math.round(n)) + ' €';
const num = n => n == null ? '—' : new Intl.NumberFormat('fr-FR').format(n);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

/** Couleur du marqueur : verte si le prix est sous le marché, rouge au-dessus. */
function tone(d){
  if (d.ec == null) return 'n';
  if (d.ec <= -5) return 'g';
  if (d.ec >= 8) return 'r';
  return 'a';
}

const nbNeufs = DATA.filter(d => d.st === 'nouveau').length;
const nbRepris = DATA.filter(d => d.st === 'republie').length;
document.getElementById('stamp').textContent =
  DATA.length + ' bien' + (DATA.length > 1 ? 's' : '') + ' localisé' + (DATA.length > 1 ? 's' : '') +
  (nbNeufs ? ' · ' + nbNeufs + ' nouveau' + (nbNeufs > 1 ? 'x' : '') : '') +
  (nbRepris ? ' · ' + nbRepris + ' remis en ligne' : '') +
  (SANS_COORDS ? ' · ' + SANS_COORDS + ' sans localisation' : '') +
  ' · ' + new Date(GENERATED).toLocaleString('fr-FR', {dateStyle:'long', timeStyle:'short'});

document.getElementById('credits').innerHTML = 'Fond de carte : ' + ATTRIBUTION;

const map = L.map('map', { zoomControl: true, scrollWheelZoom: true });
// Vue initiale posée avant toute couche : Leaflet exige un centre pour projeter.
map.setView([46.6, 2.4], 6);

${basemap ? FOND_VECTORIEL : FOND_OSM}
${basemap?.cadastre ? FOND_CADASTRE : ''}

const layer = L.layerGroup().addTo(map);
const parcelles = L.layerGroup().addTo(map);
const markers = new Map();
let selected = null;
let shownCount = 0;
let showPills = true;

/**
 * Pastilles de prix tant que la carte reste lisible. Au zoom parcelle on
 * repasse au point : la pastille masquerait le contour du terrain, qui est
 * justement ce qu'on vient regarder.
 */
function pillsWanted(){
  return (shownCount <= 80 || map.getZoom() >= 12) && map.getZoom() < 17;
}

function icon(d, sel){
  const c = tone(d);
  const html = showPills
    ? '<div class="marker ' + (sel ? 'on' : '') + '"><div class="pill ' + c + '">' +
        (d.p ? Math.round(d.p/1000) + 'k' : '?') + '</div></div>'
    : '<div class="marker ' + (sel ? 'on' : '') + '"><div class="pin ' + c + '"></div></div>';
  return L.divIcon({ className: '', html, iconSize: [0,0] });
}

function dpeBadge(v){
  const k = /^[A-G]$/.test(v || '') ? v : 'X';
  return '<span class="badge d' + k + '">' + (k === 'X' ? '?' : k) + '</span>';
}

/**
 * Nomme un lien d'après sa destination réelle. Un bouton « Annonce » qui mène
 * ailleurs qu'à une annonce est un piège : le libellé suit l'URL.
 */
function libelleLien(url, defaut){
  let hote;
  try { hote = new URL(url).hostname.replace(/^www\./, ''); } catch { return defaut; }
  if (hote.includes('leboncoin')) return 'Annonce leboncoin';
  if (hote.includes('seloger')) return 'Annonce SeLoger';
  if (hote.includes('bienici')) return "Annonce Bien'ici";
  if (hote.includes('logic-immo')) return 'Annonce Logic-Immo';
  if (hote.includes('lacquereur')) return 'Analyse';
  if (hote.includes('dvf')) return 'Vente DVF';
  if (hote.includes('geoportail')) return 'Cadastre';
  if (hote.includes('google')) return 'Maps';
  return defaut;
}

function corpsFiche(d){
  const rows = [];
  const push = (k, v) => { if (v) rows.push('<dt>' + k + '</dt><dd>' + v + '</dd>'); };
  push('Surface', d.s ? num(d.s) + ' m²' + (d.pc ? ' · ' + d.pc + ' pièces' : '') : null);
  push('Terrain', d.te ? num(d.te) + ' m²' : null);
  push('Adresse', d.ad
    ? esc(d.ad) + (d.cf ? ' <span style="color:var(--muted)">— confiance ' + esc(d.cf) + '</span>' : '')
    : (d.v ? esc(d.v) + ' — localisation approchée' : null));
  push('Parcelle', d.pcl
    ? '<span style="font-variant-numeric:tabular-nums">' + esc(d.pcl) + '</span>' +
      (d.ct ? ' <span style="color:var(--muted)">· ' + num(d.ct) + ' m² au cadastre</span>' : '')
    : null);
  push('DPE', d.dpe ? dpeBadge(d.dpe) + (d.ges ? ' &nbsp;GES ' + dpeBadge(d.ges) : '') : null);
  push('Construit en', d.an);
  if (d.ec != null) {
    const col = d.ec > 0 ? 'var(--red)' : 'var(--green)';
    push('Écart marché', '<b style="color:' + col + '">' + (d.ec > 0 ? '+' : '') + d.ec.toFixed(1) + ' %</b>' +
      (d.fb && d.fh ? ' <span style="color:var(--muted)">(' + eur(d.fb) + '–' + eur(d.fh) + ')</span>' : ''));
  }
  push('En ligne', d.j != null ? d.j + ' jours' + (d.nb ? ' · ' + d.nb + ' baisse' + (d.nb > 1 ? 's' : '') + (d.bp ? ' (−' + d.bp.toFixed(1) + ' %)' : '') : '') : null);
  push('Délai commune', d.dv ? d.dv + ' jours' : null);
  if (d.pa > 1) {
    const depuis = d.d1 ? Math.round((Date.now() - new Date(d.d1)) / 86400000) : null;
    push('Suivi', d.pa + ' parutions' + (depuis != null ? ' sur ' + depuis + ' jours' : '') +
      ' <span style="color:var(--muted)">— remis en ligne</span>');
  }
  if (d.pv) {
    const baisse = d.pv.apres < d.pv.avant;
    push('Dernier prix', '<span style="color:' + (baisse ? 'var(--green)' : 'var(--red)') + '">' +
      eur(d.pv.avant) + ' → ' + eur(d.pv.apres) + '</span>');
  }

  const links = [];
  const lien = (url, defaut) => '<a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer"' +
    ' title="' + esc(url) + '">' + esc(libelleLien(url, defaut)) + '</a>';
  if (d.ua) links.push(lien(d.ua, 'Annonce'));
  if (d.ul) links.push(lien(d.ul, 'Analyse'));
  if (d.um) links.push(lien(d.um, 'Maps'));

  return { rows: rows.join(''), links: links.join('') };
}

/** Bulle sur la carte : image, prix, caractéristiques, liens. */
function popup(d){
  const { rows, links } = corpsFiche(d);
  return '<div class="pop">' +
    (d.ph ? '<img src="' + esc(d.ph) + '" alt="" loading="lazy">' : '') +
    '<div class="body">' +
      '<h3>' + esc(d.t || 'Annonce ' + d.id) + '</h3>' +
      '<div class="p">' + eur(d.p) + (d.m2 ? '<small>' + num(d.m2) + ' €/m²</small>' : '') + '</div>' +
      '<dl>' + rows + '</dl>' +
      '<div class="links">' + links + '</div>' +
    '</div></div>';
}

/** Même contenu, déplié dans la liste : sur mobile la bulle masquerait la carte. */
function detailFiche(d){
  const { rows, links } = corpsFiche(d);
  return '<div class="pop"><dl>' + rows + '</dl><div class="links">' + links + '</div></div>';
}

function card(d){
  const tags =
    (d.st === 'nouveau' ? '<span class="tag new">nouveau</span>' : '') +
    (d.st === 'republie' ? '<span class="tag again">remis en ligne</span>' : '') +
    (d.pm === 'Sous le marché' ? '<span class="tag under">sous marché</span>' : '') +
    (d.pm === 'Au-dessus du marché' ? '<span class="tag over">au-dessus</span>' : '');
  const vignette = d.ph ? '<img src="' + esc(d.ph) + '" alt="" loading="lazy">'
    : AVEC_PHOTOS ? '<div class="noimg"></div>' : '';
  return '<article class="card" data-id="' + d.id + '" tabindex="0">' +
    '<div class="head">' + vignette +
    '<div><h3>' + esc(d.t || 'Annonce ' + d.id) + tags + '</h3>' +
    '<div class="meta">' + esc(d.v || '') + (d.cp ? ' · ' + esc(d.cp) : '') +
      (d.s ? ' · ' + num(d.s) + ' m²' : '') + (d.pc ? ' · ' + d.pc + ' p.' : '') + '</div>' +
    '<div class="price">' + eur(d.p) + (d.m2 ? ' <span class="meta">' + num(d.m2) + ' €/m²</span>' : '') + '</div>' +
    '</div></div></article>';
}

const F = { q:'', pmin:null, pmax:null, smin:null, smax:null, nw:false, again:false, under:false, drop:false, exact:false };

function matches(d){
  if (!AVEC_FILTRES) return true;
  if (F.q) {
    const hay = ((d.t || '') + ' ' + (d.v || '') + ' ' + (d.ad || '') + ' ' + (d.cp || '')).toLowerCase();
    if (!hay.includes(F.q)) return false;
  }
  if (F.pmin != null && (d.p == null || d.p < F.pmin)) return false;
  if (F.pmax != null && (d.p == null || d.p > F.pmax)) return false;
  if (F.smin != null && (d.s == null || d.s < F.smin)) return false;
  if (F.smax != null && (d.s == null || d.s > F.smax)) return false;
  if (F.nw && d.st !== 'nouveau') return false;
  if (F.again && d.st !== 'republie') return false;
  if (F.under && d.pm !== 'Sous le marché') return false;
  if (F.drop && !(d.nb > 0)) return false;
  if (F.exact && !d.pr) return false;
  return true;
}

function select(id, fly){
  if (selected && markers.has(selected)) {
    const p = markers.get(selected);
    p.m.setIcon(icon(p.d, false));
    if (p.parcelle) p.parcelle.setStyle({ color: '#3b6fb0', weight: 2.2, fillColor: '#5c86bd', fillOpacity: 0.18 });
  }
  selected = id;
  document.querySelectorAll('.card.sel').forEach(e => e.classList.remove('sel'));
  const el = document.querySelector('.card[data-id="' + id + '"]');
  if (el) { el.classList.add('sel'); amenerDansLaListe(el); }
  const entry = markers.get(id);
  if (entry) {
    entry.m.setIcon(icon(entry.d, true));
    if (entry.parcelle) {
      entry.parcelle.setStyle({ color: '#0f2742', weight: 3.5, fillColor: '#3b6fb0', fillOpacity: 0.38 });
      entry.parcelle.bringToFront();
    }
    // La bulle s'ancre au même point que la parcelle : sans décalage, elle la
    // recouvre. On la remonte de la demi-hauteur réelle du terrain à l'écran.
    const ouvrirBulle = () => {
      if (!entry.m.getPopup()) return;
      if (entry.parcelle) {
        const b = entry.parcelle.getBounds();
        const haut = map.latLngToContainerPoint(b.getNorthWest()).y;
        const bas = map.latLngToContainerPoint(b.getSouthEast()).y;
        // Demi-hauteur du terrain, plus la pointe de la bulle et une marge.
        entry.m.getPopup().options.offset = L.point(0, -(Math.abs(bas - haut) / 2 + 40));
      }
      entry.m.openPopup();
    };

    const mobile = MOBILE();
    if (mobile) {
      majDetail();
      // Laisser voir la carte : on n'ouvre le panneau qu'à mi-hauteur.
      if (position === 2) allerA(1);
    }

    if (fly) {
      const duree = DOUX ? .6 : 0;
      if (!mobile) map.once('moveend', ouvrirBulle);
      if (entry.parcelle) {
        map.flyToBounds(entry.parcelle.getBounds().pad(1.2), {
          duration: duree,
          maxZoom: 19,
          // Réserver la place de la bulle sur grand écran, celle du panneau sur mobile.
          paddingTopLeft: [20, mobile ? 20 : 360],
          paddingBottomRight: [20, mobile ? masqueBas() + 20 : 40],
        });
      } else {
        map.flyTo(entry.m.getLatLng(), Math.max(map.getZoom(), 17), { duration: duree });
      }
    } else if (!mobile) {
      ouvrirBulle();
    }
  }
}

/** Contour de la parcelle cadastrale du bien, en évidence quand il est choisi. */
function tracerParcelle(d, sel){
  if (!d.pg) return null;
  return L.polygon(d.pg.map(r => r.map(([x, y]) => [y, x])), {
    color: sel ? '#0f2742' : '#3b6fb0',
    weight: sel ? 3.5 : 2.2,
    fillColor: sel ? '#3b6fb0' : '#5c86bd',
    fillOpacity: sel ? 0.38 : 0.18,
    interactive: false,
  }).addTo(parcelles);
}

/**
 * Amène une fiche dans la partie visible de la liste. scrollIntoView ferait
 * défiler tous les ancêtres — y compris le corps de page, qui reste défilable
 * par programme même en overflow:hidden — et décalerait le panneau.
 */
function amenerDansLaListe(el){
  const liste = document.getElementById('list');
  const cible = el.offsetTop - 8;
  if (cible < liste.scrollTop || cible > liste.scrollTop + liste.clientHeight - el.offsetHeight) {
    liste.scrollTo({ top: cible, behavior: DOUX ? 'smooth' : 'auto' });
  }
}

/** Déplie le détail du bien choisi dans sa fiche de liste (mobile). */
function majDetail(){
  for (const e of document.querySelectorAll('.card .detail')) e.remove();
  if (!MOBILE() || !selected) return;
  const carte = document.querySelector('.card[data-id="' + selected + '"]');
  const entree = markers.get(selected);
  if (!carte || !entree) return;
  const bloc = document.createElement('div');
  bloc.className = 'detail';
  bloc.innerHTML = detailFiche(entree.d);
  carte.appendChild(bloc);
  amenerDansLaListe(carte);
}

function render(){
  layer.clearLayers();
  parcelles.clearLayers();
  markers.clear();
  const shown = DATA.filter(matches);
  shownCount = shown.length;
  showPills = pillsWanted();

  for (const d of shown) {
    const m = L.marker([d.la, d.lo], { icon: icon(d, false) })
      .on('click', () => select(d.id, MOBILE()));
    // Sur mobile la bulle recouvrirait la carte : le détail se déplie dans la liste.
    if (!MOBILE()) m.bindPopup(popup(d), { closeButton: true, autoPanPadding: [30, 30] });
    layer.addLayer(m);
    markers.set(d.id, { m, d, parcelle: tracerParcelle(d, false) });
  }

  const list = document.getElementById('list');
  list.innerHTML = shown.length
    ? shown.slice().sort((a,b) => (a.p ?? 1e12) - (b.p ?? 1e12)).map(card).join('')
    : '<div class="empty">Aucun bien ne correspond à ces filtres.</div>';
  list.querySelectorAll('.card').forEach(el =>
    el.addEventListener('click', () => select(el.dataset.id, true)));

  document.querySelector('#count span').textContent =
    shown.length + ' bien' + (shown.length > 1 ? 's' : '') + ' affiché' + (shown.length > 1 ? 's' : '') +
    ' sur ' + DATA.length;

  if (shown.length) {
    map.fitBounds(L.latLngBounds(shown.map(d => [d.la, d.lo])).pad(.15), {
      maxZoom: 15,
      paddingTopLeft: [20, 20],
      paddingBottomRight: [20, masqueBas() + 20],
    });
  }
  majDetail();
}

const numOrNull = v => v === '' || v == null ? null : Number(v);
const on = (id, ev, fn) => document.getElementById(id)?.addEventListener(ev, fn);

if (AVEC_FILTRES) {
  on('q', 'input', e => { F.q = e.target.value.trim().toLowerCase(); render(); });
  for (const [id, key] of [['pmin','pmin'],['pmax','pmax'],['smin','smin'],['smax','smax']]) {
    on(id, 'input', e => { F[key] = numOrNull(e.target.value); render(); });
  }
  for (const [id, key] of [['f-new','nw'],['f-again','again'],['f-under','under'],['f-drop','drop'],['f-exact','exact']]) {
    on(id, 'click', e => {
      F[key] = !F[key];
      e.currentTarget.setAttribute('aria-pressed', String(F[key]));
      render();
    });
  }
  on('reset', 'click', () => {
    Object.assign(F, { q:'', pmin:null, pmax:null, smin:null, smax:null, nw:false, again:false, under:false, drop:false, exact:false });
    document.querySelectorAll('.filters input').forEach(i => { i.value = ''; });
    document.querySelectorAll('.chip').forEach(c => c.setAttribute('aria-pressed','false'));
    render();
  });
}

// Quand les marqueurs deviennent nombreux ou la carte très dézoomée, les
// pastilles de prix se chevauchent : on bascule sur de simples points.
map.on('zoomend', () => {
  const want = pillsWanted();
  if (want !== showPills) {
    showPills = want;
    for (const [id, e] of markers) e.m.setIcon(icon(e.d, id === selected));
  }
});

// ── Panneau glissant (mobile) ────────────────────────────────────────────

const MOBILE = () => window.matchMedia('(max-width:820px)').matches;
const DOUX = !window.matchMedia('(prefers-reduced-motion:reduce)').matches;
const side = document.getElementById('side');
const poignee = document.getElementById('poignee');

/** Positions d'arrêt du panneau, du replié à l'ouvert. */
const arrets = () => {
  const h = side.offsetHeight;
  return [0, Math.round(h * 0.42), Math.round(h * 0.70)];
};
let position = 2; // replié au démarrage : la carte prime

function placerPanneau(px, anime = true) {
  side.classList.toggle('glisse', !anime);
  side.style.setProperty('--pos', px + 'px');
  side.classList.toggle('ouvert', px < arrets()[1]);
  poignee.setAttribute('aria-expanded', String(px < arrets()[2] - 4));
}

function allerA(i, anime = true) {
  const a = arrets();
  position = Math.max(0, Math.min(a.length - 1, i));
  placerPanneau(a[position], anime);
}

/** Hauteur de carte masquée par le panneau, pour ne rien cadrer dessous. */
function masqueBas() {
  if (!MOBILE()) return 0;
  const r = side.getBoundingClientRect();
  return Math.max(0, window.innerHeight - r.top);
}

if (poignee) {
  let depart = null;
  // Un glissement se termine par un clic synthétisé : sans ce drapeau, il
  // rebasculerait aussitôt le panneau.
  let aGlisse = false;
  const debut = (e) => {
    if (!MOBILE()) return;
    aGlisse = false;
    depart = { y: e.clientY, base: arrets()[position] };
    poignee.setPointerCapture?.(e.pointerId);
    side.classList.add('glisse');
  };
  const bouge = (e) => {
    if (!depart) return;
    e.preventDefault();
    if (Math.abs(e.clientY - depart.y) > 6) aGlisse = true;
    const a = arrets();
    placerPanneau(Math.max(0, Math.min(a[a.length - 1], depart.base + (e.clientY - depart.y))), false);
  };
  const fin = (e) => {
    if (!depart) return;
    const a = arrets();
    const y = Math.max(0, Math.min(a[a.length - 1], depart.base + (e.clientY - depart.y)));
    // On s'arrête au cran le plus proche.
    let proche = 0;
    for (let i = 1; i < a.length; i++) if (Math.abs(a[i] - y) < Math.abs(a[proche] - y)) proche = i;
    depart = null;
    allerA(proche);
  };
  poignee.addEventListener('pointerdown', debut);
  poignee.addEventListener('pointermove', bouge);
  poignee.addEventListener('pointerup', fin);
  poignee.addEventListener('pointercancel', fin);
  poignee.addEventListener('click', () => {
    if (aGlisse) { aGlisse = false; return; }
    if (!depart) allerA(position === 2 ? 1 : 2);
  });
  poignee.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); allerA(position === 2 ? 1 : 2); }
    if (e.key === 'ArrowUp') allerA(position - 1);
    if (e.key === 'ArrowDown') allerA(position + 1);
  });
}

on('voirtout', 'click', () => cadrerTout());

function cadrerTout() {
  const shown = DATA.filter(matches);
  if (!shown.length) return;
  map.fitBounds(L.latLngBounds(shown.map(d => [d.la, d.lo])).pad(.15), {
    maxZoom: 15,
    paddingBottomRight: [20, masqueBas() + 20],
    paddingTopLeft: [20, 20],
  });
}

window.matchMedia('(max-width:820px)').addEventListener('change', () => {
  render();
  if (MOBILE()) allerA(2, false); else side.style.removeProperty('--pos');
});
window.addEventListener('resize', () => { if (MOBILE()) allerA(position, false); });

render();
if (MOBILE()) allerA(2, false);
</script>
</body>
</html>`;

  fs.writeFileSync(file, html, 'utf8');
  return { file, plotted: points.length, skipped: sansCoords };
}
