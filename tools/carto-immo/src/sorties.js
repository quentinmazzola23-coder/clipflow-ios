import { allRecords, resumerBilans } from './store.js';
import { enrichirParcelles } from './cadastre.js';
import { communes as contoursCommunes } from './contours.js';
import { writeSpreadsheet, writeCsv } from './sheet.js';
import { writeMap } from './map.js';
import { log } from './log.js';

/**
 * Tableur, CSV et carte, à partir de la base locale.
 *
 * Séparé de la ligne de commande parce que l'agent local produit exactement les
 * mêmes sorties : une analyse lancée d'un clic sur la carte doit aboutir au même
 * fichier que celle lancée le matin par la tâche planifiée.
 */
export async function construireSorties(cfg, store, { titre = 'Veille immobilière' } = {}) {
  const records = allRecords(store);
  if (!records.length) {
    log.warn('Aucune fiche en base — rien à exporter.');
    return null;
  }

  // Contour exact du terrain, et parcelles voisines référencées : sans elles,
  // on ne pourrait pas désigner soi-même la bonne quand le point tombe à côté.
  let voisinage = [];
  if (cfg.cadastre) {
    const r = await enrichirParcelles(records, cfg.paths.cache);
    voisinage = r.voisinage;
    log.info(`${r.trouvees} parcelle(s) tracée(s) depuis le cadastre`);
  }

  const communes = await limitesCommunales(records, cfg.paths.cache);

  await writeSpreadsheet(records, cfg.paths.spreadsheet);
  writeCsv(records, cfg.paths.csv);
  const map = writeMap(records, cfg.paths.map, {
    title: titre,
    filtres: cfg.filtresCarte,
    voisinage,
    communes,
    bilan: resumerBilans(store),
  });

  log.ok(`Tableur  : ${cfg.paths.spreadsheet}`);
  log.ok(`CSV      : ${cfg.paths.csv}`);
  log.ok(`Carte    : ${cfg.paths.map}  (${map.plotted} biens placés${map.skipped ? `, ${map.skipped} sans coordonnées` : ''})`);
  return map;
}

/**
 * Limites des communes des départements déjà touchés.
 *
 * C'est ce qui permet de reconnaître un village au clic, pour demander son
 * analyse. Tout le département est embarqué, pas seulement les communes déjà
 * suivies : c'est justement sur les autres qu'on veut pouvoir cliquer.
 */
async function limitesCommunales(records, cacheDir) {
  const deps = [...new Set(records.map((r) => r.codeInsee?.slice(0, 2)).filter(Boolean))];
  const out = [];
  for (const dep of deps) {
    try {
      out.push(...(await contoursCommunes(dep, cacheDir)));
    } catch (e) {
      log.warn(`  contours des communes du ${dep} indisponibles (${e.message})`);
    }
  }
  return out;
}
