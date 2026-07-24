# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Haskell backend for a home accounting application. Uses **CQRS + Event Sourcing** with **Domain-Driven Design**, built on the Servant web framework with PostgreSQL via the Eventium event store library.

- **GHC**: 9.10.3
- **Build**: Cabal 3.10+ with Hpack (package.yaml → backend.cabal)
- **Prelude**: RIO (NoImplicitPrelude is enabled)
- **Database**: PostgreSQL 15 (Docker Compose), schema auto-created by eventium-postgresql

## Development Environment

The project uses **Nix** to manage development tooling. Run `nix develop` at the start of each session to enter the Nix dev shell, which puts GHC, Cabal, hpack, ormolu, hlint, just, and other required tools on `PATH`.

## Common Commands

All commands use `just` (task runner). Run `just --list` to see all recipes.

```bash
just build              # hpack + cabal build
just test               # cabal test --test-show-details=direct --enable-tests
just format             # ormolu -i on all .hs files
just lint               # hlint src test
just check              # format + lint
just run                # CONFIG_PATH=config/test.yaml cabal run backend
just docker-up          # start PostgreSQL container
just docker-down        # stop PostgreSQL
just watch              # ghcid continuous compilation
just repl               # cabal repl
just rebuild            # clean + build
```

Direct cabal commands also work:

```bash
cabal test --test-show-details=direct    # run all tests
cabal build                               # build (run hpack first if package.yaml changed)
```

## Architecture

For detailed architecture documentation, see [`docs/architecture.md`](docs/architecture.md).

Four-layer architecture with strict dependency direction:

```
Web → Application → Domain (pure, no IO)
           ↓
      Infrastructure → Domain
```

Arrows mean "may import". `app/Main.hs` is the composition root and is exempt — it wires all layers together.

### Layering Rules

| Layer | May import | Must NOT import |
|-------|------------|-----------------|
| `Domain.*` | (nothing — pure Haskell + base only) | `Application.*`, `Infrastructure.*`, `Web.*` |
| `Infrastructure.*` | `Domain.*`, third-party libs | `Application.*`, `Web.*` |
| `Application.*` | `Domain.*`, `Infrastructure.*` | `Web.*` |
| `Web.*` | Any layer | — |

These rules are not enforced by the compiler, but violations produce import cycles that surface immediately. The canonical failure is `Infrastructure.X → Application.Y → Infrastructure.Z → Infrastructure.X`. When adding an import, verify the arrow runs in the permitted direction before committing.

### Domain Layer (`src/Domain/`)

Pure business logic with no IO. Contains aggregates, commands, events, projections, and error types. Smart constructors return `Either DomainError a`. Three bounded contexts:

- **Account** — account lifecycle, balance tracking, access control
- **Transaction** — transfer saga orchestration
- **User** — authentication, profiles

### Application Layer (`src/Application/`)

Orchestration: services, process managers (sagas), read models. Services coordinate domain logic with infrastructure.

### Infrastructure Layer (`src/Infrastructure/`)

External world adapters: `App.hs` (AppM monad), `Config.hs`, `Database.hs`, `Eventium.hs`, `Auth/` (JWT, OAuth, Password, Telegram), `Json.hs`.

### Web Layer (`src/Web/`)

Servant API definitions, handlers, middleware, error mapping, request/response DTOs. Handlers stay in `AppM`; hoisting to Servant's `Handler` happens at the boundary.

### Entry Point

`app/Main.hs` — composition root. Loads config, creates connection pool, initializes event store, wires read models and process managers, starts Warp server.

## Application Monad

```haskell
type AppM = RIO AppEnv
```

- `AppEnv` holds all runtime dependencies (log function, DB pool, event store, config, caches)
- Use `HasX` capability pattern for narrow constraints: `(MonadReader env m, HasDbPool env)` not `MonadReader AppEnv m`
- Use RIO logging: `logInfo`, `logDebug`, `logWarn`, `logError`
- Domain logic must NOT use `AppM` — keep it pure

## Error Handling

- **Domain (pure)**: Smart constructors and validation return `Either DomainError a`
- **Application/Infrastructure (effectful)**: Use `AppM` (which provides `MonadError DomainError`)
- All errors use the unified `DomainError` sum type from `Domain.Core.Errors`
- For validation errors, use `mkValidationError` with field/message/value context
- No `error`, `undefined`, or other partial functions
- No exceptions for expected error flows
- Validation logic must be pure; push effects to boundaries

## Commands & Events

- **Actor field naming:** the actor (who performed the action) is always named `by :: UserId` — never `amendedBy`/`closedBy`/etc. (Some legacy Account fields still use the old style; match `by` for anything new.)
- **When to include `by`:** carry `by` **only** on commands/events that are a user-accountable *lifecycle action on the whole aggregate* — creating it (initiate), rewriting its posted financial facts (amend), or voiding it (cancel). Both legs of a two-phase saga carry it (Initiated + Completed) so the audit record is self-contained.
  - **Omit `by`** on in-place field/metadata edits that leave the money movement intact (labels, contact, allocations re-split, description, date, relations), and on pure system/saga success signals (posting completed/failed).
  - If per-edit accountability ever becomes a requirement, add `by` uniformly across all field edits — not ad hoc to one.
- **Audit history parity:** a new user-visible transaction event must be mapped in `TransactionHistoryService.toHistoryEntry` (with a matching `TransactionHistoryEntry` constructor) if its label/allocation siblings are — the mapping is `mapMaybe`, so a missing case silently drops the event from the audit trail.

## Testing

Tests live in `test/` and use Hspec with hspec-discover. Three categories:

| Suffix                | Type        | Purpose                                   |
| --------------------- | ----------- | ----------------------------------------- |
| `*Spec.hs`            | Unit        | Arrange-Act-Assert with pure domain logic |
| `*PropertySpec.hs`    | Property    | QuickCheck invariants and type class laws |
| `*IntegrationSpec.hs` | Integration | End-to-end workflows with event store     |

Test support modules in `test/Testkit/`: generators (`Generators.hs`), helpers (`Helpers.hs`), in-memory event store (`InMemoryEventStore.hs`).

### Running specific tests

```bash
# Run tests matching a pattern (each option needs its own --test-option flag)
cabal test all --test-option='--match' --test-option="/Domain.Account/"

# Reproduce a specific failure with seed
cabal test all --test-option='--match' --test-option="PATTERN" --test-option='--seed' --test-option=SEED_NUMBER

# Rerun only failed tests
cabal test all --test-option='--rerun'
```

### Testing philosophy

- **Property-based tests are primary**; unit tests supplement, not replace them
- Follow TDD: Red-Green-Refactor. Property tests first, then unit tests, then integration tests
- Domain logic invariants must be proven through QuickCheck properties
- Properties verified at compile-time by LiquidHaskell should NOT have redundant runtime tests
- Test error handling explicitly: verify `Left` results carry correct `errorContext` and messages
- Use mock constructors from `Testkit/Helpers.hs` to bypass validation in non-validation tests
- **Reuse existing test infrastructure** (`test/Testkit/*` — `Fixtures.hs`, `Helpers.hs`, `Generators.hs`, `InMemoryEventStore.hs`, etc.) rather than re-defining setup helpers per spec. Before writing a fixture (user registration, default account, dictionary lookup, event seeding, …), check whether Testkit already provides it. If a needed helper is missing **and generic**, add it to the appropriate `Testkit` module and reuse it — do not copy-paste a local one-off.

## Code Style

- **Formatter**: ormolu (mandatory, no manual overrides)
- **Linter**: hlint — no suppressions allowed without explicit approval and documented rationale
- **GHC warnings**: `-Wall -Wcompat -Widentities -Wincomplete-record-updates -Wredundant-constraints`. `-Werror` is enforced via the `ci` Cabal flag (`-fci`). CI runs `cabal build all -j -fci` and `cabal test all -j -fci`, and the local `just build` / `just test` gates pass `-fci` to match. Note: the incremental `.o` cache can mask `-Werror` regressions on a warm build — `just rebuild` (clean + `-fci` build) for a definitive check
- **Required extensions**: `NoImplicitPrelude`, `StrictData`, `GADTs`, `KindSignatures`, `DataKinds`, `TypeFamilies`, `NoFieldSelectors`, `DuplicateRecordFields`, `OverloadedRecordDot`
- Never export data constructors or field selectors directly — use smart constructors and accessor functions
- Total functions only; no partial functions

## Configuration

YAML-based config with environment variable substitution (`${VAR:-default}`):

- `config/local.yaml` — development
- `config/test.yaml` — testing
- `config/prod.yaml` — production (all values from env vars)

Config path set via `CONFIG_PATH` env var. Environment variables loaded via direnv (`.envrc` + `.env`).

## Event Sourcing (Eventium)

- Event store is the source of truth; no mutable state tables
- Aggregates are rebuilt from events via projections
- Optimistic concurrency via `(uuid, version)` unique constraint
- Read models are in-memory projections from events
- Process managers (sagas) handle cross-aggregate workflows (e.g., `TransferManager` for two-phase account transfers)
- Eventium packages: `eventium-core`, `eventium-postgresql`, `eventium-memory`, `eventium-testkit`

### Eventium as a first-class goal

A core goal of this project is to grow **eventium** into the best event-sourcing
library for Haskell. Eventium is developed in tandem with this backend (it is a
local, owned dependency), so:

- **Push generic event-sourcing machinery down into eventium.** If a piece of
  boilerplate or infrastructure is generic enough to apply beyond this app
  (replay/backfill, checkpointed projections, read-model lifecycle, subscription
  drivers, etc.), it belongs in the library, not in `Infrastructure.*`. The app
  should keep only domain-specific wiring.
- When adding to eventium, design for **genericity** — it must serve all event
  types and backends, and both **synchronous (in-transaction)** and
  **asynchronous (polling)** read-model consumers, not a single call site.
- Prefer evolving eventium's abstractions cleanly (we own it; there is no
  external-compat constraint) over working around them in the app.

## Monad Usage Guidelines

- **`IO`**: Only for resource acquisition, config loading, wiring in `Main.hs`
- **Polymorphic `m` with capabilities**: For reusable infrastructure helpers (DB runners, event store operations)
- **`AppM`**: For business logic flows, HTTP handlers, process managers
- **No monad**: For pure domain logic, validation, projections
- Don't over-constrain: use `MonadIO m` when `MonadUnliftIO m` isn't needed; use `HasX env` not `MonadReader AppEnv m`

## LiquidHaskell

All domain types in `src/` must have LiquidHaskell refinement types. The project uses LiquidHaskell 0.9.10+ with the following patterns:

- **`measure`** for boolean predicates (property checking): `{-@ measure isNonNegative :: Decimal -> Bool @-}`
- **`reflect`** for value-computing functions: `{-@ reflect textLength @-}`
- Smart constructors must have validation logic that mirrors refinement predicates exactly
- Use centralized validation functions returning `Maybe ErrorEnum`, then pattern match in the smart constructor
- No bang patterns (`!`) in LiquidHaskell refinements — only in actual data declarations
- Add inter-field refinements incrementally; verify after each addition
- Export all measures and predicates in the module export list
- When facing sort errors with predicates, try inlining the expression or using direct operators (`h >= low` instead of `highGEQlow h low`)

### Development sequence for new types

```
RDD (define refinements) → TDD (write tests) → Implementation → Verification
```

## Change Philosophy

- Treat existing code, types, tests, and documentation as intentionally designed
- Modifications should be strictly additive by default
- Never remove or significantly alter existing content without explicit request or documented evidence of incorrectness
- When modifying: quote the specific section, explain the reason, verify preservation of invariants

## Documentation Structure

Project documentation lives in `docs/` with a precedence hierarchy:

- **L1 (highest)**: `mission-statement.md`, `operational-context.md`, `user-experience-spec.md`
- **L2**: `architecture.md` (living doc), `deployment.md` (ops runbook)
- **L3**: `specs/` (design specs, `*-design.md`), `plans/` (implementation plans), `decisions/` (ADRs)

Specs and plans use `YYYY-MM-DD-feature-name.md` naming (`-design.md` suffix for specs) and require frontmatter with `status: draft|in-progress|completed|superseded`. In case of conflict, higher-level documents take precedence.
