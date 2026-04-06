#!/usr/bin/env bash
set -euo pipefail

# One-time server bootstrap for backend deployment.
# Run via: just infra-setup
# Prerequisites: Terraform applied, SSH access to server.

echo "=== Installing Docker ==="
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "=== Creating app directory ==="
mkdir -p /opt/backend

echo "=== Docker installed successfully ==="
echo ""
echo "Next steps (manual):"
echo "  1. Copy docker-compose.yaml and Caddyfile to server:"
echo "     just deploy-sync"
echo "  2. Create /opt/backend/.env with production secrets"
echo "  3. Log into GHCR: docker login ghcr.io"
echo "  4. Run: just deploy"
