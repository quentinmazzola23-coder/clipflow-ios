/**
 * Test d'intégration hors-ligne du pilotage navigateur.
 *
 * Aucun accès réseau : les requêtes vers leboncoin et lacquereur.fr sont
 * interceptées et servies depuis des pages enregistrées. On valide ce que le
 * test unitaire ne couvre pas — lancement du navigateur, navigation, attente
 * du rendu, détection du mur de connexion, boucle d'analyse.
 *
 *   node test/integration.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

import { openBrowser } from '../src/browser.js';
import { collectListings, applyFilters } from '../src/leboncoin.js';
import { analyseListing, analyseAll } from '../src/lacquereur.js';
import { normalize } from '../src/normalize.js';
import {
  loadStore, trierAnnonces, enregistrerAnalyse, reinitialiserStatuts, tousLesBiens,
} from '../src/store.js';
import { construireRapport, resumerRapport } from '../src/report.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = fs.readFileSync(path.join(here, 'fixtures', 'listing-analysis.html'), 'utf8');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'carto-immo-it-'));

// Le proxy éventuel de l'environnement n'a pas à intervenir : tout est simulé.
delete process.env.HTTPS_PROXY;

const cfg = {
  paths: { profile: path.join(tmp, 'profile') },
  headless: true,
  browserChannel: 'chrome', // volontaire : exerce le repli vers Chromium
  searches: ['https://www.leboncoin.fr/recherche?category=9&locations=Gers'],
  pagesPerSearch: 1,
  delayMs: { leboncoin: 10, lacquereur: 10 },
};

const PAGE_CONNEXION = `<!doctype html><html><body><div>Chargement…</div>
<script>self.__next_f.push([1,${JSON.stringify(
  JSON.stringify({ c: ['', 'login'] }) + '\n1a:I[15469,["/x.js"],"LoginForm"]\n'
)}])</script></body></html>`;

const annonce = (id, ville, prix, surface) => ({
  list_id: id,
  subject: `Maison ${surface} m² — ${ville}`,
  url: `https://www.leboncoin.fr/ad/ventes_immobilieres/${id}`,
  price: [prix],
  location: { city_label: ville, zipcode: '32230', lat: 43.52, lng: 0.15 },
  attributes: [
    { key: 'square', value: String(surface) },
    { key: 'rooms', value: '5' },
    { key: 'real_estate_type', value: '1', value_label: 'Maison' },
  ],
  images: { thumb_url: 'https://img.example/1.jpg', nb_images: 9 },
  owner: { name: 'Agence du Gers', type: 'pro' },
});

const PAGE_RECHERCHE = `<!doctype html><html><body>
<a href="/ad/ventes_immobilieres/111">Maison Marciac</a>
<a href="/ad/ventes_immobilieres/222">Maison Mirande</a>
<script>self.__next_f.push([1,${JSON.stringify(
  JSON.stringify({ ads: [annonce(111, 'Marciac', 134000, 97), annonce(222, 'Mirande', 189000, 120)] })
)}])</script></body></html>`;

// Réponse type de DataDome quand leboncoin refuse un client automatisé.
const PAGE_DATADOME = `<html><head><title>leboncoin.fr</title></head><body>
<p id="cmsg">Please enable JS and disable any ad blocker</p>
<script>var dd={'host':'geo.captcha-delivery.com'}</script></body></html>`;

/**
 * Chaque annonce doit recevoir une localisation propre : servir la même page
 * pour toutes ferait fusionner tous les biens sur la même parcelle.
 */
function personnaliser(page, urlDemandee) {
  if (page !== fixture) return page;
  const idAnnonce = decodeURIComponent(urlDemandee).match(/ventes_immobilieres\/(\d+)/)?.[1];
  if (!idAnnonce) return page;
  const bien = BIENS[idAnnonce];
  if (!bien) return page;
  return page
    .replaceAll('78403000AB0604', bien.parcelle)
    .replaceAll('78403_0005_00043', bien.ban)
    .replaceAll('49.0022370439012', String(bien.lat))
    .replaceAll('1.8785380526609368', String(bien.lon));
}

// Deux biens distincts ; l'annonce 333 republiera le bien de l'annonce 111.
const BIENS = {
  111: { parcelle: '32230000AB0111', ban: '32230_0001_00011', lat: 43.523100, lon: 0.156700 },
  222: { parcelle: '32300000AB0222', ban: '32300_0002_00022', lat: 43.518300, lon: 0.405300 },
  333: { parcelle: '32230000AB0111', ban: '32230_0001_00011', lat: 43.523100, lon: 0.156700 },
};

let passed = 0;
const check = (name, fn) => { fn(); passed++; console.log(`  ✓ ${name}`); };

console.log('\ncarto-immo — test d\'intégration navigateur\n');

const ctx = await openBrowser(cfg, { headless: true });
let servirAnalyse = fixture;
let servirRecherche = PAGE_RECHERCHE;

await ctx.route('**/*', async (route) => {
  const url = route.request().url();
  if (url.includes('lacquereur.fr')) {
    return route.fulfill({
      status: 200,
      contentType: 'text/html; charset=utf-8',
      body: personnaliser(servirAnalyse, url),
    });
  }
  if (url.includes('leboncoin.fr')) {
    return route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: servirRecherche });
  }
  return route.abort(); // images, polices : hors sujet
});

try {
  // ── Collecte ───────────────────────────────────────────────────────────
  const ads = await collectListings(ctx, cfg);
  check('la collecte lit les annonces d\'une page de résultats', () => {
    assert.equal(ads.length, 2);
    const marciac = ads.find((a) => a.id === '111');
    assert.equal(marciac.prix, 134000);
    assert.equal(marciac.surface, 97);
    assert.equal(marciac.ville, 'Marciac');
    assert.equal(marciac.vendeurType, 'pro');
  });

  // ── Analyse nominale ───────────────────────────────────────────────────
  const res = await analyseListing(ctx, ads[0].url, { timeoutMs: 20000 });
  check('l\'analyse aboutit et rend les coordonnées', () => {
    assert.equal(res.ok, true);
    assert.equal(typeof res.analysis.default_address.latitude, 'number');
    assert.match(res.analysis.default_address.label, /Mézy-sur-Seine/);
  });

  check('la fiche normalisée est complète', () => {
    const rec = normalize(ads[0], res.analysis);
    assert.equal(rec.ville, 'Mézy-Sur-Seine');
    assert.equal(rec.positionMarche, 'Au-dessus du marché');
    assert.ok(rec.urlMaps.startsWith('https://www.google.com/maps/'));
  });

  // ── Enchaînement complet ───────────────────────────────────────────────
  const vues = [];
  const stats = await analyseAll(ctx, ads, cfg, async (ad, analysis) => {
    vues.push(normalize(ad, analysis));
  });
  check('analyseAll traite toutes les annonces', () => {
    assert.equal(stats.ok, 2);
    assert.equal(stats.failed, 0);
    assert.equal(vues.length, 2);
  });

  // ── Mur de connexion ───────────────────────────────────────────────────
  servirAnalyse = PAGE_CONNEXION;
  const refus = await analyseListing(ctx, ads[0].url, { timeoutMs: 20000 });
  check('une session expirée est détectée immédiatement et marquée fatale', () => {
    assert.equal(refus.ok, false);
    assert.equal(refus.fatal, true);
    assert.match(refus.error, /session lacquereur\.fr expirée/);
  });

  const stop = await analyseAll(ctx, ads, cfg, async () => {});
  check('analyseAll s\'arrête à la première session expirée', () => {
    assert.equal(stop.ok, 0);
    assert.equal(stop.failed, 1); // et non 2 : inutile d'insister
  });

  // ── Analyse sans localisation déductible ───────────────────────────────
  // Même page, mais amputée de son bloc d'adresse : l'agent doit conclure vite.
  servirAnalyse = fixture.replaceAll('default_address', 'adresse_absente');
  const t0 = Date.now();
  const sansAdresse = await analyseListing(ctx, ads[0].url, { timeoutMs: 60000 });
  const duree = Date.now() - t0;
  check('une annonce sans adresse ne bloque pas jusqu\'au délai maximal', () => {
    assert.ok(duree < 30000, `conclu en ${Math.round(duree / 1000)} s`);
    assert.equal(sansAdresse.ok, true);
    assert.equal(sansAdresse.warning, 'localisation non déterminée');
  });
  // ── Mur anti-bot ───────────────────────────────────────────────────────
  servirRecherche = PAGE_DATADOME;
  let bloque = null;
  await collectListings(ctx, cfg).catch((e) => { bloque = e; });
  check('un mur anti-bot leboncoin donne une consigne exploitable', () => {
    assert.ok(bloque, 'la collecte doit s\'interrompre');
    assert.match(bloque.message, /anti-bot/);
    assert.match(bloque.message, /npm run login/);
  });
  // ── Deux matins consécutifs ────────────────────────────────────────────
  servirRecherche = PAGE_RECHERCHE;
  servirAnalyse = fixture;
  const store = loadStore(path.join(tmp, 'base.json'));
  const cfgStore = { reanalyseAfterDays: 14 };

  // Matin 1 : deux annonces inédites, deux analyses.
  reinitialiserStatuts(store);
  const jour1 = applyFilters(await collectListings(ctx, cfg), {});
  const triage1 = trierAnnonces(store, jour1, cfgStore, { maintenant: '2026-08-23T06:00:00.000Z' });
  const analysees1 = [];
  await analyseAll(ctx, triage1.nouveaux.map((n) => n.annonce), cfg, async (ad, a) => {
    analysees1.push(enregistrerAnalyse(store, normalize(ad, a, { collectedAt: '2026-08-23T06:00:00.000Z' }), ad).bien);
  });
  check('matin 1 — les deux annonces sont analysées et donnent deux biens', () => {
    assert.equal(triage1.nouveaux.length, 2);
    assert.equal(tousLesBiens(store).length, 2);
    assert.ok(analysees1.every((b) => b.statut === 'nouveau'));
  });

  // Matin 2 : l'annonce 111 a disparu, remplacée par 333 — même bien, prix baissé.
  servirRecherche = PAGE_RECHERCHE.replace(
    JSON.stringify(JSON.stringify({ ads: [annonce(111, 'Marciac', 134000, 97), annonce(222, 'Mirande', 189000, 120)] })),
    JSON.stringify(JSON.stringify({ ads: [annonce(333, 'Marciac', 126000, 97), annonce(222, 'Mirande', 189000, 120)] }))
  );
  reinitialiserStatuts(store);
  const jour2 = applyFilters(await collectListings(ctx, cfg), {});
  const triage2 = trierAnnonces(store, jour2, cfgStore, { maintenant: '2026-08-24T06:00:00.000Z' });

  check('matin 2 — la remise en ligne est reconnue, aucune analyse relancée', () => {
    assert.equal(triage2.nouveaux.length, 0, 'rien à analyser');
    assert.equal(triage2.republies.length, 1);
    assert.equal(triage2.republies[0].annonce.id, '333');
    assert.equal(triage2.connus.length, 1);
    assert.deepEqual(triage2.republies[0].prixModifie, { avant: 134000, apres: 126000 });
  });

  check('matin 2 — la base garde deux biens et trois parutions', () => {
    const biens = tousLesBiens(store);
    assert.equal(biens.length, 2);
    const marciac = biens.find((b) => b.cle === 'parcelle:32230000AB0111');
    assert.equal(marciac.annonces.length, 2);
    assert.equal(marciac.republications, 1);
    assert.equal(marciac.idPrincipal, '333');
    assert.equal(marciac.premiereApparition, '2026-08-23T06:00:00.000Z');
  });

  check('matin 2 — le rapport annonce zéro nouveauté et une remise en ligne', () => {
    const r = construireRapport(triage2, []);
    assert.equal(r.nouveaux.length, 0);
    assert.equal(r.republies.length, 1);
    assert.equal(r.baisses.length, 1);
    assert.match(resumerRapport(r), /0 nouveau bien/);
    assert.match(resumerRapport(r), /1 remise en ligne/);
  });
} finally {
  await ctx.close().catch(() => {});
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} vérifications passées.\n`);
