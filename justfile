# Accounting Backend - Development Commands
# Usage: just <recipe>
# List all recipes: just --list

# Default recipe to display help
default:
    @just --list

# Generate cabal file from package.yaml
hpack:
    @echo "Generating backend.cabal from package.yaml..."
    hpack
    @echo "✓ Done"

# Build the project
build: hpack
    @echo "Building accounting backend..."
    cabal build
    @echo "✓ Build complete"

# Run the server with dev config
run:
    @echo "Starting accounting backend server..."
    cabal run backend

# Run the server with custom config
run-config CONFIG:
    @echo "Starting accounting backend with {{CONFIG}}..."
    CONFIG_PATH={{CONFIG}} cabal run backend

# Run test suite
test:
    @echo "Running tests..."
    cabal test --test-show-details=direct --enable-tests

# Run tests with coverage
test-coverage:
    @echo "Running tests with coverage..."
    cabal test --enable-coverage --test-show-details=direct --enable-tests

# Clean build artifacts
clean:
    @echo "Cleaning build artifacts..."
    cabal clean
    rm -rf dist-newstyle/
    @echo "✓ Clean complete"

# Format Haskell code with ormolu
format:
    @echo "Formatting code..."
    find src app test -name '*.hs' -exec ormolu -i {} \;
    @echo "✓ Format complete"

# Check formatting without modifying files
format-check:
    @echo "Checking code formatting..."
    find src app test -name '*.hs' -exec ormolu --mode check {} \;
    @echo "✓ Format check complete"

# Lint code with hlint
lint:
    @echo "Linting code..."
    hlint src test
    @echo "✓ Lint complete"

# Format and lint code
check: format lint
    @echo "✓ Code quality checks complete"

# Start PostgreSQL with Docker Compose
db-up:
    @echo "Starting PostgreSQL..."
    docker compose up -d
    @echo "✓ PostgreSQL started"
    @echo "Waiting for PostgreSQL to be ready..."
    sleep 3
    -docker compose exec -T postgres pg_isready -U postgres || echo "PostgreSQL not ready yet..."

# Stop PostgreSQL
db-down:
    @echo "Stopping PostgreSQL..."
    docker compose down
    @echo "✓ PostgreSQL stopped"

# Stop PostgreSQL and remove volumes
db-reset:
    @echo "Stopping PostgreSQL and removing volumes..."
    docker compose down -v
    @echo "✓ PostgreSQL stopped and volumes removed"

# Show PostgreSQL logs
db-logs:
    docker compose logs -f postgres

# Connect to PostgreSQL with psql
db-psql:
    docker compose exec postgres psql -U postgres -d accounting

# Restart PostgreSQL
db-restart: db-down db-up
    @echo "✓ PostgreSQL restarted"

# Watch and rebuild on changes (requires ghcid)
watch:
    @echo "Starting continuous compilation..."
    ghcid --command="cabal repl"

# Watch and run tests on changes
watch-test:
    @echo "Starting continuous test runner..."
    ghcid --test=:test

# Setup development environment
dev-setup: hpack db-up
    @echo "Development environment ready!"
    @echo ""
    @echo "Next steps:"
    @echo "  1. Run 'just build' to build the project"
    @echo "  2. Run 'just run' to start the server"
    @echo "  3. Visit http://localhost:8080"

# Clean and rebuild
rebuild: clean build

# Run all checks and build
all: check test build
    @echo "✓ All tasks complete"

# Verify development environment setup
verify:
    @echo "Running setup verification..."
    ./scripts/verify-setup.sh

# Update dependencies
update:
    @echo "Updating dependencies..."
    cabal update
    @echo "✓ Dependencies updated"

# Generate REPL session
repl:
    cabal repl

# Show project info
info:
    @echo "Project: Accounting Backend"
    @echo "GHC: $(ghc --version)"
    @echo "Cabal: $(cabal --version | head -n1)"
    @echo "Database: PostgreSQL 15 (Docker Compose)"
    @echo ""
    @echo "Quick commands:"
    @echo "  just build       - Build the project"
    @echo "  just run         - Run the server"
    @echo "  just test        - Run tests"
    @echo "  just db-up       - Start PostgreSQL"
    @echo "  just check       - Format and lint"

# Install git hooks (if any)
install-hooks:
    @echo "Installing git hooks..."
    @echo "✓ No hooks to install yet"

# Generate documentation
docs:
    @echo "Generating documentation..."
    cabal haddock --haddock-hyperlink-source
    @echo "✓ Documentation generated in dist-newstyle/"

# Benchmark (placeholder for future)
bench:
    @echo "Running benchmarks..."
    cabal bench

# Profile the application (placeholder for future)
profile:
    @echo "Building with profiling enabled..."
    cabal build --enable-profiling

# --- CI ---

# Trigger CI workflow for the current branch
ci:
    gh workflow run CI --ref "$(git branch --show-current)"

# Trigger CI workflow with deploy for the current branch
ci-deploy:
    gh workflow run CI --ref "$(git branch --show-current)" -f deploy=true

# --- Deployment ---

# Build and push Docker image to GHCR
image-push tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    IMAGE="ghcr.io/${GHCR_OWNER}/backend:{{tag}}"
    docker build --platform linux/amd64 -f infra/docker/Dockerfile -t "$IMAGE" .
    docker push "$IMAGE"

# Build SSH/SCP flags from infra/deploy.env (DEPLOY_SSH_KEY is optional — omit for agent-based auth)
_ssh_opts := ""

# Load deploy env and SSH into server to pull & restart
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    SSH_OPTS=( ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} )
    ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" \
      "cd /opt/backend && docker compose pull && docker compose up -d && docker image prune -f"

# Sync docker-compose and Caddyfile to the server
deploy-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    SSH_OPTS=( ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} )
    scp "${SSH_OPTS[@]}" infra/docker/docker-compose.yaml "$DEPLOY_USER@$DEPLOY_HOST:/opt/backend/docker-compose.yaml"
    scp "${SSH_OPTS[@]}" infra/caddy/Caddyfile "$DEPLOY_USER@$DEPLOY_HOST:/opt/backend/Caddyfile"
    scp "${SSH_OPTS[@]}" infra/.env "$DEPLOY_USER@$DEPLOY_HOST:/opt/backend/.env"

# Show service status on the server
deploy-status:
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    SSH_OPTS=( ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} )
    ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" \
      "cd /opt/backend && docker compose ps"

# Tail logs from the server (optionally filter by service: api, caddy, postgres)
deploy-logs *service:
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    SSH_OPTS=( ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} )
    ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" \
      "cd /opt/backend && docker compose logs -f {{service}}"

# Rollback to a specific image SHA
deploy-rollback sha:
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    SSH_OPTS=( ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} )
    ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" \
      "cd /opt/backend && sed -i 's/BACKEND_TAG=.*/BACKEND_TAG={{sha}}/' .env && docker compose pull && docker compose up -d"

# Run setup script on a fresh server
infra-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    source "infra/deploy.env"
    SSH_OPTS=( ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} )
    scp "${SSH_OPTS[@]}" infra/scripts/setup-server.sh "$DEPLOY_USER@$DEPLOY_HOST:/tmp/setup-server.sh"
    ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" "bash /tmp/setup-server.sh"
