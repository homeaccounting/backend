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

Create `.deploy.prod.env` (gitignored):

```bash
DEPLOY_HOST=<server_ip>
DEPLOY_USER=root
DEPLOY_SSH_KEY=~/.ssh/your-key
```

Run the bootstrap script:

```bash
just infra-setup prod
```

This installs Docker and creates `/opt/accounting/` on the server.

### 4. Configure the Server

SSH into the server and create the environment file:

```bash
ssh -i ~/.ssh/your-key root@<server_ip>
cat > /opt/accounting/.env << 'EOF'
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
GHCR_OWNER=<your-github-username>
ACCOUNTING_TAG=latest
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
just deploy-sync prod    # copies docker-compose.yaml and Caddyfile to server
just deploy prod         # pulls image and starts services
```

Verify everything is running:

```bash
just deploy-status prod
```

Visit `https://homeaccounting.com/api/` — Caddy will automatically provision an HTTPS certificate.

## Day-to-Day Deployment

### How It Works

1. Push code to `master`
2. GitHub Actions runs tests, then builds a Docker image and pushes it to GHCR
3. When ready, deploy manually:

```bash
just deploy prod
```

### Available Commands

| Command | Description |
|---|---|
| `just deploy <env>` | Pull latest image and restart |
| `just deploy-sync <env>` | Copy docker-compose.yaml and Caddyfile to server |
| `just deploy-status <env>` | Show `docker compose ps` on server |
| `just deploy-logs <env>` | Tail service logs |
| `just deploy-rollback <env> <sha>` | Roll back to a specific image |

### Rollback

Find the commit SHA to roll back to:

```bash
git log --oneline master
```

Then:

```bash
just deploy-rollback prod abc1234
```

This updates `ACCOUNTING_TAG` in the server's `.env` and restarts services.

To go back to latest after a rollback, SSH into the server and set `ACCOUNTING_TAG=latest` in `/opt/accounting/.env`, then `just deploy prod`.

## Updating Infrastructure

If you change `docker-compose.prod.yaml` or `Caddyfile`:

```bash
just deploy-sync prod    # copy updated files to server
just deploy prod         # restart with new config
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
just deploy-logs prod
```

### SSH into the server

```bash
source .deploy.prod.env
ssh -i "$DEPLOY_SSH_KEY" "$DEPLOY_USER@$DEPLOY_HOST"
cd /opt/accounting
docker compose ps          # service status
docker compose logs -f     # all logs
docker compose logs accounting  # app logs only
```

### Restart a single service

```bash
ssh -i ... root@<ip> "cd /opt/accounting && docker compose restart accounting"
```

### Caddy not getting HTTPS certificate

- Verify DNS A record points to the server IP
- Check Caddy logs: `docker compose logs caddy`
- Ensure ports 80 and 443 are open (OpenTofu firewall handles this)

### App fails to start

- Check env vars: `docker compose exec accounting env`
- Verify Postgres is healthy: `docker compose ps postgres`
- Check app logs: `docker compose logs accounting`
