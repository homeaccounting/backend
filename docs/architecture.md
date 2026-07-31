# System Architecture

**Level 2 Document**: Current architectural state. Updated when major structural changes occur.

## Overview

A personal accounting backend built in Haskell using Domain-Driven Design with CQRS and Event Sourcing. The system tracks financial accounts, money transfers, and supports multi-user access with role-based permissions.

```
┌─────────────────────────────────────────────────────────────────┐
│                     Web Layer (HTTP only)                         │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐ ┌────────────────┐   │
│  │ AuthAPI  │ │ UserAPI  │ │ AccountAPI  │ │ TransactionAPI │   │
│  └────┬─────┘ └────┬─────┘ └──────┬──────┘ └───────┬────────┘   │
│       │            │              │                │             │
│       └────────────┴──────┬───────┴────────────────┘             │
│                           │                                      │
│  ┌──────────────┐  ┌──────┴──────┐  ┌───────────────────────┐   │
│  │ ErrorMapping │  │ Auth        │  │ Types.hs (DTOs +      │   │
│  │ (Domain→HTTP)│  │ Middleware  │  │  conversion functions) │   │
│  └──────────────┘  └──────┬──────┘  └───────────────────────┘   │
└───────────────────────────┼─────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│                    Application Layer                              │
│  ┌────────────┐ ┌──────────────┐ ┌────────────┐ ┌────────────┐   │
│  │ AccountSvc │ │TransactionSvc│ │ AuthService│ │ UserService│   │
│  └─────┬──────┘ └──────┬───────┘ └─────┬──────┘ └─────┬──────┘   │
│           │                     │                    │            │
│  ┌────────┴────┐  ┌────────────┴──────┐  ┌──────────┴────────┐  │
│  │ Process     │  │  Authorization    │  │   Read Models     │  │
│  │ Managers    │  │  Service (pure)   │  │  (Projections)    │  │
│  └────────┬────┘  └──────────────────-┘  └───────────────────┘  │
│           │                                                      │
└───────────┼──────────────────────────────────────────────────────┘
            │
┌───────────┼─────────────────────────────────────────────────────┐
│           ▼          Domain Layer (Pure)                          │
│  ┌─────────┐    ┌─────────────┐    ┌──────────────┐             │
│  │  User   │    │   Account   │    │ Transaction  │             │
│  │Aggregate│    │  Aggregate  │    │  Aggregate   │             │
│  └─────────┘    └─────────────┘    └──────────────┘             │
│       │              │                    │                      │
│       └──────────────┴────────────────────┘                      │
│                      │                                           │
│              ┌───────┴───────┐                                   │
│              │  Core Types   │                                   │
│              │ (Money, IDs)  │                                   │
│              └───────────────┘                                   │
└─────────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│                   Infrastructure Layer                            │
│  ┌──────────┐  ┌──────────┐  ┌────────┐  ┌──────────────────┐   │
│  │ Eventium │  │ Database │  │ Config │  │ Auth (JWT/OAuth/ │   │
│  │ (ES)     │  │ (PG)     │  │ (YAML) │  │ Password/TG)     │   │
│  └──────────┘  └──────────┘  └────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │  PostgreSQL   │
                    │ (Event Store) │
                    └───────────────┘
```

## Module Structure

### Layer Dependencies (Top → Bottom)

```
Web → Application → Domain → Core
                ↓
          Infrastructure
```

**Strict rule**: Dependencies flow downward only. The Application layer never imports from Web. DTO conversion (request parsing, response building) happens exclusively in the Web layer; services accept and return domain/application types.

### Source Layout

```
src/
├── Domain/                 # Pure business logic (no IO)
│   ├── Core/               # Shared types and errors
│   │   ├── Types.hs        # Money, AccountId, UserId, etc.
│   │   └── Errors.hs       # Core domain errors
│   ├── Account/            # Account aggregate
│   ├── Transaction/        # Transaction aggregate
│   └── User/               # User aggregate
│
├── Application/            # Use cases and orchestration
│   ├── ProcessManagers/    # Sagas (TransferManager)
│   ├── ReadModels/         # Query projections
│   └── Services/           # Business orchestration
│       ├── AccountService.hs       # Account use case orchestration
│       ├── AuthService.hs          # Authentication orchestration
│       ├── AuthorizationService.hs # RBAC access control (pure)
│       ├── TransactionService.hs   # Transfer use case orchestration
│       └── UserService.hs          # User profile orchestration
│
├── Infrastructure/         # External world adapters
│   ├── App.hs              # AppM monad (RIO-based)
│   ├── Config.hs           # YAML configuration
│   ├── Database.hs         # PostgreSQL connection
│   ├── Eventium.hs         # Event store integration
│   └── Auth/               # Authentication providers
│       ├── JWT.hs
│       ├── OAuth.hs
│       ├── Password.hs
│       └── Telegram.hs
│
├── Web/                    # HTTP interface (thin adapters)
│   ├── API/                # Servant API definitions (handlers)
│   ├── Middleware/         # Auth middleware
│   ├── ErrorMapping.hs     # DomainError → ServerError mapping
│   ├── Server.hs           # Warp server setup
│   └── Types.hs            # Request/Response DTOs + conversions
│
└── Telegram/               # Telegram bot interface
    ├── Bot.hs
    ├── Commands.hs
    ├── Keyboards.hs
    └── Types.hs
```

## Bounded Contexts

### User Aggregate (`Domain.User`)

**Responsibility**: User identity, authentication methods, profile.

**Commands**: `RegisterUser`, `RegisterViaTelegram`, `LinkOAuthAccount`, `LinkTelegramAccount`, `ChangePassword`

**Events**: `UserRegistered`, `UserRegisteredViaTelegram`, `OAuthAccountLinked`, `TelegramAccountLinked`, `PasswordChanged`

**Key Invariants**:
- Email is unique identifier for web login
- One Telegram account per user
- Multiple OAuth providers can link to one user
- External account auto-created on registration

### Account Aggregate (`Domain.Account`)

**Responsibility**: Account lifecycle, balance tracking, access control (RBAC).

**Commands**:
- *User-facing*: `CreateAccount`, `ShareAccount`, `RevokeAccountAccess`
- *Internal (saga-only)*: `DebitAccount`, `CreditAccount` — issued by TransferManager process manager, not exposed via API

**Events**:
- `AccountCreated`, `AccountAccessGranted`, `AccountAccessRevoked`
- `AccountDebited` — emitted when `DebitAccount` succeeds (carries `TransactionId` for saga correlation)
- `AccountCredited` — emitted when `CreditAccount` succeeds (carries `TransactionId` for saga correlation)
- `AccountDebitRejected` — emitted when `DebitAccount` fails (e.g., insufficient funds on `RegularAccount`; triggers saga compensation)

**Key Invariants**:
- Creator is always Owner
- Owner cannot be removed from access list
- External accounts cannot be shared
- External accounts can have negative balance (debit always succeeds)
- Regular accounts cannot go negative (debit rejected if insufficient funds)

**Account Types**:
- `RegularAccount` - User-created (Checking, Savings, Cash)
- `ExternalAccount` - System-created, represents "outside world" for income/expenses

**Access Roles**:
| Role | View | Transfer | Share | Delete |
|------|------|----------|-------|--------|
| Owner | ✓ | ✓ | ✓ | ✓ |
| Editor | ✓ | ✓ | ✗ | ✗ |
| Viewer | ✓ | ✗ | ✗ | ✗ |

### Transaction Aggregate (`Domain.Transaction`)

**Responsibility**: Money transfers between accounts.

**Commands**: `InitiateTransfer`, `CompleteTransfer`, `FailTransfer`

**Events**: `TransferInitiated`, `TransferCompleted`, `TransferFailed`

**Key Invariants**:
- All money movement is via transfers (double-entry)
- Source must have sufficient balance (except External)
- User needs Editor+ role on both source and target

**Transfer Patterns**:
- Income: `External → Regular`
- Expense: `Regular → External`
- Internal: `Regular → Regular`

### Configuration Aggregate (`Domain.Configuration`)

**Responsibility**: Per-user configuration — base/default currency, bank connections, and the **dictionaries** (categories, labels, contacts) used to classify transactions.

**Dictionaries** are a closed, code-defined set keyed by `DictionaryKind` (`IncomeKind`, `ExpenseKind`, `LabelKind`, `ContactKind`) — a sum type, not a free-text id — held as `Map DictionaryKind Dictionary`. There is no user-created dictionary. Entries form a **tree** via an adjacency list: each `DictionaryEntry` carries a `parentId :: Maybe DictionaryEntryId` (`Nothing` = root). A "group" is emergent — any node that has children — not a distinct type. `groupsSelectable :: DictionaryKind -> Bool` is a pure per-kind policy (never stored), and `entryAssignable` derives from it whether a given node may be attached to a transaction.

**Commands** (dictionary subset): `AddDictionaryEntry` (with optional `parentId`), `RenameDictionaryEntry`, `MoveDictionaryEntry`, `RemoveDictionaryEntry`.

**Events** (dictionary subset): `DictionaryEntryAdded`, `DictionaryEntryRenamed`, `DictionaryEntryMoved`, `DictionaryEntryRemoved`.

**Key Invariants** (dictionary tree):
- Names are unique per sibling group, not dictionary-wide
- A parent referenced by `parentId`/`newParentId` must exist
- Moves are cycle-free — a node cannot be reparented under itself or a descendant (`MoveWouldCreateCycle`)
- Tree depth is bounded at `maxDictionaryDepth = 4` (root = level 1) for both add and move (`MaxDepthExceeded`)
- A non-empty group cannot be removed (`GroupNotEmpty`)

The nesting is *derived* from the flat `parentId` adjacency, never stored as nesting: read-model rows persist `parentId` as a column, and the API layer server-materialises the nested-tree DTO (`groupsSelectable` + recursive `roots`).

## Data Flow

### Command Flow (Write Path)

```
HTTP Request
    │
    ▼
┌─────────────────┐
│ Auth Middleware  │ ──── Extract UserId from JWT
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ API Handler     │ ──── Convert DTO → domain command
│ (Web layer)     │      Map DomainError → HTTP error
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Service         │ ──── Orchestrate use case:
│ (Application)   │      - Generate IDs
│                 │      - Check authorization
│                 │      - Execute command
│                 │      - Query read model
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Command Handler │ ──── Pure domain logic
└────────┬────────┘
         │
         ▼
    [Event list]
         │
         ▼
┌──────────────┐
│ Event Store  │ ──── Append to PostgreSQL
└──────────────┘
         │
         ▼
┌──────────────┐
│ Read Models  │ ──── Update projections
└──────────────┘
```

### Query Flow (Read Path)

```
HTTP Request
    │
    ▼
┌─────────────────┐
│ Auth Middleware  │ ──── Extract UserId from JWT
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ API Handler     │ ──── Convert domain result → DTO
│ (Web layer)     │      Map DomainError → HTTP error
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Service         │ ──── Orchestrate query:
│ (Application)   │      - Validate IDs
│                 │      - Check authorization
│                 │      - Query read model
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Read Model      │ ──── Query in-memory projection
└─────────────────┘
         │
         ▼
    JSON Response
```

### Transfer Saga (Process Manager)

The TransferManager process manager (saga) coordinates the full transfer flow.
Users only issue `InitiateTransfer`. All subsequent commands are issued internally by the saga.

```
User issues InitiateTransfer
         │
         ▼
┌───────────────────────────┐
│ TransferInitiated (event) │  ← Transaction aggregate
│ on transaction stream     │
└───────────┬───────────────┘
            │
            ▼  TransferManager stores transfer data
┌───────────────────────────┐
│ DebitAccount (command)    │  → Source Account aggregate
│ with TransactionId        │
└───────────┬───────────────┘
            │
      ┌─────┴──────────┐
      │                │
   Success           Failure
      │                │
      ▼                ▼
┌─────────────┐  ┌──────────────────────┐
│ AccountDeb- │  │ AccountDebitRejected  │
│ ited (event)│  │ (event)              │
└──────┬──────┘  └──────────┬───────────┘
       │                    │
       ▼                    ▼
┌─────────────────┐  ┌──────────────────┐
│ CreditAccount   │  │ FailTransfer     │
│ (→ target acct) │  │ (→ transaction)  │
│ + CompleteTransf│  └──────────────────┘
│ er (→ transact.)│         │
└────────┬────────┘         ▼
         │           ┌──────────────────┐
         ▼           │ TransferFailed   │
┌─────────────────┐  │ (terminal state) │
│ AccountCredited │  └──────────────────┘
│ (event)         │
└────────┬────────┘
         │
         ▼  TransferManager cleans up tracking
┌──────────────────────┐
│ TransferCompleted    │
│ (terminal state)     │
└──────────────────────┘
```

**Saga Event/Command Summary:**

| Step | Trigger Event | Saga Issues | Target |
|------|--------------|-------------|--------|
| 1 | `TransferInitiated` | `DebitAccount` | Source account |
| 2a | `AccountDebited` | `CreditAccount` + `CompleteTransfer` | Target account + Transaction |
| 2b | `AccountDebitRejected` | `FailTransfer` | Transaction |
| 3 | `AccountCredited` | *(cleanup only)* | — |

## Application Services

The Application Services layer sits between the Web handlers and the Domain layer. Services orchestrate use cases without knowing about HTTP concerns.

### Service Responsibilities

| Service | Responsibility |
|---------|---------------|
| `AccountService` | Account CRUD, sharing, access revocation. Accepts domain commands, returns `Either DomainError (AccountId, AccountSummaryData)` |
| `TransactionService` | Transfer initiation and status queries. Accepts domain commands, returns `Either DomainError (TransactionId, TransactionSummaryData)` |
| `AuthService` | Registration, login, OAuth, Telegram link-code issue/redeem, token refresh. Returns `Either DomainError AuthResult` |
| `UserService` | User profile queries, password change, OAuth/Telegram unlinking. Returns `Either DomainError (UserId, UserSummaryData)` or `Either DomainError ()` |
| `AuthorizationService` | Pure RBAC access control. No IO — evaluates permissions from data |
| `PromptService` | Backs `POST /api/prompt` — natural-language transaction creation. Parses free text via a free open-weights LLM through an OpenAI-compatible provider (`Infrastructure.Llm`), then routes the recognised intent through an extensible intent architecture (`Application.Services.Prompt.*`). Reuses `TransactionService` to execute the resulting command |

### Error Handling

Services return explicit `Either DomainError a` values. The Web layer maps these to HTTP responses:

```
Service returns Left DomainError
         │
         ▼
┌─────────────────────┐
│ Web.ErrorMapping    │
│ throwDomainError    │
└─────────┬───────────┘
          │
          ▼
DomainError constructor → HTTP status:
  ValidationErr  → 400 Bad Request
  NotFound       → 404 Not Found
  InsufficientFunds → 422 Unprocessable
  AccountError   → 400 Bad Request
  TransactionError → 400 Bad Request
```

### Web Handler Pattern

All API handlers follow a uniform pattern:

1. Extract data from HTTP request (path params, body, auth user)
2. Convert DTO to domain type (via `Web.Types` conversion functions)
3. Delegate to service (passing domain types only)
4. Convert domain result to response DTO
5. Map `Left DomainError` to HTTP error via `throwDomainError`

## Infrastructure Components

### Event Store (PostgreSQL + Eventium)

- Immutable append-only log
- Stream per aggregate (e.g., `account-{uuid}`)
- Optimistic concurrency via version numbers
- JSON event payloads, wrapped in a versioned envelope `{schemaVersion, payload}`

#### Schema evolution (upcast-on-read)

Stored events are **never rewritten**. When an event type's shape changes across
a release, older stored events are normalized to the current shape *on read* by a
chain of pure single-hop upcasters. The generic machinery lives in
`Eventium.SchemaEvolution` (envelope + `SchemaRegistry` + `upcastingValueCodec`);
the app supplies the concrete registry in `Infrastructure.Eventium.Schema`
(`accountingSchemaRegistry`, `accountingEventTypeOf`, `accountingEventCodec`).
See `docs/specs/2026-07-30-event-schema-evolution-design.md`.

A stored event's `FromJSON`/`ToJSON` describes **only the current shape** —
historical compatibility never lives in the instance (no `.:?`/`.!=`/`fromMaybe`
migration logic); it belongs in an upcaster. External/inbound JSON (API DTOs,
provider payloads) is the opposite case and keeps validating custom `FromJSON`
instances. See the *Upcaster vs. custom `FromJSON`* rule in `CLAUDE.md`.

**To evolve an event's schema** (add/rename/remove a field, split/merge):

1. Change the event type in `Domain.*` to its new (current) shape.
2. Add a single-hop upcaster `Value -> Value` transforming the *previous*
   stored JSON into the new shape, and register it under the event's tag in
   `accountingSchemaRegistry`:
   ```haskell
   registerUpcasters "TransactionAmendmentInitiated" [v1_to_v2, v2_to_v3] …
   ```
   The list is ordered `[v1→v2, v2→v3, …]`; its length sets the current version
   (`1 + length`). Append the new hop — never edit or reorder existing hops.
3. Remember the JSON shape: an `AccountingEvent` encodes as
   `{ "tag": …, "contents": { …fields… } }`, so a field-level upcaster
   transforms the `contents` object. Two worked examples:
   `amendmentInitiatedV1toV2` (default an added field) and
   `postingInitiatedV1toV2` (widen a scalar `externalTransactionId` string to the
   `externalTransactionIds` list — a rename alone is insufficient, the value must
   be wrapped in an array). Write each hop to be a **no-op when its marker is
   absent**, since all pre-envelope events read as v1 and every hop runs on them.
4. Add a legacy-decode test in `Infrastructure.Eventium.SchemaSpec`: commit a
   stored-JSON fixture under `test/fixtures/events/` (copyable verbatim from a prod
   event-store row — the pre-change shape), then assert it decodes via
   `accountingEventCodec` and that re-encoding + re-reading is stable.

Pre-envelope events (written before schema versioning existed) carry no
`schemaVersion` and are read as version 1 automatically.

### Read Models (In-Memory)

- `AccountSummary` - Current balances, access lists
- `TransactionSummary` - Transfer history
- `UserSummary` - User profiles, linked accounts
- `ExchangeRateReadModel` - Per-provider, per-day published rates;
  projected from `AccountingExchangeRatesPublishedEvent`, with the
  business date carried on `EventMetadata.occurredAt` (not on the
  outer global-stream metadata). Powers historical-rate lookups for
  backdated transactions and bank imports.
- Rebuilt from event stream on startup

### Transient Auth Stores

`Application.LinkCodeStore` is also an in-memory `TVar`, but it is **not** a read model — it is not a projection from events and is not rebuilt on startup. It holds short-lived (~10 min), single-use Telegram link codes used by the bot deep-link account-linking flow: `POST /auth/telegram/link-code` issues a token and stores `(UserId, expiresAt)`; the bot's `/start LINK_<token>` handler redeems it atomically and runs the `LinkTelegramAccount` aggregate command. This state is intentionally transient — too short-lived to event-source and too auth-specific to mix with read-model rebuild logic. Codes that are not redeemed simply expire and are evicted.

### Authentication

| Provider | Purpose |
|----------|---------|
| Password (Argon2) | Email/password login |
| JWT | Session tokens |
| OAuth2 | Google, GitHub, Microsoft |
| Telegram | Bot deep-link account linking (`POST /auth/telegram/link-code` issues a short-lived code; bot's `/start LINK_<token>` redeems it and runs `LinkTelegramAccount`) |

### Configuration

- YAML files per environment (`config/local.yaml`, `config/test.yaml`, `config/prod.yaml`)
- Environment variable substitution (`${VAR}`)
- Loaded via `Infrastructure.Config`

## Technology Stack

| Component | Technology |
|-----------|------------|
| Language | Haskell (GHC 9.6.7) |
| Application Monad | RIO (ReaderT IO) |
| Web Framework | Servant + Warp |
| Event Sourcing | Eventium |
| Database | PostgreSQL |
| Auth | jose (JWT), cryptonite (Argon2) |
| Telegram | telegram-bot-simple |
| Build | Cabal + Nix Flakes |
| Linting | HLint + Ormolu |

## Related

- [Mission Statement](./mission-statement.md)
- [Operational Context](./operational-context.md)
- [User Experience Specification](./user-experience-spec.md)
- [Account Backend Plan](./plans/2025-12-01-account-backend.md)
- [User Management Plan](./plans/2026-01-30-user-management.md)
- [API Services Refactoring Plan](./plans/2026-02-03-api-services-refactor.md)
- [Transfer Saga Implementation Plan](./plans/2026-02-11-transfer-saga-implementation.md)
