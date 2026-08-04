"""
services/context-manager/fs_watcher.py

Surveille le répertoire /workspace en temps réel via watchdog.

Responsabilités :
  - Détecter les créations / modifications / suppressions de fichiers
  - Mettre à jour context:fs:changes dans Redis
  - Détecter les nouveaux commits git (polling git log)
  - Alerter si un fichier reste modifié sans commit après STALE_THRESHOLD_SEC
"""

import asyncio
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from threading import Thread

import redis.asyncio as aioredis
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from state_builder import StateBuilder

WORKSPACE_PATH     = Path(os.getenv("WORKSPACE_PATH", "/realness"))
STALE_THRESHOLD_SEC = 30
GIT_POLL_SEC        = 5


class _QueueHandler(FileSystemEventHandler):
    """Handler watchdog : pousse les événements FS dans une asyncio.Queue."""

    def __init__(self, queue: asyncio.Queue, loop: asyncio.AbstractEventLoop) -> None:
        self._queue = queue
        self._loop  = loop

    def _push(self, event_type: str, path: str) -> None:
        if ".git" not in path:  # ignorer les changements internes git
            self._loop.call_soon_threadsafe(
                self._queue.put_nowait,
                {"type": event_type, "path": path},
            )

    def on_created(self, event):
        if not event.is_directory:
            self._push("created", event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self._push("modified", event.src_path)

    def on_deleted(self, event):
        if not event.is_directory:
            self._push("deleted", event.src_path)


class FsWatcher:

    def __init__(self, redis: aioredis.Redis, state: StateBuilder) -> None:
        self._redis  = redis
        self._state  = state
        self._queue: asyncio.Queue = asyncio.Queue()
        # path relatif → timestamp (epoch) de la dernière modification non commitée
        self._pending: dict[str, float] = {}
        # dernier commit hash connu pour détecter les nouveaux commits
        self._last_commit_hash: str = ""

    async def run(self) -> None:
        """Lance watchdog dans un thread + les boucles asyncio de traitement."""
        loop    = asyncio.get_running_loop()
        handler = _QueueHandler(self._queue, loop)
        observer = Observer()
        observer.schedule(handler, str(WORKSPACE_PATH), recursive=True)
        observer.start()
        print(f"[fs-watcher] surveillance de {WORKSPACE_PATH} ✓")

        try:
            await asyncio.gather(
                self._process_fs_events(),
                self._poll_git_commits(),
                self._check_stale(),
            )
        finally:
            observer.stop()
            observer.join()

    # ─── Traitement des événements FS ────────────────────────────────────────

    async def _process_fs_events(self) -> None:
        while True:
            event = await self._queue.get()
            rel   = os.path.relpath(event["path"], WORKSPACE_PATH)

            # Mise à jour dans Redis
            await self._redis.hset("context:fs:changes", rel, json.dumps({
                "type": event["type"],
                "at":   _now(),
            }))

            if event["type"] in ("created", "modified"):
                self._pending[rel] = asyncio.get_event_loop().time()

            elif event["type"] == "deleted":
                self._pending.pop(rel, None)
                await self._redis.hdel("context:fs:changes", rel)

            print(f"[fs-watcher] {event['type'].upper():10s} {rel}")

    # ─── Polling git log ─────────────────────────────────────────────────────

    async def _poll_git_commits(self) -> None:
        """Détecte les nouveaux commits toutes les GIT_POLL_SEC secondes."""
        while True:
            await asyncio.sleep(GIT_POLL_SEC)
            try:
                result = await asyncio.create_subprocess_exec(
                    "git", "log", "--oneline", "-1",
                    "--format=%H|%ae|%s",
                    cwd=WORKSPACE_PATH,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, _ = await result.communicate()
                line = stdout.decode().strip()

                if not line:
                    continue

                commit_hash, author, message = line.split("|", 2)

                if commit_hash != self._last_commit_hash:
                    self._last_commit_hash = commit_hash
                    await self._state.update_from_commit(commit_hash, author, message)

                    # Nettoie les fichiers marqués en attente (ils sont maintenant commités)
                    self._pending.clear()
                    print(f"[fs-watcher] GIT COMMIT  [{author}] {message[:60]}")

            except Exception as e:
                print(f"[fs-watcher] erreur git poll : {e}")

    # ─── Alertes fichiers non commités ──────────────────────────────────────

    async def _check_stale(self) -> None:
        """Alerte si un fichier est modifié sans commit depuis STALE_THRESHOLD_SEC."""
        while True:
            await asyncio.sleep(10)
            now   = asyncio.get_event_loop().time()
            stale = [
                path for path, ts in list(self._pending.items())
                if (now - ts) > STALE_THRESHOLD_SEC
            ]
            for path in stale:
                print(f"[fs-watcher] ⚠️  {path} modifié sans commit depuis >{STALE_THRESHOLD_SEC}s")
                del self._pending[path]  # ne pas répéter l'alerte


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()