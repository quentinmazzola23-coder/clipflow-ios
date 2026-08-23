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

// Orthophotographie de l'IGN : en prospection, on veut voir la maison, la cour,
// les dépendances et l'accès — pas un plan schématique.
const FOND_SATELLITE = `L.tileLayer(
  'https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0' +
  '&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&STYLE=normal&TILEMATRIXSET=PM&FORMAT=image/jpeg' +
  '&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}',
  { maxZoom: 21, maxNativeZoom: 19, attribution: 'Photographies aériennes &copy; IGN' }
).addTo(map);`;

/** Photo aérienne embarquée, pour la page autonome. */
const FOND_TUILES = `map.createPane('photo');
map.getPane('photo').style.zIndex = 250;
const imagesTuiles = BASEMAP.tuiles.images;
const CouchePhoto = L.GridLayer.extend({
  createTile(coords) {
    const img = document.createElement('img');
    const src = imagesTuiles[coords.z + '/' + coords.x + '/' + coords.y];
    // Sans dalle, on laisse voir le fond vectoriel plutôt qu'un carré vide.
    if (src) img.src = src; else img.style.display = 'none';
    img.width = img.height = 256;
    return img;
  },
});
new CouchePhoto({
  pane: 'photo',
  minZoom: BASEMAP.tuiles.zoomMin,
  maxNativeZoom: BASEMAP.tuiles.zoomMax,
  maxZoom: 21,
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
  L.polygon(versLatLng(poly), {
    renderer: renduCadastre, pane: 'tilePane', color: '#cfc8ba', weight: 0.7,
    fillColor: '#f6f3ec', fillOpacity: 1, interactive: false,
  }).addTo(cadastre);
}
for (const poly of (BASEMAP.cadastre?.batiments ?? [])) {
  L.polygon(versLatLng(poly), {
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
 * @param {'plan'|'satellite'} [opts.fond] Fond des cartes en ligne.
 */
export function writeMap(
  records,
  file,
  { title = 'Veille immobilière', note = null, basemap = null, filtres = true, fond = 'satellite' } = {}
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
      pcf: r.parcelleConfiance ?? null,
      pg: r.parcelleGeom ?? null,
      bg: r.batimentGeom ?? null,
      ct: r.contenance ?? null,
      la: r.latitude,
      lo: r.longitude,
      dpe: r.dpe,
      ges: r.ges,
      an: r.anneeConstruction,
      j: r.joursEnLigne,
      jm: !!r.ancienneteMinorant,
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
#legende{display:flex;gap:10px;flex-wrap:wrap;padding:9px 18px;border-bottom:1px solid var(--line);font-size:11.5px;color:var(--muted)}
#legende span{display:flex;align-items:center;gap:5px}
#legende i{width:10px;height:10px;border-radius:50%;display:inline-block}
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
.card .corps{min-width:0;flex:1}
.card .ligne1{display:flex;align-items:baseline;gap:8px;font-variant-numeric:tabular-nums}
.card .prix{font-size:16px;font-weight:700;letter-spacing:-.02em}
.card .m2{font-size:12px;color:var(--muted)}
.age{color:#fff;padding:1px 7px;border-radius:999px;font-size:12px}
.card .jours{margin-left:auto;color:#fff;font-size:11.5px;font-weight:650;padding:2px 8px;border-radius:999px;white-space:nowrap}
.card .meta{font-size:12px;color:var(--muted);margin-top:2px}
.card h3{margin:3px 0 0;font-size:12.5px;font-weight:500;color:var(--muted);line-height:1.3;display:-webkit-box;-webkit-line-clamp:1;-webkit-box-orient:vertical;overflow:hidden}
.card.contacte{opacity:.55}
.card.contacte .prix{text-decoration:line-through;text-decoration-thickness:1px}
.card.ecarte{opacity:.35}
.suivi{display:flex;gap:6px;margin-top:10px}
.suivi button{flex:1;border:1px solid var(--line);background:#fff;border-radius:8px;padding:7px 6px;font:inherit;font-size:12px;cursor:pointer;color:var(--muted)}
.suivi button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff}
.pop .prospecter{display:block;text-align:center;background:var(--accent);color:#fff;border-radius:9px;padding:10px;font-size:13px;font-weight:600;text-decoration:none;margin-top:11px}
.pop .prospecter:hover{opacity:.9}
.tag{display:inline-block;font-size:11px;padding:1px 6px;border-radius:5px;margin-left:5px;vertical-align:1px}
.tag.new{background:#fff3d6;color:var(--amber)}
.tag.again{background:#e8eefb;color:#0b57d0}
.tag.under{background:#e3f4ea;color:var(--green)}
.tag.over{background:#fdeceb;color:var(--red)}
.marker{position:absolute;left:0;top:0;width:max-content;transform:translate(-50%,-50%)}
.pin{width:13px;height:13px;border-radius:50%;border:2.5px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)}
.pill{width:max-content;white-space:nowrap;color:#fff;font-size:11.5px;font-weight:650;padding:3px 8px;border-radius:999px;border:1.5px solid #fff;box-shadow:0 1px 5px rgba(0,0,0,.35)}
.marker.on{outline:3px solid rgba(31,58,95,.35);outline-offset:2px;border-radius:999px}
.j0{background:#8b9099} .j1{background:#4a7fb5} .j2{background:#c08a2e} .j3{background:#c25a1e} .j4{background:#b3261e}
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
    <div id="legende"></div>
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
const ATTRIBUTION = ${escapeJson(
  basemap?.attribution ?? (fond === 'satellite' ? 'Photographies aériennes © IGN' : '© OpenStreetMap')
)};
const BASEMAP = ${basemap ? escapeJson(basemap) : 'null'};

const eur = n => n == null ? '—' : new Intl.NumberFormat('fr-FR').format(Math.round(n)) + ' €';
const num = n => n == null ? '—' : new Intl.NumberFormat('fr-FR').format(n);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

/**
 * Couleur par ancienneté de l'annonce. En prospection, c'est le temps passé
 * en vitrine qui dit la disponibilité du vendeur, pas l'écart de prix.
 */
const PALIERS = [
  { min: 240, cle: 'j4', texte: '8 mois et plus' },
  { min: 120, cle: 'j3', texte: '4 à 8 mois' },
  { min: 60,  cle: 'j2', texte: '2 à 4 mois' },
  { min: 0,   cle: 'j1', texte: 'moins de 2 mois' },
];
function tone(d){
  if (d.j == null) return 'j0';
  return (PALIERS.find(p => d.j >= p.min) ?? PALIERS[PALIERS.length - 1]).cle;
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

/** GeoJSON [lon, lat] → Leaflet [lat, lon], en conservant trous et multi-parties. */
const versLatLng = (geom) => geom.map((poly) => poly.map((anneau) => anneau.map(([x, y]) => [y, x])));

// minZoom explicite : sans lui, Leaflet adopte celui de la couche la plus
// restrictive — la photo embarquée — et la carte refuse de dézoomer.
const map = L.map('map', { zoomControl: true, scrollWheelZoom: true, minZoom: 5, maxZoom: 21 });
// Vue initiale posée avant toute couche : Leaflet exige un centre pour projeter.
map.setView([46.6, 2.4], 6);

document.getElementById('legende').innerHTML =
  '<span style="color:var(--ink);font-weight:600">Ancienneté</span>' +
  PALIERS.slice().reverse().map(p => '<span><i class="' + p.cle + '"></i>' + p.texte + '</span>').join('');

${basemap ? FOND_VECTORIEL : fond === 'satellite' ? FOND_SATELLITE : FOND_OSM}
${basemap?.cadastre ? FOND_CADASTRE : ''}
${basemap?.tuiles ? FOND_TUILES : ''}

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

  push('En ligne', d.j != null
    ? '<b class="age ' + tone(d) + '">' + (d.jm ? 'au moins ' : '') + d.j + ' jours</b>' +
      (d.nb ? ' <span style="color:var(--muted)">· prix baissé</span>' : '')
    : null);
  push('Adresse', d.ad
    ? esc(d.ad) + (d.cf ? ' <span style="color:var(--muted)">— confiance ' + esc(d.cf) + '</span>' : '')
    : (d.v ? esc(d.v) + ' — localisation approchée' : null));
  push('Bien', [
    d.s ? num(d.s) + ' m²' : null,
    d.pc ? d.pc + ' pièces' : null,
    d.te ? 'terrain ' + num(d.te) + ' m²' : null,
  ].filter(Boolean).join(' · ') || null);
  push('Parcelle', d.pcl
    ? '<span style="font-variant-numeric:tabular-nums">' + esc(d.pcl) + '</span>' +
      (d.ct ? ' <span style="color:var(--muted)">· ' + num(d.ct) + ' m²</span>' : '') +
      (d.pcf === 'moyenne' || d.pcf === 'faible'
        ? ' <span style="color:var(--amber)">· à confirmer</span>' : '')
    : null);
  if (d.ec != null && Math.abs(d.ec) <= 120) {
    const col = d.ec > 0 ? 'var(--red)' : 'var(--green)';
    push('Face au marché', '<b style="color:' + col + '">' + (d.ec > 0 ? '+' : '') + d.ec.toFixed(0) + ' %</b>');
  } else if (d.ec != null) {
    push('Face au marché', '<span style="color:var(--muted)">bien atypique, hors comparaison communale</span>');
  }
  if (d.dpe) push('DPE', dpeBadge(d.dpe) + (d.ges ? ' &nbsp;GES ' + dpeBadge(d.ges) : ''));

  const liens = [];
  const lien = (url, defaut) => '<a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer"' +
    ' title="' + esc(url) + '">' + esc(libelleLien(url, defaut)) + '</a>';
  if (d.um) liens.push(lien(d.um, 'Maps'));
  if (d.ul) liens.push(lien(d.ul, 'Analyse'));

  const action = d.ua
    ? '<a class="prospecter" href="' + esc(d.ua) + '" target="_blank" rel="noopener noreferrer">' +
      'Ouvrir l’annonce · ' + esc(libelleLien(d.ua, 'source').replace(/^Annonce /, '')) + '</a>'
    : '';

  return { rows: rows.join(''), links: liens.join(''), action };
}

/** Bulle sur la carte : image, prix, caractéristiques, liens. */
function popup(d){
  const { rows, links, action } = corpsFiche(d);
  return '<div class="pop">' +
    (d.ph ? '<img src="' + esc(d.ph) + '" alt="" loading="lazy">' : '') +
    '<div class="body">' +
      '<div class="p">' + eur(d.p) + (d.m2 ? '<small>' + num(d.m2) + ' €/m²</small>' : '') + '</div>' +
      '<dl>' + rows + '</dl>' +
      action +
      '<div class="links">' + links + '</div>' +
      boutonsSuivi(d.id) +
    '</div></div>';
}

/** Boutons de suivi : où en est-on de la prospection de ce bien. */
function boutonsSuivi(id){
  const actuel = statut(id);
  return '<div class="suivi" data-suivi="' + id + '">' +
    ['afaire', 'contacte', 'ecarte'].map((v) =>
      '<button type="button" data-valeur="' + v + '" aria-pressed="' + (actuel === v) + '">' +
      LIBELLE_STATUT[v] + '</button>').join('') +
    '</div>';
}

/** Même contenu, déplié dans la liste : sur mobile la bulle masquerait la carte. */
function detailFiche(d){
  const { rows, links, action } = corpsFiche(d);
  return '<div class="pop"><dl>' + rows + '</dl>' + action +
    '<div class="links">' + links + '</div>' + boutonsSuivi(d.id) + '</div>';
}

function card(d){
  const st = statut(d.id);
  const comparable = d.ec == null || Math.abs(d.ec) <= 120;
  const tags =
    (comparable && d.pm === 'Sous le marché' ? '<span class="tag under">sous marché</span>' : '') +
    (comparable && d.pm === 'Au-dessus du marché' ? '<span class="tag over">au-dessus</span>' : '') +
    (d.st === 'republie' ? '<span class="tag again">remis en ligne</span>' : '');

  const vignette = d.ph ? '<img src="' + esc(d.ph) + '" alt="" loading="lazy">'
    : AVEC_PHOTOS ? '<div class="noimg"></div>' : '';

  return '<article class="card' + (st !== 'afaire' ? ' ' + st : '') + '" data-id="' + d.id + '" tabindex="0">' +
    '<div class="head">' + vignette +
    '<div class="corps">' +
      '<div class="ligne1">' +
        '<span class="prix">' + eur(d.p) + '</span>' +
        (d.m2 ? '<span class="m2">' + num(d.m2) + ' €/m²</span>' : '') +
        '<span class="jours ' + tone(d) + '">' + (d.j != null ? (d.jm ? '≥ ' : '') + d.j + ' j' : '?') + '</span>' +
      '</div>' +
      '<div class="meta">' + esc(d.v || '') +
        (d.s ? ' · ' + num(d.s) + ' m²' : '') + (d.pc ? ' · ' + d.pc + ' p.' : '') +
        (d.te ? ' · terrain ' + num(d.te) + ' m²' : '') + '</div>' +
      '<h3>' + esc(d.t || 'Annonce ' + d.id) + tags + '</h3>' +
    '</div></div></article>';
}

// ── Suivi de prospection ──────────────────────────────────────────────────
// Conservé dans le navigateur : la carte se régénère chaque matin, le suivi
// des contacts, lui, doit survivre.
const CLE_SUIVI = 'carto-immo:suivi';
let suivi = {};
try { suivi = JSON.parse(localStorage.getItem(CLE_SUIVI) || '{}'); } catch { suivi = {}; }

const statut = (id) => suivi[id] ?? 'afaire';
const LIBELLE_STATUT = { afaire: 'À prospecter', contacte: 'Contacté', ecarte: 'Écarté' };

function definirStatut(id, valeur){
  if (valeur === 'afaire') delete suivi[id]; else suivi[id] = valeur;
  try { localStorage.setItem(CLE_SUIVI, JSON.stringify(suivi)); } catch { /* navigation privée */ }
  render();
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

function select(id, fly, { bulleDejaGeree = false } = {}){
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
    const decalerBulle = () => {
      const bulle = entry.m.getPopup();
      if (!bulle || !entry.parcelle) return;
      const b = entry.parcelle.getBounds();
      const haut = map.latLngToContainerPoint(b.getNorthWest()).y;
      const bas = map.latLngToContainerPoint(b.getSouthEast()).y;
      // Demi-hauteur du terrain, plus la pointe de la bulle et une marge.
      bulle.options.offset = L.point(0, -(Math.abs(bas - haut) / 2 + 40));
      if (entry.m.isPopupOpen()) entry.m.openPopup(); // réapplique le décalage
    };
    const ouvrirBulle = () => {
      if (!entry.m.getPopup()) return;
      decalerBulle();
      entry.m.openPopup();
    };

    const mobile = MOBILE();
    if (mobile) {
      majDetail();
      // Laisser voir la carte : on n'ouvre le panneau qu'à mi-hauteur.
      if (position === 2) allerA(1);
    }

    if (fly) {
      // Leaflet ignore duration:0 et anime quand même : sans mouvement voulu,
      // on se pose directement.
      const anime = DOUX;
      const duree = .6;
      if (!mobile) map.once('moveend', ouvrirBulle);
      const bornes = entry.parcelle?.getBounds();
      if (bornes && mobile) {
        // La bande de carte laissée par le panneau est trop courte pour un
        // cadrage classique : on fixe le zoom, puis on décale le centre pour
        // que la parcelle se pose dans la partie visible.
        const zoom = Math.max(17, Math.min(19, map.getBoundsZoom(bornes.pad(0.4), true)));
        const pt = map.project(bornes.getCenter(), zoom);
        pt.y += masqueBas() / 2;
        const centre = map.unproject(pt, zoom);
        if (anime) map.flyTo(centre, zoom, { duration: duree });
        else map.setView(centre, zoom, { animate: false });
      } else if (bornes) {
        const cadrage = {
          maxZoom: 19,
          // Réserver la place de la bulle, qui s'ouvre au-dessus du point.
          paddingTopLeft: [20, 360],
          paddingBottomRight: [20, 40],
        };
        if (anime) map.flyToBounds(bornes.pad(1.2), { ...cadrage, duration: duree });
        else map.fitBounds(bornes.pad(1.2), { ...cadrage, animate: false });
      } else {
        const z = Math.max(map.getZoom(), 17);
        if (anime) map.flyTo(entry.m.getLatLng(), z, { duration: duree });
        else map.setView(entry.m.getLatLng(), z, { animate: false });
      }
    } else if (!mobile && !bulleDejaGeree) {
      ouvrirBulle();
    } else if (!mobile) {
      // Bulle ouverte par Leaflet : on n'a plus qu'à la décaler de la parcelle.
      decalerBulle();
    }
  }
}

/** Contour de la parcelle cadastrale du bien, en évidence quand il est choisi. */
function tracerParcelle(d, sel){
  if (!d.pg) return null;
  if (d.bg) {
    L.polygon(versLatLng(d.bg), {
      color: '#0f2742', weight: 1.2, fillColor: '#0f2742', fillOpacity: .18, interactive: false,
    }).addTo(parcelles);
  }
  return L.polygon(versLatLng(d.pg), {
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
  // offsetTop se compte depuis le premier ancêtre positionné, qui n'est pas la
  // liste : on mesure la position réelle de la fiche dans son conteneur.
  const haut = el.getBoundingClientRect().top - liste.getBoundingClientRect().top + liste.scrollTop;
  const bas = haut + el.offsetHeight;
  if (haut < liste.scrollTop || bas > liste.scrollTop + liste.clientHeight) {
    liste.scrollTo({ top: Math.max(0, haut - 8), behavior: DOUX ? 'smooth' : 'auto' });
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

/**
 * Ordre de prospection : les biens traités passent en fin de liste, puis les
 * plus anciens d'abord — ce sont eux dont le vendeur est le plus disponible.
 */
function ordreProspection(a, b){
  const rang = { afaire: 0, contacte: 1, ecarte: 2 };
  const ra = rang[statut(a.id)] - rang[statut(b.id)];
  if (ra) return ra;
  return (b.j ?? -1) - (a.j ?? -1);
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
      // Leaflet bascule lui-même la bulle au clic : on sélectionne sans la
      // rouvrir, sinon elle se referme aussitôt.
      .on('click', () => select(d.id, MOBILE(), { bulleDejaGeree: !MOBILE() }));
    // Sur mobile la bulle recouvrirait la carte : le détail se déplie dans la liste.
    if (!MOBILE()) m.bindPopup(popup(d), { closeButton: true, autoPanPadding: [30, 30] });
    layer.addLayer(m);
    markers.set(d.id, { m, d, parcelle: tracerParcelle(d, false) });
  }

  const list = document.getElementById('list');
  list.innerHTML = shown.length
    ? shown.slice().sort(ordreProspection).map(card).join('')
    : '<div class="empty">Aucun bien ne correspond à ces filtres.</div>';
  for (const el of list.querySelectorAll('.card')) {
    el.addEventListener('click', () => select(el.dataset.id, true));
    // Les fiches sont focalisables : elles doivent s'activer au clavier.
    el.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(el.dataset.id, true); }
    });
  }

  // Un re-rendu reconstruit tout en état neutre : on rétablit la sélection.
  if (selected && markers.has(selected)) {
    const e = markers.get(selected);
    e.m.setIcon(icon(e.d, true));
    if (e.parcelle) e.parcelle.setStyle({ color: '#0f2742', weight: 3.5, fillColor: '#3b6fb0', fillOpacity: 0.38 });
    document.querySelector('.card[data-id="' + selected + '"]')?.classList.add('sel');
  } else if (selected) {
    selected = null;
  }

  const restants = shown.filter(d => statut(d.id) === 'afaire').length;
  const traites = shown.length - restants;
  document.querySelector('#count span').textContent =
    restants + ' à prospecter' +
    (traites ? ' · ' + traites + ' traités' : '') +
    (shown.length !== DATA.length ? ' · ' + shown.length + '/' + DATA.length + ' affichés' : '');



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

// Délégation au document : les boutons de la bulle naissent après le rendu,
// un écouteur posé sur les blocs existants ne les verrait jamais.
document.addEventListener('click', (e) => {
  const bouton = e.target.closest('.suivi button[data-valeur]');
  if (!bouton) return;
  const bloc = bouton.closest('[data-suivi]');
  if (!bloc) return;
  e.stopPropagation();
  e.preventDefault();
  definirStatut(bloc.dataset.suivi, bouton.dataset.valeur);
});

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
