import asyncio
from agent_base import AgentBase


class ATSECAgent(AgentBase):

    async def handle_task(self, message: dict) -> None:
        payload   = message.get("payload", {})
        parent_id = message.get("message_id")

        context_request = payload.get("context", "") or payload.get("user_message", "")
        workspace_ctx   = await self.get_agent_context()  # read_all

        prompt = f"{workspace_ctx}\n\nDEMANDE D'AUDIT SÉCURITÉ :\n{context_request}" if workspace_ctx \
            else context_request

        response = await self.call_llm(prompt)

        await self.publish(
            to="agent-app",
            payload={"response": response, "specialist": self.id},
            msg_type="result",
            parent_message_id=parent_id,
        )


if __name__ == "__main__":
    asyncio.run(ATSECAgent().start())
