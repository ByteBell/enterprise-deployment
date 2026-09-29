#!/bin/sh
# =============================================================================
# dev-watch — the `dev-watch` service of docker-compose.dev.yml. Once a minute, applies every change
# to the working tree that the running dev containers do not pick up on their own.
# =============================================================================
# Source edits are NOT its job: `bun --watch` and Vite already reload those on save. What they miss:
#
#   env files, llm/ profiles, compose files  → `compose up -d`. Compose hashes each service's config,
#                                              env-file contents included, and recreates only a
#                                              service whose hash moved — so an unchanged tick is a no-op.
#   package.json / bun.lock of a repository  → reinstall (source-deps), then restart that repository's
#                                              services one at a time, so haproxy always has a replica.
#   admin-dashboard public/                  → restart admin-dashboard (public/ is rendered at start).
#   conversation-memory or a workspace       → rebuild its image and recreate it. It is bundled at build
#   package it depends on                      time and runs under Node, so it cannot be mounted.
#
# Everything works off the files on disk, committed or not. The first pass only records where things
# stand: `make up dev` has just applied all of it.
#
# Runs compose from inside a container, so the monorepo is mounted at its HOST path and compose here
# resolves every relative bind mount to the same host path the Makefile's compose did.
set -u

INTERVAL=60
cd "$COMPOSE_PROJECT_DIR" || exit 1
MONO=$(dirname "$COMPOSE_PROJECT_DIR")
IE="$MONO/services/ingestion-engine/repo"

log() { echo "$(date '+%H:%M:%S') $*"; }
compose() { docker compose --progress plain --env-file "$ENV_FILE" --env-file .db.env "$@"; }

# Same rule as the Makefile: the local mongodb / neo4j containers exist when .db.env names them.
local_dbs() {
  grep -qE '^[[:space:]]*(MONGODB_URI=.*(@|//)mongodb:|NEO4J_URI=.*//neo4j:)' .db.env && echo localhost || true
}

# Fingerprint = path, size and mtime of every file the arguments' `find` prints.
fp() { find "$@" 2>/dev/null | sort | xargs -r stat -c '%n %s %Y' 2>/dev/null | md5sum | cut -d' ' -f1; }
fp_deps() { fp "$1" -name node_modules -prune -o -type f \( -name package.json -o -name bun.lock \) -print; }

# @bytebell/<name> lives at packages/<name>; follow `workspace:` dependencies from conversation-memory.
memory_packages() {
  todo=conversation-memory; seen=""
  while [ -n "$todo" ]; do
    p=${todo%% *}; [ "$todo" = "$p" ] && todo="" || todo=${todo#* }
    case " $seen " in *" $p "*) continue ;; esac
    seen="$seen $p"
    for d in $(grep -oE '"@bytebell/[a-z0-9-]+": *"workspace:' "$IE/packages/$p/package.json" 2>/dev/null | sed -E 's#"@bytebell/([a-z0-9-]+)".*#\1#'); do
      todo="$todo $d"
    done
  done
  for p in $seen; do echo "$IE/packages/$p"; done
}
fp_memory() {
  fp $(memory_packages) "$IE/package.json" "$IE/bun.lock" "$MONO/services/ingestion-engine/Dockerfile" \
    -name node_modules -prune -o -type f -print
}

REPOS="ingestion-engine chat-mcp public-agent admin-dashboard"
repo_dir() {
  case "$1" in
    ingestion-engine) echo "$IE" ;;
    chat-mcp)         echo "$MONO/services/chat-mcp/repo" ;;
    public-agent)     echo "$MONO/services/public-agent" ;;
    admin-dashboard)  echo "$MONO/frontends/admin-dashboard/repo" ;;
  esac
}
repo_services() {
  case "$1" in
    ingestion-engine) echo "knowledge-server admin-server email-dispatcher" ;;
    chat-mcp)         echo "mcp-server-1 mcp-server-2 mcp-server-3 mcp-server-4" ;;
    public-agent)     echo "public-agent-1 public-agent-2" ;;
    admin-dashboard)  echo "admin-dashboard" ;;
  esac
}

# Every service except this one (compose recreating it would kill this loop mid-command) and the
# one-shot installer (`up` would re-run it).
app_services() { compose config --services | grep -vxE 'dev-watch|source-deps'; }

apply_config() {
  export COMPOSE_PROFILES="$(local_dbs)"
  if [ -n "$COMPOSE_PROFILES" ]; then
    compose up -d --no-deps --no-build --wait mongodb neo4j || log "✗ local databases did not come up"
  fi
  # shellcheck disable=SC2046
  compose up -d --no-deps --no-build --pull never $(app_services) 2>&1 | grep -vE ' (Running|Waiting|Healthy)$' || true
}

reinstall() {
  log "→ $1: dependencies changed — reinstalling"
  if ! compose run --rm -T --no-deps source-deps; then
    log "✗ install failed — fix package.json / bun.lock; nothing restarted"
    return 1
  fi
  for s in $(repo_services "$1"); do
    log "  restarting $s"
    compose restart "$s" >/dev/null || log "✗ $s did not restart"
  done
}

snapshot() {
  s_config=$(fp "$COMPOSE_PROJECT_DIR" -maxdepth 1 -type f \( -name '*.env' -o -name 'docker-compose*.yml' \) -print)
  s_llm=$(fp "$COMPOSE_PROJECT_DIR/llm" -maxdepth 1 -type f -name '*.env' -print)
  s_public=$(fp "$MONO/frontends/admin-dashboard/repo/public" -type f -print)
  s_memory=$(fp_memory)
  for r in $REPOS; do eval "s_deps_$(echo "$r" | tr - _)=\$(fp_deps \"\$(repo_dir $r)\")"; done
}

snapshot
p_config=$s_config; p_llm=$s_llm; p_public=$s_public; p_memory=$s_memory
for r in $REPOS; do v=$(echo "$r" | tr - _); eval "p_deps_$v=\$s_deps_$v"; done
log "watching every ${INTERVAL}s (project $COMPOSE_PROJECT_DIR)"

while sleep "$INTERVAL"; do
  # Stack Settings recreates containers itself; never race it.
  if docker ps --format '{{.Names}}' | grep -qx "${COMPOSE_PROJECT_NAME:-dev}-settings-apply"; then
    continue
  fi
  snapshot

  for r in $REPOS; do
    v=$(echo "$r" | tr - _)
    eval "now=\$s_deps_$v; was=\$p_deps_$v"
    # Recorded only once the install succeeds, so a broken lockfile is retried every tick.
    if [ "$now" != "$was" ] && reinstall "$r"; then eval "p_deps_$v=\$now"; fi
  done

  if [ "$s_memory" != "$p_memory" ]; then
    log "→ conversation-memory: source changed — rebuilding"
    if compose build conversation-memory && compose up -d --no-deps conversation-memory; then
      p_memory=$s_memory
    else
      log "✗ conversation-memory build failed — retrying next tick"
    fi
  fi

  if [ "$s_public" != "$p_public" ]; then
    log "→ admin-dashboard: public/ changed — restarting"
    compose restart admin-dashboard >/dev/null && p_public=$s_public
  fi

  if [ "$s_config" != "$p_config" ] || [ "$s_llm" != "$p_llm" ]; then
    log "→ env / compose files changed — recreating the services they affect"
    apply_config
    p_config=$s_config; p_llm=$s_llm
  fi
done
