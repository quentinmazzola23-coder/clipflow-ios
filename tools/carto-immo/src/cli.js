#!/usr/bin/env node
import path from 'node:path';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { loadConfig, ROOT } from './config.js';
import { configureLog, log } from './log.js';
import { openBrowser } from './browser.js';
import { collectListings, applyFilters } from './leboncoin.js';
import { analyseAll } from './lacquereur.js';
import { normalize } from './normalize.js';
import {
  loadStore, saveStore, trierAnnonces, enregistrerAnalyse,
  reinitialiserStatuts, allRecords,
} from './store.js';
import { construireRapport, ecrireRapport, resumerRapport } from './report.js';
import { writeSpreadsheet, writeCsv } from './sheet.js';
import { writeMap } from './map.js';
import { enrichirParcelles } from './cadastre.js';
import { collecterEtLocaliser } from './pipeline-annonces.js';

const USAGE = `
carto-immo — veille immobilière leboncoin → lacquereur.fr → tableur + carte

  node src/cli.js annonces  Relève les annonces Bien'ici d'un secteur, retrouve
                            leur adresse exacte par le registre des DPE, et
                            produit tableur et carte. Aucune connexion requise.
  node src/cli.js login     Ouvre le navigateur pour se connecter une fois
                            (leboncoin + lacquereur.fr). À faire en premier.
  node src/cli.js run       Exécution complète : collecte, analyse, tableur, carte
  node src/cli.js add <url…>  Analyse une ou plusieurs annonces précises
  node src/cli.js map       Régénère tableur et carte depuis les données locales
  node src/cli.js schedule  Affiche comment programmer l'exécution quotidienne

Options : --config <fichier>  --headless  --max <n>  --quiet
          --zone <commune>   secteur pour la commande annonces
`;

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--config') args.config = argv[++i];
    else if (a === '--max') {
      const v = Number(argv[++i]);
      if (!Number.isFinite(v) || v <= 0) {
        console.error('--max attend un nombre positif.');
        process.exit(2);
      }
      args.max = v;
    }
    else if (a === '--zone') (args.zones ??= []).push(argv[++i]);
    else if (a === '--headless') args.headless = true;
    else if (a === '--quiet') args.quiet = true;
    else args._.push(a);
  }
  return args;
}

function openInBrowser(file) {
  const cmd =
    process.platform === 'win32' ? 'cmd' : process.platform === 'darwin' ? 'open' : 'xdg-open';
  const cmdArgs = process.platform === 'win32' ? ['/c', 'start', '', file] : [file];
  try {
    const proc = spawn(cmd, cmdArgs, { detached: true, stdio: 'ignore' });
    // spawn signale ses échecs par événement, pas par exception : sans ce
    // gestionnaire, l'absence d'environnement graphique ferait tomber le process.
    proc.on('error', () => {});
    proc.unref();
  } catch {
    /* rien à faire : le chemin du fichier a été affiché */
  }
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((r) => rl.question(question, (a) => { rl.close(); r(a); }));
}

/** Écrit tableur, CSV et carte à partir de la base locale. */
async function buildOutputs(cfg, store) {
  const records = allRecords(store);
  if (!records.length) {
    log.warn('Aucune fiche en base — rien à exporter.');
    return null;
  }

  // Contour exact du terrain. Le fond OpenStreetMap montre déjà bâtiments et
  // rues au zoom parcelle : seul le contour manque, on l'ajoute.
  if (cfg.cadastre) {
    const { trouvees } = await enrichirParcelles(records, cfg.paths.cache);
    log.info(`${trouvees} parcelle(s) tracée(s) depuis le cadastre`);
  }

  await writeSpreadsheet(records, cfg.paths.spreadsheet);
  writeCsv(records, cfg.paths.csv);
  const map = writeMap(records, cfg.paths.map, {
    title: 'Veille immobilière',
    filtres: cfg.filtresCarte,
  });

  log.ok(`Tableur  : ${cfg.paths.spreadsheet}`);
  log.ok(`CSV      : ${cfg.paths.csv}`);
  log.ok(`Carte    : ${cfg.paths.map}  (${map.plotted} biens placés${map.skipped ? `, ${map.skipped} sans coordonnées` : ''})`);
  return map;
}

async function cmdLogin(cfg) {
  log.step('Ouverture du navigateur. Connecte-toi, puis reviens ici.');
  const ctx = await openBrowser(cfg, { headless: false });
  const page = ctx.pages()[0] ?? (await ctx.newPage());

  await page.goto('https://lacquereur.fr/login').catch(() => {});
  console.log(`
  1. Connecte-toi à lacquereur.fr (onglet ouvert).
  2. Ouvre un nouvel onglet sur https://www.leboncoin.fr et accepte les cookies.
     Si une vérification anti-robot apparaît, résous-la maintenant.
  3. Reviens dans ce terminal.
`);
  await ask('  Appuie sur Entrée une fois connecté… ');
  await ctx.close();
  log.ok(`Session enregistrée dans ${cfg.paths.profile}`);
}

async function analyseInto(ctx, cfg, store, listings) {
  const analysees = [];
  const stats = await analyseAll(ctx, listings, cfg, async (ad, analysis) => {
    const fiche = normalize(ad, analysis);
    const { bien, fusionAvec } = enregistrerAnalyse(store, fiche, ad);
    if (fusionAvec) {
      log.info(`  rattaché à un bien déjà suivi (${fusionAvec})`);
    }
    analysees.push(bien);
    saveStore(cfg.paths.store, store); // sauvegarde incrémentale : une coupure ne perd rien
  });
  return { stats, analysees };
}

async function cmdRun(cfg, args) {
  if (cfg.configPath?.endsWith('config.example.json')) {
    log.error('Aucun config.json : l\'agent ne tournera pas sur les recherches d\'exemple.');
    log.info('  cp config.example.json config.json');
    log.info('  puis colle dans "searches" les URL de tes recherches leboncoin.');
    process.exitCode = 1;
    return;
  }
  if (!cfg.searches?.length) {
    log.error('Aucune recherche configurée.');
    log.info(`Copie config.example.json en config.json et renseigne "searches" :`);
    log.info(`  l'URL d'une recherche leboncoin telle qu'elle apparaît dans ton navigateur.`);
    process.exitCode = 1;
    return;
  }

  const store = loadStore(cfg.paths.store);
  reinitialiserStatuts(store);
  let rapport = null;

  const ctx = await openBrowser(cfg);
  try {
    log.step(`Collecte sur ${cfg.searches.length} recherche(s)`);
    const all = await collectListings(ctx, cfg);
    log.ok(`${all.length} annonces relevées`);

    const filtered = applyFilters(all, cfg.filters);
    if (filtered.length !== all.length) {
      log.info(`${all.length - filtered.length} écartées par les filtres`);
    }

    // Triage avant toute requête : c'est ici qu'on évite de renvoyer à
    // lacquereur une maison déjà analysée sous une annonce précédente.
    log.step('Tri des annonces');
    const triage = trierAnnonces(store, filtered, cfg);
    log.info(`${triage.nouveaux.length} jamais vues`);
    if (triage.republies.length) {
      log.info(`${triage.republies.length} remises en ligne (même bien, nouvelle annonce) — pas de nouvelle analyse`);
      for (const r of triage.republies) {
        log.debug(`  ${r.annonce.url} → ${r.bien.titre ?? r.bien.cle} [${r.motifs.join(', ')}]`);
      }
    }
    log.info(`${triage.connus.length} déjà suivies`);

    const aAnalyser = [
      ...triage.nouveaux.map((n) => n.annonce),
      ...[...triage.republies, ...triage.connus]
        .filter((c) => c.aReanalyser)
        .map((c) => c.annonce),
    ];
    const cap = args.max ?? cfg.maxAnalysesPerRun;
    const batch = aAnalyser.slice(0, cap);

    let analysees = [];
    if (batch.length) {
      log.step(
        `Analyse de ${batch.length} annonce(s) sur lacquereur.fr` +
          (aAnalyser.length > batch.length ? ` (${aAnalyser.length - batch.length} reportées)` : '')
      );
      const res = await analyseInto(ctx, cfg, store, batch);
      analysees = res.analysees;
      log.ok(`${res.stats.ok} analysées, ${res.stats.failed} en échec`);
      // Une session expirée interrompt tout : l'exécution ne peut pas se
      // conclure comme si elle avait abouti.
      if (res.stats.errors.some((e) => /session lacquereur/.test(e.error))) {
        process.exitCode = 1;
      }
      if (aAnalyser.length > batch.length) {
        log.info(`${aAnalyser.length - batch.length} restantes : prochaine exécution.`);
      }
    } else {
      log.info('Rien de neuf à analyser.');
    }

    rapport = construireRapport(triage, analysees);
  } finally {
    await ctx.close().catch(() => {});
  }

  saveStore(cfg.paths.store, store);

  if (rapport) {
    const texte = ecrireRapport(rapport, cfg.paths.report);
    console.log('\n' + texte);
    log.ok(`Rapport  : ${cfg.paths.report}`);
    log.ok(`Bilan    : ${resumerRapport(rapport)}`);
  }

  const map = await buildOutputs(cfg, store);
  if (map && cfg.openMapWhenDone) openInBrowser(cfg.paths.map);
}

async function cmdAdd(cfg, urls) {
  const listings = urls.map((url) => {
    const id = url.match(/\/(\d+)(?:[/?#]|$)/)?.[1] ?? url;
    return { id, url, titre: null, prix: null };
  });

  const store = loadStore(cfg.paths.store);
  reinitialiserStatuts(store);

  const ctx = await openBrowser(cfg);
  try {
    const { stats } = await analyseInto(ctx, cfg, store, listings);
    log.ok(`${stats.ok} analysées, ${stats.failed} en échec`);
  } finally {
    await ctx.close().catch(() => {});
  }

  saveStore(cfg.paths.store, store);
  const map = await buildOutputs(cfg, store);
  if (map && cfg.openMapWhenDone) openInBrowser(cfg.paths.map);
}

/**
 * Veille sur une source qui publie ses annonces en clair : pas de navigateur,
 * pas de compte, et l'adresse exacte reconstituée depuis le registre des DPE.
 */
async function cmdAnnonces(cfg, args) {
  const zones = args.zones ?? cfg.bienici?.zones ?? [];
  if (!zones.length) {
    log.error('Aucun secteur indiqué.');
    log.info('  node src/cli.js annonces --zone Marciac');
    log.info('  ou renseigne "bienici": { "zones": ["Marciac"] } dans config.json');
    process.exitCode = 1;
    return;
  }

  const store = loadStore(cfg.paths.store);
  reinitialiserStatuts(store);

  const { fiches, total, localisees } = await collecterEtLocaliser(zones, {
    types: cfg.bienici?.types ?? ['house'],
    max: args.max ?? cfg.bienici?.max ?? 200,
    cacheDir: cfg.paths.cache,
    cadastre: cfg.cadastre,
    filtres: cfg.filters,
  });

  // Les annonces sans adresse exacte restent hors carte : on ne place pas un
  // bien sur un point qu'on n'a pas établi.
  const enregistres = [];
  for (const fiche of fiches) {
    if (!fiche.localisationPrecise) continue;
    const { bien } = enregistrerAnalyse(store, fiche, {
      id: fiche.id, url: fiche.urlAnnonce, titre: fiche.titre, prix: fiche.prix, vendeur: fiche.vendeur,
    });
    enregistres.push(bien);
  }
  saveStore(cfg.paths.store, store);

  const nouveaux = enregistres.filter((b) => b.statut === 'nouveau').length;
  log.ok(`${localisees}/${total} annonces localisées · ${nouveaux} nouvelles en base`);

  // Même rapport que la voie leboncoin : c'est ce qu'on lit en premier. Le
  // statut est porté par le bien enregistré, pas par la fiche d'entrée.
  const inchanges = enregistres.filter((b) => b.statut === 'connu').length;
  const rapport = construireRapport(
    { nouveaux: [], republies: [], connus: Array.from({ length: inchanges }, () => ({ bien: null, prixModifie: null })) },
    enregistres
  );
  const texte = ecrireRapport(rapport, cfg.paths.report);
  console.log('\n' + texte);
  log.ok(`Rapport  : ${cfg.paths.report}`);

  const map = await buildOutputs(cfg, store);
  if (map && cfg.openMapWhenDone) openInBrowser(cfg.paths.map);
}

function cmdSchedule(cfg) {
  const ps1 = path.join(ROOT, 'scripts', 'planifier-windows.ps1');
  const sh = path.join(ROOT, 'scripts', 'planifier-cron.sh');
  console.log(`
Exécution quotidienne (7 h 30)

  Windows — colle ceci dans PowerShell, une seule fois :
    powershell -ExecutionPolicy Bypass -File "${ps1}"
    (heure au choix : ajoute -Heure 06:45 ; désinstaller : ajoute -Supprimer)

  macOS / Linux — une seule commande :
    ${sh} 07:30
  (ou à la main dans \`crontab -e\` :)
    30 7 * * * cd "${ROOT}" && ${process.execPath} src/cli.js run --quiet >> data/cron.log 2>&1

Note : la tâche doit tourner sur une session ouverte, le navigateur ayant besoin
du profil connecté (${cfg.paths.profile}).
`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0] ?? 'help';
  const cfg = loadConfig(args.config);
  if (args.headless) cfg.headless = true;
  configureLog({ level: args.quiet ? 'warn' : 'info', file: cfg.paths.log });

  if (cmd !== 'help' && cfg.configPath?.endsWith('config.example.json')) {
    log.warn('config.json absent : les réglages d\'exemple sont utilisés.');
  }

  switch (cmd) {
    case 'annonces':
      return cmdAnnonces(cfg, args);
    case 'login':
      return cmdLogin(cfg);
    case 'run':
      return cmdRun(cfg, args);
    case 'add': {
      const urls = args._.slice(1);
      if (!urls.length) { console.log(USAGE); process.exitCode = 1; return; }
      return cmdAdd(cfg, urls);
    }
    case 'map':
      return void (await buildOutputs(cfg, loadStore(cfg.paths.store)));
    case 'schedule':
      return cmdSchedule(cfg);
    case 'help':
    case '--help':
    case '-h':
      console.log(USAGE);
      return;
    default:
      console.error(`Commande inconnue : ${cmd}`);
      console.log(USAGE);
      process.exitCode = 2;
  }
}

main().catch((err) => {
  log.error(err.stack || err.message);
  process.exitCode = 1;
});
