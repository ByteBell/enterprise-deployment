.PHONY: dev prod help preflight login pull up down restart ps logs verify update dirs

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

# ── Which deployment this invocation is for ──────────────────────────────────
#
#     make up prod     → .production.env    the real host, on its own domain
#     make up dev      → .env               a laptop or test box, on http://localhost
#     make up          → .env               same as dev; the default is never production
#
# `dev` and `prod` are GOALS rather than variables, so they are read out of MAKECMDGOALS and
# declared as do-nothing targets below.
#
# ONE COMPLETE FILE PER DEPLOYMENT, not a shared base with an overlay. Two files that both define
# a key are how a stack ends up running settings nobody can see in the file they are reading: the
# last definition silently wins, and the losing one looks perfectly correct sitting above it.
BB_ENV        := $(if $(filter prod,$(MAKECMDGOALS)),prod,dev)
ENV_FILE_dev   = .env
ENV_FILE_prod  = .production.env
ENV_FILE      := $(ENV_FILE_$(BB_ENV))
export ENV_FILE

# Read the selected file only to sanity-check it and to print what is running. Compose reads it
# itself for ${VAR} substitution, which is why no target has to pass IMAGE_TAG along.
-include $(ENV_FILE)

# ── IMAGE_TAG: the release to run, resolved when it is left blank ────────────
#
# Leave IMAGE_TAG unset in the env file and the newest published release is used. There is no
# `latest` tag in the repository to point at — every tag names a service AND a version
# (`ingestion-engine-5.2.1`) — so "newest" has to be looked up rather than referred to.
#
# `ingestion-engine` is the probe because every release publishes it. `sort -V` orders versions
# numerically, so 5.10.0 comes after 5.9.0 rather than before it as a plain sort would have it.
#
# Anything set explicitly is used as-is and nothing is looked up: pinning a version is how you
# roll back, and a deployment that quietly moved off the tag you pinned would be worse than one
# that fails.
define latest_tag_sh
	jwt=$$(curl -s --max-time 20 -H "Content-Type: application/json" \
	        -d "{\"username\":\"$(REGISTRY_USERNAME)\",\"password\":\"$(REGISTRY_TOKEN)\"}" \
	        https://hub.docker.com/v2/users/login/ \
	      | grep -oE '"token":"[^"]+"' | cut -d'"' -f4); \
	[ -n "$$jwt" ] || exit 1; \
	curl -s --max-time 20 -H "Authorization: JWT $$jwt" \
	     "https://hub.docker.com/v2/repositories/$(IMAGE_REPO_PREFIX)/$(IMAGE_REPO_NAME)/tags?page_size=100" \
	  | tr ',' '\n' | grep -oE '"name":"ingestion-engine-[0-9]+\.[0-9]+\.[0-9]+"' \
	  | sed -E 's/.*ingestion-engine-([0-9.]+)"/\1/' | sort -V | tail -1
endef

# Resolved at PARSE time, but only for the goals that actually pull. `make help` and `make ps`
# must not reach out to a registry.
#
# Skipped entirely when the env file is absent, so that case reaches `preflight` and gets told to
# copy a template — rather than dying here on a lookup that never had credentials to try.
ifeq ($(strip $(IMAGE_TAG)),)
  ifneq ($(filter pull up update,$(MAKECMDGOALS)),)
    ifneq ($(wildcard $(ENV_FILE)),)
      IMAGE_TAG := $(shell $(latest_tag_sh))
      ifeq ($(strip $(IMAGE_TAG)),)
        $(error IMAGE_TAG is unset and the newest release could not be read from $(IMAGE_REGISTRY). \
                Check REGISTRY_USERNAME and REGISTRY_TOKEN in $(ENV_FILE), or set IMAGE_TAG yourself)
      endif
      $(info → IMAGE_TAG unset; using the newest published release: $(IMAGE_TAG))
    endif
  endif
endif
export IMAGE_TAG

# `sudo` resets the environment, so a resolved IMAGE_TAG and the selected ENV_FILE never reach
# docker on their own — they have to be handed over explicitly. Without sudo, `export` above is
# enough and DOCKER is used unchanged.
DOCKER_ENV = $(if $(filter sudo,$(firstword $(DOCKER))),\
               sudo env IMAGE_TAG=$(IMAGE_TAG) ENV_FILE=$(ENV_FILE) $(wordlist 2,99,$(DOCKER)),\
               $(DOCKER))

# Both are needed and they are NOT the same thing. `--env-file` feeds ${VAR} substitution in
# docker-compose.yml; the exported ENV_FILE is what the `env_file:` entries inside it expand to,
# and those the flag does not touch. Set only one and the containers read one file while the
# compose file was interpolated from another — the values disagree and nothing reports it.
COMPOSE = $(DOCKER_ENV) compose --env-file $(ENV_FILE)

# Refuse rather than fall back. Silently using .env because .production.env is absent is how a
# laptop's settings reach a production host.
define require_env
	@test -f $(ENV_FILE) || { \
		echo "✗ $(BB_ENV) needs $(ENV_FILE), which does not exist."; \
		echo "    dev  → .env              cp .env.example .env"; \
		echo "    prod → .production.env   cp .env.production.example .production.env"; \
		exit 1; \
	}
endef

# Goal sinks, so `make up prod` does not report "No rule to make target 'prod'".
dev prod:
	@:


help:
	@echo "Plumbline — enterprise deployment"
	@echo ""
	@echo "  Every target takes the deployment as the last word:"
	@echo "    make up prod        the real host, reading .production.env"
	@echo "    make up dev         a laptop or test box, reading .env  (the default)"
	@echo ""
	@echo "  First run — production:"
	@echo "    cp .env.production.example .production.env && \$$EDITOR .production.env"
	@echo "    make preflight prod   Check Docker, the env file, and the required values"
	@echo "    make up prod          Pull images and start everything"
	@echo "    make verify prod      Prove the stack is actually serving"
	@echo ""
	@echo "  First run — local:"
	@echo "    cp .env.example .env && \$$EDITOR .env"
	@echo "    make up dev"
	@echo ""
	@echo "  Day to day (add dev/prod to each):"
	@echo "    make ps             What is running"
	@echo "    make logs           Follow all logs      (make logs s=admin-server for one)"
	@echo "    make restart        Restart every service"
	@echo "    make down           Stop everything (data in volumes is kept)"
	@echo ""
	@echo "  Upgrading:"
	@echo "    edit IMAGE_TAG in the env file, then: make update prod"
	@echo ""
	@echo "  Current: $(BB_ENV) ($(ENV_FILE))  IMAGE_TAG=$(if $(strip $(IMAGE_TAG)),$(IMAGE_TAG),<unset — newest release is resolved on pull>)"
	@echo "           registry=$(IMAGE_REGISTRY)/$(IMAGE_REPO_PREFIX)/$(IMAGE_REPO_NAME)"

# Fail here, with a sentence, rather than three layers down in a container log.
preflight:
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker is not installed — see README, Step 1"; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "✗ the docker compose plugin is missing — see README, Step 1"; exit 1; }
	$(call require_env)
	@missing=""; for k in IMAGE_REGISTRY IMAGE_REPO_PREFIX IMAGE_REPO_NAME REGISTRY_USERNAME \
	  REGISTRY_TOKEN COMPOSE_PROJECT_DIR MONGODB_URI NEO4J_URI NEO4J_PASSWORD JWT_SECRET \
	  UPDATE_API_TOKEN S3_FILES_BUCKET FRONTEND_BASE_URL AGENT_LLM_BASE_URL AGENT_LLM_API_KEY \
	  AGENT_MODEL; do \
	  v=$$(grep -E "^[[:space:]]*$$k=" $(ENV_FILE) | tail -1 | cut -d= -f2-); \
	  [ -z "$$v" ] && missing="$$missing $$k"; \
	done; \
	if [ -n "$$missing" ]; then echo "✗ $(ENV_FILE) is missing values:"; for m in $$missing; do echo "    $$m"; done; exit 1; fi
	@dupes=$$(grep -oE "^[[:space:]]*[A-Z0-9_]+=" $(ENV_FILE) | tr -d ' ' | sort | uniq -d | sed 's/=$$//'); \
	if [ -n "$$dupes" ]; then \
	  echo "✗ $(ENV_FILE) defines these keys more than once:"; \
	  for d in $$dupes; do echo "    $$d"; done; \
	  echo "  The LAST definition wins and the earlier one is invisible. Delete the duplicates."; \
	  exit 1; \
	fi
	@origin=$$(grep -E "^[[:space:]]*FRONTEND_BASE_URL=" $(ENV_FILE) | tail -1 | cut -d= -f2-); \
	case "$(BB_ENV)-$$origin" in \
	  prod-http://localhost*|prod-https://localhost*) \
	    echo "✗ prod, but FRONTEND_BASE_URL is $$origin — that is a dev value in $(ENV_FILE)."; exit 1;; \
	  dev-http://localhost|dev-http://localhost:*) ;; \
	  dev-*) echo "  note: dev, but FRONTEND_BASE_URL is $$origin (not localhost) — intended?";; \
	esac
	@echo "✓ docker, compose plugin and $(ENV_FILE) all present ($(BB_ENV))"

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
	@echo "Started $(BB_ENV) from $(ENV_FILE) at $(FRONTEND_BASE_URL)."
	@echo "Give it a minute, then: make verify $(BB_ENV)"

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
# Everything below dials localhost ON PURPOSE, in production too: you run this ON the host, and
# port 80 there is HAProxy itself. Going via FRONTEND_BASE_URL would drag DNS, TLS and whatever
# sits in front into a check meant to answer one question — is this stack serving?
verify:
	$(call require_env)
	@echo "→ $(BB_ENV) ($(ENV_FILE)), serving as $(FRONTEND_BASE_URL)"
	@echo ""
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
