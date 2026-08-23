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
  const villes = (Array.isArray(res) ? res : []).filter((z) => z.zoneIds?.length);
  const exact = villes.find(
    (z) => z.insee_code === recherche || z.insee_codes?.includes(recherche)
  );
  const choisie = exact ?? villes[0];
  if (!choisie) throw new Error(`zone introuvable pour « ${recherche} »`);
  return {
    id: choisie.zoneIds[0],
    nom: choisie.name,
    insee: choisie.insee_code ?? choisie.insee_codes?.[0] ?? null,
    type: choisie.type,
  };
}

const PAR_PAGE = 50;

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
    publiee: a.publicationDate ?? null,
    modifiee: a.modificationDate ?? null,
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
  const annonces = [];
  let page = 1;
  let total = null;

  while (annonces.length < max) {
    const filtres = {
      size: PAR_PAGE,
      from: annonces.length,
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
    total ??= res.total ?? 0;
    const lot = res.realEstateAds ?? [];
    if (!lot.length) break;
    annonces.push(...lot.map(normaliserAnnonce));
    log.info(`  page ${page} : ${lot.length} annonces (${annonces.length}/${Math.min(total, max)})`);
    if (annonces.length >= total) break;
    page++;
    await sleep(delaiMs);
  }

  return annonces.slice(0, max);
}
