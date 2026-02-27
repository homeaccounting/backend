---
status: done
created: 2025-12-01
author: cursor-ai
reviewed-by: oleksandrsy
---

# Accounting Backend Implementation Plan

## Overview
Implementation plan for the personal accounting backend service using Domain-Driven Design with CQRS and Event-Sourcing patterns in Haskell. This system enables personal finance tracking with account management and money transfers.

## Architecture Summary

### Design Patterns
- **Domain-Driven Design (DDD)** - Ubiquitous language, aggregates, value objects
- **CQRS** - Separate command and query models
- **Event Sourcing** - All state changes stored as immutable events
- **Hexagonal Architecture** - Clear layer separation with ports and adapters

### Technology Stack
- **Language**: Haskell (GHC 9.6.7)
- **Application Monad**: `rio` (ReaderT IO pattern with batteries included)
- **Event Sourcing**: `eventium` library (from `./lib/eventium`)
- **Web Framework**: `servant` + `warp`
- **Database**: PostgreSQL (event store via `eventium-postgresql`)
- **Persistence**: `persistent` + `persistent-postgresql`
- **Development**: Nix flake, `hlint`, `ormolu`
- **Configuration**: YAML-based configuration with environment variable substitution
- **Logging**: Structured logging via RIO's `LogFunc`

## Target Project Structure

```
accounting/
├── src/
│   ├── Domain/
│   │   ├── Account/
│   │   │   ├── Errors.hs           -- Account-specific errors
│   │   │   ├── Commands.hs         -- Account commands (CreateAccount, etc.)
│   │   │   ├── CommandHandler.hs   -- Account command handler
│   │   │   ├── Events.hs           -- Account events (AccountCreated, etc.)
│   │   │   └── Aggregate.hs        -- Account aggregate projection
│   │   ├── Account.hs              -- Re-exports from Account/*
│   │   ├── Transaction/
│   │   │   ├── Errors.hs           -- Transaction-specific errors
│   │   │   ├── Commands.hs         -- Transaction commands (TransferMoney, etc.)
│   │   │   ├── CommandHandler.hs   -- Transaction command handler
│   │   │   ├── Events.hs           -- Transaction events (MoneyTransferred, etc.)
│   │   │   └── Aggregate.hs        -- Transaction aggregate projection
│   │   ├── Transaction.hs          -- Re-exports from Transaction/*
│   │   ├── Core/
│   │   │   ├── Errors.hs           -- Core domain errors
│   │   │   └── Types.hs            -- Core types (Money, AccountId, etc.)
│   │   └── Core.hs                 -- Re-exports from Core/*
│   │   
│   │
│   ├── Application/
│   │   ├── ProcessManagers/
│   │   │   └── TransferManager.hs  -- Saga for money transfers
│   │   ├── ProcessManagers.hs      -- Re-exports from ProcessManagers/*
│   │   ├── ReadModels/
│   │   │   └── AccountSummary.hs   -- Query projection for account summaries
│   │   └── ReadModels.hs           -- Re-exports from ReadModels/*
│   │
│   ├── Infrastructure/
│   │   ├── Eventium.hs             -- Eventium wiring and serializers
│   │   ├── Config.hs               -- Configuration loading (YAML)
│   │   └── Database.hs             -- PostgreSQL connection setup
│   │
│   ├── Web/
│   │   ├── API/
│   │   │   ├── AccountAPI.hs       -- Account REST endpoints
│   │   │   └── TransactionAPI.hs   -- Transaction REST endpoints
│   │   ├── API.hs                  -- Re-exports from API/*
│   │   ├── Types.hs                -- Request/Response DTOs
│   │   └── Server.hs               -- Warp server setup
│   │
│   └── Main.hs                     -- Composition root
│
├── test/
│   ├── Domain/
│   │   ├── Account/
│   │   │   └── AccountSpec.hs      -- Account aggregate unit tests
│   │   └── Transaction/
│   │       └── TransactionSpec.hs  -- Transaction aggregate unit tests
│   └── Web/
│       └── IntegrationSpec.hs      -- REST API integration tests
│
├── config/
│   ├── test.yaml                   -- Test / CI configuration
│   ├── local.yaml                  -- Local configuration
│   └── prod.yaml                   -- Production configuration
│
├── database/
│   ├── schema.sql                  -- Event store schema
│   └── migrations/                 -- Database migrations
│
├── docker-compose.yaml             -- Development database
├── accounts.cabal                  -- Cabal configuration
├── flake.nix                       -- Nix flake for dev environment
└── README.md
```

---

## Implementation Phases

### Current Status

**Completed Phases**:
- ✅ Phase 2: Account Domain (Complete)
- ✅ Phase 3: Transaction Domain (Complete)
- ✅ Phase 4: Domain Integration (Complete)
- ✅ Phase 5: Infrastructure Layer (Complete)
- ✅ Phase 6: Web Layer (Complete)
- ✅ Phase 7: Application Composition with RIO (Complete)

**In Progress**:
- None (all core phases complete!)

**Pending**:
- ⏸️ Phase 1: Foundation Setup (not started)
- ⏸️ Phase 8: Testing & Documentation (waiting for Phase 6)

---

### Phase 1: Foundation Setup
**Goal**: Establish project infrastructure and core types

#### Task 1.1: Configure Build System
- **Status**: Pending
- **Dependencies**: None
- **Deliverables**:
  - Update `accounts.cabal` with eventium dependencies
  - Create `flake.nix` for Nix development environment
  - Create `docker-compose.yaml` for PostgreSQL

#### Task 1.2: Implement Core Domain Types
- **Status**: Pending
- **Dependencies**: Task 1.1
- **Deliverables**:
  - `Domain/Core/Types.hs`:
    - `Money` newtype with validation (non-negative)
    - `AccountId` newtype wrapper around UUID
    - `TransactionId` newtype wrapper around UUID
    - Smart constructors with validation
  - `Domain/Core/Errors.hs`:
    - `DomainError` sum type
    - `ValidationError` type
  - `Domain/Core.hs` (at same level as `Core/` folder):
    - Re-export all Core submodules using `module X` pattern

#### Task 1.3: Setup Configuration Infrastructure
- **Status**: Pending  
- **Dependencies**: Task 1.1
- **Deliverables**:
  - `Infrastructure/Config.hs`:
    - YAML configuration loading
    - `AppConfig` data type (db settings, server port, etc.)
  - `config/local.yaml`, `config/test.yaml`, `config/prod.yaml`

---

### Phase 2: Account Domain ✅ COMPLETE
**Goal**: Complete Account aggregate with eventium patterns

#### Task 2.1: Define Account Events
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Domain/Account/Events.hs`:
    - `AccountCreated` event
    - `AccountCredited` event  
    - `AccountDebited` event
    - `AccountDebitRejected` event
    - `accountEvents` list for Template Haskell
    - JSON derivations
  - `Infrastructure/Json.hs`:
    - `deriveJSONUnPrefixLower` helper
    - JSON serialization utilities

#### Task 2.2: Define Account Commands
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Domain/Account/Commands.hs`:
    - `CreateAccount` command
    - `CreditAccount` command
    - `DebitAccount` command
    - `accountCommands` list for Template Haskell
    - JSON derivations

#### Task 2.3: Implement Account Projection
- **Status**: ✅ Complete
- **Dependencies**: Task 2.1
- **Deliverables**:
  - `Domain/Account/Projection.hs`:
    - `Account` aggregate state
    - `AccountEvent` sum type (via Template Haskell)
    - `accountProjection :: Projection Account AccountEvent`
    - Event handlers for state transitions
    - Lens accessors
    - `accountDefault` helper function

#### Task 2.4: Implement Account Command Handler
- **Status**: ✅ Complete
- **Dependencies**: Tasks 2.2, 2.3
- **Deliverables**:
  - `Domain/Account/CommandHandler.hs`:
    - `AccountCommand` sum type (via Template Haskell)
    - `handleAccountCommand :: Account -> AccountCommand -> [AccountEvent]`
    - `accountCommandHandler :: CommandHandler Account AccountEvent AccountCommand`
    - Business rule enforcement (no negative balance, etc.)

#### Task 2.5: Define Account Errors
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Domain/Account/Errors.hs`:
    - `AccountError` sum type
    - `InsufficientFunds`
    - `AccountNotFound`
    - `AccountAlreadyExists`
    - `InvalidAccountName` (bonus)
    - Smart constructors for all errors

#### Task 2.6: Create Account Module Re-exports
- **Status**: ✅ Complete
- **Dependencies**: Tasks 2.1-2.5
- **Deliverables**:
  - `Domain/Account.hs` (at same level as `Account/` folder):
    - Re-export all Account submodules using `module X` pattern:
      ```haskell
      module Domain.Account (module X) where
      import Domain.Account.Commands as X
      import Domain.Account.CommandHandler as X
      import Domain.Account.Errors as X
      import Domain.Account.Events as X
      import Domain.Account.Projection as X
      ```

---

### Phase 3: Transaction Domain (Transfer Saga) ✅ COMPLETE
**Goal**: Implement money transfer between accounts using a process manager

#### Task 3.1: Define Transaction Events
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Domain/Transaction/Events.hs`:
    - `TransferInitiated` event
    - `TransferCompleted` event
    - `TransferFailed` event
    - `transactionEvents` list
    - JSON derivations

#### Task 3.2: Define Transaction Commands
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Domain/Transaction/Commands.hs`:
    - `InitiateTransfer` command
    - `CompleteTransfer` command
    - `FailTransfer` command
    - `transactionCommands` list
    - JSON derivations

#### Task 3.3: Implement Transaction Projection
- **Status**: ✅ Complete
- **Dependencies**: Task 3.1
- **Deliverables**:
  - `Domain/Transaction/Projection.hs`:
    - `Transaction` aggregate state (source, target, amount, status)
    - `TransactionEvent` sum type
    - `transactionProjection :: Projection Transaction TransactionEvent`
    - Event handlers

#### Task 3.4: Implement Transaction Command Handler
- **Status**: ✅ Complete
- **Dependencies**: Tasks 3.2, 3.3
- **Deliverables**:
  - `Domain/Transaction/CommandHandler.hs`:
    - `TransactionCommand` sum type
    - `handleTransactionCommand`
    - `transactionCommandHandler`

#### Task 3.5: Define Transaction Errors
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Domain/Transaction/Errors.hs`:
    - `TransactionError` sum type
    - `SourceAccountNotFound`
    - `TargetAccountNotFound`
    - `TransferFailed`

#### Task 3.6: Create Transaction Module Re-exports
- **Status**: ✅ Complete
- **Dependencies**: Tasks 3.1-3.5
- **Deliverables**:
  - `Domain/Transaction.hs` (at same level as `Transaction/` folder):
    - Re-export all Transaction submodules using `module X` pattern:
      ```haskell
      module Domain.Transaction (module X) where
      import Domain.Transaction.Commands as X
      import Domain.Transaction.CommandHandler as X
      import Domain.Transaction.Errors as X
      import Domain.Transaction.Events as X
      import Domain.Transaction.Projection as X
      ```

---

### Phase 4: Domain Integration ✅ COMPLETE
**Goal**: Integrate Account and Transaction domains for cross-aggregate operations

#### Task 4.1: Create Domain Models Module
- **Status**: ✅ Complete
- **Dependencies**: Tasks 2.6, 3.6
- **Deliverables**:
  - `Domain/Models.hs`:
    - Re-export Account and Transaction modules
    - `AccountingEvent` unified sum type (for all domain events)
    - `AccountingCommand` unified sum type (for all domain commands)
    - Event serializers for eventium

#### Task 4.2: Implement Transfer Process Manager
- **Status**: ✅ Complete
- **Dependencies**: Task 4.1
- **Deliverables**:
  - `Application/ProcessManagers/TransferManager.hs`:
    - `TransferManager` state type
    - `TransferManagerTransferData` tracking type
    - `transferManagerProjection`
    - Process manager that:
      1. Listens for `TransferInitiated`
      2. Issues `DebitAccount` command to source
      3. On success, issues `CreditAccount` to target
      4. On failure, compensates and emits `TransferFailed`
    - `transferProcessManager :: ProcessManager`

---

### Phase 5: Infrastructure Layer ✅ COMPLETE
**Goal**: Implement persistence and eventium wiring

#### Task 5.1: Setup Eventium Integration
- **Status**: ✅ Complete
- **Dependencies**: Task 4.1
- **Deliverables**:
  - `Infrastructure/Eventium.hs`:
    - Event serializers using eventium's `constructSerializer`
    - Command handler registry
    - Process manager registry
    - Store type aliases

#### Task 5.2: Implement Database Infrastructure
- **Status**: ✅ Complete
- **Dependencies**: Task 1.3
- **Deliverables**:
  - `Infrastructure/Database.hs`:
    - PostgreSQL connection pool creation
    - Event store initialization
    - Database migration runner
  - `database/schema.sql`:
    - Event store tables (following eventium-postgresql schema)
    - Read model tables (if needed)

#### Task 5.3: Create Read Models
- **Status**: ✅ Complete
- **Dependencies**: Task 4.1
- **Deliverables**:
  - `Application/ReadModels/AccountSummary.hs`:
    - `AccountSummary` read model type
    - `accountSummaryProjection`
    - Query functions for account lookup

---

### Phase 6: Web Layer ✅ COMPLETE
**Goal**: Implement REST API with Servant

#### Task 6.1: Define Web Types
- **Status**: ✅ Complete
- **Dependencies**: Task 1.2
- **Deliverables**:
  - `Web/Types.hs`:
    - Request DTOs (`CreateAccountRequest`, `TransferRequest`, etc.)
    - Response DTOs (`AccountResponse`, `TransactionResponse`, etc.)
    - JSON instances
    - OpenAPI schema derivations (optional, for future)

#### Task 6.2: Implement Account API
- **Status**: ✅ Complete
- **Dependencies**: Tasks 5.1, 6.1
- **Deliverables**:
  - `Web/API/AccountAPI.hs`:
    - `AccountAPI` type-level API definition
    - Endpoints:
      - `POST /api/accounts` - Create account
      - `GET /api/accounts/:id` - Get account by ID
      - `GET /api/accounts` - List all accounts
      - `POST /api/accounts/:id/credit` - Credit account
      - `POST /api/accounts/:id/debit` - Debit account
    - Server implementation using AppM monad
    - Complete error handling and logging

#### Task 6.3: Implement Transaction API
- **Status**: ✅ Complete
- **Dependencies**: Tasks 5.1, 6.1
- **Deliverables**:
  - `Web/API/TransactionAPI.hs`:
    - `TransactionAPI` type-level API definition
    - Endpoints:
      - `POST /api/transactions` - Create transaction (transfer)
      - `GET /api/transactions/:id` - Get transaction status
    - Server implementation using AppM monad
    - Event replay for transaction loading
    - Saga integration with TransferManager
    - Complete error handling and logging

#### Task 6.4: Implement Server Composition
- **Status**: ✅ Complete
- **Dependencies**: Tasks 6.2, 6.3
- **Deliverables**:
  - `Web/API.hs`:
    - Combined `API` type (AccountAPI :<|> TransactionAPI)
    - Combined `server` implementation
    - Re-exports of individual APIs
  - `Web/Server.hs`:
    - `runServer` function with Warp
    - CORS middleware
    - Logging middleware (request/response)
    - Error handling middleware
    - Compression middleware (gzip)
    - Natural transformation (AppM → Handler)
    - Server settings configuration
  - `Main.hs`:
    - Integrated web server startup
    - Updated logging for Phase 6 completion

---

### Phase 7: Application Composition ✅ COMPLETE
**Goal**: Wire everything together in Main.hs using RIO

#### Task 7.1: Implement Composition Root
- **Status**: ✅ Complete
- **Dependencies**: Tasks 5.2, 6.4 (Note: Web server integration ready for Phase 6)
- **Deliverables**:
  - `Infrastructure/App.hs`:
    - RIO-based application environment (AppEnv)
    - Application monad (AppM = RIO AppEnv)
    - Type classes for resource access (HasDbPool, HasEventStore, etc.)
    - Resource management helpers (runDb)
  - `Main.hs`:
    - Configuration loading
    - Database connection initialization
    - Event store setup (eventium-postgresql)
    - Process manager subscription
    - Read model initialization
    - Graceful startup with structured logging
    - Placeholder for web server (Phase 6)
  - `package.yaml`:
    - Added RIO and UnliftIO dependencies

---

### Phase 8: Testing & Documentation
**Goal**: Comprehensive test coverage and API documentation

#### Task 8.1: Domain Unit Tests
- **Status**: Pending
- **Dependencies**: Tasks 2.4, 3.4
- **Deliverables**:
  - `test/Domain/Account/AccountSpec.hs`:
    - Command handler tests
    - Projection tests
    - Business rule validation tests
  - `test/Domain/Transaction/TransactionSpec.hs`:
    - Transfer saga tests
    - Compensation tests

#### Task 8.2: Integration Tests
- **Status**: Pending
- **Dependencies**: Task 6.4
- **Deliverables**:
  - `test/Web/IntegrationSpec.hs`:
    - End-to-end API tests
    - Database integration tests
    - Event sourcing round-trip tests

#### Task 8.3: Generate OpenAPI Specification
- **Status**: Pending
- **Dependencies**: Task 6.4
- **Deliverables**:
  - OpenAPI 3.0 specification generation
  - API documentation

---

## Eventium Pattern Reference

### Event Definition Pattern
```haskell
-- Domain/Account/Events.hs
{-# LANGUAGE TemplateHaskell #-}

module Domain.Account.Events where

import Domain.Core.Types (Money, AccountId)
import Infrastructure.Json (deriveJSONUnPrefixLower)
import Language.Haskell.TH (Name)

accountEvents :: [Name]
accountEvents =
  [ ''AccountCreated
  , ''AccountCredited
  , ''AccountDebited
  ]

data AccountCreated = AccountCreated
  { accountCreatedName :: Text
  , accountCreatedInitialBalance :: Money
  }
  deriving (Show, Eq)

deriveJSONUnPrefixLower ''AccountCreated
```

### Command Handler Pattern
```haskell
-- Domain/Account/CommandHandler.hs
{-# LANGUAGE TemplateHaskell #-}

module Domain.Account.CommandHandler where

import Domain.Account.Commands
import Domain.Account.Events
import Domain.Account.Projection
import Eventium
import SumTypesX.TH

constructSumType "AccountCommand" defaultSumTypeOptions accountCommands

handleAccountCommand :: Account -> AccountCommand -> [AccountEvent]
handleAccountCommand account (CreateAccountAccountCommand cmd) = 
  -- Business logic here
  [AccountCreatedAccountEvent $ AccountCreated ...]

accountCommandHandler :: CommandHandler Account AccountEvent AccountCommand
accountCommandHandler = CommandHandler handleAccountCommand accountProjection
```

### Projection Pattern
```haskell
-- Domain/Account/Projection.hs
{-# LANGUAGE TemplateHaskell #-}

module Domain.Account.Projection where

import Domain.Account.Events
import Eventium
import SumTypesX.TH

data Account = Account
  { _accountBalance :: Money
  , _accountName :: Text
  }

makeLenses ''Account

constructSumType "AccountEvent" defaultSumTypeOptions accountEvents

handleAccountEvent :: Account -> AccountEvent -> Account
handleAccountEvent account (AccountCreatedAccountEvent e) = ...

accountProjection :: Projection Account AccountEvent
accountProjection = Projection accountDefault handleAccountEvent
```

### Process Manager Pattern
```haskell
-- Application/ProcessManagers/TransferManager.hs
module Application.ProcessManagers.TransferManager where

import Domain.Models
import Eventium

data TransferManager = TransferManager
  { _transferManagerPendingCommands :: [ProcessManagerCommand AccountingEvent AccountingCommand]
  , _transferManagerPendingEvents :: [StreamEvent UUID () AccountingEvent]
  }

transferProcessManager :: ProcessManager TransferManager AccountingEvent AccountingCommand
transferProcessManager = ProcessManager
  transferManagerProjection
  (view transferManagerPendingCommands)
  (view transferManagerPendingEvents)
```

---

## Technical Requirements Checklist

### Code Quality
- [ ] All code formatted with `ormolu`
- [ ] All code passes `hlint` checks
- [ ] GHC warnings enabled and resolved
- [ ] No partial functions
- [ ] Smart constructors for domain types

### Architecture
- [ ] Clear layer separation (Domain → Application → Infrastructure → Web)
- [ ] No circular dependencies
- [ ] Domain layer has no IO
- [ ] Event sourcing for all state changes

### Testing
- [ ] Unit tests on domain aggregates
- [ ] Integration tests via REST API
- [ ] Property-based tests for business rules

### Infrastructure
- [ ] PostgreSQL for event storage
- [ ] Docker Compose for local development
- [ ] YAML configuration
- [ ] Nix flake for reproducible builds

---




## Implementation Strategy

1. **Bottom-up approach**: Start with core types, then domain events/commands, then handlers
2. **Eventium-first**: Follow eventium library patterns exactly as demonstrated in bank example
3. **Incremental validation**: Each phase produces runnable/testable code
4. **Domain purity**: Keep business logic pure, push effects to boundaries
5. **RIO-based application monad**: Use RIO for resource management, logging, and effects
6. **Test alongside implementation**: Write tests as features are completed

## RIO Application Pattern

The application uses RIO (ReaderT IO pattern) for the application monad, providing:

### AppEnv - Application Environment
```haskell
data AppEnv = AppEnv
  { appLogFunc :: !LogFunc                              -- Structured logging
  , appConfig :: !AppConfig                             -- Configuration
  , appDbPool :: !ConnectionPool                        -- Database
  , appEventStoreWriter :: !(AccountingVersionedEventStoreWriter IO)
  , appEventStoreReader :: !(AccountingVersionedEventStoreReader IO)
  , appGlobalEventStoreReader :: !(AccountingGlobalEventStoreReader IO)
  , appAccountSummaryReadModel :: !(TVar AccountSummaryReadModel)
  }

type AppM = RIO AppEnv
```

### Type Classes for Resource Access
```haskell
class HasDbPool env where
  dbPoolL :: Lens' env ConnectionPool

class HasEventStore env where
  eventStoreWriterL :: Lens' env (AccountingVersionedEventStoreWriter IO)
  eventStoreReaderL :: Lens' env (AccountingVersionedEventStoreReader IO)

class HasReadModel env where
  accountSummaryReadModelL :: Lens' env (TVar AccountSummaryReadModel)
```

### Benefits
- **Structured Logging**: Built-in LogFunc with proper formatting
- **Resource Safety**: UnliftIO for safe resource management
- **Reader Pattern**: Implicit environment passing
- **Type-Safe Dependencies**: Functions declare what they need via type classes
- **Testability**: Easy to mock resources via custom environments
- **Servant Integration**: UnliftIO enables easy Handler conversion

## Next Steps

1. **Start with Task 1.1** - Setup build system and dependencies
2. Work through tasks following dependency order
3. Reference `lib/eventium/examples/bank/` for implementation patterns
4. Use eventium-memory for initial testing, switch to eventium-postgresql for production
5. Validate each phase before proceeding

---

## Application Architecture (As Implemented)

The current architecture integrates all completed phases:

```
┌─────────────────────────────────────────────────────────────┐
│                        Main.hs                               │
│  - Load configuration (YAML + env vars)                      │
│  - Setup RIO logging (LogFunc)                               │
│  - Initialize AppEnv with all resources                      │
│  - Run application in RIO monad                              │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ↓
┌─────────────────────────────────────────────────────────────┐
│              Infrastructure/App.hs (RIO)                     │
│  - AppEnv: All runtime dependencies                          │
│  - AppM: RIO AppEnv (application monad)                      │
│  - Type classes: Resource access patterns                    │
└──────────────────────────┬──────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ↓                  ↓                  ↓
┌──────────────┐  ┌─────────────────┐  ┌─────────────────┐
│Infrastructure│  │  Application    │  │    Domain       │
│- Config      │  │  - ReadModels   │  │  - Account      │
│- Database    │  │  - Process      │  │  - Transaction  │
│- Eventium    │  │    Managers     │  │  - Core         │
│              │  │                 │  │                 │
│✅ Complete   │  │  ✅ Complete    │  │  ✅ Complete    │
└──────────────┘  └─────────────────┘  └─────────────────┘

Pending Integration:
┌─────────────────┐
│   Web Layer     │
│  - AccountAPI   │  ← Next: Task 6.2
│  - TransactionAPI│ ← Next: Task 6.3
│  - Server       │  ← Next: Task 6.4
│                 │
│⏳ Partial (6.1) │
└─────────────────┘
```

### Current Capabilities

**Working Infrastructure**:
- ✅ Database connection pooling (PostgreSQL)
- ✅ Event store (eventium-postgresql)
- ✅ Command handlers (Account + Transaction)
- ✅ Read models (AccountSummary in-memory)
- ✅ Process managers (TransferManager saga)
- ✅ Structured logging (RIO LogFunc)
- ✅ Configuration management (YAML + env)

**Ready for Web Layer**:
- ✅ AppM monad for all handlers
- ✅ Resource access via type classes
- ✅ DTOs defined (Web/Types.hs)
- ✅ Conversion functions (DTO ↔ Domain)
- ✅ Error types defined

**Next Implementation**: Phase 6 Tasks 6.2-6.4 (Servant API handlers and server)

---

## Related

- PRD: [docs/prompts/PRD.md](../prompts/PRD.md)
- Documentation Rule: [.cursor/rules/documentation-management.mdc](../../.cursor/rules/documentation-management.mdc)

## References

- Eventium Library: `./lib/eventium/`
- Bank Example: `./lib/eventium/examples/bank/`
- Eventium Core: `./lib/eventium/eventium-core/`
- Eventium PostgreSQL: `./lib/eventium/eventium-postgresql/`
- RIO Library: https://hackage.haskell.org/package/rio
