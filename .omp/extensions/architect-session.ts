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
