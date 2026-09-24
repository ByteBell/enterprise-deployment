#!/usr/bin/env bash
# =============================================================================
# install.sh — the one command that brings this deployment up.
#
#     ./install.sh --env prod      the real host, on its own domain.  .production.env
#     ./install.sh --env dev       a laptop or test box, on http://localhost, using
#                                  databases you already run somewhere.  .env
#     ./install.sh --env local     the same, except MongoDB and Neo4j run HERE as
#                                  containers and one superadmin signs in by email and
#                                  password — no database elsewhere, no OAuth app
#                                  to register.  .localhost.env
#
# That is the only parameter. Everything else — logging in to the registry, which release
# to pull, which containers exist, taking the old ones down, bringing the databases up
# before the services that need them, waiting until the stack actually serves, seeding the
# superadmin — is decided here, so two people running the same command get the same stack.
#
# NOTHING IS BUILT. This package carries no source: every service is an image pulled from
# the registry, told apart by tag. Inside the ByteBell monorepo, `make build` there builds every
# image as <service>-local, and IMAGE_TAG=local in the env file runs those instead of pulling.
#
# Safe to run again — that is also how you upgrade. Containers are recreated; volumes,
# and so your data, are kept.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ── 0. The one parameter ─────────────────────────────────────────────────────
usage() {
  cat >&2 <<EOF
usage: $0 --env prod|dev|local
         (production, development and localhost mean the same three)

  prod    the real host, on its own domain                      (.production.env)
  dev     a laptop or test box, databases run elsewhere         (.env)
  local   a laptop, MongoDB + Neo4j run here, email+password    (.localhost.env)

First run: copy the matching template and fill it in.
  prod   cp .env.production.example .production.env
  dev    cp .env.example            .env
  local  cp .env.localhost.example  .localhost.env
EOF
  exit 2
}

ENV_NAME=""
case "${1:-}" in
  --env)   ENV_NAME="${2:-}"; [ $# -eq 2 ] || usage ;;
  --env=*) ENV_NAME="${1#--env=}"; [ $# -eq 1 ] || usage ;;
  *)       usage ;;
esac

# The obvious words people type are the long ones, so take them as the same thing rather
# than answering an unambiguous request with the usage text.
case "$ENV_NAME" in
  production)  ENV_NAME=prod ;;
  development) ENV_NAME=dev ;;
  localhost)   ENV_NAME=local ;;
esac

# ── Per-environment wiring — the only place the three differ ────────────────
case "$ENV_NAME" in
  prod)  ENV_FILE=".production.env"; TEMPLATE=".env.production.example"; PROFILE_ARGS=();                    LOCAL_DBS=no;  SEED=no ;;
  dev)   ENV_FILE=".env";            TEMPLATE=".env.example";            PROFILE_ARGS=();                    LOCAL_DBS=no;  SEED=no ;;
  local) ENV_FILE=".localhost.env";  TEMPLATE=".env.localhost.example";  PROFILE_ARGS=(--profile localhost); LOCAL_DBS=yes; SEED=yes ;;
  *)     usage ;;
esac

say() { printf '\n\033[1m→ %s\033[0m\n' "$*"; }
ok()  { printf '   ✓ %s\n' "$*"; }
die() { printf '\n✗ %s\n' "$*" >&2; exit 1; }
# Last definition wins, exactly as compose reads the file.
envget() { grep -E "^[[:space:]]*$1=" "$ROOT/$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }

# ── 1. Preflight — fail here with a sentence, not three layers down ─────────
say "preflight ($ENV_NAME)"

command -v docker >/dev/null 2>&1 || die "docker is not installed — see README, Step 1"
# On a fresh Ubuntu the daemon socket is root-owned until your user is in the `docker`
# group AND has logged out and back in, so fall back to sudo rather than failing.
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  elif [ -t 0 ] && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    die "cannot reach the Docker daemon as $USER — run this with sudo, or add yourself to the docker group"
  fi
fi
"${DOCKER[@]}" compose version >/dev/null 2>&1 || die "the docker compose plugin is missing — see README, Step 1"
ok "docker + compose${DOCKER[1]:+ (as root)}"

[ -f "$ROOT/$ENV_FILE" ] || die "$ENV_NAME needs $ENV_FILE, which does not exist.
    cp $TEMPLATE $ENV_FILE
  then fill it in — see README, Step 3."

required=(IMAGE_REGISTRY IMAGE_REPO_PREFIX IMAGE_REPO_NAME REGISTRY_USERNAME REGISTRY_TOKEN
          COMPOSE_PROJECT_DIR MONGODB_URI NEO4J_URI NEO4J_PASSWORD JWT_SECRET
          FILE_STORAGE_BACKEND FRONTEND_BASE_URL
          LLM_PROFILE INGEST_PROFILE FALLBACK_PROFILE AGENT_PROFILE)
[ "$SEED" = yes ] && required+=(SEED_ORG_NAME SEED_CLIENT_EMAIL SEED_CLIENT_PASSWORD)
# Guards system-manager's update API. localhost never runs system-manager, and its admin-server answers
# update requests with dev stubs, so the token is only asked of dev and prod.
[ "$ENV_NAME" = local ] || required+=(UPDATE_API_TOKEN)
case "$(envget FILE_STORAGE_BACKEND)" in
  s3)    required+=(S3_FILES_BUCKET) ;;
  local|"") ;;
  *)     die "FILE_STORAGE_BACKEND must be s3 or local, not \"$(envget FILE_STORAGE_BACKEND)\"" ;;
esac
missing=""
for k in "${required[@]}"; do [ -n "$(envget "$k")" ] || missing="$missing $k"; done
[ -z "$missing" ] || die "$ENV_FILE is missing values:$missing"

dupes=$(grep -oE "^[[:space:]]*[A-Z0-9_]+=" "$ROOT/$ENV_FILE" | tr -d ' ' | sort | uniq -d | sed 's/=$//' | tr '\n' ' ')
[ -z "$dupes" ] || die "$ENV_FILE defines these keys more than once — the LAST one silently wins and the
  earlier one still reads as though it were in force. Delete the duplicates:$dupes"

# Every profile template becomes a real profile file the first time, holding the templates'
# `replace-me-in-stack-settings` keys: the stack boots on them and the real keys are entered on
# the dashboard's Stack Settings page. A profile file that already exists is NEVER overwritten —
# it holds this deployment's own keys. (`llm/providers/` are the page's samples, not profiles.)
created=""
for tpl in "$ROOT"/llm/*.env.example; do
  f="${tpl%.example}"
  [ -e "$f" ] && continue
  cp "$tpl" "$f"
  created="$created ${f#"$ROOT"/}"
done
[ -z "$created" ] || ok "created from templates (enter their keys in Stack Settings):$created"

# A profile is a FILE named by its slot. A slot naming a file that is not there is what
# compose refuses on at start; a blank key inside the agent profile is what public-agent
# refuses to BOOT on. Both are caught here, by name.
for slot in "LLM_PROFILE:%s.env" "INGEST_PROFILE:ingest-%s.env" "FALLBACK_PROFILE:fallback-%s.env" "AGENT_PROFILE:agent-%s.env"; do
  k="${slot%%:*}"; pat="${slot#*:}"
  # shellcheck disable=SC2059
  f="llm/$(printf "$pat" "$(envget "$k")")"
  [ -f "$ROOT/$f" ] || die "$k=$(envget "$k") names $f, which does not exist.
  There is no llm/*.env.example of that name to create it from — pick a profile that exists."
done
agentf="llm/agent-$(envget AGENT_PROFILE).env"
for k in AGENT_LLM_BASE_URL AGENT_LLM_API_KEY AGENT_MODEL AGENT_REASONING_EFFORT AGENT_MAX_COMPLETION_TOKENS; do
  grep -qE "^[[:space:]]*$k=." "$ROOT/$agentf" || die "$agentf is missing $k — public-agent refuses to start without it."
done

# The knowledge server's boot gate, mirrored: the deployment route needs a credential and a
# top tier, and an IR phase on a provider OTHER than the deployment's cannot inherit either
# across a provider boundary — it needs its own.
llmf="llm/$(envget LLM_PROFILE).env"; ingf="llm/ingest-$(envget INGEST_PROFILE).env"
pget() { grep -E "^[[:space:]]*$2=" "$ROOT/$1" 2>/dev/null | tail -1 | cut -d= -f2-; }
for k in LLM_PROVIDER LLM_API_KEY SMARTEST_MODEL_NAME; do
  [ -n "$(pget "$llmf" "$k")" ] || die "$llmf is missing $k — the knowledge server would refuse to boot."
done
dep="$(pget "$llmf" LLM_PROVIDER)"
for ph in FILE UNIT; do
  prov="$(pget "$ingf" "${ph}_LLM_PROVIDER")"
  [ -n "$prov" ] && [ "$prov" != "$dep" ] || continue
  [ -n "$(pget "$ingf" "${ph}_LLM_API_KEY")" ] || die "$ingf: ${ph}_LLM_API_KEY is blank, and ${ph} runs on $prov rather than the deployment's $dep — it cannot inherit the key across a provider boundary."
  [ -n "$(pget "$ingf" "${ph}_SMART_MODELS")$(pget "$ingf" "${ph}_SMARTER_MODELS")$(pget "$ingf" "${ph}_SMARTEST_MODELS")" ] \
    || die "$ingf: ${ph} runs on $prov and names no models — set ${ph}_SMART*_MODELS."
done
ok "$ENV_FILE complete; profiles llm=$(envget LLM_PROFILE) ingest=$(envget INGEST_PROFILE) fallback=$(envget FALLBACK_PROFILE) agent=$(envget AGENT_PROFILE)"

# A dev value on a reachable host is how a production sign-in ends up trusting localhost.
origin="$(envget FRONTEND_BASE_URL)"
case "$ENV_NAME-$origin" in
  prod-http://localhost*|prod-https://localhost*) die "prod, but FRONTEND_BASE_URL is $origin — that is a dev value in $ENV_FILE." ;;
  dev-http://localhost|dev-http://localhost:*|local-http://localhost|local-http://localhost:*) ;;
  dev-*|local-*) printf '   note: %s, but FRONTEND_BASE_URL is %s (not localhost) — intended?\n' "$ENV_NAME" "$origin" ;;
esac

# The stack listens on :80. Another compose project holding it is the usual reason a fresh
# install "comes up" and then serves someone else's containers.
PROJECT_NAME="$(envget COMPOSE_PROJECT_NAME)"; PROJECT_NAME="${PROJECT_NAME:-bb-stack}"
# The project name also names every volume (<project>_mongo_data …). `local` and `dev` are the
# development environments' — production under either would attach their data. The check is
# production's only: dev and local are exactly those names.
if [ "$ENV_NAME" = prod ]; then
  case "$PROJECT_NAME" in
    local|dev) die "COMPOSE_PROJECT_NAME=$PROJECT_NAME belongs to a development environment — production needs its own (e.g. prod), or it shares their volumes" ;;
  esac
fi
holder=$("${DOCKER[@]}" ps --format '{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}' \
  | awk -F'\t' '$2 ~ /(^|[^0-9])80->/ && $3 != "'"$PROJECT_NAME"'" {print $1" (compose project "$3")"}' | head -1)
[ -z "$holder" ] || die "port 80 is held by $holder, which this install would not replace — stop that stack first."

# ── 2. Which release to run ─────────────────────────────────────────────────
# There is no `latest` tag to point at — every tag names a service AND a version
# (ingestion-engine-5.4.1) — so a blank IMAGE_TAG has to be looked up. Anything set
# explicitly is used as-is: pinning is how a deployment is held still, and how it rolls back.
IMAGE_TAG="$(envget IMAGE_TAG)"
if [ -n "$IMAGE_TAG" ]; then
  say "release $IMAGE_TAG (pinned in $ENV_FILE)"
else
  say "IMAGE_TAG is blank — asking the registry for the newest release"
  jwt=$(curl -s --max-time 20 -H "Content-Type: application/json" \
          -d "{\"username\":\"$(envget REGISTRY_USERNAME)\",\"password\":\"$(envget REGISTRY_TOKEN)\"}" \
          https://hub.docker.com/v2/users/login/ | grep -oE '"token":"[^"]+"' | cut -d'"' -f4)
  [ -n "$jwt" ] || die "registry login failed — check REGISTRY_USERNAME and REGISTRY_TOKEN in $ENV_FILE."
  IMAGE_TAG=$(curl -s --max-time 20 -H "Authorization: JWT $jwt" \
      "https://hub.docker.com/v2/repositories/$(envget IMAGE_REPO_PREFIX)/$(envget IMAGE_REPO_NAME)/tags?page_size=100" \
    | tr ',' '\n' | grep -oE '"name":"ingestion-engine-[0-9]+\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*ingestion-engine-([0-9.]+)"/\1/' | sort -V | tail -1)
  [ -n "$IMAGE_TAG" ] || die "could not read the newest release from $(envget IMAGE_REGISTRY) — set IMAGE_TAG in $ENV_FILE yourself."
  ok "newest release is $IMAGE_TAG"
fi
export IMAGE_TAG
# IMAGE_TAG=local names images the monorepo's `make build` made on this machine. They are in no
# registry: nothing to log in to, nothing to pull, and `pull_policy: always` must not replace them.
[ "$ENV_NAME" != prod ] || [ "$IMAGE_TAG" != local ] || die "IMAGE_TAG=local in $ENV_FILE: production runs released tags, never a local build."
if [ "$IMAGE_TAG" = local ]; then export PULL_POLICY=never; else export PULL_POLICY=always; fi

# ── The compose command, pinned to the selected file ────────────────────────
# --env-file feeds ${VAR} interpolation; the exported ENV_FILE is what the `env_file:`
# entries inside the compose file expand to. Both must name the same file, or the containers
# read one file while the compose file was interpolated from another and nothing reports it.
export ENV_FILE
# Names every container <environment>-<service> — see the header of docker-compose.yml.
export STACK_ENV="$ENV_NAME"
# local and dev also get the Stack Settings page (docker-compose.stack-settings.yml mounts the Docker
# socket into admin-server); prod never does. admin-server is told the file list and profiles, and
# recreates containers with the same ones.
if [ "$ENV_NAME" = prod ]; then
  export COMPOSE_FILE=docker-compose.yml COMPOSE_PROFILES=
else
  export COMPOSE_FILE=docker-compose.yml:docker-compose.stack-settings.yml
  if [ "$ENV_NAME" = local ]; then export COMPOSE_PROFILES=localhost; else export COMPOSE_PROFILES=; fi
  # Stack Settings recreates containers by running compose in COMPOSE_PROJECT_DIR.
  [ "$(envget COMPOSE_PROJECT_DIR)" = "$ROOT" ] || die "$ENV_FILE sets COMPOSE_PROJECT_DIR=$(envget COMPOSE_PROJECT_DIR), but this directory is $ROOT — set it to $ROOT"
fi
compose() { "${DOCKER[@]}" compose --env-file "$ENV_FILE" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} "$@"; }

# mongosh inside the local mongodb container, with MONGODB_URI's credentials parsed in JS (so a
# password with URL-escaped characters is decoded exactly as the driver decodes it). Connects to
# 127.0.0.1, which is what the localhost exception requires.
mongo_eval() {
  compose exec -T -e URI="$(envget MONGODB_URI)" mongodb mongosh --quiet --eval "
    const u = new URL(process.env.URI);
    const creds = { user: decodeURIComponent(u.username), pwd: decodeURIComponent(u.password) };
    const authDb = db.getSiblingDB(u.searchParams.get('authSource') || 'admin');
    $1"
}

# ── 3. Pull ─────────────────────────────────────────────────────────────────
if [ "$PULL_POLICY" = never ]; then
  say "IMAGE_TAG=local — using the images make build made, nothing is pulled"
  missing=""
  for img in $(compose config --images 2>/dev/null | grep -F "/$(envget IMAGE_REPO_PREFIX)/$(envget IMAGE_REPO_NAME):" | sort -u); do
    "${DOCKER[@]}" image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
  done
  [ -z "$missing" ] || die "these images are not on this machine — build them with 'make build' in the ByteBell monorepo:$missing"
  ok "every image is present"
else
  say "pulling $IMAGE_TAG"
  printf '%s' "$(envget REGISTRY_TOKEN)" | "${DOCKER[@]}" login "$(envget IMAGE_REGISTRY)" \
    --username "$(envget REGISTRY_USERNAME)" --password-stdin >/dev/null \
    || die "could not log in to $(envget IMAGE_REGISTRY) as $(envget REGISTRY_USERNAME)."
  compose pull
  ok "pulled"
fi

# ── 4. Replace the running containers ───────────────────────────────────────
# Down first, so nothing from a previous layout survives — a service renamed or removed
# since the last install is not left running beside the new set. Volumes are kept: the
# queues, the chat memory and (under `local`) the databases themselves live in them.
say "removing the previous containers (volumes are kept)"
compose down --remove-orphans

# Bind-mounted paths must exist first: Docker creates a missing one root-owned, and the
# service then cannot write its logs into it.
mkdir -p logs/admin-server logs/email-dispatcher logs/knowledge-server \
         logs/mcp/mcp-1 logs/mcp/mcp-2 logs/mcp/mcp-3 logs/mcp/mcp-4 temp

if [ "$LOCAL_DBS" = yes ]; then
  # The services exit when they cannot reach Mongo or Neo4j and restart until they can, and
  # Neo4j takes tens of seconds to accept a query. Bring both to HEALTHY first rather than
  # letting every service crash-loop through that window.
  say "starting MongoDB and Neo4j, waiting until they accept queries"
  compose up -d --wait mongodb neo4j
  ok "databases healthy"

  # MongoDB runs with --auth. Its first user is created from MONGODB_URI through the localhost
  # exception, which admits exactly one first user; on every later run the same credentials must
  # simply authenticate. Idempotent either way.
  mongo_user=$(mongo_eval 'try { authDb.auth(creds.user, creds.pwd); print("exists"); }
    catch (e) { authDb.createUser({ user: creds.user, pwd: creds.pwd, roles: [{ role: "root", db: "admin" }] }); print("created"); }' 2>&1 | tail -1)
  case "$mongo_user" in
    exists)  ok "MongoDB user from MONGODB_URI authenticates" ;;
    created) ok "MongoDB user from MONGODB_URI created" ;;
    *)       die "MongoDB rejects the user and password in MONGODB_URI ($mongo_user) — put back the password the database was created with." ;;
  esac
fi

say "starting the stack"
compose up -d --remove-orphans

# ── 5. Wait until it SERVES — "the containers are up" is not the same thing ──
# A live route in front of a dead backend answers 503 and still looks healthy in `ps`.
# localhost on purpose, in production too: you are ON the host, and :80 here is HAProxy.
say "waiting for the stack to serve"
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost$1" 2>/dev/null || echo 000; }
a=000; k=000
for _ in $(seq 1 60); do
  a=$(probe /api/admin/health); k=$(probe /api/knowledge/health)
  [ "$a" = 200 ] && [ "$k" = 200 ] && break
  sleep 5
done
[ "$a" = 200 ] || die "the admin API is not serving (HTTP $a) after 5 minutes — look at: ./install.sh logs, or docker compose --env-file $ENV_FILE logs admin-server"
[ "$k" = 200 ] || die "the knowledge API is not serving (HTTP $k) after 5 minutes — look at: docker compose --env-file $ENV_FILE logs knowledge-server"
ok "admin API and knowledge API answer 200"

# ── 6. local: the one superadmin ─────────────────────────────────────────────
if [ "$SEED" = yes ]; then
  # The seed binary ships inside the ingestion-engine image and reads SEED_* from the env
  # file the container already has: it creates the organisation and the SEED_CLIENT_* user
  # as its admin. That user is then promoted to superadmin in the mongodb container. Both
  # steps are idempotent, so a re-run after changing a value is how you apply it.
  say "seeding organisation '$(envget SEED_ORG_NAME)' and superadmin $(envget SEED_CLIENT_EMAIL)"
  compose exec -T admin-server /app/bytebell-seed
  admin_db="$(envget ADMIN_DATABASE_NAME)"; admin_db="${admin_db:-app_backend_v2}"
  matched=$(mongo_eval "authDb.auth(creds.user, creds.pwd);
    print(db.getSiblingDB('$admin_db').users.updateOne({email:'$(envget SEED_CLIENT_EMAIL)'},{\$set:{user_role:'super_admin'}}).matchedCount)" | tail -1 | tr -d '[:space:]')
  [ "$matched" = 1 ] || die "the seed did not create $(envget SEED_CLIENT_EMAIL) — read the seed output above."
  ok "superadmin ready"
fi

# ── 7. Done ──────────────────────────────────────────────────────────────────
say "running $IMAGE_TAG"
compose ps --format 'table {{.Service}}\t{{.Status}}'
cat <<EOF

  Dashboard      $origin/admin
  Admin API      $origin/api/admin/health
  Knowledge API  $origin/api/knowledge/health
  HAProxy stats  http://localhost:8404/stats
EOF
if [ "$SEED" = yes ]; then
  cat <<EOF
  Sign in        $origin/auth/login  as $(envget SEED_CLIENT_EMAIL)
                 the password is SEED_CLIENT_PASSWORD in $ENV_FILE
  MongoDB        mongodb://127.0.0.1:$(envget MONGODB_HOST_PORT)
  Neo4j browser  http://127.0.0.1:$(envget NEO4J_HTTP_HOST_PORT)
EOF
fi
cat <<EOF

  Upgrading is this same command again. Pin IMAGE_TAG in $ENV_FILE to hold this
  deployment still, or to roll back.
EOF
