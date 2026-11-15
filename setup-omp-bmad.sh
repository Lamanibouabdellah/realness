#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# OMP + BMAD v6.12 + OpenRouter Free
# macOS project installer
# ============================================================

VERSION="1.0.0"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

info() { printf "${BLUE}[INFO]${RESET} %s\n" "$1"; }
success() { printf "${GREEN}[OK]${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}[WARN]${RESET} %s\n" "$1"; }
die() { printf "${RED}[ERROR]${RESET} %s\n" "$1" >&2; exit 1; }

BACKUP_DIR=".omp-backups/$(date +%Y%m%d-%H%M%S)"

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        mkdir -p "$BACKUP_DIR/$(dirname "$file")"
        cp -p "$file" "$BACKUP_DIR/$file"
        info "Backup: $BACKUP_DIR/$file"
    fi
}

echo ""
echo "=================================================="
echo "  OH MY PI + BMAD INSTALLER v${VERSION}"
echo "  OpenRouter FREE models only"
echo "=================================================="
echo ""

# ------------------------------------------------------------
# 1. macOS validation
# ------------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "Ce script est réservé à macOS."

info "Projet: $PROJECT_ROOT"

# ------------------------------------------------------------
# 2. Dependencies
# ------------------------------------------------------------

for cmd in git python3 curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd est manquant."
done

PY_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' \
    || die "Python 3.10 minimum requis."

if ! command -v node >/dev/null 2>&1; then
    die "Node.js absent. Installe-le avec: brew install node"
fi

node -e '
const [major, minor] = process.versions.node.split(".").map(Number);
if (major < 20 || (major === 20 && minor < 12)) process.exit(1);
' || die "Node.js 20.12 minimum requis."

command -v uv >/dev/null 2>&1 || die "uv absent. Installe-le avec: brew install uv"

success "Dépendances validées."

# ------------------------------------------------------------
# 3. Verify existing BMAD
# ------------------------------------------------------------

[[ -d "_bmad" ]] || die \
    "Dossier _bmad absent. Installe BMAD v6.12 avant de lancer ce script."

success "Installation BMAD détectée."

if [[ ! -d "_bmad-output" ]]; then
    warn "_bmad-output absent. Il sera créé uniquement s'il est nécessaire."
fi

# ------------------------------------------------------------
# 4. Install Oh My Pi if missing
# ------------------------------------------------------------

if ! command -v omp >/dev/null 2>&1; then

    warn "Oh My Pi absent. Installation en cours."

    if command -v brew >/dev/null 2>&1; then
        brew tap can1357/tap
        brew install omp
    else
        curl -fsSL https://omp.sh/install | sh
    fi

    export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

fi

command -v omp >/dev/null 2>&1 || die \
    "Installation OMP échouée. Vérifie ton PATH."

omp --version

success "Oh My Pi disponible."

# ------------------------------------------------------------
# 5. OpenRouter API key
# ------------------------------------------------------------

echo ""
echo "OpenRouter API key"
echo "https://openrouter.ai/keys"
echo ""

if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    API_KEY="$OPENROUTER_API_KEY"
    info "Utilisation de la clé présente dans l'environnement."
else
    read -rsp "Entre ta clé OpenRouter: " API_KEY
    echo ""
fi

[[ "$API_KEY" == sk-or-* ]] || die \
    "Format de clé OpenRouter invalide."

export OPENROUTER_API_KEY="$API_KEY"

# ------------------------------------------------------------
# 6. Validate OpenRouter account and discover free models
# ------------------------------------------------------------

info "Interrogation du catalogue OpenRouter..."

curl -fsS \
    --connect-timeout 15 \
    --max-time 45 \
    -H "Authorization: Bearer $API_KEY" \
    https://openrouter.ai/api/v1/key \
    -o /dev/null || die \
    "Clé OpenRouter invalide ou API inaccessible."

mkdir -p .omp

# Python uses only the standard library.
# Models are selected dynamically from the live catalog.
python3 - <<'PY'
import json
import os
import sys
import json
import ssl
import urllib.request
import certifi

SSL_CONTEXT = ssl.create_default_context(
    cafile=certifi.where()
)

from decimal import Decimal
from pathlib import Path

candidates = {
    "code": [
        "cohere/north-mini-code:free",
        "particle-ai/particle-1:free",
        "recursive/flint-v1.0:free",
    ],
    "reasoning": [
        "nvidia/nemotron-3-ultra-550b-a55b:free",
        "thinking-machines/inkling-2-small:free",
        "baidu/ernie-5.5-flash-preview:free",
    ],
    "fast": [
        "nvidia/nemotron-3.5-lightning:free",
        "liquid/lfm3-1.7b:free",
        "particle-ai/particle-1:free",
    ],
    "vision": [
        "nvidia/nemotron-3.5-super-vl:free",
    ],
}

key = os.environ["OPENROUTER_API_KEY"]

request = urllib.request.Request(
    "https://openrouter.ai/api/v1/models",
    headers={
        "Authorization": f"Bearer {key}",
        "HTTP-Referer": "https://openrouter.ai",
        "X-Title": "Oh My Pi BMAD Installer",
    },
)

try:
    with urllib.request.urlopen(request, timeout=45, context=SSL_CONTEXT) as response:
        catalog = json.load(response)["data"]
except Exception as exc:
    sys.exit(f"Impossible de récupérer le catalogue: {exc}")

by_id = {model["id"]: model for model in catalog}

def is_free(model):
    try:
        pricing = model["pricing"]
        return (
            Decimal(str(pricing["prompt"])) == 0
            and Decimal(str(pricing["completion"])) == 0
        )
    except Exception:
        return False

def pick(role):
    for model_id in candidates[role]:
        model = by_id.get(model_id)

        if model and is_free(model) and model_id.endswith(":free"):
            if role == "vision":
                modalities = model.get("architecture", {}).get(
                    "input_modalities", []
                )
                if "image" not in modalities:
                    continue

            return model_id

    sys.exit(
        f"Aucun modèle gratuit compatible disponible pour: {role}"
    )

selected = {
    role: pick(role)
    for role in candidates
}

def fallbacks(role):
    return [
        model_id
        for model_id in candidates[role]
        if model_id != selected[role]
        and model_id in by_id
        and is_free(by_id[model_id])
        and model_id.endswith(":free")
    ]

code = selected["code"]
reasoning = selected["reasoning"]
fast = selected["fast"]
vision = selected["vision"]

# Only explicitly selected, verified free models are enabled.
all_models = []
for role in candidates:
    for model_id in [selected[role]] + fallbacks(role):
        if model_id not in all_models:
            all_models.append(model_id)

def selector(model_id):
    return "openrouter/" + model_id

def yaml_list(items, indent=6):
    if not items:
        return " " * indent + "[]"
    return "\n".join(
        " " * indent + "- " + selector(item)
        for item in items
    )

config = f"""# Generated by setup-omp-bmad.sh
# All configured chat models are verified OpenRouter :free models.

modelRoleStorage: project

modelProviderOrder:
  - openrouter

modelRoles:
  default: {selector(code)}
  plan: {selector(reasoning)}
  slow: {selector(reasoning)}
  smol: {selector(fast)}
  commit: {selector(fast)}
  task: {selector(code)}
  advisor: {selector(reasoning)}
  vision: {selector(vision)}
  tiny: {selector(fast)}
  memory: {selector(fast)}
  widget: {selector(fast)}

cycleOrder:
  - smol
  - default
  - slow

enabledModels:
{yaml_list(all_models, 2)}

retry:
  enabled: true
  maxRetries: 2
  baseDelayMs: 1000
  maxDelayMs: 30000
  modelFallback: true
  fallbackOn: any
  rateLimitWalksChain: true
  fallbackRevertPolicy: cooldown-expiry
  fallbackChains:
    default:
{yaml_list(fallbacks("code") + fallbacks("reasoning"), 6)}
    plan:
{yaml_list(fallbacks("reasoning"), 6)}
    slow:
{yaml_list(fallbacks("reasoning"), 6)}
    smol:
{yaml_list(fallbacks("fast"), 6)}
    commit:
{yaml_list(fallbacks("fast") + fallbacks("code"), 6)}
    task:
{yaml_list(fallbacks("code") + fallbacks("reasoning"), 6)}
    advisor:
{yaml_list(fallbacks("reasoning"), 6)}

tools:
  approvalMode: always-ask
  intentTracing: true
  approval:
    bash: prompt

lsp:
  enabled: true
  lazy: true
  diagnosticsOnWrite: true

compaction:
  enabled: true
"""

Path(".omp/config.yml").write_text(config)

# Store selected IDs for the human-readable model map.
Path(".omp/selected-models.json").write_text(
    json.dumps(
        {
            "selected": selected,
            "fallbacks": {
                role: fallbacks(role) for role in candidates
            },
            "all_enabled": all_models,
        },
        indent=2,
    ) + "\n"
)

print("\nModèles sélectionnés:")
for role, model_id in selected.items():
    print(f"  {role:12} -> {model_id}")

print("\nTous les modèles configurés ont un tarif API nul.")
PY

success "Catalogue gratuit vérifié et modèles sélectionnés."

# ------------------------------------------------------------
# 7. Backup existing configuration
# ------------------------------------------------------------

for file in \
    .omp/config.yml \
    .omp/AGENTS.md \
    .omp/RULES.md \
    .omp/BMAD-MODEL-MAP.md \
    .omp/selected-models.json \
    .env \
    .gitignore
do
    # config.yml and selected-models.json were generated above.
    # Existing files should be backed up BEFORE regeneration.
    :
done

# ------------------------------------------------------------
# 8. Secure API key storage
# ------------------------------------------------------------

# Preserve other existing environment variables.
backup_file ".env"

python3 - "$API_KEY" <<'PY'
import os
import sys
from pathlib import Path

key = sys.argv[1]
path = Path(".env")

lines = path.read_text().splitlines() if path.exists() else []

lines = [
    line for line in lines
    if not line.startswith("OPENROUTER_API_KEY=")
]

lines.append(f"OPENROUTER_API_KEY={key}")

path.write_text("\n".join(lines) + "\n")
os.chmod(path, 0o600)
PY

unset API_KEY

success "Clé enregistrée dans .env avec permissions privées."

# ------------------------------------------------------------
# 9. Protect secrets with Git
# ------------------------------------------------------------

touch .gitignore

if ! grep -qxF '.env' .gitignore; then
    backup_file ".gitignore"
    printf '\n# Local API credentials\n.env\n' >> .gitignore
fi

# Also prevent local installer backups from being committed.
if ! grep -qxF '.omp-backups/' .gitignore; then
    printf '.omp-backups/\n' >> .gitignore
fi

# ------------------------------------------------------------
# 10. Create OMP context
# ------------------------------------------------------------

mkdir -p .omp

backup_file ".omp/AGENTS.md"
backup_file ".omp/RULES.md"
backup_file ".omp/BMAD-MODEL-MAP.md"

cat > .omp/AGENTS.md <<'EOF'
# BMAD v6.12 + Oh My Pi Project Instructions

## Primary methodology

This repository uses BMAD Method v6.12.

BMAD is the source of truth for:
- Product requirements
- Product management
- Business analysis
- Architecture
- UX specifications
- User stories
- Acceptance criteria
- Development workflows
- Technical decisions

Oh My Pi is the execution and orchestration environment.

## Mandatory initialization

At the beginning of a new task:

1. Inspect the repository structure.
2. Inspect `_bmad/` and `_bmad-output/`.
3. Read relevant BMAD project configuration.
4. Identify the applicable BMAD agent.
5. Identify the applicable BMAD workflow.
6. Read the associated artifacts.
7. Determine the current project status.

Do not assume that BMAD workflows have been completed.

## BMAD agent responsibilities

Respect the responsibilities of the existing BMAD agents:

- Analyst: research and requirements discovery.
- Product Manager: product scope and prioritization.
- Architect: technical architecture and decisions.
- UX Designer: user experience and interface specifications.
- Scrum Master: story preparation and workflow coordination.
- Developer: implementation.
- QA: validation and quality assurance.

Do not replace these agents with generic coding-agent behavior.

## Model selection

Follow `.omp/BMAD-MODEL-MAP.md`.

Use the OMP plan/slow roles for analysis and architecture.
Use default/task roles for implementation and testing.
Use smol/commit for lightweight operations.

Never select a paid model intentionally.

## Development lifecycle

1. Understand the BMAD requirement.
2. Identify the relevant workflow.
3. Inspect existing code.
4. Propose an implementation plan.
5. Implement incrementally.
6. Run relevant tests.
7. Check linting and typing.
8. Verify acceptance criteria.
9. Report modified files and results.

## Project integrity

- Preserve all existing BMAD artifacts.
- Never invent requirements.
- Never silently change acceptance criteria.
- Never skip mandatory workflow steps.
- Do not mark stories complete without verification.
- Avoid unnecessary dependencies.
- Follow existing architecture decisions.

## Git

- Preserve uncommitted user changes.
- Never force-push without authorization.
- Never run destructive Git commands without approval.
- Keep changes focused.
- Never commit API keys or credentials.

## Reporting

At the end of a task report:

- BMAD workflow used.
- Files modified.
- Implementation summary.
- Tests executed.
- Test results.
- Remaining issues.
EOF

cat > .omp/RULES.md <<'EOF'
# Mandatory Project Rules

- BMAD v6.12 is the authoritative development methodology.
- Preserve existing BMAD documents and generated artifacts.
- Never invent requirements or acceptance criteria.
- Never claim tests passed without executing them.
- Never discard uncommitted user changes.
- Never force-push or execute destructive Git commands without approval.
- Never commit secrets or API keys.
- Respect the configured OpenRouter free-only model allowlist.
EOF

# ------------------------------------------------------------
# 11. Generate BMAD model mapping
# ------------------------------------------------------------

python3 - <<'PY'
import json
from pathlib import Path

data = json.loads(Path(".omp/selected-models.json").read_text())
selected = data["selected"]
fallbacks = data["fallbacks"]

def display(role):
    return selected[role]

content = f"""# BMAD v6.12 - OpenRouter Free Model Mapping

Generated automatically by setup-omp-bmad.sh.

All selected models are verified free variants.

## OMP workload assignments

| OMP role | Model |
|---|---|
| default | `{display("code")}` |
| plan | `{display("reasoning")}` |
| slow | `{display("reasoning")}` |
| smol | `{display("fast")}` |
| commit | `{display("fast")}` |
| task | `{display("code")}` |
| advisor | `{display("reasoning")}` |
| vision | `{display("vision")}` |

## BMAD persona recommendations

| BMAD persona | Recommended OMP workload |
|---|---|
| Analyst | plan / slow |
| Product Manager | plan / slow |
| Architect | plan / slow |
| UX Designer | plan / slow |
| Scrum Master | plan / smol |
| Developer | default / task |
| QA | default / task |

## Important distinction

BMAD personas are methodology agents, not native OMP model roles.

This mapping documents the recommended model workload. It does not
automatically change the active model when BMAD activates a persona.

Use the OMP model-role picker or the appropriate OMP workload to
select the configured model.

## Free fallbacks

"""

for role, models in fallbacks.items():
    content += f"### {role}\n\n"
    if models:
        for model in models:
            content += f"- `{model}`\n"
    else:
        content += "- No verified alternative currently available.\n"
    content += "\n"

content += """
## Cost policy

Only model IDs ending in `:free` are configured.

The project `enabledModels` allowlist contains only models verified
as free when this script was executed.

OpenRouter free models are subject to provider availability and
rate limits. A free model can become unavailable or be removed
from the catalog. Re-run the installer to refresh the selection.
"""

Path(".omp/BMAD-MODEL-MAP.md").write_text(content)
PY

success "Instructions BMAD et correspondance des modèles créées."

# ------------------------------------------------------------
# 12. Create project documentation
# ------------------------------------------------------------

cat > .omp/README.md <<'EOF'
# Oh My Pi + BMAD Integration

This configuration was generated by setup-omp-bmad.sh.

Files:
- config.yml: OMP project settings and free model roles.
- AGENTS.md: project context.
- RULES.md: persistent project constraints.
- BMAD-MODEL-MAP.md: BMAD persona/model workload mapping.
- selected-models.json: selected free model catalog entries.

Credentials:
- OPENROUTER_API_KEY is stored in the root .env file.
- .env must remain untracked.
- Never commit credentials.

Run OMP from the repository root:

    omp

Inspect models:

    omp models --kind chat

Inspect effective project settings:

    omp config get modelRoles
    omp config get enabledModels
EOF

# ------------------------------------------------------------
# 13. Validation
# ------------------------------------------------------------

echo ""
info "Validation de la configuration..."

test -s .omp/config.yml || die "config.yml absent."
test -s .omp/AGENTS.md || die "AGENTS.md absent."
test -s .omp/RULES.md || die "RULES.md absent."
test -s .omp/BMAD-MODEL-MAP.md || die "Model map absent."
test -s .env || die ".env absent."

# Ensure all configured model IDs remain free.
python3 - <<'PY'
import json
from pathlib import Path

data = json.loads(Path(".omp/selected-models.json").read_text())

for model_id in data["all_enabled"]:
    assert model_id.endswith(":free"), model_id

assert data["selected"]["vision"].endswith(":free")
print("Free-only model allowlist: OK")
PY

# Check that the API key is ignored by Git.
if ! git check-ignore -q .env; then
    die ".env n'est pas protégé par .gitignore."
fi

# Check no API key is accidentally in project config.
if grep -R -n 'sk-or-' .omp; then
    die "Une clé API semble présente dans .omp."
fi

# Validate effective OMP settings.
omp config get modelRoles >/dev/null \
    || die "OMP n'a pas pu lire modelRoles."

omp config get enabledModels >/dev/null \
    || die "OMP n'a pas pu lire enabledModels."

success "Configuration OMP validée."

# ------------------------------------------------------------
# 14. Completion
# ------------------------------------------------------------

echo ""
echo "=================================================="
printf "${GREEN}INSTALLATION TERMINÉE${RESET}\n"
echo "=================================================="
echo ""
echo "Projet       : $PROJECT_ROOT"
echo "BMAD         : installation existante préservée"
echo "Oh My Pi     : installé et configuré"
echo "Provider     : OpenRouter uniquement pour les rôles"
echo "Models       : modèles gratuits vérifiés"
echo "Credentials  : .env (non versionné)"
echo "Configuration: .omp/config.yml"
echo "Instructions: .omp/AGENTS.md"
echo "Rules        : .omp/RULES.md"
echo "Model map    : .omp/BMAD-MODEL-MAP.md"
echo ""
echo "Pour lancer Oh My Pi:"
echo "  omp"
echo ""
echo "Pour consulter les modèles:"
echo "  omp models --kind chat"
echo ""

read -r -p "Lancer Oh My Pi maintenant ? [O/n] " ANSWER

if [[ "$ANSWER" != "n" && "$ANSWER" != "N" ]]; then
    exec omp
fi

echo ""
success "Installation terminée. Bon développement avec BMAD !"

