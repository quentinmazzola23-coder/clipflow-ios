#!/usr/bin/env bash
#
# Exécute une commande avec une limite de temps ET une sortie en direct.
#
# macOS n'a pas `timeout` (outil GNU), et rediriger vers `tail` masque toute
# progression jusqu'à la fin — d'où un job CI qui a consommé 20 minutes sans
# produire une seule ligne exploitable. Ici : sortie en direct, et si le délai
# est dépassé, le processus est tué avec un message net (plus une trace des
# piles, seule façon de savoir OÙ ça bloque sans machine locale).
#
# Usage : run-with-watchdog.sh <secondes> <commande...>
#
set -uo pipefail

LIMIT="$1"
shift

"$@" &
PID=$!

ELAPSED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$ELAPSED" -ge "$LIMIT" ]; then
    echo ""
    echo "=== DÉLAI DÉPASSÉ (${LIMIT}s) : $* ==="
    echo "=== Piles d'appels des processus de test (diagnostic du blocage) ==="
    for target in $(pgrep -f 'swiftpm-testing|ClipFlowPipelinePackageTests|xctest' 2>/dev/null); do
      echo "--- pid $target"
      sample "$target" 2 -mayDie 2>/dev/null | head -120 || true
    done
    kill -9 "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    exit 124
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

wait "$PID"
