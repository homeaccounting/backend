---
status: completed
date: 2026-04-09
---

# Domain Naming Consistency

## Problem

Several naming inconsistencies exist across domain types:

1. **Directional prefixes**: `fromAccountId`/`toAccountId` use `from/to` while `sourceAmount`/`targetAmount` and `ExchangeRate` use `source/target`
2. **Classification naming**: Accounts use `kind` (`AccountKind`) while transfers use `transferType` (`TransferType`) — no consistent convention
3. **Redundant type/category**: `TransferType` and `TransferCategory` encode the same information — `TransferType` is fully derivable from `TransferCategory`

## Changes

### 1. Standardise on `source/target` prefix convention

Rename all transfer-related account references:

- `fromAccountId` → `sourceAccountId`
- `toAccountId` → `targetAccountId`

This aligns with the existing `sourceAmount`/`targetAmount` and `ExchangeRate.source`/`ExchangeRate.target` conventions. The `TransferManager` already uses `sourceAccount`/`targetAccount` internally.

**Affected types:**

| Layer | Type | Fields renamed |
|-------|------|---------------|
| Domain | `InitiateTransfer` (command) | `fromAccountId`, `toAccountId` |
| Domain | `TransferInitiated` (event) | `fromAccountId`, `toAccountId` |
| Domain | `TransactionCommandHandler` | field accesses on commands/events |
| Domain | `Transaction` (projection) | `fromAccountId`, `toAccountId` |
| Application | `TransactionData` (read model) | `fromAccountId`, `toAccountId` |
| Application | `TransferManager` (process manager) | `evt.fromAccountId`, `evt.toAccountId` field accesses |
| Web | `TransferRequest` (DTO) | `fromAccountId`, `toAccountId` |
| Web | `InternalTransferRequest` (DTO) | `fromAccountId`, `toAccountId` |
| Web | `TransactionResponse` (DTO) | `fromAccountId`, `toAccountId` |
| Web | `TransactionAPI` handlers | field accesses on request DTOs |
| Scripts | `scripts/api-test/payloads/transactions/` | JSON key names in payload files |

**JSON keys** change from `fromAccountId`/`toAccountId` to `sourceAccountId`/`targetAccountId` (breaking API change).

### 2. Standardise on `type` naming, rename `AccountKind` → `AccountType`

Rename across all layers:

- Type: `AccountKind` → `AccountType`
- Field name: `kind` → `accountType`
- Constructors: unchanged (`Regular`, `External`)

**Affected types:**

| Layer | Type | Field renamed |
|-------|------|--------------|
| Domain | `AccountCreated` (event) | `kind` → `accountType` |
| Domain | `CreateAccount` (command) | `kind` → `accountType` |
| Domain | `Account` (projection) | `kind` → `accountType` |
| Application | `AccountData` (read model) | `kind` → `accountType` |
| Application | `AccountAuthData` | `kind` → `accountType` |
| Application | `AuthorizationService` | field accesses on `AccountAuthData.kind` |
| Application | `AuthService` | default account creation uses `kind` |
| Telegram | `Telegram.Commands` | imports `AccountKind`, default account creation |

**JSON key** changes from `kind` to `accountType` in `AccountCreated` event serialization (requires backwards-compatible `FromJSON`).

### 3. Merge `TransferType` and `TransferCategory` into unified `TransferType`

**Before:**

```haskell
data TransferType
  = Income
  | Expense
  | InternalTransfer

data TransferCategory
  = IncomeCat DictionaryEntryId
  | ExpenseCat DictionaryEntryId
  | InternalCat
```

**After:**

```haskell
data TransferType
  = Income DictionaryEntryId
  | Expense DictionaryEntryId
  | Transfer
```

The single `transferType` field replaces both `transferType` and `category` in all record types. Note: the `InternalTransfer` constructor is renamed to `Transfer`.

**Eliminated:**

- `TransferCategory` type and all constructors (`IncomeCat`, `ExpenseCat`, `InternalCat`)
- `validateTransferCategory` function (validation is now structural)
- `TransferCategoryMismatch` error variant
- `TransferCategoryPropertySpec.hs` test file
- `genTransferCategory` generator and `Arbitrary TransferCategory` instance

**Affected types (field changes):**

| Layer | Type | Change |
|-------|------|--------|
| Domain | `InitiateTransfer` | Remove `transferType` + `category`, add `transferType :: TransferType` |
| Domain | `TransferInitiated` | Remove `transferType` + `category`, add `transferType :: TransferType` |
| Domain | `Transaction` | Remove `transferType` + `category`, add `transferType :: TransferType` |
| Application | `TransactionData` | Remove `transferType` + `category`, add `transferType :: TransferType` |

**Service layer changes:**

- `initiateIncome`: constructs `Income categoryEntryId` instead of separate `transferType = Income` + `category = IncomeCat categoryEntryId`
- `initiateExpense`: constructs `Expense categoryEntryId` instead of separate fields
- `initiateInternalTransfer`: constructs `Transfer` instead of separate fields

**API serialization:**

- `transferTypeToText`: `Income _ → "income"`, `Expense _ → "expense"`, `Transfer → "transfer"`
- `transferCategoryToText` removed; category UUID extracted directly from `TransferType` constructors
- `TransactionResponse` keeps both `transferType` (text) and `category` (UUID or `null`) fields for API consumers. `Transfer` returns `null` for category.

**Generator:**

```haskell
genTransferType :: Gen TransferType
genTransferType =
  oneof
    [ Income <$> genDictionaryEntryId
    , Expense <$> genDictionaryEntryId
    , pure Transfer
    ]
```

## Event Store Impact

All changes are breaking. No backwards-compatible JSON deserialization is provided. Existing persisted events with the old JSON shape will not deserialize with the new types. The event store must be recreated or migrated separately if needed. Generic `deriveJSON` is used for all types — no custom JSON instances required.

## Test Impact

All three changes require updates across test files. Key files affected:

- `test/Testkit/Generators.hs` — update `genTransferType`, remove `genTransferCategory`, update `Arbitrary` instances
- `test/Domain/Core/TransferCategoryPropertySpec.hs` — **delete** (no longer needed)
- `test/Domain/Transaction/CommandHandlerSpec.hs` — field renames + type changes
- `test/Domain/Transaction/CommandHandlerPropertySpec.hs` — field renames + type changes
- `test/Domain/Account/CommandHandlerPropertySpec.hs` — `AccountKind` → `AccountType`, `kind` → `accountType`
- `test/Application/Services/TransactionServiceSpec.hs` — field renames + type changes
- `test/Application/Services/AuthorizationServiceSpec.hs` — `AccountKind` → `AccountType`
- `test/Application/ProcessManagers/TransferManagerSpec.hs` — all three changes
- `test/Application/ProcessManagers/TransferManagerPropertySpec.hs` — all three changes
- `test/Integration/TransferWorkflowSpec.hs` — all three changes
- `test/Integration/WebAPISpec.hs` — JSON key renames in payloads

## API Breaking Changes

All changes are breaking for API consumers:

- `fromAccountId` → `sourceAccountId` in request/response JSON
- `toAccountId` → `targetAccountId` in request/response JSON
- `kind` → `accountType` in account-related JSON (if exposed)
- `category` field in `TransactionResponse` remains but is now derived from `transferType`
