/**
 * Agent local : la carte comme console de prospection.
 *
 * On vérifie ici ce qu'un fichier HTML seul ne peut pas faire — enregistrer un
 * recalage, reconnaître une commune, lancer une analyse — et surtout qu'un
 * refus s'exprime clairement plutôt que de passer pour un succès.
 *
 *   node test/agent.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

import { demarrerServeur } from '../src/serveur.js';
import { loadStore, saveStore, enregistrerAnalyse, tousLesBiens } from '../src/store.js';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'carto-immo-ag-'));
let passed = 0;
const check = async (nom, fn) => { await fn(); passed++; console.log(`  ✓ ${nom}`); };

console.log('\ncarto-immo — agent local\n');

const cfg = {
  paths: {
    store: path.join(tmp, 'annonces.json'),
    map: path.join(tmp, 'carte.html'),
    csv: path.join(tmp, 'annonces.csv'),
    spreadsheet: path.join(tmp, 'annonces.xlsx'),
    cache: path.join(tmp, 'cache'),
  },
  cadastre: false,
  filtresCarte: false,
  bienici: { zones: ['Marciac'], types: ['house'], max: 5 },
};

// Une base minimale : un bien, une annonce.
const store = loadStore(cfg.paths.store);
enregistrerAnalyse(
  store,
  {
    id: 'ag1', urlAnnonce: 'https://www.bienici.com/annonce/ag1', titre: 'Maison',
    prix: 200000, surface: 120, ville: 'Marciac', codeInsee: '32235',
    latitude: 43.5231, longitude: 0.1567, localisationPrecise: true,
    parcelle: '322350000AB0001', collecteLe: '2026-08-23T07:00:00.000Z',
  },
  { id: 'ag1', url: 'https://www.bienici.com/annonce/ag1', titre: 'Maison', prix: 200000 }
);
saveStore(cfg.paths.store, store);
fs.writeFileSync(cfg.paths.map, '<!doctype html><title>carte</title>', 'utf8');

// Port 0 : le système en choisit un libre, deux exécutions ne se gênent pas.
const { serveur, url } = await demarrerServeur(cfg, { port: 0 });
const base = `http://127.0.0.1:${serveur.address().port}`;
const appel = (chemin, opts) => fetch(base + chemin, opts);

try {
  await check('l’agent s’annonce et compte les biens', async () => {
    const r = await appel('/api/etat');
    assert.equal(r.status, 200);
    const e = await r.json();
    assert.equal(e.agent, 'carto-immo');
    assert.equal(e.biens, 1);
    assert.equal(e.occupe, false);
  });

  await check('la carte est servie telle qu’elle a été produite', async () => {
    const r = await appel('/');
    assert.equal(r.status, 200);
    assert.match(r.headers.get('content-type') ?? '', /text\/html/);
    assert.match(await r.text(), /<title>carte<\/title>/);
  });

  await check('un recalage envoyé depuis la carte est écrit en base', async () => {
    const r = await appel('/api/recalage', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ag1: { latitude: 43.524, longitude: 0.158, parcelle: 'AB9', source: 'parcelle' } }),
    });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).appliques, 1);
    const relu = loadStore(cfg.paths.store);
    assert.equal(tousLesBiens(relu)[0].recalage.parcelle, 'AB9');
  });

  await check('annuler le recalage l’efface de la base', async () => {
    const r = await appel('/api/recalage', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ag1: null }),
    });
    assert.equal((await r.json()).annules, 1);
    assert.equal(tousLesBiens(loadStore(cfg.paths.store))[0].recalage, undefined);
  });

  await check('une demande d’analyse sans zone est refusée', async () => {
    const r = await appel('/api/zone', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}',
    });
    assert.equal(r.status, 400);
    assert.match((await r.json()).erreur, /zone/);
  });

  await check('un JSON illisible est refusé proprement, sans faire tomber l’agent', async () => {
    const r = await appel('/api/recalage', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{pas du json',
    });
    assert.equal(r.status, 400, 'une requête mal formée est une erreur de l’appelant');
    assert.match((await r.json()).erreur, /JSON/);
    // L'agent répond toujours après.
    assert.equal((await appel('/api/etat')).status, 200);
  });

  await check('un travail inconnu se dit inconnu', async () => {
    const r = await appel('/api/travail/nexiste-pas');
    assert.equal(r.status, 404);
  });

  await check('un chemin non prévu ne sert aucun fichier', async () => {
    for (const chemin of ['/../src/cli.js', '/etc/passwd', '/api']) {
      const r = await appel(chemin);
      assert.equal(r.status, 404, chemin);
    }
  });

  await check('des coordonnées invalides ne partent pas interroger l’État', async () => {
    const r = await appel('/api/commune?lat=abc&lon=');
    assert.match((await r.json()).erreur, /coordonnées/);
  });
} finally {
  serveur.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} vérifications passées.\n`);
void url;
