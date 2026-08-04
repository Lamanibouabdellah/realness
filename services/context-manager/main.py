"""
services/context-manager/main.py

Point d'entrée du service context-manager.
Lance EventConsumer et FsWatcher en parallèle.
"""

import asyncio
import os
import signal

import redis.asyncio as aioredis

from event_consumer import EventConsumer
from fs_watcher import FsWatcher
from state_builder import StateBuilder

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")


async def main() -> None:
    print("[context-manager] démarrage...")

    redis = await aioredis.from_url(REDIS_URL, decode_responses=True)

    state    = StateBuilder(redis)
    consumer = EventConsumer(redis, state)
    watcher  = FsWatcher(redis, state)

    # Arrêt propre sur SIGTERM (Docker stop)
    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _handle_signal():
        print("\n[context-manager] signal reçu — arrêt...")
        stop_event.set()

    loop.add_signal_handler(signal.SIGTERM, _handle_signal)
    loop.add_signal_handler(signal.SIGINT, _handle_signal)

    tasks = [
        asyncio.create_task(consumer.run(), name="event-consumer"),
        asyncio.create_task(watcher.run(),  name="fs-watcher"),
        asyncio.create_task(stop_event.wait(), name="stop-signal"),
    ]

    # Arrêt dès que le stop_event est déclenché OU qu'une tâche plante
    done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)

    for task in pending:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    await redis.aclose()
    print("[context-manager] arrêté proprement")


if __name__ == "__main__":
    asyncio.run(main())