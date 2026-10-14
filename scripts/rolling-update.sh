#!/usr/bin/env bash
# Bring the stack up to the images and config the env file names, without a gap in service.
#
# Run by `make up` / `make update` (prod and local); `ROLL_COMPOSE` is the Makefile's compose command,
# with its env files, profile and sudo already in it. A first start is just step 2; on a running stack
# only what changed is replaced, one container at a time, each one serving before the next is touched:
#
#   1. haproxy reloads its config (graceful, USR2) — so new backend slots exist before they are used
#   2. anything not running is started; nothing running is touched
#   3. single services that changed are recreated in place (admin-dashboard, email-dispatcher, …)
#   4. knowledge-server and admin-server — ONE copy each — are swapped through an update-time copy
#      (`<service>-next`, `surge` profile): it starts on the new image, haproxy reports it serving, the
#      original is replaced, then the copy is removed. knowledge-server hands its running jobs back to
#      the queue when stopped, so a running ingestion moves to the next worker instead of failing.
#   5. mcp-server-1..4 and public-agent-1/2 are replaced one replica at a time: haproxy drains it
#      first (public-agent waits for its runs to finish, up to DRAIN_TIMEOUT), then it is recreated and
#      put back. MCP clients on that replica reconnect to another — their sessions are not resumable.
#
# ROLL_FORCE=1 replaces every application container even when nothing changed — a rolling restart
# (`make restart`). haproxy, redis and the databases are never forced: recreating them IS the gap.
set -euo pipefail

: "${ROLL_COMPOSE:?run through make up / make update}"

# Seconds to wait for a replacement to serve, and for a drained public-agent replica to finish its runs.
UP_TIMEOUT=300
DRAIN_TIMEOUT=600
# After a container is replaced haproxy still reports the old one for a moment: it re-resolves the name at
# most every 10 s (`hold valid` in haproxy.cfg) and marks a server down only after failed checks. Waiting
# this long first means an `UP` read afterwards is about the new container, not the one that just left.
SETTLE=15

compose() { eval "$ROLL_COMPOSE \"\$@\""; }

FORCE=${ROLL_FORCE:-0}
UP=(-d --no-deps)
((FORCE)) && UP+=(--force-recreate)
# Never forced — recreating one of these takes the whole stack with it.
INFRA=" haproxy redis mongodb neo4j "

# haproxy's runtime API — loopback inside the haproxy container (`stats socket` in haproxy.cfg).
hap() { compose exec -T haproxy sh -c "echo '$1' | nc -w 2 127.0.0.1 9999"; }

# Field of one server's row in `show stat`: 5 = current sessions, 18 = status (UP, DOWN, DRAIN, …),
# 37 = the last health check's result (L4OK when it connected).
stat_field() { hap "show stat" | awk -F, -v b="$1" -v s="$2" -v f="$3" '$1 == b && $2 == s { print $f }'; }

wait_serving() {
  local backend=$1 server=$2 waited=0
  until [[ "$(stat_field "$backend" "$server" 18)" == UP* ]]; do
    if ((waited >= UP_TIMEOUT)); then
      echo "✗ $backend/$server did not start serving within ${UP_TIMEOUT}s"
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
  echo "  ✓ $backend/$server serving"
}

# Would `up` replace this service's container? Compose answers from the image and the config it was
# created with, so an unchanged service is left exactly as it is.
needs_recreate() {
  if ((FORCE)) && [[ "$INFRA" != *" $1 "* ]]; then return 0; fi
  compose up -d --no-deps --dry-run "$1" 2>&1 | grep -q -E 'Recreate'
}

# ── 1. haproxy config ───────────────────────────────────────────────────────────────────────────────
if compose ps --status running --services 2>/dev/null | grep -qx haproxy; then
  compose exec -T haproxy haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg
  compose kill -s USR2 haproxy >/dev/null
  echo "✓ haproxy config reloaded"
  sleep 2
fi

# ── 2. start what is not running ────────────────────────────────────────────────────────────────────
compose up -d --no-recreate --remove-orphans

SURGED="knowledge-server admin-server"
REPLICAS="mcp-server-1 mcp-server-2 mcp-server-3 mcp-server-4 public-agent-1 public-agent-2"

# ── 3. single services ──────────────────────────────────────────────────────────────────────────────
for svc in $(compose config --services); do
  case " $SURGED $REPLICAS " in *" $svc "*) continue ;; esac
  if needs_recreate "$svc"; then
    echo "→ $svc: recreating"
    if [[ "$INFRA" == *" $svc "* ]]; then compose up -d --no-deps "$svc"; else compose up "${UP[@]}" "$svc"; fi
  fi
done

# Take a server out of rotation in every backend it is in. `wait_runs` also waits for its open
# connections to finish — a public-agent run is one long-lived stream.
drain() {
  local server=$1 wait_runs=$2 backend
  shift 2
  for backend in "$@"; do hap "set server $backend/$server state drain" >/dev/null; done
  local waited=0
  while ((wait_runs)) && [[ "$(stat_field "$1" "$server" 5)" != "0" ]] && ((waited < DRAIN_TIMEOUT)); do
    sleep 5
    waited=$((waited + 5))
  done
}
ready() {
  local server=$1 backend
  shift
  for backend in "$@"; do hap "set server $backend/$server state ready" >/dev/null; done
}

# Wait until a drained server's own health check passes. The check result is what counts, not the
# status alone: haproxy treats a server whose address it has only just resolved as up until its first
# check says otherwise, so a container that is still starting can read DRAIN before anything listens.
wait_healthy_drained() {
  local backend=$1 server=$2 waited=0
  until [[ "$(stat_field "$backend" "$server" 18)" == DRAIN* && "$(stat_field "$backend" "$server" 37)" =~ L[4-7]OK ]]; do
    if ((waited >= UP_TIMEOUT)); then
      echo "✗ $backend/$server did not pass its health checks within ${UP_TIMEOUT}s"
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

# Recreate one container on the new image while the others serve, and wait until it serves again.
# It stays drained until its own health checks pass: put back in rotation straight after the recreate,
# haproxy would route to a container that is not listening yet.
replace() {
  local svc=$1 server=$2 wait_runs=$3
  shift 3
  drain "$server" "$wait_runs" "$@"
  compose up "${UP[@]}" "$svc"
  sleep "$SETTLE"
  wait_healthy_drained "$1" "$server"
  ready "$server" "$@"
  wait_serving "$1" "$server"
}

# ── 4. one-copy services, through an update-time copy ───────────────────────────────────────────────
surge() {
  local svc=$1 server=$2 next_server=$3
  shift 3
  needs_recreate "$svc" || return 0
  echo "→ $svc: starting the update-time copy"
  drain "$next_server" 0 "$@"
  compose up "${UP[@]}" "$svc-next"
  sleep "$SETTLE"
  if ! wait_healthy_drained "$1" "$next_server"; then
    compose rm -f -s "$svc-next" >/dev/null
    echo "✗ $svc left as it was — its new version never served"
    return 1
  fi
  ready "$next_server" "$@"
  wait_serving "$1" "$next_server"
  echo "→ $svc: replacing the original"
  replace "$svc" "$server" 0 "$@"
  echo "→ $svc: removing the update-time copy"
  drain "$next_server" 0 "$@"
  compose rm -f -s "$svc-next" >/dev/null
}
surge knowledge-server knowledge1 knowledge2 knowledge_api
surge admin-server admin1 admin2 admin_api admin_api_long

# ── 5. replicas, one at a time ──────────────────────────────────────────────────────────────────────
for n in 1 2 3 4; do
  needs_recreate "mcp-server-$n" || continue
  echo "→ mcp-server-$n: replacing"
  replace "mcp-server-$n" "mcp$n" 0 mcp_server
done
for n in 1 2; do
  needs_recreate "public-agent-$n" || continue
  echo "→ public-agent-$n: draining its runs, then replacing"
  replace "public-agent-$n" "pubagent$n" 1 public_agent
done

echo "✓ stack is current"
