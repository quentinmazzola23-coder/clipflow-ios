import http from 'node:http';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import {
  loadStore, saveStore, reinitialiserStatuts, enregistrerAnalyse,
  appliquerRecalages, enregistrerBilan, tousLesBiens,
} from './store.js';
import { collecterEtLocaliser } from './pipeline-annonces.js';
import { construireSorties } from './sorties.js';
import { log, observerLog } from './log.js';

/**
 * Agent local : la carte cesse d'être une photographie du matin pour devenir
 * une console de prospection.
 *
 * Deux gestes qu'un fichier HTML seul ne peut pas rendre :
 *   — cliquer sur un village et demander l'analyse de toutes ses annonces ;
 *   — corriger la position d'un bien, et que la correction survive à la
 *     prochaine exécution.
 *
 * Le serveur n'écoute que sur la boucle locale. Il ne sert que les fichiers
 * produits par l'outil, jamais un chemin venu de la requête.
 */

const TAILLE_MAX_CORPS = 512 * 1024;
const TYPES = { '.html': 'text/html; charset=utf-8', '.csv': 'text/csv; charset=utf-8' };

export function demarrerServeur(cfg, { port = 4173, hote = '127.0.0.1' } = {}) {
  /** @type {Map<string, {lignes:string[], fini:boolean, resume:string|null, erreur:string|null}>} */
  const travaux = new Map();
  let occupe = false;

  const serveur = http.createServer((req, res) => {
    router(req, res).catch((e) => {
      // Une requête mal formée est une erreur de l'appelant, pas une panne :
      // elle ne mérite ni un 500 ni une trace dans le journal.
      if (e.code === 'requete') return repondre(res, 400, { erreur: e.message });
      log.error(`agent : ${e.stack || e.message}`);
      repondre(res, 500, { erreur: e.message });
    });
  });

  async function router(req, res) {
    const url = new URL(req.url, `http://${hote}`);
    const chemin = url.pathname;

    if (chemin === '/' || chemin === '/carte.html') return servirCarte(res);
    if (chemin === '/annonces.csv') return servirFichier(res, cfg.paths.csv);

    if (chemin === '/api/etat' && req.method === 'GET') {
      const store = loadStore(cfg.paths.store);
      return repondre(res, 200, {
        agent: 'carto-immo',
        biens: tousLesBiens(store).length,
        occupe,
        zones: cfg.bienici?.zones ?? [],
      });
    }

    if (chemin === '/api/commune' && req.method === 'GET') {
      return repondre(res, 200, await commune(url.searchParams));
    }

    if (chemin === '/api/recalage' && req.method === 'POST') {
      const corrections = await corps(req);
      const store = loadStore(cfg.paths.store);
      const bilan = appliquerRecalages(store, corrections);
      saveStore(cfg.paths.store, store);
      log.info(`recalage : ${bilan.appliques} appliqué(s), ${bilan.annules} annulé(s)`);
      return repondre(res, 200, bilan);
    }

    if (chemin === '/api/zone' && req.method === 'POST') {
      const { zone } = await corps(req);
      if (!zone || typeof zone !== 'string') return repondre(res, 400, { erreur: 'zone manquante' });
      if (occupe) return repondre(res, 409, { erreur: 'une analyse est déjà en cours' });
      const id = randomUUID();
      travaux.set(id, { lignes: [], fini: false, resume: null, erreur: null });
      // On répond tout de suite : la collecte dure des minutes, la carte suit
      // l'avancement en interrogeant /api/travail.
      analyserZone(id, zone);
      return repondre(res, 202, { id, zone });
    }

    if (chemin.startsWith('/api/travail/') && req.method === 'GET') {
      const t = travaux.get(chemin.slice('/api/travail/'.length));
      if (!t) return repondre(res, 404, { erreur: 'travail inconnu' });
      return repondre(res, 200, t);
    }

    repondre(res, 404, { erreur: 'inconnu' });
  }

  /** Collecte une commune, l'ajoute à la base, régénère les sorties. */
  async function analyserZone(id, zone) {
    const t = travaux.get(id);
    occupe = true;
    const detacher = observerLog(({ level, line }) => {
      if (level === 'debug') return;
      t.lignes.push(line);
      if (t.lignes.length > 200) t.lignes.shift();
    });

    try {
      log.step(`Analyse demandée depuis la carte : ${zone}`);
      const store = loadStore(cfg.paths.store);
      reinitialiserStatuts(store);

      const { fiches, bilan, total, localisees } = await collecterEtLocaliser([zone], {
        types: cfg.bienici?.types ?? ['house'],
        max: cfg.bienici?.max ?? 200,
        cacheDir: cfg.paths.cache,
        cadastre: cfg.cadastre,
        filtres: cfg.filters,
      });

      let ajoutes = 0;
      for (const fiche of fiches) {
        // Une annonce sans adresse établie ne rentre pas : on ne place pas un
        // bien sur un point qu'on n'a pas établi.
        if (!fiche.localisationPrecise) continue;
        const { bien } = enregistrerAnalyse(store, fiche, {
          id: fiche.id, url: fiche.urlAnnonce, titre: fiche.titre,
          prix: fiche.prix, vendeur: fiche.vendeur,
        });
        if (bien.statut === 'nouveau') ajoutes++;
      }
      enregistrerBilan(store, bilan);
      saveStore(cfg.paths.store, store);
      await construireSorties(cfg, store);

      t.resume = `${localisees}/${total} localisées, ${ajoutes} nouvelle${ajoutes > 1 ? 's' : ''}`;
      log.ok(`${zone} : ${t.resume}`);
    } catch (e) {
      t.erreur = e.message;
      t.resume = `échec : ${e.message}`;
      log.error(`${zone} : ${e.stack || e.message}`);
    } finally {
      detacher();
      t.fini = true;
      occupe = false;
      // Un travail terminé n'a plus d'intérêt passé quelques minutes.
      setTimeout(() => travaux.delete(id), 600000).unref?.();
    }
  }

  function servirCarte(res) {
    if (!fs.existsSync(cfg.paths.map)) {
      return repondre(res, 503, { erreur: 'carte pas encore générée' });
    }
    servirFichier(res, cfg.paths.map);
  }

  function servirFichier(res, chemin) {
    if (!fs.existsSync(chemin)) return repondre(res, 404, { erreur: 'absent' });
    const type = TYPES[chemin.slice(chemin.lastIndexOf('.'))] ?? 'application/octet-stream';
    res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' });
    fs.createReadStream(chemin).pipe(res);
  }

  return new Promise((resolve) => {
    serveur.listen(port, hote, () => resolve({ serveur, url: `http://${hote}:${port}/` }));
  });
}

function repondre(res, code, donnees) {
  const corpsTexte = JSON.stringify(donnees);
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(corpsTexte);
}

const erreurRequete = (message) => Object.assign(new Error(message), { code: 'requete' });

function corps(req) {
  return new Promise((resolve, reject) => {
    let brut = '';
    req.on('data', (c) => {
      brut += c;
      // Une requête démesurée ne doit pas remplir la mémoire de l'agent.
      if (brut.length > TAILLE_MAX_CORPS) { req.destroy(); reject(erreurRequete('corps trop volumineux')); }
    });
    req.on('end', () => {
      try { resolve(brut ? JSON.parse(brut) : {}); } catch { reject(erreurRequete('JSON invalide')); }
    });
    req.on('error', reject);
  });
}

/** Commune sous un point, par l'API Géo de l'État. */
async function commune(params) {
  const lat = Number(params.get('lat'));
  const lon = Number(params.get('lon'));
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return { erreur: 'coordonnées invalides' };
  const url = `https://geo.api.gouv.fr/communes?fields=nom,code&lat=${lat}&lon=${lon}`;
  try {
    const r = await fetch(url);
    if (!r.ok) return { erreur: String(r.status) };
    const l = await r.json();
    return l?.[0] ? { nom: l[0].nom, insee: l[0].code } : { erreur: 'aucune commune ici' };
  } catch (e) {
    return { erreur: e.message };
  }
}
