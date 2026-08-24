import { decodeFlight, findObjectWithKeys } from './flight.js';
import { dismissCookieBanner } from './browser.js';
import { log, sleep } from './log.js';

const BASE = 'https://lacquereur.fr';

export function analysisUrl(listingUrl) {
  return `${BASE}/listing-analysis/${encodeURIComponent(listingUrl)}`;
}

/** Trouve l'objet racine { listingUrl, analysis, analysisError } dans le flux. */
function extractAnalysis(flight) {
  if (!flight) return null;
  return (
    findObjectWithKeys(flight, ['default_address', 'listing', 'listing_id']) ||
    findObjectWithKeys(flight, ['analysis', 'listingUrl'])
  );
}

/**
 * Vrai si la page nous a renvoyés vers l'écran de connexion. Le nom du
 * composant n'apparaît qu'une fois le flux RSC décodé, jamais dans le HTML brut.
 */
function isLoginWall(page, flight) {
  if (/\/login|\/register/.test(page.url())) return true;
  return flight.includes('"LoginForm"') && !flight.includes('default_address');
}

/**
 * Certaines fiches masquent la localisation derrière un bouton. Les
 * coordonnées sont normalement déjà dans le payload serveur ; ce clic n'est
 * qu'un filet de sécurité quand elles manquent.
 */
async function revealAddress(page) {
  const labels = [
    'button:has-text("Révéler")',
    'button:has-text("Voir l\'adresse")',
    'button:has-text("Afficher l\'adresse")',
    'button:has-text("Localiser")',
    '[data-testid="reveal-address"]',
  ];
  for (const sel of labels) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 1200 })) {
        await el.click({ timeout: 4000 });
        await page.waitForTimeout(2500);
        return true;
      }
    } catch {
      /* bouton absent : la fiche est déjà complète */
    }
  }
  return false;
}

/**
 * Analyse une annonce et renvoie l'objet brut de lacquereur.fr.
 *
 * @returns {Promise<{ok: boolean, analysis?: object, error?: string}>}
 */
export async function analyseListing(ctx, listingUrl, { timeoutMs = 120000 } = {}) {
  const page = await ctx.newPage();

  // Filet secondaire : on capte aussi les réponses réseau qui portent la donnée,
  // au cas où la page passerait un jour en rendu purement client.
  let sniffed = null;
  page.on('response', async (res) => {
    if (sniffed) return;
    const ct = res.headers()['content-type'] || '';
    if (!ct.includes('json')) return;
    try {
      const body = await res.text();
      if (body.includes('"default_address"')) {
        sniffed = findObjectWithKeys(body, ['default_address', 'listing']);
      }
    } catch {
      /* corps illisible (stream, redirection) */
    }
  });

  try {
    await page.goto(analysisUrl(listingUrl), { waitUntil: 'domcontentloaded' });
    await dismissCookieBanner(page);

    const deadline = Date.now() + timeoutMs;
    let revealTried = false;
    // Nombre de tours où l'analyse est là mais la localisation absente : au-delà,
    // c'est que lacquereur.fr n'a pas su rapprocher l'annonce d'une adresse.
    let toursSansAdresse = 0;
    const TOURS_MAX_SANS_ADRESSE = 4;

    while (Date.now() < deadline) {
      const flight = decodeFlight(await page.content());

      if (isLoginWall(page, flight)) {
        return {
          ok: false,
          error:
            'session lacquereur.fr expirée — relance `npm run login` pour te reconnecter',
          fatal: true,
        };
      }

      const root = extractAnalysis(flight);
      const analysis = root?.analysis ?? root;

      if (root?.analysisError) {
        return { ok: false, error: String(root.analysisError) };
      }

      const addr = analysis?.default_address;
      if (addr?.latitude != null && addr?.longitude != null) {
        return { ok: true, analysis };
      }

      if (analysis?.listing) {
        // Localisation éventuellement masquée derrière un bouton : un seul essai.
        if (!revealTried) {
          revealTried = true;
          if (await revealAddress(page)) continue;
        }
        if (++toursSansAdresse >= TOURS_MAX_SANS_ADRESSE) {
          return { ok: true, analysis, warning: 'localisation non déterminée' };
        }
      }

      if (sniffed) return { ok: true, analysis: sniffed };

      await page.waitForTimeout(2500);
    }

    return { ok: false, error: 'délai dépassé pendant l’analyse' };
  } catch (err) {
    return { ok: false, error: err.message.split('\n')[0] };
  } finally {
    await page.close().catch(() => {});
  }
}

/** Analyse une liste d'annonces en série, en respectant les temporisations. */
export async function analyseAll(ctx, listings, cfg, onRecord) {
  const results = { ok: 0, failed: 0, errors: [] };

  for (const [i, ad] of listings.entries()) {
    log.step(`(${i + 1}/${listings.length}) analyse ${ad.url}`);
    const res = await analyseListing(ctx, ad.url);

    if (res.ok) {
      results.ok++;
      if (res.warning) log.warn(`  ${res.warning}`);
      else log.ok('  localisation récupérée');
      await onRecord(ad, res.analysis);
    } else {
      results.failed++;
      results.errors.push({ url: ad.url, error: res.error });
      log.warn(`  échec : ${res.error}`);
      if (res.fatal) break;
    }

    if (i < listings.length - 1) await sleep(cfg.delayMs.lacquereur);
  }

  return results;
}
