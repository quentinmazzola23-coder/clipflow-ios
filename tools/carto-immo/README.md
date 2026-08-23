# carto-immo — géolocalisation d'annonces immobilières

Les sites d'annonces ne publient jamais l'adresse d'un bien : ils affichent un
disque flou centré sur la ville. Cet agent la retrouve, et place chaque annonce
sur sa parcelle — avec le lien qui y ramène.

## Comment l'adresse est retrouvée

L'annonce porte les données de son **diagnostic de performance énergétique** :
date, étiquettes, surface, consommation. Or ces diagnostics sont publiés en open
data par l'**ADEME**, avec l'adresse et les coordonnées. Retrouver le
diagnostic, c'est retrouver le bien.

Un couple date + étiquette est déjà très discriminant à l'échelle d'un canton ;
la surface, la consommation et les émissions lèvent le reste. Le rapprochement
est noté, et **sans candidat qui se détache nettement, l'annonce reste sans
adresse** : mieux vaut un bien absent de la carte qu'un bien chez le voisin.

L'adresse mène ensuite à la **parcelle cadastrale**. Le point d'adresse tombe
souvent au bord de la voie, pas au centre du terrain : prendre la parcelle sous
le point désignerait la rue ou le voisin. On passe donc par le **bâtiment** —
la partie la plus sûrement identifiée d'une adresse — et c'est lui qui désigne
la parcelle. Le terrain annoncé sert de contrôle final : une parcelle bien plus
grande que lui trahit un point tombé sur une pièce agricole.

## Deux façons de relever les annonces

| | **Bien'ici** | **leboncoin** |
|---|---|---|
| Commande | `annonces` | `run` |
| Navigateur | non | oui, visible |
| Compte | aucun | lacquereur.fr |
| Localisation | registre des DPE | lacquereur.fr |

La voie Bien'ici ne demande **ni navigateur ni compte** : une simple requête
suffit. C'est la plus simple à programmer et la plus robuste. La voie leboncoin
couvre les annonces de particuliers absentes des portails, au prix d'une session
de navigateur à ouvrir une fois.

Dans les deux cas, l'agent :

1. relève les annonces du secteur ;
2. **trie ce qui est réellement nouveau** — une maison retirée puis remise en
   ligne sous un nouvel identifiant est reconnue comme le bien déjà suivi ;
3. retrouve l'adresse exacte, la parcelle, et situe le prix face aux ventes
   réelles du secteur (**DVF**) ;
4. consigne le tout dans un **tableur** (`.xlsx` + `.csv`) ;
5. génère une **carte interactive** et un **rapport du matin**.

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
| `cadastre` | Trace le contour exact de la parcelle de chaque bien |
| `filtresCarte` | Affiche le bloc de recherche et de filtres dans la carte |
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
node src/cli.js annonces --zone Marciac    # sans navigateur ni compte
npm run run                                 # voie leboncoin, session requise
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
| `rapport.md` | **Le rapport du matin** — à lire en premier |
| `carte.html` | La carte interactive — double-clique pour l'ouvrir |
| `annonces.xlsx` | Le tableur, filtres actifs et liens cliquables |
| `annonces.csv` | Même chose en CSV (point-virgule, UTF-8, s'ouvre dans Excel FR) |
| `annonces.json` | La base locale : historique et suivi des prix |
| `agent.log` | Journal des exécutions |

### La carte

Elle est faite pour décider d'aller frapper à une porte, pas pour tout savoir.

- Fond **photo aérienne** (orthophotographies IGN) : on voit la maison, la cour,
  les dépendances, l'accès.
- Une pastille par bien, avec son **prix**. La couleur dit l'**ancienneté** de
  l'annonce — bleu sous deux mois, ambre jusqu'à quatre, orange jusqu'à huit,
  rouge au-delà. C'est le temps passé en vitrine qui dit la disponibilité du
  vendeur, pas l'écart de prix.
- La liste est triée du plus ancien au plus récent, les biens déjà traités en fin.
- Chaque fiche porte trois boutons de suivi — **à prospecter · contacté ·
  écarté** — conservés dans le navigateur : la carte se régénère chaque matin,
  ton suivi lui survit.
- Le bouton **Ouvrir l'annonce** mène directement à l'offre.
- Clic sur une pastille ou sur la liste : la carte cadre **la parcelle
  cadastrale du bien**, contour tracé sur la photo, emprise du bâtiment
  ombrée. La fiche donne l'adresse exacte, la référence de parcelle et sa
  contenance, l'écart au marché et le DPE.
- Au zoom parcelle les pastilles laissent la place à de simples points : elles
  masqueraient le contour du terrain, qui est justement ce qu'on vient regarder.
- Le bloc de filtres est masqué par défaut (`filtresCarte` dans la config) :
  prix, surface, texte libre, et cinq raccourcis — *nouveaux*, *remis en ligne*,
  *sous le marché*, *prix baissé*, *adresse exacte*.
- Les liens portent le nom de leur destination : « Annonce leboncoin »,
  « Analyse », « Cadastre », « Maps ». Un bouton ne peut pas annoncer une
  annonce et mener ailleurs.
- Le fichier est autonome (Leaflet embarqué) ; seules les photographies
  aériennes se chargent en ligne.

**Sur téléphone**, la carte occupe tout l'écran et la liste devient un panneau
glissant : une poignée le fait passer de replié à mi-hauteur puis grand ouvert,
au doigt ou d'un simple appui. Choisir un bien déplie ses détails dans la liste
plutôt que dans une bulle — qui masquerait la carte — et le cadrage réserve la
hauteur du panneau pour que la parcelle reste visible.

### Le tableur

Une ligne **par bien**, colonnes rangées dans l'ordre de la décision :
ancienneté, prix, €/m², écart au marché, puis l'adresse et le détail, et enfin
les liens. L'ancienneté est colorée au-delà de quatre mois.

Contenu : prix, €/m², surface, terrain, pièces,
**adresse estimée**, indice de confiance, **latitude/longitude**, parcelle
cadastrale, DPE/GES, ancienneté, nombre de baisses de prix, **écart à la médiane
DVF du secteur**, fourchette de marché, délai de vente moyen sur la commune,
statut (*nouveau* / *remis en ligne*), date de première apparition, nombre de
parutions, et les liens vers l'annonce, l'analyse et Google Maps.

L'écart au marché est coloré : c'est la colonne à regarder pour repérer une
marge de négociation.

---

## Ce qui est nouveau, ce qui ne l'est pas

C'est le cœur de l'agent. Sur leboncoin, une maison qui ne se vend pas est
régulièrement retirée puis remise en ligne : nouvel identifiant, même bien.
Sans précaution, chaque remise en ligne repartirait pour une analyse et
s'annoncerait comme une nouveauté.

**La base est donc organisée par bien, pas par annonce.** Un bien porte la liste
de toutes ses parutions successives, sa date de première apparition et
l'historique complet de ses prix.

Le rapprochement se fait à deux niveaux :

**Avant l'analyse**, sur ce que la page de résultats laisse voir — commune,
surface, nombre de pièces, terrain, vendeur, titre, prix. C'est ce qui économise
les requêtes. La comparaison se fait toujours entre données leboncoin, jamais
contre les valeurs réécrites par lacquereur. Une surface, un nombre de pièces ou
une commune qui se contredisent écartent d'emblée le rapprochement.

**Après l'analyse**, sur la **parcelle cadastrale** — qui identifie un bien sans
ambiguïté — puis sur l'adresse BAN et enfin sur la position exacte.

Le seuil du premier niveau est volontairement élevé : rater un doublon coûte une
analyse, fusionner à tort masque une vraie annonce. Une remise en ligne trop
remaniée pour être reconnue au tri sera de toute façon démasquée à l'analyse par
sa parcelle, et les deux fiches fusionnées.

Chaque matin, tu obtiens donc trois catégories distinctes :

| Catégorie | Sens | Analysé ? |
|---|---|---|
| **Nouveau** | Bien jamais vu | Oui |
| **Remis en ligne** | Bien déjà suivi, nouvelle annonce | Non |
| Déjà suivi | Même annonce que la veille | Non |

Un bien qui accumule les parutions est un bien qui ne part pas : la colonne
**Parutions** du tableur est un bon signal de négociation.

---

## En cas de problème

| Symptôme | Cause et solution |
|---|---|
| « leboncoin affiche une vérification anti-robot » | Relance `npm run login`, résous le captcha, puis relance. Espace davantage les exécutions (`delayMs`). |
| « session lacquereur.fr expirée » | `npm run login` et reconnecte-toi. |
| Aucune annonce trouvée | L'URL de recherche est probablement périmée : refais la recherche sur le site et recolle l'URL dans `config.json`. |
| Des biens sans coordonnées | lacquereur.fr n'a pas pu rapprocher l'annonce d'un DPE ou d'une parcelle. Ils restent dans le tableur, signalés en italique, mais pas sur la carte. |
| Chrome ne se lance pas | Mets `"browserChannel": ""` dans `config.json` pour utiliser le Chromium de Playwright. |

## Voir la carte sans rien configurer

```bash
node scripts/carte-annonces.mjs --zone Marciac
```

Relève les annonces réellement en vente sur le secteur, retrouve leur adresse,
et écrit deux cartes plus le tableur — sans navigateur, sans compte, sans
configuration.

`carte-annonces.html` charge les photographies aériennes de l'IGN.
`carte-annonces-autonome.html` embarque tout et fonctionne **sans aucune requête
sortante** : la France par départements et les communes du secteur en vue large,
les **dalles de photo aérienne** autour de chaque bien au zoom parcelle. Elle
pèse quelques mégaoctets, et n'affiche pas les photos des annonces, qui sont
hébergées par le site.

```bash
node scripts/carte-annonces.mjs --zone Auch --max 100 --types house,flat --filtres
```

Les téléchargements sont mis en cache : ces API publiques répondent
régulièrement 503, et les fichiers ne bougent pas.

## Tests

```bash
npm test
```

Quatre campagnes, toutes **sans accès réseau** :

- `test/smoke.mjs` — décodage d'une vraie page lacquereur.fr enregistrée,
  normalisation, base locale, tableur, carte.
- `test/dedup.mjs` — reconnaissance des remises en ligne : republication à
  l'identique, avec baisse de prix, au titre réécrit ; non-confusion de deux
  maisons voisines de même taille ; rattrapage par la parcelle cadastrale ;
  rapport du matin.
- `test/geoloc.mjs` — géométrie cadastrale (trous, centroïdes, distance au bord)
  et appariement annonce ↔ diagnostic : ce qui doit être
  accepté (surface annoncée plus large, consommation divergente, commune
  voisine) et surtout ce qui doit être refusé (étiquette climat différente,
  appartement pour une maison, distance excessive).
- `test/integration.mjs` — pilotage réel du navigateur, requêtes interceptées :
  collecte, analyse, session expirée, mur anti-bot, annonce sans localisation,
  et un scénario complet sur deux matins consécutifs.

---

## À savoir

- L'agent reproduit ce que tu ferais à la main, à ton rythme et avec ta propre
  session : les requêtes sont **séquentielles et temporisées**, et le nombre
  d'analyses par exécution est plafonné. Garde ces réglages conservateurs —
  leboncoin comme lacquereur.fr n'autorisent pas la collecte massive dans leurs
  conditions d'utilisation, et une cadence agressive te ferait bloquer.
- Les données collectées (adresses, coordonnées) restent **sur ta machine** :
  aucun serveur, aucun envoi.
- L'adresse est **reconstituée**, pas publiée : la colonne « Confiance »
  indique la solidité du rapprochement. À vérifier avant toute démarche.
- Les données mobilisées sont ouvertes et publiques — registre des DPE, cadastre,
  ventes DVF. Le rapprochement se fait sur des biens en vente, à des fins
  d'estimation professionnelle.
