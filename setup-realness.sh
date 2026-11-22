#!/usr/bin/env bash
set -euo pipefail

# realness — bootstrap du dépôt .omp personnalisé (OpenRouter uniquement).
#
# Idempotent : régénère la configuration et l'extension, mais NE TOUCHE PAS
# aux fichiers de contexte déjà présents dans architecture/ (ton travail).
# Relancer ce script ne détruit donc jamais tes contextes ni ton .env.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

mkdir -p .omp/extensions
mkdir -p \
  architecture/network \
  architecture/security \
  architecture/compatibility \
  architecture/node \
  architecture/optimization

# ---------------------------------------------------------------------------
# 1. .gitignore unique à la racine : espace de travail propre.
#    On garde uniquement .md, la config et le code (js/sh/ts), jamais l'état runtime.
# ---------------------------------------------------------------------------
cat << 'EOF' > .gitignore
# --- OMP runtime state (jamais versionné) ----------------------------
# Seuls la config, le code et les fichiers .md de contexte sont suivis ;
# tout ce qui suit est de l'état régénérable produit par omp dans .omp/.
.omp/sessions/
.omp/terminal-sessions/
.omp/cache/
.omp/blobs/
.omp/memories/
.omp/predict/
.omp/logs/
.omp/run/
.omp/natives/
.omp/puppeteer/
.omp/agents/.cache/

# Bases SQLite (agent.db, history.db, models.db, skill-descriptions.db, ...)
.omp/*.db*

# Verrous, logs, état transitoire
.omp/*.lock
.omp/*.log
.omp/last-changelog-version
.omp/secret-placeholder.key
.omp/.broken-*

# --- Secrets (local uniquement) --------------------------------------
.omp/.env
*.env.local

# --- Bruit OS / éditeur ----------------------------------------------
.DS_Store
*.swp
EOF

# Ancien emplacement du .gitignore : on le retire (déplacé à la racine).
rm -f .omp/.gitignore

# ---------------------------------------------------------------------------
# 2. Provider unique : OpenRouter (clé lue depuis .omp/.env, jamais commitée).
# ---------------------------------------------------------------------------
cat << 'EOF' > .omp/models.yml
providers:
  openrouter:
    baseUrl: https://openrouter.ai/api/v1
    api: openai-completions
    # Résolue depuis .omp/.env (chargé car le lanceur pointe le dossier agent d'omp ici).
    apiKey: OPENROUTER_API_KEY
    authHeader: true
    models:
      - id: free
        name: OpenRouter Free Router (Auto Tool-Calling)
      - id: nvidia/nemotron-3-ultra-550b-a55b:free
        name: Nemotron 3 Ultra 550B (Free)
      - id: particle-ai/particle-1:free
        name: Particle-1 Agentic Code (Free)
      - id: cohere/north-mini-code:free
        name: Cohere North Mini Code (Free)
      - id: dots-studio/dots-3-note-preview:free
        name: Dots3-Note Preview (Free)
      - id: inclusionai/ling-3.2-flash:free
        name: Ling 3.2 Flash (Free)
EOF

cat << 'EOF' > .omp/config.yml
enabledProviders: []

disabledProviders:
  - anthropic
  - openai
  - openai-codex
  - google
  - google-vertex
  - groq
  - mistral
  - xai
  - github-copilot
  - cursor
  - azure
  - amazon-bedrock
  - deepseek
  - ollama
  - lm-studio
  - llama.cpp

enabledModels:
  - openrouter/*:free
  - openrouter/free

modelRoles:
  default: openrouter/nvidia/nemotron-3-ultra-550b-a55b:free

symbolPreset: unicode

composer:
  shape: band

theme:
  dark: titanium

update:
  auto: false

setupVersion: 3
EOF

cat << 'EOF' > .omp/.env.example
# OpenRouter credential — le fournisseur unique de ce dépôt.
#
# Copie ce fichier en `.env` (git-ignoré) dans le même dossier puis renseigne la clé :
#
#     cp .omp/.env.example .omp/.env
#
# `omp-arch.sh` pointe le dossier agent d'omp vers ce dépôt, donc omp charge
# `.omp/.env` automatiquement. Aucune variable d'environnement hors du dépôt
# n'est nécessaire.
OPENROUTER_API_KEY=
EOF

# ---------------------------------------------------------------------------
# 3. Extension OMP : sélecteur d'agent au démarrage + rechargement à chaud.
# ---------------------------------------------------------------------------
cat << 'EOF' > .omp/extensions/architect-session.ts
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

interface DomainAgentSpec {
  model?: string;
  definition?: string;
  instructions?: string[] | string;
}

interface LoadedDomainAgent {
  domain: string;
  name: string;
  contextFileName: string;
  model?: string;
  definition: string;
  instructions: string[];
  context: string;
}

function findRealnessRoot(cwd: string): string {
  const agentDir = process.env.PI_CODING_AGENT_DIR;
  if (agentDir) {
    const fromAgentDir = dirname(resolve(agentDir));
    if (existsSync(join(fromAgentDir, "architecture"))) return fromAgentDir;
  }
  if (existsSync(join(cwd, "architecture"))) return cwd;
  const nested = join(cwd, "realness");
  if (existsSync(join(nested, "architecture"))) return nested;
  return cwd;
}

function sanitizeYamlScalars(raw: string): string {
  return raw
    .split(/\r?\n/)
    .map((line) => {
      const defMatch = line.match(/^(\s*definition\s*:\s*)([^"'|>\[{].*)$/);
      if (defMatch && defMatch[2].includes(": ")) {
        return `${defMatch[1]}${JSON.stringify(defMatch[2].trim())}`;
      }
      const itemMatch = line.match(/^(\s*-\s+)([^"'|>\[{].*)$/);
      if (itemMatch && itemMatch[2].includes(": ")) {
        return `${itemMatch[1]}${JSON.stringify(itemMatch[2].trim())}`;
      }
      return line;
    })
    .join("\n");
}

function parseAgentYaml(raw: string, fileLabel: string): DomainAgentSpec {
  const cleaned = raw
    .replace(/^\uFEFF/, "")
    .replace(/^---\r?\n/, "")
    .replace(/\r?\n---\s*$/, "")
    .trim();

  const normalized = sanitizeYamlScalars(cleaned);

  try {
    return (Bun.YAML.parse(normalized) ?? {}) as DomainAgentSpec;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Erreur YAML dans ${fileLabel} : ${msg}`);
  }
}

function loadDomainAgents(realnessRoot: string): {
  agents: Map<string, LoadedDomainAgent>;
  errors: string[];
} {
  const archDir = join(realnessRoot, "architecture");
  const agents = new Map<string, LoadedDomainAgent>();
  const errors: string[] = [];

  if (!existsSync(archDir)) return { agents, errors };

  const domains = readdirSync(archDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();

  for (const domain of domains) {
    const domainDir = join(archDir, domain);
    const agentFileName = `${domain}-architect-agent.md`;
    const contextFileName = `${domain}-architect-context.md`;
    const agentPath = join(domainDir, agentFileName);
    const contextPath = join(domainDir, contextFileName);

    if (!existsSync(agentPath)) continue;

    try {
      const spec = parseAgentYaml(
        readFileSync(agentPath, "utf-8"),
        `architecture/${domain}/${agentFileName}`,
      );
      const context = existsSync(contextPath) ? readFileSync(contextPath, "utf-8").trim() : "";

      const instructions = Array.isArray(spec.instructions)
        ? spec.instructions.map((line) => String(line).trim()).filter(Boolean)
        : typeof spec.instructions === "string" && spec.instructions.trim()
          ? [spec.instructions.trim()]
          : [];

      agents.set(domain, {
        domain,
        name: `${domain}-architect-agent`,
        contextFileName,
        model: spec.model?.trim(),
        definition: spec.definition?.trim() || `Agent d'architecture (${domain})`,
        instructions,
        context,
      });
    } catch (err) {
      errors.push(err instanceof Error ? err.message : String(err));
    }
  }

  return { agents, errors };
}

export default function architectSessionExtension(pi: ExtensionAPI): void {
  const realnessRoot = findRealnessRoot(resolve(process.cwd()));
  let activeDomain: string | null = null;

  async function applyAgent(agent: LoadedDomainAgent, ctx: ExtensionContext): Promise<void> {
    activeDomain = agent.domain;

    if (agent.model) {
      const registry = ctx.modelRegistry;
      const available = registry ? registry.getAvailable() : [];
      const resolved = agent.model.includes("/")
        ? (() => {
            const [provider, ...rest] = agent.model.split("/");
            return registry?.find(provider, rest.join("/"));
          })()
        : available.find((m) => m.id === agent.model || `${m.provider}/${m.id}` === agent.model);

      if (resolved) {
        await pi.setModel(resolved);
      } else if (ctx.hasUI) {
        ctx.ui.notify(`Modèle introuvable pour ${agent.name} : ${agent.model}`, "warning");
      }
    }

    if (ctx.hasUI) {
      ctx.ui.setStatus("architect-agent", `Agent: ${agent.name}`);
    }
  }

  async function selectAgent(ctx: ExtensionContext, requested?: string): Promise<boolean> {
    const { agents, errors } = loadDomainAgents(realnessRoot);

    if (errors.length > 0 && ctx.hasUI) {
      ctx.ui.notify(errors.join("\n"), "error");
    }

    if (agents.size === 0) {
      if (ctx.hasUI && errors.length === 0) {
        ctx.ui.notify(
          "Aucun {domain}-architect-agent.md trouvé dans realness/architecture/{domain}/",
          "error",
        );
      }
      return false;
    }

    if (requested) {
      const normalized = requested
        .trim()
        .replace(/-architect-agent$/, "")
        .replace(/-architect$/, "")
        .replace(/-agent$/, "");
      const direct = agents.get(normalized);
      if (direct) {
        await applyAgent(direct, ctx);
        if (ctx.hasUI) {
          ctx.ui.notify(`Agent actif : ${direct.name}`, "info");
        }
        return true;
      }
    }

    if (!ctx.hasUI) return false;

    const entries = Array.from(agents.values());
    const options = entries.map((a) => `${a.name} — ${a.definition}`);
    const choice = await ctx.ui.select(
      "Avec quel agent d'architecture voulez-vous communiquer ?",
      options,
    );

    if (!choice) return false;

    const chosenName = choice.split(" — ")[0].trim();
    const chosen = entries.find((a) => a.name === chosenName);
    if (!chosen) return false;

    await applyAgent(chosen, ctx);
    ctx.ui.notify(`Conversation démarrée avec ${chosen.name}`, "info");
    return true;
  }

  pi.on("session_start", async (_event, ctx) => {
    await selectAgent(ctx);
  });

  pi.on("input", async (_event, ctx) => {
    if (!activeDomain) {
      const selected = await selectAgent(ctx);
      // Only swallow a submission when an interactive picker was shown and dismissed.
      // Headless/RPC modes have no picker, so their input must keep flowing.
      if (!selected && ctx.hasUI) return { action: "handled" };
    }
    return { action: "continue" };
  });

  pi.on("before_agent_start", async () => {
    if (!activeDomain) return;

    const latest = loadDomainAgents(realnessRoot).agents.get(activeDomain);
    if (!latest) return;

    const instructionsBlock = latest.instructions.length
      ? `## Instructions\n${latest.instructions.map((i) => `- ${i}`).join("\n")}`
      : "";

    const contextBlock = latest.context
      ? `## Contexte d'architecture (${latest.domain}/${latest.contextFileName})\n${latest.context}`
      : "";

    const systemPrompt = [
      `# Rôle : ${latest.name}`,
      latest.definition,
      instructionsBlock,
      contextBlock,
    ]
      .filter(Boolean)
      .join("\n\n");

    return { systemPrompt };
  });

  pi.registerCommand("agent", {
    description: "Changer d'agent d'architecture (ex: /agent security)",
    handler: async (args, ctx) => {
      await selectAgent(ctx, args);
    },
  });

  pi.registerShortcut("alt+g", {
    description: "Changer d'agent d'architecture",
    handler: async (ctx) => {
      await selectAgent(ctx);
    },
  });
}
EOF

# ---------------------------------------------------------------------------
# 4. Domaines d'architecture — créés UNIQUEMENT s'ils n'existent pas déjà
#    (tes contextes sont préservés d'un run à l'autre).
# ---------------------------------------------------------------------------
get_model() {
  echo "openrouter/cohere/north-mini-code:free"
}

get_definition() {
  case "$1" in
    network) echo "Architecte et expert réseaux spécialisé dans les systèmes décentralisés Peer-to-Peer : conçoit des mécanismes réseau nativement décentralisés, ne se limite pas à un seul paradigme, mais pense le système le plus adapté au besoin." ;;
    security) echo "Architecte et expert en sécurité des systèmes d'information : conçoit des architectures sécurisées by design, établissant la robustesse entre le réseau Peer-to-Peer et la couche logicielle en C." ;;
    compatibility) echo "Architecte et expert de compatibilité entre systèmes d'architectures différentes : conçoit un système en C de bas niveau qui peut tourner nativement et correctement sur des architectures différentes (x86-64 (AMD64) - AArch64 (ARMv8/v9 64-bit) - AArch32 (ARMv7) - ARM Cortex-M (32-bit) - RISC-V RV32 - RISC-V RV64)." ;;
    node) echo "Architecte et expert des systèmes de graphes : pense l'existence et l'intégration d'un nœud dans un graphe complexe et ses relations avec les autres nœuds." ;;
    optimization) echo "Architecte et expert d'optimisation des systèmes de bas niveau : conçoit en C un système de bas niveau nativement robuste en matière de stockage et de gestion de la mémoire." ;;
  esac
}

capitalize() {
  printf '%s' "$1" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'
}

for domain in network security compatibility node optimization; do
  agent_file="architecture/${domain}/${domain}-architect-agent.md"
  context_file="architecture/${domain}/${domain}-architect-context.md"
  draft_file="architecture/${domain}/${domain}-architect-context_draft.md"
  model_val="$(get_model)"
  def_val="$(get_definition "$domain")"
  title_val="$(capitalize "$domain")"

  if [ ! -f "$agent_file" ]; then
    cat << EOF > "$agent_file"
model: ${model_val}

definition: "${def_val}"

instructions:
  - "La logique est plus prioritaire que le détail technique."
  - "Ton contexte principal se trouve dans ./${domain}-architect-context.md que tu dois considérer très sérieusement."
  - "Quand une session commence, tu charges complètement ton contexte (expliqué avant). On échange profondément sur un sujet ; si un élément est concluant, je te demande de l'ajouter comme un seul point (- ...) dans ./${domain}-architect-context.md d'une manière explicite et compacte pour que ce dernier soit suffisant afin d'être compris dans le contexte. Sinon tu ne fais rien, ou je te demande de le mettre dans ./${domain}-architect-context_draft.md pour être repris dans d'autres sessions. Le fichier draft est censé être nettoyé et vide à chaque fois."
  - "Quand une session commence, tu vérifies si ./${domain}-architect-context_draft.md est vide pour commencer un nouveau sujet ; sinon tu me dis qu'il y a un sujet en cours."
EOF
    echo "  créé : $agent_file"
  fi

  if [ ! -f "$context_file" ]; then
    cat << EOF > "$context_file"
# Contexte Architecture — ${title_val}

## Périmètre et objectifs
- Décrire ici l'architecture cible et les invariants du domaine **${domain}**.

## Contraintes techniques
- Lister les contraintes non négociables (protocoles, versions, SLA, limites).

## Décisions d'architecture (ADR)
- Documenter les choix structurants et leurs justifications.
EOF
    echo "  créé : $context_file"
  fi

  # Le draft est un espace de travail éphémère, mais versionné (fichier .md).
  [ -f "$draft_file" ] || : > "$draft_file"
done

# ---------------------------------------------------------------------------
# 5. Credential local : .env (git-ignoré) créé depuis le modèle si absent.
# ---------------------------------------------------------------------------
if [ ! -f .omp/.env ]; then
  cp .omp/.env.example .omp/.env
  echo
  echo "ACTION REQUISE : renseigne ta clé dans .omp/.env (OPENROUTER_API_KEY=...)."
fi

echo
echo "Préparation terminée dans $ROOT"
echo "Lance une session avec : ./omp-arch.sh"