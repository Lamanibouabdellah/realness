"""
services/context-manager/state_builder.py

Maintient context:state dans Redis à partir des événements inter-agents
et des commits git détectés.

Clés Redis gérées :
  context:state           → Hash  { last_updated, last_from, last_to }
  context:agents:{id}     → Hash  { last_action_type, last_action_to, last_action_at }
  context:events:recent   → List  (100 derniers envelopes JSON, ordre LIFO)
  context:commits         → Sorted Set { JSON → timestamp }
"""

import json
import time
from datetime import datetime, timezone

import redis.asyncio as aioredis

MAX_RECENT_EVENTS = 100
MAX_COMMITS       = 50


class StateBuilder:

    def __init__(self, redis: aioredis.Redis) -> None:
        self._redis = redis

    async def update_from_event(self, envelope: dict) -> None:
        """Met à jour Redis après réception d'un événement inter-agents."""
        pipe = self._redis.pipeline()

        # État global
        pipe.hset("context:state", mapping={
            "last_updated": envelope["timestamp"],
            "last_from":    envelope["from"],
            "last_to":      envelope["to"],
            "last_type":    envelope["type"],
        })

        # Dernière action par agent émetteur
        pipe.hset(f"context:agents:{envelope['from']}", mapping={
            "last_action_type": envelope["type"],
            "last_action_to":   envelope["to"],
            "last_action_at":   envelope["timestamp"],
        })

        # Journal des 100 derniers événements (LIFO)
        pipe.lpush("context:events:recent", json.dumps(envelope))
        pipe.ltrim("context:events:recent", 0, MAX_RECENT_EVENTS - 1)

        await pipe.execute()

    async def update_from_commit(
        self,
        commit_hash: str,
        author: str,
        message: str,
    ) -> None:
        """Enregistre un commit git dans context:commits (Sorted Set)."""
        value = json.dumps({
            "hash":    commit_hash,
            "author":  author,
            "message": message,
            "at":      _now(),
        })
        await self._redis.zadd("context:commits", {value: time.time()})
        # Garde uniquement les MAX_COMMITS plus récents
        await self._redis.zremrangebyrank("context:commits", 0, -(MAX_COMMITS + 1))


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
