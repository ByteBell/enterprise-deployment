.PHONY: help preflight login pull up down restart ps logs verify update dirs

# `sudo` by default, because that is how Docker is installed on a fresh Ubuntu host: the daemon
# socket is root-owned until your user is in the `docker` group AND you have logged out and back in.
# Once that is true, run any target with DOCKER=docker to drop it:
#
#     make up DOCKER=docker
#
# Keep it consistent within a deployment. `make login` writes credentials to the config of whichever
# user runs it, and `make pull` must run as that same user or it cannot read them — a login as
# yourself followed by a pull under sudo is the most common "pull access denied" on a private repo.
DOCKER ?= sudo docker
COMPOSE = $(DOCKER) compose

# Read .env only to sanity-check it and to print what is running. Compose reads the same file itself
# for ${VAR} substitution in docker-compose.yml, which is why no target has to pass IMAGE_TAG along.
-include .env

help:
	@echo "Plumbline — enterprise deployment"
	@echo ""
	@echo "  First run:"
	@echo "    cp .env.example .env && \$$EDITOR .env"
	@echo "    make preflight      Check Docker, .env, and the required values"
	@echo "    make login          Authenticate to the private image registry"
	@echo "    make up             Pull images and start everything"
	@echo "    make verify         Prove the stack is actually serving"
	@echo ""
	@echo "  Day to day:"
	@echo "    make ps             What is running"
	@echo "    make logs           Follow all logs      (make logs s=admin-server for one)"
	@echo "    make restart        Restart every service"
	@echo "    make down           Stop everything (data in volumes is kept)"
	@echo ""
	@echo "  Upgrading:"
	@echo "    edit IMAGE_TAG in .env, then: make update"
	@echo ""
	@echo "  Current: IMAGE_TAG=$(IMAGE_TAG)  registry=$(IMAGE_REGISTRY)/$(IMAGE_REPO_PREFIX)/$(IMAGE_REPO_NAME)"

# Fail here, with a sentence, rather than three layers down in a container log.
preflight:
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker is not installed — see README, Step 1"; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "✗ the docker compose plugin is missing — see README, Step 1"; exit 1; }
	@test -f .env || { echo "✗ no .env — run: cp .env.example .env"; exit 1; }
	@missing=""; for k in IMAGE_TAG IMAGE_REGISTRY IMAGE_REPO_PREFIX IMAGE_REPO_NAME REGISTRY_USERNAME \
	  REGISTRY_TOKEN COMPOSE_PROJECT_DIR MONGODB_URI NEO4J_URI NEO4J_PASSWORD JWT_SECRET \
	  UPDATE_API_TOKEN S3_FILES_BUCKET FRONTEND_BASE_URL AGENT_LLM_BASE_URL AGENT_LLM_API_KEY \
	  AGENT_MODEL; do \
	  v=$$(grep -E "^[[:space:]]*$$k=" .env | tail -1 | cut -d= -f2-); \
	  [ -z "$$v" ] && missing="$$missing $$k"; \
	done; \
	if [ -n "$$missing" ]; then echo "✗ .env is missing values:"; for m in $$missing; do echo "    $$m"; done; exit 1; fi
	@echo "✓ docker, compose plugin and .env all present"

# The token lands in the config of the user this runs as — see the DOCKER note above.
login:
	@test -n "$(REGISTRY_USERNAME)" || { echo "✗ REGISTRY_USERNAME is not set in .env"; exit 1; }
	@printf '%s' '$(REGISTRY_TOKEN)' | $(DOCKER) login $(IMAGE_REGISTRY) --username '$(REGISTRY_USERNAME)' --password-stdin

# Bind-mounted paths must exist first. Docker creates a missing one as a root-owned directory, and
# the service then cannot write its logs into it.
dirs:
	@mkdir -p logs/admin-server logs/email-dispatcher logs/knowledge-server \
	          logs/mcp/mcp-1 logs/mcp/mcp-2 logs/mcp/mcp-3 logs/mcp/mcp-4 temp

pull: preflight login
	$(COMPOSE) pull

up: dirs pull
	$(COMPOSE) up -d
	@echo ""
	@echo "Started. Give it a minute, then: make verify"

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

ps:
	@$(COMPOSE) ps

# make logs            — everything
# make logs s=mcp-1    — one service
logs:
	@$(COMPOSE) logs -f --tail=200 $(s)

# Pull the tag now named in .env and replace the running containers with it. Compose only recreates
# services whose image actually changed, so this is also the no-op if you are already current.
update: preflight login
	$(COMPOSE) pull
	$(COMPOSE) up -d
	@echo ""
	@echo "Now on IMAGE_TAG=$(IMAGE_TAG). Confirm with: make verify"

# Prove it SERVES, which is not the same as "the containers are up" — a reachable route in front of
# a dead backend answers 503 and looks healthy in `ps`.
verify:
	@echo "→ containers"
	@$(COMPOSE) ps --format '   {{.Service}}\t{{.Status}}' 2>/dev/null || $(COMPOSE) ps
	@echo ""
	@echo "→ HAProxy backends (all should be UP)"
	@curl -s --max-time 5 'http://localhost:8404/stats;csv' 2>/dev/null \
	  | awk -F, '$$2=="BACKEND" {printf "   %-18s %s\n", $$1, $$18}' || echo "   stats page unreachable"
	@echo ""
	@echo "→ endpoints"
	@printf '   admin API        '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://localhost/api/admin/health || echo unreachable
	@printf '   knowledge API    '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://localhost/api/knowledge/health || echo unreachable
	@printf '   public questions '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 -X POST http://localhost/api/v1/public/agent/repos/x/y/ask || echo unreachable
	@echo ""
	@echo "   A 4xx on the last line is CORRECT (the service rejected an empty question)."
	@echo "   A 503 means HAProxy is up but public-agent is not — check: make logs s=public-agent-1"
