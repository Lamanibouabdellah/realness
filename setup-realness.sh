#!/usr/bin/env bash
set -euo pipefail

# realness — bootstrap du dépôt .omp personnalisé (deux voies : OpenRouter | Amundi API Gateway).
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

# Résidus temporaires (jamais versionnés)
.omp/.env.tmp*
architecture/**/*.tmp*

# --- Bruit OS / éditeur ----------------------------------------------
.DS_Store
*.swp
EOF

# Ancien emplacement du .gitignore : on le retire (déplacé à la racine).
rm -f .omp/.gitignore

# ---------------------------------------------------------------------------
# 2. Deux voies d'inférence : OpenRouter | Amundi API Gateway
#    (jetons lus depuis .omp/.env, jamais commités).
# ---------------------------------------------------------------------------
cat << 'EOF' > .omp/models.yml
# Deux voies d'inférence : OpenRouter | API Gateway Amundi (studio-llm-gateway).
#
# Le gateway Amundi n'expose pas UNE API mais TROIS surfaces distinctes ; chacune
# a son propre fournisseur ci-dessous (même jeton ALTO_STUDIO_TOKEN) :
#
#   apigateway           OpenAI « Chat Completions »   <root>/v2/usecase/35
#   apigateway-openai    OpenAI « Responses »          <root>/v2/usecase/35/openai/v1
#   apigateway-anthropic Anthropic « Messages »        <root>/usecase/35/providers/anthropic/models
#
# Les trois surfaces sont routées par le modèle : le corps de requête porte l'id
# (Anthropic inclus), donc un seul `baseUrl` par surface suffit.
#
# Aucun bloc `discovery` : <root>/models annonce aussi des modèles inutilisables
# par omp ; les entrées ci-dessous sont la seule source de vérité.
# Roster relevé sur <root>/models le 2026-11-26, chaque entrée validée par une
# requête omp réelle. Écartés (annoncés mais KO) :
#   gpt-5-codex, gpt-5.1-codex, gpt-5.1-codex-mini  404 DeploymentNotFound
#   claude-fable-5, mistral-7b-instruct-v0-3         réponse vide systématique
#   codestral, mistral-medium, mistral-small        rejettent stream_options.include_usage
#   mixtral-8x22b-instruct-v0-1-awq                 « roles must alternate » (400)
#   qwen3-vl-32b-instruct                           501 Hosted_vllmException
providers:
  # -------------------------------------------------------------------------
  # Voie « OpenRouter ».
  # -------------------------------------------------------------------------
  openrouter:
    baseUrl: https://openrouter.ai/api/v1
    api: openai-completions
    # Résolue depuis .omp/.env (chargé car le lanceur pointe le dossier agent d'omp ici).
    apiKey: OPENROUTER_API_KEY
    authHeader: true
    models:
      # Routeur automatique OpenRouter
      - id: free
        name: OpenRouter Free Router (Auto Tool-Calling)

      # --- Modèles Principaux ---
      # Agents 1 & 4 : Compatibilité C multi-arch + Optimisation mémoire/stockage
      - id: particle-ai/particle-1:free
        name: Particle-1 Agentic Code (Free)
      # Agents 2 & 5 : Réseaux décentralisés P2P + Sécurité SI (P2P <-> C)
      - id: nvidia/nemotron-3-ultra-550b-a55b:free
        name: Nemotron 3 Ultra 550B (Free)
      # Agent 3 : Systèmes de graphes (et Secours Agent 2 : Réseaux P2P)
      - id: inclusionai/ling-3.2-flash:free
        name: Ling 3.2 Flash (Free)

      # --- Modèles de Secours (Fallbacks) ---
      # Secours Agent 1 : Compatibilité C multi-architectures
      - id: cohere/north-mini-code:free
        name: Cohere North Mini Code (Free)
      # Secours Agent 3 : Systèmes de graphes
      - id: google/gemma-4-31b-it:free
        name: Gemma 4 31B IT (Free)
      # Secours Agent 4 : Optimisation stockage & mémoire en C
      - id: recursive/flint-v1.0:free
        name: Recursive Flint v1.0 (Free)
      # Secours Agent 5 : Sécurité des systèmes d'information
      - id: dots-studio/dots-3-note-preview:free
        name: Dots3-Note Preview (Free)

  # -------------------------------------------------------------------------
  # API Gateway — surface OpenAI « Chat Completions ».
  # -------------------------------------------------------------------------
  apigateway:
    baseUrl: https://studio-llm-gateway.intramundi.com/v2/usecase/35
    api: openai-completions
    apiKey: ALTO_STUDIO_TOKEN
    authHeader: true
    models:
      - id: DeepSeek-V4-Flash
        name: DeepSeek V4 Flash
        input: [text]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: deepseek-v3
      - id: DeepSeek-V4-Pro
        name: DeepSeek V4 Pro
        input: [text]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: deepseek-v3
      - id: DeepSeek-V4.1-Flash
        name: DeepSeek V4.1 Flash
        input: [text]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: deepseek-v3
      - id: DeepSeek-V4.1-Flash-1017
        name: DeepSeek V4.1 Flash 1017
        input: [text]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: deepseek-v3
      - id: FW-GLM-5.3
        name: GLM 5.3
        input: [text]
        contextWindow: 1048576
        maxTokens: 128000
        tokenizer: glm5
      - id: FW-Kimi-K3
        name: Kimi K3 (FW)
        input: [text]
        contextWindow: 131072
        maxTokens: 65536
        tokenizer: kimi-k2
      - id: Kimi-K2.7-Code
        name: Kimi K2.7 Code
        input: [text]
        contextWindow: 262144
        maxTokens: 128000
        tokenizer: kimi-k2
      - id: Kimi-K3.1-Pro
        name: Kimi K3.1 Pro
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        tokenizer: kimi-k2
      - id: codestral-22b
        name: Codestral 22B (CAGIP)
        input: [text]
        contextWindow: 32768
        maxTokens: 16384
      - id: gemma-4-31b-it
        name: Gemma 4 31B IT (CAGIP)
        input: [text, image]
        contextWindow: 131072
        maxTokens: 65536
      - id: glm-5-3-flash-nvfp4
        name: GLM 5.3 Flash NVFP4 (CAGIP)
        input: [text]
        contextWindow: 262144
        maxTokens: 128000
        tokenizer: glm5
      # Mistral : l'hôte refuse `store` et `max_completion_tokens`.
      - id: mistral-large-3
        name: Mistral Large 3
        input: [text, image]
        contextWindow: 128000
        maxTokens: 64000
        compat:
          supportsStore: false
          maxTokensField: max_tokens
      - id: mistral-small-3-2-24b-instruct-2506
        name: Mistral Small 3.2 24B Instruct (CAGIP)
        input: [text, image]
        contextWindow: 32768
        maxTokens: 16384
      - id: mistral-small-4-119b-2603-nvfp4
        name: Mistral Small 4 119B NVFP4 (CAGIP)
        input: [text]
        contextWindow: 32768
        maxTokens: 16384
      - id: qwen3-32b
        name: Qwen3 32B (CAGIP)
        input: [text]
        contextWindow: 32768
        maxTokens: 16384
        tokenizer: qwen3
      - id: qwen3-6-27b
        name: Qwen3.6 27B (CAGIP)
        input: [text]
        contextWindow: 131072
        maxTokens: 65536
        tokenizer: qwen3
      - id: qwen3-8-27b-nvfp4
        name: Qwen3.8 27B NVFP4 (CAGIP)
        input: [text]
        contextWindow: 131072
        maxTokens: 65536
        tokenizer: qwen3

  # -------------------------------------------------------------------------
  # API Gateway — surface OpenAI « Responses » (raisonnement GPT).
  # -------------------------------------------------------------------------
  apigateway-openai:
    baseUrl: https://studio-llm-gateway.intramundi.com/v2/usecase/35/openai/v1
    api: openai-responses
    apiKey: ALTO_STUDIO_TOKEN
    authHeader: true
    models:
      - id: gpt-4.1
        name: GPT 4.1
        input: [text, image]
        contextWindow: 1047576
        maxTokens: 128000
        tokenizer: o200k
      - id: gpt-4.1-mini
        name: GPT 4.1 mini
        input: [text, image]
        contextWindow: 1047576
        maxTokens: 128000
        tokenizer: o200k
      - id: gpt-5-mini
        name: GPT 5 mini
        input: [text, image]
        contextWindow: 400000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.2-codex
        name: GPT 5.2 Codex
        input: [text]
        contextWindow: 400000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.3-codex
        name: GPT 5.3 Codex
        input: [text]
        contextWindow: 400000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.4
        name: GPT 5.4
        input: [text, image]
        contextWindow: 400000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.4-mini
        name: GPT 5.4 mini
        input: [text, image]
        contextWindow: 400000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.4-nano
        name: GPT 5.4 nano
        input: [text, image]
        contextWindow: 400000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.5
        name: GPT 5.5
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.6-luna
        name: GPT 5.6 Luna
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.6-sol
        name: GPT 5.6 Sol
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-5.6-terra
        name: GPT 5.6 Terra
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-6-luna
        name: GPT 6 Luna
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-6-sol
        name: GPT 6 Sol
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-6.1-sol
        name: GPT 6.1 Sol
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k
      - id: gpt-6.1-terra
        name: GPT 6.1 Terra
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: o200k

  # -------------------------------------------------------------------------
  # API Gateway — surface Anthropic « Messages » (modèle dans le corps).
  # -------------------------------------------------------------------------
  apigateway-anthropic:
    baseUrl: https://studio-llm-gateway.intramundi.com/usecase/35/providers/anthropic/models
    api: anthropic-messages
    apiKey: ALTO_STUDIO_TOKEN
    auth: apiKey
    authHeader: true
    disableStrictTools: true
    models:
      - id: claude-haiku-5-5
        name: Claude Haiku 5.5
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: claude-v5
      - id: claude-opus-4-6
        name: Claude Opus 4.6
        input: [text, image]
        contextWindow: 200000
        maxTokens: 100000
        reasoning: true
        tokenizer: claude-v47
      - id: claude-opus-4-7
        name: Claude Opus 4.7
        input: [text, image]
        contextWindow: 200000
        maxTokens: 100000
        reasoning: true
        tokenizer: claude-v47
      - id: claude-opus-4-8
        name: Claude Opus 4.8
        input: [text, image]
        contextWindow: 200000
        maxTokens: 100000
        reasoning: true
        tokenizer: claude-v47
      - id: claude-opus-5
        name: Claude Opus 5
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: claude-v5
      - id: claude-opus-5-5
        name: Claude Opus 5.5
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: claude-v5
      - id: claude-sonnet-4-6
        name: Claude Sonnet 4.6
        input: [text, image]
        contextWindow: 200000
        maxTokens: 100000
        reasoning: true
        tokenizer: claude-v47
      - id: claude-sonnet-5
        name: Claude Sonnet 5
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: claude-v5
      - id: claude-sonnet-5-5
        name: Claude Sonnet 5.5
        input: [text, image]
        contextWindow: 1000000
        maxTokens: 128000
        reasoning: true
        tokenizer: claude-v5-sonnet
EOF

cat << 'EOF' > .omp/config.yml
enabledProviders: []

disabledProviders: []

enabledModels:
  - openrouter/*:free
  - openrouter/free
  - apigateway/*
  - apigateway-openai/*
  - apigateway-anthropic/*

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
# Jetons d'inférence — un par voie, dans le même dossier que ce modèle.
#
# Copie ce fichier en `.env` (git-ignoré) puis renseigne les clés :
#
#     cp .omp/.env.example .omp/.env
#
# `omp-arch.sh` pointe le dossier agent d'omp vers ce dépôt, donc omp charge
# `.omp/.env` automatiquement. Aucune variable d'environnement hors du dépôt
# n'est nécessaire.
#
#   OpenRouter         -> OPENROUTER_API_KEY
#   Amundi API Gateway -> ALTO_STUDIO_TOKEN
OPENROUTER_API_KEY=
ALTO_STUDIO_TOKEN=
EOF

# ---------------------------------------------------------------------------
# 3. Extension OMP : sélecteur d'agent au démarrage + rechargement à chaud.
# ---------------------------------------------------------------------------
cat << 'EOF' > .omp/extensions/architect-session.ts
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

// ---------------------------------------------------------------------------
// Deux voies d'inférence, choisies AU DÉMARRAGE de la session :
//   - apigateway : l'API Gateway Amundi (studio-llm-gateway)
//   - openrouter : OpenRouter
// Le choix de la voie précède celui de l'agent ; chaque fiche d'agent déclare
// un modèle par voie et la voie choisie décide lequel est appliqué.
// ---------------------------------------------------------------------------
const VOICE_GATEWAY = "apigateway";
const VOICE_OPENROUTER = "openrouter";

interface VoiceSpec {
  id: string;
  label: string;
  /** Variable d'environnement portant le jeton (résolue depuis .omp/.env). */
  envKey: string;
  /** Modèle appliqué dès que la voie est active (jamais celui de l'autre voie). */
  defaultModel: string;
}

const VOICES: VoiceSpec[] = [
  {
    id: VOICE_GATEWAY,
    label: "Amundi API Gateway",
    envKey: "ALTO_STUDIO_TOKEN",
    defaultModel: "apigateway/DeepSeek-V4.1-Flash",
  },
  {
    id: VOICE_OPENROUTER,
    label: "OpenRouter",
    envKey: "OPENROUTER_API_KEY",
    defaultModel: "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free",
  },
];

interface DomainAgentSpec {
  /** Rétrocompatibilité : voie unique déclarée en clair (`openrouter/...`). */
  model?: string | Record<string, string>;
  /** Modèle par voie : { openrouter: "...", apigateway: "..." }. */
  models?: Record<string, string>;
  definition?: string;
  instructions?: string[] | string;
}

interface LoadedDomainAgent {
  domain: string;
  name: string;
  contextFileName: string;
  /** Modèle par voie (clé = identifiant de voie). */
  models: Record<string, string>;
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
      // `\s` est exclu du groupe de valeur : sans cela, le retour arrière de
      // `\s*`/`\s+` laisse la valeur débuter par une espace, la classe accepte
      // alors une valeur DÉJÀ entre guillemets et la ligne devient `clé:""…""`,
      // que YAML relit comme une simple clé sans valeur (définition perdue).
      const defMatch = line.match(/^(\s*definition\s*:\s*)([^"'\s|>\[{].*)$/);
      if (defMatch && defMatch[2].includes(": ")) {
        return `${defMatch[1]}${JSON.stringify(defMatch[2].trim())}`;
      }
      const itemMatch = line.match(/^(\s*-\s+)([^"'\s|>\[{].*)$/);
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

/** Normalise `models` (ou l'ancien `model`) en table { voie: modèle }. */
function normalizeModels(spec: DomainAgentSpec): Record<string, string> {
  const models: Record<string, string> = {};
  const raw = spec.models ?? spec.model;

  if (raw && typeof raw === "object") {
    for (const [voice, value] of Object.entries(raw)) {
      if (typeof value === "string" && value.trim()) {
        models[voice.trim()] = value.trim();
      }
    }
    return models;
  }

  if (typeof raw === "string" && raw.trim()) {
    const value = raw.trim();
    models[value.split("/")[0]] = value;
  }

  return models;
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
        models: normalizeModels(spec),
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
  let activeVoice: string | null = null;
  let activeVoiceApplied = false;

  function hasEnv(key: string): boolean {
    return (process.env[key] ?? "").trim().length > 0;
  }

  function voiceLabel(id: string | null): string {
    return VOICES.find((voice) => voice.id === id)?.label ?? "aucune";
  }

  function voiceSpec(id: string | null): VoiceSpec | undefined {
    return VOICES.find((voice) => voice.id === id);
  }

  function resolveModelSpec(ctx: ExtensionContext, spec: string) {
    const registry = ctx.modelRegistry;
    const available = registry ? registry.getAvailable() : [];
    return spec.includes("/")
      ? (() => {
          const [provider, ...rest] = spec.split("/");
          return registry?.find(provider, rest.join("/"));
        })()
      : available.find((m) => m.id === spec || `${m.provider}/${m.id}` === spec);
  }

  async function applyModel(ctx: ExtensionContext, spec: string, label: string): Promise<boolean> {
    const resolved = resolveModelSpec(ctx, spec);

    if (!resolved) {
      if (ctx.hasUI) {
        ctx.ui.notify(`Modèle introuvable pour ${label} : ${spec}`, "warning");
      }
      return false;
    }

    if ((await pi.setModel(resolved)) === false) {
      if (ctx.hasUI) {
        ctx.ui.notify(
          `Modèle ${spec} non activable pour ${label} — la session reste sur le modèle précédent.`,
          "error",
        );
      }
      return false;
    }
    return true;
  }

  function statusText(agentName: string | null): string {
    const parts = [agentName ? `Agent: ${agentName}` : "Agent: aucun", `Voie: ${voiceLabel(activeVoice)}`];
    if (activeVoice && !activeVoiceApplied) parts.push("modèle non activé");
    return parts.join(" · ");
  }

  function warnMissingTokens(ctx: ExtensionContext): void {
    const missingKey = VOICES.filter((voice) => !hasEnv(voice.envKey));
    if (missingKey.length > 0 && ctx.hasUI) {
      ctx.ui.notify(
        `Jeton absent dans .omp/.env : ${missingKey.map((voice) => voice.envKey).join(", ")} — voie non proposée.`,
        "warning",
      );
    }
  }

  async function applyAgent(agent: LoadedDomainAgent, ctx: ExtensionContext): Promise<void> {
    activeDomain = agent.domain;

    const voice = voiceSpec(activeVoice);

    if (voice) {
      const declared = agent.models[voice.id];
      const label = `${agent.name} [${voice.label}]`;

      if (declared) {
        await applyModel(ctx, declared, label);
      } else {
        if (ctx.hasUI) {
          ctx.ui.notify(
            `Aucun modèle déclaré pour la voie « ${voice.label} » (agent ${agent.name}) — repli sur le modèle par défaut de la voie : ${voice.defaultModel}.`,
            "warning",
          );
        }
        await applyModel(ctx, voice.defaultModel, label);
      }
    } else if (ctx.hasUI) {
      ctx.ui.notify(`Aucune voie active : modèle de ${agent.name} non appliqué.`, "warning");
    }

    if (ctx.hasUI) {
      ctx.ui.setStatus("architect-agent", statusText(agent.name));
    }
  }

  async function chooseVoice(ctx: ExtensionContext, force = false): Promise<string | null> {
    warnMissingTokens(ctx);

    const withKey = VOICES.filter((voice) => hasEnv(voice.envKey));
    if (!force && withKey.length === 1) return withKey[0].id;

    const candidates = force || withKey.length === 0 ? VOICES : withKey;
    if (!ctx.hasUI) return force ? null : candidates[0].id;

    const choice = await ctx.ui.select(
      "Quelle voie d'inférence veux-tu utiliser pour cette session ?",
      candidates.map((voice) => voice.label),
    );
    if (!choice) return null;

    return candidates.find((voice) => voice.label === choice)?.id ?? null;
  }

  async function ensureVoice(ctx: ExtensionContext): Promise<boolean> {
    if (activeVoice) return true;

    const chosen = await chooseVoice(ctx);
    if (!chosen) return false;

    const voice = voiceSpec(chosen);
    if (!voice) return false;

    activeVoice = voice.id;
    activeVoiceApplied = await applyModel(ctx, voice.defaultModel, voice.label);
    if (ctx.hasUI) ctx.ui.setStatus("architect-agent", statusText(activeDomain));
    if (ctx.hasUI) {
      ctx.ui.notify(`Voie active : ${voiceLabel(chosen)}`, "info");
    }
    return true;
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

  async function ensureSession(ctx: ExtensionContext): Promise<boolean> {
    if (!(await ensureVoice(ctx))) return false;
    if (activeDomain) return true;
    return selectAgent(ctx);
  }

  async function switchVoice(ctx: ExtensionContext, requested?: string): Promise<void> {
    const requestedId = (requested ?? "").trim().toLowerCase();
    const direct = VOICES.find(
      (voice) => voice.id === requestedId || voice.label.toLowerCase() === requestedId,
    );

    if (direct) warnMissingTokens(ctx);

    const previous = activeVoice;
    const chosen = direct ? direct.id : await chooseVoice(ctx, true);
    if (!chosen) return;

    const voice = voiceSpec(chosen);
    if (!voice) return;

    activeVoice = voice.id;
    activeVoiceApplied = await applyModel(ctx, voice.defaultModel, voice.label);
    if (ctx.hasUI) ctx.ui.setStatus("architect-agent", statusText(activeDomain));
    if (ctx.hasUI) {
      ctx.ui.notify(
        chosen === previous
          ? `Voie déjà active : ${voiceLabel(chosen)}`
          : `Voie active : ${voiceLabel(chosen)}`,
        "info",
      );
    }

    if (activeDomain) {
      const agent = loadDomainAgents(realnessRoot).agents.get(activeDomain);
      if (agent) await applyAgent(agent, ctx);
    } else {
      await selectAgent(ctx);
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    await ensureSession(ctx);
  });

  pi.on("input", async (event, ctx) => {
    // /agent et /voie font leur propre sélection : `input` précède l'interprétation
    // des commandes, on ne laisse passer que ces deux commandes ; toute autre soumission
    // (y compris /help ou un chemin absolu) passe par ensureSession.
    const text = (event as unknown as { text?: string }).text ?? "";
    if (/^\s*\/(agent|voie)\b/i.test(text)) return;

    const ready = await ensureSession(ctx);
    // Only swallow a submission when an interactive picker was shown and dismissed.
    // Headless/RPC modes have no picker, so their input must keep flowing.
    if (!ready && ctx.hasUI) return { handled: true };
    return;
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
      if (!(await ensureVoice(ctx))) return;
      await selectAgent(ctx, args);
    },
  });

  pi.registerCommand("voie", {
    description: "Changer de voie d'inférence : /voie (apigateway | openrouter)",
    handler: async (args, ctx) => {
      await switchVoice(ctx, args);
    },
  });

  pi.registerShortcut("alt+g", {
    description: "Changer d'agent d'architecture",
    handler: async (ctx) => {
      if (!(await ensureVoice(ctx))) return;
      await selectAgent(ctx);
    },
  });

  pi.registerShortcut("alt+v", {
    description: "Changer de voie d'inférence",
    handler: async (ctx) => {
      await switchVoice(ctx);
    },
  });
}
EOF

# ---------------------------------------------------------------------------
# 4. Domaines d'architecture — créés UNIQUEMENT s'ils n'existent pas déjà
#    (tes contextes sont préservés d'un run à l'autre).
# ---------------------------------------------------------------------------
get_openrouter_model() {
  case "$1" in
    network|security) echo "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free" ;;
    compatibility|optimization) echo "openrouter/particle-ai/particle-1:free" ;;
    node) echo "openrouter/inclusionai/ling-3.2-flash:free" ;;
    *) echo "openrouter/cohere/north-mini-code:free" ;;
  esac
}

get_apigateway_model() {
  # Modèle appliqué par défaut aux fiches d'agent côté gateway.
  # L'agent de compatibilité raisonne sur Claude Opus 5 (surface Anthropic) ;
  # les autres domaines restent sur DeepSeek (surface Chat Completions).
  case "$1" in
    compatibility) echo "apigateway-anthropic/claude-opus-5" ;;
    *) echo "apigateway/DeepSeek-V4.1-Flash" ;;
  esac
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

# Migration des fiches créées avant l'introduction des deux voies :
#   - `model: openrouter/...` -> bloc `models:` (openrouter + apigateway) ;
#   - ni `models:` ni `model:` -> bloc `models:` ajouté en tête.
# Idempotent : une fiche déclarant déjà `models:` n'est jamais modifiée.
# L'état du retour à la ligne final de la fiche est toujours préservé.
migrate_agent_models() {
  local file="$1" default_openrouter="$2" apigateway_model="$3" legacy_model mode

  if grep -qE '^models:' "$file"; then
    return 0
  fi

  if grep -qE '^model:[[:space:]]*[^[:space:]]' "$file"; then
    mode="replace"
    legacy_model="$(awk '/^model:[[:space:]]*[^[:space:]]/ { sub(/^model:[[:space:]]*/, ""); gsub(/\r/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$file")"
  else
    mode="prepend"
    legacy_model="$default_openrouter"
  fi

  awk -v mode="$mode" -v or_model="$legacy_model" -v gw_model="$apigateway_model" '
    function block() {
      print "models:"
      print "  openrouter: " or_model
      print "  apigateway: " gw_model
    }
    mode == "replace" && replaced == 0 && /^model:[[:space:]]*[^[:space:]]/ {
      block()
      replaced = 1
      next
    }
    mode == "prepend" && NR == 1 && /^---\r?$/ {
      # Fiche avec front-matter explicite : le bloc va juste après la première ligne.
      print
      block()
      next
    }
    mode == "prepend" && NR == 1 {
      block()
      print ""
    }
    { print }
    END {
      if (mode == "prepend" && NR == 0) block()
    }
  ' "$file" > "${file}.tmp"
  # awk ajoute toujours un saut de ligne final : on préserve l'état d'origine
  # (fiche sans retour à la ligne terminal) pour ne modifier que le front-matter.
  if [ -n "$(tail -c 1 "$file")" ]; then
    printf '%s' "$(cat "${file}.tmp")" > "${file}.tmp2"
    mv "${file}.tmp2" "${file}.tmp"
  fi
  mv "${file}.tmp" "$file"
  echo "  migré : $file (voie apigateway ajoutée)"
}

for domain in network security compatibility node optimization; do
  agent_file="architecture/${domain}/${domain}-architect-agent.md"
  context_file="architecture/${domain}/${domain}-architect-context.md"
  draft_file="architecture/${domain}/${domain}-architect-context_draft.md"
  openrouter_model="$(get_openrouter_model "$domain")"
  apigateway_model="$(get_apigateway_model "$domain")"
  def_val="$(get_definition "$domain")"
  title_val="$(capitalize "$domain")"

  if [ ! -f "$agent_file" ]; then
    cat << EOF > "$agent_file"
models:
  openrouter: ${openrouter_model}
  apigateway: ${apigateway_model}

definition: "${def_val}"

instructions:
  - "La logique est plus prioritaire que le détail technique."
  - "Ton contexte principal se trouve dans ./${domain}-architect-context.md que tu dois considérer très sérieusement."
  - "Quand une session commence, tu charges complètement ton contexte (expliqué avant). On échange profondément sur un sujet ; si un élément est concluant, je te demande de l'ajouter comme un seul point (- ...) dans ./${domain}-architect-context.md d'une manière explicite et compacte pour que ce dernier soit suffisant afin d'être compris dans le contexte. Sinon tu ne fais rien, ou je te demande de le mettre dans ./${domain}-architect-context_draft.md pour être repris dans d'autres sessions. Le fichier draft est censé être nettoyé et vide à chaque fois."
  - "Quand une session commence, tu vérifies si ./${domain}-architect-context_draft.md est vide pour commencer un nouveau sujet ; sinon tu me dis qu'il y a un sujet en cours."
EOF
    echo "  créé : $agent_file"
  else
    migrate_agent_models "$agent_file" "$openrouter_model" "$apigateway_model"
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
# 5. Credentials locaux : .env (git-ignoré) créé depuis le modèle si absent,
#    puis complété avec les clés des deux voies si elles manquent.
# ---------------------------------------------------------------------------
ENV_FILE=".omp/.env"
if [ ! -f "$ENV_FILE" ]; then
  cp .omp/.env.example "$ENV_FILE"
fi

for key in OPENROUTER_API_KEY ALTO_STUDIO_TOKEN; do
  if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$ENV_FILE"; then
    printf '\n%s=\n' "$key" >> "$ENV_FILE"
    echo "ACTION REQUISE : renseigne ${key} dans ${ENV_FILE}."
  elif ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[^[:space:]]" "$ENV_FILE"; then
    echo "INFO : ${key} est vide dans ${ENV_FILE} — la voie correspondante sera indisponible."
  fi
done

echo
echo "Préparation terminée dans $ROOT"
echo "Deux voies disponibles au démarrage : Amundi API Gateway ou OpenRouter."
echo "Lance une session avec : ./omp-arch.sh"