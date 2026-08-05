# Deployment Guide

How to provision, deploy, and operate the accounting backend.

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) >= 1.5 (provided by `nix develop`)
- SSH key pair for server access
- [Hetzner Cloud](https://console.hetzner.cloud/) account + API token
- Domain with DNS you control
- GitHub account (for GHCR image registry)

## First-Time Setup

### 1. Provision the Server

Create `infra/terraform/terraform.tfvars` (gitignored):

```hcl
hcloud_token   = "your-hetzner-api-token"
ssh_public_key = "ssh-ed25519 AAAA... you@host"
domain         = "accounting.example.com"
```

Then:

```bash
cd infra/terraform
tofu init
tofu plan     # review what will be created
tofu apply    # provision VPS, firewall, SSH key, rDNS
```

Note the server IP from the output:

```bash
tofu output server_ip
```

### 2. Point Your Domain

Create an **A record** at your DNS provider:

```
homeaccounting.com → <server_ip>
```

Wait for DNS propagation before proceeding (Caddy needs this for HTTPS).

### 3. Bootstrap the Server

Update `infra/deploy.env` with your server details:

```bash
DEPLOY_HOST=<server_ip>
DEPLOY_USER=root
DEPLOY_SSH_KEY=infra/deploy_key
GHCR_OWNER=<your-github-username>
```

Run the bootstrap script:

```bash
just infra-setup
```

This installs Docker and creates `/opt/backend/` on the server.

### 4. Configure the Environment

Edit `infra/.env` (checked into git) with your production values. Replace all `CHANGE_ME` placeholders with real secrets:

```bash
$EDITOR infra/.env
```

> **Note:** `infra/.env` contains secrets. It is committed to git for convenience (private repo).
> If you change secrets later, edit `infra/.env` and run `just deploy-sync` to push the update.

### 5. Log Into GHCR on the Server

Still on the server, authenticate Docker with GitHub Container Registry:

```bash
docker login ghcr.io -u <github-username>
```

Use a [personal access token](https://github.com/settings/tokens) with `read:packages` scope as the password.

### 6. Sync Config Files & Deploy

Back on your local machine:

```bash
just deploy-sync    # copies docker-compose.yaml, Caddyfile, and .env to server
just deploy         # pulls image and starts services
```

Verify everything is running:

```bash
just deploy-status
```

Visit `https://homeaccounting.com/api/` — Caddy will automatically provision an HTTPS certificate.

## Day-to-Day Deployment

### How It Works (Continuous Delivery)

1. Push code to `master`
2. GitHub Actions runs tests, builds a Docker image, and pushes it to GHCR
3. GitHub Actions automatically deploys to production via SSH

No manual step is required — every green master push is deployed.

### GitHub Actions Secrets

The deploy job requires these secrets (`Settings → Secrets and variables → Actions`):

| Secret           | Description                    |
| ---------------- | ------------------------------ |
| `DEPLOY_HOST`    | Server IP address              |
| `DEPLOY_USER`    | SSH user (e.g. `root`)         |
| `DEPLOY_SSH_KEY` | Private SSH key for the server |

### Available Commands

| Command                      | Description                                      |
| ---------------------------- | ------------------------------------------------ |
| `just deploy`                | Pull latest image and restart                    |
| `just deploy-sync`           | Copy docker-compose.yaml, Caddyfile, and .env to server |
| `just deploy-status`         | Show `docker compose ps` on server               |
| `just deploy-logs`           | Tail service logs                                |
| `just deploy-rollback <sha>` | Roll back to a specific image                    |

### Rollback

Find the commit SHA to roll back to:

```bash
git log --oneline master
```

Then:

```bash
just deploy-rollback abc1234
```

This updates `BACKEND_TAG` in the server's `.env` and restarts services.

To go back to latest after a rollback, SSH into the server and set `BACKEND_TAG=latest` in `/opt/backend/.env`, then `just deploy`.

## Updating Infrastructure

If you change `docker-compose.yaml`, `Caddyfile`, or `infra/.env`:

```bash
just deploy-sync    # copy updated files to server
just deploy         # restart with new config
```

If you change OpenTofu config:

```bash
cd infra/terraform
tofu plan
tofu apply
```

## Event store: backup & restore

The event store is an immutable append-only log — it is the source of truth, and
read models are rebuilt from it. Backup is a plain PostgreSQL dump:

```bash
pg_dump "$DATABASE_URL" -t events > events-backup.sql   # the events table is what matters
# full DB dump is also fine:
pg_dump "$DATABASE_URL" > backup.sql
```

Restore into any PostgreSQL 15+ instance (new host, new machine, upgraded
Postgres) with `psql < backup.sql`, then start the app.

**Schema evolution makes restore version-independent.** Because the app
normalizes older events to the current shape *on read* (upcast-on-read; see
`docs/architecture.md`), **any app version can read any dump** — including a dump
taken several releases ago restored against a much newer app. You do not need to
match the app version to the dump, and you never run a migration step against the
log. Version-skipping (e.g. restoring a v1-era backup into a v3 app) just runs
more upcaster hops at read time. Stored bytes are never mutated, so a restore is
non-destructive and re-runnable.

### One-time data reset — provider category-signal release (pre-launch alpha)

> **This release is an exception to the version-independent-restore guarantee
> above, and only because we are still pre-launch alpha (beta-testers only).** The
> provider category-signal change altered several stored-event shapes without
> shipping upcasters (documented alpha escape hatch — see `CLAUDE.md` "Backward
> compatibility"). Deploying it therefore **requires recreating the event-store
> DB**; existing beta-tester data is discarded, not migrated. Old dumps taken
> before this release are **not** readable by this app version.
>
> ```bash
> # stop the app, then drop & recreate the event-store database (destroys data)
> dropdb "$PGDATABASE" && createdb "$PGDATABASE"
> # start the app; eventium-postgresql recreates the schema on boot
> ```
>
> This is a one-off tied to alpha. Once launched, the standing upcast-on-read
> policy applies and restores become version-independent again.

## Observability (metrics & logs)

The backend provides two **operator seams**; the observability *stack* that
consumes them (Prometheus, Loki, Promtail, Grafana) lives in the infra repo —
**homeaccounting/infra#8**, not here. The app requires **no** observability
backend to run.

### Metrics — `GET /metrics`

Unauthenticated Prometheus text-exposition endpoint (served at the WAI layer,
outside the API). Low-cardinality by design — **no per-user or per-path labels**:

- `events_persisted_total{event_type}` — events written, by specific event tag.
- `events_write_conflicts_total` — optimistic-concurrency conflicts.
- `http_request_duration_seconds{handler="app",method,status_code}` — request
  latency/rate (constant `handler` label to avoid path cardinality). Display as
  **ms** in Grafana; the metric is stored in seconds (base unit).
- `ghc_*` — GHC runtime (heap, GC, threads); requires `-with-rtsopts=-T` (set).

### Logs — structured JSON on stdout

With `logging.format: json` (default in prod), every stdout line is **one JSON
object**: `{ts,level,msg,caller,correlationId,userId}`. `persistent` SQL logs are
bridged onto the same stream as `{…,"source":"sql"}` (debug-level, gated by
`logging.level`). `logging.format: text` keeps the legacy human-readable output
for dev. Ship stdout to Loki with a log agent (see infra#8); query per-user /
per-request via LogQL `| json | userId="…"` / `correlationId="…"`.

**Attribution limitation.** Per-request events and logs carry `correlationId` +
`userId`. **Saga/process-manager-emitted events** now carry them too: since sagas
run synchronously within the originating request, each `ProcessManager.react`
receives the triggering event's metadata and propagates its `correlationId` +
`userId` onto every command it issues (`propagateContext` in
`Infrastructure.Observability.Context`), so the whole saga chain — e.g. the
credit leg of a transfer, or the reversal legs of a cancellation — is attributed
to the originating request. Only genuinely **background writes** (the
exchange-rate publisher timer, startup seed) remain unattributed: they get the
correct **`event_type`** but **no** `correlationId`/`userId`, since they run
detached from any request. Their log lines carry a **nil** `correlationId`
(`00000000-…`) as a "no request" sentinel, and `| json | correlationId="…"`
won't match them.

## Troubleshooting

### Check logs

```bash
just deploy-logs
```

### SSH into the server

```bash
source infra/deploy.env
ssh -i "$DEPLOY_SSH_KEY" "$DEPLOY_USER@$DEPLOY_HOST"
cd /opt/backend
docker compose ps          # service status
docker compose logs -f     # all logs
docker compose logs backend     # app logs only
```

### Restart a single service

```bash
ssh -i ... root@<ip> "cd /opt/backend && docker compose restart backend"
```

### Caddy not getting HTTPS certificate

- Verify DNS A record points to the server IP
- Check Caddy logs: `docker compose logs caddy`
- Ensure ports 80 and 443 are open (OpenTofu firewall handles this)

### App fails to start

- Check env vars: `docker compose exec backend env`
- Verify Postgres is healthy: `docker compose ps postgres`
- Check app logs: `docker compose logs backend`
