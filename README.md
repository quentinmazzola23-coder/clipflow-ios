# ClipFlow — sélection rapide de rushes et ralenti interpolé (iOS)

Application iPhone native (Swift / SwiftUI, iOS 26+) pour parcourir très vite des
dizaines ou centaines de rushes, sélectionner des passages courts de **durée finale
fixe** (ex. 1,3 s), puis exporter chaque passage **ralenti à 0,5×** avec
**interpolation d'images par flux optique** (VideoToolbox `VTFrameProcessor`).

Entièrement hors ligne : aucun serveur, aucun compte, aucune analytique.
SwiftData strictement local (CloudKit désactivé). Export direct dans Photos.

---

## ⚠️ État du projet — à lire d'abord

Ce projet a été **généré sur une machine Windows, sans Xcode ni SDK iOS**.
Conformément au cahier des charges (section 2), l'intégralité du projet et des
tests est fournie, mais :

1. **La compilation réelle doit être effectuée sur un Mac avec Xcode 26+**
   (SDK iOS 26 requis pour `VTFrameProcessor` / `VTFrameRateConversionConfiguration`).
2. **Vérification API obligatoire avant première compilation** — voir section
   dédiée ci-dessous. Les signatures VideoToolbox suivent la documentation Apple
   mais n'ont pas pu être confrontées aux interfaces réelles du SDK.
3. Aucune mesure de performance sur appareil réel n'a encore été faite.

## Structure

```
ClipFlow-iOS/
├── ClipFlow.xcodeproj/          Projet Xcode (objectVersion 77, groupes synchronisés)
├── ClipFlow/
│   ├── App/ClipFlowApp.swift            Entrée + conteneur SwiftData local
│   ├── Models/Models.swift              ClipProject, Rush, Passage, catégories
│   ├── Core/
│   │   ├── TimeMath.swift               Maths temporelles RATIONNELLES + FramePlanner
│   │   ├── SelectionEngine.swift        Sélection à durée fixe (logique pure)
│   │   ├── NamingEngine.swift           001_reveal_grange_fixe_statique.mov
│   │   └── ChronoSort.swift             Tri chronologique par cascade de replis
│   ├── Services/
│   │   ├── PhotoImporter.swift          PhotosPicker → fichier (jamais de Data), métadonnées
│   │   ├── MediaAvailabilityService.swift  États local/iCloud/hors-ligne, source d'export
│   │   ├── ProxyGenerator.swift         Proxys 144p/240p tout-intra, file en arrière-plan
│   │   ├── ThumbnailCache.swift         Miniatures NSCache depuis les proxys
│   │   ├── StorageManager.swift         App Support / Caches / Temporary, exclusion backup
│   │   ├── ThermalMonitor.swift         Température, batterie, veille
│   │   ├── RenderQueue.swift            File de rendu : 1 passage à la fois, pause/reprise
│   │   ├── PhotoExportService.swift     PhotoKit .addOnly, suppression après confirmation
│   │   └── ManifestExporter.swift       Manifeste JSON partageable
│   ├── Interpolation/
│   │   ├── FrameInterpolationEngine.swift          Protocole + fabrique
│   │   ├── VideoToolboxFrameInterpolationEngine.swift  iOS 26+, flux optique .quality
│   │   └── PassthroughRetimeEngine.swift           « Rapide — sans interpolation avancée »
│   ├── Pipeline/VideoRenderPipeline.swift  Reader → plan → interpolation → Writer → vérif
│   └── Views/                           SwiftUI + timeline UIKit virtualisée
└── ClipFlowTests/                       Tests Swift Testing + vidéos synthétiques
```

## Compilation et installation sur iPhone

### Prérequis
- Mac avec **Xcode 26** ou ultérieur (SDK iOS 26).
- iPhone sous iOS 26+ (l'app cible iOS 26 pour `VTFrameProcessor`).
- Un identifiant Apple (gratuit suffisant pour l'installation personnelle, 7 jours ;
  compte développeur payant pour 1 an).

### Étapes
1. Ouvrir `ClipFlow.xcodeproj` dans Xcode.
2. Cible **ClipFlow** → onglet *Signing & Capabilities* :
   - cocher **Automatically manage signing** (déjà configuré) ;
   - choisir votre **Team** (votre identifiant Apple) ;
   - remplacer le **Bundle Identifier** `com.example.clipflow` par un identifiant
     unique, ex. `com.votrenom.clipflow`.
   Aucun certificat ni identifiant personnel n'est stocké dans le dépôt.
3. Brancher l'iPhone, l'autoriser à faire confiance au Mac.
4. Sélectionner l'iPhone comme destination, puis ⌘R.
5. Sur l'iPhone : *Réglages → Général → VPN et gestion de l'appareil* → faire
   confiance au profil développeur.

### Lignes de commande
```bash
# Compilation (remplacer TEAM_ID)
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=TEAM_ID PRODUCT_BUNDLE_IDENTIFIER=com.votrenom.clipflow \
  build

# Tests unitaires (simulateur — les tests VideoToolbox exigent un appareil réel)
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  test

# Tests sur appareil réel
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow \
  -destination 'platform=iOS,name=VOTRE_IPHONE' \
  test
```

## Vérification API — à faire dans Xcode avant la première compilation

Le moteur `VideoToolboxFrameInterpolationEngine` suit la documentation Apple :

- [`VTFrameRateConversionConfiguration`](https://developer.apple.com/documentation/videotoolbox/vtframerateconversionconfiguration/init%28framewidth%3Aframeheight%3Auseprecomputedflow%3Aqualityprioritization%3Arevision%3A%29)
- [WWDC 2025 — session 300 (conversion de fréquence / interpolation)](https://developer.apple.com/videos/play/wwdc2025/300/)

Points à confronter aux interfaces réelles (⌃⌘-clic sur le symbole → *Jump to Definition*) :

| Élément | À vérifier |
|---|---|
| `VTFrameRateConversionConfiguration.init(frameWidth:frameHeight:usePrecomputedFlow:qualityPrioritization:revision:)` | failable ? ordre/nom des paramètres |
| `VTFrameRateConversionConfiguration.isSupported` | nom exact de la propriété de disponibilité |
| `configuration.sourcePixelBufferAttributes` / `.destinationPixelBufferAttributes` | type de retour (NSDictionary vs [String: Any]) |
| `VTFrameProcessor.startSession(configuration:)` / `.process(parameters:)` / `.endSession()` | variante async |
| `VTFrameProcessorFrame(buffer:presentationTimeStamp:)` | failable ? |
| `VTFrameRateConversionParameters(sourceFrame:nextFrame:opticalFlow:interpolationPhase:submissionMode:destinationFrames:)` | type d'`interpolationPhase` ([Float] vs [NSNumber]) |
| `AVAssetExportSession.export(to:as:)` | disponibilité de l'API async (iOS 18+) |

En cas d'écart : la correction reste localisée dans
`Interpolation/VideoToolboxFrameInterpolationEngine.swift` — le reste du pipeline
passe par le protocole `FrameInterpolationEngine`.

## Autorisations

| Clé | Usage |
|---|---|
| `NSPhotoLibraryAddUsageDescription` | Enregistrement des exports dans Photos (accès **ajout seul**) |
| `NSPhotoLibraryUsageDescription` | Facultatif : lecture des dates de capture PHAsset pour affiner le tri |

`PhotosPicker` n'exige aucune autorisation (interface système hors processus).

## Précision temporelle (rappel des garanties)

- Durées en **centisecondes entières**, vitesses en **fractions** (1/2), timestamps
  en **CMTime rationnels** — aucun cumul d'erreurs flottantes.
- 1,3 s à 0,5× → 0,65 s source → **exactement 78 images à 60 fps** (testé).
- Une image source tombant exactement sur un timestamp final est **copiée, pas
  interpolée** (source 120 fps → 0 interpolation, testé).
- Vérification post-rendu : durée + comptage d'images du fichier produit ;
  échec = erreur, jamais d'export silencieusement faux.

## Limites connues du MVP

1. **Non compilé** (généré hors macOS) — voir « Vérification API ».
2. **Mode espace réduit incomplet** : l'import copie toujours le fichier complet
   dans l'app (le transfert PhotosPicker produit de toute façon une copie).
   La libération automatique des sources après mise en cache des plages validées
   reste à faire ; en attendant, la page Stockage permet les suppressions manuelles.
3. **HDR** : SDR et HLG pris en charge (HEVC Main10 + tags 2020/HLG). PQ,
   Dolby Vision et Apple Log sont **refusés à l'export** avec message clair
   (pas de conversion tone-mappée encore — jamais d'export délavé silencieux).
4. **Audio** : supprimé dans tous les exports (option « audio ralenti » prévue au schéma).
5. **Moteur Vision/Metal** (`VNGenerateOpticalFlowRequest` + warping Metal) non
   implémenté — le protocole `FrameInterpolationEngine` est prêt à l'accueillir.
   Secours actuel : duplication d'images, nommé honnêtement
   « Rapide — sans interpolation avancée ».
6. **Analyse locale des catégories** (section 16) non commencée — volontaire, hors MVP.
7. **Réordonnancement manuel** des passages en relecture : suppression et
   catégories opérationnelles ; le glisser-déposer d'ordre reste à câbler.
8. **iCloud Photos** : si une vidéo n'est pas locale, le picker la télécharge lors
   de la sélection (comportement système). L'app affiche l'état par rush mais ne
   peut pas déclencher elle-même un téléchargement (aucun réseau applicatif).
9. Concurrence : ciblage Swift 5 mode (pas de strict concurrency complète) ;
   passage à Swift 6 prévu après validation sur appareil.

## À valider sur appareil réel (non mesurable hors Mac/iPhone)

- fluidité timeline (objectif : 60–120 Hz, retour < 100 ms) — profiler avec
  Instruments (`os_signpost` déjà posés dans le pipeline de rendu) ;
- débit réel du moteur VideoToolbox en 4K et comportement thermique ;
- consommation mémoire du scrubbing avec 500 rushes ;
- proxys : vitesse de génération (viser ≈ temps réel ×3 ou mieux en 144p).

## Ordre de test conseillé sur iPhone

1. Créer un projet, importer 3–5 vidéos → vérifier ordre chronologique.
2. Attendre les proxys (badge orange → disparition), passer en mode avion.
3. Régler 1,3 s, toucher un rush, déplacer la sélection, valider, catégoriser.
4. Relecture → tout lire.
5. Exports → vérifier dans Photos : 1,3 s, 78 images, ralenti fluide.
6. Fermer/rouvrir l'app → projet intact.
