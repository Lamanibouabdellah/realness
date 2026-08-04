import asyncio
from agent_base import AgentBase


class AFP2PAgent(AgentBase):

    async def handle_task(self, message: dict) -> None:
        payload   = message.get("payload", {})
        parent_id = message.get("message_id")

        question = payload.get("context", "") or payload.get("user_message", "")
        response = await self.call_llm(question)

        await self.publish(
            to="agent-app",
            payload={"response": response, "specialist": self.id},
            msg_type="result",
            parent_message_id=parent_id,
        )


if __name__ == "__main__":
    asyncio.run(AFP2PAgent().start())
