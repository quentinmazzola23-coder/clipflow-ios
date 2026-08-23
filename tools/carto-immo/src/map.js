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

const escapeJson = (obj) =>
  JSON.stringify(obj).replace(/</g, '\\u003c').replace(/-->/g, '--\\u003e');

export function writeMap(records, file, { title = 'Veille immobilière' } = {}) {
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
      cf: r.confianceAdresse,
      pr: r.localisationPrecise,
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
      nw: !!r.nouvelle,
      ph: r.photo,
      ua: r.urlAnnonce,
      ul: r.urlAnalyse,
      um: r.urlMaps,
    }));

  const sansCoords = records.length - points.length;
  const { css, js } = inlineLeaflet();

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
html,body{height:100%;margin:0}
body{font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--bg)}
#app{display:flex;height:100%}
#side{width:370px;flex:none;background:var(--panel);border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0}
#map{flex:1;min-width:0}
header{padding:16px 18px 12px;border-bottom:1px solid var(--line)}
header h1{margin:0 0 2px;font-size:16px;font-weight:650;letter-spacing:-.01em}
header .sub{color:var(--muted);font-size:12.5px}
.filters{padding:12px 18px;border-bottom:1px solid var(--line);display:grid;gap:9px}
.row{display:flex;gap:8px;align-items:center}
.row label{font-size:12px;color:var(--muted);min-width:64px}
input[type=number],select,input[type=search]{width:100%;padding:7px 9px;border:1px solid var(--line);border-radius:8px;font:inherit;font-size:13px;background:#fff;color:var(--ink)}
input[type=search]{padding-left:10px}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{border:1px solid var(--line);background:#fff;border-radius:999px;padding:5px 11px;font-size:12.5px;cursor:pointer;color:var(--muted);user-select:none}
.chip[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:#fff}
#count{padding:9px 18px;font-size:12.5px;color:var(--muted);border-bottom:1px solid var(--line);display:flex;justify-content:space-between;align-items:center}
#count button{border:none;background:none;color:var(--accent);font:inherit;font-size:12.5px;cursor:pointer;text-decoration:underline}
#list{overflow:auto;flex:1;min-height:0}
.card{display:flex;gap:11px;padding:11px 18px;border-bottom:1px solid var(--line);cursor:pointer}
.card:hover{background:#faf9f6}
.card.sel{background:#eef2f8;box-shadow:inset 3px 0 0 var(--accent)}
.card img{width:74px;height:56px;object-fit:cover;border-radius:7px;background:#e9e7e1;flex:none}
.card .noimg{width:74px;height:56px;border-radius:7px;background:#e9e7e1;flex:none}
.card h3{margin:0 0 3px;font-size:13px;font-weight:600;line-height:1.3;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.card .meta{font-size:12px;color:var(--muted)}
.card .price{font-size:13.5px;font-weight:680;margin-top:2px}
.tag{display:inline-block;font-size:11px;padding:1px 6px;border-radius:5px;margin-left:5px;vertical-align:1px}
.tag.new{background:#fff3d6;color:var(--amber)}
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
@media (max-width:820px){#app{flex-direction:column}#side{width:100%;height:52%}#map{height:48%}}
</style>
</head>
<body>
<div id="app">
  <aside id="side">
    <header>
      <h1>${title}</h1>
      <div class="sub" id="stamp"></div>
    </header>
    <div class="filters">
      <input type="search" id="q" placeholder="Filtrer par ville, titre, adresse…">
      <div class="row"><label for="pmin">Prix</label>
        <input type="number" id="pmin" placeholder="min €"><input type="number" id="pmax" placeholder="max €"></div>
      <div class="row"><label for="smin">Surface</label>
        <input type="number" id="smin" placeholder="min m²"><input type="number" id="smax" placeholder="max m²"></div>
      <div class="chips">
        <button class="chip" id="f-new" aria-pressed="false">Nouvelles</button>
        <button class="chip" id="f-under" aria-pressed="false">Sous le marché</button>
        <button class="chip" id="f-drop" aria-pressed="false">Prix baissé</button>
        <button class="chip" id="f-exact" aria-pressed="false">Adresse exacte</button>
      </div>
    </div>
    <div id="count"><span></span><button id="reset">Réinitialiser</button></div>
    <div id="list"></div>
  </aside>
  <div id="map"></div>
</div>
<script>${js}</script>
<script>
const DATA = ${escapeJson(points)};
const GENERATED = ${escapeJson(new Date().toISOString())};
const SANS_COORDS = ${sansCoords};

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

document.getElementById('stamp').textContent =
  DATA.length + ' bien' + (DATA.length > 1 ? 's' : '') + ' localisé' + (DATA.length > 1 ? 's' : '') +
  ' · mis à jour le ' + new Date(GENERATED).toLocaleString('fr-FR', {dateStyle:'long', timeStyle:'short'}) +
  (SANS_COORDS ? ' · ' + SANS_COORDS + ' sans localisation' : '');

const map = L.map('map', { zoomControl: true, scrollWheelZoom: true });
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);

const layer = L.layerGroup().addTo(map);
const markers = new Map();
let selected = null;
let shownCount = 0;
let showPills = true;

/** Pastilles de prix tant que la carte reste lisible, points sinon. */
function pillsWanted(){ return shownCount <= 80 || map.getZoom() >= 12; }

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

function popup(d){
  const rows = [];
  const push = (k, v) => { if (v) rows.push('<dt>' + k + '</dt><dd>' + v + '</dd>'); };
  push('Surface', d.s ? num(d.s) + ' m²' + (d.pc ? ' · ' + d.pc + ' pièces' : '') : null);
  push('Terrain', d.te ? num(d.te) + ' m²' : null);
  push('Adresse', d.ad ? esc(d.ad) + (d.cf ? ' <span style="color:var(--muted)">(' + d.cf + '%)</span>' : '') : (d.v ? esc(d.v) + ' — localisation approchée' : null));
  push('DPE', d.dpe ? dpeBadge(d.dpe) + (d.ges ? ' &nbsp;GES ' + dpeBadge(d.ges) : '') : null);
  push('Construit en', d.an);
  if (d.ec != null) {
    const col = d.ec > 0 ? 'var(--red)' : 'var(--green)';
    push('Écart marché', '<b style="color:' + col + '">' + (d.ec > 0 ? '+' : '') + d.ec.toFixed(1) + ' %</b>' +
      (d.fb && d.fh ? ' <span style="color:var(--muted)">(' + eur(d.fb) + '–' + eur(d.fh) + ')</span>' : ''));
  }
  push('En ligne', d.j != null ? d.j + ' jours' + (d.nb ? ' · ' + d.nb + ' baisse' + (d.nb > 1 ? 's' : '') + (d.bp ? ' (−' + d.bp.toFixed(1) + ' %)' : '') : '') : null);
  push('Délai commune', d.dv ? d.dv + ' jours' : null);

  const links = [];
  if (d.ua) links.push('<a href="' + esc(d.ua) + '" target="_blank" rel="noopener">Annonce</a>');
  if (d.ul) links.push('<a href="' + esc(d.ul) + '" target="_blank" rel="noopener">Analyse</a>');
  if (d.um) links.push('<a href="' + esc(d.um) + '" target="_blank" rel="noopener">Maps</a>');

  return '<div class="pop">' +
    (d.ph ? '<img src="' + esc(d.ph) + '" alt="" loading="lazy">' : '') +
    '<div class="body">' +
      '<h3>' + esc(d.t || 'Annonce ' + d.id) + '</h3>' +
      '<div class="p">' + eur(d.p) + (d.m2 ? '<small>' + num(d.m2) + ' €/m²</small>' : '') + '</div>' +
      '<dl>' + rows.join('') + '</dl>' +
      '<div class="links">' + links.join('') + '</div>' +
    '</div></div>';
}

function card(d){
  const tags =
    (d.nw ? '<span class="tag new">nouveau</span>' : '') +
    (d.pm === 'Sous le marché' ? '<span class="tag under">sous marché</span>' : '') +
    (d.pm === 'Au-dessus du marché' ? '<span class="tag over">au-dessus</span>' : '');
  return '<article class="card" data-id="' + d.id + '">' +
    (d.ph ? '<img src="' + esc(d.ph) + '" alt="" loading="lazy">' : '<div class="noimg"></div>') +
    '<div><h3>' + esc(d.t || 'Annonce ' + d.id) + tags + '</h3>' +
    '<div class="meta">' + esc(d.v || '') + (d.cp ? ' · ' + esc(d.cp) : '') +
      (d.s ? ' · ' + num(d.s) + ' m²' : '') + (d.pc ? ' · ' + d.pc + ' p.' : '') + '</div>' +
    '<div class="price">' + eur(d.p) + (d.m2 ? ' <span class="meta">' + num(d.m2) + ' €/m²</span>' : '') + '</div>' +
    '</div></article>';
}

const F = { q:'', pmin:null, pmax:null, smin:null, smax:null, nw:false, under:false, drop:false, exact:false };

function matches(d){
  if (F.q) {
    const hay = ((d.t || '') + ' ' + (d.v || '') + ' ' + (d.ad || '') + ' ' + (d.cp || '')).toLowerCase();
    if (!hay.includes(F.q)) return false;
  }
  if (F.pmin != null && (d.p == null || d.p < F.pmin)) return false;
  if (F.pmax != null && (d.p == null || d.p > F.pmax)) return false;
  if (F.smin != null && (d.s == null || d.s < F.smin)) return false;
  if (F.smax != null && (d.s == null || d.s > F.smax)) return false;
  if (F.nw && !d.nw) return false;
  if (F.under && d.pm !== 'Sous le marché') return false;
  if (F.drop && !(d.nb > 0)) return false;
  if (F.exact && !d.pr) return false;
  return true;
}

function select(id, fly){
  if (selected && markers.has(selected)) markers.get(selected).m.setIcon(icon(markers.get(selected).d, false));
  selected = id;
  document.querySelectorAll('.card.sel').forEach(e => e.classList.remove('sel'));
  const el = document.querySelector('.card[data-id="' + id + '"]');
  if (el) { el.classList.add('sel'); el.scrollIntoView({ block:'nearest', behavior:'smooth' }); }
  const entry = markers.get(id);
  if (entry) {
    entry.m.setIcon(icon(entry.d, true));
    if (fly) map.flyTo(entry.m.getLatLng(), Math.max(map.getZoom(), 15), { duration:.6 });
    entry.m.openPopup();
  }
}

function render(){
  layer.clearLayers();
  markers.clear();
  const shown = DATA.filter(matches);
  shownCount = shown.length;
  showPills = pillsWanted();

  for (const d of shown) {
    const m = L.marker([d.la, d.lo], { icon: icon(d, false) })
      .bindPopup(popup(d), { closeButton:true, autoPanPadding:[30,30] })
      .on('click', () => select(d.id, false));
    layer.addLayer(m);
    markers.set(d.id, { m, d });
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

  if (shown.length) map.fitBounds(L.latLngBounds(shown.map(d => [d.la, d.lo])).pad(.15), { maxZoom: 15 });
}

const numOrNull = v => v === '' || v == null ? null : Number(v);
const on = (id, ev, fn) => document.getElementById(id).addEventListener(ev, fn);

on('q', 'input', e => { F.q = e.target.value.trim().toLowerCase(); render(); });
for (const [id, key] of [['pmin','pmin'],['pmax','pmax'],['smin','smin'],['smax','smax']]) {
  on(id, 'input', e => { F[key] = numOrNull(e.target.value); render(); });
}
for (const [id, key] of [['f-new','nw'],['f-under','under'],['f-drop','drop'],['f-exact','exact']]) {
  on(id, 'click', e => {
    F[key] = !F[key];
    e.currentTarget.setAttribute('aria-pressed', String(F[key]));
    render();
  });
}
on('reset', 'click', () => {
  Object.assign(F, { q:'', pmin:null, pmax:null, smin:null, smax:null, nw:false, under:false, drop:false, exact:false });
  document.querySelectorAll('.filters input').forEach(i => { i.value = ''; });
  document.querySelectorAll('.chip').forEach(c => c.setAttribute('aria-pressed','false'));
  render();
});

// Quand les marqueurs deviennent nombreux ou la carte très dézoomée, les
// pastilles de prix se chevauchent : on bascule sur de simples points.
map.on('zoomend', () => {
  const want = pillsWanted();
  if (want !== showPills) {
    showPills = want;
    for (const [id, e] of markers) e.m.setIcon(icon(e.d, id === selected));
  }
});

map.setView([43.52, 0.16], 9);
render();
</script>
</body>
</html>`;

  fs.writeFileSync(file, html, 'utf8');
  return { file, plotted: points.length, skipped: sansCoords };
}
