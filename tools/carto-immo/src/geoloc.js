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

const CHAMPS = [
  'adresse_ban', 'identifiant_ban', 'numero_voie_ban', 'nom_rue_ban', 'code_postal_ban',
  'nom_commune_ban', 'code_insee_ban', 'etiquette_dpe', 'etiquette_ges', '_geopoint',
  'surface_habitable_logement', 'annee_construction', 'date_etablissement_dpe',
  'conso_5_usages_par_m2_ep', 'emission_ges_5_usages_par_m2', 'numero_dpe', 'type_batiment',
].join(',');

// Une agence promeut un bien depuis la ville voisine, rarement au-delà.
const RAYON_KM = 30;
const NOTE_MINIMALE = 80;
const ECART_MINIMAL = 12; // marge exigée sur le deuxième candidat

const TYPE_ADEME = { Maison: 'maison', Appartement: 'appartement', house: 'maison', flat: 'appartement' };

async function json(url, essais = 4) {
  let derniere;
  for (let i = 0; i < essais; i++) {
    try {
      const r = await fetch(url);
      if (r.ok) return r.json();
      derniere = new Error(String(r.status));
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) {
      derniere = e;
    }
    await new Promise((r) => setTimeout(r, 2000 * 2 ** i));
  }
  throw derniere;
}

/** Diagnostics établis le même jour, autour de la position approchée. */
async function diagnosticsCandidats(annonce) {
  if (annonce.flouLat == null || annonce.flouLon == null || !annonce.dateDpe) return [];

  const dy = RAYON_KM / 111;
  const dx = dy / Math.cos((annonce.flouLat * Math.PI) / 180);
  const bbox = [
    annonce.flouLon - dx, annonce.flouLat - dy,
    annonce.flouLon + dx, annonce.flouLat + dy,
  ].join(',');

  const filtres = [`date_etablissement_dpe:${annonce.dateDpe}`];
  if (annonce.dpeAnnonce) filtres.push(`etiquette_dpe:${annonce.dpeAnnonce}`);
  const type = TYPE_ADEME[annonce.typeBien] ?? TYPE_ADEME[annonce.typeBrut];
  if (type) filtres.push(`type_batiment:${type}`);

  const url = `${API}?size=100&bbox=${bbox}&qs=${encodeURIComponent(filtres.join(' AND '))}&select=${CHAMPS}`;
  try {
    return (await json(url)).results ?? [];
  } catch (e) {
    log.warn(`  registre DPE indisponible (${e.message})`);
    return [];
  }
}

/**
 * Note la compatibilité entre une annonce et un diagnostic.
 * @returns {{note:number, motifs:string[], distance:number|null}|null} null si incompatible
 */
export function noterDiagnostic(annonce, d) {
  const motifs = ['date du diagnostic'];
  let note = 35 + 15; // date exacte et étiquette énergie, déjà filtrées

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

  // La consommation annoncée n'est pas toujours l'énergie primaire : elle
  // conforte le rapprochement sans jamais l'écarter.
  const conso = Number(d.conso_5_usages_par_m2_ep);
  if (annonce.consoAnnonce && conso) {
    const ecart = Math.abs(conso - annonce.consoAnnonce) / annonce.consoAnnonce;
    note += ecart <= 0.02 ? 15 : ecart <= 0.08 ? 10 : ecart <= 0.2 ? 4 : 0;
    if (ecart <= 0.08) motifs.push('consommation');
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

  const [lat, lon] = String(d._geopoint).split(',').map(Number);
  let distance = null;
  if (annonce.flouLat != null && Number.isFinite(lat)) {
    distance = metres(annonce.flouLat, annonce.flouLon, lat, lon);
    if (distance > RAYON_KM * 1000) return null;
    note += distance <= 2000 ? 12 : distance <= 8000 ? 8 : distance <= 20000 ? 3 : -10;
  }

  return { note, motifs, distance };
}

const niveau = (note, adresseFine) =>
  note >= 115 && adresseFine ? 'élevée' : note >= 95 ? 'bonne' : 'moyenne';

/**
 * Localise une annonce. Renvoie `null` si aucun diagnostic ne se détache :
 * mieux vaut une annonce sans adresse qu'une adresse fausse.
 */
export async function localiser(annonce) {
  const candidats = await diagnosticsCandidats(annonce);
  const notes = candidats
    .map((d) => {
      const r = noterDiagnostic(annonce, d);
      return r && { d, ...r };
    })
    .filter(Boolean)
    .sort((a, b) => b.note - a.note);

  if (!notes.length) return null;
  const meilleur = notes[0];
  if (meilleur.note < NOTE_MINIMALE) return null;
  if (notes.length > 1 && meilleur.note - notes[1].note < ECART_MINIMAL) return null;

  const d = meilleur.d;
  const [latitude, longitude] = String(d._geopoint).split(',').map(Number);
  const adresseFine = !!d.numero_voie_ban && !!d.nom_rue_ban;

  return {
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
    consoEnergie: Number(d.conso_5_usages_par_m2_ep) || null,
    emissionsGes: Number(d.emission_ges_5_usages_par_m2) || null,
    anneeConstruction: Number(d.annee_construction) || null,
    surfaceDpe: Number(d.surface_habitable_logement) || null,
    note: meilleur.note,
    confiance: niveau(meilleur.note, adresseFine),
    motifs: meilleur.motifs,
    distanceFlouM: meilleur.distance == null ? null : Math.round(meilleur.distance),
    adresseFine,
  };
}

/** Localise une série d'annonces, en série et avec temporisation. */
export async function localiserToutes(annonces, { delaiMs = 400 } = {}) {
  const resultats = [];
  let trouvees = 0;

  for (const [i, a] of annonces.entries()) {
    const loc = await localiser(a).catch((e) => {
      log.warn(`  ${a.url} : ${e.message}`);
      return null;
    });
    if (loc) {
      trouvees++;
      log.debug(`  ${a.url} -> ${loc.adresse} (${loc.confiance})`);
    }
    resultats.push({ annonce: a, localisation: loc });
    if (i < annonces.length - 1) await sleep(delaiMs, 0.2);
  }

  log.info(`${trouvees}/${annonces.length} annonces localisées à l'adresse exacte`);
  return resultats;
}
