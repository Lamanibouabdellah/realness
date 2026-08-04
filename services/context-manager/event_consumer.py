"""
services/context-manager/event_consumer.py

Consomme le stream Redis `events:log` en continu.

Responsabilités :
  - Lire tous les événements publiés par les agents
  - Déléguer la mise à jour de l'état à StateBuilder
  - Afficher le live feed coloré dans stdout
  - Persister le dernier ID lu dans Redis (reprise après redémarrage)
"""

import json

import redis.asyncio as aioredis

from state_builder import StateBuilder

STREAM_KEY      = "events:log"
LAST_ID_KEY     = "context:consumer:last_id"
STREAM_BLOCK_MS = 1000
BATCH_SIZE      = 10

# Couleurs ANSI pour le live feed
_COLORS = {
    "task":   "\033[94m",   # bleu
    "result": "\033[92m",   # vert
    "event":  "\033[93m",   # jaune
    "error":  "\033[91m",   # rouge
}
_RESET = "\033[0m"
_DIM   = "\033[2m"
_BOLD  = "\033[1m"


class EventConsumer:

    def __init__(self, redis: aioredis.Redis, state: StateBuilder) -> None:
        self._redis = redis
        self._state = state

    async def run(self) -> None:
        """Boucle principale de consommation (ne s'arrête pas)."""
        # Reprise depuis le dernier ID connu (ou depuis maintenant si premier démarrage)
        last_id = await self._redis.get(LAST_ID_KEY) or "$"
        print(f"[event-consumer] démarré — reprise depuis id={last_id}")

        while True:
            try:
                results = await self._redis.xread(
                    {STREAM_KEY: last_id},
                    block=STREAM_BLOCK_MS,
                    count=BATCH_SIZE,
                )
                if not results:
                    continue

                for _, messages in results:
                    for msg_id, data in messages:
                        last_id = msg_id
                        envelope = json.loads(data["envelope"])
                        await self._process(envelope)

                # Persistance du curseur pour reprise après redémarrage
                await self._redis.set(LAST_ID_KEY, last_id)

            except Exception as e:
                print(f"[event-consumer] erreur : {e}")
                import asyncio
                await asyncio.sleep(1)

    async def _process(self, envelope: dict) -> None:
        """Traitement d'un événement : mise à jour état + live feed."""
        await self._state.update_from_event(envelope)
        _print_live(envelope)


# ─── Live feed ──────────────────────────────────────────────────────────────

def _print_live(envelope: dict) -> None:
    """Affiche une ligne formatée pour chaque événement inter-agents."""
    ts      = envelope.get("timestamp", "")[:19].replace("T", " ")
    from_   = envelope["from"].ljust(18)
    to_     = envelope["to"].ljust(18)
    etype   = envelope["type"]
    payload = envelope.get("payload", {})

    summary = (
        payload.get("instruction")
        or payload.get("result", "")
        or payload.get("message", "")
        or ""
    )
    summary = summary[:70].replace("\n", " ")
    if len(summary) == 70:
        summary = summary[:67] + "..."

    color = _COLORS.get(etype, "")
    print(
        f"{_DIM}[{ts}]{_RESET} "
        f"{_BOLD}{from_}{_RESET} "
        f"→ {to_}  "
        f"{color}[{etype}]{_RESET}  "
        f"{_DIM}{summary}{_RESET}"
    )
