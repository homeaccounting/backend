---
status: completed
created: 2026-02-11
author: cursor-ai
reviewed-by: pending
---

# Transfer Saga Implementation Plan

## Overview

Implement the full transfer saga (process manager) for coordinating money transfers between accounts using the debit → credit → complete flow with failure compensation. This replaces the simplified "immediate complete" model with a proper double-entry accounting saga that enforces balance invariants at the Account aggregate level.

## Problem Statement

The original implementation used a simplified `TransferManager` that immediately issued `CompleteTransfer` upon receiving `TransferInitiated`, bypassing balance validation entirely. The `docs/architecture.md` described a full debit/credit saga, but the code did not implement it.

**Key confusion**: The `docs/plans/2026-01-30-user-management.md` stated "Remove standalone credit/debit operations" without clarifying that this applied only to the **user-facing API**, not to internal saga operations.

## Design Decision

**"Transfer-only" applies to the user-facing API.** Users only issue `InitiateTransfer`. Internally, the TransferManager process manager (saga) coordinates `DebitAccount` → `CreditAccount` → `CompleteTransfer` commands on Account aggregates to implement double-entry accounting with proper failure compensation.

### Event/Command Replacement

Replaced the single `AccountBalanceUpdated` event with three granular events for saga correlation:

| Old | New | Purpose |
|-----|-----|---------|
| `AccountBalanceUpdated` | `AccountDebited` | Source account balance decreased (carries `TransactionId`) |
| — | `AccountCredited` | Target account balance increased (carries `TransactionId`) |
| — | `AccountDebitRejected` | Debit failed, triggers compensation (carries `TransactionId` + reason) |

Added two internal commands to Account aggregate:

| Command | Purpose |
|---------|---------|
| `DebitAccount` | Issued by saga to debit source account |
| `CreditAccount` | Issued by saga to credit target account |

## Saga Flow

### Successful Transfer

```
1. TransferInitiated → Store transfer data, issue DebitAccount to source
2. AccountDebited    → Issue CreditAccount to target + CompleteTransfer to transaction
3. AccountCredited   → Clean up transfer tracking (saga complete)
```

### Failed Transfer (Insufficient Funds)

```
1. TransferInitiated     → Store transfer data, issue DebitAccount to source
2. AccountDebitRejected  → Issue FailTransfer with reason, remove from tracking
```

### Business Rules

- **RegularAccount**: `DebitAccount` checks `subtractMoney` — rejects if insufficient funds
- **ExternalAccount**: `DebitAccount` always succeeds (external accounts can go negative)
- **CreditAccount**: Always succeeds for both account types
- **Idempotency**: Duplicate `TransferInitiated` for same transaction ID is ignored
- **Correlation**: All saga events carry `TransactionId` for matching

## Changes Made

### Domain Layer

| File | Change |
|------|--------|
| `Domain/Account/Events.hs` | Replaced `AccountBalanceUpdated` with `AccountDebited`, `AccountCredited`, `AccountDebitRejected` |
| `Domain/Account/Commands.hs` | Added `DebitAccount`, `CreditAccount` commands |
| `Domain/Account/CommandHandler.hs` | Added handlers for `DebitAccount` (with balance validation) and `CreditAccount` |
| `Domain/Account/Projection.hs` | Updated to handle new events instead of `AccountBalanceUpdated` |
| `Domain/Account.hs` | Updated exports |
| `Domain/Models.hs` | TH auto-generates unified types (no manual change needed) |

### Application Layer

| File | Change |
|------|--------|
| `Application/ProcessManagers/TransferManager.hs` | Full saga implementation with debit → credit → complete flow |
| `Application/ReadModels/AccountSummary.hs` | Handle `AccountDebited`/`AccountCredited` instead of `AccountBalanceUpdated` |

### Infrastructure Layer

| File | Change |
|------|--------|
| `Infrastructure/Eventium.hs` | Exported `transferManagerEventHandler` for test integration |

### Test Support

| File | Change |
|------|--------|
| `TestSupport/InMemoryEventStore.hs` | Added `createTestAppEnvWithProcessManager` for PM-enabled test environments |

### Tests

| File | Coverage |
|------|----------|
| `TransferManagerSpec.hs` | Unit tests: all saga transitions (initiate, debit success, debit failure, credit, unrelated events, idempotency) |
| `TransferManagerPropertySpec.hs` | Property tests: determinism, idempotency, state invariants (completed/failed removal, correct targeting) |
| `TransferWorkflowSpec.hs` | Integration tests: end-to-end saga with PM, balance updates, external account negative balance, insufficient funds rejection, multiple sequential transfers |

### Documentation

| File | Change |
|------|--------|
| `docs/architecture.md` | Updated Account Aggregate commands/events, detailed Transfer Saga diagram with event/command table |
| `docs/plans/2026-01-30-user-management.md` | Clarified Phase 2 & Phase 3: internal saga commands/events are kept, only user-facing API endpoints removed |

## Test Results

All tests pass: **236 examples, 0 failures, 1 pending** (the 1 pending is unrelated OAuth test).

Key test coverage:
- 17 unit tests for saga state transitions
- 7 property tests (100 samples each) for determinism, idempotency, and invariants
- 5 integration tests for full end-to-end saga behavior with PM-enabled environment

## Related

- [Architecture](../architecture.md) — Transfer Saga section
- [User Management Plan](./2026-01-30-user-management.md) — Phase 2 & Phase 3
- [Account Backend Plan](./2025-12-01-account-backend.md)
