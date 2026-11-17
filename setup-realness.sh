#!/usr/bin/env bash
set -euo pipefail

if [ "$(basename "$PWD")" != "realness" ]; then
  echo "Erreur : placez-vous dans le dossier 'realness/' avant de lancer ce script (actuel : '$PWD')." >&2
  exit 1
fi

mkdir -p .omp/extensions
mkdir -p \
  architecture/network \
  architecture/security \
  architecture/compatibility \
  architecture/node \
  architecture/optimization

# 1. Configuration OMP isolée (OpenRouter uniquement, aucune config système)
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
  - "openrouter/*:free"
  - "openrouter/free"

modelRoles:
  default: openrouter/free
EOF

# 2. Provider OpenRouter (utilise la variable système OPENROUTER_API_KEY)
cat << 'EOF' > .omp/models.yml
providers:
  openrouter:
    baseUrl: https://openrouter.ai/api/v1
    api: openai-completions
    apiKey: OPENROUTER_API_KEY
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

cat << 'EOF' > .omp/.gitignore
sessions/
agent.db*
*.log
EOF

# 3. Extension OMP : sélecteur d'agent au démarrage + rechargement à chaud
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
      const available = ctx.modelRegistry.getAvailable();
      const resolved = agent.model.includes("/")
        ? (() => {
            const [provider, ...rest] = agent.model.split("/");
            return ctx.modelRegistry.find(provider, rest.join("/"));
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
      if (!selected) return { action: "handled" };
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

# 4. Génération des 5 domaines d'architecture
get_model() {
  case "$1" in
    network) echo "openrouter/dots-studio/dots-3-note-preview:free" ;;
    security) echo "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free" ;;
    compatibility) echo "openrouter/cohere/north-mini-code:free" ;;
    node) echo "openrouter/particle-ai/particle-1:free" ;;
    optimization) echo "openrouter/particle-ai/particle-1:free" ;;
  esac
}

get_definition() {
  case "$1" in
    network) echo "Architecte réseau : topologie, protocoles, routage, latence et résilience des communications" ;;
    security) echo "Architecte sécurité : authentification, autorisation, chiffrement, surface d'attaque et conformité" ;;
    compatibility) echo "Architecte compatibilité : rétrocompatibilité, contrats d'API, versions et interopérabilité" ;;
    node) echo "Architecte Node : runtime Node.js, gestion mémoire/event-loop, dépendances et configuration des nœuds" ;;
    optimization) echo "Architecte optimisation : performances, profiling, caching et réduction des coûts CPU/mémoire/I/O" ;;
  esac
}

capitalize() {
  printf '%s' "$1" | awk '{print toupper(substr($0,1,1)) substr($0,2)}'
}

for domain in network security compatibility node optimization; do
  agent_file="architecture/${domain}/${domain}-architect-agent.md"
  context_file="architecture/${domain}/${domain}-architect-context.md"
  model_val="$(get_model "$domain")"
  def_val="$(get_definition "$domain")"
  title_val="$(capitalize "$domain")"

  cat << EOF > "$agent_file"
model: ${model_val}
definition: "${def_val}"
instructions:
  - "Appuie systématiquement tes analyses sur ${domain}-architect-context.md et le code existant."
  - "Signale tout écart entre l'implémentation et les règles d'architecture du domaine ${domain}."
  - "Propose des décisions concrètes, chiffrées et directement actionnables."
EOF

  cat << EOF > "$context_file"
# Contexte Architecture — ${title_val}

## Périmètre et objectifs
- Décrire ici l'architecture cible et les invariants du domaine **${domain}**.

## Contraintes techniques
- Lister les contraintes non négociables (protocoles, versions, SLA, limites).

## Décisions d'architecture (ADR)
- Documenter les choix structurants et leurs justifications.
EOF
done

echo "Préparation terminée dans $PWD."
