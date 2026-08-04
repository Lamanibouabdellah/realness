"""
services/graph-registry/main.py

Point d'entrée du graph-registry.
"""

import asyncio
import logging
import os
import signal

import redis.asyncio as aioredis

from registry import Registry

REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s — %(message)s",
    datefmt="%H:%M:%S",
)


async def main() -> None:
    logging.getLogger("graph-registry").info("démarrage...")

    redis = await aioredis.from_url(REDIS_URL, decode_responses=True)
    registry = Registry(redis)

    loop       = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _handle_signal():
        stop_event.set()

    loop.add_signal_handler(signal.SIGTERM, _handle_signal)
    loop.add_signal_handler(signal.SIGINT,  _handle_signal)

    tasks = [
        asyncio.create_task(registry.run(),       name="registry"),
        asyncio.create_task(stop_event.wait(),    name="stop-signal"),
    ]

    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)

    for task in tasks:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    await redis.aclose()
    logging.getLogger("graph-registry").info("arrêté proprement")


if __name__ == "__main__":
    asyncio.run(main())
