import { log, sleep } from './log.js';

/**
 * Collecteur d'annonces Bien'ici.
 *
 * Complète leboncoin, dont la protection anti-robot impose un navigateur : ici
 * une simple requête HTTP suffit, ce qui rend la veille possible même sans
 * session ouverte. Les annonces sont les mêmes offres, souvent diffusées sur
 * les deux sites.
 *
 * Bien'ici ne publie pas la position exacte des biens : chaque annonce porte un
 * disque de floutage centré sur la ville d'affichage. La localisation précise
 * est l'affaire de `geoloc.js`.
 */

const RECHERCHE = 'https://www.bienici.com/realEstateAds.json';
const SUGGESTION = 'https://res.bienici.com/suggest.json';
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

async function json(url, essais = 4) {
  let derniere;
  for (let i = 0; i < essais; i++) {
    try {
      const r = await fetch(url, { headers: { 'User-Agent': UA, Accept: 'application/json' } });
      if (r.ok) return r.json();
      derniere = new Error(`${r.status} sur ${url.split('?')[0]}`);
      if (r.status < 500 && r.status !== 429) break;
    } catch (e) {
      derniere = e;
    }
    await new Promise((r) => setTimeout(r, 2000 * 2 ** i));
  }
  throw derniere;
}

/** Retrouve la zone Bien'ici d'une commune à partir de son nom ou de son code INSEE. */
export async function trouverZone(recherche) {
  const res = await json(`${SUGGESTION}?q=${encodeURIComponent(recherche)}`);
  const zones = (Array.isArray(res) ? res : []).filter((z) => z.zoneIds?.length);
  const exact = zones.find((z) => z.insee_code === recherche || z.insee_codes?.includes(recherche));
  // À défaut de code INSEE, on privilégie une commune dont le nom correspond :
  // la première suggestion venue peut être un département homonyme.
  const cle = (v) => String(v ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const nomExact = zones.find((z) => z.type === 'city' && cle(z.name) === cle(recherche));
  const choisie = exact ?? nomExact ?? zones.find((z) => z.type === 'city') ?? zones[0];
  if (!choisie) throw new Error(`zone introuvable pour « ${recherche} »`);
  return {
    id: choisie.zoneIds[0],
    nom: choisie.name,
    insee: choisie.insee_code ?? choisie.insee_codes?.[0] ?? null,
    type: choisie.type,
  };
}

const PAR_PAGE = 50;

/**
 * Le site renvoie « 1970-01-01 » quand il ignore la date : la sentinelle doit
 * être lue comme une absence, sinon l'annonce paraît en ligne depuis 56 ans.
 */
function dateOuRien(v) {
  if (!v) return null;
  const t = Date.parse(v);
  if (!Number.isFinite(t)) return null;
  return new Date(t).getUTCFullYear() > 2000 ? new Date(t).toISOString() : null;
}

/** Normalise une annonce Bien'ici en fiche exploitable par le reste du pipeline. */
function normaliserAnnonce(a) {
  const flou = a.blurInfo?.position ?? a.blurInfo?.centroid ?? null;
  return {
    id: String(a.id),
    source: 'bienici',
    url: `https://www.bienici.com/annonce/${a.id}`,
    titre: a.title ?? null,
    prix: a.price ?? null,
    ville: a.city ?? null,
    codePostal: a.postalCode ?? null,
    surface: a.surfaceArea ?? null,
    terrain: a.landSurfaceArea ?? null,
    pieces: a.roomsQuantity ?? null,
    chambres: a.bedroomsQuantity ?? null,
    typeBien: a.propertyType === 'house' ? 'Maison' : a.propertyType === 'flat' ? 'Appartement' : a.propertyType,
    typeBrut: a.propertyType ?? null,
    dpeAnnonce: a.energyClassification ?? null,
    gesAnnonce: a.greenhouseGazClassification ?? null,
    consoAnnonce: a.energyValue ?? null,
    emissionsAnnonce: a.greenhouseGazValue ?? null,
    dateDpe: a.energyPerformanceDiagnosticDate?.slice(0, 10) ?? null,
    anneeConstruction: a.yearOfConstruction ?? null,
    publiee: dateOuRien(a.publicationDate),
    modifiee: dateOuRien(a.modificationDate),
    prixBaisse: !!a.priceHasDecreased,
    vendeur: a.adCreatedByPro ? 'Professionnel' : 'Particulier',
    vendeurType: a.adCreatedByPro ? 'pro' : 'part',
    photo: a.photos?.[0]?.url_photo ?? null,
    photos: (a.photos ?? []).slice(0, 8).map((p) => p.url_photo).filter(Boolean),
    description: a.description ?? null,
    jardin: a.hasGarden ?? null,
    terrasse: a.hasTerrace ?? null,
    piscine: a.hasPool ?? null,
    parking: a.hasGarage ?? null,
    // Position approchée fournie par le site, point de départ de la localisation.
    flouLat: flou?.lat ?? null,
    flouLon: flou?.lon ?? null,
    flouRayon: a.blurInfo?.radius ?? null,
  };
}

/**
 * Relève les annonces d'une zone.
 *
 * @param {string} zoneId identifiant de zone Bien'ici
 * @param {object} [opts]
 * @param {string[]} [opts.types] 'house', 'flat', 'terrain'…
 * @param {number} [opts.max] plafond d'annonces relevées
 * @param {number} [opts.delaiMs] temporisation entre deux pages
 */
export async function collecterZone(zoneId, { types = ['house'], max = 200, delaiMs = 1200 } = {}) {
  const parId = new Map();
  let page = 1;
  let total = null;
  let vues = 0;

  while (parId.size < max) {
    const filtres = {
      size: PAR_PAGE,
      from: vues,
      filterType: 'buy',
      propertyType: types,
      page,
      sortBy: 'publicationDate',
      sortOrder: 'desc',
      onTheMarket: [true],
      zoneIdsByTypes: { zoneIds: [zoneId] },
    };
    const url = `${RECHERCHE}?filters=${encodeURIComponent(JSON.stringify(filtres))}`;
    const res = await json(url);
    if (total === null && Number.isFinite(res.total)) total = res.total;
    const lot = res.realEstateAds ?? [];
    if (!lot.length) break;

    vues += lot.length;
    // Une annonce publiée pendant la collecte décale la pagination : sans
    // déduplication, elle apparaîtrait deux fois et en masquerait une autre.
    for (const a of lot) {
      const fiche = normaliserAnnonce(a);
      if (!parId.has(fiche.id)) parId.set(fiche.id, fiche);
    }
    const cible = total === null ? max : Math.min(total, max);
    log.info(`  page ${page} : ${lot.length} annonces (${parId.size}/${cible})`);

    if (total !== null && vues >= total) break;
    if (lot.length < PAR_PAGE) break; // dernière page
    page++;
    await sleep(delaiMs);
  }

  return [...parId.values()].slice(0, max);
}
