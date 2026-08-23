import fs from 'node:fs';
import { cleBien, rapprocher, rapprocherApresAnalyse } from './identity.js';

/**
 * Base locale, un simple fichier JSON. Volume attendu : quelques milliers de
 * fiches au plus, une vraie base serait de la sur-ingénierie ici.
 *
 * L'unité n'est pas l'annonce mais **le bien** : une maison remise en ligne
 * sous un nouvel identifiant reste la même fiche, à laquelle vient s'ajouter
 * une nouvelle parution.
 */

const VERSION = 2;

export function loadStore(file) {
  if (!fs.existsSync(file)) return neuf();
  let brut;
  try {
    brut = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    // Fichier corrompu : on le met de côté plutôt que de perdre l'exécution.
    fs.renameSync(file, `${file}.corrupt-${Date.now()}`);
    return neuf();
  }
  if (brut.version !== VERSION) return migrer(brut);
  brut.biens ??= {};
  return brut;
}

const neuf = () => ({ version: VERSION, updatedAt: null, biens: {} });

/** Reprend une base v1 (une entrée par annonce) dans le modèle par bien. */
function migrer(ancien) {
  const store = neuf();
  for (const rec of Object.values(ancien.records ?? {})) {
    const cle = cleBien(rec);
    store.biens[cle] = {
      ...rec,
      cle,
      annonces: [
        {
          id: rec.id,
          url: rec.urlAnnonce,
          titre: rec.titre,
          prix: rec.prix,
          vuLe: rec.vuePremiereFois ?? rec.collecteLe,
          vuDerniereFois: rec.collecteLe,
          vendeur: rec.vendeur ?? null,
        },
      ],
      idPrincipal: rec.id,
      premiereApparition: rec.vuePremiereFois ?? rec.collecteLe,
      derniereApparition: rec.collecteLe,
      republications: 0,
      statut: 'connu',
      analyseLe: rec.collecteLe,
    };
  }
  return store;
}

export function saveStore(file, store) {
  store.updatedAt = new Date().toISOString();
  fs.writeFileSync(file, JSON.stringify(store, null, 1));
}

export const tousLesBiens = (store) => Object.values(store.biens);

/** Index identifiant d'annonce → bien, reconstruit à la demande. */
function indexAnnonces(store) {
  const idx = new Map();
  for (const bien of tousLesBiens(store)) {
    for (const a of bien.annonces ?? []) idx.set(String(a.id), bien);
  }
  return idx;
}

/** Faut-il (ré)analyser ce bien ? */
export function besoinAnalyse(bien, reanalyseAfterDays) {
  if (!bien?.analyseLe) return true;
  if (!reanalyseAfterDays) return false;
  const age = (Date.now() - new Date(bien.analyseLe).getTime()) / 86400000;
  return age >= reanalyseAfterDays;
}

function noterPrix(bien, prix, date) {
  if (prix == null) return;
  const suivi = (bien.suiviPrix ??= []);
  const dernier = suivi[suivi.length - 1];
  if (!dernier || dernier.prix !== prix) suivi.push({ date: date.slice(0, 10), prix });
}

/** Rattache une parution à un bien connu et met à jour prix et dates. */
export function rattacherAnnonce(bien, annonce, quand) {
  const existante = (bien.annonces ??= []).find((a) => String(a.id) === String(annonce.id));
  if (existante) {
    existante.vuDerniereFois = quand;
    if (annonce.prix != null) existante.prix = annonce.prix;
  } else {
    bien.annonces.push({
      id: annonce.id,
      url: annonce.url,
      titre: annonce.titre ?? null,
      prix: annonce.prix ?? null,
      vuLe: quand,
      vuDerniereFois: quand,
      vendeur: annonce.vendeur ?? null,
    });
    bien.republications = bien.annonces.length - 1;
  }
  bien.idPrincipal = annonce.id;
  bien.derniereApparition = quand;
  if (annonce.prix != null) {
    bien.prix = annonce.prix;
    noterPrix(bien, annonce.prix, quand);
  }
  return bien;
}

/**
 * Trie les annonces collectées en trois paquets.
 *
 * Ne déclenche aucune requête : c'est précisément l'étape qui évite d'envoyer
 * à lacquereur une maison déjà analysée sous une autre annonce.
 */
export function trierAnnonces(store, annonces, cfg, { maintenant = new Date().toISOString() } = {}) {
  const parAnnonce = indexAnnonces(store);
  const biens = tousLesBiens(store);
  const nouveaux = [];
  const republies = [];
  const connus = [];

  for (const annonce of annonces) {
    const dejaVue = parAnnonce.get(String(annonce.id));
    if (dejaVue) {
      const avant = dejaVue.prix;
      rattacherAnnonce(dejaVue, annonce, maintenant);
      dejaVue.prixModifie =
        annonce.prix != null && avant != null && annonce.prix !== avant
          ? { avant, apres: annonce.prix }
          : null;
      connus.push({
        annonce,
        bien: dejaVue,
        prixModifie: dejaVue.prixModifie,
        aReanalyser: besoinAnalyse(dejaVue, cfg.reanalyseAfterDays),
      });
      continue;
    }

    const match = rapprocher(annonce, biens);
    if (match) {
      const avant = match.bien.prix;
      rattacherAnnonce(match.bien, annonce, maintenant);
      parAnnonce.set(String(annonce.id), match.bien);
      match.bien.prixModifie =
        annonce.prix != null && avant != null && annonce.prix !== avant
          ? { avant, apres: annonce.prix }
          : null;
      match.bien.statut = 'republie';
      match.bien.motifRapprochement = match.motifs.join(', ');
      republies.push({
        annonce,
        bien: match.bien,
        motifs: match.motifs,
        note: match.note,
        prixModifie: match.bien.prixModifie,
        aReanalyser: besoinAnalyse(match.bien, cfg.reanalyseAfterDays),
      });
      continue;
    }

    nouveaux.push({ annonce });
  }

  return { nouveaux, republies, connus };
}

/**
 * Enregistre le résultat d'une analyse. Si la localisation révèle que ce bien
 * est déjà en base sous une autre clé — même parcelle cadastrale, typiquement —
 * les deux fiches sont fusionnées.
 *
 * @returns {{bien: object, fusionAvec: string|null}}
 */
export function enregistrerAnalyse(store, fiche, annonce) {
  const quand = fiche.collecteLe;
  const cle = cleBien(fiche);
  fiche.cle = cle;

  const doublon = rapprocherApresAnalyse(fiche, tousLesBiens(store));
  if (doublon) {
    const bien = doublon.bien;
    Object.assign(bien, fusionnable(fiche));
    rattacherAnnonce(bien, annonce, quand);
    bien.analyseLe = quand;
    bien.statut = 'republie';
    bien.motifRapprochement = doublon.motif;
    return { bien, fusionAvec: doublon.motif };
  }

  const existant = store.biens[cle];
  // L'annonce est-elle déjà rattachée à ce bien, ou est-ce une nouvelle parution ?
  const dejaRattachee = existant?.annonces?.some((a) => String(a.id) === String(annonce.id));

  const bien = existant ?? { ...fiche, annonces: [], premiereApparition: quand, republications: 0 };
  if (existant) Object.assign(bien, fusionnable(fiche));

  bien.cle = cle;
  bien.analyseLe = quand;
  if (!existant) {
    bien.statut = 'nouveau';
  } else if (existant.statut === 'republie' || !dejaRattachee) {
    // Bien déjà en base sous une autre annonce : c'est une remise en ligne que
    // le triage n'avait pas su reconnaître, l'analyse vient de la démasquer.
    bien.statut = 'republie';
    // L'analyse fait autorité : son motif remplace celui, plus faible, du triage.
    bien.motifRapprochement = fiche.parcelle ? 'même parcelle cadastrale' : 'même bien';
  } else {
    bien.statut = 'connu';
  }
  rattacherAnnonce(bien, annonce, quand);
  store.biens[cle] = bien;

  // La clé a pu se préciser (empreinte → parcelle) : on retire l'ancienne.
  if (existant && existant.cle && existant.cle !== cle) delete store.biens[existant.cle];

  return { bien, fusionAvec: null };
}

/** Champs issus de l'analyse, à écraser ; l'historique du bien est préservé. */
function fusionnable(fiche) {
  const { annonces, premiereApparition, republications, suiviPrix, statut, cle, ...reste } = fiche;
  return reste;
}

/** Remet tous les biens en « connu » avant une nouvelle exécution. */
export function reinitialiserStatuts(store) {
  for (const bien of tousLesBiens(store)) {
    bien.statut = 'connu';
    bien.prixModifie = null;
  }
}

export function allRecords(store) {
  return tousLesBiens(store).sort((a, b) =>
    String(b.derniereApparition ?? '').localeCompare(String(a.derniereApparition ?? ''))
  );
}
