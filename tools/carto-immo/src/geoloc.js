import { log, sleep } from './log.js';
import { metres } from './cadastre.js';

/**
 * Localisation exacte d'une annonce par appariement avec le registre des DPE.
 *
 * Les sites d'annonces ne publient jamais l'adresse : ils affichent un disque
 * de floutage centré sur la commune. En revanche l'annonce porte les données de
 * son diagnostic — date, étiquettes, consommation, surface — et ces diagnostics
 * sont publiés en open data par l'ADEME, **avec l'adresse et les coordonnées**.
 *
 * Retrouver le diagnostic, c'est retrouver le bien. Un couple date + étiquette
 * est déjà très discriminant à l'échelle d'un canton ; la surface et la
 * consommation lèvent le reste de l'ambiguïté.
 *
 * Le doute ne se transforme jamais en certitude : chaque rapprochement porte
 * une note et un niveau de confiance, et l'absence de rapprochement net laisse
 * l'annonce sans adresse plutôt que de lui en inventer une.
 */

const API = 'https://data.ademe.fr/data-fair/api/v1/datasets/dpe03existant/lines';

// Le socle : ces colonnes existent, la chaîne tourne dessus depuis le début.
const CHAMPS_SURS = [
  'adresse_ban', 'identifiant_ban', 'numero_voie_ban', 'nom_rue_ban', 'code_postal_ban',
  'nom_commune_ban', 'code_insee_ban', 'etiquette_dpe', 'etiquette_ges', '_geopoint',
  'surface_habitable_logement', 'annee_construction', 'date_etablissement_dpe',
  'conso_5_usages_par_m2_ep', 'emission_ges_5_usages_par_m2', 'numero_dpe', 'type_batiment',
];

/**
 * Colonnes qui affinent le jugement quand le millésime les porte : l'énergie
 * finale, que bien des annonces affichent à la place de l'énergie primaire, et
 * la commune déclarée. Le jeu de données évolue : leur absence ne doit rien
 * casser, d'où le repli sur le socle en cas de refus.
 *
 * `score_ban` et `statut_geocodage` ont été essayés puis retirés : mesurés sur
 * le secteur de Marciac, ils ne disent rien de la précision du point. Le score
 * médian y vaut 0,46 pour des adresses parfaitement exactes — c'est un score
 * de rapprochement de chaîne, pas de position — et des enregistrements marqués
 * « non géocodée » portent malgré tout un numéro et une rue justes. S'en servir
 * coûtait neuf biens sur la carte sans écarter une seule erreur.
 */
const CHAMPS_BONUS = [
  'conso_5_usages_par_m2_ef', 'nom_commune_brut', 'code_postal_brut',
];

// Une agence promeut un bien depuis la ville voisine, rarement au-delà.
const RAYON_KM = 30;
const NOTE_MINIMALE = 80;
const ECART_MINIMAL = 12; // marge exigée sur le deuxième candidat
const TAILLE = 1000; // plafond d'un lot renvoyé par l'API
// Rétrécissements successifs quand le jour est trop chargé pour départager.
const RAYONS_KM = [RAYON_KM, 12, 5];
const JOURS_VOISINS = 3; // repêchage quand la date exacte ne donne rien

const TYPE_ADEME = { Maison: 'maison', Appartement: 'appartement', house: 'maison', flat: 'appartement' };

/** État du cache des colonnes : le premier refus fait basculer tout le lot. */
let champsBonusDisponibles = true;

const champs = () => (champsBonusDisponibles ? [...CHAMPS_SURS, ...CHAMPS_BONUS] : CHAMPS_SURS).join(',');

async function json(url, essais = 4) {
  let derniere;
  for (let i = 0; i < essais; i++) {
    try {
      const r = await fetch(url);
      if (r.ok) return r.json();
      derniere = new Error(String(r.status));
      derniere.status = r.status;
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) {
      derniere = e;
    }
    await new Promise((r) => setTimeout(r, 2000 * 2 ** i));
  }
  throw derniere;
}

/** Un jour décalé de n jours, au format du registre. */
function jourDecale(iso, n) {
  const t = Date.parse(`${iso}T00:00:00Z`);
  if (!Number.isFinite(t)) return null;
  return new Date(t + n * 86400000).toISOString().slice(0, 10);
}

/** Interroge le registre pour un filtre donné, en rétrécissant si le lot déborde. */
async function interroger(annonce, filtres) {
  const type = TYPE_ADEME[annonce.typeBien] ?? TYPE_ADEME[annonce.typeBrut];
  const tous = [...filtres];
  if (annonce.dpeAnnonce) tous.push(`etiquette_dpe:${annonce.dpeAnnonce}`);
  if (type) tous.push(`type_batiment:${type}`);
  const qs = encodeURIComponent(tous.join(' AND '));

  for (const rayon of RAYONS_KM) {
    const dy = rayon / 111;
    const dx = dy / Math.cos((annonce.flouLat * Math.PI) / 180);
    const bbox = [
      annonce.flouLon - dx, annonce.flouLat - dy,
      annonce.flouLon + dx, annonce.flouLat + dy,
    ].join(',');
    const url = `${API}?size=${TAILLE}&bbox=${bbox}&qs=${qs}&select=${champs()}`;

    let res;
    try {
      res = await json(url);
    } catch (e) {
      // Une colonne absente du millésime fait rejeter la requête entière : on
      // retombe sur le socle plutôt que de perdre la localisation.
      if (e.status === 400 && champsBonusDisponibles) {
        champsBonusDisponibles = false;
        log.warn('  colonnes étendues refusées par le registre : retour au jeu de base');
        return interroger(annonce, filtres);
      }
      log.warn(`  registre DPE indisponible (${e.message})`);
      return { lot: [], motif: 'registre indisponible' };
    }

    // Un lot tronqué fausserait le départage. Plutôt que de renoncer, on
    // resserre la fenêtre : le bien est de toute façon près du disque flou.
    if (res.total > TAILLE) continue;
    return { lot: res.results ?? [], motif: null };
  }

  log.warn(`  plus de ${TAILLE} diagnostics même à ${RAYONS_KM[RAYONS_KM.length - 1]} km : impossible de départager`);
  return { lot: [], motif: 'trop de diagnostics pour départager' };
}

/**
 * Diagnostics candidats, par passes de plus en plus larges.
 *
 * @returns {Promise<{lot:object[], dateExacte:boolean, motif:string|null}>}
 */
async function diagnosticsCandidats(annonce) {
  if (annonce.flouLat == null || annonce.flouLon == null) {
    return { lot: [], dateExacte: true, motif: 'annonce sans position approchée' };
  }
  if (!annonce.dateDpe) {
    return { lot: [], dateExacte: true, motif: 'annonce sans date de diagnostic' };
  }

  const exact = await interroger(annonce, [`date_etablissement_dpe:${annonce.dateDpe}`]);
  if (exact.lot.length) return { lot: exact.lot, dateExacte: true, motif: null };
  if (exact.motif) return { lot: [], dateExacte: true, motif: exact.motif };

  // Rien ce jour-là : la date affichée par le site peut être celle de la visite,
  // ou décalée d'un jour par un fuseau horaire. On élargit de quelques jours,
  // en sachant que la note du candidat baissera d'autant.
  const debut = jourDecale(annonce.dateDpe, -JOURS_VOISINS);
  const fin = jourDecale(annonce.dateDpe, JOURS_VOISINS);
  if (!debut || !fin) return { lot: [], dateExacte: true, motif: 'date de diagnostic illisible' };
  const voisins = await interroger(annonce, [`date_etablissement_dpe:[${debut} TO ${fin}]`]);
  return {
    lot: voisins.lot,
    dateExacte: false,
    motif: voisins.lot.length ? null : voisins.motif ?? 'aucun diagnostic ce jour-là dans le secteur',
  };
}

// ── Notation ──────────────────────────────────────────────────────────────

const sansAccent = (s) =>
  String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z]+/g, '');

/**
 * Jusqu'où descend l'adresse du diagnostic : un numéro, une voie, ou rien de
 * plus qu'un lieu.
 *
 * Seul ce que porte l'adresse elle-même est retenu, parce que c'est la seule
 * chose vérifiable. Un lieu-dit sans numéro ni rue reste une adresse
 * parfaitement valable à la campagne : on ne lui retire pas de points, on
 * refuse seulement de la dire « exacte au numéro ».
 *
 * @returns {'numero'|'voie'|'inconnu'}
 */
export function qualiteGeocodage(d) {
  if (d.numero_voie_ban && d.nom_rue_ban) return 'numero';
  if (d.nom_rue_ban) return 'voie';
  return 'inconnu';
}

/**
 * Note la compatibilité entre une annonce et un diagnostic.
 *
 * @param {object} annonce
 * @param {object} d enregistrement du registre
 * @param {object} [opts]
 * @param {boolean} [opts.dateExacte] la date du diagnostic tombe pile sur celle annoncée
 * @returns {{note:number, motifs:string[], distance:number|null, qualite:string}|null}
 *   null si le diagnostic est incompatible
 */
export function noterDiagnostic(annonce, d, { dateExacte = true } = {}) {
  const motifs = [dateExacte ? 'date du diagnostic' : 'date du diagnostic à quelques jours'];
  // Une date voisine reste un indice fort, mais ce n'est plus une coïncidence
  // exacte : elle ne peut pas peser autant.
  let note = dateExacte ? 35 : 24;
  if (annonce.dpeAnnonce) {
    if (d.etiquette_dpe && d.etiquette_dpe !== annonce.dpeAnnonce) return null;
    note += 15;
    motifs.push('étiquette énergie');
  }

  const type = TYPE_ADEME[annonce.typeBien] ?? TYPE_ADEME[annonce.typeBrut];
  if (type && d.type_batiment) {
    if (d.type_batiment !== type) return null;
    note += 10;
  }

  // Une étiquette climat qui diverge désigne un autre logement.
  if (annonce.gesAnnonce && d.etiquette_ges) {
    if (d.etiquette_ges !== annonce.gesAnnonce) return null;
    note += 15;
    motifs.push('étiquette climat');
  }

  const surface = Number(d.surface_habitable_logement);
  if (annonce.surface && surface) {
    const ecart = Math.abs(surface - annonce.surface) / annonce.surface;
    if (ecart > 0.25) return null;
    note += ecart <= 0.01 ? 25 : ecart <= 0.05 ? 18 : ecart <= 0.1 ? 12 : 5;
    if (ecart <= 0.05) motifs.push('surface');
  }

  // La consommation annoncée n'est pas toujours l'énergie primaire : les sites
  // affichent tantôt l'une, tantôt l'autre. On retient la meilleure des deux
  // lectures, et elle conforte le rapprochement sans jamais l'écarter.
  if (annonce.consoAnnonce) {
    let meilleur = null;
    for (const champ of ['conso_5_usages_par_m2_ep', 'conso_5_usages_par_m2_ef']) {
      const v = Number(d[champ]);
      if (!v) continue;
      const ecart = Math.abs(v - annonce.consoAnnonce) / annonce.consoAnnonce;
      if (meilleur == null || ecart < meilleur) meilleur = ecart;
    }
    if (meilleur != null) {
      note += meilleur <= 0.02 ? 15 : meilleur <= 0.08 ? 10 : meilleur <= 0.2 ? 4 : 0;
      if (meilleur <= 0.08) motifs.push('consommation');
    }
  }

  const ges = Number(d.emission_ges_5_usages_par_m2);
  if (annonce.emissionsAnnonce && ges &&
      Math.abs(ges - annonce.emissionsAnnonce) <= Math.max(1, annonce.emissionsAnnonce * 0.1)) {
    note += 8;
    motifs.push('émissions');
  }

  if (annonce.anneeConstruction && d.annee_construction &&
      Math.abs(Number(d.annee_construction) - annonce.anneeConstruction) <= 3) {
    note += 6;
    motifs.push('année de construction');
  }

  // Sans position exploitable, le diagnostic ne peut pas localiser : il sort.
  const [lat, lon] = String(d._geopoint ?? '').split(',').map(Number);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;

  // Le code postal et la commune de l'annonce disent où **l'agence** situe le
  // bien, pas où il est. Mesuré autour de Marciac : des annonces diffusées sous
  // ce nom désignent des maisons à Troncens, Tillac ou Marseillan, sept à douze
  // kilomètres plus loin, avec des concordances de note supérieures à 120. Une
  // divergence n'écarte donc rien ; une concordance ne vaut qu'un petit appoint,
  // trop faible pour créer à elle seule l'écart exigé sur le second candidat.
  const cpAnnonce = String(annonce.codePostal ?? '').trim();
  const cpDpe = String(d.code_postal_ban ?? d.code_postal_brut ?? '').trim();
  if (cpAnnonce && cpAnnonce === cpDpe) { note += 4; motifs.push('code postal'); }

  const villeAnnonce = sansAccent(annonce.ville);
  const villeDpe = sansAccent(d.nom_commune_ban ?? d.nom_commune_brut);
  if (villeAnnonce && villeAnnonce === villeDpe) { note += 4; motifs.push('commune'); }

  let distance = null;
  if (annonce.flouLat != null) {
    // Le rayon publié par le site a été essayé comme contrainte dure, puis
    // retiré : sa position de référence est celle de la ville de diffusion, pas
    // un point flouté proche du bien. Un rayon de 250 m accompagne couramment un
    // bien situé à onze kilomètres. Seul le rayon de diffusion reste opposable.
    distance = metres(annonce.flouLat, annonce.flouLon, lat, lon);
    if (distance > RAYON_KM * 1000) return null;
    note += distance <= 2000 ? 12 : distance <= 8000 ? 8 : distance <= 20000 ? 3 : -10;
  }

  // La finesse de l'adresse ne retranche rien : elle plafonne la confiance.
  return { note, motifs, distance, qualite: qualiteGeocodage(d) };
}

/**
 * Niveau de confiance affiché. Le géocodage plafonne : une note superbe posée
 * sur un point de commune reste une adresse approchée.
 */
export function niveauConfiance(note, qualite) {
  // « Élevée » suppose une adresse descendue jusqu'au numéro : sans cette
  // précision, la note la plus haute vaut « bonne », pas mieux.
  if (note >= 115 && qualite === 'numero') return 'élevée';
  return note >= 95 ? 'bonne' : 'moyenne';
}

/** Fiche d'un diagnostic, telle qu'affichée dans le bloc de vérification. */
function candidat(n) {
  const d = n.d;
  const [latitude, longitude] = String(d._geopoint).split(',').map(Number);
  return {
    numeroDpe: d.numero_dpe ?? null,
    adresse: d.adresse_ban ?? null,
    latitude,
    longitude,
    banId: d.identifiant_ban ?? null,
    codeInsee: d.code_insee_ban ?? null,
    codePostal: d.code_postal_ban ?? null,
    commune: d.nom_commune_ban ?? null,
    surfaceDpe: Number(d.surface_habitable_logement) || null,
    note: n.note,
    motifs: n.motifs,
    qualite: n.qualite,
    confiance: niveauConfiance(n.note, n.qualite),
    distanceFlouM: n.distance == null ? null : Math.round(n.distance),
  };
}

/**
 * Localise une annonce.
 *
 * Renvoie toujours un verdict : soit l'adresse, soit la raison pour laquelle on
 * a renoncé. Le silence serait le pire des résultats — on ne saurait pas si la
 * moitié des annonces manquantes tient à un registre muet ou à une exigence
 * trop haute.
 *
 * Le résultat porte aussi les diagnostics écartés de peu : ce sont eux qu'on
 * propose quand il faut recaler le bien à la main.
 *
 * @returns {Promise<{localisation:object|null, motif:string|null, examines:number}>}
 */
export async function localiser(annonce) {
  const { lot, dateExacte, motif } = await diagnosticsCandidats(annonce);
  if (motif) return { localisation: null, motif, examines: 0 };
  const notes = lot
    .map((d) => {
      const r = noterDiagnostic(annonce, d, { dateExacte });
      return r && { d, ...r };
    })
    .filter(Boolean)
    .sort((a, b) => b.note - a.note);

  if (!notes.length) {
    return { localisation: null, motif: 'aucun diagnostic compatible', examines: lot.length };
  }
  const meilleur = notes[0];

  // Un même logement peut porter deux diagnostics : ce n'est pas une ambiguïté
  // de localisation, seule l'adresse nous intéresse.
  const memeLogement = (a, b) =>
    (a.identifiant_ban && a.identifiant_ban === b.identifiant_ban) ||
    (a.adresse_ban && a.adresse_ban === b.adresse_ban && a._geopoint === b._geopoint);
  const concurrents = notes.slice(1).filter((n) => !memeLogement(n.d, meilleur.d));
  const ecartSecond = concurrents.length ? meilleur.note - concurrents[0].note : null;

  // Les concurrents sérieux restent disponibles pour un recalage manuel, même
  // quand ils font échouer le rapprochement automatique : c'est justement là
  // qu'un œil humain tranche mieux que la note.
  const alternatives = concurrents.slice(0, 4).map(candidat);

  if (meilleur.note < NOTE_MINIMALE) {
    return { localisation: null, motif: 'concordance trop faible', examines: lot.length, alternatives };
  }
  if (ecartSecond != null && ecartSecond < ECART_MINIMAL) {
    return { localisation: null, motif: 'deux logements également plausibles', examines: lot.length, alternatives };
  }

  const d = meilleur.d;
  const [latitude, longitude] = String(d._geopoint).split(',').map(Number);

  const localisation = {
    adresse: d.adresse_ban,
    latitude,
    longitude,
    banId: d.identifiant_ban ?? null,
    codePostal: d.code_postal_ban ?? null,
    commune: d.nom_commune_ban ?? null,
    codeInsee: d.code_insee_ban ?? null,
    numeroDpe: d.numero_dpe ?? null,
    dpe: d.etiquette_dpe ?? null,
    ges: d.etiquette_ges ?? null,
    consoEnergie: Number(d.conso_5_usages_par_m2_ep) || Number(d.conso_5_usages_par_m2_ef) || null,
    emissionsGes: Number(d.emission_ges_5_usages_par_m2) || null,
    anneeConstruction: Number(d.annee_construction) || null,
    surfaceDpe: Number(d.surface_habitable_logement) || null,
    note: meilleur.note,
    confiance: niveauConfiance(meilleur.note, meilleur.qualite),
    qualiteGeocodage: meilleur.qualite,
    dateExacte,
    motifs: meilleur.motifs,
    distanceFlouM: meilleur.distance == null ? null : Math.round(meilleur.distance),
    adresseFine: meilleur.qualite === 'numero',
    ecartSecond,
    alternatives,
  };
  return { localisation, motif: null, examines: lot.length };
}

/**
 * Localise une série d'annonces, en série et avec temporisation.
 *
 * Le bilan compte ce qui a été tenté et ce qui a abouti, avec la raison de
 * chaque renoncement : c'est ce qui permet de juger l'outil sur pièces plutôt
 * que sur un taux global.
 */
export async function localiserToutes(annonces, { delaiMs = 400 } = {}) {
  const resultats = [];
  const motifs = {};
  // Par commune de diffusion : c'est sous ce nom que l'annonce a été vue, et
  // c'est ce nom qu'on clique sur la carte. La commune réelle du bien, elle,
  // n'est connue que pour les annonces qui ont abouti.
  const diffusion = {};
  let trouvees = 0;
  let tentees = 0;

  for (const [i, a] of annonces.entries()) {
    const r = await localiser(a).catch((e) => {
      log.warn(`  ${a.url} : ${e.message}`);
      return { localisation: null, motif: 'erreur pendant la recherche', examines: 0 };
    });
    // « Tentée » veut dire : l'annonce portait de quoi chercher. Une annonce
    // sans diagnostic n'a jamais eu sa chance, la compter en échec fausserait
    // le taux de réussite.
    const tentee = r.motif !== 'annonce sans date de diagnostic'
      && r.motif !== 'annonce sans position approchée';
    if (tentee) tentees++;

    const sousCeNom = (diffusion[a.ville || '—'] ??= { vues: 0, tentees: 0, localisees: 0, certaines: 0 });
    sousCeNom.vues++;
    if (tentee) sousCeNom.tentees++;

    if (r.localisation) {
      trouvees++;
      sousCeNom.localisees++;
      // « Avec certitude » : une adresse descendue au numéro et nettement
      // détachée de ses concurrentes. Le reste demande un coup d'œil.
      if (r.localisation.confiance === 'élevée') sousCeNom.certaines++;
      log.debug(`  ${a.url} -> ${r.localisation.adresse} (${r.localisation.confiance})`);
    } else {
      motifs[r.motif] = (motifs[r.motif] ?? 0) + 1;
      log.debug(`  ${a.url} : ${r.motif}`);
    }
    resultats.push({ annonce: a, localisation: r.localisation, motif: r.motif });
    if (i < annonces.length - 1) await sleep(delaiMs, 0.2);
  }

  const bilan = { relevees: annonces.length, tentees, localisees: trouvees, motifs, diffusion };
  log.info(`${trouvees}/${tentees} annonces localisées (${annonces.length} relevées)`);
  for (const [m, n] of Object.entries(motifs).sort((a, b) => b[1] - a[1])) {
    log.info(`  ${n} × ${m}`);
  }
  return { resultats, bilan };
}
