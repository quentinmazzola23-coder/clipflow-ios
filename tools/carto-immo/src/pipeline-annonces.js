import { trouverZone, collecterZone } from './bienici.js';
import { localiserToutes } from './geoloc.js';
import { reperes, situer } from './marche.js';
import { normaliserAnnonce } from './normalize.js';
import { enrichirParcelles } from './cadastre.js';
import { log } from './log.js';

/**
 * Chaîne complète pour une source d'annonces sans adresse publiée :
 *
 *   relever les annonces → retrouver leur diagnostic dans le registre ADEME,
 *   donc leur adresse exacte → situer le prix face aux ventes du secteur →
 *   tracer la parcelle cadastrale.
 *
 * Chaque fiche garde le lien vers l'annonce : c'est bien la géolocalisation
 * d'une annonce, pas d'une statistique.
 */
export async function collecterEtLocaliser(zones, cfg) {
  const {
    types = ['house'], max = 200, cacheDir, cadastre = true, rayonContexteM = 300, filtres = null,
  } = cfg;

  // ── Relevé ──────────────────────────────────────────────────────────────
  const annonces = [];
  const zonesVues = [];
  for (const z of zones) {
    const zone = await trouverZone(z);
    zonesVues.push(zone);
    log.step(`${zone.nom} (${zone.type})`);
    // Le plafond vaut pour la collecte entière, pas par zone.
    const reste = max - annonces.length;
    if (reste <= 0) break;
    annonces.push(...(await collecterZone(zone.id, { types, max: reste })));
  }

  // Une même offre peut être diffusée sur plusieurs zones qui se recouvrent.
  let uniques = [...new Map(annonces.map((a) => [a.id, a])).values()];
  log.ok(`${uniques.length} annonces relevées`);

  if (filtres) {
    const avant = uniques.length;
    const { minPrice, maxPrice, minSurface, propertyTypes } = filtres;
    uniques = uniques.filter((a) =>
      (!minPrice || a.prix == null || a.prix >= minPrice) &&
      (!maxPrice || a.prix == null || a.prix <= maxPrice) &&
      (!minSurface || a.surface == null || a.surface >= minSurface) &&
      (!propertyTypes?.length || !a.typeBien || propertyTypes.includes(a.typeBien)));
    if (uniques.length !== avant) log.info(`${avant - uniques.length} écartées par les filtres`);
  }

  // ── Localisation ────────────────────────────────────────────────────────
  log.step('Localisation par le registre des DPE');
  const localisees = await localiserToutes(uniques);

  // ── Marché et mise en forme ─────────────────────────────────────────────
  log.step('Repères de marché');
  const fiches = [];
  for (const { annonce, localisation } of localisees) {
    const insee = localisation?.codeInsee ?? null;
    const rep = insee ? await reperes(insee, annonce.typeBien, cacheDir) : null;
    const marche = situer(annonce.prix, annonce.surface, rep);
    fiches.push(normaliserAnnonce(annonce, localisation, marche));
  }

  // ── Parcelle cadastrale ─────────────────────────────────────────────────
  let contexte = { parcelles: [], batiments: [] };
  if (cadastre) {
    log.step('Parcelles cadastrales');
    const r = await enrichirParcelles(fiches, cacheDir, { rayon: rayonContexteM });
    contexte = r.contexte;
    log.ok(`${r.trouvees} parcelles tracées`);
  }

  const localisation = fiches.filter((f) => f.localisationPrecise).length;
  log.ok(`${localisation}/${fiches.length} annonces à l'adresse exacte`);

  return { fiches, contexte, zones: zonesVues, total: uniques.length, localisees: localisation };
}
