#!/usr/bin/env bash
# Lance la veille immobilière. Rends ce fichier exécutable : chmod +x bin/lancer-agent.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -d node_modules ]; then
  echo "Première utilisation : installation des dépendances…"
  npm install
  npx playwright install chromium
fi
exec node src/cli.js "${1:-run}" "${@:2}"
