#!/usr/bin/env bash
# Lance une session omp entièrement confinée à ce dépôt.
# Aucune configuration externe n'est requise :
#   - agent dir   -> ./.omp       (config.yml, models.yml, extensions/, sessions/)
#   - credentials -> ./.omp/.env  (OPENROUTER_API_KEY, ALTO_STUDIO_TOKEN)
# Le binaire omp reste le seul prérequis système (https://oh-my-pi).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PI_CODING_AGENT_DIR="$ROOT/.omp"
ENV_FILE="$ROOT/.omp/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "realness: .omp/.env manquant — copie .omp/.env.example vers .omp/.env et renseigne les jetons." >&2
else
  # Normalise les fins de ligne (édition Windows) uniquement si un CR est présent ;
  # mktemp crée le fichier en 0600 et il reste dans le motif .omp/.env.tmp* ignoré.
  if grep -q $'\r' "$ENV_FILE"; then
    tmp="$(mktemp "$ROOT/.omp/.env.tmp.XXXXXX")"
    tr -d '\r' < "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
  fi
  set -a && source "$ENV_FILE" && set +a
fi

for var in OPENROUTER_API_KEY ALTO_STUDIO_TOKEN; do
  if [ -z "${!var:-}" ]; then
    echo "realness: $var vide/absent — la voie correspondante sera indisponible." >&2
  fi
done

cd "$ROOT"
exec omp "$@"
