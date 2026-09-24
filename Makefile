.PHONY: dev prod localhost local help superadmin preflight login pull up down restart ps logs verify update dirs publish

# `sudo` by default, because that is how Docker is installed on a fresh Ubuntu host: the daemon
# socket is root-owned until your user is in the `docker` group AND you have logged out and back in.
# Once that is true, run any target with DOCKER=docker to drop it:
#
#     make up DOCKER=docker
#
# Keep it consistent within a deployment. `make login` writes credentials to the config of whichever
# user runs it, and `make pull` must run as that same user or it cannot read them — a login as
# yourself followed by a pull under sudo is the most common "pull access denied" on a private repo.
#
# When Docker already answers without sudo (Docker Desktop, or a user in the `docker` group), plain
# `docker` is used — the same choice install.sh makes.
DOCKER ?= $(shell docker info >/dev/null 2>&1 && echo docker || echo sudo docker)

# ── Which deployment this invocation is for ──────────────────────────────────
#
#     make up prod       → .production.env    the real host, on its own domain
#     make up dev        → .env               a laptop or test box, on http://localhost, using
#                                             databases you already run somewhere
#     make up local      → .localhost.env     the same, plus MongoDB and Neo4j started HERE as
#                                             containers (the `localhost` compose profile).
#                                             `localhost` is the same goal.
#     make up            → .env               same as dev; the default is never production
#
# `dev`, `prod` and `localhost` are GOALS rather than variables, so they are read out of
# MAKECMDGOALS and declared as do-nothing targets below.
#
# ONE COMPLETE FILE PER DEPLOYMENT, not a shared base with an overlay. Two files that both define
# a key are how a stack ends up running settings nobody can see in the file they are reading: the
# last definition silently wins, and the losing one looks perfectly correct sitting above it.
BB_ENV        := $(if $(filter prod,$(MAKECMDGOALS)),prod,$(if $(filter localhost local,$(MAKECMDGOALS)),localhost,dev))
ENV_FILE_dev   = .env
ENV_FILE_prod  = .production.env
ENV_FILE_localhost = .localhost.env
# The two database containers exist only under this compose profile, so only `localhost` sees
# them — in `ps`, `logs`, `pull`, `up` and `down` alike. `dev` and `prod` never start a database.
COMPOSE_PROFILE := $(if $(filter localhost,$(BB_ENV)),--profile localhost)
ENV_FILE      := $(ENV_FILE_$(BB_ENV))
export ENV_FILE
# Names every container <environment>-<service> — see the header of docker-compose.yml.
STACK_ENV     := $(if $(filter localhost,$(BB_ENV)),local,$(BB_ENV))
export STACK_ENV
# local and dev also get the Stack Settings page (docker-compose.stack-settings.yml mounts the Docker
# socket into admin-server); prod never does. COMPOSE_PROFILES says the same as $(COMPOSE_PROFILE) —
# exported too, because admin-server is told it and recreates containers under the same profiles.
COMPOSE_FILE     := docker-compose.yml$(if $(filter prod,$(BB_ENV)),,:docker-compose.stack-settings.yml)
COMPOSE_PROFILES := $(if $(filter localhost,$(BB_ENV)),localhost)
export COMPOSE_FILE COMPOSE_PROFILES

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
# `latest` — on the command line, `make up local IMAGE_TAG=latest` — asks for the same lookup, so an
# env file pinned to a version or to `local` can still run the newest release without being edited.
# `override`: a command-line IMAGE_TAG would otherwise win over the resolved value.
ifneq ($(filter-out latest,$(strip $(IMAGE_TAG))),$(strip $(IMAGE_TAG)))
  override IMAGE_TAG :=
endif
ifeq ($(strip $(IMAGE_TAG)),)
  ifneq ($(filter pull up update,$(MAKECMDGOALS)),)
    ifneq ($(wildcard $(ENV_FILE)),)
      override IMAGE_TAG := $(shell $(latest_tag_sh))
      ifeq ($(strip $(IMAGE_TAG)),)
        $(error IMAGE_TAG is unset and the newest release could not be read from $(IMAGE_REGISTRY). \
                Check REGISTRY_USERNAME and REGISTRY_TOKEN in $(ENV_FILE), or set IMAGE_TAG yourself)
      endif
      $(info → using the newest published release: $(IMAGE_TAG))
    endif
  endif
endif
export IMAGE_TAG

# ── IMAGE_TAG=local: run what the monorepo's `make build` made on this machine ──
#
# `make build` in the ByteBell monorepo tags every image <service>-local under the same registry path
# this compose file runs. Those images exist in no registry, so for them there is nothing to log in
# to and nothing to pull — pulling would fail, and `pull_policy: always` would replace a build with a
# download. A deployment without the monorepo never sets this; it runs released tags.
LOCAL_BUILD := $(filter local,$(strip $(IMAGE_TAG)))
PULL_POLICY := $(if $(LOCAL_BUILD),never,always)
export PULL_POLICY

# `sudo` resets the environment, so a resolved IMAGE_TAG and the selected ENV_FILE never reach
# docker on their own — they have to be handed over explicitly. Without sudo, `export` above is
# enough and DOCKER is used unchanged.
# LLM provider profiles. The env file names them (LLM_PROFILE / INGEST_PROFILE → llm/<name>.env,
# loaded by every service's env_file: list); `make up prod LLM=openrouter INGEST=baseten FALLBACK=none` overrides
# them for one invocation — a shell variable outranks --env-file in compose interpolation.
PROFILE_ENV = $(if $(LLM),LLM_PROFILE=$(LLM)) $(if $(INGEST),INGEST_PROFILE=$(INGEST)) $(if $(FALLBACK),FALLBACK_PROFILE=$(FALLBACK))
DOCKER_ENV = $(if $(filter sudo,$(firstword $(DOCKER))),\
               sudo env IMAGE_TAG=$(IMAGE_TAG) PULL_POLICY=$(PULL_POLICY) ENV_FILE=$(ENV_FILE) STACK_ENV=$(STACK_ENV) COMPOSE_FILE=$(COMPOSE_FILE) COMPOSE_PROFILES=$(COMPOSE_PROFILES) $(PROFILE_ENV) $(wordlist 2,99,$(DOCKER)),\
               $(PROFILE_ENV) $(DOCKER))

# Both are needed and they are NOT the same thing. `--env-file` feeds ${VAR} substitution in
# docker-compose.yml; the exported ENV_FILE is what the `env_file:` entries inside it expand to,
# and those the flag does not touch. Set only one and the containers read one file while the
# compose file was interpolated from another — the values disagree and nothing reports it.
COMPOSE = $(DOCKER_ENV) compose --env-file $(ENV_FILE) $(COMPOSE_PROFILE)

# Refuse rather than fall back. Silently using .env because .production.env is absent is how a
# laptop's settings reach a production host.
define require_env
	@test -f $(ENV_FILE) || { \
		echo "✗ $(BB_ENV) needs $(ENV_FILE), which does not exist."; \
		echo "    dev       → .env              cp .env.example .env"; \
		echo "    prod      → .production.env   cp .env.production.example .production.env"; \
		echo "    local     → .localhost.env    cp .env.localhost.example .localhost.env"; \
		exit 1; \
	}
endef

# mongosh inside the local mongodb container, authenticated as the MONGODB_URI user. The URI is
# parsed in JS so a password with URL-escaped characters is decoded exactly as the driver decodes it.
# `$(1)` runs after `creds` and `authDb` are defined. Connects to 127.0.0.1, which is what the
# localhost exception (the one unauthenticated createUser) requires.
# The scripts are variables because `$(call)` splits its arguments at commas, and a variable's
# commas are not split. Recursive (`=`), so the `$$` in them survives to the shell as a literal `$`.
MONGO_ENSURE_USER_JS = try { authDb.auth(creds.user, creds.pwd); print('exists'); } \
  catch (e) { authDb.createUser({ user: creds.user, pwd: creds.pwd, roles: [{ role: 'root', db: 'admin' }] }); print('created'); }
MONGO_SUPERADMIN_JS = authDb.auth(creds.user, creds.pwd); \
  const r = db.getSiblingDB('$(or $(ADMIN_DATABASE_NAME),app_backend_v2)').users.updateOne({email:'$(SEED_CLIENT_EMAIL)'},{\$$set:{user_role:'super_admin'}}); \
  print(r.matchedCount ? 'ok' : 'NO SUCH USER — did the seed step fail?')
define mongo_eval
$(COMPOSE) exec -T -e URI='$(MONGODB_URI)' mongodb mongosh --quiet --eval " \
  const u = new URL(process.env.URI); \
  const creds = { user: decodeURIComponent(u.username), pwd: decodeURIComponent(u.password) }; \
  const authDb = db.getSiblingDB(u.searchParams.get('authSource') || 'admin'); \
  $(1)"
endef

# Goal sinks, so `make up prod` does not report "No rule to make target 'prod'".
dev prod localhost local:
	@:


help:
	@echo "Plumbline — enterprise deployment"
	@echo ""
	@echo "  Every target takes the deployment as the last word:"
	@echo "    make up prod        the real host, reading .production.env"
	@echo "    make up dev         a laptop or test box, reading .env  (the default)"
	@echo "    make up local       a laptop, reading .localhost.env, with MongoDB + Neo4j run here"
	@echo "                        (localhost is the same goal)"
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
	@echo "  First run — local, nothing to run elsewhere:"
	@echo "    cp .env.localhost.example .localhost.env && \$$EDITOR .localhost.env"
	@echo "    make up local"
	@echo "    make superadmin local   Create the email+password superadmin named in the env file"
	@echo ""
	@echo "  In the ByteBell monorepo — images built from source instead of pulled:"
	@echo "    set IMAGE_TAG=local in the env file, run 'make build' in the monorepo, then 'make up local|dev'"
	@echo "    make up local IMAGE_TAG=latest    Pull and run the newest release instead, env file untouched"
	@echo "    make up local IMAGE_TAG=5.4.2     Pull and run that release"
	@echo "    make publish prod VERSION=x.y.z   Multi-arch build + push, via the monorepo's release"
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
	@echo "  Current: $(BB_ENV) ($(ENV_FILE))  IMAGE_TAG=$(if $(strip $(IMAGE_TAG)),$(IMAGE_TAG)$(if $(LOCAL_BUILD), (built by make build — never pulled)),<unset — newest release is resolved on pull>)"
	@echo "           registry=$(IMAGE_REGISTRY)/$(IMAGE_REPO_PREFIX)/$(IMAGE_REPO_NAME)"

# Fail here, with a sentence, rather than three layers down in a container log.
preflight:
	@command -v docker >/dev/null 2>&1 || { echo "✗ docker is not installed — see README, Step 1"; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "✗ the docker compose plugin is missing — see README, Step 1"; exit 1; }
	$(call require_env)
	@missing=""; for k in IMAGE_REGISTRY IMAGE_REPO_PREFIX IMAGE_REPO_NAME REGISTRY_USERNAME \
	  REGISTRY_TOKEN COMPOSE_PROJECT_DIR MONGODB_URI NEO4J_URI NEO4J_PASSWORD JWT_SECRET \
	  UPDATE_API_TOKEN S3_FILES_BUCKET FRONTEND_BASE_URL LLM_PROFILE INGEST_PROFILE \
	  FALLBACK_PROFILE AGENT_PROFILE; do \
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
	@# A profile is a FILE named by its slot. A slot naming a file that is not there is what compose
	@# would refuse on at start; a blank key inside the agent profile is what public-agent would
	@# refuse to BOOT on. Both are caught here, by name, rather than three layers down.
	@missing=""; for slot in LLM_PROFILE:llm/%s.env INGEST_PROFILE:llm/ingest-%s.env \
	  FALLBACK_PROFILE:llm/fallback-%s.env AGENT_PROFILE:llm/agent-%s.env; do \
	  k=$${slot%%:*}; pat=$${slot#*:}; \
	  name=$$(grep -E "^[[:space:]]*$$k=" $(ENV_FILE) | tail -1 | cut -d= -f2-); \
	  f=$$(printf "$$pat" "$$name"); \
	  [ -f "$$f" ] || missing="$$missing $$k=$$name->$$f"; \
	done; \
	if [ -n "$$missing" ]; then echo "✗ a profile named in $(ENV_FILE) has no file:"; for m in $$missing; do echo "    $$m"; done; \
	  echo "  Copy the matching llm/*.env.example to that name and fill it in — see README, Step 3b."; exit 1; fi
	@agent=$$(grep -E "^[[:space:]]*AGENT_PROFILE=" $(ENV_FILE) | tail -1 | cut -d= -f2-); f="llm/agent-$$agent.env"; missing=""; \
	for k in AGENT_LLM_BASE_URL AGENT_LLM_API_KEY AGENT_MODEL AGENT_REASONING_EFFORT AGENT_MAX_COMPLETION_TOKENS; do \
	  v=$$(grep -E "^[[:space:]]*$$k=" "$$f" | tail -1 | cut -d= -f2-); \
	  [ -z "$$v" ] && missing="$$missing $$k"; \
	done; \
	if [ -n "$$missing" ]; then echo "✗ $$f is missing values:"; for m in $$missing; do echo "    $$m"; done; \
	  echo "  public-agent refuses to start without every one of these."; exit 1; fi
	@# The knowledge server's boot gate, mirrored. It refuses to start unless the deployment route has
	@# a credential and a top tier, and unless every IR phase on a provider OTHER than the deployment's
	@# carries its own credential and at least one tier — a phase cannot inherit either across a
	@# provider boundary. Assumes hosted providers; a keyless one (ollama, claude-cli) would be
	@# over-checked here and is not something this stack deploys. Measured on a real upgrade: the
	@# ingest template ships FILE_LLM_API_KEY blank, and the server crash-looped on exactly that.
	@get() { grep -E "^[[:space:]]*$$2=" "$$1" 2>/dev/null | tail -1 | cut -d= -f2-; }; \
	llm=$$(get $(ENV_FILE) LLM_PROFILE); lf="llm/$$llm.env"; ing=$$(get $(ENV_FILE) INGEST_PROFILE); inf="llm/ingest-$$ing.env"; missing=""; \
	for k in LLM_PROVIDER LLM_API_KEY SMARTEST_MODEL_NAME; do [ -n "$$(get $$lf $$k)" ] || missing="$$missing $$lf:$$k"; done; \
	dep=$$(get $$lf LLM_PROVIDER); \
	for ph in FILE UNIT; do prov=$$(get $$inf $${ph}_LLM_PROVIDER); \
	  if [ -n "$$prov" ] && [ "$$prov" != "$$dep" ]; then \
	    [ -n "$$(get $$inf $${ph}_LLM_API_KEY)" ] || missing="$$missing $$inf:$${ph}_LLM_API_KEY"; \
	    [ -n "$$(get $$inf $${ph}_SMART_MODELS)$$(get $$inf $${ph}_SMARTER_MODELS)$$(get $$inf $${ph}_SMARTEST_MODELS)" ] || missing="$$missing $$inf:$${ph}_SMART*_MODELS"; \
	  fi; \
	done; \
	if [ -n "$$missing" ]; then echo "✗ the knowledge server would refuse to boot — blank in a profile:"; for m in $$missing; do echo "    $$m"; done; \
	  echo "  A phase on a provider other than LLM_PROVIDER cannot inherit the deployment's key or tiers; set its own."; exit 1; fi
	@origin=$$(grep -E "^[[:space:]]*FRONTEND_BASE_URL=" $(ENV_FILE) | tail -1 | cut -d= -f2-); \
	case "$(BB_ENV)-$$origin" in \
	  prod-http://localhost*|prod-https://localhost*) \
	    echo "✗ prod, but FRONTEND_BASE_URL is $$origin — that is a dev value in $(ENV_FILE)."; exit 1;; \
	  dev-http://localhost|dev-http://localhost:*|localhost-http://localhost|localhost-http://localhost:*) ;; \
	  dev-*|localhost-*) echo "  note: $(BB_ENV), but FRONTEND_BASE_URL is $$origin (not localhost) — intended?";; \
	esac
	@# Stack Settings recreates containers by running compose in COMPOSE_PROJECT_DIR, so on local and
	@# dev it has to BE this directory.
	@dir=$$(grep -E "^[[:space:]]*COMPOSE_PROJECT_DIR=" $(ENV_FILE) | tail -1 | cut -d= -f2-); \
	if [ "$(BB_ENV)" != prod ] && [ "$$dir" != "$(CURDIR)" ]; then \
	  echo "✗ $(ENV_FILE) sets COMPOSE_PROJECT_DIR=$$dir, but this directory is $(CURDIR) — set it to $(CURDIR)"; exit 1; fi
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

ifeq ($(LOCAL_BUILD),)
pull: preflight login
	$(COMPOSE) pull
else ifeq ($(BB_ENV),prod)
pull:
	@echo "✗ IMAGE_TAG=local in $(ENV_FILE): production runs released tags, never a local build"; exit 1
else
# Nothing to pull — but every image of ours has to be here, or `up` fails one service at a time.
# Only ours: redis, haproxy, mongo and neo4j are public and compose pulls them as usual.
pull: preflight
	@missing=""; for img in $$($(COMPOSE) config --images 2>/dev/null | grep -F '/$(IMAGE_REPO_PREFIX)/$(IMAGE_REPO_NAME):' | sort -u); do \
	  $(DOCKER) image inspect "$$img" >/dev/null 2>&1 || missing="$$missing $$img"; \
	done; \
	if [ -n "$$missing" ]; then echo "✗ IMAGE_TAG=local, but these images are not on this machine:"; \
	  for m in $$missing; do echo "    $$m"; done; \
	  echo "  Build them with 'make build' in the ByteBell monorepo."; exit 1; fi
	@echo "✓ IMAGE_TAG=local — running the images make build made; nothing is pulled"
endif

up: dirs pull
# The services connect to Mongo and Neo4j at boot and exit when they cannot, then restart until
# they can. Neo4j takes tens of seconds to accept a query, so bring the databases to HEALTHY
# first rather than letting every service crash-loop through that window.
ifeq ($(BB_ENV),localhost)
	$(COMPOSE) up -d --wait mongodb neo4j
	@# MongoDB runs with --auth. Its first user is created from MONGODB_URI; on every later start the
	@# same credentials must authenticate. Idempotent either way.
	@r=$$($(call mongo_eval,$(MONGO_ENSURE_USER_JS)) 2>&1 | tail -1); \
	case "$$r" in \
	  exists)  echo "✓ MongoDB user from MONGODB_URI authenticates";; \
	  created) echo "✓ MongoDB user from MONGODB_URI created";; \
	  *) echo "✗ MongoDB rejects the user and password in MONGODB_URI ($$r) — put back the password the database was created with"; exit 1;; \
	esac
endif
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
update: pull
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
ifeq ($(BB_ENV),localhost)
	@echo "→ databases (run here under the localhost profile)"
	@printf '   mongodb          '; $(COMPOSE) exec -T mongodb mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null || echo unreachable
	@printf '   neo4j            '; $(COMPOSE) exec -T neo4j cypher-shell -u neo4j -p '$(NEO4J_PASSWORD)' 'RETURN 1' >/dev/null 2>&1 && echo ok || echo unreachable
	@echo ""
endif
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

# The localhost stack signs in by email + password, with no OAuth app: create that account.
# Three steps, each idempotent — seed the organisation and the SEED_CLIENT_* user (the seed
# binary shipped in the ingestion-engine image, reading SEED_* from the env file the container
# already has), then promote that user to superadmin in the mongodb container. localhost only:
# on dev/prod the database is not ours to reach into, and the seed's org addresses are
# written for this compose file.
superadmin:
	$(call require_env)
	@test "$(BB_ENV)" = "localhost" || { echo "✗ superadmin is for the local deployment only (make superadmin local)"; exit 1; }
	@test -n "$(SEED_CLIENT_EMAIL)" -a -n "$(SEED_CLIENT_PASSWORD)" || { echo "✗ SEED_CLIENT_EMAIL and SEED_CLIENT_PASSWORD must be set in $(ENV_FILE)"; exit 1; }
	@echo "→ seeding organisation '$(SEED_ORG_NAME)' and user $(SEED_CLIENT_EMAIL)"
	$(COMPOSE) exec -T admin-server /app/bytebell-seed
	@echo "→ promoting $(SEED_CLIENT_EMAIL) to superadmin"
	@$(call mongo_eval,$(MONGO_SUPERADMIN_JS))
	@echo ""
	@echo "Sign in at $(FRONTEND_BASE_URL)/auth/login as $(SEED_CLIENT_EMAIL) with SEED_CLIENT_PASSWORD from $(ENV_FILE)."

# Publishing BUILDS — multi-arch (amd64 + arm64), because the servers this package runs on are not
# the machine it was built on — and so it needs the source, which lives in the ByteBell monorepo this
# package is checked out inside. A deployment has neither the source nor a push credential.
# VERSION, SEVERITY, CHANGELOG and ECR_PUSH on the command line travel to the monorepo's make.
publish:
	@test "$(BB_ENV)" = prod || { echo "✗ publish releases for production: make publish prod VERSION=x.y.z"; exit 1; }
	@test -n "$(VERSION)" || { echo "✗ usage: make publish prod VERSION=x.y.z [SEVERITY=critical] [CHANGELOG='msg'] [ECR_PUSH=true]"; exit 1; }
	@test -x ../scripts/local-release.sh || { echo "✗ publishing builds from source — run it from the enterprise-deployment/ inside the ByteBell monorepo"; exit 1; }
	$(MAKE) -C .. publish prod
