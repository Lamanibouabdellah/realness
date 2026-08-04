"""
agents/agent-app/cli.py — Affichage terminal pour le Phase Controller.
"""

import asyncio

_BOLD   = "\033[1m"
_DIM    = "\033[2m"
_GREEN  = "\033[92m"
_YELLOW = "\033[93m"
_CYAN   = "\033[96m"
_BLUE   = "\033[94m"
_RED    = "\033[91m"
_RESET  = "\033[0m"
_SEP    = "─" * 60


def display_welcome() -> None:
    print(f"\n{_BOLD}{_CYAN}{'═' * 60}{_RESET}")
    print(f"{_BOLD}{_CYAN}  🏗  AGENTIC PLATFORM — realness framework{_RESET}")
    print(f"{_DIM}  Phases : PAF → PAT → PD → PT{_RESET}")
    print(f"{_BOLD}{_CYAN}{'═' * 60}{_RESET}")
    print(f"{_DIM}  Commandes : 'phase PAF|PAT|PD|PT' · 'status' · 'exit'{_RESET}\n")


def display_phase_header(phase: str, step: str) -> None:
    labels = {
        "PAF": "Phase Architecture Fonctionnelle",
        "PAT": "Phase Architecture Technique",
        "PD":  "Phase Développement",
        "PT":  "Phase Test",
    }
    label = labels.get(phase, phase)
    print(f"\n{_BOLD}{_YELLOW}{'═' * 60}{_RESET}")
    print(f"{_BOLD}{_YELLOW}  {label}  [{step}]{_RESET}")
    print(f"{_YELLOW}{'═' * 60}{_RESET}\n")


def display_agent_response(agent_id: str, response: str) -> None:
    short = response[:800] + ("..." if len(response) > 800 else "")
    print(f"\n{_BOLD}{_BLUE}[{agent_id}]{_RESET}")
    print(f"{_SEP}")
    print(short)
    print(f"{_SEP}\n")


async def display_specialist_request(spec_req: dict, loop) -> bool:
    agent  = spec_req.get("agent", "?")
    reason = spec_req.get("reason", "")
    print(f"\n{_YELLOW}⚡ Demande de spécialiste : {_BOLD}{agent}{_RESET}")
    print(f"  Raison : {reason}")
    answer = await loop.run_in_executor(
        None, lambda: input(f"  Approuver la consultation de {agent} ? [o/N] : ")
    )
    return answer.strip().lower() in ("o", "oui", "y", "yes")


def display_spec_commit(spec_ref: str, functional_ref: str, files: list[str]) -> None:
    files_str = ", ".join(files) if files else "(aucun fichier)"
    print(f"  {_GREEN}✓{_RESET} commit {_BOLD}{spec_ref}{_RESET} ({functional_ref}) — {files_str}")


def display_status(state: dict) -> None:
    phase = state.get("phase", "IDLE")
    step  = state.get("step", "")
    it    = state.get("iteration", 0)
    print(f"\n{_SEP}")
    print(f"  Phase courante : {_BOLD}{phase}{_RESET}  |  Étape : {step}  |  Itération : {it}")
    print(f"{_SEP}\n")


def display_error(msg: str) -> None:
    print(f"\n{_RED}❌ {msg}{_RESET}\n")
