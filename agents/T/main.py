"""
agents/T/main.py

Agent Testeur — compile le code sur les architectures cibles et rapporte les résultats.
"""

import asyncio
from agent_base import AgentBase


COMPILE_TARGETS = [
    {"arch": "x86_64", "compiler": "gcc",           "flags": "-Wall -Wextra -O2 -std=c11"},
    {"arch": "aarch64", "compiler": "aarch64-linux-gnu-gcc", "flags": "-Wall -O2 -std=c11"},
    {"arch": "riscv64", "compiler": "riscv64-linux-gnu-gcc", "flags": "-Wall -O2 -std=c11"},
]


class TAgent(AgentBase):

    async def handle_task(self, message: dict) -> None:
        payload   = message.get("payload", {})
        parent_id = message.get("message_id")

        test_request  = payload.get("instruction", "Tester la compilation complète")
        workspace_ctx = await self.get_agent_context()

        # Tentative de compilation réelle sur les architectures disponibles
        compile_results = await self._try_compile_all()

        prompt = (
            f"{workspace_ctx}\n\n"
            f"DEMANDE DE TEST :\n{test_request}\n\n"
            f"RÉSULTATS DE COMPILATION :\n{compile_results}"
        )

        response = await self.call_llm(prompt)

        await self.publish(
            to="agent-app",
            payload={"response": response, "compile_results": compile_results},
            msg_type="result",
            parent_message_id=parent_id,
        )

    async def _try_compile_all(self) -> str:
        """Tente de compiler sur chaque architecture disponible dans le container."""
        results = []
        for target in COMPILE_TARGETS:
            result = await self._compile(target)
            results.append(result)
        return "\n".join(results)

    async def _compile(self, target: dict) -> str:
        arch     = target["arch"]
        compiler = target["compiler"]
        flags    = target["flags"]

        # Vérifie si le compilateur est disponible
        check = await asyncio.create_subprocess_shell(
            f"which {compiler}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await check.communicate()
        if check.returncode != 0:
            return f"[{arch}] SKIP — compilateur {compiler} non disponible"

        # Compile tous les .c du workspace
        cmd = f"{compiler} {flags} $(find . -name '*.c') -I. -o /tmp/test_{arch} 2>&1"
        proc = await asyncio.create_subprocess_shell(
            cmd,
            cwd=str(self._get_workspace()),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        stdout, _ = await proc.communicate()
        output    = stdout.decode().strip()

        status = "OK" if proc.returncode == 0 else "ERREUR"
        return f"[{arch}] {status}\n{output[:500] if output else '(aucune sortie)'}"

    def _get_workspace(self):
        from pathlib import Path
        import os
        return Path(os.getenv("WORKSPACE_PATH", "/realness"))


if __name__ == "__main__":
    asyncio.run(TAgent().start())
