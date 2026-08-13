# Flux optique — paquet de correction

Écrit le 13/08/2026, à l'état du commit `c28920c`.
Complément à `FLUX-OPTIQUE-EXPLICATION.txt`, qu'il **corrige sur plusieurs points**.

---

## AVERTISSEMENT — ce qui a été vérifié, et ce qui ne l'a pas été

Ce document est issu d'une **lecture statique du code**. Aucun export n'a été
observé, aucun log d'appareil n'a été lu, aucune image n'a été comparée.

Ce qui est **prouvé** (vérifiable par lecture ou `grep`, sans appareil) :

- `FrameInterpolationEngine.sourcePixelBufferAttributes` n'est lu par aucun
  appelant. Le pipeline n'utilise jamais les exigences d'entrée de VideoToolbox.
- `supported.isEmpty` déclenche un repli silencieux sur BGRA — exactement la
  supposition que l'en-tête du moteur décrit comme cause du ciel rose.
- Le pool de destination est construit avec le format dérivé des formats
  **source**, et `makePool` écrase la clé de format des attributs de destination.
- La condition de conversion en sortie teste la branche d'**entrée**
  (`usesDirectBGRA`), pas le format réel du pool de destination.
- `propagateColorAttachments` écrit dans `group.prev`/`group.next` quand le
  failsafe substitue, pendant que ces mêmes buffers sont soumis à VideoToolbox
  pour le groupe suivant.
- Les seuils et l'échantillonnage des détecteurs les rendent aveugles à tout
  artefact qui n'est pas plein cadre (chiffres en §D).

Ce qui reste une **hypothèse** : la part de chacun de ces défauts dans les
artefacts observés. Elle peut être de 90 % comme de 5 %. **L'étape 0 est donc
bloquante** : sans elle, les correctifs 1 à 3 sont appliqués à l'aveugle.

Ce qui n'est **pas** corrigible : les limites intrinsèques du flux optique
(occlusions, flou de bougé, grand déplacement, texture répétitive, spéculaires,
rolling shutter). Un rush POV moto/skate les cumule toutes. Après correction, le
taux d'artefact sera celui de l'algorithme, pas celui du code — il ne sera pas
nul. D'où §F (repli total), qui reste nécessaire même si tout ce document est
appliqué.

---

# PARTIE 1 — PROMPT À DONNER À LA SESSION QUI TRAVAILLE SUR MAC

> Copier-coller le bloc ci-dessous tel quel.

```
Contexte
--------
Dépôt ClipFlow-iOS, app iOS 26 native. Le rendu de ralenti 0,5× utilise
VTFrameProcessor + VTFrameRateConversionConfiguration pour fabriquer les images
intermédiaires. Le flux optique produit des artefacts visibles sur du contenu
réel et a été désactivé par défaut au commit 1cf7414 (`opticalFlowEnabled =
false`). Objectif : corriger l'intégration VideoToolbox, MESURER le résultat, et
ne rallumer l'interrupteur que si la mesure le justifie.

Lis d'abord FLUX-OPTIQUE-CORRECTIFS.md à la racine du dépôt. Il contient
l'analyse, les 7 correctifs avec le code complet, la refonte du détecteur et le
protocole de validation.

Ce que tu dois savoir avant de commencer
----------------------------------------
1. L'analyse dans ce fichier est une lecture statique. Rien n'a été vérifié sur
   appareil. Ne traite pas ses conclusions comme acquises.
2. Le simulateur iOS n'embarque PAS VTFrameProcessor, et le runner CI échoue à
   startSession avec VTFrameProcessorErrorDomain Code=-19730. Seul un iPhone
   physique exécute réellement ce moteur. Toute validation passe par l'appareil.
3. Le dépôt a été écrit sous Windows et n'a jamais été compilé. Les signatures
   VideoToolbox iOS 26 sont à confronter aux interfaces réelles (⌃⌘-clic →
   Jump to Definition). Le tableau de vérification est dans README.md §
   « Vérification API ».

Ordre de travail — impératif
----------------------------
ÉTAPE 0 (BLOQUANTE). Applique l'instrumentation de la §A. Compile, lance sur
iPhone, exporte un clip avec le flux optique ACTIVÉ, et rapporte-moi le contenu
brut des logs : type dynamique et contenu de sourcePixelBufferAttributes et
destinationPixelBufferAttributes, liste des formats détectés, branche empruntée.
NE PASSE PAS à l'étape suivante avant d'avoir ces logs. Les correctifs 1, 2 et 3
dépendent de ce qu'ils révèlent, et l'un des embranchements (VT n'accepte pas
BGRA) invalide la chaîne tout-RGB du pipeline.

ÉTAPE 1. Refonte du détecteur (§D). Avant tout correctif de rendu. Les
détecteurs actuels échantillonnent 0,05 % des pixels avec un seuil de 38 niveaux
sur une moyenne de tuile : ils ne peuvent pas te dire si une correction a marché.
Livrer un correctif sans instrument de mesure, c'est refaire le cycle qui a mené
à l'interrupteur éteint.

ÉTAPE 2. Correctifs 1 à 7 (§B), dans l'ordre donné. Un commit par correctif,
message court, en français, sans mention d'outil.

ÉTAPE 3. Repli total (§F) : remplacer la réparation partielle en 3 passes par un
re-rendu complet sans flux optique dès la moindre anomalie.

ÉTAPE 4. Protocole de validation (§G). Rapporte le taux d'artefact PAR IMAGE
FABRIQUÉE, mesuré, sur les rushes réels et sur les 5 patterns adverses.

Règles
------
- N'active PAS `opticalFlowEnabled = true` par défaut. L'interrupteur reste
  éteint tant que le taux d'artefact n'est pas mesuré et rapporté. C'est ma
  décision, pas la tienne.
- N'ajoute aucun effet, aucun filtre, aucun lissage pour masquer un artefact.
- Si une signature d'API diffère de ce que le document suppose, dis-le et
  arrête-toi — ne devine pas la sémantique d'un mode de soumission ou d'un
  format de pixel.
- Si un correctif ne peut pas être validé sur appareil, dis-le explicitement
  plutôt que de le déclarer bon.
```

---

# PARTIE 2 — LES CORRECTIFS

## §A — ÉTAPE 0 : instrumentation (bloquante)

Rien dans le dépôt ne montre ce que VideoToolbox demande réellement. Les
correctifs 1 à 3 s'appuient sur des suppositions tant que ces lignes ne sont pas
lues sur un iPhone.

**Fichier :** `ClipFlow/Interpolation/VideoToolboxFrameInterpolationEngine.swift`

Ajouter en haut du fichier :

```swift
import os
```

Ajouter dans la classe :

```swift
    private static let log = OSLog(subsystem: "com.example.clipflow", category: "Interpolation")

    /// Rend un OSType lisible : « BGRA (0x42475241) ».
    static func fourCC(_ format: OSType) -> String {
        let bytes = [
            UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
            UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        let ascii = printable ? String(decoding: bytes, as: UTF8.self) : "????"
        return "\(ascii) (0x\(String(format, radix: 16)))"
    }

    /// Description BRUTE d'un dictionnaire d'attributs VideoToolbox, type
    /// dynamique compris. Le README signale que le type de retour de
    /// `sourcePixelBufferAttributes` n'a jamais été confronté à l'interface
    /// réelle : c'est précisément ce que cette trace doit établir.
    static func describeAttributes(_ raw: Any?) -> String {
        guard let raw else { return "nil" }
        var report = "type dynamique = \(type(of: raw))\n"
        guard let dictionary = raw as? [String: Any] else {
            report += "  NON PONTABLE en [String: Any] — contenu brut : \(raw)"
            return report
        }
        for key in dictionary.keys.sorted() {
            let value = dictionary[key]!
            if key == kCVPixelBufferPixelFormatTypeKey as String {
                report += "  \(key) : type \(type(of: value)) = \(value)\n"
            } else {
                report += "  \(key) = \(value)\n"
            }
        }
        return report
    }
```

Et dans `startSession`, immédiatement après `try processor.startSession(configuration: configuration)` :

```swift
        // ÉTAPE 0 — INSTRUMENTATION. À retirer une fois les branches 1 à 3
        // arbitrées sur appareil.
        os_log("VT config %dx%d — sourcePixelBufferAttributes :\n%{public}@",
               log: Self.log, type: .info, width, height,
               Self.describeAttributes(configuration.sourcePixelBufferAttributes))
        os_log("VT config %dx%d — destinationPixelBufferAttributes :\n%{public}@",
               log: Self.log, type: .info, width, height,
               Self.describeAttributes(configuration.destinationPixelBufferAttributes))
        let probedSource = Self.pixelFormats(in: configuration.sourcePixelBufferAttributes)
        let probedDestination = Self.pixelFormats(in: configuration.destinationPixelBufferAttributes)
        os_log("VT formats — source : [%{public}@] / destination : [%{public}@]",
               log: Self.log, type: .info,
               probedSource.map(Self.fourCC).joined(separator: ", "),
               probedDestination.map(Self.fourCC).joined(separator: ", "))
```

(`pixelFormats` est la version robuste définie au correctif 2 — l'appliquer
avant de compiler cette trace.)

**Ce qu'il faut rapporter :** les trois blocs de log, verbatim. En particulier :
le type dynamique des deux dictionnaires, la présence ou l'absence de
`kCVPixelBufferPixelFormatTypeKey`, si BGRA figure dans la liste source, et si
les listes source et destination diffèrent.

**Trois embranchements possibles, tous à traiter différemment :**

| Résultat de l'étape 0 | Conséquence |
|---|---|
| BGRA présent en source ET en destination | Chaîne tout-RGB valide. Correctifs 1-3 restent des durcissements. |
| BGRA absent de la source | **La chaîne tout-RGB tombe.** Le lecteur doit décoder au format VT, et la classe de bug « chrominance inversée » redevient possible. Décision à prendre avant d'aller plus loin. |
| Les dictionnaires ne se pontent pas en `[String: Any]` | Le code actuel tombe dans `supported.isEmpty` → BGRA supposé → VT réinterprète la mémoire depuis toujours. **Cause racine probable.** |

---

## §B — LES 7 CORRECTIFS

### Correctif 1 — brancher les exigences d'entrée du moteur sur le décodeur

**Problème.** `sourcePixelBufferAttributes` est déclaré « à passer au décodeur »
et n'est lu nulle part. Le lecteur est câblé en dur sur BGRA + IOSurface,
ignorant l'alignement de ligne, les pixels étendus et la compatibilité Metal
exigés par VideoToolbox. En `usesDirectBGRA = true`, le buffer du décodeur part
tel quel dans `VTFrameProcessorFrame`.

**Fichier :** `ClipFlow/Pipeline/VideoRenderPipeline.swift`

Ajouter dans `VideoRenderPipeline` :

```swift
    /// Clés que `AVAssetReaderTrackOutput` accepte réellement dans ses
    /// outputSettings vidéo. VideoToolbox peut en retourner d'autres (attributs
    /// de pool notamment) : passer son dictionnaire verbatim lève une exception
    /// — c'est ce que redoutait le commentaire d'origine, et c'est la raison
    /// pour laquelle rien n'avait été branché. Le filtre lève l'objection.
    static let readerAcceptedKeys: Set<String> = [
        kCVPixelBufferPixelFormatTypeKey as String,
        kCVPixelBufferBytesPerRowAlignmentKey as String,
        kCVPixelBufferExtendedPixelsLeftKey as String,
        kCVPixelBufferExtendedPixelsRightKey as String,
        kCVPixelBufferExtendedPixelsTopKey as String,
        kCVPixelBufferExtendedPixelsBottomKey as String,
        kCVPixelBufferIOSurfacePropertiesKey as String,
        kCVPixelBufferMetalCompatibilityKey as String,
    ]

    /// Attributs de lecture = exigences du MOTEUR, filtrées sur ce que le
    /// lecteur accepte, plus nos garanties non négociables.
    ///
    /// Une liste de formats est un CHOIX offert par VideoToolbox, pas une
    /// consigne : le lecteur en veut exactement un. Priorité à BGRA s'il est
    /// proposé (chaîne tout-RGB), sinon le premier de la liste.
    static func readerSettings(engineAttributes: [String: Any]?,
                               preferredFormat: OSType) -> [String: Any] {
        var settings: [String: Any] = [:]
        for (key, value) in engineAttributes ?? [:] where readerAcceptedKeys.contains(key) {
            settings[key] = value
        }
        let formatKey = kCVPixelBufferPixelFormatTypeKey as String
        let offered = VideoToolboxFormatProbe.pixelFormats(in: engineAttributes)
        if offered.isEmpty {
            settings[formatKey] = preferredFormat
        } else if offered.contains(preferredFormat) {
            settings[formatKey] = preferredFormat
        } else {
            settings[formatKey] = offered[0]
        }
        // Non négociable : IOSurface (partage GPU sans copie).
        settings[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        return settings
    }
```

Remplacer le bloc `readerSettings` de `renderPass` (actuellement lignes 367-370) :

```swift
        // AVANT
        let readerSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: readerPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        // APRÈS
        // Le décodeur produit EXACTEMENT ce que le moteur exige. Sans cela, VT
        // reçoit des buffers dont il n'a jamais validé l'alignement de ligne ni
        // les pixels étendus — et il ne lève aucune erreur, il lit de travers.
        let readerSettings = Self.readerSettings(
            engineAttributes: engine.sourcePixelBufferAttributes,
            preferredFormat: readerPixelFormat
        )
        let decodedFormat = readerSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType
            ?? readerPixelFormat
        os_log("Décodage au format %{public}@ (exigé par %{public}@)",
               log: signpostLog, type: .info,
               VideoToolboxFormatProbe.fourCC(decodedFormat), engine.displayName)
```

**Ordre d'exécution — point à traiter.** `readerSettings` a besoin du moteur, or
le moteur est préchauffé **en parallèle** de la passe 1 (lecture des timestamps).
La passe 1 ne lit que des PTS, jamais des pixels : son format n'influe pas sur
l'ensemble des échantillons livrés, seulement sur leur représentation. Elle peut
donc rester en BGRA. Le commentaire lignes 274-278 qui exige « la même
configuration de lecteur » vise le passthrough contre le décodage, pas le format
de pixel. **À confirmer par mesure** : comparer `sourcePTS.count` entre les deux
formats sur un rush réel avant de considérer le point clos.

**Conséquence si VT n'accepte pas BGRA :** la chaîne tout-RGB du pipeline tombe,
`tileLuma` bascule sur sa branche bi-planaire (déjà écrite), et la classe de bug
« chrominance inversée » redevient possible côté encodeur. Ne pas appliquer ce
correctif sans avoir lu les logs de l'étape 0.

---

### Correctif 2 — supprimer le repli silencieux sur BGRA

**Problème.** `supported.isEmpty` → on suppose BGRA. C'est mot pour mot la
supposition que l'en-tête du fichier décrit comme cause du ciel rose. Et
`isEmpty` est facile à atteindre : `as? [String: Any]` échoue si le retour est un
`NSDictionary` à clés non-String, `as? [NSNumber]` échoue si le CFArray se ponte
en `[Any]`. VideoToolbox ne lève aucune erreur sur un format non conforme : il
réinterprète la mémoire.

**Fichier :** `ClipFlow/Interpolation/VideoToolboxFrameInterpolationEngine.swift`

Extraire la sonde de format hors de la classe (elle doit servir au pipeline et
rester compilable hors `#if !targetEnvironment(simulator)`) — **nouveau fichier**
`ClipFlow/Interpolation/VideoToolboxFormatProbe.swift` :

```swift
//
//  VideoToolboxFormatProbe.swift
//  ClipFlow
//
//  Lecture ROBUSTE des dictionnaires d'attributs VideoToolbox. Chaque pont
//  Swift raté ici se traduit par une liste de formats vide, donc par une
//  supposition — et une supposition de format ne provoque aucune erreur : VT
//  réinterprète simplement la mémoire des plans.
//

import Foundation
import CoreVideo

enum VideoToolboxFormatProbe {

    /// Formats de pixel annoncés par un dictionnaire d'attributs.
    /// Tolère les trois pontages possibles de la valeur : nombre unique,
    /// tableau de NSNumber, tableau hétérogène issu d'un CFArray.
    static func pixelFormats(in attributes: Any?) -> [OSType] {
        guard let dictionary = attributes as? [String: Any],
              let value = dictionary[kCVPixelBufferPixelFormatTypeKey as String] else { return [] }
        if let number = value as? NSNumber { return [number.uint32Value] }
        if let list = value as? [NSNumber] { return list.map { $0.uint32Value } }
        if let list = value as? [Any] { return list.compactMap { ($0 as? NSNumber)?.uint32Value } }
        return []
    }

    /// Rend un OSType lisible : « BGRA (0x42475241) ».
    static func fourCC(_ format: OSType) -> String {
        let bytes = [
            UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
            UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        let ascii = printable ? String(decoding: bytes, as: UTF8.self) : "????"
        return "\(ascii) (0x\(String(format, radix: 16)))"
    }
}
```

Dans le moteur, remplacer `supportedSourceFormats` par un appel à la sonde, et
remplacer la négociation (lignes 92-117) :

```swift
        // AVANT
        let supported = Self.supportedSourceFormats(of: configuration)
        if supported.isEmpty || supported.contains(kCVPixelFormatType_32BGRA) {
            usesDirectBGRA = true
            vtFormat = kCVPixelFormatType_32BGRA
        } else {

        // APRÈS
        let supported = VideoToolboxFormatProbe.pixelFormats(in: configuration.sourcePixelBufferAttributes)
        // AUCUNE SUPPOSITION. Une liste vide signifie que la configuration n'a
        // rien annoncé d'exploitable — supposer BGRA réinterpréterait la mémoire
        // des plans SANS erreur (ciel rose, verts turquoise, constaté sur
        // exports réels). Échec net.
        guard !supported.isEmpty else {
            processor.endSession()
            throw InterpolationError.processingFailed(
                "Aucun format de pixel source exploitable annoncé par "
                + "VTFrameRateConversionConfiguration. Attributs bruts : "
                + String(describing: configuration.sourcePixelBufferAttributes)
            )
        }
        if supported.contains(kCVPixelFormatType_32BGRA) {
            usesDirectBGRA = true
            vtFormat = kCVPixelFormatType_32BGRA
        } else {
```

---

### Correctif 3 — pool de destination au format de DESTINATION

**Problème.** Le pool de destination est construit avec `vtFormat`, dérivé des
formats **source**, et `makePool` écrase la clé de format des attributs de
destination. Si VT sort en NV12 et entre en BGRA (ou l'inverse), il écrit sa
géométrie de plans dans un buffer déclaré autrement — aucune erreur, pixels
faux. Second défaut : la conversion de sortie teste `usesDirectBGRA`, une
variable de la branche d'**entrée**.

**Fichier :** `ClipFlow/Interpolation/VideoToolboxFrameInterpolationEngine.swift`

Ajouter la propriété :

```swift
    /// Format réel du pool de destination — négocié séparément du format
    /// d'entrée : VT peut parfaitement entrer en RGB et sortir en YCbCr.
    private var vtDestinationFormat: OSType = kCVPixelFormatType_32BGRA
```

Remplacer la création du pool de destination (lignes 118-121) :

```swift
        // AVANT
        vtDestinationPool = try Self.makePool(
            width: width, height: height, format: vtFormat,
            base: configuration.destinationPixelBufferAttributes as? [String: Any]
        )

        // APRÈS
        let destinationFormats = VideoToolboxFormatProbe.pixelFormats(
            in: configuration.destinationPixelBufferAttributes
        )
        guard !destinationFormats.isEmpty else {
            processor.endSession()
            throw InterpolationError.processingFailed(
                "Aucun format de pixel destination annoncé. Attributs bruts : "
                + String(describing: configuration.destinationPixelBufferAttributes)
            )
        }
        // Préférence au format d'entrée quand il est aussi proposé en sortie
        // (une conversion de moins), jamais imposition.
        vtDestinationFormat = destinationFormats.contains(vtFormat) ? vtFormat : destinationFormats[0]
        vtDestinationPool = try Self.makePool(
            width: width, height: height, format: vtDestinationFormat,
            base: configuration.destinationPixelBufferAttributes as? [String: Any]
        )
```

La session de transfert et le pool BGRA de sortie doivent exister dès que
**l'une ou l'autre** frontière convertit. Remplacer leur création conditionnelle
par un bloc unique, placé après la négociation des deux formats :

```swift
        let needsInputConversion = !usesDirectBGRA
        let needsOutputConversion = vtDestinationFormat != kCVPixelFormatType_32BGRA
        if needsInputConversion || needsOutputConversion {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session
            )
            guard status == noErr, let session else {
                processor.endSession()
                throw InterpolationError.processingFailed("VTPixelTransferSession indisponible (\(status)).")
            }
            transferSession = session
        }
        if needsInputConversion {
            vtInputPool = try Self.makePool(
                width: width, height: height, format: vtFormat,
                base: configuration.sourcePixelBufferAttributes as? [String: Any]
            )
        }
        if needsOutputConversion {
            bgraOutputPool = try Self.makePool(
                width: width, height: height,
                format: kCVPixelFormatType_32BGRA, base: nil
            )
        }
```

Et la frontière de sortie (lignes 180-184) :

```swift
        // AVANT
        if usesDirectBGRA {
            return destinationFrames.map { $0.buffer }
        }

        // APRÈS — la sortie dépend du format du pool de DESTINATION, pas de la
        // branche d'entrée.
        if vtDestinationFormat == kCVPixelFormatType_32BGRA {
            return destinationFrames.map { $0.buffer }
        }
```

Ajouter enfin `vtDestinationFormat = kCVPixelFormatType_32BGRA` dans
`endSession()`, avec les autres remises à zéro.

---

### Correctif 4 — mode de soumission et cycle de vie de la session

**Problème.** `submissionMode: .sequential` déclare que chaque soumission
prolonge la précédente, donc autorise le processeur à réutiliser son état
temporel. Or la session est réutilisée :

- **d'un clip à l'autre** (`takeCachedEngine` / `storeCachedEngine`) — le premier
  couple du clip N+1 hérite de l'état du clip N, contenu totalement différent ;
- **à travers les 3 passes de réparation** — chaque passe repart de l'image 0
  alors que VT croit le temps continu ;
- de part et d'autre des entrées `.copy` et de la duplication de fin de plan.

Trois discontinuités présentées comme des continuations.

**Correctif principal, indépendant de toute sémantique d'API à vérifier :**
supprimer la réutilisation de session entre clips et entre passes.

**Fichier :** `ClipFlow/Pipeline/VideoRenderPipeline.swift`

```swift
        // AVANT (ligne 249)
            if let reused = takeCachedEngine(width: encodeWidth, height: encodeHeight) {
                return Task { .success(reused) }
            }

        // APRÈS — supprimer ces 3 lignes.
        // Le cache de session faisait hériter au premier couple d'un clip
        // l'état temporel du clip PRÉCÉDENT, en mode de soumission séquentiel.
        // Le gain (quelques centaines de ms au démarrage) ne vaut pas une
        // image fausse en tête de clip.
```

et, ligne 352 :

```swift
        // AVANT
        defer {
            if engineIsReusable && renderCompleted {
                storeCachedEngine(engine, width: encodeWidth, height: encodeHeight)
            } else {
                engine.endSession()
            }
        }

        // APRÈS — une session par passe de rendu, toujours fermée.
        defer { engine.endSession() }
```

`takeCachedEngine`, `storeCachedEngine`, `cachedEngineLock` et `engineIsReusable`
deviennent morts : les supprimer. `drainCachedEngine()` a des appelants dans
`RenderQueue` — les retirer aussi.

**Correctif secondaire, à vérifier dans Xcode avant application.** Si
`VTFrameProcessorSubmissionMode` propose bien un mode « soumission non continue »
(`.random` ou équivalent), l'utiliser : chaque paire est ici indépendante
(`usePrecomputedFlow: false`, `opticalFlow: nil`), rien ne prolonge rien.

```swift
        // VideoToolboxFrameInterpolationEngine.swift ligne 168
        // AVANT : submissionMode: .sequential,
        // APRÈS : submissionMode: .random,
```

> **À NE PAS DEVINER.** Si les cas de cet enum ne sont pas ceux-là, ou si leur
> documentation ne dit pas explicitement qu'un mode non séquentiel invalide
> l'état mis en cache, arrête-toi et rapporte les cas réels. Un mode de
> soumission mal choisi est exactement le genre d'erreur silencieuse qui a
> produit ce document.

---

### Correctif 5 — ne jamais toucher un buffer que VideoToolbox tient

**Problème.** Dans la boucle de production :

```swift
async let producedNow = try await engine.interpolate(previous: prev, next: next, ...)  // groupe k+1
try await flushPending()   // encode le groupe k — EN MÊME TEMPS
```

`group_k.next` **est** `group_{k+1}.prev`. Or `flushPending` :

1. appelle `tileLuma(of: group.prev)` et `tileLuma(of: group.next)`, qui font
   `CVPixelBufferLockBaseAddress` sur des buffers en cours de lecture par le GPU ;
2. quand le failsafe substitue, pose `outputBuffer = group.prev` ou `group.next`,
   puis appelle `propagateColorAttachments(from:to:)` — c'est-à-dire
   `CVBufferSetAttachments`, une **écriture**, dans une `sourceFrame` vivante.

Le commentaire de `alwaysCopiesSampleData = true` (lignes 372-381) montre que ce
mode de défaillance était compris côté décodeur. Le failsafe le réintroduit côté
VideoToolbox.

**Fichier :** `ClipFlow/Pipeline/VideoRenderPipeline.swift`

**5a — calculer les signatures source AVANT la soumission suivante.** Les porter
dans la structure, remplies au moment où elle est construite (VT est alors au
repos, on vient d'`await` son résultat) :

```swift
        // AVANT
        struct PendingInterpolation {
            let startIndex: Int
            let prev: CVPixelBuffer
            let next: CVPixelBuffer
            let phases: [Float]
            let produced: [CVPixelBuffer]
        }

        // APRÈS
        struct PendingInterpolation {
            let startIndex: Int
            let prev: CVPixelBuffer
            let next: CVPixelBuffer
            /// Signatures des DEUX sources, calculées à la construction —
            /// c'est-à-dire pendant que le moteur est au repos. Les calculer
            /// dans flushPending verrouillait l'adresse de base de buffers que
            /// VideoToolbox lisait déjà comme sources du groupe SUIVANT
            /// (group_k.next === group_{k+1}.prev).
            let tilesPrev: [Double]?
            let tilesNext: [Double]?
            let phases: [Float]
            let produced: [CVPixelBuffer]
        }
```

```swift
        // Construction (ligne 690)
        // AVANT
        pendingGroup = PendingInterpolation(
            startIndex: entryIndex,
            prev: prev, next: next, phases: groupPhases, produced: try await producedNow
        )

        // APRÈS
        let produced = try await producedNow   // moteur au repos à partir d'ici
        pendingGroup = PendingInterpolation(
            startIndex: entryIndex,
            prev: prev, next: next,
            tilesPrev: Self.tileLuma(of: prev), tilesNext: Self.tileLuma(of: next),
            phases: groupPhases, produced: produced
        )
```

```swift
        // flushPending (lignes 581-582)
        // AVANT
        let tilesPrev = Self.tileLuma(of: group.prev)
        let tilesNext = Self.tileLuma(of: group.next)

        // APRÈS
        let tilesPrev = group.tilesPrev
        let tilesNext = group.tilesNext
```

**5b — ne propager les attachements que sur les buffers produits par le moteur.**
Une image substituée par le failsafe **est** une image source : elle porte déjà
ses propres attachements, et les écraser mute un buffer en vol.

```swift
        // flushPending (ligne 619)
        // AVANT
        Self.propagateColorAttachments(from: group.prev, to: outputBuffer)

        // APRÈS
        // Uniquement sur un buffer sorti du pool du moteur. Une image
        // substituée est une image SOURCE : elle a ses attachements, et
        // CVBufferSetAttachments écrirait dans une sourceFrame que
        // VideoToolbox lit encore pour le groupe suivant.
        if outputBuffer === buffer {
            Self.tagInterpolatedBuffer(outputBuffer, from: group.prev, untagged: &untaggedInterpolatedFrames)
        }
```

(`tagInterpolatedBuffer` est défini au correctif 6.)

---

### Correctif 6 — étiquetage colorimétrique explicite, jamais silencieux

**Problème.** `CVBufferCopyAttachments` renvoyant `nil` laisse l'image
interpolée **sans étiquette**, pendant que les copies gardent celles de la
source. Le writer est forcé en 709 : il *convertit* ce qui est étiqueté, pas ce
qui ne l'est pas. Une image sur deux teintée — le flash bleu, toujours non gardé.

**Fichier :** `ClipFlow/Pipeline/VideoRenderPipeline.swift`

```swift
    /// Étiquette une image interpolée : attachements de la source si
    /// disponibles, sinon BT.709 EXPLICITE.
    ///
    /// L'ancienne version était un `if let` sans branche `else` : quand la
    /// source ne portait aucun attachement propageable, l'image interpolée
    /// partait nue vers l'encodeur — qui la traitait en 709 sans conversion,
    /// entre des copies étiquetées et converties. Une image sur deux teintée.
    /// Un défaut d'étiquetage doit être COMPTÉ, jamais silencieux.
    static func tagInterpolatedBuffer(_ destination: CVPixelBuffer,
                                      from source: CVPixelBuffer,
                                      untagged: inout Int) {
        guard source !== destination else { return }
        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
            return
        }
        untagged += 1
        CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
```

Déclarer `var untaggedInterpolatedFrames = 0` près des autres compteurs de
`renderPass`, l'ajouter à `RenderResult`, et le remonter au bilan de
`RenderQueue`. Un compteur non nul est un défaut à corriger, pas une statistique.

**Point d'honnêteté connexe, à arbitrer.** Le commentaire ligne 236 affirme que
le décodeur « tone-mappe le HDR vers du RGB écran ». C'est faux :
`AVAssetReaderTrackOutput` avec un simple `kCVPixelBufferPixelFormatTypeKey:
32BGRA` fait une conversion matricielle, pas de tone mapping. Du HLG reste
encodé HLG dans les octets BGRA, puis est étiqueté 709 par
`AVVideoColorPropertiesKey`. Deux issues honnêtes :

1. refuser HLG comme PQ et Apple Log, en attendant un vrai tone mapping —
   une ligne, `case "pq", "dolbyVision", "appleLog", "hlg":` ;
2. faire un vrai tone mapping (`AVVideoComposition` avec
   `colorPrimaries`/`colorTransferFunction` cibles, ou `VTPixelTransferSession`
   avec les propriétés de destination renseignées).

Corriger au minimum le commentaire, qui décrit un traitement qui n'existe pas.

---

### Correctif 7 — PTS de destination rationnels et monotones

**Problème.** Seul endroit flottant d'une chaîne sinon rationnelle :

```swift
let offsetSeconds = interval.seconds * Double(phase)
let pts = CMTimeAdd(previousPTS, CMTime(seconds: offsetSeconds, preferredTimescale: interval.timescale))
```

`interval.timescale` est le timescale **source**. À 600 (iPhone), les phases
0,25/0,50/0,75 d'un intervalle 20/600 donnent 5/10/15 — distinctes. À un
timescale ≤ 100 (réencodages Photos), elles s'arrondissent sur la même valeur :
**PTS de destination dupliqués ou non monotones**, en contradiction avec le mode
de soumission.

**Fichier :** `ClipFlow/Interpolation/VideoToolboxFrameInterpolationEngine.swift`

```swift
        // AVANT (lignes 148-161)
        let interval = CMTimeSubtract(nextPTS, previousPTS)
        for phase in phases {
            guard let buffer = buffer(from: vtDestinationPool) else {
                throw InterpolationError.bufferAllocationFailed
            }
            let offsetSeconds = interval.seconds * Double(phase)
            let pts = CMTimeAdd(previousPTS, CMTime(seconds: offsetSeconds, preferredTimescale: interval.timescale))
            ...
        }

        // APRÈS
        // Base de temps FIXE et fine (1/90000) : arrondir au timescale source
        // confondait deux phases dès que celui-ci était grossier (≤ 100 sur les
        // réencodages Photos), produisant des PTS de destination identiques ou
        // décroissants — sans erreur, avec des images fausses.
        let ptsTimescale: CMTimeScale = 90_000
        let base = CMTimeConvertScale(previousPTS, timescale: ptsTimescale,
                                      method: .roundHalfAwayFromZero)
        let span = CMTimeConvertScale(CMTimeSubtract(nextPTS, previousPTS),
                                      timescale: ptsTimescale, method: .roundHalfAwayFromZero)
        let interval = CMTimeSubtract(nextPTS, previousPTS)
        var lastPTS: CMTime = base
        for phase in phases {
            guard let buffer = buffer(from: vtDestinationPool) else {
                throw InterpolationError.bufferAllocationFailed
            }
            let pts = CMTimeAdd(base, CMTimeMultiplyByFloat64(span, multiplier: Float64(phase)))
            // Une phase strictement croissante DOIT donner un PTS strictement
            // croissant. Sinon la soumission est dégénérée : échec net plutôt
            // qu'un groupe d'images fausses.
            guard CMTimeCompare(pts, lastPTS) > 0 else {
                throw InterpolationError.processingFailed(
                    "PTS de destination non monotone (phase \(phase), intervalle "
                    + "\(interval.seconds) s, timescale source \(interval.timescale))."
                )
            }
            lastPTS = pts
            ...
        }
```

Assainir aussi la source du flottant, dans `FramePlanner.plan`
(`ClipFlow/Core/TimeMath.swift:199`) : la phase y est calculée par
`Float(numerator.seconds / denominator.seconds)` alors que `numerator` et
`denominator` sont deux `CMTime` exacts. Passer la phase en rationnel
(`(value, timescale)`) dans `FramePlanEntry.interpolate` supprimerait le dernier
flottant de la chaîne temporelle. Refonte plus large — à faire seulement si
l'étape 4 montre des artefacts corrélés aux phases.

---

## §D — ÉTAPE 1 : refonte du détecteur (à faire AVANT les correctifs)

Sans instrument, aucun correctif n'est vérifiable. Voici pourquoi les détecteurs
actuels ne peuvent rien mesurer :

| | grille | déclenchement | pixels lus en 4K |
|---|---|---|---|
| failsafe en ligne | 4×4, tuile = 1/16 image | marge 26 + seuil 12 = **38 niveaux sur une MOYENNE de tuile** | `step = w/64` → 64×65 ≈ 4 160 / 8 300 000 = **0,05 %** |
| détecteur final | 8×8, tuile = 1/64 | 24 + 16 = **40 niveaux** | `w/(8·16)` → ~17 000 = **0,2 %** |

Un flash blanc plein pot couvrant 5 % de l'image déplace une moyenne de tuile de
~13 niveaux. Seuil : 38. Il ne se déclenche jamais. Le compteur de doublons
(`abs(diff) < 0.02` sur ces mêmes 0,05 %) est du même acabit.

**Trois changements, dans cet ordre d'importance :**

**D1 — mesurer les extrêmes, pas seulement la moyenne.** C'est le point
principal : une moyenne de tuile ne peut pas voir un artefact localisé, quelle
que soit la finesse de la grille. `FrameSignature` doit porter, par tuile et par
composante, le **max** et le **min** en plus de la moyenne, et `anomalyScore`
doit tester le max du candidat contre l'enveloppe des max des références (et
symétriquement pour le min).

```swift
    struct FrameSignature: Sendable {
        var luma: [Double]
        var lumaMax: [Double]     // ← un flash de 8×8 pixels déplace le MAX de
        var lumaMin: [Double]     //   la tuile, jamais sa moyenne
        var cb: [Double]
        var cbMax: [Double]
        var cbMin: [Double]
        var cr: [Double]
        var crMax: [Double]
        var crMin: [Double]
    }
```

**D2 — échantillonner sérieusement.** Passer de `max(w/(grid*16), 1)` à
`max(w/1024, 1)` en x et y : au moins 1024×1024 échantillons par plan, soit
~13 % des pixels en 4K au lieu de 0,2 %. Coût : quelques centaines de ms par
clip sur une passe qui n'est pas interactive.

**D3 — resserrer grille et seuils.** `outputGrid = 16`,
`outputEnvelopeMargin = 8`, `outputAnomalyThreshold = 6` **sur les extrêmes**.
Ces valeurs sont un point de départ : elles doivent être **calibrées** en
mesurant `maxOutputAnomaly` sur des clips connus sains (flux optique éteint) et
en plaçant le seuil au-dessus du bruit mesuré, pas au jugé.

**Test de recevabilité du détecteur, obligatoire.** Reprendre le pattern
`singleFrameFlash` de `PipelineHarnessTests/RealEngineArtifactTests.swift` et en
faire une famille : flash couvrant 100 %, 25 %, 5 %, 1 % puis 0,1 % de l'image.
Le détecteur doit signaler les cinq. Tant qu'il n'y arrive pas, il ne mesure rien
et aucun résultat de l'étape 4 n'a de valeur.

---

## §F — ÉTAPE 3 : repli total, à la place de la réparation partielle

La réparation partielle a échoué trois fois, et pour une raison qui ne se corrige
pas : **réparer une image inventée par une autre image inventée ne garantit
rien**. S'y ajoute un défaut non identifié jusqu'ici : `renderPass` est relancée
à travers un chemin matériel non déterministe, donc la passe 2 produit un jeu
d'artefacts **différent**, à d'autres indices. `detectedEver.subtracting(remaining)`
compte alors « réparée » une image qui a seulement déménagé — ce qui explique les
mesures « 0 réparée alors que 2 forcées » sans avoir besoin de la théorie du
raisonnement circulaire.

**Fichier :** `ClipFlow/Pipeline/VideoRenderPipeline.swift` — remplacer
intégralement `render` (lignes 142-190) :

```swift
    /// Rendu avec CONTRÔLE ET REPLI TOTAL.
    ///
    /// Le flux optique fabrique des images ; une fabrication peut être fausse,
    /// et son taux d'échec ne sera jamais nul. La seule garantie tenable n'est
    /// donc pas « aucun artefact » mais « aucun artefact LIVRÉ » : au moindre
    /// défaut mesuré sur le fichier produit, le clip ENTIER est re-rendu sans
    /// flux optique. Pire cas : un clip saccadé. Jamais un clip faux.
    ///
    /// Pas de réparation partielle. Elle a échoué trois fois, et le re-rendu
    /// d'une passe sur un chemin matériel non déterministe déplace les
    /// artefacts au lieu de les supprimer — ce que l'ancien comptage
    /// interprétait à tort comme une réparation.
    static func render(job: RenderJob,
                       onProgress: @escaping @Sendable (Double) -> Void) async throws -> RenderResult {
        var result = try await renderPass(job: job, forcedCopyOutputIndices: [], onProgress: onProgress)
        guard !result.artifactFrames.isEmpty, !job.forceFastEngine else { return result }

        os_log("Repli total : %d image(s) aberrante(s) mesurée(s) sur le fichier produit",
               log: signpostLog, type: .error, result.artifactFrames.count)
        let rejected = result.artifactFrames.count
        var safeJob = job
        safeJob.forceFastEngine = true
        result = try await renderPass(job: safeJob, forcedCopyOutputIndices: [], onProgress: onProgress)
        result.opticalFlowRejected = true
        result.rejectedArtifactFrames = rejected
        // Une anomalie SUBSISTANT sans flux optique vient de la source
        // (changement d'exposition filmé) : signalée, jamais « corrigée ».
        result.sourceAnomalyFrames = result.artifactFrames.count
        return result
    }
```

Ajouter à `RenderResult` :

```swift
    /// Le rendu au flux optique a été REJETÉ et refait sans interpolation.
    var opticalFlowRejected: Bool = false
    /// Nombre d'images aberrantes qui ont motivé le rejet.
    var rejectedArtifactFrames: Int = 0
```

`forcedCopyOutputIndices` n'a plus d'appelant non vide : le paramètre, la
substitution dans `appendOutput`, `lastGoodOutputBuffer`, `correctedFrames`,
`repairedFrames`, `unrepairedAnomalyFrames` et `unrepairableCopyFrames`
deviennent morts. Les supprimer plutôt que de les laisser mentir.

`RenderQueue` doit afficher le rejet à l'utilisateur : « flux optique écarté sur
ce clip (N images aberrantes) — rendu sans interpolation ». Un rejet visible est
la donnée qui permettra de décider si le flux optique mérite d'être rallumé.

---

## §G — ÉTAPE 4 : protocole de validation

Sur **iPhone physique**, jamais en simulateur ni en CI.

1. Détecteur validé par le test de recevabilité §D (flash à 100 / 25 / 5 / 1 /
   0,1 % détecté).
2. Calibrage du bruit : 10 clips rendus **flux optique éteint**. Relever
   `maxOutputAnomaly`. C'est le plancher de bruit — le seuil doit être au-dessus.
3. Mesure : 30 clips de rushes POV réels (la vraie matière : asphalte, vitesse,
   flou de bougé, reflets) rendus **flux optique allumé**, plus les 5 patterns
   adverses du banc d'essai.
4. Rapporter le **taux d'artefact par image fabriquée** :
   `images aberrantes / images interpolées`, et non par clip.

Repère d'interprétation — à 30 i/s source, 0,5× vers 60 i/s, **58 des 78 images
d'un clip de 1,3 s sont fabriquées** :

| taux par image fabriquée | artefacts visibles |
|---|---|
| 1 % | ~1 tous les 2 clips |
| 0,1 % | ~1 tous les 17 clips |
| 0,02 % | ~1 tous les 100 clips |

`VTFrameProcessor` est une boîte noire réglée pour de la conversion 30→60 de
contenu ordinaire ; aucun levier n'existe sur son intérieur. Si la mesure
plafonne autour de 1 %, la conclusion honnête est que le flux optique reste
éteint par défaut, avec §F comme filet pour ceux qui l'allument.

**Et le correctif qui bat tous les autres reste hors code :** filmer à 60 i/s
met le nombre d'images fabriquées à **zéro** (toutes les entrées du plan
deviennent des `.copy`), avec une fluidité parfaite. L'app connaît déjà la
cadence de chaque rush et ne l'affiche nulle part. L'exposer dans la grille de
rushes, avec un avertissement sur les rushes à 30 i/s, coûte quelques lignes et
supprime le problème à la racine.

---

## Récapitulatif — ordre et dépendances

| # | Action | Dépend de | Vérifiable sans appareil |
|---|---|---|---|
| 0 | Instrumentation des attributs VT | — | non |
| 1 | Refonte du détecteur (§D) | — | oui (test de recevabilité) |
| 2 | Correctif 2 — plus de repli BGRA | 0 | oui (compile + erreur nette) |
| 3 | Correctif 1 — attributs du moteur au décodeur | 0, 2 | non |
| 4 | Correctif 3 — pool destination | 0, 2 | non |
| 5 | Correctif 4 — session par passe | — | oui |
| 6 | Correctif 5 — pas de mutation en vol | — | oui |
| 7 | Correctif 6 — étiquetage explicite | — | oui |
| 8 | Correctif 7 — PTS monotones | — | oui (test unitaire timescale 30) |
| 9 | Repli total (§F) | 1 | oui |
| 10 | Mesure (§G) | tout | non |

Les étapes 5 à 9 ne dépendent pas de l'étape 0 et peuvent avancer pendant que
les logs sont récoltés.
