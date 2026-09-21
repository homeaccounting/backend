# Accounting Backend

A personal accounting system backend built with Haskell using **Domain-Driven Design (DDD)**, **CQRS** (Command Query Responsibility Segregation), and **Event Sourcing** patterns with the [Eventium](https://eventium.dev) library.

## Architecture

This system implements a clean hexagonal architecture with the following layers:

### Domain Layer (`src/Domain/`)
- **Core Types**: Money, AccountId, TransactionId, validation
- **Account Aggregate**: Account commands, events, projections, and business rules
- **Transaction Aggregate**: Transfer saga with process manager coordination
- Pure business logic with no IO

### Application Layer (`src/Application/`)
- **Process Managers**: Transfer saga orchestration
- **Read Models**: Optimized query projections (AccountSummary)
- Application services and orchestration

### Infrastructure Layer (`src/Infrastructure/`)
- **Event Store**: PostgreSQL-backed event sourcing (via eventium-postgresql)
- **Configuration**: YAML-based configuration management
- **Database**: Connection pooling and migration management

### Web Layer (`src/Web/`)
- **REST API**: Type-safe Servant API with OpenAPI documentation
- **DTOs**: Request/Response types
- **Server**: Warp HTTP server with CORS and error handling

## Features

- ✅ **Event Sourcing**: All state changes stored as immutable events
- ✅ **CQRS**: Separate command and query models
- ✅ **Process Managers**: Saga pattern for complex workflows (money transfers)
- ✅ **Type Safety**: Leverages Haskell's type system for correctness
- ✅ **PostgreSQL**: Persistent event store with optimistic concurrency
- ✅ **REST API**: Clean HTTP API with Servant
- 🚧 **Projections**: Real-time read model updates
- 🚧 **Testing**: Property-based and integration tests

## Prerequisites

### With Nix (Recommended)

- [Nix](https://nixos.org/download.html) with flakes enabled
- [Docker](https://www.docker.com/get-started) (for PostgreSQL)
- [just](https://github.com/casey/just) command runner (optional but recommended)

### Without Nix

- GHC 9.10.3
- Cabal 3.10+
- PostgreSQL 15+
- [just](https://github.com/casey/just) command runner (optional but recommended)
- System libraries: `libpq-dev`, `zlib1g-dev`

## Quick Start

### 1. Start Development Environment

#### With Nix (Recommended)

```bash
# Enter development shell
nix develop

# Or use direnv for automatic loading
direnv allow
```

#### Without Nix

```bash
# Install dependencies
cabal update
cabal build --only-dependencies
```

### 2. Start PostgreSQL

```bash
# Start PostgreSQL with Docker Compose
just db-up

# Or manually with docker compose
docker compose up -d

# Verify it's running
docker compose ps
```

### 3. Build and Run

```bash
# Build the project (runs hpack + cabal build)
just build

# Run the server
just run

# Or with a specific config
just run-config config/local.yaml

# Or manually with cabal
cabal run backend
```

The server starts on `http://localhost:8080` by default.

## Development Workflow

### Project Structure

```
accounting/
├── src/
│   ├── Domain/              # Pure business logic
│   │   ├── Core/           # Shared domain types
│   │   ├── Account/        # Account aggregate
│   │   └── Transaction/    # Transaction aggregate
│   ├── Application/         # Application services
│   │   ├── ProcessManagers/# Saga orchestration
│   │   └── ReadModels/     # Query projections
│   ├── Infrastructure/      # Technical concerns
│   ├── Web/                # HTTP API
│   └── Main.hs             # Composition root
├── test/                   # Test suites
├── config/                 # Configuration files
├── database/               # Database schemas
├── package.yaml            # Hpack configuration
├── cabal.project           # Multi-package project
├── flake.nix              # Nix development environment
├── docker-compose.yaml     # PostgreSQL container (local dev)
└── infra/                  # Deployment: Docker, Caddy, Terraform, scripts
```

### Common Commands

```bash
# Build / run
just build                  # hpack + cabal build
just rebuild                # clean + build
just run                    # run the server
just run-config CONFIG      # run with a specific config path

# Code quality
just format                 # ormolu -i on src/app/test
just format-check           # ormolu --mode check
just lint                   # hlint src test
just check                  # format + lint

# Tests
just test                   # cabal test --test-show-details=direct
just test-coverage          # tests with --enable-coverage
just watch                  # ghcid continuous compilation
just watch-test             # ghcid --test=:test

# Database (PostgreSQL via docker compose)
just db-up                  # start PostgreSQL
just db-down                # stop PostgreSQL
just db-reset               # stop and remove volumes
just db-restart             # restart
just db-logs                # tail logs
just db-psql                # psql shell

# Dev environment
just dev-setup              # hpack + db-up
just hpack                  # regenerate backend.cabal from package.yaml
just update                 # cabal update
just repl                   # cabal repl
just clean                  # remove build artifacts
just all                    # check + test + build

# CI / deployment
just ci                     # trigger CI workflow for current branch
just ci-deploy              # trigger CI with deploy=true
just image-push [tag]       # build & push Docker image to GHCR
just deploy                 # pull & restart on server
just deploy-sync            # sync compose + Caddyfile to server
just deploy-status          # service status on server
just deploy-logs [service]  # tail server logs
just deploy-rollback SHA    # roll back to a specific image SHA
just infra-setup            # run setup script on a fresh server

# Show all available commands
just --list
```

See [`docs/deployment.md`](docs/deployment.md) for the full deployment runbook.

### Configuration

The application uses YAML configuration files in `config/`:

- `local.yaml` - Local development (default)
- `test.yaml` - Test suite / CI
- `prod.yaml` - Production settings

Override with environment variable:
```bash
# Using just
just run-config config/local.yaml

# Or manually with cabal
CONFIG_PATH=config/local.yaml cabal run backend
```

### Environment Variables

Defined in `.env` (loaded automatically by `.envrc` via direnv):

```bash
DB_HOST=127.0.0.1
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=password
DB_NAME=accounting
CONFIG_FILE=config/local.yaml
```

## API Endpoints

### Accounts

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/accounts` | Create new account |
| GET | `/accounts/:id` | Get account details |
| POST | `/accounts/:id/credit` | Credit account |
| POST | `/accounts/:id/debit` | Debit account |

### Transactions

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/transactions` | Create transaction (transfer) |
| GET | `/transactions/:id` | Get transaction status |

## Domain Model

### Account Aggregate

**Commands:**
- `CreateAccount` - Create a new account with initial balance
- `CreditAccount` - Add money to account
- `DebitAccount` - Remove money from account (with insufficient funds check)

**Events:**
- `AccountCreated` - Account successfully created
- `AccountCredited` - Money added to account
- `AccountDebited` - Money removed from account
- `AccountDebitRejected` - Debit failed (insufficient funds)

### Transaction Aggregate (Transfer Saga)

**Commands:**
- `InitiateTransfer` - Start money transfer between accounts
- `CompleteTransfer` - Finalize successful transfer
- `FailTransfer` - Compensate failed transfer

**Events:**
- `TransferInitiated` - Transfer started
- `TransferCompleted` - Transfer succeeded
- `TransferFailed` - Transfer rolled back

**Process Manager:**
The `TransferManager` orchestrates the saga:
1. Listen for `TransferInitiated`
2. Debit source account
3. Credit target account (on success)
4. Emit `TransferCompleted` or `TransferFailed`
5. Compensate on failure

## Event Sourcing with Eventium

This project uses the [Eventium](https://eventium.dev) library for event sourcing:

- **Event Store**: PostgreSQL-backed persistent storage
- **Projections**: Aggregate state reconstruction from events
- **Command Handlers**: Pure business logic with event generation
- **Process Managers**: Saga pattern for distributed transactions
- **Read Models**: Optimized query projections

### Using Hackage Packages (Default)

By default, the project uses published eventium packages from Hackage:
- `eventium-core` - Core event sourcing abstractions
- `eventium-postgresql` - PostgreSQL event store implementation
- `eventium-memory` - In-memory store for testing

No special setup is required - Cabal automatically fetches these dependencies.

### Local Development with Eventium

If you need to develop eventium changes alongside accounting code:

```bash
# 1. Enable local packages
cp cabal.project.local.example cabal.project.local

# 2. Clean and rebuild
cabal clean
cabal build all
```

To switch back to Hackage packages:
```bash
rm cabal.project.local
cabal clean
cabal build all
```

## Testing

```bash
# Run all tests
cabal test

# Run specific test suite
cabal test accounts-test

# With coverage
cabal test --enable-coverage

# Watch mode
ghcid --test=:test
```

Test structure:
- `test/Domain/` - Domain aggregate unit tests
- `test/Web/` - API integration tests

## Continuous Integration

The project uses GitHub Actions for automated testing and quality checks. The CI pipeline runs on:
- Every push to `main`/`master` branches
- All pull requests
- Version tags

The pipeline includes:
- ✅ **Build**: Compiles the project with GHC 9.10.3
- ✅ **Lint**: Runs hlint for code quality checks
- ✅ **Test**: Executes all test suites with PostgreSQL
- ✅ **Cache**: Optimizes build times with dependency caching

Trigger CI manually with `just ci` (or `just ci-deploy` to include a deploy step).

## Troubleshooting

### PostgreSQL Connection Issues

```bash
# Check if PostgreSQL is running
just db-up

# View logs
just db-logs

# Restart PostgreSQL
just db-restart

# Connect to PostgreSQL
just db-psql
```

### Build Issues

```bash
# Clean build artifacts
just clean

# Update dependencies
just update

# Regenerate cabal file
just hpack

# Build with verbose output
cabal build -v2

# Clean and rebuild
just rebuild
```

### Nix Issues

```bash
# Update flake inputs
nix flake update

# Rebuild development shell
nix develop --refresh

# Clear Nix cache
nix-collect-garbage -d
```

## References

- [`docs/architecture.md`](docs/architecture.md) - Living architecture doc
- [`docs/deployment.md`](docs/deployment.md) - Deployment runbook
- [`CLAUDE.md`](CLAUDE.md) - Coding conventions and monad/error handling guidance
- [Eventium](https://eventium.dev) - Event sourcing framework

## Contributing

- [`CONTRIBUTING.md`](CONTRIBUTING.md) - How to set up, what blocks a merge, commit and branch conventions
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) - Expected behaviour; reports go to `conduct@homeaccounting.com`
- [`CLA.md`](CLA.md) - Contributor Licence Agreement, signed once via a bot on your first PR
- [Discussions](https://github.com/homeaccounting/backend/discussions) - Questions, ideas, and bank-provider requests
- [Community chat](https://www.homeaccounting.com/chat) - Discord

## Security

Never report a vulnerability in a public issue - see [`SECURITY.md`](SECURITY.md)
for private reporting and `security@homeaccounting.com`.

## License

GNU Affero General Public License v3.0 (AGPL-3.0) - See [LICENSE](LICENSE) for details.

The HomeAccounting name and logo are not covered by that license - see
[`TRADEMARK.md`](TRADEMARK.md).
