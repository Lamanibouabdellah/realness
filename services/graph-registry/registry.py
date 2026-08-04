"""
services/graph-registry/registry.py

Cœur du graph-registry.

Deux boucles concurrentes :
  - TopologyLoop : relit agents:index toutes les TOPOLOGY_POLL_SEC secondes,
                   reconstruit graph:edges et graph:capabilities si changement détecté.
  - HealthLoop   : vérifie les heartbeats toutes les HEALTH_CHECK_SEC secondes,
                   met à jour graph:status pour chaque agent.

Clés Redis écrites :
  graph:edges          → List  [ JSON {"from": id, "to": id} ]
  graph:capabilities   → Hash  { capability → JSON [agent_ids] }
  graph:status         → Hash  { agent_id   → "online" | "stale" | "offline" }
  graph:last_rebuilt   → String (timestamp ISO)
"""

import asyncio
import json
import logging
from datetime import datetime, timezone

import redis.asyncio as aioredis

TOPOLOGY_POLL_SEC = 5
HEALTH_CHECK_SEC  = 15
HEARTBEAT_TIMEOUT = 30  # secondes sans heartbeat → statut "stale"

log = logging.getLogger("graph-registry")


class Registry:

    def __init__(self, redis: aioredis.Redis) -> None:
        self._redis = redis
        # Cache local pour détecter les changements sans réécrire à chaque poll
        self._known_agents: set[str] = set()

    async def run(self) -> None:
        log.info("démarré ✓")
        await asyncio.gather(
            self._topology_loop(),
            self._health_loop(),
        )

    # ──────────────────────────────────────────────────────────────────────────
    # TOPOLOGY
    # ──────────────────────────────────────────────────────────────────────────

    async def _topology_loop(self) -> None:
        while True:
            try:
                await self._rebuild_topology()
            except Exception as e:
                log.error(f"erreur topology : {e}")
            await asyncio.sleep(TOPOLOGY_POLL_SEC)

    async def _rebuild_topology(self) -> None:
        """
        Relit agents:index et reconstruit le graph si l'ensemble d'agents a changé.
        Reconstruction toujours complète (pas de diff partiel) — simple et fiable.
        """
        agent_ids: set[str] = await self._redis.smembers("agents:index")

        if agent_ids == self._known_agents:
            return  # rien de nouveau, on évite des écritures inutiles

        new_agents  = agent_ids - self._known_agents
        lost_agents = self._known_agents - agent_ids

        for aid in new_agents:
            log.info(f"nouvel agent : {aid}")
        for aid in lost_agents:
            log.info(f"agent retiré de l'index : {aid}")

        self._known_agents = agent_ids

        edges: list[str]                   = []
        capabilities: dict[str, list[str]] = {}

        for agent_id in agent_ids:
            data = await self._redis.hgetall(f"agents:{agent_id}")
            if not data:
                continue

            sub_agents  = json.loads(data.get("sub_agents",   "[]"))
            agent_caps  = json.loads(data.get("capabilities", "[]"))

            # Edge : cet agent peut déléguer à ses sous-agents
            for sub in sub_agents:
                edges.append(json.dumps({"from": agent_id, "to": sub}))

            # Index des capabilities
            for cap in agent_caps:
                capabilities.setdefault(cap, []).append(agent_id)

        # Écriture atomique dans Redis
        pipe = self._redis.pipeline()

        pipe.delete("graph:edges")
        if edges:
            pipe.rpush("graph:edges", *edges)

        # Réécrit toutes les capabilities (delete + set pour éviter les doublons)
        pipe.delete("graph:capabilities")
        for cap, agents in capabilities.items():
            pipe.hset("graph:capabilities", cap, json.dumps(agents))

        pipe.set("graph:last_rebuilt", _now())

        await pipe.execute()
        log.info(
            f"topologie reconstruite — "
            f"{len(agent_ids)} agent(s), {len(edges)} edge(s), "
            f"{len(capabilities)} capabilit(ies)"
        )

    # ──────────────────────────────────────────────────────────────────────────
    # HEALTH CHECK
    # ──────────────────────────────────────────────────────────────────────────

    async def _health_loop(self) -> None:
        while True:
            await asyncio.sleep(HEALTH_CHECK_SEC)
            try:
                await self._check_health()
            except Exception as e:
                log.error(f"erreur health check : {e}")

    async def _check_health(self) -> None:
        """
        Pour chaque agent connu, calcule son statut réel à partir de last_heartbeat.

        Statuts possibles :
          online  → heartbeat récent (< HEARTBEAT_TIMEOUT secondes)
          stale   → heartbeat trop ancien (agent peut-être planté)
          offline → l'agent s'est déclaré offline proprement
          unknown → pas encore de heartbeat enregistré
        """
        if not self._known_agents:
            return

        now  = datetime.now(timezone.utc)
        pipe = self._redis.pipeline()

        for agent_id in self._known_agents:
            data = await self._redis.hgetall(f"agents:{agent_id}")
            if not data:
                continue

            declared = data.get("status", "unknown")

            if declared == "offline":
                # L'agent s'est arrêté proprement (via AgentBase.stop())
                pipe.hset("graph:status", agent_id, "offline")
                continue

            last_hb = data.get("last_heartbeat")
            if not last_hb:
                pipe.hset("graph:status", agent_id, "unknown")
                continue

            try:
                hb_time = datetime.fromisoformat(last_hb)
                age_sec = (now - hb_time).total_seconds()
                status  = "online" if age_sec <= HEARTBEAT_TIMEOUT else "stale"
            except ValueError:
                status = "unknown"

            pipe.hset("graph:status", agent_id, status)

            if status == "stale":
                log.warning(f"{agent_id} : pas de heartbeat depuis >{HEARTBEAT_TIMEOUT}s")

        await pipe.execute()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
