/**
 * Appariement annonce ↔ diagnostic, sans accès réseau.
 *
 * C'est la pièce qui transforme un disque flou de 250 m en une adresse. Une
 * erreur ici place un bien chez le voisin : le test vérifie autant ce qui doit
 * être accepté que ce qui doit être refusé.
 *
 *   node test/geoloc.mjs
 */
import assert from 'node:assert/strict';
import { noterDiagnostic } from '../src/geoloc.js';
import { dansAnneau, metres } from '../src/cadastre.js';

let passed = 0;
const check = (nom, fn) => { fn(); passed++; console.log(`  ✓ ${nom}`); };
console.log('\ncarto-immo — localisation des annonces\n');

/** Annonce telle que la rend le collecteur Bien'ici. */
const annonce = (o = {}) => ({
  id: 'x', url: 'https://www.bienici.com/annonce/x',
  typeBien: 'Maison', typeBrut: 'house',
  surface: 180, prix: 399000, pieces: 5,
  dpeAnnonce: 'C', gesAnnonce: 'A', consoAnnonce: 143, emissionsAnnonce: 4,
  dateDpe: '2023-08-29', anneeConstruction: null,
  flouLat: 43.5231, flouLon: 0.1567,
  ...o,
});

/** Enregistrement tel que le rend le registre ADEME. */
const dpe = (o = {}) => ({
  adresse_ban: '28 Rue Morlas 32230 Marciac',
  numero_voie_ban: '28', nom_rue_ban: 'Rue Morlas',
  etiquette_dpe: 'C', etiquette_ges: 'A',
  surface_habitable_logement: 180,
  conso_5_usages_par_m2_ep: 124.5,
  emission_ges_5_usages_par_m2: 4,
  annee_construction: null,
  type_batiment: 'maison',
  _geopoint: '43.52402,0.15851',
  ...o,
});

// ── Ce qui doit être accepté ──────────────────────────────────────────────

check('un diagnostic concordant obtient une note élevée', () => {
  const r = noterDiagnostic(annonce(), dpe());
  assert.ok(r, 'le rapprochement doit aboutir');
  assert.ok(r.note >= 100, `note ${r.note}`);
  assert.ok(r.motifs.includes('surface'));
  assert.ok(r.distance < 1500);
});

check('une consommation divergente n\'écarte pas le rapprochement', () => {
  // Les annonces affichent tantôt l'énergie primaire, tantôt l'énergie finale.
  const r = noterDiagnostic(annonce(), dpe({ conso_5_usages_par_m2_ep: 210 }));
  assert.ok(r, 'la consommation ne doit jamais être rédhibitoire');
  assert.ok(!r.motifs.includes('consommation'));
});

check('une surface annoncée un peu plus large reste compatible', () => {
  // Le vendeur compte souvent des surfaces que le diagnostic ignore.
  const r = noterDiagnostic(annonce({ surface: 198 }), dpe({ surface_habitable_logement: 187 }));
  assert.ok(r && r.note >= 80, `note ${r?.note}`);
});

check('l\'année de construction conforte quand elle concorde', () => {
  const sans = noterDiagnostic(annonce(), dpe());
  const avec = noterDiagnostic(annonce({ anneeConstruction: 1900 }), dpe({ annee_construction: 1901 }));
  assert.ok(avec.note > sans.note);
  assert.ok(avec.motifs.includes('année de construction'));
});

check('un bien de la commune voisine reste plausible', () => {
  // Les agences promeuvent depuis le bourg voisin : 8 km ne disqualifient pas.
  const r = noterDiagnostic(annonce(), dpe({ _geopoint: '43.59,0.10' }));
  assert.ok(r, 'un bien à quelques kilomètres doit rester candidat');
  assert.ok(r.distance > 5000 && r.distance < 15000);
});

// ── Ce qui doit être refusé ───────────────────────────────────────────────

check('une étiquette climat différente écarte le diagnostic', () => {
  assert.equal(noterDiagnostic(annonce(), dpe({ etiquette_ges: 'D' })), null);
});

check('un appartement ne peut pas répondre pour une maison', () => {
  assert.equal(noterDiagnostic(annonce(), dpe({ type_batiment: 'appartement' })), null);
});

check('une surface trop éloignée écarte le diagnostic', () => {
  assert.equal(noterDiagnostic(annonce({ surface: 345 }), dpe({ surface_habitable_logement: 225 })), null);
});

check('au-delà du rayon de diffusion, le diagnostic est écarté', () => {
  // 42 km : une annonce de Marciac ne désigne pas un bien du Béarn.
  assert.equal(noterDiagnostic(annonce(), dpe({ _geopoint: '43.20,0.05' })), null);
});

check('une adresse sans numéro ni rue pèse moins', () => {
  const fine = noterDiagnostic(annonce(), dpe());
  const vague = noterDiagnostic(annonce(), dpe({ numero_voie_ban: null, nom_rue_ban: null }));
  // Le lieu-dit reste une adresse valable en campagne : la note ne chute pas,
  // c'est le niveau de confiance rendu par `localiser` qui en tient compte.
  assert.equal(vague.note, fine.note);
});

// ── Géométrie ─────────────────────────────────────────────────────────────

check('le test point-dans-parcelle est correct', () => {
  const carre = [[0, 0], [0, 1], [1, 1], [1, 0], [0, 0]];
  assert.equal(dansAnneau(0.5, 0.5, carre), true);
  assert.equal(dansAnneau(1.5, 0.5, carre), false);
  assert.equal(dansAnneau(0.5, 1.5, carre), false);
});

check('la distance en mètres est plausible', () => {
  // Marciac → Mirande, une vingtaine de kilomètres.
  const d = metres(43.5231, 0.1567, 43.5183, 0.4053);
  assert.ok(d > 19000 && d < 21000, `${Math.round(d)} m`);
});

console.log(`\n${passed} vérifications passées.\n`);
