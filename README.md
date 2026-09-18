# Plumbline — enterprise deployment

Everything needed to run Plumbline on your own server. Four files, four commands.

This repository is public and contains **no credentials and no source code** — only the compose
file, the proxy config, and an environment template. The images themselves live in a private
registry, and you need a read-only token from ByteBell to pull them.

```bash
git clone https://github.com/ByteBell/enterprise-deployment.git plumbline
cd plumbline
cp .env.example .env      # fill it in — see Step 3
make login
make up
make verify
```

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

Any directory works; `COMPOSE_PROJECT_DIR` in `.env` must be its absolute path.

## Step 3 — Configure

```bash
cp .env.example .env
$EDITOR .env
```

Work top to bottom. Every `[REQUIRED]` line must be filled; each one says what it is for. Generate
the two secrets rather than inventing them:

```bash
openssl rand -hex 32     # JWT_SECRET
openssl rand -hex 32     # UPDATE_API_TOKEN
```

Two that are easy to get wrong:

- **`IMAGE_TAG`** — there is no `latest` tag in the repository. Unset, every pull fails with a 404.
- **`JWT_SECRET`** — it signs sessions *and* derives the encryption key for stored credentials.
  Changing it later signs everyone out and makes previously stored secrets unreadable. Set it once
  and back it up.

Then check yourself before starting anything:

```bash
make preflight
```

It names any missing value instead of letting a container exit three layers down.

## Step 4 — Start

```bash
make login    # authenticate to the private registry
make up       # create directories, pull images, start everything
make verify   # prove it is actually serving
```

`make verify` is not the same as "the containers are up". It checks the HAProxy backends and the
endpoints, because a live route in front of a dead backend answers 503 and still looks healthy in
`docker ps`. On the public-questions line **a 4xx is the correct answer** — the service rejected an
empty question. A 503 there means HAProxy is up and `public-agent` is not.

---

## Day to day

```bash
make ps                     # what is running
make logs                   # follow everything
make logs s=knowledge-server  # follow one service
make restart                # restart all services
make down                   # stop (volumes, and so your data, are kept)
```

### Upgrading

```bash
$EDITOR .env      # set the new IMAGE_TAG
make update       # pull it and replace the running containers
make verify
```

Compose recreates only the services whose image actually changed. To roll back, put the previous tag
in `IMAGE_TAG` and run `make update` again — the old images are still in the registry.

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
A required value is missing from `.env`. That is the intended behaviour — a container that cannot
serve should not report healthy. Run `make preflight`.

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
