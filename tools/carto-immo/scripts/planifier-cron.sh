#!/usr/bin/env bash
# Programme la veille immobilière tous les matins (macOS / Linux).
#   ./scripts/planifier-cron.sh          installe à 7 h 30
#   ./scripts/planifier-cron.sh 06:45    installe à l'heure indiquée
#   ./scripts/planifier-cron.sh --supprimer
set -euo pipefail

racine="$(cd "$(dirname "$0")/.." && pwd)"
marqueur="# carto-immo"

if [ "${1:-}" = "--supprimer" ]; then
  crontab -l 2>/dev/null | grep -v "$marqueur" | crontab -
  echo "Tâche supprimée."
  exit 0
fi

# La voie `annonces` ne demande pas de session ouverte : c'est celle qu'on
# programme par défaut. `--commande run` bascule sur la voie leboncoin.
commande="src/cli.js annonces"
if [ "${1:-}" = "--commande" ]; then
  [ "${2:-}" = "run" ] && commande="src/cli.js run"
  shift 2
fi

heure="${1:-07:30}"
h="${heure%%:*}"; m="${heure##*:}"
ligne="$((10#$m)) $((10#$h)) * * * cd \"$racine\" && $(command -v node) $commande --quiet >> data/cron.log 2>&1 $marqueur"

{ crontab -l 2>/dev/null | grep -v "$marqueur"; echo "$ligne"; } | crontab -
echo "Tâche programmée tous les jours à $heure."
echo "Vérifier : crontab -l"
