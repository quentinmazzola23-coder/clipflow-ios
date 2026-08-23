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
import { loadStore, saveStore, upsert, needsAnalysis, allRecords } from '../src/store.js';
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

// ── 3. Base locale et suivi des prix ─────────────────────────────────────
const storeFile = path.join(out, 'annonces.json');
const store = loadStore(storeFile);

check('une annonce inconnue est à analyser', () =>
  assert.equal(needsAnalysis(store, rec.id, 14), true));

upsert(store, rec);
check('la première insertion marque « nouvelle »', () =>
  assert.equal(store.records[rec.id].nouvelle, true));

// Deuxième passage, prix baissé : le suivi doit l'enregistrer.
store.records[rec.id].nouvelle = false;
upsert(store, { ...rec, prix: 379000, collecteLe: '2026-09-01T08:00:00.000Z' });
check('une baisse de prix est tracée', () => {
  const s = store.records[rec.id];
  assert.equal(s.suiviPrix.length, 2);
  assert.equal(s.baisseDepuisSuivi, 15000);
  assert.equal(s.nouvelle, false);
  assert.equal(s.vuePremiereFois, '2026-08-23T08:00:00.000Z');
});
check('une annonce fraîche n\'est pas ré-analysée', () =>
  assert.equal(needsAnalysis(store, rec.id, 14), false));

saveStore(storeFile, store);
check('la base se recharge sans perte', () =>
  assert.equal(allRecords(loadStore(storeFile)).length, 1));

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
  { ...rec, nouvelle: true },
  {
    ...rec,
    id: '999',
    titre: 'Maison sans localisation',
    latitude: null,
    longitude: null,
    localisationPrecise: false,
    ecartMarchePct: -12.4,
    positionMarche: 'Sous le marché',
    nouvelle: false,
  },
];

const xlsx = path.join(out, 'annonces.xlsx');
const csv = path.join(out, 'annonces.csv');
const mapFile = path.join(out, 'carte.html');

await writeSpreadsheet(records, xlsx);
writeCsv(records, csv);
const map = writeMap(records, mapFile);

check('le tableur est écrit et non vide', () => assert.ok(fs.statSync(xlsx).size > 5000));
check('le CSV porte l\'en-tête et les lignes', () => {
  const lines = fs.readFileSync(csv, 'utf8').split('\n');
  assert.equal(lines.length, 3);
  assert.ok(lines[0].startsWith('﻿Titre;'));
  assert.ok(lines[1].includes('394000'));
});
check('la carte ne place que les biens localisés', () => {
  assert.equal(map.plotted, 1);
  assert.equal(map.skipped, 1);
});
check('la carte est autonome (Leaflet embarqué)', () => {
  const h = fs.readFileSync(mapFile, 'utf8');
  assert.ok(h.includes('49.0022'), 'les coordonnées sont injectées');
  assert.ok(h.includes('.leaflet-container') && h.length > 150000, 'Leaflet est inliné');
  assert.ok(!/<script[^>]+src=/.test(h), 'aucun script externe');
});

fs.rmSync(out, { recursive: true, force: true });
console.log(`\n${passed} vérifications passées.\n`);
