"""
agents/D/main.py

Agent Développeur C.

Logique de traitement d'une instruction :
  1. Tente d'abord une opération filesystem directe (direct_ops.py)
     → supprime, nettoie, liste, renomme, mkdir — exécutés en Python, sans LLM
  2. Si ce n'est pas une op directe → appelle le LLM pour du dev C
"""

import asyncio
import re

from agent_base import AgentBase
from direct_ops import try_direct_op
from workspace import apply_delete_ops, apply_file_ops, parse_delete_ops, parse_file_ops


class DAgent(AgentBase):

    async def handle_task(self, message: dict) -> None:
        payload        = message.get("payload", {})
        parent_id      = message.get("message_id")
        instruction    = payload.get("instruction", "")
        spec_ref       = payload.get("spec_ref", "")
        functional_ref = payload.get("functional_ref", "")
        is_direct      = payload.get("direct", False)

        # ── 1. Interception : opération filesystem directe ──────────────────
        op = try_direct_op(instruction)

        if op.handled:
            print(f"[D] op directe : {op.summary}")
            print(f"[D] {op.output}")

            # Demande de commit au git-bridge si des fichiers ont changé
            all_changed = op.written + op.deleted
            if all_changed:
                await self.request_commit(message=op.summary, files=all_changed)

            await self.publish(
                to="agent-app",
                payload={
                    "response":      op.output,
                    "files_written": op.written,
                    "files_deleted": op.deleted,
                    "spec_ref":      spec_ref,
                    "functional_ref": functional_ref,
                },
                msg_type="result",
                parent_message_id=parent_id,
            )
            return

        # ── 2. Développement C via LLM ──────────────────────────────────────
        print(f"[D] 🔨 dev C : {instruction[:80]}...")

        workspace_ctx = await self.get_agent_context()  # read_write

        prompt = f"{workspace_ctx}\n\nSPÉCIFICATION À IMPLÉMENTER :\n{instruction}"
        if spec_ref:
            prompt += f"\n\nRÉFÉRENCE : {spec_ref}"
        if functional_ref:
            prompt += f" ({functional_ref})"

        response = await self.call_llm(prompt)

        # Parse fichiers à créer/modifier
        ops     = parse_file_ops(response)
        written = []
        if ops:
            try:
                written = apply_file_ops(ops)
                print(f"[D] fichiers écrits : {written}")
            except ValueError as e:
                print(f"[D] erreur écriture : {e}")

        # Parse suppressions déclarées par le LLM
        del_ops = parse_delete_ops(response)
        deleted = []
        if del_ops:
            try:
                deleted = apply_delete_ops(del_ops)
                print(f"[D] fichiers supprimés : {deleted}")
            except ValueError as e:
                print(f"[D] erreur suppression : {e}")

        all_changed = written + deleted

        # Extraire summary depuis la réponse LLM
        summary_match = re.search(r'SUMMARY:\s*(.+)', response, re.IGNORECASE)
        summary = summary_match.group(1).strip() if summary_match else instruction[:60]

        # Commande directe : le LLM ne doit jamais polluer le summary avec des refs PAT/PAF
        if is_direct:
            summary = re.sub(r'\s*\|?\s*PAT:\S+', '', summary).strip()
            summary = re.sub(r'\s*(?:conformément\s+à\s+)?PAT:\S+', '', summary, flags=re.IGNORECASE).strip()
            summary = re.sub(r'\s*\(PAF:\S+\)', '', summary).strip()
            spec_ref       = ""   # force : pas de spec ref sur commande directe
            functional_ref = ""

        # Extraire refs si non fournies (uniquement pour dev C formel)
        if not is_direct:
            if not spec_ref:
                m = re.search(r'SPEC_REF:\s*(\S+)', response, re.IGNORECASE)
                if m:
                    spec_ref = m.group(1)
            if not functional_ref:
                m = re.search(r'FUNCTIONAL_REF:\s*(\S+)', response, re.IGNORECASE)
                if m:
                    functional_ref = m.group(1)

        # Demande de commit au git-bridge (les refs spec_at/spec_af sont vides si commande directe)
        if all_changed:
            await self.request_commit(
                message=summary,
                files=all_changed,
                spec_at=spec_ref       if not is_direct else "",
                spec_af=functional_ref if not is_direct else "",
            )

        await self.publish(
            to="agent-app",
            payload={
                "response":       response,
                "files_written":  written,
                "files_deleted":  deleted,
                "spec_ref":       spec_ref,
                "functional_ref": functional_ref,
            },
            msg_type="result",
            parent_message_id=parent_id,
        )


if __name__ == "__main__":
    asyncio.run(DAgent().start())