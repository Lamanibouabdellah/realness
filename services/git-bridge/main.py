"""
services/git-bridge/main.py

Seul service autorisé à faire des opérations git sur le monorepo.

Écoute deux streams Redis :
  git:commits  → git add <files> + git commit avec message structuré
  git:tags     → git tag <name>

Format d'un commit request (JSON dans le champ "data") :
  {
    "agent":   "D",
    "phase":   "PD",
    "message": "Implémentation de realness_init()",
    "files":   ["realness/src/init.c", "realness/include/realness.h"],
    "spec_at": "realness_init doit initialiser le contexte en O(1)",
    "spec_af": "Fonction d'initialisation du moteur"
  }

Format d'un tag request :
  { "tag": "phase/PAF-1" }

Le commit message structuré résultant :
  [D][PD] Implémentation de realness_init()

  Agent: D
  Phase: PD
  Spec-AT: realness_init doit initialiser le contexte en O(1)
  Spec-AF: Fonction d'initialisation du moteur
  Files: realness/src/init.c, realness/include/realness.h

Volume requis : ./:/workspace (rw)
GIT_ROOT env var : /workspace (défaut)
"""

import asyncio
import json
import os
import subprocess
from pathlib import Path

import redis.asyncio as aioredis

# ─── Configuration ─────────────────────────────────────────────────────────────

REDIS_URL      = os.getenv("REDIS_URL", "redis://redis:6379")
REPO_ROOT      = Path(os.getenv("GIT_ROOT", "/workspace"))
# Identité git — définie une seule fois dans .env (GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL)
GIT_AUTHOR     = os.getenv("GIT_AUTHOR_NAME",  "agentic-platform")
GIT_EMAIL      = os.getenv("GIT_AUTHOR_EMAIL", "agentic@platform.local")
CONSUMER_GROUP = "git-bridge-group"
CONSUMER_NAME  = "git-bridge"

# ─── Helpers git ───────────────────────────────────────────────────────────────

def _git(args: list[str], with_identity: bool = False) -> subprocess.CompletedProcess:
    """Exécute une commande git depuis REPO_ROOT."""
    cmd = ["git", "-C", str(REPO_ROOT)]
    if with_identity:
        cmd += ["-c", f"user.name={GIT_AUTHOR}", "-c", f"user.email={GIT_EMAIL}"]
    cmd += args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout.strip():
        print(f"[git-bridge] {result.stdout.strip()}")
    if result.stderr.strip() and result.returncode != 0:
        print(f"[git-bridge] stderr: {result.stderr.strip()}")
    return result


def _has_staged_changes() -> bool:
    """Retourne True si des changements sont en attente de commit."""
    r = _git(["diff", "--cached", "--quiet"])
    return r.returncode != 0  # returncode 1 = des changements existent


# ─── Handlers ──────────────────────────────────────────────────────────────────

def handle_commit(payload: dict) -> None:
    """Traite une demande de commit structuré."""
    agent    = payload.get("agent", "?")
    phase    = payload.get("phase",  "?")
    message  = payload.get("message", "update")
    files    = payload.get("files",   [])
    spec_at  = payload.get("spec_at", "")
    spec_af  = payload.get("spec_af", "")

    # git add — fichiers spécifiés ou tout le workspace par défaut
    if files:
        _git(["add", "--"] + files)
    else:
        _git(["add", "-A"])

    if not _has_staged_changes():
        print(f"[git-bridge] [{agent}][{phase}] rien à committer — ignoré")
        return

    # Construction du message de commit structuré
    subject = f"[{agent}][{phase}] {message}"
    body_lines = [
        f"Agent: {agent}",
        f"Phase: {phase}",
    ]
    if spec_at:
        body_lines.append(f"Spec-AT: {spec_at}")
    if spec_af:
        body_lines.append(f"Spec-AF: {spec_af}")
    if files:
        body_lines.append(f"Files: {', '.join(files)}")

    full_message = subject + "\n\n" + "\n".join(body_lines)

    result = _git(["commit", "-m", full_message], with_identity=True)
    if result.returncode == 0:
        print(f"[git-bridge] ✓ commit : {subject}")
    else:
        print(f"[git-bridge] ✗ commit échoué : {result.stderr.strip()}")


def handle_tag(payload: dict) -> None:
    """Crée un tag git léger."""
    tag = payload.get("tag", "").strip()
    if not tag:
        print("[git-bridge] tag request sans nom — ignoré")
        return

    result = _git(["tag", tag])
    if result.returncode == 0:
        print(f"[git-bridge] ✓ tag créé : {tag}")
    else:
        # Le tag existe peut-être déjà (idempotent)
        print(f"[git-bridge] tag '{tag}' : {result.stderr.strip()}")


# ─── Boucle principale ─────────────────────────────────────────────────────────

async def main() -> None:
    redis = await aioredis.from_url(REDIS_URL, decode_responses=True)

    # Retry Redis
    for attempt in range(1, 11):
        try:
            await redis.ping()
            break
        except Exception as e:
            print(f"[git-bridge] Redis non prêt ({attempt}/10) : {e}")
            await asyncio.sleep(2)
    else:
        raise RuntimeError("[git-bridge] Impossible de joindre Redis")

    # Vérifie que REPO_ROOT est un dépôt git
    if not (REPO_ROOT / ".git").exists():
        raise RuntimeError(f"[git-bridge] {REPO_ROOT} n'est pas un dépôt git")

    # Création des consumer groups (id="$" : ne retraite pas l'historique au démarrage)
    for stream in ("git:commits", "git:tags"):
        try:
            await redis.xgroup_create(stream, CONSUMER_GROUP, id="$", mkstream=True)
        except aioredis.ResponseError as e:
            if "BUSYGROUP" not in str(e):
                raise

    print(f"[git-bridge] démarré ✓ — repo : {REPO_ROOT}")

    STREAMS = {"git:commits": handle_commit, "git:tags": handle_tag}

    while True:
        for stream, handler in STREAMS.items():
            try:
                results = await redis.xreadgroup(
                    groupname=CONSUMER_GROUP,
                    consumername=CONSUMER_NAME,
                    streams={stream: ">"},
                    count=1,
                    block=1000,
                )
                if not results:
                    continue
                for _, messages in results:
                    for msg_id, data in messages:
                        try:
                            payload = json.loads(data["data"])
                            handler(payload)
                        except Exception as e:
                            print(f"[git-bridge] erreur {stream} : {e}")
                        finally:
                            await redis.xack(stream, CONSUMER_GROUP, msg_id)
            except aioredis.RedisError as e:
                print(f"[git-bridge] erreur Redis : {e}")
                await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())