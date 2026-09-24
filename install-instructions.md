# Install instructions

Everything that runs a Plumbline stack lives in this directory. There are three environments, and
each one reads its own env file:

| Environment | Env file          | Template                  | Databases                           |
| ----------- | ----------------- | ------------------------- | ----------------------------------- |
| `local`     | `.localhost.env`  | `.env.localhost.example`  | MongoDB + Neo4j run here            |
| `dev`       | `.env`            | `.env.example`            | run elsewhere (named in env file)   |
| `prod`      | `.production.env` | `.env.production.example` | run elsewhere (named in env file)   |

`localhost` is accepted as another name for `local`. Leaving the environment off means `dev`, so a
bare command never reaches production.

## First run

```bash
cp .env.localhost.example .localhost.env    # or .env.example / .env.production.example
$EDITOR .localhost.env                      # fill in every [REQUIRED] value
make preflight local                        # checks Docker, the env file and the LLM profiles
```

## Start and stop

```bash
make up local      make down local
make up dev        make down dev
make up prod       make down prod
```

- `make down` keeps the volumes, so your data survives. Only `docker compose down -v` deletes it.
- `make up local` starts MongoDB and Neo4j first and waits until both accept queries. It then
  creates the MongoDB user named in `MONGODB_URI`, or checks that user still signs in, before
  starting everything else.
- After the first `make up local`, create the sign-in account:

  ```bash
  make superadmin local
  ```

  This creates the `SEED_CLIENT_EMAIL` user with `SEED_CLIENT_PASSWORD` and makes it superadmin.
  Running it again is safe.
- `./install.sh --env local|dev|prod` does the whole sequence in one command: preflight, pull,
  replace containers, wait until the stack serves, and seed the superadmin (local only).

## Stack Settings page (`local` and `dev`)

The super-admin **Configuration → Stack Settings** page edits passwords, provider keys and LLM
profiles, and then recreates only the containers that read a changed value. It works on `local` and
`dev` because those environments also load `docker-compose.stack-settings.yml`, which mounts the
Docker socket and this directory into admin-server. `prod` never loads that file.

For the page to work:

- `COMPOSE_PROJECT_DIR` in the env file must be the absolute path of **this** directory. `make
  preflight` checks it.
- Start the stack with `make up local|dev` or `./install.sh`, never with a bare `docker compose up`.
  The page recreates containers exactly as they were started, keeping the same `local-`/`dev-` names,
  the same image tag, and the same compose files and profiles.

If the page answers 503, the message says which of these is missing.

## File storage: the S3 bucket and its access

Every environment, `local` included, stores files in S3 (`FILE_STORAGE_BACKEND=s3`). One bucket,
`S3_FILES_BUCKET`, holds all of it:

- each indexed commit's source tree, which the MCP `the_receipts` tool reads back
- generated spec pages
- conversation-memory snapshots, under the `conversation-ladybug/` prefix

Give each environment its **own** bucket. If a laptop points at production's bucket, every repository
indexed on that laptop is uploaded into production storage.

### 1. Create the bucket

A standard (general purpose) bucket is the simple choice and works everywhere:

```bash
export AWS_REGION=us-east-1
export BUCKET=plumbline-files-local-<yourname>        # globally unique, lowercase

aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION"
# outside us-east-1, add:  --create-bucket-configuration LocationConstraint=$AWS_REGION

# Private: nothing in it is ever public. Downloads are handed out as presigned URLs.
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Production uses an **S3 Express One Zone directory bucket**: the name ends in
`--<az-id>--x-s3`, e.g. `plumbline-files--use1-az4--x-s3`. It gives lower latency when the stack
runs in that same availability zone. The code recognises the `--x-s3` suffix and handles it
automatically. Its presigned URLs last at most about 4.5 minutes.

```bash
aws s3api create-bucket --bucket "plumbline-files--use1-az4--x-s3" --region us-east-1 \
  --create-bucket-configuration \
  'Location={Type=AvailabilityZone,Name=use1-az4},Bucket={DataRedundancy=SingleAvailabilityZone,Type=Directory}'
```

### 2. Grant access: least privilege

The services list, read, write, copy and delete objects, and presign downloads. They never create or
delete buckets. Save this as `plumbline-files-policy.json`, replacing `BUCKET`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListTheBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::BUCKET"
    },
    {
      "Sid": "ReadWriteObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET/*"
    }
  ]
}
```

`s3:GetObject` also covers `HeadObject` and presigned downloads. `s3:PutObject` plus `s3:GetObject`
cover server-side copies.

For a **directory bucket**, replace both statements with this one. Directory buckets authorise every
object call through a session:

```json
{
  "Effect": "Allow",
  "Action": ["s3express:CreateSession"],
  "Resource": "arn:aws:s3express:us-east-1:ACCOUNT_ID:bucket/plumbline-files--use1-az4--x-s3"
}
```

```bash
aws iam create-policy --policy-name plumbline-files-local \
  --policy-document file://plumbline-files-policy.json
```

### 3a. On a server: an IAM role, no keys

On EC2, attach the policy to a role, attach the role to the instance, and **leave
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` blank** in the env file. Every service then falls back
to the AWS SDK's default credential chain, which picks up the instance role. There are no keys to
leak or rotate.

```bash
aws iam create-role --role-name plumbline-stack \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name plumbline-stack \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/plumbline-files-local
aws iam create-instance-profile --instance-profile-name plumbline-stack
aws iam add-role-to-instance-profile --instance-profile-name plumbline-stack --role-name plumbline-stack
aws ec2 associate-iam-instance-profile --instance-id i-xxxxxxxx \
  --iam-instance-profile Name=plumbline-stack
```

The containers reach the instance role through the EC2 metadata service. If the instance enforces
IMDSv2, set the hop limit to 2 so a container, which is one network hop further away, can reach it:

```bash
aws ec2 modify-instance-metadata-options --instance-id i-xxxxxxxx \
  --http-put-response-hop-limit 2 --http-endpoint enabled
```

### 3b. On a laptop (`local`, `dev`): an IAM user with an access key

A laptop has no instance role, so the containers need a key. Create a user that can do nothing
except use this one bucket:

```bash
aws iam create-user --user-name plumbline-local-<yourname>
aws iam attach-user-policy --user-name plumbline-local-<yourname> \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/plumbline-files-local
aws iam create-access-key --user-name plumbline-local-<yourname>   # prints the key pair once
```

### 4. Put it in the env file

```bash
FILE_STORAGE_BACKEND=s3
S3_FILES_BUCKET=plumbline-files-local-<yourname>
AWS_DEFAULT_REGION=us-east-1
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=AKIA...              # blank on a server with an IAM role
AWS_SECRET_ACCESS_KEY=...              # blank on a server with an IAM role
```

Then run `make up local` (or `dev`/`prod`) so the containers read the new values.

### 5. Check it

```bash
# the key can reach the bucket
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... aws s3 ls "s3://$BUCKET"

# after indexing a repository, its source tree is there
aws s3 ls "s3://$BUCKET/" --recursive | grep /repository/ | head
```

Then ask the MCP for a file with `the_receipts`. It returns a presigned URL on this bucket, and
downloading that URL returns the file.

Changing the bucket does not move anything that was already indexed. Re-index a repository to
write it into the new bucket.

## Which images run: `IMAGE_TAG`

| `IMAGE_TAG` in the env file | What runs                                                          |
| --------------------------- | ------------------------------------------------------------------ |
| blank                       | the newest published release, looked up in the registry and pulled |
| `5.4.1` (a version)         | that release, pulled. Pin a version to hold a deployment still or to roll back |
| `local`                     | images built on this machine by `make build` in the ByteBell monorepo; nothing is pulled |

`prod` refuses `IMAGE_TAG=local`, so production can only run published releases.

## Inside the ByteBell monorepo: build, run, publish

Only the monorepo's `make build` builds images. Everything else runs from this directory.

```bash
# 1. At the monorepo root: check out each submodule's release branch, then build every image
make build
#    Produces <IMAGE_REGISTRY>/<IMAGE_REPO_PREFIX>/<IMAGE_REPO_NAME>:<service>-local
#    for admin-dashboard, ingestion-engine, conversation-memory, mcp-server and public-agent.

# 2. Here, with IMAGE_TAG=local in .localhost.env or .env
cd enterprise-deployment
make up local            # or: make up dev
```

When `IMAGE_TAG=local` and an image is missing, `make up` stops, lists the missing images and tells
you to run `make build`.

### Publishing a release

```bash
make publish prod VERSION=5.4.2 [SEVERITY=critical] [CHANGELOG='...'] [ECR_PUSH=true]
```

This hands off to the monorepo's `make publish`. Publishing is the one step that builds for itself:
a single multi-arch build (amd64 + arm64) that is pushed to Docker Hub, plus ECR when
`ECR_PUSH=true`. A `make build` on a Mac produces arm64-only images, and pushing those would leave
amd64 servers unable to start the release. The push token is asked for at the prompt and is never
read from the env file, because the token in the env file is a pull credential.

## Logs

`make logs` follows the last 200 lines and then keeps streaming. `s=` takes one or more service
names, and their lines come out together, each prefixed with its container name.

```bash
make logs local                                                        # every container

make logs local s="public-agent-1 public-agent-2"                      # all public agents
make logs local s="mcp-server-1 mcp-server-2 mcp-server-3 mcp-server-4" # all MCP replicas
make logs local s="knowledge-server admin-server email-dispatcher"     # all ingestion-engine processes
make logs local s=knowledge-server                                     # one service
```

Replace `local` with `dev` or `prod` for the other environments.

Service names: `knowledge-server`, `admin-server`, `email-dispatcher`, `conversation-memory`,
`mcp-server-1` to `mcp-server-4`, `public-agent-1`, `public-agent-2`, `admin-dashboard`, `haproxy`,
`redis` and `log-cleaner`. `local` also has `mongodb` and `neo4j`.

Containers are named `<environment>-<service>`, for example `local-knowledge`, `dev-mcp-2` or
`prod-public-agent-1`.

The services also write their own log files to disk:

```text
logs/knowledge-server/   logs/admin-server/   logs/email-dispatcher/   logs/mcp/mcp-1 … mcp-4/
```

`log-cleaner` deletes files there that are older than 7 days.

## Day to day

```bash
make ps local          # what is running
make verify local      # prove it serves: containers, HAProxy backends, health endpoints
make restart local     # restart every service
make update prod       # pull the IMAGE_TAG now in the env file and replace changed containers
make help              # every target, and which env file and IMAGE_TAG are in effect
```

## Docker and sudo

Targets use plain `docker` when it works for your user (Docker Desktop, or a user in the `docker`
group). Otherwise they fall back to `sudo docker`. To force one, add `DOCKER=docker` or
`DOCKER="sudo docker"` to the command line.
