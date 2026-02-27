# Operational Context

**Level 1 Document: This document defines the fundamental operational constraints and context within which the entire system operates. All architectural decisions, implementation choices, and operational procedures must align with this context.**

## 1. Core Operational Model

### 1.1 State Management

The system has two sources of persistent state:

1. **PostgreSQL Event Store** — The authoritative source of truth
   - Stores all domain events (AccountCreated, AccountCredited, AccountDebited, TransferInitiated, etc.)
   - Immutable append-only log
   - Managed via `eventium-postgresql`

2. **In-Memory Read Models** — Derived projections for queries
   - `AccountSummary` — Current account balances and metadata
   - Rebuilt from event stream on startup
   - Transient; can be reconstructed at any time

All other state is transient and exists only within a single request execution.

### 1.2 Execution Environment

- **Single-user operation** — Personal finance tracking for one individual
- **Server deployment** — Runs as a backend service (Warp HTTP server)
- **Local development** — Docker Compose for PostgreSQL, Nix flake for toolchain
- **Concurrency model** — Multi-threaded request handling, single-writer event store
- **Process lifecycle** — Continuous operation as a service
- **Persistence** — Event store is durable; read models are transient

### 1.3 Operational Cadence

- **User-initiated operations** — All state changes triggered by REST API calls
- **Synchronous command handling** — Commands processed and events persisted before response
- **Asynchronous projections** — Read models updated after event persistence
- **Process manager orchestration** — Transfer saga coordinates multi-aggregate operations

## 2. State Management Model

### 2.1 Persisted State

1. **Event Store (PostgreSQL)**
   - Account events: `AccountCreated`, `AccountCredited`, `AccountDebited`, `AccountDebitRejected`
   - Transaction events: `TransferInitiated`, `TransferCompleted`, `TransferFailed`
   - Stored with stream ID, version, timestamp, and JSON payload
   - Atomicity guaranteed by database transactions

2. **Configuration (YAML files)**
   - Database connection settings
   - Server port and host
   - Logging configuration
   - Environment-specific overrides (dev, local, prod)

### 2.2 Component State Machines

1. **Account Aggregate**

   ```
   ∅ → [CreateAccount] → Created
   Created → [CreditAccount] → Created (balance increased)
   Created → [DebitAccount] → Created (balance decreased) | DebitRejected (insufficient funds)
   ```

2. **Transaction Aggregate**

   ```
   ∅ → [InitiateTransfer] → Initiated
   Initiated → [CompleteTransfer] → Completed
   Initiated → [FailTransfer] → Failed
   ```

3. **State Machine Properties**
   - Pure functions transforming immutable states
   - Type-safe transitions via Haskell ADTs
   - Validation at aggregate boundaries
   - No partial state updates

### 2.3 State Machine Usage

```math
command: (Aggregate × Command) → [Event]
projection: (Aggregate × Event) → Aggregate
```

Commands produce events; events update aggregate state through projections.

## 3. System Boundaries

### 3.1 What The System Is

1. **A personal accounting backend** that:
   - Creates and manages financial accounts
   - Tracks account balances through credits and debits
   - Executes money transfers between accounts
   - Maintains complete audit history via event sourcing

2. **A CQRS/ES implementation** that:
   - Separates command and query responsibilities
   - Stores all state changes as immutable events
   - Provides eventual consistency between write and read models
   - Enables full state reconstruction from event history

3. **A REST API service** that:
   - Exposes account management endpoints
   - Exposes transfer execution endpoints
   - Returns JSON responses following REST conventions
   - Provides structured error responses

### 3.2 What The System Is Not

1. **Not a multi-user system**
   - No authentication or authorization
   - No user management
   - No access control between accounts

2. **Not a banking system**
   - No real money integration
   - No external payment processing
   - No regulatory compliance features
   - No interest calculations

3. **Not a frontend application**
   - No web UI
   - No mobile app
   - API-only interface

## 4. Implementation Implications

### 4.1 Architectural Requirements

1. Components must:
   - Maintain clear layer separation (Domain → Application → Infrastructure → Web)
   - Keep domain logic pure (no IO in Domain layer)
   - Express all errors explicitly in types
   - Use smart constructors for domain types (Money, AccountId, etc.)

2. Components must not:
   - Allow negative account balances
   - Permit partial transfers (debit without credit)
   - Store derived state as source of truth
   - Use exceptions for control flow

### 4.2 Operational Requirements

1. All operations must:
   - Be traceable to explicit events
   - Maintain aggregate invariants
   - Return meaningful error responses
   - Log significant actions via structured logging
   - Be idempotent where possible (using command IDs)

2. All operations must not:
   - Mutate state without producing events
   - Bypass aggregate command handlers
   - Access database directly from domain layer
   - Silently fail or swallow errors

## 5. Verification Requirements

Every architectural decision, implementation choice, and operational procedure must be verified against this context:

1. **State Management**
   - Does this change persist state outside the event store?
   - Is the event store still the single source of truth?
   - Can this state be reconstructed from events?

2. **Execution Model**
   - Does this fit the single-user, server-based model?
   - Is concurrency handled correctly?
   - Are effects properly bounded?

3. **Operational Simplicity**
   - Does this add unnecessary complexity?
   - Can this be tested in isolation?
   - Does this maintain layer boundaries?

## 6. Cross-Reference Requirements

All other system documentation must:

1. Reference this document when describing operational context
2. Maintain consistency with these constraints
3. Avoid duplicating these definitions

## 7. Evolution Requirements

Any proposed changes to this operational context must:

1. Demonstrate clear necessity
2. Preserve system integrity (especially event store as source of truth)
3. Maintain operational simplicity
4. Update all dependent documentation

---

## Related

- [Mission Statement](./mission-statement.md)
- [User Experience Specification](./user-experience-spec.md)
- [Implementation Plan](./plans/2025-12-01-account-backend.md)
