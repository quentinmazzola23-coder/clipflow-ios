import { decodeFlight, decodeNextData, collectObjectsWithKeys } from './flight.js';
import { looksBlocked, dismissCookieBanner } from './browser.js';
import { log, sleep } from './log.js';

const AD_URL_RE = /^https?:\/\/(?:www\.)?leboncoin\.fr\/(?:ad|offre)\/[a-z_]+\/(\d+)/i;

/** Ajoute/remplace le paramètre de pagination d'une URL de recherche. */
export function pageUrl(searchUrl, page) {
  const u = new URL(searchUrl);
  if (page <= 1) {
    u.searchParams.delete('page');
    return u.toString();
  }
  u.searchParams.set('page', String(page));
  return u.toString();
}

function attr(ad, key) {
  const a = (ad.attributes || []).find((x) => x.key === key);
  return a ? (a.value_label ?? a.value) : null;
}

function num(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(String(v).replace(/[^\d.,-]/g, '').replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/** Normalise un objet annonce brut de leboncoin en fiche stable. */
function normalizeAd(ad) {
  const id = String(ad.list_id ?? ad.id ?? '');
  if (!id) return null;
  const url =
    ad.url && /^https?:/.test(ad.url)
      ? ad.url
      : `https://www.leboncoin.fr/ad/ventes_immobilieres/${id}`;
  const loc = ad.location || {};
  const price = Array.isArray(ad.price) ? ad.price[0] : ad.price ?? null;

  return {
    id,
    url,
    titre: ad.subject ?? null,
    prix: num(price),
    ville: loc.city_label || loc.city || null,
    codePostal: loc.zipcode || null,
    departement: loc.department_name || null,
    lbcLat: num(loc.lat),
    lbcLon: num(loc.lng),
    surface: num(attr(ad, 'square')),
    terrain: num(attr(ad, 'land_plot_surface')),
    pieces: num(attr(ad, 'rooms')),
    typeBien: attr(ad, 'real_estate_type'),
    dpeAnnonce: attr(ad, 'energy_rate'),
    gesAnnonce: attr(ad, 'ges'),
    publiee: ad.first_publication_date ?? null,
    vendeur: ad.owner?.name ?? null,
    vendeurType: ad.owner?.type ?? null,
    photo: ad.images?.thumb_url || ad.images?.urls_thumb?.[0] || null,
    nbPhotos: ad.images?.nb_images ?? null,
  };
}

/**
 * Extrait les annonces d'une page de résultats.
 *
 * Trois stratégies, de la plus riche à la plus tolérante : le flux RSC de
 * Next.js, le `__NEXT_DATA__` historique, puis un simple ratissage des liens
 * du DOM. La dernière ne rend que l'URL, ce qui suffit à alimenter lacquereur.
 */
export function extractAdsFromHtml(html) {
  // 1. Flux RSC (App Router) — contient les objets annonce complets.
  const flight = decodeFlight(html);
  if (flight.length > 0) {
    const raw = collectObjectsWithKeys(flight, ['list_id', 'subject']);
    const ads = raw.map(normalizeAd).filter(Boolean);
    if (ads.length) return { ads, strategy: 'rsc' };
  }

  // 2. __NEXT_DATA__ (Pages Router).
  const nd = decodeNextData(html);
  const fromNextData =
    nd?.props?.pageProps?.searchData?.ads ??
    nd?.props?.pageProps?.initialProps?.searchData?.ads ??
    null;
  if (Array.isArray(fromNextData) && fromNextData.length) {
    const ads = fromNextData.map(normalizeAd).filter(Boolean);
    if (ads.length) return { ads, strategy: 'next-data' };
  }

  // 3. Repli : les liens d'annonces présents dans le HTML.
  const urls = new Set();
  const re = /href="(\/(?:ad|offre)\/[a-z_]+\/\d+[^"]*)"/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    urls.add(new URL(m[1], 'https://www.leboncoin.fr').toString().split('?')[0]);
  }
  const ads = [...urls].map((url) => {
    const id = url.match(AD_URL_RE)?.[1];
    return id ? { id, url, titre: null, prix: null } : null;
  });
  return { ads: ads.filter(Boolean), strategy: 'dom' };
}

/** Parcourt les recherches configurées et renvoie les annonces dédupliquées. */
export async function collectListings(ctx, cfg) {
  const page = await ctx.newPage();
  const byId = new Map();

  try {
    for (const search of cfg.searches) {
      for (let p = 1; p <= cfg.pagesPerSearch; p++) {
        const url = pageUrl(search, p);
        log.step(`leboncoin — page ${p} : ${url}`);

        let html;
        try {
          await page.goto(url, { waitUntil: 'domcontentloaded' });
          await dismissCookieBanner(page);
          // Le rendu des résultats est différé : on laisse le temps au client.
          await page
            .waitForSelector('a[href*="/ad/"], a[href*="/offre/"]', { timeout: 20000 })
            .catch(() => {});
          html = await page.content();
        } catch (err) {
          log.warn(`  page inaccessible (${err.message.split('\n')[0]})`);
          continue;
        }

        if (looksBlocked(html)) {
          throw new Error(
            'leboncoin affiche une vérification anti-bot. Lance `npm run login` ' +
              'pour la résoudre à la main une fois, puis relance.'
          );
        }

        const { ads, strategy } = extractAdsFromHtml(html);
        let added = 0;
        for (const ad of ads) {
          if (!byId.has(ad.id)) {
            byId.set(ad.id, ad);
            added++;
          }
        }
        log.info(`  ${ads.length} annonces lues (${strategy}), ${added} nouvelles`);

        if (ads.length === 0) break; // fin de pagination
        if (p < cfg.pagesPerSearch) await sleep(cfg.delayMs.leboncoin);
      }
      await sleep(cfg.delayMs.leboncoin);
    }
  } finally {
    await page.close().catch(() => {});
  }

  return [...byId.values()];
}

/** Applique les filtres de config pour éviter des analyses inutiles. */
export function applyFilters(ads, filters) {
  const { minPrice, maxPrice, minSurface, propertyTypes } = filters;
  return ads.filter((a) => {
    if (minPrice && a.prix != null && a.prix < minPrice) return false;
    if (maxPrice && a.prix != null && a.prix > maxPrice) return false;
    if (minSurface && a.surface != null && a.surface < minSurface) return false;
    if (propertyTypes?.length && a.typeBien && !propertyTypes.includes(a.typeBien))
      return false;
    return true;
  });
}
