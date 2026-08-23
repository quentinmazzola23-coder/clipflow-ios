import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const DEFAULTS = {
  // Recherches leboncoin à parcourir. Colle ici l'URL d'une recherche
  // (ou d'une recherche sauvegardée) telle qu'elle apparaît dans ton navigateur.
  searches: [],
  // Nombre de pages de résultats parcourues par recherche.
  pagesPerSearch: 2,
  // Plafond d'annonces analysées par exécution (analyse = 1 requête lacquereur).
  maxAnalysesPerRun: 40,
  // Ré-analyser une annonce déjà connue après N jours (0 = jamais).
  reanalyseAfterDays: 14,
  // Attente moyenne entre deux requêtes, en millisecondes. Reste poli.
  delayMs: { leboncoin: 4000, lacquereur: 6000 },
  // Filtres appliqués avant l'appel à lacquereur (économise des requêtes).
  filters: { minPrice: 0, maxPrice: 0, minSurface: 0, propertyTypes: [] },
  // Chemins de sortie, relatifs au dossier de l'outil.
  paths: {
    profile: 'browser-profile',
    data: 'data',
    spreadsheet: 'data/annonces.xlsx',
    csv: 'data/annonces.csv',
    map: 'data/carte.html',
    store: 'data/annonces.json',
    report: 'data/rapport.md',
    log: 'data/agent.log',
  },
  // headless: false est nettement plus fiable face aux protections anti-bot.
  headless: false,
  // 'chrome' utilise le Chrome installé sur la machine, sinon le Chromium de Playwright.
  browserChannel: 'chrome',
  // Ouvre la carte dans le navigateur à la fin d'une exécution réussie.
  openMapWhenDone: true,
};

function deepMerge(base, override) {
  if (override === undefined || override === null) return base;
  if (Array.isArray(base) || typeof base !== 'object') return override;
  const out = { ...base };
  for (const [k, v] of Object.entries(override)) {
    out[k] = k in base ? deepMerge(base[k], v) : v;
  }
  return out;
}

export function loadConfig(explicitPath) {
  const candidates = explicitPath
    ? [path.resolve(explicitPath)]
    : [path.join(ROOT, 'config.json'), path.join(ROOT, 'config.example.json')];

  let raw = {};
  let used = null;
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      raw = JSON.parse(fs.readFileSync(c, 'utf8'));
      used = c;
      break;
    }
  }

  const cfg = deepMerge(DEFAULTS, raw);
  cfg.configPath = used;
  for (const [k, v] of Object.entries(cfg.paths)) {
    cfg.paths[k] = path.isAbsolute(v) ? v : path.join(ROOT, v);
  }
  fs.mkdirSync(cfg.paths.data, { recursive: true });
  return cfg;
}
