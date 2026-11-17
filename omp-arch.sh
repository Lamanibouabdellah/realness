#!/usr/bin/env bash
set -euo pipefail

export PI_CODING_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.omp"
exec omp "$@"
