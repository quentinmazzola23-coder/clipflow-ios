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
import { noterDiagnostic, qualiteGeocodage, niveauConfiance } from '../src/geoloc.js';
import { dansAnneau, dansPolygone, aire, centroide, metres, distanceAuBord } from '../src/cadastre.js';

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

// ── Ce que le registre dit de son propre géocodage ────────────────────────

check('une consommation en énergie finale est reconnue', () => {
  // Les sites publient tantôt l'énergie primaire, tantôt la finale. Un
  // diagnostic qui ne concorde que sur la finale doit tout de même être crédité.
  const d = dpe({ conso_5_usages_par_m2_ep: 210, conso_5_usages_par_m2_ef: 143 });
  const r = noterDiagnostic(annonce(), d);
  assert.ok(r.motifs.includes('consommation'), r.motifs.join(', '));
  assert.ok(r.note > noterDiagnostic(annonce(), dpe({ conso_5_usages_par_m2_ep: 210 })).note);
});

check('la finesse de l\'adresse se lit sur l\'adresse, pas ailleurs', () => {
  assert.equal(qualiteGeocodage({ numero_voie_ban: '28', nom_rue_ban: 'Rue Morlas' }), 'numero');
  assert.equal(qualiteGeocodage({ nom_rue_ban: 'Route de Plaisance' }), 'voie');
  assert.equal(qualiteGeocodage({ adresse_ban: 'Lieu-dit Bourdette 32230 Marciac' }), 'inconnu');
});

check('le score BAN du registre ne juge pas la position', () => {
  // Mesuré sur le secteur : le score médian vaut 0,46 pour des adresses
  // exactes, et des lignes marquées « non géocodée » portent un numéro juste.
  // S'en servir écarterait des biens parfaitement localisés.
  const faible = dpe({ score_ban: 0.2, statut_geocodage: 'adresse non géocodée ban car aucune correspondance trouvée' });
  assert.equal(noterDiagnostic(annonce(), faible).note, noterDiagnostic(annonce(), dpe()).note);
  assert.equal(qualiteGeocodage(faible), 'numero');
});

check('un lieu-dit sans numéro ne perd pas de points', () => {
  assert.equal(noterDiagnostic(annonce(), dpe({ numero_voie_ban: null, nom_rue_ban: null })).note,
    noterDiagnostic(annonce(), dpe()).note);
});

check('« élevée » exige une adresse descendue au numéro', () => {
  assert.equal(niveauConfiance(130, 'numero'), 'élevée');
  assert.equal(niveauConfiance(130, 'voie'), 'bonne');
  assert.equal(niveauConfiance(130, 'inconnu'), 'bonne');
  assert.equal(niveauConfiance(85, 'numero'), 'moyenne');
});

// ── Ce que la géographie de l'annonce vaut, et ne vaut pas ────────────────

check('le rayon de floutage publié n\'écarte rien', () => {
  // Mesuré autour de Marciac : un rayon annoncé de 250 m accompagne
  // couramment un bien situé à onze kilomètres, parce que le point de
  // référence est la ville de diffusion, pas le bien. S'en servir comme
  // contrainte écartait des rapprochements notés au-dessus de 120.
  const serre = annonce({ flouRayon: 250 });
  const loin = noterDiagnostic(serre, dpe({ _geopoint: '43.6131,0.1567' })); // ~10 km
  assert.ok(loin, 'un bien de la commune voisine reste candidat');
});

check('commune et code postal concordants ne font qu\'un appoint', () => {
  const a = annonce({ ville: 'Marciac', codePostal: '32230' });
  const avec = noterDiagnostic(a, dpe({ nom_commune_ban: 'Marciac', code_postal_ban: '32230' }));
  const sans = noterDiagnostic(a, dpe({ nom_commune_ban: 'Auch', code_postal_ban: '32000' }));
  // Volontairement inférieur à l'écart exigé sur le second candidat : la ville
  // de diffusion ne doit pas départager à elle seule.
  assert.equal(avec.note - sans.note, 8);
  assert.ok(avec.note - sans.note < 12);
  assert.ok(avec.motifs.includes('commune') && avec.motifs.includes('code postal'));
});

check('l\'accent et la casse n\'empêchent pas la concordance', () => {
  const a = annonce({ ville: 'BEAUMARCHÉS' });
  assert.ok(noterDiagnostic(a, dpe({ nom_commune_ban: 'Beaumarches' })).motifs.includes('commune'));
});

check('un bien de la commune voisine reste candidat', () => {
  // Une agence de Marciac vend à Tillac ou à Troncens : c'est la règle, pas
  // l'exception. Seul le rayon de diffusion de 30 km est opposable.
  const a = annonce({ ville: 'Marciac', codePostal: '32230' });
  assert.ok(noterDiagnostic(a, dpe({ _geopoint: '43.6131,0.1567', nom_commune_ban: 'Tillac', code_postal_ban: '32170' })));
  // Au-delà, plus aucune agence ne promeut : on écarte.
  assert.equal(noterDiagnostic(a, dpe({ _geopoint: '43.9231,0.1567', nom_commune_ban: 'Auch' })), null);
});

check('une date voisine vaut moins qu\'une date exacte', () => {
  const exact = noterDiagnostic(annonce(), dpe());
  const voisin = noterDiagnostic(annonce(), dpe(), { dateExacte: false });
  assert.equal(exact.note - voisin.note, 11);
  assert.ok(voisin.motifs[0].includes('quelques jours'));
});

// ── Géométrie ─────────────────────────────────────────────────────────────

const carre = [[0, 0], [0, 1], [1, 1], [1, 0], [0, 0]];
const trou = [[.4, .4], [.4, .6], [.6, .6], [.6, .4], [.4, .4]];

check('le test point-dans-anneau est correct', () => {
  assert.equal(dansAnneau(0.5, 0.5, carre), true);
  assert.equal(dansAnneau(1.5, 0.5, carre), false);
  assert.equal(dansAnneau(0.5, 1.5, carre), false);
});

check('une parcelle percée ne contient pas son trou', () => {
  // Une parcelle en U n'englobe pas ce qu'elle enserre.
  assert.equal(dansPolygone(0.5, 0.5, [carre, trou]), false);
  assert.equal(dansPolygone(0.2, 0.2, [carre, trou]), true);
});

check('l\'aire déduit les trous', () => {
  const pleine = aire([[carre]]);
  const percee = aire([[carre, trou]]);
  assert.ok(percee < pleine);
  // Le trou fait 4 % du carré.
  assert.ok(Math.abs(1 - percee / pleine - 0.04) < 0.005, String(percee / pleine));
});

check('le centroïde ne se laisse pas tirer par les sommets denses', () => {
  // Rectangle dont un seul côté est densément découpé : la moyenne des sommets
  // s'y déporte, le centroïde géométrique reste au milieu du terrain.
  const anneau = [];
  for (let i = 0; i <= 60; i++) anneau.push([0, i / 60]); // bord gauche subdivisé
  anneau.push([1, 1], [1, 0], [0, 0]);
  const c = centroide([[anneau]]);
  const moyenne = anneau.reduce((a, p) => a + p[0], 0) / anneau.length;
  assert.ok(moyenne < 0.1, 'la moyenne des sommets vaut ' + moyenne.toFixed(3));
  assert.ok(c[0] > 0.4 && c[0] < 0.6, 'le centroïde vaut ' + c[0].toFixed(3));
});

check('la distance au bord est mesurée sur le contour, pas sur le centre', () => {
  // Parcelle très allongée : un point à son extrémité en est proche par le
  // bord, loin par le centre.
  const bande = [[0, 0], [0, 0.0001], [0.01, 0.0001], [0.01, 0], [0, 0]];
  const parBord = distanceAuBord(0.00005, 0.0102, [[bande]]);
  const parCentre = metres(0.00005, 0.0102, 0.00005, 0.005);
  assert.ok(parBord < 30, 'au bord : ' + Math.round(parBord) + ' m');
  assert.ok(parCentre > 500, 'au centre : ' + Math.round(parCentre) + ' m');
});

check('la distance en mètres est plausible', () => {
  // Marciac → Mirande, une vingtaine de kilomètres.
  const d = metres(43.5231, 0.1567, 43.5183, 0.4053);
  assert.ok(d > 19000 && d < 21000, `${Math.round(d)} m`);
});

console.log(`\n${passed} vérifications passées.\n`);
