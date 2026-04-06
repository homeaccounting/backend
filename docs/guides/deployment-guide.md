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

### 4. Configure the Server

SSH into the server and create the environment file:

```bash
ssh -i ~/.ssh/your-key root@<server_ip>
cat > /opt/backend/.env << 'EOF'
# Database
DB_HOST=postgres
DB_PORT=5432
DB_USER=accounting
DB_PASSWORD=<generate-a-secure-password>
DB_NAME=accounting

# Auth
JWT_SECRET=<generate-a-secure-secret>

# OAuth (optional)
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
TELEGRAM_BOT_TOKEN=<your-bot-token>
TELEGRAM_BOT_USERNAME=<your-bot-username>
TELEGRAM_WEBHOOK_URL=https://homeaccounting.com/api/telegram/webhook

# Docker image
GHCR_OWNER=homeaccounting
BACKEND_TAG=latest
DOMAIN=homeaccounting.com

# Exchange rate
EXCHANGE_RATE_PROVIDER=nbu
EOF
```

### 5. Log Into GHCR on the Server

Still on the server, authenticate Docker with GitHub Container Registry:

```bash
docker login ghcr.io -u <github-username>
```

Use a [personal access token](https://github.com/settings/tokens) with `read:packages` scope as the password.

### 6. Sync Config Files & Deploy

Back on your local machine:

```bash
just deploy-sync    # copies docker-compose.yaml and Caddyfile to server
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
| `just deploy-sync`           | Copy docker-compose.yaml and Caddyfile to server |
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

If you change `docker-compose.yaml` or `Caddyfile`:

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
