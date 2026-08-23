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
    let cle = cleBien(rec);
    // Deux annonces d'une base v1 peuvent partager une empreinte sans désigner
    // le même bien : les écraser perdrait parutions et historique de prix.
    if (store.biens[cle]) {
      let n = 2;
      while (store.biens[`${cle}#${n}`]) n++;
      cle = `${cle}#${n}`;
    }
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

  // Le bien déjà rattaché à cette annonce fait foi : c'est le seul lien certain,
  // là où la clé, elle, peut se préciser d'une analyse à l'autre.
  const parAnnonce = indexAnnonces(store).get(String(annonce.id)) ?? null;

  const doublon = parAnnonce ? null : rapprocherApresAnalyse(fiche, tousLesBiens(store));
  if (doublon) {
    const bien = doublon.bien;
    const ancienneCle = bien.cle;
    Object.assign(bien, fusionnable(fiche));
    bien.cle = ancienneCle; // la fiche fusionnée garde sa place en base
    rattacherAnnonce(bien, annonce, quand);
    bien.analyseLe = quand;
    bien.statut = 'republie';
    bien.motifRapprochement = doublon.motif;
    return { bien, fusionAvec: doublon.motif };
  }

  // Sinon : le bien portant déjà l'annonce, ou celui rangé sous cette clé — à
  // condition que la clé soit une vraie preuve d'identité.
  const sousLaCle = store.biens[cle];
  const cleProbante = !cle.startsWith('empreinte:');
  const existant = parAnnonce ?? (cleProbante ? sousLaCle : null);
  const dejaRattachee = !!parAnnonce;

  const bien = existant ?? { ...fiche, annonces: [], premiereApparition: quand, republications: 0 };
  const ancienneCle = existant?.cle ?? null;
  if (existant) Object.assign(bien, fusionnable(fiche));

  // Deux biens distincts peuvent partager une empreinte : on ne les écrase pas.
  let cleFinale = cle;
  if (!existant && sousLaCle) {
    let n = 2;
    while (store.biens[`${cle}#${n}`]) n++;
    cleFinale = `${cle}#${n}`;
  }

  bien.cle = cleFinale;
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

  // La clé a pu se préciser (empreinte → parcelle) : on déménage la fiche.
  if (ancienneCle && ancienneCle !== cleFinale) delete store.biens[ancienneCle];
  store.biens[cleFinale] = bien;

  return { bien, fusionAvec: null };
}

/**
 * Champs issus de l'analyse, à écraser ; l'historique du bien est préservé.
 *
 * `recalage` en fait partie : c'est une correction faite à la main, elle ne
 * doit jamais être effacée par une nouvelle passe automatique.
 */
function fusionnable(fiche) {
  const {
    annonces, premiereApparition, republications, suiviPrix, statut, cle, recalage, ...reste
  } = fiche;
  return reste;
}

/**
 * Applique des recalages faits depuis la carte.
 *
 * Une correction est indexée par l'identifiant de l'annonce — c'est ce que la
 * carte connaît — et se pose sur le bien qui la porte. Une valeur nulle annule
 * le recalage et rend le bien à sa position automatique.
 *
 * @param {object} store
 * @param {Record<string, object|null>} corrections
 * @returns {{appliques:number, annules:number, inconnus:string[]}}
 */
export function appliquerRecalages(store, corrections) {
  const parAnnonce = indexAnnonces(store);
  const parCle = store.biens;
  let appliques = 0;
  let annules = 0;
  const inconnus = [];

  for (const [id, correction] of Object.entries(corrections ?? {})) {
    const bien = parAnnonce.get(String(id)) ?? parCle[id] ?? null;
    if (!bien) { inconnus.push(id); continue; }
    if (!correction) {
      if (bien.recalage) annules++;
      delete bien.recalage;
      continue;
    }
    bien.recalage = {
      latitude: Number(correction.latitude),
      longitude: Number(correction.longitude),
      parcelle: correction.parcelle ?? null,
      adresse: correction.adresse ?? null,
      source: correction.source ?? 'manuel',
      le: correction.le ?? new Date().toISOString(),
    };
    if (!Number.isFinite(bien.recalage.latitude) || !Number.isFinite(bien.recalage.longitude)) {
      // Une parcelle sans point reste exploitable : son centre servira de point.
      bien.recalage.latitude = null;
      bien.recalage.longitude = null;
      if (!bien.recalage.parcelle) { delete bien.recalage; inconnus.push(id); continue; }
    }
    appliques++;
  }

  return { appliques, annules, inconnus };
}

/** Recalages en base, indexés par identifiant d'annonce principal. */
export function recalagesConnus(store) {
  const out = {};
  for (const bien of tousLesBiens(store)) {
    if (!bien.recalage) continue;
    for (const a of bien.annonces ?? []) out[String(a.id)] = bien.recalage;
  }
  return out;
}

/** Remet tous les biens en « connu » avant une nouvelle exécution. */
export function reinitialiserStatuts(store) {
  for (const bien of tousLesBiens(store)) {
    bien.statut = 'connu';
    bien.prixModifie = null;
  }
}

/**
 * Retient le bilan de localisation d'une zone.
 *
 * Un bilan par zone, remplacé à chaque passage : deux analyses de Marciac ne
 * doivent pas s'additionner, mais Marciac et Beaumarchés, si.
 */
export function enregistrerBilan(store, bilan) {
  if (!bilan) return;
  store.bilans ??= {};
  for (const zone of bilan.zones?.length ? bilan.zones : ['—']) {
    store.bilans[zone] = {
      relevees: bilan.relevees, tentees: bilan.tentees, localisees: bilan.localisees,
      motifs: bilan.motifs ?? {}, le: bilan.le ?? new Date().toISOString(),
      // Une collecte portant sur plusieurs zones ne peut pas être ventilée :
      // on l'inscrit une fois par zone en le disant.
      partage: (bilan.zones?.length ?? 0) > 1,
    };
  }
}

/** Somme des bilans connus, pour l'afficher sur la carte. */
export function resumerBilans(store) {
  const zones = Object.entries(store.bilans ?? {});
  if (!zones.length) return null;
  // Une collecte multi-zones est inscrite à l'identique sous chacune : la
  // compter une fois par zone tromperait sur le volume relevé.
  const vus = new Set();
  const total = { relevees: 0, tentees: 0, localisees: 0, motifs: {}, zones: [], le: null };
  for (const [nom, b] of zones) {
    total.zones.push({ nom, ...b });
    if (!total.le || b.le > total.le) total.le = b.le;
    const cle = b.partage ? `${b.le}|${b.relevees}` : nom;
    if (vus.has(cle)) continue;
    vus.add(cle);
    total.relevees += b.relevees ?? 0;
    total.tentees += b.tentees ?? 0;
    total.localisees += b.localisees ?? 0;
    for (const [m, n] of Object.entries(b.motifs ?? {})) total.motifs[m] = (total.motifs[m] ?? 0) + n;
  }
  total.zones.sort((a, b) => String(b.le).localeCompare(String(a.le)));
  return total;
}

export function allRecords(store) {
  return tousLesBiens(store).sort((a, b) =>
    String(b.derniereApparition ?? '').localeCompare(String(a.derniereApparition ?? ''))
  );
}
