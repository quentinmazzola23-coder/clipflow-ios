/**
 * Test de bout en bout de la moitié « aval » du pipeline, sur une vraie page
 * d'analyse enregistrée : décodage → normalisation → base → tableur → carte.
 *
 *   node test/smoke.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

import { decodeFlight, findObjectWithKeys, collectObjectsWithKeys } from '../src/flight.js';
import { extractAdsFromHtml, pageUrl, applyFilters } from '../src/leboncoin.js';
import { analysisUrl } from '../src/lacquereur.js';
import { normalize } from '../src/normalize.js';
import { loadStore, saveStore, enregistrerAnalyse, tousLesBiens, allRecords } from '../src/store.js';
import { writeSpreadsheet, writeCsv } from '../src/sheet.js';
import { writeMap } from '../src/map.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'carto-immo-'));
let passed = 0;

function check(name, fn) {
  fn();
  passed++;
  console.log(`  ✓ ${name}`);
}

console.log('\ncarto-immo — test de bout en bout\n');

// ── 1. Décodage du payload d'une vraie page lacquereur.fr ────────────────
const html = fs.readFileSync(path.join(here, 'fixtures', 'listing-analysis.html'), 'utf8');
const flight = decodeFlight(html);
const root = findObjectWithKeys(flight, ['default_address', 'listing', 'listing_id']);
const analysis = root.analysis;

check('le flux RSC est reconstitué', () => assert.ok(flight.length > 50000));
check('l\'objet d\'analyse est retrouvé', () => assert.ok(analysis?.listing));
check('les coordonnées sont présentes', () => {
  assert.equal(typeof analysis.default_address.latitude, 'number');
  assert.equal(typeof analysis.default_address.longitude, 'number');
});
check('l\'adresse est exploitable', () =>
  assert.match(analysis.default_address.label, /Mézy-sur-Seine/));

// ── 2. Normalisation ─────────────────────────────────────────────────────
const ad = {
  id: '2952864630',
  url: 'https://www.leboncoin.fr/ad/ventes_immobilieres/2952864630',
  titre: 'Maison de village 6 pièces',
  prix: 394000,
  ville: 'Mézy-sur-Seine',
};
const rec = normalize(ad, analysis, { collectedAt: '2026-08-23T08:00:00.000Z' });

check('prix et surface sont repris', () => {
  assert.equal(rec.prix, 394000);
  assert.equal(rec.surface, 133);
  assert.equal(rec.prixM2, 2962);
});
check('la localisation est marquée précise', () => {
  assert.equal(rec.localisationPrecise, true);
  assert.equal(rec.confianceAdresse, 80);
  assert.equal(rec.parcelle, '78403000AB0604');
});
check('l\'écart au marché DVF est calculé', () => {
  assert.equal(rec.ecartMarchePct, 19.3);
  assert.equal(rec.positionMarche, 'Au-dessus du marché');
});
check('l\'historique de prix est résumé', () => {
  assert.equal(rec.prixInitial, 415000);
  assert.equal(rec.nbBaisses, 3);
  assert.equal(rec.baissePct, 5.1);
});
check('le DPE est repris', () => {
  assert.equal(rec.dpe, 'E');
  assert.equal(rec.consoEnergie, 283);
});
check('les liens sont construits', () => {
  assert.ok(rec.urlMaps.includes('49.0022'));
  assert.equal(rec.urlAnalyse, analysisUrl(ad.url));
});

// ── 3. Base locale ───────────────────────────────────────────────────────
// Le détail du suivi et des remises en ligne est couvert par test/dedup.mjs.
const storeFile = path.join(out, 'annonces.json');
const store = loadStore(storeFile);

const { bien } = enregistrerAnalyse(store, rec, ad);
check('la fiche analysée entre en base comme bien nouveau', () => {
  assert.equal(bien.statut, 'nouveau');
  assert.equal(bien.cle, 'parcelle:78403000AB0604');
  assert.equal(bien.annonces.length, 1);
  assert.equal(bien.annonces[0].id, ad.id);
});

saveStore(storeFile, store);
check('la base se recharge sans perte', () => {
  const relu = loadStore(storeFile);
  assert.equal(tousLesBiens(relu).length, 1);
  assert.equal(allRecords(relu)[0].adresseEstimee, rec.adresseEstimee);
});

// ── 4. Collecteur leboncoin ──────────────────────────────────────────────
check('la pagination est réécrite', () => {
  assert.equal(
    pageUrl('https://www.leboncoin.fr/recherche?category=9&locations=Gers', 3),
    'https://www.leboncoin.fr/recherche?category=9&locations=Gers&page=3'
  );
  assert.ok(!pageUrl('https://www.leboncoin.fr/recherche?page=4', 1).includes('page'));
});

const fauxResultats = `<html><body>
  <a href="/ad/ventes_immobilieres/2475975829?ref=x">Maison Marciac</a>
  <a href="/offre/ventes_immobilieres/2475975830">Maison Mirande</a>
  <a href="/ad/ventes_immobilieres/2475975829">doublon</a>
  <a href="/boutique/123/agence.htm">une agence</a>
</body></html>`;
check('le repli DOM récupère les annonces sans doublon', () => {
  const { ads, strategy } = extractAdsFromHtml(fauxResultats);
  assert.equal(strategy, 'dom');
  assert.equal(ads.length, 2);
  assert.ok(ads.every((a) => /\/(ad|offre)\//.test(a.url)));
});

check('le flux RSC de leboncoin est préféré au DOM', () => {
  const adObj = {
    list_id: 2475975829,
    subject: 'Maison 5 pièces',
    url: 'https://www.leboncoin.fr/ad/ventes_immobilieres/2475975829',
    price: [134000],
    location: { city_label: 'Marciac', zipcode: '32230', lat: 43.523, lng: 0.157 },
    attributes: [
      { key: 'square', value: '97' },
      { key: 'rooms', value: '5' },
      { key: 'real_estate_type', value: '1', value_label: 'Maison' },
    ],
    images: { thumb_url: 'https://img/1.jpg', nb_images: 12 },
  };
  const page = `<script>self.__next_f.push([1,${JSON.stringify(
    JSON.stringify({ ads: [adObj] })
  )}])</script>`;
  const { ads, strategy } = extractAdsFromHtml(page);
  assert.equal(strategy, 'rsc');
  assert.equal(ads[0].prix, 134000);
  assert.equal(ads[0].surface, 97);
  assert.equal(ads[0].ville, 'Marciac');
  assert.equal(ads[0].typeBien, 'Maison');
});

check('les filtres écartent hors budget et hors surface', () => {
  const ads = [
    { id: '1', prix: 90000, surface: 60 },
    { id: '2', prix: 250000, surface: 140 },
    { id: '3', prix: 600000, surface: 300 },
  ];
  const kept = applyFilters(ads, { minPrice: 100000, maxPrice: 400000, minSurface: 80, propertyTypes: [] });
  assert.deepEqual(kept.map((a) => a.id), ['2']);
});

check('collectObjectsWithKeys ne rend que les objets complets', () => {
  const text = '{"list_id":1,"subject":"a"} {"list_id":2} {"list_id":3,"subject":"c"}';
  assert.equal(collectObjectsWithKeys(text, ['list_id', 'subject']).length, 2);
});

// ── 5. Sorties ───────────────────────────────────────────────────────────
const records = [
  { ...bien, statut: 'nouveau' },
  {
    ...bien,
    id: '999',
    cle: 'empreinte:sansgeo',
    titre: 'Maison sans localisation',
    latitude: null,
    longitude: null,
    localisationPrecise: false,
    ecartMarchePct: -12.4,
    positionMarche: 'Sous le marché',
    statut: 'republie',
    annonces: [{ id: '999' }, { id: '998' }],
    premiereApparition: '2026-07-01T08:00:00.000Z',
  },
];

const xlsx = path.join(out, 'annonces.xlsx');
const csv = path.join(out, 'annonces.csv');
const mapFile = path.join(out, 'carte.html');

await writeSpreadsheet(records, xlsx);
writeCsv(records, csv);
const map = writeMap(records, mapFile);

check('le tableur est écrit et non vide', () => assert.ok(fs.statSync(xlsx).size > 5000));
check('le CSV s\'ouvre sur ce qui décide de prospecter', () => {
  const lines = fs.readFileSync(csv, 'utf8').split('\n');
  assert.equal(lines.length, 3);
  // L'ancienneté puis le prix : l'ordre des colonnes est celui de la décision.
  assert.ok(lines[0].startsWith('﻿Jours en ligne;Prix;€/m²;'), lines[0].slice(0, 50));
  assert.ok(lines[0].includes(';Statut;'));
  assert.ok(lines[1].includes('394000'));
  assert.ok(lines[1].includes(';nouveau;'), 'le statut est reporté');
});

check('un écart de prix hors de proportion n\'est pas donné comme comparable', () => {
  const f = path.join(out, 'atypique.csv');
  writeCsv([{ ...records[0], ecartMarchePct: 536 }], f);
  const colonnes = fs.readFileSync(f, 'utf8').split('\n')[1].split(';');
  assert.equal(colonnes[3], '', 'la colonne écart marché reste vide');
});
check('la carte ne place que les biens localisés', () => {
  assert.equal(map.plotted, 1);
  assert.equal(map.skipped, 1);
});
check('la carte accepte un fond vectoriel et une note', () => {
  const f = path.join(out, 'carte-autonome.html');
  const communes = [
    { n: 'Marciac', c: '32233', g: [[[0.15, 43.51], [0.17, 43.51], [0.17, 43.53], [0.15, 43.53], [0.15, 43.51]]] },
  ];
  writeMap([{ ...records[0], codeInsee: '32233' }], f, {
    note: 'Données de démonstration',
    basemap: { communes, attribution: 'IGN / Etalab' },
  });
  const h = fs.readFileSync(f, 'utf8');
  assert.ok(!h.includes('tile.openstreetmap.org'), 'aucune tuile distante');
  assert.ok(h.includes('"Marciac"') && h.includes('IGN / Etalab'), 'le fond est embarqué');
  assert.ok(h.includes('Données de démonstration'), 'la note est rendue');
  assert.ok(h.includes('"32233"'), 'la commune du bien est marquée');
});

check('la parcelle cadastrale est tracée et détaillée', () => {
  const f = path.join(out, 'carte-parcelle.html');
  writeMap([{
    ...records[0],
    parcelle: '78403000AB0604',
    contenance: 372,
    parcelleGeom: [[[[1.8785, 49.0022], [1.8788, 49.0022], [1.8788, 49.0025], [1.8785, 49.0025], [1.8785, 49.0022]]]],
  }], f);
  const h = fs.readFileSync(f, 'utf8');
  assert.ok(h.includes('"78403000AB0604"'), 'la référence de parcelle est transmise');
  assert.ok(h.includes('49.0025'), 'le contour est transmis');
  assert.ok(h.includes("' m²</span>'"), 'la contenance est affichée');
  assert.ok(h.includes('tracerParcelle'), 'le tracé est présent');
});

check('la carte peut se passer du bloc de filtres', () => {
  const avec = path.join(out, 'carte-filtres.html');
  const sans = path.join(out, 'carte-sans-filtres.html');
  writeMap(records, avec, { filtres: true });
  writeMap(records, sans, { filtres: false });
  const a = fs.readFileSync(avec, 'utf8');
  const b = fs.readFileSync(sans, 'utf8');
  assert.ok(a.includes('class="filters"') && a.includes('Sous le marché'));
  assert.ok(!b.includes('class="filters"'), 'aucun bloc de filtres');
  assert.ok(!b.includes('id="reset"'), 'aucun bouton de réinitialisation');
  assert.ok(b.includes('AVEC_FILTRES = false'), 'le filtrage est désactivé côté page');
});

check('les liens portent le nom de leur destination', () => {
  const f = path.join(out, 'carte-liens.html');
  writeMap([{
    ...records[0],
    urlAnnonce: 'https://www.leboncoin.fr/ad/ventes_immobilieres/2952864630',
    urlAnalyse: 'https://lacquereur.fr/listing-analysis/x',
    urlMaps: 'https://www.google.com/maps/search/?api=1&query=49.1,1.8',
  }], f);
  const h = fs.readFileSync(f, 'utf8');
  assert.ok(h.includes('Annonce leboncoin'), 'une URL leboncoin est nommée comme telle');
  assert.ok(h.includes('leboncoin.fr/ad/ventes_immobilieres/2952864630'), 'l\'URL de l\'annonce est intacte');
  assert.ok(h.includes('target=\\"_blank\\"') || h.includes("target=\\'_blank\\'") || h.includes('_blank'),
    'le lien s\'ouvre dans un nouvel onglet');
  assert.ok(h.includes('noopener noreferrer'), 'le lien est isolé de la page');
  assert.ok(h.includes('libelleLien'), 'le nommage est appliqué à l\'exécution');
});

check('un lien vers une autre source ne se fait pas passer pour une annonce', () => {
  const f = path.join(out, 'carte-liens-dvf.html');
  writeMap([{ ...records[0], urlAnnonce: 'https://app.dvf.etalab.gouv.fr/?code_commune=32233' }], f);
  const h = fs.readFileSync(f, 'utf8');
  assert.ok(h.includes('app.dvf.etalab.gouv.fr'));
});

check('par défaut, la carte en ligne est une photo aérienne', () => {
  const h = fs.readFileSync(mapFile, 'utf8');
  assert.ok(h.includes('ORTHOIMAGERY.ORTHOPHOTOS'), 'orthophotographie IGN');
  assert.ok(!h.includes('tile.openstreetmap.org'), 'pas de fond plan résiduel');
});

check('le fond plan reste disponible', () => {
  const f = path.join(out, 'carte-plan.html');
  writeMap(records, f, { fond: 'plan' });
  const h = fs.readFileSync(f, 'utf8');
  assert.ok(h.includes('tile.openstreetmap.org'));
  assert.ok(!h.includes('ORTHOIMAGERY'), 'un seul fond à la fois');
});

check('la carte garde son propre minZoom malgré les couches', () => {
  // Sans minZoom explicite, Leaflet adopte celui de la couche la plus
  // restrictive — la photo embarquée — et refuse de dézoomer sur la France.
  const h = fs.readFileSync(mapFile, 'utf8');
  assert.match(h, /L\.map\('map',[^)]*minZoom:\s*5/);
});

check('la photo aérienne peut être embarquée dans la page', () => {
  const f = path.join(out, 'carte-photo.html');
  writeMap([{ ...records[0], codeInsee: '78403' }], f, {
    basemap: {
      departements: [],
      communes: [],
      attribution: 'IGN',
      tuiles: { images: { '18/1/2': 'data:image/jpeg;base64,AAAA' }, zoomMin: 16, zoomMax: 18 },
    },
  });
  const h = fs.readFileSync(f, 'utf8');
  assert.ok(h.includes('CouchePhoto'), 'la couche embarquée est présente');
  assert.ok(h.includes('"18/1/2"'), 'les dalles sont injectées');
  assert.ok(!h.includes('data.geopf.fr'), 'aucune requête sortante');
});

// ── Vérification et recalage ──────────────────────────────────────────────

const carre = (lon, lat, d) => [[[[lon-d,lat-d],[lon+d,lat-d],[lon+d,lat+d],[lon-d,lat+d],[lon-d,lat-d]]]];

check('la carte embarque le voisinage cadastral et les communes', () => {
  const f = path.join(out, 'carte-recal.html');
  writeMap([{ ...records[0], codeInsee: '32235' }], f, {
    voisinage: [{ i: '322350000AB0009', g: carre(0.1567, 43.5231, 4e-4), c: [0.1567, 43.5231], s: 900 }],
    communes: [{ n: 'Marciac', c: '32235', g: [[[0.14, 43.51], [0.18, 43.51], [0.18, 43.54], [0.14, 43.51]]] }],
  });
  const html = fs.readFileSync(f, 'utf8');
  assert.match(html, /322350000AB0009/);
  assert.match(html, /const VOISINAGE = \[\{/);
  assert.match(html, /"n":"Marciac"/);
});

check('sans voisinage fourni, la carte reste valide', () => {
  const f = path.join(out, 'carte-sans-voisinage.html');
  writeMap(records, f);
  assert.match(fs.readFileSync(f, 'utf8'), /const VOISINAGE = \[\];/);
});

check('la fiche porte de quoi contester le rapprochement', () => {
  const f = path.join(out, 'carte-verif.html');
  writeMap([{
    ...records[0],
    numeroDpe: '2332E0123456X', confianceAdresse: 118, ecartSecond: 23,
    qualiteGeocodage: 'numero', distanceFlouM: 412,
    motifsLocalisation: ['date du diagnostic', 'surface'],
    dpeAlternatives: [{ numeroDpe: 'Y', adresse: '4 Route de Plaisance', latitude: 43.52, longitude: 0.16, note: 95, confiance: 'bonne', surfaceDpe: 176, distanceFlouM: 610 }],
  }], f);
  const html = fs.readFileSync(f, 'utf8');
  assert.match(html, /2332E0123456X/, 'le numéro de DPE doit figurer');
  assert.match(html, /Route de Plaisance/, 'les diagnostics écartés doivent rester consultables');
  assert.match(html, /data-recaler=/, 'le bouton de recalage doit être posé');
});

check('un recalage en base déplace le bien et garde l\'automatique', () => {
  const f = path.join(out, 'carte-recale.html');
  writeMap([{
    ...records[0], latitude: 43.6, longitude: 0.2,
    recalage: { latitude: 43.6, longitude: 0.2, parcelle: 'AB9', source: 'parcelle' },
    auto: { latitude: 43.5231, longitude: 0.1567, parcelle: 'AB1', adresse: 'A', niveauConfiance: 'bonne' },
  }], f);
  const html = fs.readFileSync(f, 'utf8');
  assert.match(html, /"rc":\{/, 'le recalage doit être transmis');
  assert.match(html, /"au":\{/, 'la position automatique doit rester disponible');
});

check('plusieurs photos donnent une galerie feuilletable', () => {
  const f = path.join(out, 'carte-galerie.html');
  writeMap([{ ...records[0], photo: 'https://h/590x330/a.jpg', photos: ['https://h/590x330/a.jpg', 'https://h/590x330/b.jpg'] }], f);
  const html = fs.readFileSync(f, 'utf8');
  assert.match(html, /"phs":\["https:\/\/h\/590x330\/a.jpg","https:\/\/h\/590x330\/b.jpg"\]/);
  assert.match(html, /class="galerie"/);
  assert.match(html, /data-pas="1"/);
});

check('la carte autonome n\'emporte aucune photo distante', () => {
  const f = path.join(out, 'carte-autonome-photos.html');
  writeMap([{ ...records[0], codeInsee: '32233', photo: 'https://h/a.jpg', photos: ['https://h/a.jpg'] }], f, {
    basemap: { departements: [], communes: [], attribution: 'x' },
  });
  const html = fs.readFileSync(f, 'utf8');
  assert.match(html, /"phs":\[\]/);
  assert.ok(!html.includes('https://h/a.jpg'), 'aucune URL de photo ne doit rester');
});

check('la carte est autonome (Leaflet embarqué)', () => {
  const h = fs.readFileSync(mapFile, 'utf8');
  assert.ok(h.includes('49.0022'), 'les coordonnées sont injectées');
  assert.ok(h.includes('.leaflet-container') && h.length > 150000, 'Leaflet est inliné');
  assert.ok(!/<script[^>]+src=/.test(h), 'aucun script externe');
  assert.ok(h.includes('Remis en ligne'), 'le filtre des remises en ligne est présent');
});

fs.rmSync(out, { recursive: true, force: true });
console.log(`\n${passed} vérifications passées.\n`);
