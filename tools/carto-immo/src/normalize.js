/**
 * Aplatit la réponse de lacquereur.fr (très imbriquée) en une fiche à plat,
 * directement utilisable en colonne de tableur et en popup de carte.
 */

const round = (v, d = 0) =>
  v == null || !Number.isFinite(Number(v))
    ? null
    : Number(Number(v).toFixed(d));

function daysBetween(a, b) {
  if (!a) return null;
  const d = (new Date(b).getTime() - new Date(a).getTime()) / 86400000;
  return Number.isFinite(d) ? Math.round(d) : null;
}

const TYPE_FR = {
  house: 'Maison',
  apartment: 'Appartement',
  land: 'Terrain',
  building: 'Immeuble',
  parking: 'Parking',
  other: 'Autre',
};

export function normalize(ad, analysis, { collectedAt = new Date().toISOString() } = {}) {
  const l = analysis?.listing ?? {};
  const addr = analysis?.default_address ?? {};
  const provider = l.provider_location ?? {};
  const dpe = l.dpe_info ?? {};
  const dvf = analysis?.default_price_analysis?.dvf ?? {};
  const band = dvf.price_band ?? {};
  const stats = dvf.price_statistics ?? {};
  const dev = dvf.price_deviation ?? {};
  const duration = analysis?.default_price_analysis?.commune_listing_duration ?? {};
  const parcelHistory = analysis?.default_price_analysis?.parcel_sales_history ?? {};

  const prix = l.price ?? ad.prix ?? null;
  const surface = l.surface ?? ad.surface ?? null;
  const prixM2 = prix && surface ? round(prix / surface) : null;

  const history = Array.isArray(l.price_history) ? l.price_history : [];
  const prixInitial = history.length ? history[0].price : null;
  const baisseEuros = prixInitial && prix ? prixInitial - prix : null;
  const baissePct =
    prixInitial && prix ? round(((prixInitial - prix) / prixInitial) * 100, 1) : null;

  const lat = addr.latitude ?? provider.latitude ?? ad.lbcLat ?? null;
  const lon = addr.longitude ?? provider.longitude ?? ad.lbcLon ?? null;
  const localisationPrecise = addr.latitude != null;

  // Positionnement du prix affiché face à la fourchette de marché DVF.
  let positionMarche = null;
  if (prix && band.high_total && band.low_total) {
    if (prix > band.high_total) positionMarche = 'Au-dessus du marché';
    else if (prix < band.low_total) positionMarche = 'Sous le marché';
    else positionMarche = 'Dans le marché';
  }

  return {
    // ── Identité ────────────────────────────────────────────────────────
    id: ad.id,
    collecteLe: collectedAt,
    titre: ad.titre ?? null,
    typeBien: TYPE_FR[l.property_type] ?? ad.typeBien ?? l.property_type ?? null,

    // ── Prix et surfaces ────────────────────────────────────────────────
    prix,
    prixM2,
    prixFraisInclus: l.price_including_fees ?? null,
    surface,
    terrain: l.land_surface ?? ad.terrain ?? null,
    pieces: l.rooms ?? ad.pieces ?? null,
    chambres: l.bedrooms ?? null,
    anneeConstruction: l.year_built ?? null,

    // ── Localisation ────────────────────────────────────────────────────
    ville: provider.city ?? ad.ville ?? null,
    codePostal: addr.postcode ?? provider.zip_code ?? ad.codePostal ?? null,
    adresseEstimee: addr.label ?? null,
    latitude: lat,
    longitude: lon,
    localisationPrecise,
    confianceAdresse: addr.confidence ?? null,
    sourceAdresse: addr.source ?? null,
    parcelle: addr.parcelle_id ?? null,
    banId: addr.ban_id ?? null,
    codeInsee: addr.commune_insee_code ?? provider.insee_code_hint ?? null,

    // ── Énergie ─────────────────────────────────────────────────────────
    dpe: dpe.dpe_rating ?? ad.dpeAnnonce ?? null,
    ges: dpe.climate_rating ?? ad.gesAnnonce ?? null,
    consoEnergie: dpe.primary_energy_kwh_m2_year ?? null,
    emissionsGes: dpe.ghg_emissions_kgco2_m2_year ?? null,
    dateDpe: dpe.dpe_date ?? null,

    // ── Historique de l'annonce ─────────────────────────────────────────
    publieeLe: l.publication_date ?? ad.publiee ?? null,
    joursEnLigne: l.days_since_publication ?? daysBetween(ad.publiee, collectedAt),
    nbBaisses: l.price_decreases_count ?? null,
    prixInitial,
    baisseEuros,
    baissePct,
    mandatExclusif: l.exclusive_mandate ?? null,
    nbAgences: l.dealer_count ?? null,

    // ── Marché (DVF) ────────────────────────────────────────────────────
    ecartMarchePct: dev.deviation_from_median_ht_pct ?? null,
    medianeSecteurM2: stats.median_per_m2 ?? band.pivot_per_m2 ?? null,
    fourchetteBasse: band.low_total ?? null,
    fourchetteHaute: band.high_total ?? null,
    positionMarche,
    nbVentesComparables: band.sample_size ?? stats.sample_size ?? null,
    delaiVenteCommuneJours: duration.median_days ?? null,
    ventesParcelle: parcelHistory.sale_count ?? null,
    derniereVenteParcelle: parcelHistory.sales?.[0]?.date_mutation ?? null,
    prixDerniereVenteParcelle: parcelHistory.sales?.[0]?.valeur_fonciere ?? null,

    // ── Confort ─────────────────────────────────────────────────────────
    jardin: l.has_garden ?? null,
    terrasse: l.has_terrace ?? null,
    piscine: l.has_pool ?? null,
    parking: l.has_parking ?? null,

    // Caractéristiques telles qu'annoncées sur leboncoin, conservées à part.
    // Le rapprochement d'une future annonce se fait contre celles-ci, et non
    // contre les valeurs réécrites par lacquereur : on compare ce qui est
    // comparable, deux descriptions issues du même site.
    lbc: {
      titre: ad.titre ?? null,
      prix: ad.prix ?? null,
      ville: ad.ville ?? null,
      codePostal: ad.codePostal ?? null,
      surface: ad.surface ?? null,
      terrain: ad.terrain ?? null,
      pieces: ad.pieces ?? null,
      typeBien: ad.typeBien ?? null,
      vendeur: ad.vendeur ?? null,
      lat: ad.lbcLat ?? null,
      lon: ad.lbcLon ?? null,
    },

    // ── Liens et médias ─────────────────────────────────────────────────
    urlAnnonce: ad.url,
    urlAnalyse: `https://lacquereur.fr/listing-analysis/${encodeURIComponent(ad.url)}`,
    urlMaps: lat && lon ? `https://www.google.com/maps/search/?api=1&query=${lat},${lon}` : null,
    urlCadastre:
      addr.parcelle_id && lat && lon
        ? `https://www.geoportail.gouv.fr/carte?c=${lon},${lat}&z=18&l0=CADASTRALPARCELS.PARCELLAIRE_EXPRESS::GEOPORTAIL:OGC:WMTS(1)`
        : null,
    autresAnnonces: Array.isArray(l.provider_listing_urls) ? l.provider_listing_urls : [],
    photo: l.image_urls?.[0] ?? ad.photo ?? null,
    photos: Array.isArray(l.image_urls) ? l.image_urls.slice(0, 8) : [],
    description: l.description ?? null,
    vendeur: ad.vendeur ?? null,
  };
}

/**
 * Fiche construite à partir d'une annonce et de sa localisation par le DPE.
 *
 * Même forme que `normalize`, qui part de l'analyse lacquereur : le reste du
 * pipeline — base, tableur, carte — ne connaît qu'une seule structure.
 */
export function normaliserAnnonce(annonce, localisation, marche = {}, { collectedAt = new Date().toISOString() } = {}) {
  const loc = localisation ?? {};
  const prix = annonce.prix ?? null;
  const surface = annonce.surface ?? null;

  return {
    id: annonce.id,
    source: annonce.source ?? null,
    collecteLe: collectedAt,
    titre: annonce.titre ?? null,
    typeBien: annonce.typeBien ?? null,

    prix,
    prixM2: prix && surface ? round(prix / surface) : null,
    surface,
    terrain: annonce.terrain ?? null,
    pieces: annonce.pieces ?? null,
    chambres: annonce.chambres ?? null,
    anneeConstruction: loc.anneeConstruction ?? annonce.anneeConstruction ?? null,

    // La commune du DPE fait foi : les annonces sont classées sous la ville de
    // diffusion, qui n'est pas toujours celle du bien.
    ville: loc.commune ?? annonce.ville ?? null,
    codePostal: loc.codePostal ?? annonce.codePostal ?? null,
    adresseEstimee: loc.adresse ?? null,
    latitude: loc.latitude ?? annonce.flouLat ?? null,
    longitude: loc.longitude ?? annonce.flouLon ?? null,
    localisationPrecise: !!loc.adresse,
    confianceAdresse: loc.note ?? null,
    niveauConfiance: loc.confiance ?? null,
    sourceAdresse: loc.adresse ? 'dpe' : annonce.flouLat ? 'approchée' : null,
    motifsLocalisation: loc.motifs ?? [],
    distanceFlouM: loc.distanceFlouM ?? null,
    banId: loc.banId ?? null,
    codeInsee: loc.codeInsee ?? null,
    numeroDpe: loc.numeroDpe ?? null,

    dpe: loc.dpe ?? annonce.dpeAnnonce ?? null,
    ges: loc.ges ?? annonce.gesAnnonce ?? null,
    consoEnergie: loc.consoEnergie ?? annonce.consoAnnonce ?? null,
    emissionsGes: loc.emissionsGes ?? annonce.emissionsAnnonce ?? null,
    dateDpe: annonce.dateDpe ?? null,

    publieeLe: annonce.publiee ? String(annonce.publiee).slice(0, 10) : null,
    // À défaut de date de publication, la dernière modification donne un
    // minorant : le bien est en ligne depuis au moins cette date.
    joursEnLigne: daysBetween(annonce.publiee ?? annonce.modifiee, collectedAt),
    ancienneteMinorant: !annonce.publiee && !!annonce.modifiee,
    nbBaisses: annonce.prixBaisse ? 1 : 0,

    ...marche,

    jardin: annonce.jardin ?? null,
    terrasse: annonce.terrasse ?? null,
    piscine: annonce.piscine ?? null,
    parking: annonce.parking ?? null,

    urlAnnonce: annonce.url,
    urlAnalyse: `https://lacquereur.fr/listing-analysis/${encodeURIComponent(annonce.url)}`,
    urlMaps: loc.latitude
      ? `https://www.google.com/maps/search/?api=1&query=${loc.latitude},${loc.longitude}`
      : null,
    photo: annonce.photo ?? null,
    photos: annonce.photos ?? [],
    description: annonce.description ?? null,
    vendeur: annonce.vendeur ?? null,
  };
}
