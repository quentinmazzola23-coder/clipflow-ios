import fs from 'node:fs';
import { chromium } from 'playwright';
import { log } from './log.js';

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

/**
 * Ouvre un contexte Chromium *persistant* : les cookies leboncoin (jeton
 * DataDome) et la session lacquereur.fr survivent d'une exécution à l'autre.
 * C'est ce qui permet de ne se connecter qu'une seule fois, à la main.
 */
export async function openBrowser(cfg, { headless = cfg.headless } = {}) {
  fs.mkdirSync(cfg.paths.profile, { recursive: true });

  const launch = {
    headless,
    viewport: { width: 1440, height: 940 },
    locale: 'fr-FR',
    timezoneId: 'Europe/Paris',
    userAgent: UA,
    args: [
      '--disable-blink-features=AutomationControlled',
      '--disable-features=IsolateOrigins,site-per-process',
    ],
    ignoreDefaultArgs: ['--enable-automation'],
  };
  if (process.env.HTTPS_PROXY) launch.proxy = { server: process.env.HTTPS_PROXY };

  let ctx;
  try {
    ctx = await chromium.launchPersistentContext(cfg.paths.profile, {
      ...launch,
      channel: cfg.browserChannel || undefined,
    });
  } catch (err) {
    if (cfg.browserChannel) {
      log.warn(
        `Chrome (channel "${cfg.browserChannel}") indisponible, bascule sur le Chromium de Playwright.`
      );
      ctx = await chromium.launchPersistentContext(cfg.paths.profile, launch);
    } else {
      throw err;
    }
  }

  // Gomme les marqueurs d'automatisation les plus grossiers.
  await ctx.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    Object.defineProperty(navigator, 'languages', { get: () => ['fr-FR', 'fr'] });
    if (!window.chrome) window.chrome = { runtime: {} };
  });

  ctx.setDefaultTimeout(45000);
  ctx.setDefaultNavigationTimeout(75000);
  return ctx;
}

/** Vrai si la page affichée est un mur anti-bot DataDome. */
export function looksBlocked(html) {
  return /captcha-delivery\.com|geo\.captcha|DataDome|Please enable JS and disable any ad blocker/i.test(
    html
  );
}

/**
 * Accepte la bannière cookies si elle est présente. Sans ça, certaines pages
 * restent figées derrière l'overlay et le contenu n'est jamais rendu.
 */
export async function dismissCookieBanner(page) {
  const selectors = [
    '#didomi-notice-agree-button',
    'button#didomi-notice-agree-button',
    'button:has-text("Accepter")',
    'button:has-text("Tout accepter")',
    'button:has-text("J\'accepte")',
  ];
  for (const sel of selectors) {
    try {
      const el = page.locator(sel).first();
      if (await el.isVisible({ timeout: 1500 })) {
        await el.click({ timeout: 3000 });
        await page.waitForTimeout(600);
        return true;
      }
    } catch {
      /* bannière absente : cas nominal une fois le profil chaud */
    }
  }
  return false;
}
