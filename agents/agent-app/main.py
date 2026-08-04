"""
agents/agent-app/main.py — Phase Controller principal.

Remplace l'ancien dispatcher LLM. Orchestre les phases PAF → PAT → PD → PT.
Toutes les délégations vers les spécialistes sont validées par l'utilisateur.

Commandes CLI :
  phase PAF   → démarrer / reprendre la phase PAF
  phase PAT   → démarrer / reprendre la phase PAT
  phase PD    → démarrer / reprendre la phase PD
  phase PT    → démarrer / reprendre la phase PT
  status      → afficher l'état courant
  history     → afficher l'historique de la phase courante
  exit        → quitter
"""

import asyncio
import json
import os
import signal
import uuid
from datetime import datetime, timezone
from typing import Optional

import redis.asyncio as aioredis

from agent_base import AgentBase
from cli import (
    display_welcome, display_phase_header, display_status,
    display_error, display_agent_response,
)
from phase_controller import PhaseController


class AgentApp(AgentBase):

    def __init__(self) -> None:
        super().__init__("agent.yaml")
        self._controller: Optional[PhaseController] = None
        self._pending: dict[str, asyncio.Future] = {}

    # ──────────────────────────────────────────────────────────────────────────
    # START (override pour ajouter le CLI loop)
    # ──────────────────────────────────────────────────────────────────────────

    async def start(self) -> None:
        self._redis   = await aioredis.from_url(
            os.getenv("REDIS_URL", "redis://redis:6379"), decode_responses=True
        )
        self._running = True

        for attempt in range(1, 11):
            try:
                await self._redis.ping()
                break
            except Exception as e:
                print(f"[agent-app] Redis non prêt ({attempt}/10) : {e}")
                await asyncio.sleep(2)

        await self._register()
        await self._ensure_consumer_groups()

        self._controller = PhaseController(self._redis, self)

        display_welcome()

        await asyncio.gather(
            self._message_loop(),
            self._heartbeat_loop(),
            self._cli_loop(),
        )

    # ──────────────────────────────────────────────────────────────────────────
    # handle_task : résultats entrants des agents
    # ──────────────────────────────────────────────────────────────────────────

    async def handle_task(self, message: dict) -> None:
        parent_id = message.get("parent_message_id")
        payload   = message.get("payload", {})
        future    = self._pending.pop(parent_id, None) if parent_id else None

        if future and not future.done():
            future.set_result(payload)
        else:
            print(f"\n[agent-app] message non sollicité de {message.get('from')}")

    # ──────────────────────────────────────────────────────────────────────────
    # send_and_wait : utilisé par PhaseController
    # ──────────────────────────────────────────────────────────────────────────

    async def send_and_wait(self, to: str, payload: dict, timeout: int = 300) -> dict:
        loop   = asyncio.get_running_loop()
        future = loop.create_future()

        msg_id = await self.publish(to=to, payload=payload, msg_type="task")
        self._pending[msg_id] = future

        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(msg_id, None)
            return {"response": f"[TIMEOUT] {to} n'a pas répondu dans les {timeout}s"}

    # ──────────────────────────────────────────────────────────────────────────
    # CLI loop
    # ──────────────────────────────────────────────────────────────────────────

    async def _cli_loop(self) -> None:
        loop = asyncio.get_running_loop()

        while self._running:
            try:
                raw = await loop.run_in_executor(None, lambda: input("\n🏗  > "))
                cmd = raw.strip()
            except (EOFError, KeyboardInterrupt):
                break

            if not cmd:
                continue

            if cmd.lower() in ("exit", "quit", "q"):
                await self.stop()
                break

            if cmd.lower() == "status":
                state = await self._controller.get_state()
                display_status(state)
                continue

            if cmd.lower() == "history":
                state = await self._controller.get_state()
                phase = state["phase"]
                if phase == "IDLE":
                    print("  Aucune phase active.")
                else:
                    hist = await self._controller.get_history(phase)
                    for h in hist[-8:]:
                        print(f"  [{h['role']}] {h['content'][:150]}")
                continue

            # Commande phase
            parts = cmd.split()
            if parts[0].lower() == "phase" and len(parts) >= 2:
                await self._start_phase(parts[1].upper(), loop)
                continue

            # Commande directe vers un agent : "D: nettoie le dossier"
            if ":" in cmd:
                parts   = cmd.split(":", 1)
                agent_id = parts[0].strip().upper()
                instruction = parts[1].strip()
                if agent_id and instruction:
                    await self._direct_command(agent_id, instruction)
                    continue

            # Dans une phase active : transmet le message à l'agent courant
            state = await self._controller.get_state()
            phase = state["phase"]

            if phase == "IDLE":
                print("  Aucune phase active. Démarre avec : phase PAF")
                print("  Ou envoie une commande directe : D: <instruction>")
                continue

            await self._handle_phase_input(phase, cmd, loop)

    # ──────────────────────────────────────────────────────────────────────────
    # Gestion des phases
    # ──────────────────────────────────────────────────────────────────────────

    async def _start_phase(self, phase: str, loop) -> None:
        if phase not in ("PAF", "PAT", "PD", "PT"):
            display_error(f"Phase inconnue : {phase}. Valeurs : PAF, PAT, PD, PT")
            return

        state = await self._controller.get_state()

        # Reprise ou démarrage
        if state["phase"] == phase:
            print(f"  → Reprise {phase} (étape : {state['step']}, itération : {state['iteration']})")
        else:
            step_map = {"PAF": "PAF1", "PAT": "PAT1", "PD": "PD1", "PT": "PT1"}
            await self._controller.set_state(phase, step_map[phase])
            print(f"  → Démarrage {phase}")

        display_phase_header(phase, (await self._controller.get_state())["step"])

        if phase == "PD":
            await self._run_pd(loop)
        elif phase == "PT":
            await self._controller.handle_pt(loop)

    async def _handle_phase_input(self, phase: str, user_input: str, loop) -> None:
        """Traite une entrée utilisateur dans le contexte de la phase courante."""
        if phase == "PAF":
            result = await self._controller.handle_paf(user_input, loop)
            if result:  # PAF3 : archi prête
                await self._finalize_paf(result, loop)

        elif phase == "PAT":
            result = await self._controller.handle_pat(user_input, loop)
            if result:  # PAT3 : specs prêtes
                await self._finalize_pat(result, loop)

        elif phase in ("PD", "PT"):
            print(f"  Utilise 'phase {phase}' pour démarrer cette phase.")

    async def _finalize_paf(self, response: str, loop) -> None:
        """PAF3 : sauvegarde PAF_context.md (commit + tag PAF) et propose de passer à PAT."""
        await self._controller.save_paf_context(response)
        print("\n✅ Architecture fonctionnelle finalisée → PAF_context.md sauvegardé")

        answer = await loop.run_in_executor(
            None, lambda: input("  Passer à la phase PAT ? [o/N] : ")
        )
        if answer.strip().lower() in ("o", "oui", "y", "yes"):
            await self._start_phase("PAT", loop)

    async def _finalize_pat(self, response: str, loop) -> None:
        """PAT3 : sauvegarde PAT_spec.md (commit + tag PAT) et propose de passer à PD."""
        await self._controller.save_pat_spec(response)
        print("\n✅ Spécifications techniques finalisées → PAT_spec.md sauvegardé")

        answer = await loop.run_in_executor(
            None, lambda: input("  Passer à la phase PD ? [o/N] : ")
        )
        if answer.strip().lower() in ("o", "oui", "y", "yes"):
            await self._run_pd(loop)

    async def _direct_command(self, agent_id: str, instruction: str) -> None:
        """
        Envoie une instruction directe à n'importe quel agent, hors phase formelle.
        Pas de spec_ref, pas de validation de plan — juste l'instruction brute.
        """
        print(f"\n  → commande directe vers {agent_id} : {instruction[:80]}")
        result = await self.send_and_wait(agent_id, {
            "instruction":    instruction,
            "spec_ref":       "",
            "functional_ref": "",
            "direct":         True,   # flag : pas de commit de spec obligatoire
        })
        response = result.get("response", "")
        from cli import display_agent_response
        display_agent_response(agent_id, response)

    async def _run_pd(self, loop) -> None:
        """PD : charge les specs AT et les envoie à D une par une."""
        await self._controller.set_state("PD", "PD1")
        specs = self._controller.load_pat_specs_as_list()

        if not specs:
            display_error(
                "Aucune spec trouvée dans realness/specs/PAT_spec.md\n"
                "  Assurez-vous d'avoir terminé la phase PAT (PAT3)."
            )
            return

        print(f"\n  {len(specs)} spec(s) à implémenter :")
        for s in specs:
            print(f"    {s['spec_ref']} ({s['functional_ref']}) — {s['instruction'][:60]}")

        answer = await loop.run_in_executor(
            None, lambda: input(f"\n  Confirmer l'envoi de {len(specs)} spec(s) à D ? [o/N] : ")
        )
        if answer.strip().lower() not in ("o", "oui", "y", "yes"):
            print("  Annulé.")
            return

        await self._controller.set_state("PD", "PD2")
        await self._controller.handle_pd_specs(specs)
        print("\n✅ Phase PD terminée.")


# ─── Entry point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    asyncio.run(AgentApp().start())