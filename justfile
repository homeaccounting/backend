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

# Build the project (-fci enables -Werror, matching CI)
build: hpack
    @echo "Building accounting backend..."
    cabal build all -fci
    @echo "✓ Build complete"

# Run the server with dev config
run:
    @echo "Starting accounting backend server..."
    cabal run backend

# Run the server with custom config
run-config CONFIG:
    @echo "Starting accounting backend with {{CONFIG}}..."
    CONFIG_PATH={{CONFIG}} cabal run backend

# Run test suite (-fci enables -Werror, matching CI)
test:
    @echo "Running tests..."
    cabal test all -fci --test-show-details=direct --enable-tests

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

# Lint code with hlint (read-only)
lint:
    @echo "Linting code..."
    hlint src test
    @echo "✓ Lint complete"

# Auto-fix lint issues with hlint --refactor (requires apply-refact)
lint-fix:
    @echo "Auto-fixing lint issues..."
    hlint src test --refactor --refactor-options="-i"
    @echo "✓ Lint fix complete"

# Read-only quality umbrella: format check + lint (CI-safe)
check: format-check lint
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

# Prepare everything needed before `just run` (env, db, hpack, build)
dev-setup: hpack db-up build
    @[ -f .env ] || (cp .env.example .env && echo "✓ Created .env from .env.example")
    @echo "✓ Development environment ready — run 'just run' to start the server (http://localhost:8080)"

# Clean and rebuild
rebuild: clean build

# Run all checks and build
all: check test build
    @echo "✓ All tasks complete"

# Verify development environment setup
verify:
    @echo "Running setup verification..."
    ./scripts/verify-setup.sh

# Refresh the Hackage package index (to pull newer deps, bump index-state in cabal.project)
update:
    @echo "Refreshing Hackage package index..."
    cabal update

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

# --- Image ---

# Build and push image to ghcr.io. Tag defaults to dev-<short-sha>.
# Requires `gh auth login` and `docker login ghcr.io` (or runs gh-token login below).
publish tag="": hpack
    #!/usr/bin/env bash
    set -euo pipefail
    SHA="$(git rev-parse --short HEAD)"
    TAG="{{tag}}"
    [[ -z "$TAG" ]] && TAG="dev-$SHA"
    OWNER="homeaccounting"
    IMAGE="ghcr.io/${OWNER}/backend:${TAG}"
    echo "==> docker login ghcr.io"
    gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin
    echo "==> docker build $IMAGE"
    docker build --platform linux/amd64 \
      --build-arg APP_COMMIT_HASH="$SHA" \
      -t "$IMAGE" .
    echo "==> docker push $IMAGE"
    docker push "$IMAGE"
    echo "==> Published: $IMAGE"

# Deployment moved to homeaccounting/infra. From that repo:
#   just deploy-backend <sha>   # deploy this image
#   just deploy-config           # push compose/Caddyfile changes
# Or via gh: gh workflow run deploy.yml -R homeaccounting/infra -f service=backend -f tag=<sha>
