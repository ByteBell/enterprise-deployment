# Plumbline — enterprise deployment

Everything needed to run Plumbline on your own server — on a real host or on a laptop, from the
same files.

This repository is public and contains **no credentials and no source code** — only the compose
file, the proxy config, and an environment template. The images themselves live in a private
registry, and you need a read-only token from ByteBell to pull them.

```bash
git clone https://github.com/ByteBell/enterprise-deployment.git plumbline
cd plumbline

# A laptop or test box — MongoDB and Neo4j run here, files stay in ./temp, no S3
cp .env.localhost.example .localhost.env     # fill it in — see the Quick start below
./install.sh --env local

# A real host on its own domain — your MongoDB, Neo4j and S3 bucket
cp .env.production.example .production.env   # fill it in — see Step 3
./install.sh --env prod
```

**`./install.sh` is the whole deployment, and its one parameter is which one this is.** It checks
the env file and the provider profiles, authenticates to the registry, works out which release to
pull, replaces the running containers, and then waits until the stack actually *serves* before it
says it is up. Running it again is also how you upgrade.

| | reads | what you get |
| --- | --- | --- |
| `./install.sh --env local` | `.localhost.env` | a laptop or test box at `http://localhost:8081`; MongoDB and Neo4j run **here**, files stay in `./temp` (no S3), and one superadmin signs in by email and password — nothing to run elsewhere, no OAuth app to register |
| `./install.sh --env prod` | `.production.env` | the real host, on its own domain, with your MongoDB, Neo4j and S3 bucket |

`production` and `localhost` mean the same two, so whichever word you reach for
works. Nothing is ever built: every service is an image pulled from the registry, told apart by
tag. There is no default environment — you say which one, every time, so production is never what
you get by forgetting.

The `make` targets below still work and do the same jobs one at a time (`make logs`, `make ps`,
`make down`). `install.sh` is the one that takes you from a filled-in env file to a serving stack.

---

## Quick start — Plumbline on your laptop, end to end

From nothing to asking Plumbline questions in Claude Code. The rest of this README explains each
step in depth; this is the short path.

### What you need

- **Docker Desktop** running, **git**, and **Node 18+**.
- **A registry token from ByteBell** — a username and a read-only token. The images are private;
  without it nothing downloads.
- **A GitHub personal access token** that can read the repositories you want to index.
- **An API key from an LLM provider** (for example OpenRouter or Baseten).

### 1. Download

```bash
git clone https://github.com/ByteBell/enterprise-deployment.git plumbline
cd plumbline
```

### 2. Configure

```bash
cp .env.localhost.example .localhost.env
```

Open `.localhost.env` and fill in these values. Leave everything else as it is.

| Key | What to put |
| --- | --- |
| `REGISTRY_USERNAME`, `REGISTRY_TOKEN` | The registry token ByteBell gave you |
| `COMPOSE_PROJECT_DIR` | The full path of this folder — run `pwd` to see it |
| `JWT_SECRET` | The output of `openssl rand -hex 32`. Set it once and keep a copy |
| `SEED_CLIENT_PASSWORD` | The password you will sign in with (the email is `admin@localhost`) |
| `PERSONAL_ACCESS_TOKEN` | Your GitHub personal access token |

Leave `IMAGE_TAG` blank: the newest published release is downloaded, and its version is printed.

### 3. Start

```bash
./install.sh --env local
```

This checks your file, downloads the images, starts MongoDB, Neo4j and every service, waits until
they answer, and creates your sign-in account. The first run takes a few minutes.

### 4. Sign in

Open **<http://localhost:8081>** and sign in as `admin@localhost` with the password you chose.

### 5. Add your LLM keys

In the sidebar, open **Stack Settings → LLM profiles** and enter your provider's API key. Until you
do, indexing and questions fail: the stack starts with placeholder keys.

### 6. Index a repository

Open **Code repositories** and add a repository. It is read with the `PERSONAL_ACCESS_TOKEN` from
step 2; a token pasted in that form is used instead, for that repository. Wait until it shows as
processed — a large repository takes a while.

### 7. Copy your MCP key

Open **MCP Keys** and copy the key that starts with `mcp_`.

### 8. Install the Plumbline commands

```bash
npm install -g github:ByteBell/plumbline-skills
plumbline install --url http://localhost:8081 --key mcp_…
```

`plumbline install` checks the key first, then adds the commands to every coding agent it finds
(Claude Code, OpenCode, Codex). **Restart Claude Code** afterwards.

### 9. Use it in Claude Code

Open Claude Code in any folder and type:

| Command | What it does |
| --- | --- |
| `/plumbline-verify` | Reviews your last commit against every caller in every indexed repository |
| `/plumbline-review-pr <PR URL>` | Reviews a pull request the same way, without switching your branch |
| `/plumbline-blast <file or symbol>` | Shows what depends on this code and what breaks if it changes |
| `/plumbline-resolve-issue <issue>` | Finds the affected files, writes failing tests, then the fix |

`plumbline help` explains each one.

### Stop, restart, upgrade

```bash
make down local            # stop everything; your data is kept
./install.sh --env local   # start again, or upgrade to the newest release
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
| `redis` | Job queues, caches, rate-limit counters | loopback only |
| `log-cleaner` | Deletes logs older than 7 days | — |

**What is NOT in here:** MongoDB and Neo4j. Point the stack at your own — managed (Atlas, Aura),
self-hosted, or containers you run separately. That is deliberate: your data outlives this stack, and
databases should not share a lifecycle with application containers you replace on every upgrade.

---

## Before you start

From ByteBell, for every environment: a **Docker Hub username + read-only token** for the private
image repository. Leave `IMAGE_TAG` blank and the newest published release is pulled.

What else you bring depends on which environment this is:

| | `local` | `prod` | `dev` |
| --- | --- | --- | --- |
| Machine | Docker Desktop on a laptop, or any test box | a **Linux host** — 4 vCPU / 16 GB is a sensible floor; ingestion is the hungry part | the ByteBell monorepo checked out |
| MongoDB + Neo4j | none — started here as containers | yours, reachable from the host | yours, reachable from the machine |
| File storage | none — `./temp` (`FILE_STORAGE_BACKEND=local`) | an **S3 bucket** for repository source, generated specs and snapshots | an S3 bucket, never production's |
| LLM keys | **Stack Settings → LLM profiles** on the dashboard | `llm/*.env`, edited by hand (prod has no Stack Settings page) | Stack Settings or `llm/*.env` |

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

Every `make` target uses plain `docker` when it already works for your user, and `sudo docker` otherwise —
which is what a fresh host needs. To drop sudo, add yourself to the `docker` group and **log out and back
in**; `DOCKER=sudo docker` or `DOCKER=docker` on the command line forces either.
Be consistent: `make login` stores credentials for the user that runs it, and `make pull` must run as
that same user or it cannot read them.

## Step 2 — Get the files

```bash
git clone https://github.com/ByteBell/enterprise-deployment.git /opt/plumbline
cd /opt/plumbline
```

Any directory works; `COMPOSE_PROJECT_DIR` in your env file must be its absolute path.

## Step 3 — Configure

There are two templates for a deployment. They are the same document with different values — copy
the one that matches where this is running:

| Running on | Copy | To | Then |
| --- | --- | --- | --- |
| A real host, own domain | `.env.production.example` | `.production.env` | `make up prod` |
| A laptop or test box, nothing run elsewhere | `.env.localhost.example` | `.localhost.env` | `make up local` |

A third, `.env.example` → `.dev.env`, is for `make up dev`, which exists only inside the ByteBell
monorepo: every service runs the monorepo's source and reloads on save (`docker-compose.dev.yml`),
against databases you already run somewhere.

`localhost` is the self-contained one: it starts MongoDB and Neo4j as containers in this compose
file (behind the `localhost` compose profile, so `dev` and `prod` never see them) and its template
already points `MONGODB_URI` and `NEO4J_URI` at them. What is left to fill in is a Neo4j password,
the registry credential, the secrets and the provider keys. No S3 bucket: files stay in `./temp`,
and the MCP servers hand them to MCP clients as signed links. Both databases keep their data in
Docker volumes (`mongo_data`, `neo4j_data`) and publish loopback-only ports for `mongosh` and the
Neo4j browser; move a port in `.localhost.env` if the default is already taken on your machine.

`localhost` also needs **no OAuth app**. Its template switches every social sign-in button off
(`ENABLE_GITHUB_LOGIN`, `ENABLE_GITLAB`, `ENABLE_BITBUCKET`, `ENABLE_GOOGLE` all `false`, and
`PAY_PER_USER_MODE=false` so the email + password form shows) and leaves the `*_CLIENT_ID` /
`*_CLIENT_SECRET` keys blank, so nobody has to register a GitHub, GitLab, Bitbucket or Google app,
or be handed the keys of one, to use the stack. Instead:

- **Sign-in** is one superadmin account, named by `SEED_CLIENT_EMAIL` / `SEED_CLIENT_PASSWORD`.
  Once the stack is up, `make superadmin local` seeds the organisation, creates that user and
  promotes it. It is idempotent — run it again after changing the values.
- **Repositories** are read with personal access tokens. `ENABLE_TOKEN_ENV_FALLBACK=true` plus
  `PERSONAL_ACCESS_TOKEN` (GitHub), `GITLAB_TOKEN` and `BITBUCKET_TOKEN` in the env file cover any
  repository whose organisation holds no token of its own; a token pasted when adding a repository
  in the dashboard is used ahead of them. Each developer puts in tokens they already have.

```bash
cp .env.production.example .production.env
$EDITOR .production.env
```

**Keep the files separate and complete.** Do not turn one into a base that another adds to.
When two files both define a key, the last one read silently wins — and the definition that lost
still sits there reading as though it were in force.

Work top to bottom. Every `[REQUIRED]` line must be filled; each one says what it is for. Generate
the secret rather than inventing it:

```bash
openssl rand -hex 32     # JWT_SECRET
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

You do not copy anything: `./install.sh` creates every `llm/<name>.env` from its
`llm/<name>.env.example` the first time, and never overwrites one that already exists. The templates
carry no credentials — every key is `replace-me-in-stack-settings`, so the stack boots but no model
call succeeds until you enter the real keys on the dashboard's **Stack Settings → LLM profiles**
page. That page stores each provider's profile (samples in `llm/providers/`) in MongoDB and rewrites
the slot's file when you attach it. Editing `llm/*.env` by hand still works, but the next save from
the page overwrites that file.

Name the profiles in your env file:

```
LLM_PROFILE=gemini
INGEST_PROFILE=baseten
FALLBACK_PROFILE=openrouter
AGENT_PROFILE=baseten
```

`llm/*.env` is gitignored — the templates are tracked, the copies holding your keys are not. **A profile
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
./install.sh --env prod
```

That is the whole thing. Say `local` instead for a laptop or test box. It runs, in order:

1. **Preflight** — Docker and the compose plugin, the env file's required values, no key defined
   twice, every LLM profile it names exists and carries what the services refuse to boot without,
   and nothing else already holding port 80.
2. **Which release** — a pinned `IMAGE_TAG` is used as-is; a blank one resolves to the newest
   published release, which it prints.
3. **Pull**, after logging in to the registry.
4. **Replace the containers** — down first, so a service removed since the last install is not
   left running beside the new set. Volumes, and so your data, are kept.
5. **Databases first** under `--env local`: MongoDB and Neo4j reach healthy before the services
   that would otherwise crash-loop waiting for them.
6. **Wait until it serves.** Not the same as "the containers are up": a live route in front of a
   dead backend answers 503 and still looks healthy in `docker ps`. It polls the admin and
   knowledge APIs and fails naming the service whose logs to read.
7. **The superadmin** under `--env local`: seeds the organisation and the account, then promotes
   it. Idempotent, so re-running after changing a value is how you apply it.

`make verify` remains as a separate check of the HAProxy backends and the endpoints. On the
public-questions line **a 4xx is the correct answer** — the service rejected an empty question. A
503 there means HAProxy is up and `public-agent` is not.

---

## Step 5 — Agent commands for your developers

Once a repository is indexed, every developer can use four commands inside the coding agent they
already run — **Claude Code**, **OpenCode** or **Codex**:

| Command | What it does |
| --- | --- |
| `/plumbline-verify [from] [to]` | Reviews the change between two commits (default: the last commit) against every caller in every indexed repository. Output is a GitHub-style review. |
| `/plumbline-review-pr <PR URL \| #n> [more PRs]` | The same review for a GitHub, GitLab or Bitbucket pull request, fetched without switching your branch. Several PRs across repositories are reviewed as one change. |
| `/plumbline-blast <file[:lines] \| symbol \| pasted code>` | What depends on this code and what breaks if it changes, laid out like the IDE's Find All References. |
| `/plumbline-resolve-issue <issue text \| issue URL>` | Finds every file the issue touches, writes failing tests first, then the fix, then runs the tests until they pass. Nothing is committed. |

**Each developer needs** Node 18+, the address of this deployment, and an MCP key: in the dashboard,
**MCP keys** → copy the `mcp_…` key. Then, once:

```bash
npm install -g github:ByteBell/plumbline-skills
plumbline install --url https://plumbline.acme.com --key mcp_…
```

`plumbline install` checks the key against `<url>/mcp` first and refuses a wrong one, then installs
into every agent it finds on the PATH, for the developer's user. Restart the agent afterwards.

Full usage for each command — arguments, examples, what it does, what the output looks like — is in
the tool itself:

```bash
plumbline help                   # overview
plumbline help verify            # /plumbline-verify
plumbline help blast             # /plumbline-blast
plumbline help resolve-issue     # /plumbline-resolve-issue
plumbline help review-pr         # /plumbline-review-pr
plumbline help repos             # --repos: across repositories
plumbline help install           # install, update, uninstall, where files go
```

```bash
plumbline install --url … --key … --agents claude,opencode    # only these agents
plumbline install --url … --key … --project ~/code/my-repo    # only this one repository
plumbline uninstall                                           # remove everything it added
```

`npm install -g` only puts the `plumbline` tool on the PATH; `plumbline install` is what adds the
commands. Without `--project` it installs for the developer's user, so the commands are in **every**
session of every agent it installed into, in any directory — they work wherever the repository is
indexed and say so where it is not. With `--project` they exist only in sessions started in that
repository.

To point at a different deployment or use a new key, run `plumbline install` again with the new
`--url` / `--key` and restart the agent. It replaces the `plumbline` entry and checks the new pair
first, so a wrong one leaves the old setup working. Moving between `--project` and a user install,
`plumbline uninstall` the old one first: in Claude Code a project entry wins inside that repository.

To update, run both again — `install` copies the command files, it does not link them:

```bash
npm install -g github:ByteBell/plumbline-skills
plumbline install --url … --key …
```

**Running them** — inside a checkout of an indexed repository:

```text
Claude Code, OpenCode   /plumbline-verify            /plumbline-verify a1b2c3d HEAD
                        /plumbline-blast src/api/orders.ts
                        /plumbline-resolve-issue https://github.com/acme/app/issues/412
Codex                   /prompts:plumbline-verify    (same arguments; Codex prefixes custom prompts)
```

**How it works.** Each command is a markdown file — a prompt — that `plumbline install` copies into the
agent's command folder (`~/.claude/commands/`, `~/.config/opencode/command/`, `~/.codex/prompts/`), next
to an MCP server entry for `<url>/mcp` with the key. Typing the command hands that prompt, with the
arguments filled in, to the model the developer is already using. That model then:

- queries **this deployment** through MCP for the graph — callers, dependents, which files an issue
  touches, across every indexed repository;
- works in **the developer's own checkout** for everything else — `git diff`, reading and editing
  files, running the tests.

So this stack answers graph queries only. It runs no model for these commands, and no code leaves
the developer's machine except the queries themselves. Token cost is the developer's own agent's.

### When it does not work

| Symptom | Cause |
| --- | --- |
| `answered HTTP 401 to that key` | Wrong or deactivated key — copy it again from **MCP keys**. |
| `cannot reach …/mcp` | Wrong `--url`, or the stack is down (`./install.sh` status, `make verify`). |
| "This repository is not indexed" | Add the repository in the dashboard and let it finish indexing. |
| The commands do not appear | Restart the agent. With `--project`, run the agent from inside that directory. |
| A result says the index is N commits behind | Normal — the repository was indexed at an older commit. Re-index for fresh dependents. |

With `--project`, the key is written into that repository's `.mcp.json` / `opencode.json`: keep both
out of git.

---

## Day to day

Every target takes `prod` or `local` (also spelled `localhost`) as its last word. Omitting it means
`dev`, the ByteBell monorepo's source mode, so on a deployment always say which:

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
sudo docker logs prod-knowledge --tail 200
sudo docker logs prod-public-agent-1 --since 10m
sudo docker logs prod-mcp-3 --tail 500 2>&1 | grep -i error
```

Container names are `<environment>-<service>` — `prod-` here, `local-` on a laptop and `dev-` in the
monorepo; MCP replicas are `prod-mcp-1` to `-4` and the public agents `prod-public-agent-1` and `-2`.

**When chasing one review or question:** the four MCP replicas sit behind HAProxy with sticky
sessions keyed on `mcp-session-id`, so every graph call of a single run lands on ONE replica.
`docker logs` on that replica is far less noise than the four-way stream. HAProxy's own log
(`sudo docker logs prod-haproxy`) shows which backend each session was pinned to.

### Upgrading

Upgrading is the install command again:

```bash
git pull                  # only if you want new compose/proxy config too
./install.sh --env prod
```

With `IMAGE_TAG` blank it moves you to the newest published release each time, printing which
one it picked. Pin `IMAGE_TAG` in your env file to hold this deployment still — and to roll
back, since a pinned tag is never looked up or moved.

**Upgrading onto the release that introduced `AGENT_PROFILE` needs one extra step, once.** The
public-agent credential used to sit in your env file as `AGENT_LLM_BASE_URL` / `AGENT_LLM_API_KEY` /
`AGENT_MODEL`. It now lives in a profile, so before you upgrade:

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
| `6379` | Bound to `127.0.0.1` in this compose and unreachable from outside the host. |

Redis runs without a password and holds job payloads — it does not belong on a public interface,
which is why it is pinned to loopback here. If you change that mapping, change your firewall to match.

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
cannot serve should not report healthy. Run `make preflight prod` (or `local`), which also reports a
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

Application data lives in your MongoDB, your Neo4j and your S3 bucket (or `./temp` with
`FILE_STORAGE_BACKEND=local`) — back those up as you would any database.

On the host itself, these Docker volumes hold state: `redis_data` (queues in flight),
`conversation-ladybug` (chat memory). Under `localhost`,
`mongo_data` and `neo4j_data` are the databases themselves — there is no copy anywhere else.
`make down` keeps them; `docker compose down -v` destroys them.
