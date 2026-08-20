#!/usr/bin/env bash
#
# Recopie les fichiers sources du pipeline d'export de l'app iOS vers le
# paquet Swift de test (banc d'essai macOS du vrai moteur VideoToolbox).
#
# L'app reste la SOURCE DE VÉRITÉ : rien n'est dupliqué dans le dépôt, la
# copie est faite au moment de tester. Si un fichier listé disparaît (renommé,
# déplacé), le script échoue bruyamment — jamais un banc d'essai qui teste une
# version périmée du pipeline en silence.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/PipelineHarness/Sources/ClipFlowPipeline"

SOURCES=(
  "ClipFlow/Core/SelectionEngine.swift"
  "ClipFlow/Montage/BeatMap.swift"
  "ClipFlow/Montage/OnsetExtractor.swift"
  "ClipFlow/Montage/TempoEstimator.swift"
  "ClipFlow/Montage/BeatAnalyzer.swift"
  "ClipFlow/Montage/MontagePlanner.swift"
  "ClipFlow/Core/TimeMath.swift"
  "ClipFlow/Interpolation/FrameInterpolationEngine.swift"
  "ClipFlow/Interpolation/PassthroughRetimeEngine.swift"
  "ClipFlow/Interpolation/VideoToolboxFrameInterpolationEngine.swift"
  "ClipFlow/Interpolation/VideoToolboxFormatProbe.swift"
  "ClipFlow/Pipeline/VideoRenderPipeline.swift"
  "ClipFlow/Services/StorageManager.swift"
)

rm -rf "$DEST"
mkdir -p "$DEST"

for relative in "${SOURCES[@]}"; do
  if [ ! -f "$ROOT/$relative" ]; then
    echo "ERREUR : source introuvable — $relative" >&2
    echo "Le banc d'essai doit être mis à jour (PipelineHarness/sync-sources.sh)." >&2
    exit 1
  fi
  cp "$ROOT/$relative" "$DEST/$(basename "$relative")"
done

# Garde-fou : tout nouveau fichier du pipeline non listé ici passerait sous le
# radar du banc d'essai. On le signale.
for candidate in "$ROOT"/ClipFlow/Pipeline/*.swift "$ROOT"/ClipFlow/Interpolation/*.swift; do
  name="$(basename "$candidate")"
  if [ ! -f "$DEST/$name" ]; then
    echo "ERREUR : $name n'est pas testé par le banc d'essai." >&2
    echo "Ajoutez-le à SOURCES dans PipelineHarness/sync-sources.sh." >&2
    exit 1
  fi
done

echo "Sources synchronisées vers $DEST :"
ls -1 "$DEST"
