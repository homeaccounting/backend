---
status: in-progress
---

# Deployment Infrastructure Design

## Overview

Declarative infrastructure and deployment setup for the home accounting backend service. Hetzner VPS running Docker Compose (app + Postgres + Caddy), provisioned with OpenTofu, images built by GitHub Actions and pushed to GHCR, deployed manually via `just deploy <env>`.

**Cost:** ~€5/mo (Hetzner CX22)

## Goals

- Fully declarative infrastructure (OpenTofu)
- Docker-packaged application
- Push to master builds and publishes a Docker image (CI)
- Manual deploy via `just deploy prod` / `just deploy test`
- HTTPS with automatic certificate management
- Minimal operational overhead

## Non-Goals

- Auto-deploy on push (explicit deploy control preferred)
- Managed database (Postgres runs on the same VPS)
- Database backups (deferred)
- Multi-region or HA setup
- Kubernetes or container orchestration

## Repository Structure

```
infra/
├── terraform/
│   ├── main.tf                    # Hetzner provider, VPS, firewall, SSH key
│   ├── variables.tf               # Configurable inputs (server type, location, domain)
│   ├── outputs.tf                 # Server IP, domain info
│   ├── dns.tf                     # DNS records
│   ├── terraform.tfvars           # (gitignored) actual values
│   └── backend.tf                 # OpenTofu state backend (local)
├── docker/
│   ├── Dockerfile                 # Multi-stage: build Haskell app, copy to slim runtime
│   └── docker-compose.prod.yaml   # App + Postgres + Caddy, runs on VPS
├── caddy/
│   └── Caddyfile                  # Reverse proxy with automatic HTTPS
└── scripts/
    └── setup-server.sh            # One-time server bootstrap
```

Infra code lives in `infra/` at the repo root. Existing `docker-compose.yaml` (dev Postgres) is untouched.

## Docker Image

### Multi-Stage Build

1. **Build stage:** Official Haskell image (GHC 9.10.3). Install system deps (`libpq-dev`). Two-step COPY for caching: first copy `package.yaml`, `cabal.project`, and generated `.cabal` file, then `cabal build --only-dependencies` (cached unless deps change). Then copy source and `cabal build`. Eventium is pulled from Hackage. **Important:** `cabal.project.local` must NOT be copied — it contains local override paths for eventium that only apply to development.

2. **Runtime stage:** Debian slim with runtime libraries (`libpq`, `libgmp`, `zlib`). Copy compiled binary from build stage. Final image ~50-80MB.

All three config files (`config/local.yaml`, `config/test.yaml`, `config/prod.yaml`) are baked into the image. The environment selects the config via `CONFIG_FILE` env var (e.g., `CONFIG_FILE=config/prod.yaml`). This keeps one image for all environments. Configs contain no secrets — only `${VAR}` references resolved at runtime. Separate config files are intentional: prod has no fallback defaults (fail-fast on missing env vars), while local/test provide sensible defaults for development.

### Registry

GitHub Container Registry (GHCR).

- Free for public repos, 500MB free storage for private
- Auth via built-in `GITHUB_TOKEN`
- Tags: `ghcr.io/<owner>/accounting:<short-sha>` and `:latest`

## CI Pipeline (GitHub Actions)

Extend existing `.github/workflows/ci.yml` with a new job:

```
push to master
  → existing CI job (lint, test)
  → "build-image" job (needs: ci, only on master)
      → checkout
      → docker buildx build (with layer caching)
      → push to GHCR with :sha and :latest tags
```

- New `build-image` job added to the same `ci.yml` file, with `needs: build-and-test`
- Only triggers on master pushes (not PRs)
- Uses Docker BuildKit layer caching — Cabal dependencies cached separately from source
- `GITHUB_TOKEN` for GHCR authentication (no extra secrets)

## OpenTofu

OpenTofu provisions the **production** environment only. Test environment provisioning is deferred (see Future Considerations).

### Resources Provisioned

| Resource | Details |
|---|---|
| Hetzner VPS | CX22: 2 vCPU, 4GB RAM, 40GB disk |
| Firewall | Allow SSH (22), HTTP (80), HTTPS (443) |
| SSH Key | User's public key |
| DNS Records | A record: domain → VPS IP |

### State

Stored locally in `infra/terraform/terraform.tfstate` (gitignored). Remote state is unnecessary for a single-person project.

### What OpenTofu Does NOT Manage

Docker containers, application deployments, secrets on disk. OpenTofu handles infrastructure only.

## Server Bootstrap

One-time `scripts/setup-server.sh` (run via `just infra-setup` after `tofu apply`):

- Install Docker Engine + Docker Compose plugin
- Create app directory (`/opt/accounting/`)
- Copy `docker-compose.prod.yaml` and `Caddyfile` to server
- Create `.env` on the server with required production env vars (see below)
- Log into GHCR (`docker login ghcr.io`) for image pulls

> **Note (2026-04-17):** The env-var layout shown below reflects the deployment as originally designed. The OAuth `*_REDIRECT_URI` variables and `TELEGRAM_WEBHOOK_URL` are no longer set by the operator — they are derived from `API_BASE_URL` in `config/prod.yaml`. See `docs/specs/2026-04-17-api-base-url-derived-urls-design.md` for the current layout.

### Required Server Environment Variables

The `.env` file on the VPS must contain all variables referenced by `config/prod.yaml`:

```
# Database (Postgres service name is the Docker Compose hostname)
DB_HOST=postgres
DB_PORT=5432
DB_USER=accounting
DB_PASSWORD=<secure-password>
DB_NAME=accounting

# Auth
JWT_SECRET=<secure-secret>

# OAuth (optional, set if enabled)
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_REDIRECT_URI=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
GITHUB_REDIRECT_URI=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
MICROSOFT_REDIRECT_URI=

# Telegram
TELEGRAM_BOT_TOKEN=<token>
TELEGRAM_BOT_USERNAME=<username>
TELEGRAM_WEBHOOK_URL=https://<domain>/api/telegram/webhook

# Docker image
GHCR_OWNER=<github-username-or-org>
IMAGE_TAG=latest
DOMAIN=<your-domain.com>

# Exchange rate
EXCHANGE_RATE_PROVIDER=nbu
```

## Production Stack (Docker Compose)

Three services on a shared Docker network:

```
caddy (:80/:443, exposed)
  → accounting (:8080, internal)
  → postgres (:5432, internal)
```

- **Caddy:** Automatic HTTPS via Let's Encrypt. Proxies `domain → accounting:8080`. Zero-config cert renewal.
- **Accounting:** Image from GHCR. `CONFIG_FILE=config/prod.yaml` selects the production config (baked into the image). Secrets injected via env vars from server `.env`. Depends on Postgres health check. Restart: `unless-stopped`.
- **Postgres 15:** Named volume for persistence. Not exposed to the internet.

Only Caddy exposes ports to the host.

## Deploy Flow

### Commands

- `just deploy prod` — deploy to production
- `just deploy test` — deploy to test environment
- `just deploy-status <env>` — check service health
- `just deploy-logs <env>` — tail logs
- `just deploy-rollback <env> <sha>` — rollback to specific image (find SHA via `git log --oneline` or GHCR web UI)

### What `just deploy <env>` Does

1. Read `.deploy.<env>.env` for connection details
2. SSH into the VPS
3. `docker compose pull` — pull latest image from GHCR
4. `docker compose up -d` — restart changed services
5. `docker image prune -f` — clean up old images

### Environment Config

Per-environment files (gitignored):

- `.deploy.prod.env`
- `.deploy.test.env`

Shape:

```
DEPLOY_HOST=1.2.3.4
DEPLOY_USER=root
DEPLOY_SSH_KEY=~/.ssh/hetzner
```

## Security

- Firewall allows only ports 22, 80, 443
- Postgres not exposed to the internet
- Production secrets via env vars on the server (not in repo)
- SSH key authentication only
- `terraform.tfvars`, `terraform.tfstate*`, and `.deploy.*.env` gitignored
- GHCR images private by default
- `.gitignore` must be updated to include these patterns

## Future Considerations (Not in Scope)

- Postgres backups to Hetzner Object Storage
- Health check endpoint for monitoring
- Structured logging / observability
- Zero-downtime deploys
- Test environment provisioning
