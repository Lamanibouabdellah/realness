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
