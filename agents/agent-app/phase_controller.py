"""
agents/agent-app/phase_controller.py

Contrôleur de phases — machine à états qui orchestre PAF → PAT → PD → PT.

ÉTAT (persisté dans Redis avec AOF) :
  phase:current        → "PAF" | "PAT" | "PD" | "PT" | "IDLE"
  phase:step           → "PAF1" | "PAF2" | "PAF3" | ...
  phase:iteration      → int
  phase:{PHASE}:history → List JSON (historique de conversation par phase)

RÉSUMÉ DES PHASES :
  PAF : itération AF ↔ user (+ spécialistes AF_P2P validés)
  PAT : itération AT ↔ user (+ spécialistes AT_SEC, AT_COMP validés)
  PD  : envoi séquentiel de chaque spec AT à D (un commit par spec)
  PT  : audit AT/AT_SEC/AT_COMP + tests T
"""

import json
import os
import re
from pathlib import Path

import redis.asyncio as aioredis

from cli import (
    display_phase_header,
    display_agent_response,
    display_specialist_request,
    display_spec_commit,
    display_error,
)

WORKSPACE_PATH = Path(os.getenv("WORKSPACE_PATH", "/realness"))
SPECS_PATH     = WORKSPACE_PATH / "specs"

# Préfixe git-bridge pour les fichiers relatifs à GIT_ROOT
_GIT_ROOT = Path(os.getenv("GIT_ROOT", str(WORKSPACE_PATH)))
try:
    _scope_raw = str(WORKSPACE_PATH.relative_to(_GIT_ROOT))
    _GIT_SCOPE = "" if _scope_raw == "." else _scope_raw
except ValueError:
    _GIT_SCOPE = ""

# Mapping phase → agent principal
PHASE_AGENTS = {
    "PAF": "AF",
    "PAT": "AT",
    "PD":  "D",
    "PT":  None,  # PT multiplex AT + AT_SEC + AT_COMP + T
}

PHASES_ORDER = ["PAF", "PAT", "PD", "PT"]


class PhaseController:

    def __init__(self, redis: aioredis.Redis, dispatcher) -> None:
        self._redis  = redis
        self._disp   = dispatcher   # référence vers l'AgentApp pour publish/wait

    # ──────────────────────────────────────────────────────────────────────────
    # ÉTAT
    # ──────────────────────────────────────────────────────────────────────────

    async def get_state(self) -> dict:
        return {
            "phase":     await self._redis.get("phase:current") or "IDLE",
            "step":      await self._redis.get("phase:step")    or "",
            "iteration": int(await self._redis.get("phase:iteration") or 0),
        }

    async def set_state(self, phase: str, step: str, iteration: int = 0) -> None:
        await self._redis.set("phase:current",   phase)
        await self._redis.set("phase:step",      step)
        await self._redis.set("phase:iteration", str(iteration))

    async def get_history(self, phase: str) -> list[dict]:
        raw = await self._redis.lrange(f"phase:{phase}:history", 0, -1)
        return [json.loads(r) for r in raw]

    async def add_to_history(self, phase: str, role: str, content: str) -> None:
        entry = json.dumps({"role": role, "content": content})
        await self._redis.rpush(f"phase:{phase}:history", entry)

    def _format_history(self, history: list[dict], max_entries: int = 10) -> str:
        """Formate l'historique pour injection dans le prompt — limité aux N dernières entrées."""
        recent = history[-max_entries:]
        return "\n".join(f"[{h['role']}] {h['content'][:300]}" for h in recent)

    # ──────────────────────────────────────────────────────────────────────────
    # GIT BRIDGE — délégation commit / tag depuis le phase controller
    # ──────────────────────────────────────────────────────────────────────────

    async def _request_git_commit(self, message: str, files: list[str]) -> None:
        """
        Publie un commit de spec sur git:commits.
        `files` sont relatifs à WORKSPACE_PATH (ex: "specs/PAF_context.md").
        """
        phase     = await self._redis.get("phase:current") or "?"
        git_files = [f"{_GIT_SCOPE}/{f}" if _GIT_SCOPE else f for f in files]
        payload   = {
            "agent":   "agent-app",
            "phase":   phase,
            "message": message,
            "files":   git_files,
        }
        await self._redis.xadd("git:commits", {"data": json.dumps(payload)})
        print(f"[agent-app] commit demandé → [agent-app][{phase}] {message}")

    async def _request_git_tag(self, phase: str) -> None:
        """Crée un tag git de fin de phase (ex: phase/PAF-1)."""
        counter  = await self._redis.incr(f"git:tag_counter:{phase}")
        tag_name = f"phase/{phase}-{counter}"
        await self._redis.xadd("git:tags", {"data": json.dumps({"tag": tag_name})})
        print(f"[agent-app] 🏷  tag git demandé → {tag_name}")

    # ──────────────────────────────────────────────────────────────────────────
    # DISPATCH VERS UN AGENT + ATTENTE RÉSULTAT
    # ──────────────────────────────────────────────────────────────────────────

    async def _call_agent(self, agent_id: str, payload: dict) -> str:
        """Envoie une tâche à un agent et attend sa réponse (via dispatcher)."""
        result = await self._disp.send_and_wait(agent_id, payload)
        return result.get("response", "")

    # ──────────────────────────────────────────────────────────────────────────
    # PHASE PAF
    # ──────────────────────────────────────────────────────────────────────────

    async def handle_paf(self, user_input: str, loop) -> str | None:
        """
        Traite un message dans la phase PAF.
        Retourne None pour continuer l'itération,
        ou le contenu PAF_context.md si l'archi est finalisée.
        """
        state   = await self.get_state()
        history = await self.get_history("PAF")

        await self.add_to_history("PAF", "user", user_input)

        payload = {
            "user_message":      user_input,
            "conversation_history": self._format_history(history),
        }

        response = await self._call_agent("AF", payload)
        display_agent_response("AF", response)
        await self.add_to_history("PAF", "AF", response)

        # Détecte une demande de spécialiste
        spec_req = _parse_specialist_request(response)
        if spec_req:
            approved = await display_specialist_request(spec_req, loop)
            if approved:
                spec_response = await self._call_agent(spec_req["agent"], {
                    "context": spec_req["context"],
                    "reason":  spec_req["reason"],
                })
                display_agent_response(spec_req["agent"], spec_response)
                await self.add_to_history("PAF", spec_req["agent"], spec_response)

                # Retransmet le résultat à AF
                followup = await self._call_agent("AF", {
                    "user_message":      "Continue avec le résultat du spécialiste.",
                    "conversation_history": self._format_history(await self.get_history("PAF")),
                    "specialist_result": spec_response,
                })
                display_agent_response("AF", followup)
                await self.add_to_history("PAF", "AF", followup)

        # Détecte PAF3 (archi finalisée)
        if "READY_FOR_PAF3: true" in response:
            await self.set_state("PAF", "PAF3")
            return response  # le caller extrait le contenu PAF_context

        iteration = state["iteration"] + 1
        await self.set_state("PAF", "PAF2", iteration)
        return None

    # ──────────────────────────────────────────────────────────────────────────
    # PHASE PAT
    # ──────────────────────────────────────────────────────────────────────────

    async def handle_pat(self, user_input: str, loop) -> str | None:
        """Même logique que PAF mais avec AT et ses spécialistes."""
        state   = await self.get_state()
        history = await self.get_history("PAT")

        await self.add_to_history("PAT", "user", user_input)

        payload = {
            "user_message":         user_input,
            "conversation_history": self._format_history(history),
        }

        response = await self._call_agent("AT", payload)
        display_agent_response("AT", response)
        await self.add_to_history("PAT", "AT", response)

        spec_req = _parse_specialist_request(response)
        if spec_req and spec_req["agent"] in ("AT_SEC", "AT_COMP"):
            approved = await display_specialist_request(spec_req, loop)
            if approved:
                spec_response = await self._call_agent(spec_req["agent"], {
                    "context": spec_req["context"],
                    "reason":  spec_req["reason"],
                })
                display_agent_response(spec_req["agent"], spec_response)
                await self.add_to_history("PAT", spec_req["agent"], spec_response)

                followup = await self._call_agent("AT", {
                    "user_message":         "Continue avec le résultat du spécialiste.",
                    "conversation_history": self._format_history(await self.get_history("PAT")),
                    "specialist_result":    spec_response,
                })
                display_agent_response("AT", followup)
                await self.add_to_history("PAT", "AT", followup)

        if "READY_FOR_PAT3: true" in response:
            await self.set_state("PAT", "PAT3")
            return response

        iteration = state["iteration"] + 1
        await self.set_state("PAT", "PAT2", iteration)
        return None

    # ──────────────────────────────────────────────────────────────────────────
    # PHASE PD
    # ──────────────────────────────────────────────────────────────────────────

    async def handle_pd_specs(self, specs: list[dict]) -> None:
        """
        Envoie chaque spec à D séquentiellement (un commit par spec).

        specs = [
            {"spec_ref": "PAT:1.1", "functional_ref": "PAF:1.2",
             "instruction": "Implémenter ..."},
            ...
        ]
        """
        await self.set_state("PD", "PD2", 0)

        for i, spec in enumerate(specs):
            print(f"\n[PD] → spec {i+1}/{len(specs)} : {spec['spec_ref']}")

            result = await self._disp.send_and_wait("D", {
                "instruction":    spec["instruction"],
                "spec_ref":       spec["spec_ref"],
                "functional_ref": spec.get("functional_ref", ""),
            })

            files_written = result.get("files_written", [])
            display_spec_commit(spec["spec_ref"], spec.get("functional_ref", ""), files_written)

            await self._redis.set("phase:iteration", str(i + 1))

        await self.set_state("PD", "DONE")
        await self._request_git_tag("PD")

    # ──────────────────────────────────────────────────────────────────────────
    # PHASE PT
    # ──────────────────────────────────────────────────────────────────────────

    async def handle_pt(self, loop) -> None:
        """Lance l'audit (AT + AT_SEC + AT_COMP) puis les tests (T)."""
        await self.set_state("PT", "PT1")
        print("\n[PT1] Audit par les architectes...")

        # Audit simultané AT + AT_SEC + AT_COMP (séquentiel ici pour simplicité)
        for auditor in ("AT", "AT_SEC", "AT_COMP"):
            approved = await _ask_approval(f"Lancer l'audit de {auditor}", loop)
            if approved:
                result = await self._call_agent(auditor, {
                    "user_message": "Effectue un audit complet du code implémenté."
                })
                display_agent_response(auditor, result)
                await self.add_to_history("PT", auditor, result)

        await self.set_state("PT", "PT2")
        print("\n[PT2] Tests de compilation...")
        approved = await _ask_approval("Lancer les tests de compilation (T)", loop)
        if approved:
            result = await self._call_agent("T", {
                "instruction": "Teste la compilation sur toutes les architectures disponibles."
            })
            display_agent_response("T", result)
            await self.add_to_history("PT", "T", result)

        await self.set_state("PT", "DONE")
        await self._request_git_tag("PT")

    # ──────────────────────────────────────────────────────────────────────────
    # SAUVEGARDE DES SPECS
    # ──────────────────────────────────────────────────────────────────────────

    async def save_paf_context(self, content: str) -> None:
        """Écrit PAF_context.md, commit + tag phase/PAF."""
        SPECS_PATH.mkdir(parents=True, exist_ok=True)
        (SPECS_PATH / "PAF_context.md").write_text(
            _extract_spec_content(content, "PAF_context.md"), encoding="utf-8"
        )
        print(f"[PAF3] PAF_context.md sauvegardé dans {SPECS_PATH}")
        await self._request_git_commit(
            message="PAF_context.md — architecture fonctionnelle",
            files=["specs/PAF_context.md"],
        )
        await self._request_git_tag("PAF")

    async def save_pat_spec(self, content: str) -> None:
        """Écrit PAT_spec.md, commit + tag phase/PAT."""
        SPECS_PATH.mkdir(parents=True, exist_ok=True)
        (SPECS_PATH / "PAT_spec.md").write_text(
            _extract_spec_content(content, "PAT_spec.md"), encoding="utf-8"
        )
        print(f"[PAT3] PAT_spec.md sauvegardé dans {SPECS_PATH}")
        await self._request_git_commit(
            message="PAT_spec.md — spécifications techniques",
            files=["specs/PAT_spec.md"],
        )
        await self._request_git_tag("PAT")

    def load_pat_specs_as_list(self) -> list[dict]:
        """
        Lit PAT_spec.md et extrait la liste des specs au format :
            N.M - description (PAF:X.Y)
        Retourne une liste de dict { spec_ref, functional_ref, instruction }.
        """
        spec_file = SPECS_PATH / "PAT_spec.md"
        if not spec_file.exists():
            return []

        content = spec_file.read_text(encoding="utf-8")
        specs   = []

        pattern = re.compile(
            r'(\d+\.\d+)\s*[-–]\s*(.+?)\s*\(PAF:(\d+\.\d+)\)',
            re.MULTILINE
        )
        for match in pattern.finditer(content):
            specs.append({
                "spec_ref":       f"PAT:{match.group(1)}",
                "functional_ref": f"PAF:{match.group(3)}",
                "instruction":    match.group(2).strip(),
            })

        return specs


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _parse_specialist_request(response: str) -> dict | None:
    """Extrait SPECIALIST_REQUEST: {...} depuis la réponse d'un agent."""
    match = re.search(r'SPECIALIST_REQUEST:\s*(\{.+\})', response)
    if not match:
        return None
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError:
        return None


def _extract_spec_content(response: str, filename: str) -> str:
    """
    Extrait le contenu du document de spec depuis la réponse LLM.
    Si le LLM a encapsulé le contenu dans un bloc markdown, l'extrait.
    Sinon retourne la réponse complète avec un en-tête.
    """
    # Cherche un bloc ```markdown ... ``` ou le contenu brut
    md_match = re.search(r'```(?:markdown)?\n(.*?)```', response, re.DOTALL)
    content  = md_match.group(1) if md_match else response

    return f"# {filename}\n\n{content.strip()}\n"


async def _ask_approval(prompt: str, loop) -> bool:
    answer = await loop.run_in_executor(
        None, lambda: input(f"\n  ✅ {prompt} ? [o/N] : ")
    )
    return answer.strip().lower() in ("o", "oui", "y", "yes")