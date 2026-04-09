# Domain Naming Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify naming conventions across domain types: `source/target` for directionality, `type` for classification, and merge `TransferType`+`TransferCategory` into one type.

**Architecture:** All changes are breaking (no backwards-compatible JSON). Three rename/refactor streams applied bottom-up: core types → domain → application → web → tests. Generic `deriveJSON` used throughout — no custom JSON instances needed.

**Tech Stack:** Haskell, Aeson (JSON), Template Haskell (`deriveJSON`), Optics, Eventium

**Spec:** `docs/specs/2026-04-09-domain-naming-consistency-design.md`

---

## Task 1: Merge `TransferType` + `TransferCategory` → unified `TransferType`

Changes the core type definition. All downstream modules will break until updated.

**Files:**
- Modify: `src/Domain/Core/Types.hs:862-893` (type defs) and `:95-98` (exports)

- [ ] **Step 1: Replace `TransferType`, `TransferCategory`, and `validateTransferCategory`**

Replace lines 862-893 with:

```haskell
-- | Type of transfer operation.
--
-- Income and Expense carry a DictionaryEntryId referencing the user's
-- configured category. Transfer (internal) has no category.
data TransferType
  = Income DictionaryEntryId
  | Expense DictionaryEntryId
  | Transfer
  deriving (Show, Eq, Generic)

instance ToJSON TransferType

instance FromJSON TransferType
```

- [ ] **Step 2: Update exports**

Replace lines 95-98:
```haskell
    -- * Transfer Types
    TransferType (..),
```

Remove `TransferCategory (..)` and `validateTransferCategory`.

- [ ] **Step 3: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "refactor: merge TransferType and TransferCategory into unified TransferType"
```

---

## Task 2: Update Domain Transaction layer

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/Projection.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`

- [ ] **Step 1: Update `TransferInitiated` event**

In `Events.hs`, remove `category :: TransferCategory` field, keep `transferType :: TransferType`. Keep `deriveJSON defaultOptions ''TransferInitiated`. Remove `TransferCategory` from imports.

- [ ] **Step 2: Update `InitiateTransfer` command**

In `Commands.hs`, remove `category :: TransferCategory` field, keep `transferType :: TransferType`. Remove `TransferCategory` from imports.

- [ ] **Step 3: Update `Transaction` projection**

In `Projection.hs`:
- Remove `category :: TransferCategory` from `Transaction` record
- Update `transactionDefault`: replace `transferType = Income, category = IncomeCat (unsafeDictionaryEntryId nil)` → `transferType = Income (unsafeDictionaryEntryId nil)`
- Update event handler: remove `& #category .~ evt.category`
- Remove `TransferCategory (..)` from imports

- [ ] **Step 4: Update `CommandHandler`**

In `CommandHandler.hs`:
- Remove `validateTransferCategory` import
- Remove `TransferCategoryMismatch` from `TransactionError`
- Remove the `validateTransferCategory` check block (lines 128-130), simplify to go directly from amount validation to event construction
- Remove `category = category` from event construction

- [ ] **Step 5: Build domain**

Run: `cabal build 2>&1 | head -50`

Expected: Domain compiles, downstream errors expected.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Transaction/
git commit -m "refactor: update domain transaction types for unified TransferType"
```

---

## Task 3: Update Application layer for `TransferType` merge

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Modify: `src/Application/Services/TransactionService.hs`

- [ ] **Step 1: Update `TransactionData` read model**

In `ReadModels/Transaction.hs`:
- Remove `category :: TransferCategory` from `TransactionData`
- Remove `category = evt.category` from event handler
- Remove `TransferCategory` from imports

- [ ] **Step 2: Update `TransactionService`**

In `TransactionService.hs`:
- `initiateIncome`: replace `transferType = Income, category = IncomeCat categoryEntryId` → `transferType = Income categoryEntryId`
- `initiateExpense`: replace `transferType = Expense, category = ExpenseCat categoryEntryId` → `transferType = Expense categoryEntryId`
- `initiateInternalTransfer`: replace `transferType = InternalTransfer, category = InternalCat` → `transferType = Transfer`
- Remove `TransferCategory (..)` from imports

- [ ] **Step 3: Commit**

```bash
git add src/Application/
git commit -m "refactor: update application layer for unified TransferType"
```

---

## Task 4: Update Web + Telegram layers for `TransferType` merge

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Telegram/Commands.hs`

- [ ] **Step 1: Update `TransactionResponse` DTO**

Change `category :: Text` → `category :: Maybe Text`.

- [ ] **Step 2: Update serialization helpers**

Replace `transferTypeToText` and `transferCategoryToText` with:

```haskell
transferTypeToText :: TransferType -> Text
transferTypeToText (Income _) = "income"
transferTypeToText (Expense _) = "expense"
transferTypeToText Transfer = "transfer"

transferTypeCategoryText :: TransferType -> Maybe Text
transferTypeCategoryText (Income entryId) = Just $ T.pack $ UUID.toString $ unDictionaryEntryId entryId
transferTypeCategoryText (Expense entryId) = Just $ T.pack $ UUID.toString $ unDictionaryEntryId entryId
transferTypeCategoryText Transfer = Nothing
```

- [ ] **Step 3: Update conversion functions**

In `fromTransactionData` and `fromTransaction`: `category = transferTypeCategoryText transferType`.

- [ ] **Step 4: Update `toInitiateTransferCommand`**

Replace `transferType = InternalTransfer, category = InternalCat` → `transferType = Transfer`.

- [ ] **Step 5: Remove stale imports**

Remove `TransferCategory (..)`, `InternalCat`, `InternalTransfer` references.

- [ ] **Step 6: Update Telegram module**

In `src/Telegram/Commands.hs`, update `TransferCategory`/`InternalTransfer` → unified type.

- [ ] **Step 7: Build source**

Run: `cabal build 2>&1 | head -50`

- [ ] **Step 8: Commit**

```bash
git add src/Web/ src/Telegram/
git commit -m "refactor: update web and telegram layers for unified TransferType"
```

---

## Task 5: Rename `fromAccountId`/`toAccountId` → `sourceAccountId`/`targetAccountId`

All layers at once — straightforward find-and-replace since no backwards compat needed.

**Files:**
- Modify: `src/Domain/Transaction/Events.hs` — record fields
- Modify: `src/Domain/Transaction/Commands.hs` — record fields
- Modify: `src/Domain/Transaction/Projection.hs` — record fields, `transactionDefault`, event handler optics (`#fromAccountId` → `#sourceAccountId`)
- Modify: `src/Domain/Transaction/CommandHandler.hs` — RecordWildCards bindings, guard, event construction
- Modify: `src/Application/ReadModels/Transaction.hs` — `TransactionData` record + event handler
- Modify: `src/Application/ProcessManagers/TransferManager.hs` — `evt.fromAccountId` → `evt.sourceAccountId`
- Modify: `src/Application/Services/TransactionService.hs` — `InitiateTransfer` record literals
- Modify: `src/Web/Types.hs` — `TransferRequest`, `InternalTransferRequest`, `TransactionResponse`, conversion functions, doc comments
- Modify: `src/Web/API/TransactionAPI.hs` — `request.fromAccountId` → `request.sourceAccountId`, validation error field names
- Modify: `scripts/api-test/payloads/transactions/*.json` — JSON key names
- Modify: `scripts/api-test/test-transactions.sh` — JSON payloads in shell script
- Modify: `scripts/api-test/test-full-workflow.sh` — JSON payloads in shell script
- Modify: `scripts/api-test/test-telegram.sh` — JSON payloads in shell script
- Modify: `scripts/api-test/quick-test.sh` — JSON payloads in shell script
- Modify: `scripts/api-test/README.md` — example JSON
- Modify: `scripts/api-test/CURL_REFERENCE.md` — example JSON

- [ ] **Step 1: Rename in all source files**

In every file above, replace `fromAccountId` → `sourceAccountId` and `toAccountId` → `targetAccountId` in field definitions, record construction, field access, optics labels, JSON keys, shell scripts, and documentation.

- [ ] **Step 2: Build source**

Run: `cabal build 2>&1 | head -50`

- [ ] **Step 3: Commit**

```bash
git add src/ scripts/
git commit -m "refactor: rename fromAccountId/toAccountId to sourceAccountId/targetAccountId"
```

---

## Task 6: Rename `AccountKind` → `AccountType`, `kind` → `accountType`

All layers at once.

**Files:**
- Modify: `src/Domain/Core/Types.hs` — type name (`AccountKind` → `AccountType`), export list
- Modify: `src/Domain/Account/Events.hs` — `kind :: AccountKind` → `accountType :: AccountType`, import
- Modify: `src/Domain/Account/Commands.hs` — same field rename, import
- Modify: `src/Domain/Account/Projection.hs` — `Account` record field, optics `#kind` → `#accountType`, import
- Modify: `src/Domain/Account/CommandHandler.hs` — import, pattern matches on `kind`/`accountType`, optics
- Modify: `src/Application/ReadModels/Account.hs` — `AccountData` record field, event handler `evt.kind` → `evt.accountType`
- Modify: `src/Application/Services/AccountService.hs` — import
- Modify: `src/Application/Services/TransactionService.hs` — import, field accesses
- Modify: `src/Application/Services/AuthorizationService.hs` — `AccountAuthData` record, field accesses
- Modify: `src/Application/Services/AuthService.hs` — import, `kind = External` → `accountType = External`
- Modify: `src/Web/Types.hs` — import, `fromAccountData` pattern match on `kind` → `accountType`
- Modify: `src/Telegram/Commands.hs` — import, `kind = Regular defaultCash` → `accountType = Regular defaultCash`

- [ ] **Step 1: Rename type in Core Types**

`data AccountKind` → `data AccountType`. Update `ToJSON`/`FromJSON` instance names. Update export.

- [ ] **Step 2: Rename field and import in all files above**

`kind` → `accountType` in record definitions, construction, field access, optics labels. `AccountKind` → `AccountType` in imports and type annotations.

- [ ] **Step 3: Build source**

Run: `cabal build 2>&1 | head -50`

- [ ] **Step 4: Commit**

```bash
git add src/
git commit -m "refactor: rename AccountKind to AccountType, kind to accountType"
```

---

## Task 7: Update all tests

**Files:**
- Delete: `test/Domain/Core/TransferCategoryPropertySpec.hs`
- Modify: `test/Testkit/Generators.hs`
- Modify: `test/Domain/Transaction/CommandHandlerSpec.hs`
- Modify: `test/Domain/Transaction/CommandHandlerPropertySpec.hs`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs`
- Modify: `test/Application/Services/TransactionServiceSpec.hs`
- Modify: `test/Application/Services/AuthorizationServiceSpec.hs`
- Modify: `test/Application/ProcessManagers/TransferManagerSpec.hs`
- Modify: `test/Application/ProcessManagers/TransferManagerPropertySpec.hs`
- Modify: `test/Integration/TransferWorkflowSpec.hs`
- Modify: `test/Integration/WebAPISpec.hs`

- [ ] **Step 1: Delete `TransferCategoryPropertySpec.hs`**

```bash
rm test/Domain/Core/TransferCategoryPropertySpec.hs
```

- [ ] **Step 2: Update `Testkit/Generators.hs`**

- Remove `genTransferCategory`, `Arbitrary TransferCategory`
- Update `genTransferType`:
  ```haskell
  genTransferType :: Gen TransferType
  genTransferType =
    oneof
      [ Income <$> genDictionaryEntryId,
        Expense <$> genDictionaryEntryId,
        pure Transfer
      ]
  ```
- Rename `Arbitrary AccountKind` → `Arbitrary AccountType`
- Remove `TransferCategory` imports, `AccountKind` → `AccountType`

- [ ] **Step 3: Update all test files**

Apply across all test files listed above:
- `fromAccountId` → `sourceAccountId`, `toAccountId` → `targetAccountId`
- `transferType = InternalTransfer, category = InternalCat` → `transferType = Transfer`
- `transferType = Income, category = IncomeCat x` → `transferType = Income x`
- `transferType = Expense, category = ExpenseCat x` → `transferType = Expense x`
- `AccountKind` → `AccountType`, `kind` → `accountType`
- Remove `TransferCategoryMismatch` test cases
- Remove `TransferCategory` imports
- JSON keys in `WebAPISpec.hs`: `"fromAccountId"` → `"sourceAccountId"`, `"toAccountId"` → `"targetAccountId"`
- `"category"` field assertions: update for `null` values where `Transfer` type is used

- [ ] **Step 4: Build and run tests**

```bash
cabal build --enable-tests 2>&1 | head -80
cabal test --test-show-details=direct
```

Expected: All tests compile and pass.

- [ ] **Step 5: Commit**

```bash
git add test/
git commit -m "test: update all tests for domain naming consistency refactoring"
```

---

## Task 8: Final checks

- [ ] **Step 1: Format and lint**

```bash
just format && just lint
```

- [ ] **Step 2: Run full test suite**

```bash
just test
```

- [ ] **Step 3: Fix issues if any, commit**

```bash
git add src/ test/
git commit -m "style: format and lint fixes for naming consistency refactoring"
```

- [ ] **Step 4: Update spec status**

Change `status: in-progress` → `status: completed` in `docs/specs/2026-04-09-domain-naming-consistency-design.md`.

```bash
git add docs/
git commit -m "docs: mark domain naming consistency spec as completed"
```
