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
# Say where it stopped. Several steps send their output to /dev/null, so without this a failure ends
# in a bare `make: Error 1` with nothing to read.
trap 'echo "✗ rolling update stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

: "${ROLL_COMPOSE:?run through make up / make update}"

# Seconds to wait for a replacement to serve, and for a drained public-agent replica to finish its runs.
UP_TIMEOUT=300
DRAIN_TIMEOUT=600
# After a container is replaced haproxy still reports the old one for a moment: it re-resolves the name at
# most every 10 s (`hold valid` in haproxy.cfg) and marks a server down only after failed checks. Waiting
# this long first means an `UP` read afterwards is about the new container, not the one that just left.
SETTLE=15

compose() { eval "$ROLL_COMPOSE \"\$@\""; }
# The plain docker CLI (`sudo docker` where the user is not in the docker group).
docker_() { eval "${ROLL_DOCKER:-docker} \"\$@\""; }

FORCE=${ROLL_FORCE:-0}
UP=(-d --no-deps)
((FORCE)) && UP+=(--force-recreate)
# Never forced — recreating one of these takes the whole stack with it.
INFRA=" haproxy redis mongodb neo4j "
# What this run replaced, said at the end — so a run that changed nothing says so.
REPLACED=()

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

# Does this service's running container differ from what the env file now describes? The same two
# tests compose itself makes: the config hash the container was created with (image tag, env files,
# everything in its definition) against the current one, and the image it runs against the image its
# tag now points to (a re-pushed tag). ANYTHING that cannot be read counts as changed — a wrong
# "unchanged" leaves an old release running while the script reports the stack current.
needs_recreate() {
  local svc=$1 cid want have ref running pulled
  if ((FORCE)) && [[ "$INFRA" != *" $svc "* ]]; then return 0; fi
  cid=$(compose ps -q "$svc" 2>/dev/null | head -1)
  [[ -n "$cid" ]] || return 0
  want=$(compose config --hash "$svc" 2>/dev/null | awk -v s="$svc" '$1 == s { print $2 }')
  have=$(docker_ inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$cid" 2>/dev/null)
  [[ -n "$want" && "$want" == "$have" ]] || return 0
  ref=$(docker_ inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)
  running=$(docker_ inspect -f '{{.Image}}' "$cid" 2>/dev/null)
  pulled=$(docker_ image inspect -f '{{.Id}}' "$ref" 2>/dev/null)
  [[ -n "$running" && "$running" == "$pulled" ]] || return 0
  return 1
}

# ── 1. haproxy config ───────────────────────────────────────────────────────────────────────────────
# Every later step drives haproxy's runtime API, so haproxy must be running THIS haproxy.cfg first. A
# reload (USR2) is enough when the container already sees the file on disk. It is not when haproxy's own
# definition changed, or the container sees an older haproxy.cfg than the one here (a stack started
# with the old single-file mount, then `git pull`) — then haproxy itself is recreated: a second or two
# of refused connections, once.
HAP_CFG=/usr/local/etc/haproxy/haproxy.cfg
if [[ -n "$(compose ps -q --status running haproxy 2>/dev/null)" ]]; then
  seen=$(compose exec -T haproxy cat "$HAP_CFG" 2>/dev/null | cksum || true)
  if needs_recreate haproxy || [[ "$seen" != "$(cksum < haproxy/haproxy.cfg)" ]]; then
    echo "→ haproxy: running an older config than haproxy/haproxy.cfg — recreating it"
    compose up -d --no-deps --force-recreate haproxy
  else
    compose exec -T haproxy haproxy -c -q -f "$HAP_CFG"
    compose kill -s USR2 haproxy >/dev/null
    echo "✓ haproxy config reloaded"
  fi
  waited=0
  until hap "show info" >/dev/null 2>&1; do
    if ((waited >= UP_TIMEOUT)); then
      echo "✗ haproxy's runtime API (stats socket in haproxy.cfg) is not answering"
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
fi

# ── 2. start what is not running ────────────────────────────────────────────────────────────────────
compose up -d --no-recreate --remove-orphans

SURGED="knowledge-server admin-server"
REPLICAS="mcp-server-1 mcp-server-2 mcp-server-3 mcp-server-4 public-agent-1 public-agent-2"

# ── 3. single services ──────────────────────────────────────────────────────────────────────────────
for svc in $(compose config --services); do
  case " $SURGED $REPLICAS haproxy " in *" $svc "*) continue ;; esac
  if needs_recreate "$svc"; then
    echo "→ $svc: recreating"
    REPLACED+=("$svc")
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
  REPLACED+=("$svc")
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
  REPLACED+=("mcp-server-$n")
  replace "mcp-server-$n" "mcp$n" 0 mcp_server
done
for n in 1 2; do
  needs_recreate "public-agent-$n" || continue
  echo "→ public-agent-$n: draining its runs, then replacing"
  REPLACED+=("public-agent-$n")
  replace "public-agent-$n" "pubagent$n" 1 public_agent
done

if ((${#REPLACED[@]})); then
  echo "✓ replaced ${#REPLACED[@]}: ${REPLACED[*]}"
else
  echo "✓ nothing to replace — every running container already matches the env file and its images"
fi
