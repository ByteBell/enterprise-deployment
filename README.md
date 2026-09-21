# Plumbline — enterprise deployment

Everything needed to run Plumbline on your own server — on a real host or on a laptop, from the
same files.

This repository is public and contains **no credentials and no source code** — only the compose
file, the proxy config, and an environment template. The images themselves live in a private
registry, and you need a read-only token from ByteBell to pull them.

```bash
git clone https://github.com/ByteBell/enterprise-deployment.git plumbline
cd plumbline
cp .env.production.example .production.env   # fill it in — see Step 3
make up prod                                 # checks, logs in, pulls, starts
make verify prod
```

`make up` is the whole deployment: it checks the env file, authenticates to the registry, pulls
every image from Docker Hub, and starts the stack. There is no separate pull step to remember.

Trying it on a laptop first? Every target takes `dev` instead, which reads `.env` and expects the
stack at `http://localhost`:

```bash
cp .env.example .env
make up dev
```

`dev` is the default, so a bare `make up` is the local one. Production is never what you get by
forgetting to say which.

---

## What you are running

One HAProxy in front, a handful of services behind it, all on one Docker network.

| Service | What it does | Reachable at |
| --- | --- | --- |
| `haproxy` | Routes every request by path; load-balances the replicas | `:80`, stats on `:8404` |
| `admin-dashboard` | The web UI | `/` |
| `admin-server` | Organisations, users, keys, integrations | `/api/admin/*` |
| `knowledge-server` | Ingestion — clones repositories, analyses them, writes the graph | `/api/knowledge/*` |
| `mcp-server-1…4` | Serves the knowledge graph to editors and agents over MCP | `/mcp` |
| `public-agent-1,2` | Answers questions about repositories you have published | `/api/v1/public/agent/*` |
| `conversation-memory` | Chat memory (single instance — it owns an embedded database) | internal |
| `email-dispatcher` | Outbound mail | internal |
| `system-manager` | Applies updates, snapshots for rollback | `/system/status` |
| `redis` | Job queues, caches, rate-limit counters | loopback only |
| `log-cleaner` | Deletes logs older than 7 days | — |

**What is NOT in here:** MongoDB and Neo4j. Point the stack at your own — managed (Atlas, Aura),
self-hosted, or containers you run separately. That is deliberate: your data outlives this stack, and
databases should not share a lifecycle with application containers you replace on every upgrade.

---

## Before you start

From ByteBell:

- **Docker Hub username + read-only token** for the private image repository
- **`CLIENT_ID` and `LICENSE_KEY`** (unless you run `STANDALONE_MODE=true`)
- the **image tag** to run, e.g. `5.0.2`

Your own:

- a **Linux host** — 4 vCPU / 16 GB is a sensible floor; ingestion is the hungry part
- **MongoDB** and **Neo4j**, reachable from that host
- an **S3 bucket** for repository source, generated specs and snapshots
- an **inference endpoint** for public questions — an OpenAI-compatible base URL, a key, a model id

Both CPU architectures are published, so x86_64 and ARM (AWS Graviton, Ampere) both work with no
change on your side.

---

## Step 1 — Docker

Ubuntu:

```bash
sudo apt-get update && sudo apt-get install -y docker.io
sudo systemctl enable --now docker

sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
```

Verify with `docker compose version`. The plugin has to be installed separately because Ubuntu's
`docker.io` package does not carry Compose v2, and `docker-compose` (the old hyphenated Python tool)
cannot read this file.

Every `make` target uses `sudo` by default, which is correct on a fresh host. To drop it, add
yourself to the `docker` group, **log out and back in**, and run targets as `make up DOCKER=docker`.
Be consistent: `make login` stores credentials for the user that runs it, and `make pull` must run as
that same user or it cannot read them.

## Step 2 — Get the files

```bash
git clone https://github.com/ByteBell/enterprise-deployment.git /opt/plumbline
cd /opt/plumbline
```

Any directory works; `COMPOSE_PROJECT_DIR` in your env file must be its absolute path.

## Step 3 — Configure

There are two templates. They are the same document with different values — copy the one that
matches where this is running:

| Running on | Copy | To | Then |
| --- | --- | --- | --- |
| A real host, own domain | `.env.production.example` | `.production.env` | `make up prod` |
| A laptop or test box | `.env.example` | `.env` | `make up dev` |

```bash
cp .env.production.example .production.env
$EDITOR .production.env
```

**Keep the two files separate and complete.** Do not turn one into a base that the other adds to.
When two files both define a key, the last one read silently wins — and the definition that lost
still sits there reading as though it were in force.

Work top to bottom. Every `[REQUIRED]` line must be filled; each one says what it is for. Generate
the two secrets rather than inventing them:

```bash
openssl rand -hex 32     # JWT_SECRET
openssl rand -hex 32     # UPDATE_API_TOKEN
```

Two that are easy to get wrong:

- **`IMAGE_TAG`** — leave it blank to run the newest published release; `make up` looks it up and
  prints what it chose. Pin it to a version to keep a deployment still, and to roll back — a
  pinned tag is never looked up or moved.
- **`JWT_SECRET`** — it signs sessions *and* derives the encryption key for stored credentials.
  Changing it later signs everyone out and makes previously stored secrets unreadable. Set it once
  and back it up.

Then check yourself before starting anything:

```bash
make preflight prod
```

It names any missing value instead of letting a container exit three layers down.

## Step 3b — Choose your LLM providers

Nothing provider-specific belongs in your env file. Each provider's complete configuration — its
name, its credential, its model ids and its endpoint — is **one file under `llm/`**, and your env
file names which of those files to read. Switching provider is changing one word; it is never
uncommenting a block.

Four slots, because these four jobs have genuinely different needs and one choice cannot serve all
of them:

| Slot | Drives | Reads | Why it is its own slot |
| --- | --- | --- | --- |
| `LLM_PROFILE` | answers, summaries, query enrichment | `llm/<name>.env` | Wants a cheap-first tier chain |
| `INGEST_PROFILE` | the two IR phases, `FILE_*` and `UNIT_*` | `llm/ingest-<name>.env` | Tens of thousands of short calls per repo |
| `FALLBACK_PROFILE` | where a call goes while its provider refuses on capacity | `llm/fallback-<name>.env` | Must NOT name the same provider as `LLM_PROFILE` |
| `AGENT_PROFILE` | the public repo page — question runs and PR reviews | `llm/agent-<name>.env` | A long tool-calling loop wanting one strong model with reasoning on |

Copy the templates you need and fill in the credential:

```bash
cp llm/gemini.env.example         llm/gemini.env
cp llm/ingest-baseten.env.example llm/ingest-baseten.env
cp llm/agent-baseten.env.example  llm/agent-baseten.env
$EDITOR llm/*.env
```

Then name them in your env file:

```
LLM_PROFILE=gemini
INGEST_PROFILE=baseten
FALLBACK_PROFILE=openrouter
AGENT_PROFILE=baseten
```

`llm/*.env` is gitignored — the templates are tracked, your filled-in copies are not. **A profile
you name must exist.** An unset or misspelled slot resolves to a file that is not there and compose
refuses to start anything, which is the intended loud failure rather than a container that boots
without a credential.

`FALLBACK_PROFILE=none` disables failover and rotates within the provider's own tiers instead.

### The agent profile carries an operating mode, not just a credential

`llm/agent-<name>.env` sets four keys that move together, and the last two are the ones people miss:

```
AGENT_LLM_BASE_URL=https://inference.baseten.co/v1
AGENT_LLM_API_KEY=
AGENT_MODEL=deepseek-ai/DeepSeek-V4-Pro
AGENT_REASONING_EFFORT=medium
AGENT_MAX_COMPLETION_TOKENS=8096
```

All four are **required** — `public-agent` refuses to start if any is unset, rather than guessing.

Reasoning is charged against the completion ceiling on these providers, whatever their docs say, so
the last two are one setting in two fields. Measured on a pull-request review (2026-09-21): at
`high` effort with a 4096 ceiling the model reasoned out a verdict for every hunk and was then cut
off mid-sentence having emitted no tool calls at all — a turn that cost a full completion and
delivered nothing, ending the review with 0 of 13 hunks reported. At `medium` with 8096 the same
review reported all 13. **If you want more thinking, raise the ceiling before raising the effort.**
The failure mode is an empty turn, not a shallow one.

## Step 4 — Start

```bash
make up prod       # check, authenticate, pull every image, start everything
make verify prod   # prove it is actually serving
```

On a laptop, say `dev` instead of `prod` in each — or leave it off, since `dev` is the default.

`make verify` is not the same as "the containers are up". It checks the HAProxy backends and the
endpoints, because a live route in front of a dead backend answers 503 and still looks healthy in
`docker ps`. On the public-questions line **a 4xx is the correct answer** — the service rejected an
empty question. A 503 there means HAProxy is up and `public-agent` is not.

---

## Day to day

Every target takes `dev` or `prod` as its last word, and `dev` is what you get if you omit it:

```bash
make ps prod                       # what is running
make logs prod                     # follow everything
make logs s=knowledge-server prod  # follow one service
make restart prod                  # restart all services
make down prod                     # stop (volumes, and so your data, are kept)
```

### Logs

`make logs` follows live, starts with the last 200 lines, and takes one or more service names in
`s=`. `Ctrl-C` stops following and touches nothing.

```bash
make logs prod s="public-agent-1 public-agent-2"                        # both public agents
make logs prod s="knowledge-server"                                      # the knowledge server
make logs prod s="mcp-server-1 mcp-server-2 mcp-server-3 mcp-server-4"  # all four MCP replicas
make logs prod                                                           # everything in the stack
```

All seven of those in one interleaved stream, each line prefixed with its service:

```bash
make logs prod s="public-agent-1 public-agent-2 knowledge-server mcp-server-1 mcp-server-2 mcp-server-3 mcp-server-4"
```

For one container's recent output without following, use its container name:

```bash
sudo docker logs bb-stack-knowledge --tail 200
sudo docker logs bb-stack-public-agent-1 --since 10m
sudo docker logs bb-stack-mcp-3 --tail 500 2>&1 | grep -i error
```

Container names are `bb-stack-<service>`; MCP replicas are `bb-stack-mcp-1` to `-4` and the public
agents `bb-stack-public-agent-1` and `-2`.

**When chasing one review or question:** the four MCP replicas sit behind HAProxy with sticky
sessions keyed on `mcp-session-id`, so every graph call of a single run lands on ONE replica.
`docker logs` on that replica is far less noise than the four-way stream. HAProxy's own log
(`sudo docker logs bb-stack-haproxy`) shows which backend each session was pinned to.

### Upgrading

```bash
$EDITOR .production.env   # set the new IMAGE_TAG
make update prod          # pull it and replace the running containers
make verify prod
```

With `IMAGE_TAG` blank, `make update prod` moves you to the newest release each time it runs.

**Upgrading onto the release that introduced `AGENT_PROFILE` needs one extra step, once.** The
public-agent credential used to sit in your env file as `AGENT_LLM_BASE_URL` / `AGENT_LLM_API_KEY` /
`AGENT_MODEL`. It now lives in a profile, so before `make update`:

```bash
cp llm/agent-baseten.env.example llm/agent-baseten.env
$EDITOR llm/agent-baseten.env          # paste the key your env file had
echo 'AGENT_PROFILE=baseten' >> .production.env
```

Then delete those three `AGENT_LLM_*` lines from `.production.env`. Compose loads the profile AFTER
your env file, so a copy left behind is shadowed rather than used — but leaving it there means a
credential sitting in two places, one of which no longer does anything.

`public-agent` refuses to start without all four profile keys, so a missed step fails at boot with
the name of the key, not later with a 500.

**If preflight reports `LLM_PROFILE`, `INGEST_PROFILE` and `FALLBACK_PROFILE` missing**, your env
file predates the profile system altogether and still carries every provider inline. Do Step 3b in
full, moving values rather than retyping them:

| Your inline keys | Go into | Then set |
| --- | --- | --- |
| `LLM_PROVIDER`, `LLM_API_KEY`, `SMART*_MODEL_NAME` | `llm/<provider>.env` | `LLM_PROFILE=<provider>` |
| `FILE_LLM_*`, `FILE_SMART*_MODELS`, `UNIT_LLM_*`, `UNIT_SMART*_MODELS` | `llm/ingest-<provider>.env` | `INGEST_PROFILE=<provider>` |
| nothing — `llm/fallback-none.env` is already in the repo | — | `FALLBACK_PROFILE=none` |

Delete the inline keys afterwards for the same reason as above: a copy left behind is shadowed by
the profile and reads as though it were in force.

Compose recreates only the services whose image actually changed. To roll back, put the previous
tag in `IMAGE_TAG` and run `make update prod` again — the old images are still in the registry,
and a pinned tag stops the lookup, so you stay there until you clear it.

---

## Ports and firewall

| Port | Who needs it |
| --- | --- |
| `80` | **Open it.** This is the application. |
| `8404` | HAProxy stats. Keep it closed; reach it over SSH. |
| `6379`, `3003` | Bound to `127.0.0.1` in this compose and unreachable from outside the host. |

Redis runs without a password and holds job payloads, and `:3003` is the API that replaces running
containers — neither belongs on a public interface, which is why both are pinned to loopback here. If
you change those mappings, change your firewall to match.

Put TLS in front of `:80` — a reverse proxy or a load balancer — before exposing this to the
internet. Nothing in this stack terminates TLS.

---

## Disk: count inodes, not gigabytes

`temp/` is where repository analysis lands, and it is **millions of small files**: one directory per
analysed file, for every repository and every indexed commit. On ext4 the number of inodes is fixed
when the filesystem is created, so a volume can hit "no space left on device" with free gigabytes
showing.

```bash
df -i /opt/plumbline/temp     # inodes — the number that runs out first
df -h /opt/plumbline/temp     # bytes
```

Size that volume by **expected object count**. For a large ingestion workload use XFS, which
allocates inodes dynamically, or `mkfs.ext4 -i 8192`. Check `df -i` during your first big ingestion
rather than after it fails.

`temp/` is a data store, not a scratch directory — do not "clean it up" to reclaim space.

---

## When something is wrong

**`pull access denied` / `repository does not exist`**
The registry login belongs to a different user than the pull. If `make pull` uses `sudo` (the
default), `make login` must too. Re-run `make login`, then `make pull`.

**`manifest unknown` or a 404 on pull**
`IMAGE_TAG` names a release that does not exist. There is no `latest` here. Confirm the tag with
ByteBell.

**A container exits immediately, log names a variable**
A required value is missing from your env file. That is the intended behaviour — a container that
cannot serve should not report healthy. Run `make preflight prod` (or `dev`), which also reports a
key defined twice, where the later definition quietly overrides the one you are reading.

**`make verify` shows a backend DOWN**
That service did not start. `make logs s=<service>` — the name is in the table at the top.

**Public questions return 503**
`public-agent-1` / `public-agent-2` are not running. Usually one of `AGENT_LLM_BASE_URL`,
`AGENT_LLM_API_KEY`, `AGENT_MODEL`, or the three database names is blank.

**Everything is up but ingestion fails part-way**
Check `df -i` first. See the disk section above.

---

## Data and backups

Application data lives in your MongoDB, your Neo4j and your S3 bucket — back those up as you would
any database.

On the host itself, these Docker volumes hold state: `redis_data` (queues in flight),
`conversation-ladybug` (chat memory), `updater_state` and `shared-config`. `make down` keeps them;
`docker compose down -v` destroys them.
