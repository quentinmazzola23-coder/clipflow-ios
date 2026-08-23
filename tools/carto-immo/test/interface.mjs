/**
 * La carte telle qu'on s'en sert : dans un navigateur, à la souris.
 *
 * Les tests précédents lisent le HTML produit. Celui-ci l'exécute — c'est le
 * seul moyen de vérifier qu'un bouton fait ce qu'il annonce, que le prix
 * apparaît au bon zoom, et qu'un recalage fait à la main arrive bien en base.
 *
 *   node test/interface.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';

import { writeMap } from '../src/map.js';
import { demarrerServeur } from '../src/serveur.js';
import { loadStore, saveStore, enregistrerAnalyse, tousLesBiens } from '../src/store.js';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'carto-immo-ui-'));
let passed = 0;
const check = async (nom, fn) => { await fn(); passed++; console.log(`  ✓ ${nom}`); };

console.log('\ncarto-immo — la carte dans un navigateur\n');

// ── Décor ─────────────────────────────────────────────────────────────────

const carre = (lon, lat, d) => [[[[lon - d, lat - d], [lon + d, lat - d], [lon + d, lat + d], [lon - d, lat + d], [lon - d, lat - d]]]];

const BIENS = [
  {
    id: 'a1', titre: 'Maison de village', typeBien: 'Maison', prix: 299000, prixM2: 1661,
    surface: 180, terrain: 4760, pieces: 9, ville: 'Beaumarchés', codePostal: '32160',
    adresseEstimee: '33 Quartier Lasserre 32160 Beaumarchés', niveauConfiance: 'bonne',
    localisationPrecise: true, parcelle: '320360000B1223', parcelleConfiance: 'bonne',
    parcelleSource: 'dpe', parcelleMotif: 'parcelle du bâtiment',
    parcelleGeom: carre(0.1567, 43.5231, 4e-4), batimentGeom: carre(0.1567, 43.5231, 1e-4),
    contenance: 4067, latitude: 43.5231, longitude: 0.1567, codeInsee: '32036',
    dpe: 'C', ges: 'A', joursEnLigne: 56, ancienneteMinorant: true,
    numeroDpe: '2332E0123456X', confianceAdresse: 118, ecartSecond: 23,
    qualiteGeocodage: 'numero', distanceFlouM: 412,
    motifsLocalisation: ['date du diagnostic', 'étiquette énergie', 'surface'],
    dpeAlternatives: [{
      numeroDpe: '2332E0999999Y', adresse: '4 Route de Plaisance 32160 Beaumarchés',
      latitude: 43.524, longitude: 0.158, note: 95, confiance: 'bonne', surfaceDpe: 176, distanceFlouM: 610,
    }],
    photo: 'https://v.seloger.com/s/crop/590x330/visuels/a.jpg',
    photos: ['https://v.seloger.com/s/crop/590x330/visuels/a.jpg',
             'https://v.seloger.com/s/crop/590x330/visuels/b.jpg'],
    urlAnnonce: 'https://www.bienici.com/annonce/a1', statut: 'nouveau',
  },
  {
    id: 'a2', titre: 'Corps de ferme', typeBien: 'Maison', prix: 189000, surface: 160,
    ville: 'Marciac', codePostal: '32230', adresseEstimee: '2 Rue du Chevalier 32230 Marciac',
    niveauConfiance: 'élevée', localisationPrecise: true, latitude: 43.5241, longitude: 0.1582,
    codeInsee: '32235', joursEnLigne: 190, dpe: 'E', parcelle: '322350000AB0002',
    urlAnnonce: 'https://www.bienici.com/annonce/a2',
    recalage: { latitude: 43.5241, longitude: 0.1582, parcelle: '322350000AB0002', source: 'parcelle' },
    auto: {
      latitude: 43.524, longitude: 0.158, parcelle: '322350000AB0001',
      adresse: '2 Rue du Chevalier 32230 Marciac', niveauConfiance: 'bonne',
    },
  },
];

const VOISINAGE = [
  { i: '320360000B1223', g: carre(0.1567, 43.5231, 4e-4), c: [0.1567, 43.5231], s: 4067 },
  { i: '320360000B1224', g: carre(0.1577, 43.5231, 4e-4), c: [0.1577, 43.5231], s: 2100 },
  { i: '322350000AB0002', g: carre(0.1582, 43.5241, 3e-4), c: [0.1582, 43.5241], s: 900 },
];
const COMMUNES = [{
  n: 'Marciac', c: '32235',
  g: [[[0.14, 43.51], [0.18, 43.51], [0.18, 43.54], [0.14, 43.54], [0.14, 43.51]]],
}];
const BILAN = {
  relevees: 62, tentees: 58, localisees: 34,
  motifs: { 'aucun diagnostic compatible': 14, 'concordance trop faible': 7, 'deux logements également plausibles': 3 },
  diffusion: {
    Marciac: { vues: 47, tentees: 44, localisees: 28, certaines: 9, le: '2026-08-23T07:00:00.000Z' },
    Beaumarchés: { vues: 15, tentees: 14, localisees: 6, certaines: 2, le: '2026-08-23T07:00:00.000Z' },
  },
  zones: [{ nom: 'Marciac', relevees: 62, tentees: 58, localisees: 34, le: '2026-08-23T07:00:00.000Z' }],
  le: '2026-08-23T07:00:00.000Z',
};

const fichier = path.join(tmp, 'carte.html');
writeMap(BIENS, fichier, { title: 'Essai', voisinage: VOISINAGE, communes: COMMUNES, bilan: BILAN, filtres: true });

// Aucun accès réseau dans un test : on répond une image vide aux tuiles.
const PIXEL = Buffer.from('R0lGODlhAQABAIAAAMzMzAAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw==', 'base64');
const navigateur = await chromium
  .launch({ executablePath: '/opt/pw-browsers/chromium' })
  .catch(() => chromium.launch());

async function ouvrir(url, { local = null } = {}) {
  const ctx = await navigateur.newContext({ viewport: { width: 1280, height: 860 } });
  await ctx.route('**/*', (route) => {
    const u = route.request().url();
    if (u.startsWith('file://') || (local && u.startsWith(local))) return route.continue();
    return route.fulfill({ status: 200, contentType: 'image/gif', body: PIXEL });
  });
  const page = await ctx.newPage();
  const erreurs = [];
  page.on('pageerror', (e) => erreurs.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') erreurs.push('console: ' + m.text()); });
  await page.goto(url);
  await page.waitForFunction(() => window.cartoImmo && document.querySelectorAll('.marker').length > 0);
  return { ctx, page, erreurs };
}

try {
  // ── Carte ouverte comme simple fichier ─────────────────────────────────
  const { ctx, page, erreurs } = await ouvrir('file://' + fichier);
  const zoom = async (z) => {
    await page.evaluate((zz) => window.cartoImmo.map.setZoom(zz, { animate: false }), z);
    await page.waitForTimeout(300);
  };
  const marqueurs = () => page.evaluate(() => ({
    pins: document.querySelectorAll('.marker .pin').length,
    pills: document.querySelectorAll('.marker .pill').length,
    hauts: document.querySelectorAll('.marker.haut').length,
  }));

  await check('la page s’ouvre sans erreur', () => assert.deepEqual(erreurs, []));

  await check('le bilan annonce ce qui a été tenté et ce qui a abouti', async () => {
    const resume = await page.textContent('#bilan summary');
    assert.match(resume, /34\/58/);
    assert.match(resume, /59 %/);
    await page.click('#bilan summary');
    const corps = await page.textContent('#bilan .corps');
    assert.match(corps, /62\s*annonces relevées/);
    assert.match(corps, /aucun diagnostic compatible/);
    assert.match(corps, /14/);
    assert.match(corps, /Marciac — 34\/58/);
  });

  await check('le bilan détaille chaque commune : vues, placés, certains', async () => {
    const t = await page.textContent('#bilan .parcommune');
    assert.match(t, /Marciac/);
    assert.match(t, /Beaumarchés/);
    const marciac = await page.evaluate(() => {
      const tr = [...document.querySelectorAll('#bilan .parcommune tbody tr')]
        .find((x) => x.textContent.startsWith('Marciac'));
      return [...tr.querySelectorAll('td')].map((td) => td.textContent);
    });
    // 47 annonces vues sous ce nom, 1 bien effectivement situé là, certain
    // parce que sa position a été confirmée à la main.
    assert.deepEqual(marciac, ['47', '1', '1']);
  });

  await check('un bilan d’exécution, sans détail par zone, reste lisible', async () => {
    // Le bilan d'une collecte ne connaît que des noms de zones ; celui tenu en
    // base porte le détail. La carte doit accepter les deux.
    const brut = path.join(tmp, 'brut.html');
    writeMap(BIENS, brut, { title: 'Brut', bilan: { ...BILAN, zones: ['Marciac'] } });
    const html = fs.readFileSync(brut, 'utf8');
    assert.ok(!html.includes('undefined/undefined'));
    assert.match(html, /"zones":\["Marciac"\]/);
  });

  await check('de loin : des points de couleur, aucun prix', async () => {
    await zoom(10);
    const m = await marqueurs();
    assert.ok(m.pins > 0);
    assert.equal(m.pills, 0);
  });

  await check('de près : le prix', async () => {
    await zoom(15);
    const m = await marqueurs();
    assert.ok(m.pills > 0);
    assert.equal(m.hauts, 0);
  });

  await check('au zoom parcelle : le prix se pose au-dessus du point', async () => {
    await zoom(19);
    const m = await marqueurs();
    assert.ok(m.hauts > 0 && m.pins > 0 && m.pills > 0);
  });

  await check('la règle ne dépend jamais du nombre de biens affichés', async () => {
    await zoom(10);
    await page.fill('#q', 'Beaumarchés');
    await page.waitForTimeout(250);
    assert.equal((await marqueurs()).pills, 0, 'toujours pas de prix de loin, même à un seul bien');
    await page.fill('#q', '');
    await page.waitForTimeout(250);
  });

  await check('la bulle montre les photos, allégées et feuilletables', async () => {
    await zoom(17);
    await page.click('.card[data-id="a1"]');
    await page.waitForSelector('.leaflet-popup .galerie img');
    const premiere = await page.getAttribute('.leaflet-popup .galerie img', 'src');
    assert.match(premiere, /295x165/, 'la miniature est demandée en demi-format');
    assert.equal(await page.textContent('.leaflet-popup .galerie .rang'), '1/2');
    await page.click('.leaflet-popup .galerie .suiv');
    await page.waitForTimeout(150);
    assert.notEqual(await page.getAttribute('.leaflet-popup .galerie img', 'src'), premiere);
    assert.equal(await page.textContent('.leaflet-popup .galerie .rang'), '2/2');
    assert.match(
      await page.getAttribute('.leaflet-popup .galerie .pleine', 'href'),
      /590x330\/visuels\/b\.jpg$/,
      'le lien mène à la photo en pleine définition'
    );
  });

  await check('cliquer un marqueur cadre le bien à l’échelle de sa parcelle', async () => {
    await zoom(13);
    // On vise le marqueur du bien à 299 000 €, pas « le premier venu ».
    await page.evaluate(() => {
      const cible = [...document.querySelectorAll('.leaflet-marker-icon')]
        .find((m) => m.textContent.includes('299k'));
      cible.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 1, clientY: 1 }));
    });
    await page.waitForTimeout(1500);
    const apres = await page.evaluate(() => {
      const d = window.cartoImmo.DATA.find((x) => x.id === 'a1');
      const e = window.cartoImmo.etat(d);
      const p = window.cartoImmo.map.latLngToContainerPoint([e.la, e.lo]);
      return {
        zoom: window.cartoImmo.map.getZoom(),
        dansLaVue: window.cartoImmo.map.getBounds().contains([e.la, e.lo]),
        y: p.y,
        hauteur: window.innerHeight,
      };
    });
    assert.ok(apres.zoom >= 16 && apres.zoom <= 20, `zoom ${apres.zoom}`);
    assert.equal(apres.dansLaVue, true, 'le bien cliqué doit rester dans la vue');
    // La bulle s'ouvre au-dessus du point : celui-ci doit se poser dans la
    // moitié basse, sinon la bulle sortirait de l'écran.
    assert.ok(apres.y > apres.hauteur * 0.45, `le bien se pose à ${Math.round(apres.y)} px`);
  });

  await check('la fiche se pose à côté du terrain, jamais dessus ni hors écran', async () => {
    await zoom(19);
    await page.evaluate(() => {
      const m = [...document.querySelectorAll('.leaflet-marker-icon')]
        .find((x) => x.textContent.includes('299k'));
      m.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 1, clientY: 1 }));
    });
    await page.waitForTimeout(1500);
    const g = await page.evaluate(() => {
      const bulle = document.querySelector('.leaflet-popup').getBoundingClientRect();
      const carte = document.getElementById('map').getBoundingClientRect();
      const p = document.querySelector('.leaflet-overlay-pane path').getBoundingClientRect();
      const chevauche = !(bulle.right < p.left || bulle.left > p.right
        || bulle.bottom < p.top || bulle.top > p.bottom);
      return {
        dansLEcran: bulle.top >= carte.top - 1 && bulle.bottom <= carte.bottom + 1
          && bulle.left >= carte.left - 1 && bulle.right <= carte.right + 1,
        chevauche, haut: Math.round(bulle.top),
      };
    });
    assert.equal(g.dansLEcran, true, `la fiche déborde de la carte (haut ${g.haut})`);
    assert.equal(g.chevauche, false, 'la fiche ne doit pas recouvrir le terrain');
  });

  await check('la photo de la fiche reste visible à l’écran', async () => {
    const v = await page.evaluate(() => {
      const img = document.querySelector('.leaflet-popup .galerie img').getBoundingClientRect();
      const carte = document.getElementById('map').getBoundingClientRect();
      return img.top >= carte.top - 1 && img.bottom <= carte.bottom + 1 && img.height > 20;
    });
    assert.equal(v, true, 'la photo doit être entièrement dans la fenêtre');
  });

  await check('une annonce du jour se dit au singulier', async () => {
    const t = await page.evaluate(() => {
      const d = window.cartoImmo.DATA[0];
      const avant = d.j;
      d.j = 1;
      window.cartoImmo.render();
      const html = document.querySelector('.card') ? document.body.innerHTML : '';
      d.j = avant;
      window.cartoImmo.render();
      return html;
    });
    assert.ok(!t.includes('>1 jours<'), 'pas de « 1 jours »');
  });

  await check('la bulle défile au lieu de déborder', async () => {
    const style = await page.evaluate(() => getComputedStyle(document.querySelector('.leaflet-popup-content')).overflowY);
    assert.equal(style, 'auto');
  });

  await check('la fiche donne de quoi contester le rapprochement', async () => {
    const t = await page.textContent('.leaflet-popup .verif');
    assert.match(t, /2332E0123456X/);
    assert.match(t, /note 118/);
    assert.match(t, /\+23 sur le suivant/);
  });

  await check('« Vérifier / recaler » ouvre le panneau', async () => {
    await page.click('.leaflet-popup .verif button[data-recaler]');
    await page.waitForSelector('#recal.on');
    const t = await page.textContent('#recal');
    assert.match(t, /320360000B1223/);
    assert.match(t, /Route de Plaisance/, 'le diagnostic écarté reste proposable');
  });

  await check('désigner une parcelle voisine déplace le bien', async () => {
    await page.click('#recal button[data-mode="parcelle"]');
    await page.waitForTimeout(300);
    const surlignees = await page.evaluate(() =>
      document.querySelectorAll('path[stroke="#a06a00"], path[stroke="#1e7a46"]').length);
    assert.ok(surlignees >= 2, `parcelles proposées : ${surlignees}`);
    await page.evaluate(() => {
      document.querySelector('path[stroke="#a06a00"]')
        .dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 1, clientY: 1 }));
    });
    await page.waitForTimeout(350);
    const apres = await page.evaluate(() => ({
      etat: window.cartoImmo.etat(window.cartoImmo.DATA.find((d) => d.id === 'a1')),
      garde: JSON.parse(localStorage.getItem('carto-immo:recalage') || '{}'),
    }));
    assert.notEqual(apres.etat.pcl, '320360000B1223');
    assert.equal(apres.etat.rec, true);
    assert.equal(apres.garde.a1.source, 'parcelle');
  });

  await check('le compteur de recalages apparaît', async () => {
    assert.match(await page.textContent('#corrections'), /1 recalage à exporter/);
  });

  await check('revenir à l’automatique rétablit la parcelle d’origine', async () => {
    await page.click('#recal .annuler');
    await page.waitForTimeout(300);
    const e = await page.evaluate(() =>
      window.cartoImmo.etat(window.cartoImmo.DATA.find((d) => d.id === 'a1')));
    assert.equal(e.pcl, '320360000B1223');
    assert.equal(e.rec, false);
  });

  await check('un bien recalé en base garde sa correction, et sa position d’avant', async () => {
    const e = await page.evaluate(() => {
      const d = window.cartoImmo.DATA.find((x) => x.id === 'a2');
      return { effectif: window.cartoImmo.etat(d), auto: d.au };
    });
    assert.equal(e.effectif.pcl, '322350000AB0002');
    assert.equal(e.effectif.rec, true);
    assert.equal(e.auto.pcl, '322350000AB0001');
  });

  await check('Échap referme le panneau', async () => {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);
    assert.equal(await page.isVisible('#recal'), false);
  });

  await check('cliquer un village annonce ce qu’on y a vu et ce qu’on y a placé', async () => {
    await page.evaluate(() => window.cartoImmo.map.fire('click', { latlng: { lat: 43.52, lng: 0.16 } }));
    await page.waitForSelector('.zonepop');
    const t = await page.textContent('.zonepop');
    assert.match(t, /Marciac/);
    assert.match(t, /47 annonces relevées sous ce nom/);
    assert.match(t, /28 identifiées/);
    assert.match(t, /9 avec certitude/);
    assert.match(t, /1 bien situé ici/);
    assert.match(t, /Dernier balayage le 23\/08\/2026/);
    // Sans agent, la carte ne promet rien qu'elle ne puisse tenir.
    assert.match(t, /annonces --zone "Marciac"/);
  });

  await check('aucune erreur au terme de la séance', () => assert.deepEqual(erreurs, []));
  await ctx.close();

  // ── Carte servie par l'agent local ─────────────────────────────────────
  const cfg = {
    paths: {
      store: path.join(tmp, 'base.json'), map: fichier,
      csv: path.join(tmp, 'a.csv'), spreadsheet: path.join(tmp, 'a.xlsx'), cache: path.join(tmp, 'c'),
    },
    cadastre: false, filtresCarte: true, bienici: { zones: ['Marciac'], types: ['house'], max: 3 },
  };
  const base = loadStore(cfg.paths.store);
  enregistrerAnalyse(base, { ...BIENS[0], collecteLe: '2026-08-23T07:00:00.000Z' },
    { id: 'a1', url: BIENS[0].urlAnnonce, titre: BIENS[0].titre, prix: BIENS[0].prix });
  saveStore(cfg.paths.store, base);

  const { serveur } = await demarrerServeur(cfg, { port: 0 });
  const racine = `http://127.0.0.1:${serveur.address().port}`;
  try {
    const agent = await ouvrir(racine + '/', { local: racine });
    await agent.page.waitForTimeout(400);

    await check('la carte servie reconnaît l’agent', async () => {
      const etat = await agent.page.evaluate(() => fetch('api/etat').then((r) => r.json()));
      assert.equal(etat.agent, 'carto-immo');
    });

    await check('un clic sur le village propose de lancer l’analyse', async () => {
      await agent.page.evaluate(() => window.cartoImmo.map.fire('click', { latlng: { lat: 43.52, lng: 0.16 } }));
      await agent.page.waitForSelector('.zonepop button[data-zone="Marciac"]');
    });

    await check('un recalage fait à la carte arrive en base', async () => {
      await agent.page.evaluate(() => window.cartoImmo.ouvrirRecal('a1'));
      await agent.page.waitForSelector('#recal.on');
      await agent.page.click('#recal button[data-mode="parcelle"]');
      await agent.page.waitForTimeout(300);
      await agent.page.evaluate(() => {
        document.querySelector('path[stroke="#a06a00"]')
          .dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: 1, clientY: 1 }));
      });
      await agent.page.waitForTimeout(800);
      const relu = tousLesBiens(loadStore(cfg.paths.store))[0];
      assert.ok(relu.recalage, 'la base doit porter la correction');
      assert.match(await agent.page.textContent('#corrections'), /recalage enregistré/);
    });

    await check('aucune erreur en mode agent', () => assert.deepEqual(agent.erreurs, []));
    await agent.ctx.close();
  } finally {
    serveur.close();
  }
} finally {
  await navigateur.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log(`\n${passed} vérifications passées.\n`);
