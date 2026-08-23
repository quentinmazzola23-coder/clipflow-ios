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
//
// Deux couches empilées. Le socle s'arrête au niveau que l'IGN sert partout ;
// la couche fine va chercher le niveau le plus profond et demande ses dalles un
// cran plus bas pour les dessiner deux fois plus petites — deux fois plus de
// pixels à l'écran, là où la matière existe. Une dalle fine manquante laisse
// voir le socle plutôt qu'un carré vide.
const URL_ORTHO =
  "'https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0' +\n" +
  "  '&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&STYLE=normal&TILEMATRIXSET=PM&FORMAT=image/jpeg' +\n" +
  "  '&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}'";

const FOND_SATELLITE = `const PIXEL_VIDE =
  'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';

L.tileLayer(
  ${URL_ORTHO},
  {
    maxZoom: 22, maxNativeZoom: 19, zIndex: 1,
    attribution: 'Photographies aériennes &copy; IGN',
  }
).addTo(map);

// Quatre fois plus de dalles : on ne l'allume qu'au zoom où l'on regarde
// vraiment un bien, pas pendant qu'on survole le département.
const ZOOM_DETAIL = 16;
const detail = L.tileLayer(
  ${URL_ORTHO},
  {
    maxZoom: 22, maxNativeZoom: 20, zIndex: 2,
    tileSize: 128, zoomOffset: 1,
    errorTileUrl: PIXEL_VIDE,
    updateWhenIdle: true,
  }
);
function majDetail_() {
  const veut = map.getZoom() >= ZOOM_DETAIL;
  if (veut && !map.hasLayer(detail)) detail.addTo(map);
  else if (!veut && map.hasLayer(detail)) map.removeLayer(detail);
}
map.on('zoomend', majDetail_);
majDetail_();`;

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
  maxZoom: 22,
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
 * @param {{i:string,g:number[][][][],c:number[],s:number}[]} [opts.voisinage]
 *   Parcelles voisines référencées, pour désigner soi-même la bonne quand le
 *   rapprochement automatique s'est trompé.
 * @param {{n:string,c:string,g:number[][][][]}[]} [opts.communes] Contours des
 *   communes, pour reconnaître au clic celle qu'on veut faire analyser.
 * @param {object} [opts.bilan] Compte rendu de la localisation : relevées,
 *   tentées, réussies, et la raison de chaque renoncement.
 */
export function writeMap(
  records,
  file,
  {
    title = 'Veille immobilière', note = null, basemap = null, filtres = true, fond = 'satellite',
    voisinage = null, communes = null, bilan = null,
  } = {}
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
      pcs: r.parcelleSource ?? null,
      pcm: r.parcelleMotif ?? null,
      pg: r.parcelleGeom ?? null,
      bg: r.batimentGeom ?? null,
      ct: r.contenance ?? null,
      la: r.latitude,
      lo: r.longitude,
      ins: r.codeInsee ?? null,
      // Pièces du dossier : de quoi vérifier le rapprochement, et le refaire.
      nd: r.numeroDpe ?? null,
      no: r.confianceAdresse ?? null,
      e2: r.ecartSecond ?? null,
      qg: r.qualiteGeocodage ?? null,
      df: r.distanceFlouM ?? null,
      mo: r.motifsLocalisation ?? [],
      alt: (r.dpeAlternatives ?? []).map((a) => ({
        nd: a.numeroDpe, ad: a.adresse, la: a.latitude, lo: a.longitude,
        no: a.note, cf: a.confiance, s: a.surfaceDpe, df: a.distanceFlouM,
      })),
      rc: r.recalage ?? null,
      au: r.auto ? {
        la: r.auto.latitude, lo: r.auto.longitude,
        pcl: r.auto.parcelle, ad: r.auto.adresse, cf: r.auto.niveauConfiance,
      } : null,
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
      phs: (r.photos ?? []).slice(0, 8),
      ua: r.urlAnnonce,
      ul: r.urlAnalyse,
      um: r.urlMaps,
    }));

  // En mode autonome la page ne doit émettre aucune requête : les photos, qui
  // sont hébergées par le site d'annonces, laisseraient des cadres vides.
  // Une page autonome ne doit émettre aucune requête : les photos hébergées par
  // le site d'annonces laisseraient des cadres vides. Celles déjà embarquées en
  // data-URI, elles, restent — c'est justement ce qui permet de comparer
  // l'annonce à la vue du ciel hors ligne.
  const embarquee = (u) => typeof u === 'string' && u.startsWith('data:');
  if (basemap) {
    for (const p of points) {
      p.phs = (p.phs ?? []).filter(embarquee);
      if (!embarquee(p.ph)) p.ph = p.phs[0] ?? null;
    }
  }

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
/* Prix au-dessus, point sur l'emplacement exact : au zoom parcelle, la
   pastille ne doit plus recouvrir le terrain. */
.marker.haut{display:flex;flex-direction:column;align-items:center;gap:3px;transform:translate(-50%,calc(-100% + 9px))}
.pin{width:13px;height:13px;border-radius:50%;border:2.5px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)}
.pill{width:max-content;white-space:nowrap;color:#fff;font-size:11.5px;font-weight:650;padding:3px 8px;border-radius:999px;border:1.5px solid #fff;box-shadow:0 1px 5px rgba(0,0,0,.35)}
.marker.on{outline:3px solid rgba(31,58,95,.35);outline-offset:2px;border-radius:999px}
.j0{background:#8b9099} .j1{background:#4a7fb5} .j2{background:#c08a2e} .j3{background:#c25a1e} .j4{background:#b3261e}
.leaflet-popup.deportee .leaflet-popup-tip-container{display:none}
.leaflet-popup-content{margin:0;width:296px!important;max-height:min(78vh,620px);overflow-y:auto;overscroll-behavior:contain}
.leaflet-popup-content-wrapper{border-radius:12px;padding:0;overflow:hidden}
.pop img{width:100%;height:132px;object-fit:cover;display:block;background:#e9e7e1}
.galerie{position:relative;background:#e9e7e1;line-height:0}
.galerie img{image-rendering:auto}
.galerie .fleche{position:absolute;top:50%;transform:translateY(-50%);width:30px;height:30px;border:none;border-radius:50%;background:rgba(21,23,28,.55);color:#fff;font-size:15px;line-height:30px;text-align:center;cursor:pointer;padding:0;opacity:.9}
.galerie .fleche:hover{background:rgba(21,23,28,.8)}
.galerie .prec{left:7px}
.galerie .suiv{right:7px}
.galerie .pleine{display:block;line-height:0}
.galerie .rang{position:absolute;right:8px;bottom:7px;background:rgba(21,23,28,.6);color:#fff;font-size:11px;padding:1px 7px;border-radius:999px;line-height:1.6;font-variant-numeric:tabular-nums}
.card .detail .galerie img{height:150px}
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
#bilan{border-bottom:1px solid var(--line);font-size:12.5px}
#bilan[hidden]{display:none}
#bilan summary{padding:10px 18px;cursor:pointer;list-style:none;display:flex;align-items:baseline;gap:8px}
#bilan summary::-webkit-details-marker{display:none}
#bilan summary::after{content:'▾';margin-left:auto;color:var(--muted);font-size:11px}
#bilan[open] summary::after{content:'▴'}
#bilan .taux{font-weight:700;font-variant-numeric:tabular-nums}
#bilan .resume{color:var(--muted)}
#bilan .corps{padding:0 18px 12px}
#bilan .barre{display:flex;height:7px;border-radius:4px;overflow:hidden;background:var(--line);margin-bottom:9px}
#bilan .barre i{display:block;height:100%}
#bilan .barre .place{background:var(--green)}
#bilan .barre .rate{background:#c9a227}
#bilan .barre .hors{background:#c4c0b8}
#bilan dl{display:grid;grid-template-columns:auto 1fr;gap:2px 10px;margin:0 0 9px}
#bilan dt{font-variant-numeric:tabular-nums;font-weight:600;text-align:right}
#bilan dd{margin:0;color:var(--muted)}
#bilan .motifs{margin:0;padding:0;list-style:none;border-top:1px solid var(--line);padding-top:8px}
#bilan .motifs li{display:flex;gap:9px;padding:2px 0;color:var(--muted)}
#bilan .motifs b{min-width:2.2em;text-align:right;color:var(--ink);font-variant-numeric:tabular-nums}
#bilan .zones{margin:8px 0 0;color:var(--muted);font-size:11.5px;line-height:1.5}
#bilan .parcommune{width:100%;border-collapse:collapse;margin-top:10px;font-size:11.5px;font-variant-numeric:tabular-nums}
#bilan .parcommune caption{text-align:left;color:var(--ink);font-weight:600;font-size:12px;padding-bottom:4px}
#bilan .parcommune th[scope=col]{color:var(--muted);font-weight:500;text-align:right;padding:3px 0 5px;border-bottom:1px solid var(--line)}
#bilan .parcommune th[scope=col]:first-child{text-align:left}
#bilan .parcommune th[scope=row]{font-weight:500;text-align:left;padding:3px 8px 3px 0}
#bilan .parcommune td{text-align:right;padding:3px 0;color:var(--muted)}
#bilan .parcommune tbody tr:nth-child(even){background:rgba(0,0,0,.02)}
.empty{padding:34px 18px;text-align:center;color:var(--muted);font-size:13px}
.verif{margin-top:11px;padding-top:10px;border-top:1px dashed var(--line);font-size:12px;color:var(--muted)}
.verif b{color:var(--ink);font-weight:600}
.verif .preuves{margin:3px 0 0;line-height:1.5}
.verif button{margin-top:8px;width:100%;border:1px solid var(--line);background:#fff;border-radius:8px;padding:7px;font:inherit;font-size:12px;cursor:pointer;color:var(--accent)}
.verif button:hover{background:#f2f5f9}
.marque{display:inline-block;font-size:10.5px;letter-spacing:.03em;text-transform:uppercase;padding:1px 6px;border-radius:5px;background:#f4f1ea;color:var(--muted);margin-left:5px}
.marque.rec{background:#e3f4ea;color:var(--green)}
.marque.doute{background:#fdf1dc;color:var(--amber)}
#recal{position:absolute;right:14px;top:14px;width:322px;max-width:calc(100% - 28px);max-height:calc(100% - 28px);overflow:auto;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:0 8px 30px rgba(0,0,0,.18);z-index:1200;padding:13px 14px;font-size:12.5px;display:none}
#recal.on{display:block}
#recal h2{margin:0 0 3px;font-size:13.5px}
#recal .ferme{position:absolute;right:9px;top:8px;border:none;background:none;font-size:17px;line-height:1;cursor:pointer;color:var(--muted)}
#recal dl{margin:8px 0 0;display:grid;grid-template-columns:auto 1fr;gap:3px 10px}
#recal dt{color:var(--muted)}
#recal dd{margin:0;font-variant-numeric:tabular-nums}
#recal .actions2{display:flex;gap:7px;margin-top:11px}
#recal .actions2 button{flex:1;border:1px solid var(--line);background:#fff;border-radius:8px;padding:8px 6px;font:inherit;font-size:12px;cursor:pointer;color:var(--accent)}
#recal .actions2 button[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff}
#recal .cands{margin-top:11px;border-top:1px solid var(--line);padding-top:9px}
#recal .cand{display:flex;gap:8px;align-items:baseline;padding:6px 0;border-bottom:1px solid var(--line)}
#recal .cand:last-child{border-bottom:none}
#recal .cand span{flex:1;min-width:0}
#recal .cand button{border:1px solid var(--line);background:#fff;border-radius:7px;padding:4px 9px;font:inherit;font-size:11.5px;cursor:pointer;color:var(--accent)}
#recal .annuler{margin-top:11px;width:100%;border:1px solid var(--line);background:#fff;border-radius:8px;padding:8px;font:inherit;font-size:12px;cursor:pointer;color:var(--red)}
#recal .aide{margin:9px 0 0;padding:7px 9px;border-radius:7px;background:#fdf1dc;color:var(--amber);line-height:1.45}
#map.viser{cursor:crosshair}
#travaux{position:absolute;left:50%;top:14px;transform:translateX(-50%);z-index:1200;background:var(--panel);border:1px solid var(--line);border-radius:11px;box-shadow:0 6px 24px rgba(0,0,0,.18);padding:11px 15px;font-size:12.5px;max-width:min(420px,calc(100% - 28px));display:none}
#travaux.on{display:block}
#travaux .lignes{margin-top:6px;color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;line-height:1.5;max-height:120px;overflow:auto;white-space:pre-wrap}
.zonepop b{display:block;font-size:13.5px;margin-bottom:2px}
.zonepop button{margin-top:8px;width:100%;border:none;background:var(--accent);color:#fff;border-radius:8px;padding:8px;font:inherit;font-size:12.5px;font-weight:600;cursor:pointer}
.zonepop code{display:block;margin-top:7px;padding:7px 8px;background:#f4f1ea;border-radius:7px;font-size:11px;word-break:break-all;user-select:all}
.zonepop .quoi{color:var(--muted);font-size:11.5px;margin-top:4px;line-height:1.45}
.zonepop .chiffre{color:var(--ink);font-variant-numeric:tabular-nums}
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
    <details id="bilan"></details>
    <div id="legende"></div>
    <div id="count"><span></span><span class="actions"><button id="corrections" hidden></button><button id="voirtout">Tout voir</button>${filtres ? '<button id="reset">Réinitialiser</button>' : ''}</span></div>
    <div id="list"></div>
    <p id="credits"></p>
  </aside>
  <div id="map"></div>
  <div id="recal" role="dialog" aria-label="Recaler ce bien" aria-modal="false"></div>
  <div id="travaux" role="status" aria-live="polite"></div>
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
const BILAN = ${bilan ? escapeJson(bilan) : 'null'};
// Parcelles voisines référencées : de quoi désigner la bonne à la main.
const VOISINAGE = ${voisinage?.length ? escapeJson(voisinage) : '[]'};
// Contours de communes, pour reconnaître au clic celle qu'on veut faire analyser.
const COMMUNES = ${communes?.length ? escapeJson(communes) : basemap?.communes ? '(BASEMAP.communes || [])' : '[]'};

const eur = n => n == null ? '—' : new Intl.NumberFormat('fr-FR').format(Math.round(n)) + ' €';
const num = n => n == null ? '—' : new Intl.NumberFormat('fr-FR').format(n);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const parId = new Map(DATA.map(d => [String(d.id), d]));

/**
 * La même image, en deux fois plus léger. On ne vient pas admirer la maison
 * mais la reconnaître sur la photo aérienne : la silhouette du bâti, la cour,
 * l'accès. La miniature suffit, et la bulle s'ouvre sans attendre.
 */
function basseQualite(url){
  // Les hébergeurs d'annonces encodent la taille dans le chemin (…/590x330/…).
  const bouts = String(url).split('/');
  for (let i = 0; i < bouts.length; i++) {
    const x = bouts[i].indexOf('x');
    if (x <= 0) continue;
    const w = Number(bouts[i].slice(0, x)), h = Number(bouts[i].slice(x + 1));
    if (!Number.isInteger(w) || !Number.isInteger(h) || w < 240 || h < 160) continue;
    bouts[i] = Math.round(w / 2) + 'x' + Math.round(h / 2);
    return bouts.join('/');
  }
  return String(url);
}

const photosDe = (d) => (d && d.phs && d.phs.length ? d.phs : d && d.ph ? [d.ph] : []);

/** Bandeau de photos, feuilletable : comparer l'annonce à ce qu'on voit du ciel. */
function galerie(d){
  const photos = photosDe(d);
  if (!photos.length) return '';
  const n = photos.length;
  // La miniature suffit à comparer ; le lien reste ouvert vers l'original pour
  // le détail qui fait douter.
  return '<div class="galerie" data-gal="' + esc(d.id) + '" data-i="0">' +
    '<a class="pleine" href="' + esc(photos[0]) + '" target="_blank" rel="noopener noreferrer"' +
    ' title="Ouvrir la photo en pleine définition">' +
    '<img src="' + esc(basseQualite(photos[0])) + '" alt="Photo de l\u2019annonce" loading="lazy" decoding="async">' +
    '</a>' +
    (n > 1
      ? '<button type="button" class="fleche prec" data-pas="-1" aria-label="Photo pr\u00e9c\u00e9dente">\u2039</button>' +
        '<button type="button" class="fleche suiv" data-pas="1" aria-label="Photo suivante">\u203a</button>' +
        '<span class="rang">1/' + n + '</span>'
      : '') +
    '</div>';
}

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

/**
 * Ce qu'on sait d'une commune : ce qui y a été vu, et ce qui y a été placé.
 *
 * Deux comptes bien distincts. « Vues sous ce nom » se rapporte à la commune de
 * diffusion de l'annonce — celle de l'agence. « Placés ici » se rapporte à la
 * commune réelle du bien, connue seulement une fois l'adresse retrouvée. Une
 * agence de Marciac vendant à Tillac alimente la première ligne de Marciac et
 * la seconde de Tillac.
 */
function statsCommune(nom, insee){
  const vus = (BILAN && BILAN.diffusion && BILAN.diffusion[nom]) || null;
  let places = 0;
  let certains = 0;
  for (const d of DATA) {
    const ici = insee ? d.ins === insee : d.v === nom;
    if (!ici) continue;
    places++;
    const e = etat(d);
    // « Avec certitude » : adresse au numéro nettement détachée, ou position
    // confirmée à la main.
    if (e.rec || d.cf === 'élevée') certains++;
  }
  return {
    nom,
    vues: vus ? vus.vues : 0,
    tentees: vus ? vus.tentees : 0,
    localisees: vus ? vus.localisees : 0,
    certaines: vus ? vus.certaines : 0,
    le: vus ? vus.le : null,
    places,
    certains,
    connue: !!vus,
  };
}

/** Toutes les communes dont on sait quelque chose, les plus fournies d'abord. */
function communesConnues(){
  const noms = new Set();
  if (BILAN && BILAN.diffusion) for (const n of Object.keys(BILAN.diffusion)) noms.add(n);
  for (const d of DATA) if (d.v) noms.add(d.v);
  const insees = new Map(DATA.map((d) => [d.v, d.ins]));
  return [...noms]
    .map((n) => statsCommune(n, insees.get(n)))
    .sort((a, b) => (b.vues + b.places) - (a.vues + a.places));
}

/**
 * Ce qui a été relevé, ce qui a été tenté, ce qui a abouti.
 *
 * Le taux se calcule sur les annonces qui portaient de quoi chercher : compter
 * en échec une annonce sans diagnostic reviendrait à se reprocher un silence
 * qui n'est pas le nôtre.
 */
/** Une ligne par commune : vues sous ce nom, placées ici, dont certaines. */
function tableauCommunes(){
  const lignes = communesConnues();
  if (!lignes.length) return '';
  const corps = lignes.map((c) =>
    '<tr><th scope="row">' + esc(c.nom) + '</th>' +
    '<td>' + (c.vues || '—') + '</td>' +
    '<td>' + (c.places || '—') + '</td>' +
    '<td>' + (c.certains || '—') + '</td></tr>').join('');
  return '<table class="parcommune"><caption>Par commune</caption><thead><tr>' +
    '<th scope="col">Commune</th>' +
    '<th scope="col" title="Annonces relevées sous ce nom de commune">Vues</th>' +
    '<th scope="col" title="Biens dont l’adresse retrouvée tombe sur cette commune">Placés</th>' +
    '<th scope="col" title="Adresse au numéro nettement détachée, ou position confirmée à la main">Certains</th>' +
    '</tr></thead><tbody>' + corps + '</tbody></table>';
}

function afficherBilan(){
  const b = document.getElementById('bilan');
  if (!BILAN || !BILAN.relevees) { b.hidden = true; return; }
  const sansDiag = BILAN.relevees - BILAN.tentees;
  const ratees = BILAN.tentees - BILAN.localisees;
  const taux = BILAN.tentees ? Math.round((BILAN.localisees / BILAN.tentees) * 100) : 0;
  const pc = (n) => (BILAN.relevees ? (n / BILAN.relevees) * 100 : 0).toFixed(2) + '%';

  const motifs = Object.entries(BILAN.motifs || {})
    .sort((x, y) => y[1] - x[1])
    .map(([m, n]) => '<li><b>' + n + '</b><span>' + esc(m) + '</span></li>').join('');

  // Le bilan d'une exécution ne connaît que des noms de zones ; celui tenu en
  // base porte le détail par zone. On affiche ce qui est disponible.
  const zones = (BILAN.zones || []).map((z) => {
    const nom = typeof z === 'string' ? z : z.nom;
    if (!nom) return '';
    if (typeof z === 'string' || !Number.isFinite(z.tentees)) return esc(nom);
    return esc(nom) + ' — ' + z.localisees + '/' + z.tentees +
      (z.le ? ' le ' + new Date(z.le).toLocaleDateString('fr-FR') : '');
  }).filter(Boolean).join('<br>');

  b.innerHTML =
    '<summary><span class="taux">' + BILAN.localisees + '/' + BILAN.tentees + '</span>' +
      '<span class="resume">annonces replacées à leur adresse · ' + taux + ' %</span></summary>' +
    '<div class="corps">' +
      '<div class="barre">' +
        '<i class="place" style="width:' + pc(BILAN.localisees) + '"></i>' +
        '<i class="rate" style="width:' + pc(ratees) + '"></i>' +
        '<i class="hors" style="width:' + pc(sansDiag) + '"></i>' +
      '</div>' +
      '<dl>' +
        '<dt>' + BILAN.relevees + '</dt><dd>annonces relevées</dd>' +
        '<dt>' + BILAN.tentees + '</dt><dd>portaient un diagnostic exploitable</dd>' +
        '<dt>' + BILAN.localisees + '</dt><dd>replacées à leur adresse exacte</dd>' +
      '</dl>' +
      (motifs ? '<ul class="motifs">' + motifs + '</ul>' : '') +
      tableauCommunes() +
      (zones ? '<p class="zones">' + zones + '</p>' : '') +
    '</div>';
}

/** GeoJSON [lon, lat] → Leaflet [lat, lon], en conservant trous et multi-parties. */
const versLatLng = (geom) => geom.map((poly) => poly.map((anneau) => anneau.map(([x, y]) => [y, x])));

// minZoom explicite : sans lui, Leaflet adopte celui de la couche la plus
// restrictive — la photo embarquée — et la carte refuse de dézoomer.
const map = L.map('map', { zoomControl: true, scrollWheelZoom: true, minZoom: 5, maxZoom: 22 });
// Vue initiale posée avant toute couche : Leaflet exige un centre pour projeter.
map.setView([46.6, 2.4], 6);

document.getElementById('legende').innerHTML =
  '<span style="color:var(--ink);font-weight:600">Ancienneté</span>' +
  PALIERS.slice().reverse().map(p => '<span><i class="' + p.cle + '"></i>' + p.texte + '</span>').join('') +
  '<span style="flex-basis:100%;height:0"></span>' +
  '<span>Points de loin, prix dès qu’on approche.</span>';

${basemap ? FOND_VECTORIEL : fond === 'satellite' ? FOND_SATELLITE : FOND_OSM}
${basemap?.cadastre ? FOND_CADASTRE : ''}
${basemap?.tuiles ? FOND_TUILES : ''}

const layer = L.layerGroup().addTo(map);
const parcelles = L.layerGroup().addTo(map);
const markers = new Map();
let selected = null;
/**
 * Une seule règle, pour que la carte soit prévisible : de loin un point de
 * couleur, de près le prix. Rien qui dépende du nombre de biens affichés.
 *
 * Au zoom parcelle le prix se pose au-dessus du point plutôt que dessus : il
 * masquerait le terrain, qui est justement ce qu'on vient regarder.
 */
const ZOOM_PRIX = 13;
const ZOOM_ANCRE = 18;
const renduMarqueur = () => {
  const z = map.getZoom();
  return z < ZOOM_PRIX ? 'point' : z < ZOOM_ANCRE ? 'prix' : 'prixAncre';
};
let rendu = 'prix';

function icon(d, sel){
  const c = tone(d);
  const marque = 'marker' + (sel ? ' on' : '');
  const prix = '<div class="pill ' + c + '">' + (d.p ? Math.round(d.p / 1000) + 'k' : '?') + '</div>';
  const point = '<div class="pin ' + c + '"></div>';
  const html =
    rendu === 'point' ? '<div class="' + marque + '">' + point + '</div>'
    : rendu === 'prix' ? '<div class="' + marque + '">' + prix + '</div>'
    : '<div class="' + marque + ' haut">' + prix + point + '</div>';
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
  const e = etat(d);
  const rows = [];
  const push = (k, v) => { if (v) rows.push('<dt>' + k + '</dt><dd>' + v + '</dd>'); };

  push('En ligne', d.j != null
    ? '<b class="age ' + tone(d) + '">' + (d.jm ? 'au moins ' : '') + d.j +
      (d.j > 1 ? ' jours' : ' jour') + '</b>' +
      (d.nb ? ' <span style="color:var(--muted)">· prix baissé</span>' : '')
    : null);
  push('Adresse', e.ad
    ? esc(e.ad) + (e.rec
        ? '<span class="marque rec">recalée</span>'
        : e.cf ? ' <span style="color:var(--muted)">— confiance ' + esc(e.cf) + '</span>' : '')
    : (d.v ? esc(d.v) + ' — localisation approchée' : null));
  push('Bien', [
    d.s ? num(d.s) + ' m²' : null,
    d.pc ? d.pc + ' pièces' : null,
    d.te ? 'terrain ' + num(d.te) + ' m²' : null,
  ].filter(Boolean).join(' · ') || null);
  const surfaceParcelle = e.pcl === d.pcl ? d.ct : (VOIS.get(e.pcl) || {}).s;
  push('Parcelle', e.pcl
    ? '<span style="font-variant-numeric:tabular-nums">' + esc(e.pcl) + '</span>' +
      (surfaceParcelle ? ' <span style="color:var(--muted)">· ' + num(surfaceParcelle) + ' m²</span>' : '') +
      (e.rec ? '<span class="marque rec">choisie</span>'
        : d.pcf === 'moyenne' || d.pcf === 'faible'
          ? '<span class="marque doute">à confirmer</span>' : '')
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

  return { rows: rows.join(''), links: liens.join(''), action, verif: blocVerif(d, e) };
}

/**
 * D'où vient cette adresse, et comment la corriger.
 *
 * Une adresse reconstituée n'est pas une adresse publiée : elle doit pouvoir
 * être contestée sur pièces, ici même, par celui qui ira sur place.
 */
function blocVerif(d, e){
  if (!d.pr && !e.rec) return '';
  const bouts = [];
  if (d.nd) bouts.push('DPE n° <b>' + esc(d.nd) + '</b>');
  if (d.no != null) bouts.push('note <b>' + Math.round(d.no) + '</b>');
  if (d.e2 != null) bouts.push('+' + Math.round(d.e2) + ' sur le suivant');
  if (d.df != null) bouts.push(num(d.df) + ' m du point flouté');
  const preuves = (d.mo || []).join(', ');
  return '<div class="verif">' +
    (bouts.length ? bouts.join(' · ') : 'Localisation reconstituée') +
    (preuves ? '<p class="preuves">Concordances : ' + esc(preuves) + '.</p>' : '') +
    '<button type="button" data-recaler="' + esc(d.id) + '">' +
    (e.rec ? 'Revoir le recalage' : 'Vérifier / recaler ce bien') + '</button></div>';
}

/** Bulle sur la carte : image, prix, caractéristiques, liens. */
function popup(d){
  const { rows, links, action, verif } = corpsFiche(d);
  return '<div class="pop">' +
    galerie(d) +
    '<div class="body">' +
      '<div class="p">' + eur(d.p) + (d.m2 ? '<small>' + num(d.m2) + ' €/m²</small>' : '') + '</div>' +
      '<dl>' + rows + '</dl>' +
      action +
      '<div class="links">' + links + '</div>' +
      boutonsSuivi(d.id) +
      verif +
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
  const { rows, links, action, verif } = corpsFiche(d);
  return '<div class="pop">' + galerie(d) + '<dl>' + rows + '</dl>' + action +
    '<div class="links">' + links + '</div>' + boutonsSuivi(d.id) + verif + '</div>';
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


// ── Recalage manuel ───────────────────────────────────────────────────────
// L'appariement se trompe parfois de maison, et le point du registre tombe
// parfois chez le voisin. Celui qui va sur place tranche : il désigne la bonne
// parcelle, et c'est sa version qui fait foi ensuite.
const CLE_RECAL = 'carto-immo:recalage';
let recal = {};
try { recal = JSON.parse(localStorage.getItem(CLE_RECAL) || '{}'); } catch { recal = {}; }

const VOIS = new Map(VOISINAGE.map(p => [p.i, p]));
const aRecal = (id) => Object.prototype.hasOwnProperty.call(recal, String(id));

/** Position proposée par l'automatique, d'avant tout recalage. */
const auto = (d) => d.au || { la: d.la, lo: d.lo, pcl: d.pcl, ad: d.ad, cf: d.cf };

/** Position, parcelle et adresse effectives d'un bien. */
function etat(d){
  if (!aRecal(d.id)) return { la: d.la, lo: d.lo, pcl: d.pcl, ad: d.ad, cf: d.cf, rec: !!d.rc };
  const r = recal[String(d.id)];
  // Recalage annulé ici même : on rend le bien à ce que l'automatique proposait.
  if (!r) { const a = auto(d); return { la: a.la, lo: a.lo, pcl: a.pcl, ad: a.ad, cf: a.cf, rec: false }; }
  const p = r.parcelle ? VOIS.get(r.parcelle) : null;
  return {
    la: Number.isFinite(r.latitude) ? r.latitude : p ? p.c[1] : d.la,
    lo: Number.isFinite(r.longitude) ? r.longitude : p ? p.c[0] : d.lo,
    pcl: r.parcelle || null,
    ad: r.adresse || auto(d).ad,
    cf: 'recalée',
    rec: true,
  };
}

/** Contour de la parcelle effective : celle du bien, ou celle qu'on a désignée. */
function geomParcelle(d, e){
  if (!e.pcl) return null;
  if (e.pcl === d.pcl && d.pg) return d.pg;
  const p = VOIS.get(e.pcl);
  return p ? p.g : null;
}

const metresC = (la1, lo1, la2, lo2) =>
  Math.hypot((la2 - la1) * 111320, (lo2 - lo1) * 111320 * Math.cos(la1 * Math.PI / 180));

function dansAnneau(lon, lat, a){
  let dedans = false;
  for (let i = 0, j = a.length - 1; i < a.length; j = i++) {
    if ((a[i][1] > lat) !== (a[j][1] > lat) &&
        lon < ((a[j][0] - a[i][0]) * (lat - a[i][1])) / (a[j][1] - a[i][1]) + a[i][0]) dedans = !dedans;
  }
  return dedans;
}
/** Dans le contour extérieur, hors de tout trou. */
function dansPoly(lon, lat, poly){
  if (!poly.length || !dansAnneau(lon, lat, poly[0])) return false;
  for (let i = 1; i < poly.length; i++) if (dansAnneau(lon, lat, poly[i])) return false;
  return true;
}
/** Parcelle du voisinage sous un point. */
function parcelleSous(lat, lon){
  for (const p of VOISINAGE) for (const poly of p.g) if (dansPoly(lon, lat, poly)) return p;
  return null;
}

function poserRecal(id, valeur){
  const cle = String(id);
  if (valeur === undefined) delete recal[cle]; else recal[cle] = valeur;
  try { localStorage.setItem(CLE_RECAL, JSON.stringify(recal)); } catch { /* navigation privée */ }
  if (valeur !== undefined) enregistrerRecal(cle, valeur);
  render();
  majBoutonCorrections();
  majPanneauRecal();
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

// Échelles de prospection. En dessous de 16 on ne distingue plus le bâti ;
// au-delà de 20 l'orthophotographie n'a plus de matière à montrer.
const ZOOM_BIEN = 18;
const ZOOM_BIEN_MIN = 16;
const ZOOM_BIEN_MAX = 20;
const MARGE_BULLE = 18;

/**
 * Exécute une fois le déplacement terminé.
 *
 * L'événement de fin de mouvement ne se déclenche pas quand la carte est déjà
 * au bon endroit : sans ce filet, la bulle d'un bien déjà cadré ne s'ouvrirait
 * jamais.
 */
function apresLeMouvement(fn){
  let fait = false;
  const faire = () => { if (fait) return; fait = true; fn(); };
  map.once('moveend', faire);
  setTimeout(faire, 900);
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
    const ouvrirBulle = () => {
      if (!entry.m.getPopup()) return;
      entry.m.openPopup();
      placerBulle(entry);
    };

    const mobile = MOBILE();
    if (mobile) {
      majDetail();
      // Laisser voir la carte : on n'ouvre le panneau qu'à mi-hauteur.
      if (position === 2) allerA(1);
    }

    if (fly) {
      // Un même cadrage pour tout le monde : la parcelle entière et un peu de
      // son voisinage, jamais moins que le bâti, jamais l'échelle du bourg.
      // On calcule zoom et centre explicitement — fitBounds ne sait pas tenir
      // compte de ce que le panneau ou la bulle recouvrent.
      const bornes = entry.parcelle?.getBounds();
      const zoom = bornes
        ? Math.max(ZOOM_BIEN_MIN, Math.min(ZOOM_BIEN_MAX, map.getBoundsZoom(bornes.pad(0.5), true)))
        : ZOOM_BIEN;
      // Sur mobile le panneau mange le bas de l'écran : on décale le centre
      // pour que le bien se pose dans la bande visible. Sur ordinateur on
      // centre franchement la parcelle et on laisse le recentrage de la bulle
      // faire le dernier ajustement — deux mécanismes qui décalent en même
      // temps se contrarient, et le bien finissait collé au bord bas.
      const masque = mobile ? masqueBas() : 0;
      const pt = map.project(bornes ? bornes.getCenter() : entry.m.getLatLng(), zoom);
      pt.y += masque / 2;
      const centre = map.unproject(pt, zoom);
      if (!mobile) apresLeMouvement(ouvrirBulle);
      // Leaflet ignore duration:0 et anime quand même : sans mouvement voulu,
      // on se pose directement.
      if (DOUX) map.flyTo(centre, zoom, { duration: .6 });
      else map.setView(centre, zoom, { animate: false });
    } else if (!mobile && !bulleDejaGeree) {
      ouvrirBulle();
    } else if (!mobile) {
      // Bulle ouverte par Leaflet : il reste à la poser à côté du terrain.
      placerBulle(entry);
    }
  }
}

/**
 * Pose la fiche **à côté** du terrain, jamais dessus.
 *
 * Une bulle ancrée au-dessus du point recouvre la parcelle — c'est-à-dire
 * exactement ce qu'on vient regarder — et, au zoom parcelle, sort par le haut
 * de l'écran en emportant la photo avec elle. On la place donc sur le flanc
 * qui offre le plus de place, centrée sur le terrain, et bornée à la fenêtre.
 */
function placerBulle(entry){
  const bulle = entry.m.getPopup();
  if (!bulle || !entry.m.isPopupOpen()) return;
  const element = bulle.getElement();
  if (!element) return;

  const carte = map.getSize();
  const boite = element.getBoundingClientRect();
  const l = boite.width || 300;
  const h = boite.height || 300;
  const ancre = map.latLngToContainerPoint(entry.m.getLatLng());

  // Emprise du terrain à l'écran : c'est elle qu'il ne faut pas recouvrir.
  let gauche = ancre.x, droite = ancre.x, milieuY = ancre.y;
  if (entry.parcelle) {
    const b = entry.parcelle.getBounds();
    const nw = map.latLngToContainerPoint(b.getNorthWest());
    const se = map.latLngToContainerPoint(b.getSouthEast());
    gauche = Math.min(nw.x, se.x);
    droite = Math.max(nw.x, se.x);
    milieuY = (nw.y + se.y) / 2;
  }

  // Le flanc le plus dégagé l'emporte ; à égalité, la droite, plus naturelle
  // à lire.
  const placeDroite = carte.x - droite;
  const placeGauche = gauche;
  const aDroite = placeDroite >= placeGauche;
  let centreX = aDroite ? droite + MARGE_BULLE + l / 2 : gauche - MARGE_BULLE - l / 2;

  // Bornage : la fiche doit tenir entière dans la fenêtre, photo comprise.
  centreX = Math.max(l / 2 + 8, Math.min(carte.x - l / 2 - 8, centreX));
  const centreY = Math.max(h / 2 + 8, Math.min(carte.y - h / 2 - 8, milieuY));

  // Leaflet pose le bas de la bulle sur l'ancre décalée.
  bulle.options.offset = L.point(Math.round(centreX - ancre.x), Math.round(centreY + h / 2 - ancre.y));
  element.classList.add('deportee');
  bulle.update();
}

/** Contour de la parcelle cadastrale du bien, en évidence quand il est choisi. */
function tracerParcelle(d, e, sel){
  const g = geomParcelle(d, e);
  if (!g) return null;
  // L'emprise du bâti n'a de sens que sur la parcelle que l'automatique a
  // tracée : sur une parcelle choisie à la main, elle induirait en erreur.
  if (d.bg && e.pcl === d.pcl) {
    L.polygon(versLatLng(d.bg), {
      color: '#0f2742', weight: 1.2, fillColor: '#0f2742', fillOpacity: .18, interactive: false,
    }).addTo(parcelles);
  }
  return L.polygon(versLatLng(g), {
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

let cadre = false;

function render(){
  layer.clearLayers();
  parcelles.clearLayers();
  markers.clear();
  const shown = DATA.filter(matches);
  rendu = renduMarqueur();

  for (const d of shown) {
    const e = etat(d);
    const m = L.marker([e.la, e.lo], { icon: icon(d, false) })
      // Cliquer un point ou un prix, c'est demander à voir ce bien : on cadre
      // sa parcelle. Leaflet bascule lui-même la bulle au clic, on ne la rouvre
      // donc pas — elle se refermerait aussitôt.
      .on('click', () => select(d.id, true, { bulleDejaGeree: !MOBILE() }));
    // Sur mobile la bulle recouvrirait la carte : le détail se déplie dans la liste.
    if (!MOBILE()) {
      // Pas de recentrage automatique : le placement latéral décide seul, et
      // deux mécanismes qui se contrarient renvoyaient la fiche hors écran.
      m.bindPopup(popup(d), { closeButton: true, autoPan: false });
    }
    layer.addLayer(m);
    markers.set(d.id, { m, d, parcelle: tracerParcelle(d, e, false) });
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



  // Un recalage ne doit pas recadrer la carte sous les yeux : on ne cadre
  // qu'au premier rendu, ensuite c'est « Tout voir » qui le fait.
  if (shown.length && !cadre) {
    cadre = true;
    map.fitBounds(L.latLngBounds(shown.map(d => { const e = etat(d); return [e.la, e.lo]; })).pad(.15), {
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

// De loin les pastilles de prix se chevaucheraient : on bascule sur le point.
// Une fiche posée sur le flanc du terrain doit y rester quand la carte bouge.
map.on('moveend zoomend', () => {
  if (selected && markers.has(selected)) placerBulle(markers.get(selected));
});

map.on('zoomend', () => {
  const veut = renduMarqueur();
  if (veut === rendu) return;
  rendu = veut;
  for (const [id, e] of markers) e.m.setIcon(icon(e.d, id === selected));
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
  map.fitBounds(L.latLngBounds(shown.map(d => { const e = etat(d); return [e.la, e.lo]; })).pad(.15), {
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


// ── Galerie : feuilleter les photos de l'annonce ─────────────────────────
// Les bulles naissent après le rendu : l'écouteur se pose sur le document.
document.addEventListener('click', (ev) => {
  const f = ev.target.closest('.galerie .fleche');
  if (!f) return;
  ev.preventDefault();
  ev.stopPropagation();
  const g = f.closest('.galerie');
  const photos = photosDe(parId.get(g.dataset.gal));
  if (photos.length < 2) return;
  const i = (Number(g.dataset.i) + Number(f.dataset.pas) + photos.length) % photos.length;
  g.dataset.i = i;
  g.querySelector('img').src = basseQualite(photos[i]);
  const pleine = g.querySelector('.pleine');
  if (pleine) pleine.href = photos[i];
  const rang = g.querySelector('.rang');
  if (rang) rang.textContent = (i + 1) + '/' + photos.length;
});

// ── Panneau de recalage ──────────────────────────────────────────────────

const RAYON_RECAL = 200;
const panneauRecal = document.getElementById('recal');
const coucheRecal = L.layerGroup();
let cibleRecal = null;
let modeRecal = null;

function ouvrirRecal(id){
  cibleRecal = String(id);
  modeRecal = null;
  const d = parId.get(cibleRecal);
  if (d) {
    const e = etat(d);
    map.setView([e.la, e.lo], Math.max(map.getZoom(), 18));
  }
  dessinerVoisinage();
  majPanneauRecal();
}

function fermerRecal(){
  cibleRecal = null;
  modeRecal = null;
  coucheRecal.clearLayers();
  if (map.hasLayer(coucheRecal)) map.removeLayer(coucheRecal);
  document.getElementById('map').classList.remove('viser');
  panneauRecal.classList.remove('on');
}

/** Surligne les parcelles voisines : c'est parmi elles qu'on désigne la bonne. */
function dessinerVoisinage(){
  coucheRecal.clearLayers();
  document.getElementById('map').classList.toggle('viser', modeRecal === 'point');
  if (modeRecal !== 'parcelle' || !cibleRecal) {
    if (map.hasLayer(coucheRecal)) map.removeLayer(coucheRecal);
    return;
  }
  const d = parId.get(cibleRecal);
  if (!d) return;
  const e = etat(d);
  for (const p of VOISINAGE) {
    if (metresC(e.la, e.lo, p.c[1], p.c[0]) > RAYON_RECAL) continue;
    const choisie = p.i === e.pcl;
    const poly = L.polygon(versLatLng(p.g), {
      color: choisie ? '#1e7a46' : '#a06a00',
      weight: choisie ? 3 : 1.4,
      fillColor: choisie ? '#1e7a46' : '#e8a33d',
      fillOpacity: choisie ? .3 : .18,
    }).addTo(coucheRecal);
    poly.bindTooltip(p.i + (p.s ? ' · ' + num(p.s) + ' m²' : ''), { sticky: true });
    poly.on('mouseover', () => poly.setStyle({ fillOpacity: .45 }));
    poly.on('mouseout', () => poly.setStyle({ fillOpacity: choisie ? .3 : .18 }));
    poly.on('click', (ev) => { L.DomEvent.stop(ev); choisirParcelle(p); });
  }
  coucheRecal.addTo(map);
}

const horodate = () => new Date().toISOString();

function choisirParcelle(p){
  poserRecal(cibleRecal, {
    latitude: p.c[1], longitude: p.c[0], parcelle: p.i,
    adresse: null, source: 'parcelle', le: horodate(),
  });
  modeRecal = null;
  dessinerVoisinage();
}

function placerPoint(lat, lon){
  const p = parcelleSous(lat, lon);
  poserRecal(cibleRecal, {
    latitude: lat, longitude: lon, parcelle: p ? p.i : null,
    adresse: null, source: 'point', le: horodate(),
  });
  modeRecal = null;
  dessinerVoisinage();
}

/** Adopte un diagnostic écarté de peu par la note. */
function adopterCandidat(i){
  const d = parId.get(cibleRecal);
  const c = d && d.alt ? d.alt[i] : null;
  if (!c) return;
  const p = parcelleSous(c.la, c.lo);
  poserRecal(cibleRecal, {
    latitude: c.la, longitude: c.lo, parcelle: p ? p.i : null,
    adresse: c.ad || null, source: 'diagnostic', le: horodate(),
  });
  modeRecal = null;
  dessinerVoisinage();
  map.setView([c.la, c.lo], Math.max(map.getZoom(), 18));
}

const LIBELLE_GEO = { numero: 'au numéro', voie: 'à la voie', commune: 'à la commune' };

function majPanneauRecal(){
  if (!cibleRecal) { panneauRecal.classList.remove('on'); return; }
  const d = parId.get(cibleRecal);
  if (!d) return fermerRecal();
  const e = etat(d);
  const surf = e.pcl === d.pcl ? d.ct : (VOIS.get(e.pcl) || {}).s;

  const origine = [];
  if (d.nd) origine.push('diagnostic n° ' + esc(d.nd));
  if (d.no != null) origine.push('note ' + Math.round(d.no));
  if (d.e2 != null) origine.push('+' + Math.round(d.e2) + ' sur le suivant');
  if (d.qg) origine.push('géocodage ' + esc(LIBELLE_GEO[d.qg] || d.qg));
  if (d.df != null) origine.push(num(d.df) + ' m du point flouté');

  const cands = (d.alt || []).map((c, i) =>
    '<div class="cand"><span><b>' + esc(c.ad || 'adresse inconnue') + '</b><br>' +
      'note ' + Math.round(c.no) + (c.s ? ' · ' + num(c.s) + ' m²' : '') +
      (c.df != null ? ' · à ' + num(c.df) + ' m' : '') + '</span>' +
      '<button type="button" data-cand="' + i + '">Adopter</button></div>').join('');

  panneauRecal.innerHTML =
    '<button type="button" class="ferme" aria-label="Fermer">×</button>' +
    '<h2>Recaler ce bien</h2>' +
    '<div style="color:var(--muted)">' + eur(d.p) +
      (d.s ? ' · ' + num(d.s) + ' m²' : '') + (d.v ? ' · ' + esc(d.v) : '') + '</div>' +
    '<dl>' +
      '<dt>Adresse</dt><dd>' + esc(e.ad || '—') + (e.rec ? '<span class="marque rec">recalée</span>' : '') + '</dd>' +
      '<dt>Parcelle</dt><dd>' + esc(e.pcl || '—') + (surf ? ' · ' + num(surf) + ' m²' : '') + '</dd>' +
      (d.pcm && !e.rec ? '<dt>Retenue</dt><dd>' + esc(d.pcm) + '</dd>' : '') +
      (origine.length ? '<dt>Origine</dt><dd>' + origine.join('<br>') + '</dd>' : '') +
    '</dl>' +
    '<div class="actions2">' +
      '<button type="button" data-mode="parcelle"' + (VOISINAGE.length ? '' : ' disabled') +
        ' aria-pressed="' + (modeRecal === 'parcelle') + '">Choisir la parcelle</button>' +
      '<button type="button" data-mode="point" aria-pressed="' + (modeRecal === 'point') + '">Placer le point</button>' +
    '</div>' +
    (modeRecal === 'parcelle'
      ? '<p class="aide">Clique sur la parcelle du bien : les voisines sont surlignées.</p>' : '') +
    (modeRecal === 'point'
      ? '<p class="aide">Clique sur la carte, à l’aplomb du bâtiment. La parcelle sous le point est reprise.</p>' : '') +
    (!VOISINAGE.length
      ? '<p class="aide">Plan cadastral absent de cette carte : seul le point libre est possible.</p>' : '') +
    (cands ? '<div class="cands"><b>Autres diagnostics compatibles</b>' + cands + '</div>' : '') +
    (e.rec ? '<button type="button" class="annuler">Revenir à la position automatique</button>' : '');
  panneauRecal.classList.add('on');
}

panneauRecal.addEventListener('click', (ev) => {
  if (ev.target.closest('.ferme')) return fermerRecal();
  const m = ev.target.closest('[data-mode]');
  if (m) {
    modeRecal = modeRecal === m.dataset.mode ? null : m.dataset.mode;
    dessinerVoisinage();
    return majPanneauRecal();
  }
  const c = ev.target.closest('[data-cand]');
  if (c) return adopterCandidat(Number(c.dataset.cand));
  if (ev.target.closest('.annuler')) {
    poserRecal(cibleRecal, null);
    modeRecal = null;
    dessinerVoisinage();
  }
});

document.addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-recaler]');
  if (!b) return;
  ev.preventDefault();
  ev.stopPropagation();
  ouvrirRecal(b.dataset.recaler);
});

document.addEventListener('keydown', (ev) => {
  if (ev.key !== 'Escape') return;
  if (modeRecal) { modeRecal = null; dessinerVoisinage(); majPanneauRecal(); }
  else if (cibleRecal) fermerRecal();
});

// ── Agent local ───────────────────────────────────────────────────────────
// Ouverte depuis l'agent, la carte devient une console : elle lance des
// analyses et enregistre les recalages. Ouverte comme simple fichier, elle
// reste utilisable et dit quoi taper.
let SERVEUR = null;

async function detecterAgent(){
  if (location.protocol === 'file:') return majBoutonCorrections();
  try {
    const r = await fetch('api/etat', { cache: 'no-store' });
    if (r.ok) SERVEUR = await r.json();
  } catch { /* carte servie sans agent */ }
  majBoutonCorrections();
}

function enregistrerRecal(id, valeur){
  if (!SERVEUR) return;
  const corps = {};
  corps[id] = valeur;
  fetch('api/recalage', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(corps),
  }).catch(() => { /* on garde la copie locale */ });
}

function majBoutonCorrections(){
  const b = document.getElementById('corrections');
  if (!b) return;
  const n = Object.keys(recal).length;
  b.hidden = !n;
  const pluriel = n > 1 ? 's' : '';
  b.textContent = n + ' recalage' + pluriel + (SERVEUR ? ' enregistré' + pluriel : ' à exporter');
}

const banniere = document.getElementById('travaux');
const montrer = (html) => { banniere.innerHTML = html; banniere.classList.add('on'); };

on('corrections', 'click', async () => {
  const contenu = JSON.stringify(recal, null, 1);
  if (SERVEUR) {
    montrer('<b>Recalages enregistrés</b><div class="lignes">Ils seront repris à la prochaine carte.</div>');
    setTimeout(() => banniere.classList.remove('on'), 3000);
    return;
  }
  // Le presse-papiers plutôt qu'un téléchargement : une carte consultée depuis
  // un lien n'a pas le droit de déposer un fichier, et un bouton qui ne fait
  // rien vaut moins que pas de bouton du tout.
  try {
    await navigator.clipboard.writeText(contenu);
    montrer('<b>Recalages copiés</b><div class="lignes">' +
      'Colle-les dans recalages.json, puis :<br>node src/cli.js recaler recalages.json</div>');
  } catch {
    montrer('<b>Recalages à reporter</b><div class="lignes">' +
      esc(contenu).slice(0, 2000) + '</div>');
  }
});

// ── Analyser une commune ─────────────────────────────────────────────────

function communeSous(lat, lon){
  for (const c of COMMUNES) {
    for (const anneau of c.g) if (dansAnneau(lon, lat, anneau)) return { nom: c.n, insee: c.c };
  }
  return null;
}

async function proposerCommune(lat, lon){
  let com = communeSous(lat, lon);
  if (!com) {
    const source = SERVEUR
      ? 'api/commune?lat=' + lat + '&lon=' + lon
      : 'https://geo.api.gouv.fr/communes?fields=nom,code&lat=' + lat + '&lon=' + lon;
    com = await fetch(source)
      .then((r) => (r.ok ? r.json() : null))
      .then((j) => {
        const c = Array.isArray(j) ? j[0] : j;
        return c && (c.nom || c.n) ? { nom: c.nom || c.n, insee: c.code || c.insee } : null;
      })
      .catch(() => null);
  }
  if (!com) return;
  montrerZone(lat, lon, com);
}

const jourCourt = (iso) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d.toLocaleDateString('fr-FR');
};

/**
 * Ce qu'on sait déjà de cette commune, et ce qu'on propose d'y faire.
 *
 * Une commune jamais balayée mérite un balayage complet ; une commune déjà
 * traitée mérite qu'on le dise, avec ses chiffres, avant de proposer de
 * recommencer.
 */
function montrerZone(lat, lon, com){
  const c = statsCommune(com.nom, com.insee);
  const quand = c.le ? jourCourt(c.le) : null;

  const lignes = [];
  if (c.connue) {
    lignes.push('<b class="chiffre">' + c.vues + '</b> annonce' + (c.vues > 1 ? 's' : '') +
      ' relevée' + (c.vues > 1 ? 's' : '') + ' sous ce nom, <b class="chiffre">' + c.localisees +
      '</b> identifiée' + (c.localisees > 1 ? 's' : '') +
      (c.certaines ? ' dont <b class="chiffre">' + c.certaines + '</b> avec certitude' : ''));
  }
  if (c.places) {
    lignes.push('<b class="chiffre">' + c.places + '</b> bien' + (c.places > 1 ? 's' : '') +
      ' situé' + (c.places > 1 ? 's' : '') + ' ici sur la carte' +
      (c.certains ? ', dont <b class="chiffre">' + c.certains + '</b> sûr' + (c.certains > 1 ? 's' : '') : ''));
  }
  if (!lignes.length) lignes.push('Jamais balayée.');
  if (quand) lignes.push('Dernier balayage le ' + quand + '.');

  const libelle = c.connue ? 'Rebalayer toute la commune' : 'Analyser toutes les annonces';
  const action = SERVEUR
    ? '<button type="button" data-zone="' + esc(com.nom) + '">' + libelle + '</button>' +
      '<div class="quoi">Reprend toutes les annonces de la commune, sans plafond, et' +
      ' n’ajoute que ce qui manque.</div>'
    : '<div class="quoi">À lancer depuis le terminal :</div>' +
      '<code>node src/cli.js annonces --zone "' + esc(com.nom) + '"</code>';

  L.popup({ closeButton: true, autoPanPadding: [30, 30] })
    .setLatLng([lat, lon])
    .setContent('<div class="zonepop"><b>' + esc(com.nom) + '</b>' +
      lignes.map((l) => '<div class="quoi">' + l + '</div>').join('') + action + '</div>')
    .openOn(map);
}

document.addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-zone]');
  if (!b) return;
  ev.preventDefault();
  lancerZone(b.dataset.zone);
});

async function lancerZone(zone){
  map.closePopup();
  montrer('<b>Analyse de ' + esc(zone) + '…</b><div class="lignes">démarrage</div>');
  // On reprend l'intégralité de la commune, sans le plafond de la veille
  // quotidienne : c'est un geste délibéré, pas une exécution de routine.
  const r = await fetch('api/zone', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ zone, tout: true }),
  }).then((x) => x.json()).catch((e) => ({ erreur: String(e && e.message ? e.message : e) }));
  if (!r || r.erreur) {
    montrer('<b>Analyse impossible</b><div class="lignes">' + esc(r && r.erreur ? r.erreur : 'agent injoignable') + '</div>');
    return;
  }
  suivreTravail(r.id, zone);
}

async function suivreTravail(id, zone){
  for (;;) {
    await new Promise((r) => setTimeout(r, 1500));
    const e = await fetch('api/travail/' + id).then((r) => (r.ok ? r.json() : null)).catch(() => null);
    if (!e) continue;
    const lignes = (e.lignes || []).slice(-6).map(esc).join('<br>');
    if (!e.fini) {
      montrer('<b>Analyse de ' + esc(zone) + '…</b><div class="lignes">' + lignes + '</div>');
      continue;
    }
    // Une analyse en échec ne doit pas recharger la page : ce serait effacer
    // sous les yeux la seule explication de ce qui s'est passé.
    if (e.erreur) {
      montrer('<b>' + esc(zone) + ' — analyse interrompue</b><div class="lignes">' +
        esc(e.erreur) + '</div>');
      return;
    }
    montrer('<b>' + esc(zone) + ' — ' + esc(e.resume || 'terminé') + '</b>' +
      '<div class="lignes">la carte se recharge…</div>');
    setTimeout(() => location.reload(), 1400);
    return;
  }
}

map.on('click', (ev) => {
  if (modeRecal === 'point') return placerPoint(ev.latlng.lat, ev.latlng.lng);
  if (modeRecal === 'parcelle') return;
  proposerCommune(ev.latlng.lat, ev.latlng.lng);
});

detecterAgent();

// Poignée de service : la carte est un fichier autonome, sans console de
// développement branchée dessus. C'est par là que les vérifications
// automatisées la pilotent, et qu'on l'inspecte quand quelque chose cloche.
window.cartoImmo = { map, DATA, recal, etat, render, ouvrirRecal, fermerRecal };

// Le bilan lit l'état effectif de chaque bien, recalages compris : il ne peut
// être dressé qu'une fois ceux-ci chargés.
afficherBilan();
render();
if (MOBILE()) allerA(2, false);
</script>
</body>
</html>`;

  fs.writeFileSync(file, html, 'utf8');
  return { file, plotted: points.length, skipped: sansCoords };
}
