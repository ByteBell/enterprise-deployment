# Deployment: ByteBell's GCP application server

This covers the server ByteBell runs for itself on GCP, project `ancient-blade-473009-k2`. Client installs
follow `README.md` and need none of this.

The server runs the normal production stack (`make up prod`), plus **vm-worker**. vm-worker starts and stops
the language VMs and forwards the page's Free/Paid jobs to them. public-agent calls it at
`ISSUE_VM_WORKER_URL`.

## Sign in as the vm-worker service account, never as a person

Nothing on this server signs in as a person. A personal login such as `saurav@bytebell.ai` expires under
Google's sign-in policy, and then someone has to sign in again in a browser. A service account does not
expire.

**The server `application-vm` runs as `application-vm@ancient-blade-473009-k2.iam.gserviceaccount.com`,
which holds the roles listed below.** Changing a VM's service account means stopping the VM, so granting
the roles to the account already attached avoids the downtime.

**For a new server, attach the vm-worker service account when you create the VM:**

```bash
gcloud compute instances create <server-name> \
  --project=ancient-blade-473009-k2 \
  --service-account=vm-worker@ancient-blade-473009-k2.iam.gserviceaccount.com \
  --scopes=cloud-platform \
  ...
```

After that, `gcloud`, the GCS client and the Google SDKs sign themselves in through the VM's metadata
server. You don't need to log in or provide a key file, and tokens refresh on their own indefinitely.

**There is no key file, and there can't be one.** The org enforces `iam.disableServiceAccountKeyCreation`,
so an attached service account is the only setup that fits the policy. The key used on the dev Mac was a
one-off, created while the policy was lifted for about 90 seconds. Don't plan around getting another.

**Everything that touches GCP runs as this account.** That includes:
- the vm-worker container,
- the run driver and CLI, which read the bucket, write `agent_traces` rows, and start and stop VMs.

On the dev Mac the driver runs under a personal login, and that login is what expired. On the server the
driver runs inside the container or on the VM, as the service account.

**Roles.** `vm-worker@` and `application-vm@` both hold these:

| Role | On |
|---|---|
| Compute Instance Admin | the project's VMs |
| Service Account User | the index VMs' service account |
| Storage Object Admin | `gs://bytebell-agent-traces` |

## Turning vm-worker on

vm-worker is a released image like every other service: `vm-worker-<version>`, built by the monorepo's
`scripts/local-release.sh` from `docker/vm-worker.Dockerfile`. The image carries the code the worker
sends to each VM, so the server needs only this directory, the same as for any prod install.

1. **Set the vm-worker values in `.production.env`:**

   ```
   VM_WORKER_SSH_USER=<the login user on the language VMs>
   ISSUE_VM_WORKER_URL=http://vm-worker:7071
   ```

   `VM_WORKER_SSH_USER` is the user whose home on the language VMs holds their code. On ByteBell's VMs
   that is `sauravverma`. Do not set `VM_WORKER_KEY_FILE` here: that is the dev Mac's key file, and the
   server has none.

2. **Start the stack:**

   ```bash
   make up prod
   ```

   When `VM_WORKER_SSH_USER` is set, `make up prod` adds `docker-compose.vm-worker.yml`. When it is
   unset, the stack runs without vm-worker, which is how every client install runs.

The worker reads `.db.env` and `llm/` from this directory. They are mounted read-only into the container,
never copied into the image.

### How the server's vm-worker differs from dev's

| | dev (`docker-compose.dev.yml`) | server (`docker-compose.vm-worker.yml`) |
|---|---|---|
| Code | the monorepo's source, mounted | the released `vm-worker-<version>` image |
| Sign-in | `gcloud auth activate-service-account` with `VM_WORKER_KEY_FILE` | attached service account, through the metadata server |
| Port | `127.0.0.1:7071` on the host | none; public-agent reaches it over `stack-net` |
| Plumbline MCP for the VMs | forwarded from `haproxy:80` | the same |

Both keep `/root` on a named volume, so gcloud's SSH key to the VMs survives a restart.
