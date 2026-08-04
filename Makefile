# Agentic Platform — Makefile
.PHONY: up down rebuild sync-shared logs feed attach status phase-status \
        history redis-cli git-logs git-tags platform-git-update clean help

AGENTS = AF AF_P2P AT AT_SEC AT_COMP D T

# ─── Démarrage ─────────────────────────────────────────────────────────────────

## Démarre la plateforme (sync-shared + vérif realness/ + docker compose up)
up: sync-shared
	@if [ ! -d realness ]; then \
		echo "ERREUR : realness/ n'existe pas." ; \
		echo "  -> mkdir -p realness" ; \
		exit 1 ; \
	fi
	@mkdir -p data/redis
	docker compose up -d --build
	@echo ""
	@echo "Plateforme démarrée."
	@echo "  -> make attach      : Phase Controller CLI"
	@echo "  -> make feed        : live feed des événements"
	@echo "  -> make git-logs    : journal des commits agentiques"

## Copie agent_base.py + workspace.py dans chaque dossier agent (avant build Docker)
sync-shared:
	@echo "-> Synchronisation fichiers partagés..."
	@for agent in $(AGENTS) agent-app; do \
		cp shared/agent_base.py agents/$$agent/ ; \
		cp shared/workspace.py  agents/$$agent/ ; \
	done
	@echo "   OK -> agents/ ($(AGENTS) agent-app)"

# ─── Cycle de vie ──────────────────────────────────────────────────────────────

## Rebuild complet sans cache
rebuild: sync-shared
	docker compose build --no-cache
	docker compose up -d

## Arrête tout
down:
	docker compose down

## Supprime containers et images buildées (conserve data/redis)
clean:
	docker compose down --rmi local
	@echo "data/redis conservé (historique Redis). Supprimer manuellement si voulu."

# ─── Observation ───────────────────────────────────────────────────────────────

## Logs de tous les services
logs:
	docker compose logs -f

## Live feed des événements inter-agents (context-manager)
feed:
	docker compose logs -f context-manager

## Attache le terminal au Phase Controller CLI
## Détacher : Ctrl+P puis Ctrl+Q
attach:
	docker attach agentic-agent-app

## Statut des agents (via Redis)
status:
	docker compose exec redis redis-cli hgetall graph:status

## Phase courante et specs
phase-status:
	@echo "=== PHASE COURANTE ==="
	docker compose exec redis redis-cli get phase:current
	docker compose exec redis redis-cli get phase:step
	@echo "=== SPECS ==="
	@ls -la realness/specs/ 2>/dev/null || echo "(pas encore de specs)"

## Journal git des commits agentiques (scopé à realness/)
history:
	@git log --oneline --format="%h  %ae  %s" -- realness/ 2>/dev/null \
		|| echo "Aucun commit dans realness/"

## Logs git structurés des agents (format complet)
git-logs:
	@git log --format="%h %ai%n%b" -- realness/ 2>/dev/null | head -100 \
		|| echo "Aucun commit"

## Tags de phase créés par git-bridge
git-tags:
	@git tag -l "phase/*" | sort || echo "Aucun tag de phase"

## Accès direct à redis-cli
redis-cli:
	docker compose exec redis redis-cli

# ─── Git (platform) ────────────────────────────────────────────────────────────

## Commit + push rapide de la plateforme (infra seulement)
platform-git-update:
	@git add .
	@git diff --cached --quiet \
		&& echo "Plateforme : rien à committer" \
		|| git commit -m "chore: platform update"
	@git push || echo "Plateforme : rien à pusher (vérifier remote)"

# ─── Aide ──────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  make up                -> démarrer la plateforme"
	@echo "  make attach            -> Phase Controller CLI"
	@echo "  make feed              -> live feed événements"
	@echo "  make status            -> statut agents"
	@echo "  make phase-status      -> phase courante + specs"
	@echo "  make history           -> commits dans realness/"
	@echo "  make git-logs          -> commits détaillés"
	@echo "  make git-tags          -> tags de phase"
	@echo "  make rebuild           -> rebuild sans cache"
	@echo "  make down              -> arrêter"
	@echo "  make platform-git-update -> co