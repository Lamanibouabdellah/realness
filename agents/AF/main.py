"""
agents/AF/main.py

Agent Architecte Fonctionnel principal.
N'a aucun accès au repo. Itère avec l'utilisateur via agent-app.

Réponse possible :
  - Texte d'itération (questions, précisions, propositions)
  - SPECIALIST_REQUEST: {...}  → demande de sous-agent (validée par l'utilisateur)
  - READY_FOR_PAF3: true       → signale que l'archi est prête à formaliser
"""

import asyncio
from agent_base import AgentBase


class AFAgent(AgentBase):

    async def handle_task(self, message: dict) -> None:
        payload   = message.get("payload", {})
        parent_id = message.get("message_id")

        # Reconstruit le prompt avec l'historique de la conversation
        user_message      = payload.get("user_message", "")
        conversation_hist = payload.get("conversation_history", "")
        specialist_result = payload.get("specialist_result", "")

        prompt_parts = []
        if conversation_hist:
            prompt_parts.append(f"HISTORIQUE DE LA CONVERSATION :\n{conversation_hist}")
        if specialist_result:
            prompt_parts.append(f"RÉSULTAT DU SPÉCIALISTE :\n{specialist_result}")
        prompt_parts.append(f"MESSAGE UTILISATEUR :\n{user_message}")

        prompt = "\n\n".join(prompt_parts)

        # Pas de contexte workspace (access: none)
        response = await self.call_llm(prompt)

        await self.publish(
            to="agent-app",
            payload={"response": response},
            msg_type="result",
            parent_message_id=parent_id,
        )


if __name__ == "__main__":
    asyncio.run(AFAgent().start())
