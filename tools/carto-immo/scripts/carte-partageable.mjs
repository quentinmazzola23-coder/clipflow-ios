/**
 * Carte entièrement embarquée, destinée à être partagée par un lien.
 *
 *   node scripts/carte-partageable.mjs [--zone Marciac] [--max 300] [--out data-demo]
 *
 * La carte de production charge ses photographies aériennes chez l'IGN et les
 * photos des annonces chez leurs hébergeurs. Publiée en ligne, une page n'a pas
 * toujours le droit d'aller les chercher — et de toute façon, un lien qu'on
 * ouvre au bord d'une route doit s'afficher tout de suite.
 *
 * Tout est donc embarqué : contours, dalles de photo aérienne, parcelles, et
 * une photo par bien, réduite. Le fichier pèse quelques mégaoctets et ne fait
 * aucune requête sortante.
 */
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { ROOT } from '../src/config.js';
import { collecterEtLocaliser } from '../src/pipeline-annonces.js';
import { departements, communes } from '../src/contours.js';
import { tuilesAutour } from '../src/tuiles.js';
import { writeMap } from '../src/map.js';
import { log, sleep } from '../src/log.js';

const args = process.argv.slice(2);
const opt = (nom, def) => { const i = args.indexOf(`--${nom}`); return i === -1 ? def : args[i + 1]; };

const ZONES = opt('zone', 'Marciac').split(',');
const OUT = path.resolve(ROOT, opt('out', 'data-demo'));
const CACHE = path.join(OUT, '.cache');
const MAX = Number(opt('max', '300'));
const FICHIER = path.join(OUT, opt('fichier', 'carte-partageable.html'));

// Assez grand pour reconnaître une façade et une toiture, assez petit pour que
// trente-huit photos tiennent dans une page qu'on ouvre au téléphone.
const LARGEUR_PHOTO = 420;
const QUALITE_PHOTO = 0.62;

fs.mkdirSync(OUT, { recursive: true });

const { fiches, voisinage, bilan, total, localisees } = await collecterEtLocaliser(ZONES, {
  types: (opt('types', 'house')).split(','), max: MAX, cacheDir: CACHE,
  cadastre: true, rayonContexteM: 300,
});

const placees = fiches.filter((f) => f.localisationPrecise);
if (!placees.length) {
  log.error('Aucune annonce localisée.');
  process.exit(1);
}

// ── Photos réduites ────────────────────────────────────────────────────────

/**
 * Réduit une image en passant par le navigateur : ni ImageMagick ni bibliothèque
 * d'images ici, mais un moteur de rendu sait très bien redessiner un JPEG.
 */
async function reduire(page, octets, type) {
  const source = `data:${type};base64,${octets.toString('base64')}`;
  return page.evaluate(
    async ({ src, largeur, qualite }) =>
      new Promise((resolve) => {
        const img = new Image();
        img.onload = () => {
          const echelle = Math.min(1, largeur / img.naturalWidth);
          const c = document.createElement('canvas');
          c.width = Math.round(img.naturalWidth * echelle);
          c.height = Math.round(img.naturalHeight * echelle);
          c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
          resolve(c.toDataURL('image/jpeg', qualite));
        };
        img.onerror = () => resolve(null);
        img.src = src;
      }),
    { src: source, largeur: LARGEUR_PHOTO, qualite: QUALITE_PHOTO }
  );
}

log.step('Photos des annonces');
const navigateur = await chromium
  .launch({ executablePath: '/opt/pw-browsers/chromium' })
  .catch(() => chromium.launch());
const page = await (await navigateur.newContext()).newPage();
// La page ne doit rien charger elle-même : on lui passe des octets déjà en main.
await page.setContent('<!doctype html><title>reduction</title>');

let octetsPhotos = 0;
let sansPhoto = 0;
for (const [i, f] of placees.entries()) {
  const url = f.photo ?? f.photos?.[0] ?? null;
  f.photos = [];
  f.photo = null;
  if (!url) { sansPhoto++; continue; }
  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error(String(r.status));
    const brut = Buffer.from(await r.arrayBuffer());
    const petite = await reduire(page, brut, r.headers.get('content-type') ?? 'image/jpeg');
    if (!petite) throw new Error('image illisible');
    f.photo = petite;
    f.photos = [petite];
    octetsPhotos += petite.length;
  } catch (e) {
    sansPhoto++;
    log.debug(`  photo indisponible pour ${f.id} (${e.message})`);
  }
  if ((i + 1) % 10 === 0) log.info(`  ${i + 1}/${placees.length} photos`);
  await sleep(120, 0.3);
}
await navigateur.close();
log.ok(`  ${placees.length - sansPhoto} photos embarquées · ${(octetsPhotos / 1048576).toFixed(1)} Mo` +
  (sansPhoto ? ` · ${sansPhoto} indisponibles` : ''));

// ── Fonds ──────────────────────────────────────────────────────────────────

log.step('Contours');
let deps = [];
const coms = [];
try { deps = await departements(CACHE); } catch (e) { log.warn(`  départements indisponibles (${e.message})`); }
for (const d of [...new Set(placees.map((f) => f.codeInsee?.slice(0, 2)).filter(Boolean))]) {
  try { coms.push(...(await communes(d, CACHE))); }
  catch (e) { log.warn(`  communes ${d} indisponibles (${e.message})`); }
}
log.ok(`  ${deps.length} départements · ${coms.length} communes`);

// Le niveau 19 quadruple le poids de la page pour un gain que le partage ne
// justifie pas : la version locale, elle, le garde.
log.step('Photographies aériennes');
const r = await tuilesAutour(placees, { zooms: { 16: 0, 17: 1, 18: 1 }, cacheDir: CACHE });
log.ok(`  ${Object.keys(r.tuiles).length} dalles · ${(r.octets / 1048576).toFixed(1)} Mo`);

const eleve = placees.filter((f) => f.niveauConfiance === 'élevée').length;
const note =
  `${placees.length} annonces en vente autour de ${ZONES.join(', ')}, chacune replacée à son ` +
  'adresse exacte par recoupement avec le registre des DPE. Page entièrement autonome : ' +
  'photographies aériennes, parcelles et photos d\'annonces sont embarquées, aucune requête ' +
  `n'est émise. ${eleve} adresses en confiance élevée. ${total - localisees} annonces sur ` +
  `${total} n'ont pas pu être localisées et ne figurent pas ici.`;

const carte = writeMap(placees, FICHIER, {
  title: opt('titre', `Prospection ${ZONES.join(', ')}`),
  note,
  voisinage,
  bilan,
  basemap: {
    departements: deps,
    communes: coms,
    cadastre: null,
    tuiles: Object.keys(r.tuiles).length ? { images: r.tuiles, zoomMin: 16, zoomMax: r.zoomMax } : null,
    attribution:
      'Annonces Bien\'ici · adresses DPE ADEME · cadastre et contours © IGN / Etalab · ' +
      'prix DVF · photographies aériennes © IGN',
  },
});

const mo = fs.statSync(FICHIER).size / 1048576;
log.ok(`Carte partageable : ${FICHIER}  ${mo.toFixed(1)} Mo  (${carte.plotted} biens)`);
if (mo > 15) log.warn('  au-delà de 15 Mo, la page devient lourde à ouvrir sur téléphone.');
