"""
shared/agent_base.py

Classe de base abstraite pour tous les agents de la plateforme.

ACCÈS ET CONTEXTE
─────────────────
L'accès au workspace est déclaré dans agent.yaml sous `workspace.access`.
Ce niveau détermine le contexte maximum injecté dans le LLM — rien de plus.

  none          → aucun contexte repo (AF, AF_P2P)
  read_headers  → specs/*.md + tous les .h (via filesystem, git non requis)
  read_all      → specs/*.md + arborescence + git log + fichiers clés
  read_write    → tout ci-dessus + diff récent (D, T)

GIT : AUCUN COMMIT DEPUIS LES AGENTS
──────────────────────────────────────
Les agents n'exécutent jamais git directement.
Ils publient des demandes sur les streams Redis gérés par git-bridge :

  await self.request_commit(message, files, spec_at="", spec_af="")
  await self.request_tag(tag_name)

GIT_ROOT vs WORKSPACE_PATH
──────────────────────────
  WORKSPACE_PATH = dossier de travail du framework C (ex: /workspace/realness)
  GIT_ROOT       = racine du dépôt git (ex: /workspace)
  _GIT_SCOPE     = WORKSPACE_PATH relatif à GIT_ROOT (ex: "realness")

  Pour les agents n'ayant que le dossier realness/ monté (AT, T, context-manager) :
    GIT_ROOT == WORKSPACE_PATH  →  _GIT_SCOPE = ""  →  pas de préfixe ajouté
"""

import asyncio
import json
import os
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import aiohttp
import redis.asyncio as aioredis
import yaml

# ─── Constantes d'environnement ───────────────────────────────────────────────

WORKSPACE_PATH  = Path(os.getenv("WORKSPACE_PATH", "/realness"))
SPECS_PATH      = WORKSPACE_PATH / "specs"
REDIS_URL       = os.getenv("REDIS_URL", "redis://redis:6379")
OPENROUTER_URL  = "https://openrouter.ai/api/v1/chat/completions"
HEARTBEAT_SEC   = 10
STREAM_BLOCK_MS = 1000

# Racine du dépôt git — peut différer de WORKSPACE_PATH dans le monorepo
GIT_ROOT = Path(os.getenv("GIT_ROOT", str(WORKSPACE_PATH)))

# Préfixe de WORKSPACE_PATH dans le dépôt (ex: "realness")
# Utilisé pour scoper les commandes git et préfixer les paths dans git:commits
try:
    _git_scope_raw = str(WORKSPACE_PATH.relative_to(GIT_ROOT))
    _GIT_SCOPE     = "" if _git_scope_raw == "." else _git_scope_raw
except ValueError:
    _GIT_SCOPE = ""

# Hiérarchie des niveaux d'accès (ordre croissant de permissions)
ACCESS_LEVELS = ["none", "read_headers", "read_all", "read_write"]


# ─── Helpers module-level ──────────────────────────────────────────────────────

def _strip_scope_prefix(text: str, scope: str) -> str:
    """
    Supprime le préfixe 'scope/' sur chaque ligne de sortie git.
    Ex: "realness/src/main.c" → "src/main.c"
    Permet d'afficher au LLM des chemins relatifs à son WORKSPACE_PATH.
    """
    if not scope:
        return text
    prefix = scope + "/"
    return "\n".join(
        line[len(prefix):] if line.startswith(prefix) else line
        for line in text.splitlines()
    )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ─── Classe de base ────────────────────────────────────────────────────────────

class AgentBase(ABC):

    def __init__(self, config_path: str = "agent.yaml") -> None:
        config_file = Path(config_path)
        if not config_file.exists():
            raise FileNotFoundError(f"agent.yaml introuvable : {config_path}")

        with open(config_file) as f:
            self.config: dict = yaml.safe_load(f)

        self.id:             str       = self.config["id"]
        self.name:           str       = self.config["name"]
        self.llm_config:     dict      = self.config["llm"]
        self.subscriptions:  list[str] = self.config.get("subscriptions", [])
        self.sub_agents:     list[str] = self.config.get("can_delegate_to", [])
        self.capabilities:   list[str] = self.config.get("capabilities", [])
        self.phases:         list[str] = self.config.get("phases", [])

        workspace_cfg              = self.config.get("workspace", {})
        self.workspace_access: str = workspace_cfg.get("access", "none")

        if self.workspace_access not in ACCESS_LEVELS:
            raise ValueError(
                f"[{self.id}] workspace.access invalide : '{self.workspace_access}'. "
                f"Valeurs acceptées : {ACCESS_LEVELS}"
            )

        self._redis:          Optional[aioredis.Redis] = None
        self._running:        bool                     = False
        self._consumer_group: str                      = f"group:{self.id}"

    # ──────────────────────────────────────────────────────────────────────────
    # LIFECYCLE
    # ──────────────────────────────────────────────────────────────────────────

    async def start(self) -> None:
        self._redis   = await aioredis.from_url(REDIS_URL, decode_responses=True)
        self._running = True

        for attempt in range(1, 11):
            try:
                await self._redis.ping()
                break
            except Exception as e:
                print(f"[{self.id}] Redis non prêt ({attempt}/10) : {e}")
                await asyncio.sleep(2)
        else:
            raise RuntimeError(f"[{self.id}] Impossible de joindre Redis")

        await self._register()
        await self._ensure_consumer_groups()
        print(
            f"[{self.id}] démarré — accès: {self.workspace_access}"
            f" — écoute: {self.subscriptions}"
        )

        await asyncio.gather(
            self._message_loop(),
            self._heartbeat_loop(),
        )

    async def stop(self) -> None:
        self._running = False
        if self._redis:
            await self._redis.hset(f"agents:{self.id}", "status", "offline")
            await self._redis.aclose()

    # ──────────────────────────────────────────────────────────────────────────
    # REGISTRATION & HEARTBEAT
    # ──────────────────────────────────────────────────────────────────────────

    async def _register(self) -> None:
        await self._redis.hset(f"agents:{self.id}", mapping={
            "id":               self.id,
            "name":             self.name,
            "status":           "online",
            "workspace_access": self.workspace_access,
            "capabilities":     json.dumps(self.capabilities),
            "can_delegate_to":  json.dumps(self.sub_agents),
            "phases":           json.dumps(self.phases),
            "subscriptions":    json.dumps(self.subscriptions),
            "registered_at":    _now(),
        })
        await self._redis.sadd("agents:index", self.id)
        print(f"[{self.id}] enregistré ✓")

    async def _heartbeat_loop(self) -> None:
        while self._running:
            await self._redis.hset(f"agents:{self.id}", "last_heartbeat", _now())
            await asyncio.sleep(HEARTBEAT_SEC)

    # ──────────────────────────────────────────────────────────────────────────
    # REDIS STREAMS
    # ──────────────────────────────────────────────────────────────────────────

    async def _ensure_consumer_groups(self) -> None:
        for stream in self.subscriptions:
            try:
                await self._redis.xgroup_create(
                    stream, self._consumer_group, id="0", mkstream=True
                )
            except aioredis.ResponseError as e:
                if "BUSYGROUP" not in str(e):
                    raise

    async def _message_loop(self) -> None:
        while self._running:
            for stream in self.subscriptions:
                try:
                    results = await self._redis.xreadgroup(
                        groupname=self._consumer_group,
                        consumername=self.id,
                        streams={stream: ">"},
                        count=1,
                        block=STREAM_BLOCK_MS,
                    )
                    if not results:
                        continue
                    for _, messages in results:
                        for msg_id, data in messages:
                            message = json.loads(data["envelope"])
                            try:
                                await self.handle_task(message)
                            except Exception as e:
                                print(f"[{self.id}] erreur handle_task : {e}")
                            finally:
                                await self._redis.xack(
                                    stream, self._consumer_group, msg_id
                                )
                except aioredis.RedisError as e:
                    print(f"[{self.id}] erreur Redis : {e}")
                    await asyncio.sleep(1)

    async def publish(
        self,
        to: str,
        payload: dict,
        msg_type: str = "task",
        parent_message_id: Optional[str] = None,
    ) -> str:
        message_id = str(uuid.uuid4())
        envelope = {
            "message_id":        message_id,
            "from":              self.id,
            "to":                to,
            "type":              msg_type,
            "payload":           payload,
            "timestamp":         _now(),
            "parent_message_id": parent_message_id,
        }
        raw = {"envelope": json.dumps(envelope)}
        await self._redis.xadd(f"tasks.{to}", raw)
        await self._redis.xadd("events:log", raw)
        return message_id

    # ──────────────────────────────────────────────────────────────────────────
    # GIT BRIDGE — délégation de toutes les opérations git
    # ──────────────────────────────────────────────────────────────────────────

    async def request_commit(
        self,
        message: str,
        files: list[str],
        spec_at: str = "",
        spec_af: str = "",
    ) -> None:
        """
        Publie une demande de commit vers git-bridge (stream `git:commits`).

        `files` sont relatifs à WORKSPACE_PATH (ex: "src/init.c").
        Le préfixe _GIT_SCOPE est ajouté automatiquement pour les rendre
        relatifs à GIT_ROOT (ex: "realness/src/init.c"), comme attendu par
        `git add`.

        L'identité git, le message structuré et le commit lui-même
        sont entièrement gérés par git-bridge — jamais ici.
        """
        phase     = await self._redis.get("phase:current") or "?"
        git_files = [
            f"{_GIT_SCOPE}/{f}" if _GIT_SCOPE else f
            for f in files
        ]
        payload = {
            "agent":   self.id,
            "phase":   phase,
            "message": message,
            "files":   git_files,
            "spec_at": spec_at,
            "spec_af": spec_af,
        }
        await self._redis.xadd("git:commits", {"data": json.dumps(payload)})
        print(f"[{self.id}] commit demandé → [{self.id}][{phase}] {message[:60]}")

    async def request_tag(self, tag_name: str) -> None:
        """Publie une demande de tag git vers git-bridge (stream `git:tags`)."""
        await self._redis.xadd("git:tags", {"data": json.dumps({"tag": tag_name})})
        print(f"[{self.id}] tag demandé → {tag_name}")

    # ──────────────────────────────────────────────────────────────────────────
    # CONTEXTE WORKSPACE — respecte workspace.access
    # ──────────────────────────────────────────────────────────────────────────

    async def get_agent_context(self) -> str:
        """
        Retourne le contexte à injecter dans le LLM de cet agent.
        Strictement limité par workspace.access déclaré dans agent.yaml.

          none          → "" (chaîne vide)
          read_headers  → specs/*.md  +  .h via filesystem (git non requis)
          read_all      → specs/*.md  +  arborescence  +  git log  +  fichiers clés
          read_write    → read_all    +  diff récent
        """
        if self.workspace_access == "none":
            return ""

        parts: list[str] = []

        specs = await self._read_specs()
        if specs:
            parts.append(f"=== SPÉCIFICATIONS ===\n{specs}")

        if self.workspace_access == "read_headers":
            # Pas de git requis — lecture directe via Path.rglob
            headers = await self._read_h_files()
            if headers:
                parts.append(f"=== INTERFACES (.h) ===\n{headers}")
            return "\n\n".join(parts)

        # read_all / read_write : nécessite git
        scope_args = ["--", _GIT_SCOPE] if _GIT_SCOPE else []

        tree_raw = await self._run_cmd(["git", "ls-files"] + scope_args)
        # Supprime le préfixe scope pour que le LLM voie "src/main.c" et non "realness/src/main.c"
        tree = _strip_scope_prefix(tree_raw, _GIT_SCOPE)

        log = await self._run_cmd([
            "git", "log", "--oneline", "-10",
            "--format=%h  [%ae]  %s",
        ] + scope_args)

        parts.append(f"=== ARBORESCENCE ===\n{tree or '(vide)'}")
        parts.append(f"=== HISTORIQUE (10 derniers commits) ===\n{log or '(aucun)'}")

        key_files = await self._read_key_files()
        if key_files:
            parts.append(f"=== FICHIERS CLÉS ===\n{key_files}")

        if self.workspace_access == "read_all":
            return "\n\n".join(parts)

        # read_write : + diff récent
        diff  = await self._run_cmd(
            ["git", "diff", "HEAD~3..HEAD", "--stat", "--no-color"] + scope_args
        )
        patch = await self._run_cmd(
            ["git", "diff", "HEAD~3..HEAD", "--no-color"] + scope_args
        )
        if len(patch) > 4000:
            patch = patch[:4000] + "\n... [diff tronqué]"
        if diff:
            parts.append(
                f"=== DIFF RÉCENT (3 derniers commits) ===\n{diff}\n\n{patch}"
            )

        return "\n\n".join(parts)

    async def _read_specs(self) -> str:
        """Lit tous les fichiers *.md dans realness/specs/."""
        if not SPECS_PATH.exists():
            return ""
        sections = []
        for md_file in sorted(SPECS_PATH.glob("*.md")):
            try:
                content = md_file.read_text(encoding="utf-8").strip()
                if content:
                    sections.append(f"--- {md_file.name} ---\n{content}")
            except Exception:
                pass
        return "\n\n".join(sections)

    async def _read_h_files(self, max_lines_per_file: int = 200) -> str:
        """Lit tous les .h du workspace (interfaces C)."""
        if self.workspace_access == "read_headers":
            # git non disponible pour ces agents → filesystem
            path_pairs = [
                (str(p.relative_to(WORKSPACE_PATH)), p)
                for p in sorted(WORKSPACE_PATH.rglob("*.h"))
            ]
        else:
            # git disponible — scope à WORKSPACE_PATH
            scope_args = ["--", _GIT_SCOPE] if _GIT_SCOPE else []
            raw        = await self._run_cmd(["git", "ls-files"] + scope_args)
            h_git      = [f.strip() for f in raw.splitlines() if f.strip().endswith(".h")]
            path_pairs = [
                (
                    _strip_scope_prefix(rel, _GIT_SCOPE),  # chemin affiché au LLM
                    GIT_ROOT / rel,                          # chemin absolu sur disque
                )
                for rel in h_git
            ]

        sections = []
        for display_name, abs_path in path_pairs:
            if not abs_path.exists():
                continue
            try:
                lines   = abs_path.read_text(encoding="utf-8").splitlines()
                content = "\n".join(lines[:max_lines_per_file])
                if len(lines) > max_lines_per_file:
                    content += f"\n... [{len(lines) - max_lines_per_file} lignes tronquées]"
                sections.append(f"--- {display_name} ---\n{content}")
            except Exception:
                pass
        return "\n\n".join(sections)

    async def _read_key_files(self, max_files: int = 4, max_lines: int = 150) -> str:
        """Headers + fichiers récemment modifiés (dédupliqués, limités)."""
        scope_args = ["--", _GIT_SCOPE] if _GIT_SCOPE else []

        h_raw   = await self._run_cmd(["git", "ls-files"] + scope_args)
        rec_raw = await self._run_cmd(
            ["git", "log", "--name-only", "--format=", "-2"] + scope_args
        )

        # Chemins affichés au LLM (relatifs à WORKSPACE_PATH)
        h_files   = [
            _strip_scope_prefix(f.strip(), _GIT_SCOPE)
            for f in h_raw.splitlines()
            if f.strip().endswith(".h")
        ]
        rec_files = [
            _strip_scope_prefix(f.strip(), _GIT_SCOPE)
            for f in rec_raw.splitlines()
            if f.strip()
        ]

        seen:       set[str]  = set()
        candidates: list[str] = []
        for f in h_files + rec_files:
            if f not in seen:
                seen.add(f)
                candidates.append(f)
            if len(candidates) >= max_files:
                break

        sections = []
        for rel in candidates:
            path = WORKSPACE_PATH / rel
            if not path.exists():
                continue
            try:
                lines   = path.read_text(encoding="utf-8").splitlines()
                content = "\n".join(lines[:max_lines])
                if len(lines) > max_lines:
                    content += f"\n... [{len(lines) - max_lines} lignes tronquées]"
                sections.append(f"--- {rel} ---\n{content}")
            except Exception:
                pass
        return "\n\n".join(sections)

    # ──────────────────────────────────────────────────────────────────────────
    # LLM (OpenRouter)
    # ──────────────────────────────────────────────────────────────────────────

    async def call_llm(self, user_prompt: str, extra_context: str = "") -> str:
        api_key       = os.environ["OPENROUTER_API_KEY"]
        system_prompt = self.llm_config.get("system_prompt", "")
        if extra_context:
            system_prompt += f"\n\n{extra_context}"

        async with aiohttp.ClientSession() as session:
            async with session.post(
                OPENROUTER_URL,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type":  "application/json",
                },
                json={
                    "model":       self.llm_config["model"],
                    "temperature": self.llm_config.get("temperature", 0.3),
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user",   "content": user_prompt},
                    ],
                },
            ) as resp:
                resp.raise_for_status()
                data = await resp.json()
                return data["choices"][0]["message"]["content"]

    # ──────────────────────────────────────────────────────────────────────────
    # UTILITAIRE — subprocess
    # ──────────────────────────────────────────────────────────────────────────

    async def _run_cmd(self, cmd: list[str]) -> str:
        """
        Exécute une commande en subprocess.
        Les commandes git s'exécutent depuis GIT_ROOT,
        les autres depuis WORKSPACE_PATH.
        """
        cwd  = GIT_ROOT if (cmd and cmd[0] == "git") else WORKSPACE_PATH
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        out = stdout.decode().strip()
        return out if out else stderr.decode().strip()

    # ──────────────────────────────────────────────────────────────────────────
    # ABSTRACT
    # ──────────────────────────────────────────────────────────────────────────

    @abstractmethod
    async def handle_task(self, message: dict) -> None:
        """
        Traite un message entrant.
        Chaque agent implémente uniquement cette méthode.

        message = {
            message_id, from, to, type, payload,
            timestamp, parent_message_id
        }
        """