# BMAD v6.12 + Oh My Pi Project Instructions

## Primary methodology

This repository uses BMAD Method v6.12.

BMAD is the source of truth for:
- Product requirements
- Product management
- Business analysis
- Architecture
- UX specifications
- User stories
- Acceptance criteria
- Development workflows
- Technical decisions

Oh My Pi is the execution and orchestration environment.

## Mandatory initialization

At the beginning of a new task:

1. Inspect the repository structure.
2. Inspect `_bmad/` and `_bmad-output/`.
3. Read relevant BMAD project configuration.
4. Identify the applicable BMAD agent.
5. Identify the applicable BMAD workflow.
6. Read the associated artifacts.
7. Determine the current project status.

Do not assume that BMAD workflows have been completed.

## BMAD agent responsibilities

Respect the responsibilities of the existing BMAD agents:

- Analyst: research and requirements discovery.
- Product Manager: product scope and prioritization.
- Architect: technical architecture and decisions.
- UX Designer: user experience and interface specifications.
- Scrum Master: story preparation and workflow coordination.
- Developer: implementation.
- QA: validation and quality assurance.

Do not replace these agents with generic coding-agent behavior.

## Model selection

Follow `.omp/BMAD-MODEL-MAP.md`.

Use the OMP plan/slow roles for analysis and architecture.
Use default/task roles for implementation and testing.
Use smol/commit for lightweight operations.

Never select a paid model intentionally.

## Development lifecycle

1. Understand the BMAD requirement.
2. Identify the relevant workflow.
3. Inspect existing code.
4. Propose an implementation plan.
5. Implement incrementally.
6. Run relevant tests.
7. Check linting and typing.
8. Verify acceptance criteria.
9. Report modified files and results.

## Project integrity

- Preserve all existing BMAD artifacts.
- Never invent requirements.
- Never silently change acceptance criteria.
- Never skip mandatory workflow steps.
- Do not mark stories complete without verification.
- Avoid unnecessary dependencies.
- Follow existing architecture decisions.

## Git

- Preserve uncommitted user changes.
- Never force-push without authorization.
- Never run destructive Git commands without approval.
- Keep changes focused.
- Never commit API keys or credentials.

## Reporting

At the end of a task report:

- BMAD workflow used.
- Files modified.
- Implementation summary.
- Tests executed.
- Test results.
- Remaining issues.
