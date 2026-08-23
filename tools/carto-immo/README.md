# carto-immo — veille immobilière automatisée

Agent qui, à la demande ou chaque matin :

1. parcourt tes recherches **leboncoin** et relève toutes les annonces ;
2. envoie chaque annonce à **lacquereur.fr**, qui en déduit l'emplacement du bien
   (adresse BAN, parcelle cadastrale, coordonnées GPS) ainsi que son positionnement
   de prix face aux ventes réelles du secteur (DVF) ;
3. consigne le tout dans un **tableur** (`.xlsx` + `.csv`) ;
4. génère une **carte interactive** où chaque maison apparaît à sa position, avec
   son prix, ses infos et ses liens.

---

## Installation (une seule fois)

Il faut [Node.js 18+](https://nodejs.org). Ensuite, dans ce dossier :

```bash
npm install
npx playwright install chromium
```

### 1. Régler tes recherches

```bash
cp config.example.json config.json
```

Ouvre `config.json` et colle dans `"searches"` les URL de tes recherches
leboncoin — exactement celles qui s'affichent dans la barre d'adresse quand tu
as posé tes filtres sur le site. Tu peux en mettre autant que tu veux.

| Réglage | Rôle |
|---|---|
| `searches` | Les URL de recherche leboncoin à parcourir |
| `pagesPerSearch` | Nombre de pages de résultats par recherche |
| `maxAnalysesPerRun` | Plafond d'analyses par exécution — évite les longues sessions |
| `reanalyseAfterDays` | Rafraîchir une annonce déjà connue au bout de N jours |
| `filters` | Écarte les annonces hors budget/surface **avant** analyse |
| `headless` | Laisse `false` : le navigateur visible passe bien mieux les protections |
| `openMapWhenDone` | Ouvre la carte automatiquement en fin d'exécution |

### 2. Se connecter (une seule fois)

```bash
npm run login
```

Un navigateur s'ouvre. Connecte-toi à **lacquereur.fr** (un compte est
obligatoire pour analyser une annonce), puis va sur **leboncoin.fr**, accepte
les cookies et résous la vérification anti-robot si elle apparaît. Reviens dans
le terminal et appuie sur Entrée.

La session est enregistrée dans `browser-profile/` et réutilisée à chaque
exécution : tu ne referas ça que si tu es déconnecté.

> Sous Windows, `bin\connexion.cmd` fait la même chose en double-cliquant.

---

## Utilisation

```bash
npm run run           # exécution complète
```

Sous Windows, double-clique **`bin\lancer-agent.cmd`**.

Autres commandes :

```bash
node src/cli.js add <url…>   # analyser une ou plusieurs annonces précises
node src/cli.js map          # régénérer tableur et carte sans rien recollecter
node src/cli.js schedule     # rappeler comment programmer l'exécution quotidienne
node src/cli.js run --max 10 # limiter le nombre d'analyses pour ce lancement
```

Depuis Claude Code, la commande `/carto-immo` lance la même chose.

### Tous les matins

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\planifier-windows.ps1
powershell -ExecutionPolicy Bypass -File scripts\planifier-windows.ps1 -Heure 06:45
```

```bash
# macOS / Linux
./scripts/planifier-cron.sh 07:30
```

La tâche doit s'exécuter **session ouverte** : le navigateur a besoin du profil
connecté. Une exécution en arrière-plan, machine verrouillée, échouera.

---

## Ce que tu récupères

Tout arrive dans `data/` :

| Fichier | Contenu |
|---|---|
| `carte.html` | La carte interactive — double-clique pour l'ouvrir |
| `annonces.xlsx` | Le tableur, filtres actifs et liens cliquables |
| `annonces.csv` | Même chose en CSV (point-virgule, UTF-8, s'ouvre dans Excel FR) |
| `annonces.json` | La base locale : historique et suivi des prix |
| `agent.log` | Journal des exécutions |

### La carte

- Une pastille par bien, avec son prix. **Vert** = sous le marché,
  **orange** = dans le marché, **rouge** = au-dessus, **gris** = pas d'estimation.
- Clic sur une pastille ou sur la liste de gauche : photo, prix au m², surface,
  DPE, adresse estimée, écart au marché, ancienneté de l'annonce, liens.
- Filtres : prix, surface, texte libre, et quatre raccourcis — *nouvelles*,
  *sous le marché*, *prix baissé*, *adresse exacte*.
- Le fichier est autonome (Leaflet embarqué) ; seul le fond de carte
  OpenStreetMap se charge en ligne.

### Le tableur

Une ligne par bien : prix, €/m², surface, terrain, pièces, **adresse estimée**,
indice de confiance, **latitude/longitude**, parcelle cadastrale, DPE/GES,
ancienneté, nombre de baisses de prix, **écart à la médiane DVF du secteur**,
fourchette de marché, délai de vente moyen sur la commune, et les liens vers
l'annonce, l'analyse et Google Maps.

L'écart au marché est coloré : c'est la colonne à regarder pour repérer une
marge de négociation.

---

## Suivi dans le temps

La base locale n'est jamais écrasée. À chaque exécution :

- les annonces déjà vues ne sont pas ré-analysées (sauf après
  `reanalyseAfterDays`), ce qui économise des requêtes ;
- les nouvelles sont marquées **nouveau** dans la carte et le tableur ;
- toute variation de prix est ajoutée à l'historique de la fiche.

---

## En cas de problème

| Symptôme | Cause et solution |
|---|---|
| « leboncoin affiche une vérification anti-robot » | Relance `npm run login`, résous le captcha, puis relance. Espace davantage les exécutions (`delayMs`). |
| « session lacquereur.fr expirée » | `npm run login` et reconnecte-toi. |
| Aucune annonce trouvée | L'URL de recherche est probablement périmée : refais la recherche sur le site et recolle l'URL dans `config.json`. |
| Des biens sans coordonnées | lacquereur.fr n'a pas pu rapprocher l'annonce d'un DPE ou d'une parcelle. Ils restent dans le tableur, signalés en italique, mais pas sur la carte. |
| Chrome ne se lance pas | Mets `"browserChannel": ""` dans `config.json` pour utiliser le Chromium de Playwright. |

## Tests

```bash
npm test
```

Deux campagnes, toutes deux **sans accès réseau** :

- `test/smoke.mjs` — décodage d'une vraie page lacquereur.fr enregistrée,
  normalisation, base locale, tableur, carte.
- `test/integration.mjs` — pilotage réel du navigateur, requêtes interceptées :
  collecte, analyse, session expirée, mur anti-bot, annonce sans localisation.

---

## À savoir

- L'agent reproduit ce que tu ferais à la main, à ton rythme et avec ta propre
  session : les requêtes sont **séquentielles et temporisées**, et le nombre
  d'analyses par exécution est plafonné. Garde ces réglages conservateurs —
  leboncoin comme lacquereur.fr n'autorisent pas la collecte massive dans leurs
  conditions d'utilisation, et une cadence agressive te ferait bloquer.
- Les données collectées (adresses, coordonnées) restent **sur ta machine** :
  aucun serveur, aucun envoi.
- L'adresse rendue par lacquereur.fr est une **estimation** : la colonne
  « Confiance » indique sa fiabilité. À vérifier avant toute démarche.
