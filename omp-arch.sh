#!/usr/bin/env bash
# Lance une session omp entièrement confinée à ce dépôt.
# Aucune configuration externe n'est requise :
#   - agent dir  -> ./.omp            (config.yml, models.yml, extensions/, sessions/)
#   - credential -> ./.omp/.env       (OPENROUTER_API_KEY)
# Le binaire omp reste le seul prérequis système (https://oh-my-pi).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PI_CODING_AGENT_DIR="$ROOT/.omp"

if [ ! -f "$ROOT/.omp/.env" ]; then
  echo "realness: .omp/.env manquant — copie .omp/.env.example vers .omp/.env et renseigne OPENROUTER_API_KEY." >&2
fi

sed -i '' $'s/\r$//' $ROOT/.omp/.env
set -a && source $ROOT/.omp/.env && set +a

cd "$ROOT"
exec omp "$@"