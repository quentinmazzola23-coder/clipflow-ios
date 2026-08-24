/**
 * Reconnaissance des remises en ligne.
 *
 * Le cas qui compte : une maison invendue est retirée puis republiée sous un
 * nouvel identifiant. Elle ne doit être ni réanalysée, ni annoncée comme une
 * nouveauté — mais deux maisons différentes qui se ressemblent ne doivent pas
 * être confondues pour autant.
 *
 *   node test/dedup.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

import { noterRapprochement, rapprocher, similitudeTitre, empreinte, cleBien } from '../src/identity.js';
import {
  loadStore, saveStore, trierAnnonces, enregistrerAnalyse,
  reinitialiserStatuts, tousLesBiens, besoinAnalyse,
  appliquerRecalages, recalagesConnus,
} from '../src/store.js';
import { appliquerRecalage } from '../src/cadastre.js';
import { construireRapport, resumerRapport, ecrireRapport } from '../src/report.js';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'carto-immo-dd-'));
let passed = 0;
const check = (name, fn) => { fn(); passed++; console.log(`  ✓ ${name}`); };

console.log('\ncarto-immo — reconnaissance des remises en ligne\n');

const CFG = { reanalyseAfterDays: 14 };

/** Annonce telle que la rend le collecteur leboncoin. */
const annonce = (o) => ({
  id: String(o.id),
  url: `https://www.leboncoin.fr/ad/ventes_immobilieres/${o.id}`,
  titre: o.titre ?? 'Maison de village 5 pièces avec jardin',
  prix: o.prix ?? 189000,
  ville: o.ville ?? 'Marciac',
  codePostal: o.cp ?? '32230',
  surface: 'surface' in o ? o.surface : 118,
  terrain: 'terrain' in o ? o.terrain : 850,
  pieces: 'pieces' in o ? o.pieces : 5,
  typeBien: 'Maison',
  vendeur: 'vendeur' in o ? o.vendeur : 'Agence du Sud Gers',
  lbcLat: o.lat ?? 43.5231,
  lbcLon: o.lon ?? 0.1567,
});

/** Fiche telle que la rend l'analyse lacquereur. */
const fiche = (a, o = {}) => ({
  id: a.id,
  collecteLe: o.quand ?? '2026-08-23T06:00:00.000Z',
  titre: a.titre,
  typeBien: 'Maison',
  prix: a.prix,
  surface: a.surface,
  terrain: a.terrain,
  pieces: a.pieces,
  ville: a.ville,
  codePostal: a.codePostal,
  vendeur: a.vendeur,
  adresseEstimee: 'adresse' in o ? o.adresse : '12 Rue du Château 32230 Marciac',
  latitude: o.lat ?? 43.52341,
  longitude: o.lon ?? 0.15702,
  localisationPrecise: true,
  parcelle: 'parcelle' in o ? o.parcelle : '32230000AB0142',
  banId: 'banId' in o ? o.banId : '32230_0012_00012',
  positionMarche: o.positionMarche ?? 'Sous le marché',
  ecartMarchePct: o.ecart ?? -11.2,
  urlAnnonce: a.url,
  autresAnnonces: o.autresAnnonces ?? [],
});

// ── Notation brute ────────────────────────────────────────────────────────

const REFERENCE = { ...fiche(annonce({ id: 1 })), annonces: [] };

check('une republication à l\'identique est reconnue', () => {
  const r = noterRapprochement(annonce({ id: 2 }), REFERENCE);
  assert.ok(r && r.note >= 85, `note ${r?.note}`);
});

check('une republication avec baisse de prix est reconnue', () => {
  const r = noterRapprochement(annonce({ id: 3, prix: 174000 }), REFERENCE);
  assert.ok(r && r.note >= 85, `note ${r?.note}`);
  assert.ok(r.motifs.includes('même terrain'));
});

check('une republication au titre réécrit reste reconnue', () => {
  const r = noterRapprochement(
    annonce({ id: 4, titre: 'Charmante maison 5 pièces, jardin clos, Marciac', prix: 179000 }),
    REFERENCE
  );
  assert.ok(r && r.note >= 85, `note ${r?.note}`);
});

check('une surface différente écarte le rapprochement', () => {
  assert.equal(noterRapprochement(annonce({ id: 5, surface: 96 }), REFERENCE), null);
});

check('un nombre de pièces différent écarte le rapprochement', () => {
  assert.equal(noterRapprochement(annonce({ id: 6, pieces: 7 }), REFERENCE), null);
});

check('une autre commune écarte le rapprochement', () => {
  assert.equal(
    noterRapprochement(annonce({ id: 7, ville: 'Mirande', cp: '32300' }), REFERENCE),
    null
  );
});

check('deux maisons voisines de même taille ne sont pas confondues', () => {
  // Même village, même surface, même nombre de pièces, titre générique :
  // le terrain et le vendeur diffèrent, cela doit rester deux biens.
  const voisine = annonce({
    id: 8,
    titre: 'Maison 5 pièces à vendre',
    terrain: 320,
    vendeur: 'Particulier',
    prix: 232000,
  });
  const r = noterRapprochement(voisine, REFERENCE);
  assert.ok(!r || r.note < 85, `note ${r?.note} — fusion à tort`);
});

check('une surface inconnue interdit de conclure', () => {
  assert.equal(noterRapprochement(annonce({ id: 9, surface: null }), REFERENCE), null);
});

check('une URL déjà connue du bien tranche immédiatement', () => {
  const bien = { ...REFERENCE, autresAnnonces: ['https://www.leboncoin.fr/ad/ventes_immobilieres/424242'] };
  const r = noterRapprochement(annonce({ id: 424242, surface: 999, ville: 'Ailleurs' }), bien);
  assert.equal(r.note, 100);
});

check('rapprocher choisit le meilleur candidat', () => {
  const autre = { ...fiche(annonce({ id: 20, terrain: 300, vendeur: 'Particulier' })), annonces: [] };
  const m = rapprocher(annonce({ id: 21 }), [autre, REFERENCE]);
  assert.equal(m.bien, REFERENCE);
});

// ── Triage sur la base ────────────────────────────────────────────────────

const storeFile = path.join(tmp, 'annonces.json');
const store = loadStore(storeFile);

// Jour 1 : une annonce inédite.
const j1 = annonce({ id: 1001 });
let triage = trierAnnonces(store, [j1], CFG, { maintenant: '2026-08-23T06:00:00.000Z' });
check('jour 1 — l\'annonce est inconnue, donc à analyser', () => {
  assert.equal(triage.nouveaux.length, 1);
  assert.equal(triage.republies.length, 0);
});

let { bien } = enregistrerAnalyse(store, fiche(j1), j1);
check('jour 1 — le bien est enregistré comme nouveau', () => {
  assert.equal(bien.statut, 'nouveau');
  assert.equal(bien.cle, 'parcelle:32230000AB0142');
  assert.equal(bien.annonces.length, 1);
  assert.equal(bien.republications, 0);
});

// Jour 2 : la même annonce, toujours en ligne.
reinitialiserStatuts(store);
triage = trierAnnonces(store, [j1], CFG, { maintenant: '2026-08-24T06:00:00.000Z' });
check('jour 2 — la même annonce est reconnue, aucune analyse', () => {
  assert.equal(triage.connus.length, 1);
  assert.equal(triage.nouveaux.length, 0);
  assert.equal(triage.connus[0].aReanalyser, false);
});

// Jour 3 : retirée, remise en ligne sous un nouvel identifiant, prix baissé.
reinitialiserStatuts(store);
const j3 = annonce({ id: 2002, prix: 174000, titre: 'Maison de village 5 pièces, jardin — Marciac' });
triage = trierAnnonces(store, [j3], CFG, { maintenant: '2026-09-02T06:00:00.000Z' });
check('jour 3 — la remise en ligne est reconnue sans analyse', () => {
  assert.equal(triage.republies.length, 1);
  assert.equal(triage.nouveaux.length, 0);
  assert.equal(triage.republies[0].aReanalyser, false);
  assert.deepEqual(triage.republies[0].prixModifie, { avant: 189000, apres: 174000 });
});

check('jour 3 — les deux parutions sont rattachées au même bien', () => {
  const biens = tousLesBiens(store);
  assert.equal(biens.length, 1, 'un seul bien en base');
  assert.equal(biens[0].annonces.length, 2);
  assert.equal(biens[0].republications, 1);
  assert.equal(biens[0].statut, 'republie');
  assert.equal(biens[0].premiereApparition, '2026-08-23T06:00:00.000Z');
  assert.equal(biens[0].idPrincipal, '2002');
});

check('jour 3 — l\'historique de prix est complet', () => {
  assert.deepEqual(tousLesBiens(store)[0].suiviPrix, [
    { date: '2026-08-23', prix: 189000 },
    { date: '2026-09-02', prix: 174000 },
  ]);
});

// Jour 4 : une vraie nouveauté dans la même commune.
reinitialiserStatuts(store);
const j4 = annonce({ id: 3003, surface: 74, pieces: 3, terrain: 210, titre: 'Maisonnette 3 pièces centre-bourg', prix: 98000 });
triage = trierAnnonces(store, [j3, j4], CFG, { maintenant: '2026-09-03T06:00:00.000Z' });
check('jour 4 — une maison différente du même village reste une nouveauté', () => {
  assert.equal(triage.nouveaux.length, 1);
  assert.equal(triage.nouveaux[0].annonce.id, '3003');
  assert.equal(triage.connus.length, 1);
});

// Elle est analysée à son tour : la base contient désormais deux biens.
const bienJ4 = enregistrerAnalyse(
  store,
  fiche(j4, { parcelle: '32230000AB0999', banId: '32230_0044_00003', quand: '2026-09-03T06:00:00.000Z', ecart: -14.1 }),
  j4
).bien;
check('jour 4 — la nouveauté est enregistrée à part', () => {
  assert.equal(bienJ4.statut, 'nouveau');
  assert.equal(tousLesBiens(store).length, 2);
});

// ── Rattrapage après analyse, sur la parcelle cadastrale ──────────────────

reinitialiserStatuts(store);
// Annonce trop remaniée pour être rapprochée au triage : autre agence, terrain
// annoncé différemment, titre entièrement réécrit.
const j5 = annonce({
  id: 4004,
  titre: 'Exclusivité — belle demeure rénovée proche commerces',
  terrain: 640,
  vendeur: 'Immo Marciac',
  prix: 168000,
});
triage = trierAnnonces(store, [j5], CFG, { maintenant: '2026-09-20T06:00:00.000Z' });
check('une remise en ligne trop remaniée échappe au triage', () => {
  assert.equal(triage.nouveaux.length, 1);
});

const res = enregistrerAnalyse(store, fiche(j5, { quand: '2026-09-20T06:00:00.000Z' }), j5);
check('… mais la parcelle cadastrale la démasque à l\'analyse', () => {
  assert.equal(res.bien.statut, 'republie');
  assert.equal(res.bien.motifRapprochement, 'même parcelle cadastrale');
  assert.equal(tousLesBiens(store).length, 2, 'toujours deux biens, pas trois');
  assert.equal(res.bien.annonces.length, 3);
});

// Fusion de deux fiches enregistrées sous des clés différentes.
reinitialiserStatuts(store);
const isole = annonce({ id: 5005, ville: 'Mirande', cp: '32300', surface: 140, pieces: 6, terrain: 1200 });
enregistrerAnalyse(
  store,
  fiche(isole, { parcelle: null, banId: null, adresse: null, lat: 43.5183, lon: 0.4053, quand: '2026-09-21T06:00:00.000Z' }),
  isole
);
const avantFusion = tousLesBiens(store).length;
const memeBien = annonce({ id: 6006, ville: 'Mirande', cp: '32300', surface: 140, pieces: 6, terrain: 1200, titre: 'Autre titre pour la même maison' });
const fusion = enregistrerAnalyse(
  store,
  fiche(memeBien, { parcelle: null, banId: null, adresse: null, lat: 43.51832, lon: 0.40531, quand: '2026-09-22T06:00:00.000Z' }),
  memeBien
);
check('deux fiches au même emplacement et même surface sont fusionnées', () => {
  assert.equal(tousLesBiens(store).length, avantFusion);
  assert.equal(fusion.fusionAvec, 'même emplacement et même surface');
});

// ── Une clé qui se précise ne doit pas dupliquer le bien ─────────────────

check('un bien localisé après coup reste le même bien', () => {
  const f = path.join(tmp, 'precision.json');
  const st = loadStore(f);
  const a = annonce({ id: 7007, ville: 'Auch', cp: '32000', surface: 120, pieces: 5 });

  // Jour 1 : analyse sans adresse — la clé se réduit à une empreinte.
  const j1 = enregistrerAnalyse(st, {
    ...fiche(a, { parcelle: null, banId: null, adresse: null, quand: '2026-08-01T06:00:00.000Z' }),
    localisationPrecise: false, latitude: null, longitude: null,
  }, a).bien;
  assert.match(j1.cle, /^empreinte:/);
  assert.equal(j1.statut, 'nouveau');

  // Jour 15 : la même annonce, cette fois localisée.
  reinitialiserStatuts(st);
  const j15 = enregistrerAnalyse(st, fiche(a, {
    parcelle: '32013000AR0366', quand: '2026-08-15T06:00:00.000Z',
  }), a).bien;

  assert.equal(tousLesBiens(st).length, 1, 'un seul bien, pas deux');
  assert.equal(j15.cle, 'parcelle:32013000AR0366');
  assert.equal(j15.premiereApparition, '2026-08-01T06:00:00.000Z', 'l\'ancienneté est conservée');
  assert.equal(j15.statut, 'connu', 'ce n\'est pas une nouveauté');
  assert.equal(j15.annonces.length, 1, 'une seule parution');
});

check('deux biens de même empreinte ne se confondent pas', () => {
  const f = path.join(tmp, 'empreintes.json');
  const st = loadStore(f);
  // Mêmes commune, type, surface et pièces : l'empreinte est identique.
  for (const id of [8001, 8002]) {
    const a = annonce({ id, ville: 'Auch', cp: '32000', surface: 100, pieces: 4 });
    enregistrerAnalyse(st, {
      ...fiche(a, { parcelle: null, banId: null, adresse: null }),
      localisationPrecise: false, latitude: null, longitude: null,
    }, a);
  }
  assert.equal(tousLesBiens(st).length, 2, 'deux biens distincts');
});

// ── Persistance ───────────────────────────────────────────────────────────

saveStore(storeFile, store);
check('la base se recharge sans perte', () => {
  const relu = loadStore(storeFile);
  assert.equal(relu.version, 2);
  assert.equal(tousLesBiens(relu).length, tousLesBiens(store).length);
  assert.equal(tousLesBiens(relu)[0].annonces.length, tousLesBiens(store)[0].annonces.length);
});

check('une base au format annonce est reprise au format bien', () => {
  const v1 = path.join(tmp, 'v1.json');
  fs.writeFileSync(v1, JSON.stringify({
    version: 1,
    records: {
      777: {
        id: '777', titre: 'Maison', prix: 150000, surface: 100, ville: 'Auch',
        parcelle: '32013000AC0001', urlAnnonce: 'https://www.leboncoin.fr/ad/ventes_immobilieres/777',
        collecteLe: '2026-08-01T06:00:00.000Z', vuePremiereFois: '2026-07-20T06:00:00.000Z',
      },
    },
  }));
  const migre = loadStore(v1);
  assert.equal(migre.version, 2);
  const b = tousLesBiens(migre)[0];
  assert.equal(b.cle, 'parcelle:32013000AC0001');
  assert.equal(b.annonces[0].id, '777');
  assert.equal(b.premiereApparition, '2026-07-20T06:00:00.000Z');
});

// ── Rapport du matin ──────────────────────────────────────────────────────

const bienMarciac = tousLesBiens(store).find((b) => b.cle === 'parcelle:32230000AB0142');
const rapport = construireRapport(
  {
    nouveaux: [{ annonce: j4 }],
    republies: [{ bien: bienMarciac, motifs: ['118 m²', 'même terrain'], prixModifie: { avant: 189000, apres: 174000 } }],
    connus: [{ bien: bienJ4, prixModifie: null }],
  },
  [{ ...fiche(j4), statut: 'nouveau', positionMarche: 'Sous le marché', ecartMarchePct: -14.1, idPrincipal: '3003' }],
  { maintenant: '2026-09-22T06:00:00.000Z' }
);

check('le rapport compte séparément nouveautés et remises en ligne', () => {
  assert.equal(rapport.nouveaux.length, 1);
  assert.equal(rapport.republies.length, 1);
  assert.equal(rapport.baisses.length, 1);
  assert.equal(rapport.inchanges, 1);
});

check('le rapport met en avant les biens sous le marché', () => {
  assert.equal(rapport.affaires.length, 1);
});

check('le résumé tient sur une ligne', () => {
  const r = resumerRapport(rapport);
  assert.match(r, /1 nouveau bien/);
  assert.match(r, /1 remise en ligne/);
  assert.match(r, /1 baisse de prix/);
});

check('le rapport écrit est lisible et complet', () => {
  const f = path.join(tmp, 'rapport.md');
  const texte = ecrireRapport(rapport, f);
  assert.ok(fs.existsSync(f));
  assert.match(texte, /# Veille immobilière/);
  assert.match(texte, /## 1 remise en ligne/);
  assert.match(texte, /189\s?000\s?€ → 174\s?000\s?€/);
  assert.match(texte, /À regarder en priorité/);
});

// ── Divers ────────────────────────────────────────────────────────────────

check('l\'empreinte tolère un arrondi de surface', () => {
  assert.equal(
    empreinte({ ville: 'Marciac', typeBien: 'Maison', surface: 118, pieces: 5 }),
    empreinte({ ville: 'MARCIAC', typeBien: 'maison', surface: 121, pieces: 5 })
  );
});

check('la clé se dégrade proprement quand la parcelle manque', () => {
  assert.equal(cleBien({ parcelle: 'P1' }), 'parcelle:P1');
  assert.equal(cleBien({ banId: 'B1' }), 'ban:B1');
  assert.match(cleBien({ latitude: 43.5, longitude: 0.15, localisationPrecise: true }), /^geo:/);
  assert.match(cleBien({ ville: 'Auch', surface: 100, pieces: 4 }), /^empreinte:/);
});

check('la similitude de titre ignore accents et ponctuation', () => {
  assert.equal(similitudeTitre('Maison rénovée, Marciac', 'maison renovee marciac'), 1);
});

check('besoinAnalyse respecte le délai de rafraîchissement', () => {
  const vieux = { analyseLe: '2026-07-01T00:00:00.000Z' };
  assert.equal(besoinAnalyse(vieux, 14), true);
  assert.equal(besoinAnalyse({ analyseLe: new Date().toISOString() }, 14), false);
  assert.equal(besoinAnalyse({}, 14), true);
  assert.equal(besoinAnalyse(vieux, 0), false);
});

// ── Recalage manuel ───────────────────────────────────────────────────────
// Une correction faite sur le terrain doit survivre à tout : à une nouvelle
// analyse, à une régénération de la carte, au lendemain matin.

const ficheBase = (o = {}) => ({
  id: 'r1', urlAnnonce: 'https://www.bienici.com/annonce/r1', titre: 'Maison', prix: 200000,
  surface: 120, ville: 'Marciac', codeInsee: '32235', latitude: 43.5231, longitude: 0.1567,
  localisationPrecise: true, adresseEstimee: '1 Rue A 32230 Marciac', niveauConfiance: 'bonne',
  parcelle: '322350000AB0001', collecteLe: '2026-08-01T07:00:00.000Z', ...o,
});

check('un recalage se pose sur le bien qui porte l\'annonce', () => {
  const store = loadStore(path.join(tmp, 'recal.json'));
  enregistrerAnalyse(store, ficheBase(), { id: 'r1', url: 'u', titre: 'Maison', prix: 200000 });
  const bilan = appliquerRecalages(store, {
    r1: { latitude: 43.5240, longitude: 0.1580, parcelle: '322350000AB0009', source: 'parcelle' },
  });
  assert.equal(bilan.appliques, 1);
  assert.equal(tousLesBiens(store)[0].recalage.parcelle, '322350000AB0009');
  assert.equal(recalagesConnus(store).r1.source, 'parcelle');
});

check('une annonce inconnue est signalée, pas inventée', () => {
  const store = loadStore(path.join(tmp, 'recal2.json'));
  const bilan = appliquerRecalages(store, { zzz: { latitude: 43, longitude: 0 } });
  assert.deepEqual(bilan.inconnus, ['zzz']);
  assert.equal(bilan.appliques, 0);
});

check('une nouvelle analyse n\'efface pas le recalage', () => {
  const f = path.join(tmp, 'recal3.json');
  const store = loadStore(f);
  enregistrerAnalyse(store, ficheBase(), { id: 'r1', url: 'u', prix: 200000 });
  appliquerRecalages(store, { r1: { latitude: 43.5240, longitude: 0.1580, parcelle: 'AB9' } });
  // Le lendemain, l'annonce est réanalysée et l'automatique propose autre chose.
  enregistrerAnalyse(
    store,
    ficheBase({ latitude: 43.5100, longitude: 0.1400, parcelle: 'AB1', collecteLe: '2026-08-02T07:00:00.000Z' }),
    { id: 'r1', url: 'u', prix: 200000 }
  );
  const bien = tousLesBiens(store)[0];
  assert.equal(bien.recalage.parcelle, 'AB9', 'le recalage doit survivre');
  // Et il reprend le dessus au moment de tracer la parcelle.
  appliquerRecalage(bien);
  assert.equal(bien.parcelle, 'AB9');
  assert.equal(bien.latitude, 43.5240);
  assert.equal(bien.niveauConfiance, 'recalée');
});

check('la position automatique est gardée pour pouvoir revenir en arrière', () => {
  const bien = ficheBase({ recalage: { latitude: 43.6, longitude: 0.2, parcelle: 'AB9' } });
  appliquerRecalage(bien);
  assert.equal(bien.auto.latitude, 43.5231);
  assert.equal(bien.auto.parcelle, '322350000AB0001');
  // Un second passage ne doit pas prendre la position recalée pour l'automatique.
  appliquerRecalage(bien);
  assert.equal(bien.auto.latitude, 43.5231);
});

check('un recalage annulé rend le bien à l\'automatique', () => {
  const store = loadStore(path.join(tmp, 'recal4.json'));
  enregistrerAnalyse(store, ficheBase(), { id: 'r1', url: 'u', prix: 200000 });
  appliquerRecalages(store, { r1: { latitude: 43.6, longitude: 0.2, parcelle: 'AB9' } });
  const bilan = appliquerRecalages(store, { r1: null });
  assert.equal(bilan.annules, 1);
  assert.equal(tousLesBiens(store)[0].recalage, undefined);
});

check('une parcelle désignée sans point reste exploitable', () => {
  const store = loadStore(path.join(tmp, 'recal5.json'));
  enregistrerAnalyse(store, ficheBase(), { id: 'r1', url: 'u', prix: 200000 });
  const bilan = appliquerRecalages(store, { r1: { parcelle: 'AB9' } });
  assert.equal(bilan.appliques, 1);
  assert.equal(tousLesBiens(store)[0].recalage.latitude, null);
});

fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\n${passed} vérifications passées.\n`);
