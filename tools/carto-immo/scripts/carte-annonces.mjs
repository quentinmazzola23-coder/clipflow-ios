/**
 * Carte des annonces d'un secteur, géolocalisées à l'adresse exacte.
 *
 *   node scripts/carte-annonces.mjs [--zone Marciac] [--max 200] [--out data-demo]
 *                                   [--filtres] [--types house,flat]
 *
 * Chaîne : annonces Bien'ici → adresse exacte par le registre des DPE (ADEME)
 * → prix situé face aux ventes réelles du secteur (DVF) → parcelle cadastrale.
 * Chaque bien garde le lien vers son annonce.
 *
 * Deux cartes sont écrites : l'une sur fond OpenStreetMap comme en production,
 * l'autre entièrement autonome (départements, communes, plan cadastral
 * embarqués), utilisable sans aucune requête sortante.
 */
import fs from 'node:fs';
import path from 'node:path';
import { ROOT } from '../src/config.js';
import { collecterEtLocaliser } from '../src/pipeline-annonces.js';
import { departements, communes } from '../src/contours.js';
import { writeMap } from '../src/map.js';
import { writeSpreadsheet, writeCsv } from '../src/sheet.js';
import { log } from '../src/log.js';

const args = process.argv.slice(2);
const opt = (nom, def) => { const i = args.indexOf(`--${nom}`); return i === -1 ? def : args[i + 1]; };

const ZONES = opt('zone', 'Marciac').split(',');
const OUT = path.resolve(ROOT, opt('out', 'data-demo'));
const CACHE = path.join(OUT, '.cache');
const MAX = Number(opt('max', '200'));
const TYPES = opt('types', 'house').split(',');
const FILTRES = args.includes('--filtres');

fs.mkdirSync(OUT, { recursive: true });

const { fiches, contexte, total, localisees } = await collecterEtLocaliser(ZONES, {
  types: TYPES, max: MAX, cacheDir: CACHE, cadastre: true, rayonContexteM: 300,
});

// Une annonce sans adresse établie n'est pas placée : la carte ne montre que
// ce qui est localisé, jamais une approximation à la commune.
const placees = fiches.filter((f) => f.localisationPrecise);
if (!placees.length) {
  log.error('Aucune annonce localisée.');
  process.exit(1);
}

const villes = [...new Set(placees.map((f) => f.ville))];
const secteur = ZONES.join(', ');
const titre = `Annonces — ${secteur}`;
const eleve = placees.filter((f) => f.niveauConfiance === 'élevée').length;

const note =
  `${placees.length} annonces en vente autour de ${secteur}, chacune replacée à son adresse exacte. ` +
  'Les sites d\'annonces ne publient pas l\'adresse : ils affichent un disque flou centré sur la ville. ' +
  'Chaque annonce a été rapprochée de son diagnostic dans le registre ADEME — même date, mêmes ' +
  'étiquettes, même surface, même consommation — ce qui donne l\'adresse, les coordonnées et la ' +
  `parcelle. ${eleve} le sont avec une confiance élevée ; le niveau est indiqué sur chaque fiche. ` +
  `Prix situés face aux ventes réelles du secteur (DVF). ${total - localisees} annonces sur ${total} ` +
  'n\'ont pas pu être localisées et ne figurent pas sur la carte.';

log.step('Contours');
let deps = [], coms = [];
try { deps = await departements(CACHE); log.ok(`  ${deps.length} départements`); }
catch (e) { log.warn(`  départements indisponibles (${e.message})`); }
const depsSecteur = [...new Set(placees.map((f) => f.codeInsee?.slice(0, 2)).filter(Boolean))];
for (const d of depsSecteur) {
  try { coms.push(...(await communes(d, CACHE))); }
  catch (e) { log.warn(`  communes ${d} indisponibles (${e.message})`); }
}
if (coms.length) log.ok(`  ${coms.length} communes`);

const osm = writeMap(placees, path.join(OUT, 'carte-annonces.html'), { title: titre, note, filtres: FILTRES });

const attribution =
  'Annonces <a href="https://www.bienici.com/">Bien\'ici</a> · adresses ' +
  '<a href="https://data.ademe.fr/">DPE ADEME</a> · cadastre et contours © IGN / Etalab · ' +
  'prix <a href="https://app.dvf.etalab.gouv.fr/">DVF</a>';

const autonome = (deps.length || coms.length)
  ? writeMap(placees, path.join(OUT, 'carte-annonces-autonome.html'), {
      title: titre, note, filtres: FILTRES,
      basemap: { departements: deps, communes: coms, cadastre: contexte, attribution },
    })
  : null;
if (!autonome) fs.rmSync(path.join(OUT, 'carte-annonces-autonome.html'), { force: true });

await writeSpreadsheet(placees, path.join(OUT, 'annonces.xlsx'));
writeCsv(placees, path.join(OUT, 'annonces.csv'));

log.ok(`Carte (OpenStreetMap) : ${osm.file}`);
if (autonome) {
  log.ok(`Carte (autonome)      : ${autonome.file}  ${(fs.statSync(autonome.file).size / 1024).toFixed(0)} Ko`);
}
log.ok(`Tableur               : ${path.join(OUT, 'annonces.xlsx')}`);
log.info(`Communes touchées     : ${villes.join(', ')}`);
