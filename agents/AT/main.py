import asyncio
from agent_base import AgentBase


class ATAgent(AgentBase):

    async def handle_task(self, message: dict) -> None:
        payload   = message.get("payload", {})
        parent_id = message.get("message_id")

        user_message      = payload.get("user_message", "")
        conversation_hist = payload.get("conversation_history", "")
        specialist_result = payload.get("specialist_result", "")

        # Contexte workspace : specs/*.md + tous les .h (read_headers)
        workspace_ctx = await self.get_agent_context()

        prompt_parts = []
        if workspace_ctx:
            prompt_parts.append(workspace_ctx)
        if conversation_hist:
            prompt_parts.append(f"HISTORIQUE :\n{conversation_hist}")
        if specialist_result:
            prompt_parts.append(f"RÉSULTAT SPÉCIALISTE :\n{specialist_result}")
        prompt_parts.append(f"MESSAGE :\n{user_message}")

        response = await self.call_llm("\n\n".join(prompt_parts))

        await self.publish(
            to="agent-app",
            payload={"response": response},
            msg_type="result",
            parent_message_id=parent_id,
        )


if __name__ == "__main__":
    asyncio.run(ATAgent().start())
