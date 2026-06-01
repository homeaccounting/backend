---
status: draft
date: 2026-05-30
spec: ../specs/2026-05-30-transaction-allocations-design.md
issue: homeaccounting/backend#89
---

# Transaction Allocations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single `CategoryId` embedded in `TransferType.Income` / `TransferType.Expense` with `NonEmpty Allocation`, enabling multi-category splits on a single transaction while leaving account-side debit/credit machinery untouched.

**Architecture:** A new `Allocation = (CategoryId, Money)` value type lives next to `TransferType` in `Domain.Core.Types`. `TransferType.Income` and `TransferType.Expense` carry `NonEmpty Allocation`; `Transfer` and `Adjustment` stay nullary. Smart constructors enforce sum-equals-total, amount > 0, and currency consistency. `ChangeTransactionCategory` is replaced by `SetTransactionAllocations` (taking `newAllocations :: NonEmpty Allocation`). `AmendTransfer` keeps master's lean shape — it does NOT carry allocations; when the categorised amount changes via amendment, the **command handler** rescales existing allocations proportionally (exact `Rational`) and emits the scaled allocations as a new field `newAllocations :: Maybe (NonEmpty Allocation)` on the `TransferAmendmentCompleted` event. Projections / read models apply the field via `replaceAllocations` on the existing kind. No event upcaster — DB is recreated at deploy.

> **Amendment-surface rollback note (2026-05-30):** An earlier iteration of this plan extended `AmendTransfer` / `CompleteTransferAmendment` / `TransferAmendment{Initiated,Completed}` with `newTransferType :: TransferType` as a user-amendable field. That was reverted: amendment is posting-facts only as far as the **command** surface is concerned, and kind is structurally preserved by `AccountType` invariants.
>
> **Refinement (2026-05-30, post-master rebase):** the *event* `TransferAmendmentCompleted` gains a handler-computed snapshot of the post-amendment allocations (not a command field). The command handler arm for `CompleteTransferAmendment` rescales allocations once and emits the result; projections / read models just apply it. This avoids each event consumer redoing the rescale derivation. The `AmendTransfer` and `CompleteTransferAmendment` commands stay lean.
>
> **Tightening (2026-05-31):** the three derivative surfaces — `SetTransactionAllocations` command, `TransactionAllocationsChanged` event, and `TransferAmendmentCompleted` event — were tightened from carrying a full `TransferType` to carrying only the changing allocations (`NonEmpty Allocation` / `Maybe (NonEmpty Allocation)`). Kind cannot change in any of these events; a small helper `replaceAllocations :: NonEmpty Allocation -> TransferType -> TransferType` reconstructs the full `TransferType` at the projection from existing state. Initial registration (`TransferInitiated` / `InitiateTransfer`) still carries the full `TransferType` — at initiation the kind IS being set.

**Tech Stack:** GHC 9.10.3, Cabal, Eventium, Servant, RIO. All commands via `just` (run inside `nix develop`).

**Reference spec:** [`docs/specs/2026-05-30-transaction-allocations-design.md`](../specs/2026-05-30-transaction-allocations-design.md). Every task references the spec section that defines the contract — read before coding.

**Reference implementations:**
- The transfer-amendment-saga plan ([`docs/plans/2026-05-23-transfer-amendment-saga.md`](2026-05-23-transfer-amendment-saga.md), merged in PR #83) for: how `TransferAmendment{Initiated,Completed}` events carry payloads through the saga; how the amendment service threads through `AmendTransfer`.
- The delete-transaction plan ([`docs/plans/2026-05-29-delete-transaction.md`](2026-05-29-delete-transaction.md), merged in PR #87) for: command/event addition style; typed `DomainError` extension pattern.
- `Domain.Core.Types.Money` for the smart-constructor + LiquidHaskell refinement pattern (`measure` + `reflect`).

---

## File Inventory

**New files:**
- `test/Domain/Core/AllocationPropertySpec.hs`
- `test/Domain/Core/TransferTypePropertySpec.hs`
- `test/Domain/Transaction/AllocationsSpec.hs`
- `test/Application/Services/TransactionAllocationsIntegrationSpec.hs`

**Modified files (Domain):**
- `src/Domain/Core/Types.hs` — add `Allocation`, `TransferKind`, rewrite `TransferType`, smart constructors, accessors, LH refinements
- `src/Domain/Core/Errors.hs` — add new variants, remove `CannotChangeCategoryOnUncategorizedTransaction`
- `src/Domain/Transaction/Commands.hs` — rename `ChangeTransactionCategory` → `SetTransactionAllocations { newAllocations :: NonEmpty Allocation }`. `AmendTransfer` / `CompleteTransferAmendment` match master verbatim (no allocations).
- `src/Domain/Transaction/Events.hs` — rename `TransactionCategoryChanged` → `TransactionAllocationsChanged { newAllocations :: NonEmpty Allocation }`. `TransferAmendmentInitiated` matches master verbatim. `TransferAmendmentCompleted` gains one new field, `newAllocations :: Maybe (NonEmpty Allocation)` (handler-computed snapshot; `Nothing` for `Transfer` / `Adjustment`).
- `src/Domain/Transaction/CommandHandler.hs` — invariants on `InitiateTransfer` (allocation sum/currency/positivity). `AmendTransfer` arm matches master (no kind-preservation or allocation checks — kind preservation is structural via `AccountType`). Replace category-change arm with allocations-change arm.
- `src/Domain/Transaction/Projection.hs` — rewrite default state; on the new `TransactionAllocationsChanged` arm, apply `evt.newAllocations` via `replaceAllocations` on the existing `transferType`; on `TransferAmendmentCompleted`, apply `evt.newAllocations` via `replaceAllocations` when `Just` (the rescale is performed by the command handler, not the projection).

**Modified files (Application):**
- `src/Application/Services/TransactionService.hs` — replace `changeTransactionCategory` with `setTransactionAllocations :: ... -> NonEmpty Allocation -> AppM (...)`; widen `initiateIncome` / `initiateExpense` to take `NonEmpty Allocation`; update `pickCategoryDict`. `amendTransfer` matches master verbatim (no allocations plumbing).
- `src/Application/Services/TransactionHistoryService.hs` — rename history variant `HistoryCategoryChanged` → `HistoryAllocationsChanged`
- `src/Application/Services/BankImportService.hs` — build length-1 `NonEmpty Allocation` at the import boundary
- `src/Application/ReadModels/Transaction.hs` — replace `TransactionCategoryChangedEvent` arm with the new `TransactionAllocationsChangedEvent` arm applying `evt.newAllocations` via `replaceAllocations`; on `TransferAmendmentCompleted`, apply `evt.newAllocations` via `replaceAllocations` when `Just` (no rescale logic); update `findReferencingTransactions` to walk allocations.

**Modified files (Process Manager):**
- `src/Application/ProcessManagers/TransferAmendmentManager.hs` — saga state matches master verbatim (no `newTransferType`); allocations are not on the amendment surface.

**Modified files (Web):**
- `src/Web/Types.hs` — replace `ChangeTransactionCategoryRequest` with `SetTransactionAllocationsRequest`; update `transferTypeToText` / `transferTypeCategoryText` helpers (the latter likely deleted or rewritten)
- `src/Web/API/TransactionAPI.hs` — replace `PATCH /transactions/{id}/category` with `PATCH /transactions/{id}/allocations`; update body handling
- `src/Web/ErrorMapping.hs` — add new validation-error mappings; remove `CannotChangeCategoryOnUncategorizedTransaction`

**Modified files (Telegram):**
- `src/Telegram/Commands.hs` — wherever it constructs `Income` / `Expense`, build a length-1 `NonEmpty Allocation`

**Modified files (Tests — sweep):**
- `test/Domain/Transaction/LabelsAndCategorySpec.hs` — rename `ChangeTransactionCategory` ↦ `SetTransactionAllocations`, update event expectations
- `test/Domain/Transaction/LabelsProjectionSpec.hs` — same
- `test/Application/ReadModels/TransactionListSpec.hs` — same
- `test/Application/ReadModels/TransactionListPropertySpec.hs` — same
- `test/Web/API/TransactionAPISpec.hs` — new endpoint paths and DTO shape
- `test/Web/API/TransactionCategoryAPISpec.hs` — **rename** to `TransactionAllocationsAPISpec.hs`; rewrite to exercise `PATCH /transactions/{id}/allocations` instead of `…/category`. Old file deleted; new file replaces.
- `test/Testkit/Generators.hs` — `Arbitrary TransferType` / `Allocation` generators
- `test/Testkit/Helpers.hs` — mock constructors for `Allocation`, `TransferType`

**Modified files (Build):**
- `package.yaml` — bump `version: 0.3.0` → `0.4.0` (breaking domain change)

---

## Task Ordering

Bottom-up: value types → domain commands/events → handler → projection → service → read model → web → telegram. Cross-cutting test edits sit alongside their layer.

Standing rules (apply to every commit):
- Run `just check` (ormolu + hlint) before committing.
- Run `just build` after every code change.
- Run `just test` after every test addition.
- Commits use Conventional Commits (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`).
- Each task is one PR-sized commit unless explicitly split.

---

## Task 1: `Allocation` value type + property tests

**Spec:** §1 (Domain types) — paragraph on `Allocation`, paragraph on duplicates allowed.

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Create: `test/Domain/Core/AllocationPropertySpec.hs`

- [ ] **Step 1: Define `Allocation`**

In `src/Domain/Core/Types.hs`, add next to `TransferType` (around line 920, before `data TransferType`):

```haskell
-- | A single category slice of a transaction's categorised amount.
--
-- An 'Allocation' associates a portion of a transaction's total amount
-- with a category. Allocations are the building blocks of multi-category
-- splits: a 1000 UAH grocery purchase that is 200 UAH food and 800 UAH
-- housekeeping has two Allocations summing to 1000 UAH.
--
-- Invariants (enforced by the smart constructors of 'TransferType' that
-- wrap allocation lists):
--
--   * amount > 0 (strict positivity)
--   * all allocations on one transaction share a 'Currency'
--   * sum of amounts equals the categorised total of the transaction
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: Money
  }
  deriving (Show, Eq, Generic)

instance ToJSON Allocation

instance FromJSON Allocation
```

Export `Allocation (..)` from the module (data + selectors — this is a transparent value type unlike `Money`).

- [ ] **Step 2: Write the failing property test**

Create `test/Domain/Core/AllocationPropertySpec.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Domain.Core.AllocationPropertySpec
-- Description : Property tests for the Allocation value type
module Domain.Core.AllocationPropertySpec (spec) where

import Data.Aeson (decode, encode)
import Domain.Core.Types (Allocation (..))
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Testkit.Generators ()

spec :: Spec
spec = describe "Allocation" $ do
  prop "JSON roundtrip" $ \(alloc :: Allocation) ->
    decode (encode alloc) == Just alloc
```

- [ ] **Step 3: Add `Arbitrary Allocation` to `test/Testkit/Generators.hs`**

```haskell
instance Arbitrary Allocation where
  arbitrary = Allocation <$> arbitrary <*> arbitrary
```

- [ ] **Step 4: Run tests**

```
just build
just test --test-option='--match' --test-option='Domain.Core.Allocation'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add src/Domain/Core/Types.hs test/Domain/Core/AllocationPropertySpec.hs test/Testkit/Generators.hs
git commit -m "feat(domain): add Allocation value type"
```

---

## Task 2: Rewrite `TransferType` with allocations + smart constructors

**Spec:** §1 (Domain types) — `TransferType` shape, smart constructors, invariants table.

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Create: `test/Domain/Core/TransferTypePropertySpec.hs`
- Modify: `test/Testkit/Generators.hs`, `test/Testkit/Helpers.hs`

- [ ] **Step 1: Rewrite `TransferType`**

Replace the existing definition (`data TransferType = Income CategoryId | Expense CategoryId | Transfer | Adjustment`) with:

```haskell
-- | A non-empty list of allocations — the categorised side of an
-- Income/Expense transaction.
type Allocations = NonEmpty Allocation

-- | Type of transfer operation.
--
-- 'Income' and 'Expense' carry one or more 'Allocation's whose amounts
-- sum to the transaction's categorised total. The constructors are
-- /not/ exported — construct via 'mkIncome' / 'mkExpense'.
--
-- 'Transfer' (internal account-to-account) and 'Adjustment' (balance
-- reconciliation) have no category side.
data TransferType
  = Income     Allocations
  | Expense    Allocations
  | Transfer
  | Adjustment
  deriving (Show, Eq, Generic)

instance ToJSON TransferType

instance FromJSON TransferType
```

Update the module export list:

- Export the type `TransferType` (no data constructors).
- Export `Transfer` and `Adjustment` (nullary — safe to expose by name).
- Export `mkIncome`, `mkExpense`.
- Export `allocationsOf`, `categorisedAmount`, `isCategorised`.
- Export `TransferKind (..)`, `kindOf`.

- [ ] **Step 2: Add `TransferKind` and `kindOf`**

```haskell
-- | The kind of a 'TransferType', ignoring its payload. Used by command
-- handlers to enforce kind-preservation across edits.
data TransferKind = IncomeKind | ExpenseKind | TransferKind | AdjustmentKind
  deriving (Show, Eq, Generic)

kindOf :: TransferType -> TransferKind
kindOf (Income _)  = IncomeKind
kindOf (Expense _) = ExpenseKind
kindOf Transfer    = TransferKind
kindOf Adjustment  = AdjustmentKind
```

- [ ] **Step 3: Add accessors**

```haskell
-- | The allocations on a categorised 'TransferType', 'Nothing' otherwise.
allocationsOf :: TransferType -> Maybe Allocations
allocationsOf (Income  xs) = Just xs
allocationsOf (Expense xs) = Just xs
allocationsOf Transfer     = Nothing
allocationsOf Adjustment   = Nothing

-- | Sum of allocation amounts (= categorised total) where defined.
--   Uses 'sumAllocationsUnchecked' (defined in Step 4 below) — safe here
--   because allocations inside a 'TransferType' have already passed
--   the smart-constructor currency check at construction time.
categorisedAmount :: TransferType -> Maybe Money
categorisedAmount = fmap sumAllocationsUnchecked . allocationsOf

-- | True for Income / Expense; False for Transfer / Adjustment.
isCategorised :: TransferType -> Bool
isCategorised = isJust . allocationsOf
```

- [ ] **Step 4: Add smart constructors and validation helpers**

`Money` is `{ amount :: Rational, currency :: Currency }` — that's the actual field name; `m.amount` is the rational, `m.currency` is the currency. `addMoney :: Money -> Money -> Either Text Money` already checks currency. To compute the trusted sum inside the smart constructor *after* currency equality has been established, use a small unchecked helper that folds the underlying `Rational`s — that sidesteps `addMoney`'s `Either`:

```haskell
-- | Sum of allocation amounts, assuming all share a currency.
-- The caller must validate currency equality first (see 'validateAllocations').
-- We fold the underlying 'Rational' so the helper is total.
sumAllocationsUnchecked :: Allocations -> Money
sumAllocationsUnchecked xs =
  Money
    (sum (fmap (\a -> a.amount.amount) xs))
    (NE.head xs).amount.currency
```

Smart constructors return `Either DomainError TransferType`. Validation uses `ValidationErr (mkValidationError ...)` to wrap into `DomainError`. Each check uses an explicit guard returning `Left` — no `for_/unless` interleaving (those discard `Left`s):

```haskell
-- | Construct an Income TransferType.
--
-- The categorised amount is the transaction's target-side amount
-- (the side credited by the income). The allocations must:
--   * be non-empty (enforced by the NonEmpty type)
--   * each have @amount > 0@
--   * all share the same Currency as @categorisedAmount@
--   * sum to @categorisedAmount@
mkIncome :: Money -> Allocations -> Either DomainError TransferType
mkIncome categorisedAmount allocs = do
  validateAllocations categorisedAmount allocs
  pure (Income allocs)

-- | Construct an Expense TransferType.
--
-- The categorised amount is the transaction's source-side amount
-- (the side debited by the expense). Same invariants as 'mkIncome'.
mkExpense :: Money -> Allocations -> Either DomainError TransferType
mkExpense categorisedAmount allocs = do
  validateAllocations categorisedAmount allocs
  pure (Expense allocs)

validateAllocations ::
  Money ->
  Allocations ->
  Either DomainError ()
validateAllocations expectedTotal allocs =
  checkPositive *> checkCurrency *> checkSum
  where
    expectedCurrency :: Currency
    expectedCurrency = expectedTotal.currency

    checkPositive :: Either DomainError ()
    checkPositive = case NE.filter (\a -> a.amount.amount <= 0) allocs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError
            "amount"
            "Allocation amount must be positive"
            (T.pack (show bad.amount.amount))

    checkCurrency :: Either DomainError ()
    checkCurrency =
      case NE.filter (\a -> a.amount.currency /= expectedCurrency) allocs of
        [] -> Right ()
        (bad : _) ->
          Left . ValidationErr $
            mkValidationError
              "currency"
              "All allocations must share the categorised currency"
              (T.pack (show bad.amount.currency))

    checkSum :: Either DomainError ()
    checkSum =
      let s = sumAllocationsUnchecked allocs
       in if s == expectedTotal
            then Right ()
            else
              Left . ValidationErr $
                mkValidationError
                  "allocations"
                  "Sum of allocations must equal categorised amount"
                  (T.pack (show s.amount))
```

`ValidationErr` is the `DomainError` constructor that wraps a `ValidationError`. `mkValidationError` and the `ValidationError` type live in `Domain.Core.Errors`. Import them. `NE` is `Data.List.NonEmpty`.

- [ ] **Step 5: Write failing property tests**

`test/Domain/Core/TransferTypePropertySpec.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}

module Domain.Core.TransferTypePropertySpec (spec) where

import Domain.Core.Types
import qualified Data.List.NonEmpty as NE
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (counterexample, (===))
import Testkit.Generators ()

spec :: Spec
spec = describe "TransferType" $ do
  describe "mkIncome / mkExpense" $ do
    prop "accepts allocations summing to total with consistent currency" $
      \(total :: Money) (cats :: NonEmpty CategoryId) ->
        -- generate allocations summing to total
        let n = length cats
            per = total -- placeholder; the test will partition `total` across `cats`
        in ... -- exercise: build a list of allocations that satisfy the invariants,
               -- call mkIncome, expect Right
    prop "rejects allocations whose sum does not equal total" $ ...
    prop "rejects allocations with currency mismatch" $ ...
    prop "rejects allocations with non-positive amount" $ ...

  describe "allocationsOf / categorisedAmount / isCategorised / kindOf" $ do
    prop "allocationsOf is Just iff kindOf ∈ {IncomeKind, ExpenseKind}" $ \tt ->
      isJust (allocationsOf tt) === (kindOf tt `elem` [IncomeKind, ExpenseKind])
    prop "categorisedAmount equals sum of allocations when defined" $ \tt ->
      categorisedAmount tt === fmap sumAllocationsUnchecked (allocationsOf tt)
    prop "kindOf is total" $ \tt ->
      kindOf tt `seq` True
```

Flesh out the partition-allocations helper in `test/Testkit/Helpers.hs`:

```haskell
-- | Partition a Money amount into N positive slices summing exactly to it.
-- Used by tests that need to construct valid allocation lists.
partitionMoney :: Money -> [CategoryId] -> Allocations
partitionMoney = ... -- splits the value equally with the last allocation
                     -- absorbing the rounding residual
```

- [ ] **Step 6: Add `Arbitrary TransferType` to `test/Testkit/Generators.hs`**

```haskell
instance Arbitrary TransferType where
  arbitrary = oneof
    [ do total <- arbitrary
         cats  <- arbitrary
         pure (either (const Transfer) id (mkIncome total (partitionMoney total cats)))
    , do total <- arbitrary
         cats  <- arbitrary
         pure (either (const Transfer) id (mkExpense total (partitionMoney total cats)))
    , pure Transfer
    , pure Adjustment
    ]
```

- [ ] **Step 7: Run**

```
just build
just test --test-option='--match' --test-option='Domain.Core.TransferType'
```

Expected: PASS.

- [ ] **Step 8: Commit**

```
git add src/Domain/Core/Types.hs test/Domain/Core/TransferTypePropertySpec.hs \
        test/Testkit/Generators.hs test/Testkit/Helpers.hs
git commit -m "feat(domain): TransferType carries NonEmpty Allocation"
```

> **Note:** This commit breaks downstream files that construct `Income CategoryId` / `Expense CategoryId` directly. The next tasks fix them in dependency order. **Expect `just build` to fail at the end of this step in dependent modules — that's the signal to move to Task 3.**

---

## Task 3: Update destructuring sites in Domain layer

**Spec:** §1, §5.

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs:207`, `:317-318`
- Modify: `src/Domain/Transaction/CommandHandler.hs:214-215`

- [ ] **Step 1: Update `transactionDefault` in `Projection.hs`**

Replace `transferType = Income (unsafeDictionaryEntryId nil)` with a sentinel that satisfies `Income (NonEmpty Allocation)` but is never observed in practice:

```haskell
transferType =
  Income (NE.singleton
            (Allocation (unsafeDictionaryEntryId nil)
                        (mkDefaultMoney 0 `orErrorMsg` "transactionDefault: zero money")))
```

Where `orErrorMsg :: Either e a -> Text -> a` is whatever convention this module uses (use the existing `error` pattern at line 195 — keep style consistent).

> **Why this is safe:** the default value is only ever read before any event is applied, and the first event (`TransferInitiated`) overwrites the entire `transferType`. The sentinel needs no validity beyond type-checking.

- [ ] **Step 2: Update `Income _ -> Income evt.newCategory` arms**

In `Projection.hs:317-318` and `src/Application/ReadModels/Transaction.hs:345-346`, these arms will be rewritten when we replace the `TransactionCategoryChanged` event handler (Task 6 / Task 11). Leave them building-broken for now; the rename pass will replace these lines wholesale.

- [ ] **Step 3: Update `CommandHandler.hs:214-215`**

These arms are inside the `ChangeTransactionCategory` handler, which will be removed entirely in Task 5. Leave broken.

- [ ] **Step 4: Verify build status**

```
just build
```

Expected: still failing — `Income _` / `Expense _` arms missing; `ChangeTransactionCategory` references stale. Tasks 4-7 fix these as a unit.

- [ ] **Step 5: Commit interim**

```
git add src/Domain/Transaction/Projection.hs
git commit -m "refactor(transaction): widen projection default to NonEmpty Allocation"
```

---

## Task 4: Add new + remove old `DomainError` variants

**Spec:** §8 (Web layer error table).

**Files:**
- Modify: `src/Domain/Core/Errors.hs`

- [ ] **Step 1: Remove the old variant**

Delete the `CannotChangeCategoryOnUncategorizedTransaction` constructor and its `errorMessage` arm.

- [ ] **Step 2: Add the new variants**

Add (next to existing `Cannot*` variants):

```haskell
  | -- | Smart-constructor / handler rejection: sum of allocation amounts
    --   does not equal the categorised total.
    AllocationsDoNotSumToTotal
  | -- | An allocation's amount is zero or negative.
    AllocationAmountNotPositive
  | -- | An allocation's currency differs from the categorised side's currency.
    AllocationCurrencyMismatch
  | -- | SetTransactionAllocations / AmendTransfer issued with a
    --   newTransferType whose kind differs from the existing transaction's.
    --   Recategorising across the kind boundary is a delete-and-repost
    --   operation.
    CannotChangeKindOfCategorisedTransaction
  | -- | SetTransactionAllocations issued against a Transfer or Adjustment,
    --   which has no allocations to set.
    CannotSetAllocationsOnUncategorisedTransaction
  | -- | SetTransactionAllocations issued against a non-Completed transaction.
    TransactionMustBeCompletedForAllocationsEdit
```

- [ ] **Step 3: Add `errorMessage` arms**

```haskell
  AllocationsDoNotSumToTotal ->
    "Sum of allocation amounts must equal the categorised amount"
  AllocationAmountNotPositive ->
    "Each allocation amount must be positive"
  AllocationCurrencyMismatch ->
    "All allocations must share the categorised currency"
  CannotChangeKindOfCategorisedTransaction ->
    "Cannot change Income ↔ Expense ↔ Transfer ↔ Adjustment via allocation edit; delete and repost instead"
  CannotSetAllocationsOnUncategorisedTransaction ->
    "Transfer and Adjustment transactions have no allocations to set"
  TransactionMustBeCompletedForAllocationsEdit ->
    "Allocations can only be edited on Completed transactions"
```

- [ ] **Step 4: Run hlint + ormolu**

```
just check
```

- [ ] **Step 5: Commit**

```
git add src/Domain/Core/Errors.hs
git commit -m "refactor(domain): rotate DomainError variants for allocations"
```

---

## Task 5: Rename `ChangeTransactionCategory` → `SetTransactionAllocations`

**Spec:** §3 (Commands).

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs`

- [ ] **Step 1: Replace the command type**

Replace `data ChangeTransactionCategory = …` (and its haddock block) with:

```haskell
-- | Command to set the allocation list on a completed Income / Expense transaction.
--
-- Replaces the old single-category 'ChangeTransactionCategory': a
-- fresh allocation list is supplied atomically. Single-category edits
-- are the degenerate length-1 case. The command carries only
-- allocations, not a full 'TransferType' — the surrounding kind is
-- preserved structurally from existing state.
--
-- Business Rules (enforced by the pure handler — see also DomainError):
--   * Transaction must be in the Completed state
--     ('CannotEditUncompletedTransaction').
--   * Existing 'transferType' must be Income or Expense
--     ('CannotSetAllocationsOnUncategorisedTransaction').
--   * Sum of 'newAllocations' must equal the existing categorised
--     amount ('AllocationsDoNotSumToTotal').
--   * Allocation currencies match the existing categorised currency
--     ('AllocationCurrencyMismatch') and each amount > 0
--     ('AllocationAmountNotPositive').
--   * Service layer validates each 'CategoryId' exists in the user's
--     dictionary for the existing kind.
--
-- Example:
-- >>> SetTransactionAllocations txId (allocA :| [allocB])
data SetTransactionAllocations = SetTransactionAllocations
  { transactionId  :: TransactionId
  , newAllocations :: Allocations
  }
  deriving (Show, Eq)
```

> **Tightening (2026-05-31):** an earlier draft of this task had `newTransferType :: TransferType` on `SetTransactionAllocations`. That carried a kind that could never differ from the existing one; tightened to `NonEmpty Allocation`. Kind preservation is now structural — `CannotChangeKindOfCategorisedTransaction` is no longer reachable through this command.

- [ ] **Step 2: Update the export list and `transactionCommands`**

In the `module` header export list, replace `ChangeTransactionCategory (..)` with `SetTransactionAllocations (..)`. In `transactionCommands` list, replace `''ChangeTransactionCategory` with `''SetTransactionAllocations`.

- [ ] **Step 3: `AmendTransfer` — UNCHANGED (rollback note)**

> **Rollback:** an earlier iteration added `newTransferType :: TransferType` to `AmendTransfer` and `CompleteTransferAmendment`. That field is **not** part of the final shape: amendment is posting-facts only. Both records keep master's shape verbatim. Kind preservation is structural — guaranteed by `validateAccountTypePreserved` at the service layer (the kind is a function of source/target `AccountType`). When the categorised amount changes via amendment, the projection rescales existing allocations proportionally (see Task 8).

- [ ] **Step 4: Update `deriveJSON` calls**

Replace `deriveJSON defaultOptions ''ChangeTransactionCategory` with `deriveJSON defaultOptions ''SetTransactionAllocations`.

- [ ] **Step 5: Run ormolu + hlint**

```
just check
```

- [ ] **Step 6: Commit**

```
git add src/Domain/Transaction/Commands.hs
git commit -m "refactor(transaction): rename Change->Set allocations"
```

---

## Task 6: Rename `TransactionCategoryChanged` → `TransactionAllocationsChanged`

**Spec:** §4 (Events).

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`

- [ ] **Step 1: Replace the event type**

Replace `data TransactionCategoryChanged = …` with:

```haskell
-- | Event emitted when the allocation list on a completed Income / Expense
-- transaction is replaced. The event carries only the new allocations
-- — the surrounding kind is preserved from existing state and
-- reconstructed at the projection via 'replaceAllocations'.
data TransactionAllocationsChanged = TransactionAllocationsChanged
  { transactionId  :: TransactionId
  , newAllocations :: Allocations
  }
  deriving (Show, Eq)
```

> **Tightening (2026-05-31):** earlier draft had `newTransferType :: TransferType` here. Tightened to `NonEmpty Allocation` since the kind cannot change on this event.

- [ ] **Step 2: Update exports and `transactionEvents`**

Replace `TransactionCategoryChanged (..)` with `TransactionAllocationsChanged (..)` in exports. Replace `''TransactionCategoryChanged` with `''TransactionAllocationsChanged` in `transactionEvents`.

- [ ] **Step 3: Amendment events**

> **Refinement (2026-05-30 post-master rebase):**
>
> `TransferAmendmentInitiated` keeps master's shape verbatim — it is a posting-facts-only saga-trigger event; the saga's leg orchestration does not care about categorisation.
>
> `TransferAmendmentCompleted` gains one new field:
>
> ```haskell
> data TransferAmendmentCompleted = TransferAmendmentCompleted
>   { transactionId      :: TransactionId
>   , newSourceAccountId :: AccountId
>   , newTargetAccountId :: AccountId
>   , newSourceAmount    :: Money
>   , newTargetAmount    :: Money
>   , newExchangeRate    :: Maybe ExchangeRate
>   , newAllocations     :: Maybe Allocations  -- NEW: handler-computed
>   , amendedBy          :: UserId
>   }
> ```
>
> The field is **handler-computed**, not user-supplied — the `AmendTransfer` / `CompleteTransferAmendment` commands deliberately do not accept allocations. The command handler for `CompleteTransferAmendment` rescales the existing allocations against the new categorised amount (see Task 7) and emits `Just scaled` for Income / Expense; the field is `Nothing` for `Transfer` / `Adjustment`. Projections / read models apply the field via `replaceAllocations` on the existing kind (see Task 8 / Task 11).
>
> **Tightening (2026-05-31):** earlier draft had `newTransferType :: TransferType` here. Tightened to `Maybe (NonEmpty Allocation)` since kind is structurally preserved across amendment by `AccountType` invariants.

- [ ] **Step 4: Update `deriveJSON`**

Replace `deriveJSON defaultOptions ''TransactionCategoryChanged` with `deriveJSON defaultOptions ''TransactionAllocationsChanged`.

- [ ] **Step 5: Run ormolu + hlint**

```
just check
```

- [ ] **Step 6: Commit**

```
git add src/Domain/Transaction/Events.hs
git commit -m "refactor(transaction): rename CategoryChanged->AllocationsChanged event"
```

---

## Task 7: Rewrite `CommandHandler` arms

**Spec:** §3 (Commands), §4 (Events), §5 (Aggregate projection).

**Files:**
- Modify: `src/Domain/Transaction/CommandHandler.hs`

- [ ] **Step 1: Update the `InitiateTransfer` arm**

Where the handler emits `TransferInitiated`, add invariants before emission, using helpers from `Domain.Core.Types`:

```haskell
-- Categorised-side checks (the smart constructor *should* have done these,
-- but we re-check at the boundary because nothing prevents a caller from
-- assembling a TransferType directly outside the constructor module).
case cmd.transferType of
  Income allocs ->
    checkAllocationsAgainst cmd.targetAmount allocs
  Expense allocs ->
    checkAllocationsAgainst cmd.sourceAmount allocs
  Transfer   -> Right ()
  Adjustment -> Right ()
```

Where `checkAllocationsAgainst` is a small local helper:

```haskell
checkAllocationsAgainst :: Money -> Allocations -> Either DomainError ()
checkAllocationsAgainst expected allocs = do
  unless (allSameCurrency expected.currency allocs) $
    Left AllocationCurrencyMismatch
  unless (sumAllocationsUnchecked allocs == expected) $
    Left AllocationsDoNotSumToTotal
  -- amount > 0 is already an Allocation-construction invariant; we re-check
  -- defensively at the handler boundary:
  case NE.filter (\a -> a.amount.amount <= 0) allocs of
    [] -> Right ()
    _  -> Left AllocationAmountNotPositive

allSameCurrency :: Currency -> Allocations -> Bool
allSameCurrency c = all (\a -> a.amount.currency == c)
```

`sumAllocationsUnchecked` lives in `Domain.Core.Types` (Task 2). `allSameCurrency` can live alongside it (also used by the smart constructors) — promote to `Domain.Core.Types` and export.

- [ ] **Step 2: Replace the `ChangeTransactionCategory` arm**

Delete the existing handler arm matching on `ChangeTransactionCategoryTransactionCommand`. Replace with the arm below. The plan deliberately avoids `error "unreachable"` (forbidden by CLAUDE.md): we get `(existingAllocs, newAllocs)` out of one `case` whose branches are total, then run the checks linearly.

```haskell
-- Handle SetTransactionAllocations command
--
-- The command carries only the new allocation list; kind is preserved
-- structurally from existing state. We therefore only check that the
-- existing transaction is categorised, then validate the allocations
-- against the existing categorised total / currency / positivity.
handleTransactionCommand transaction
  (SetTransactionAllocationsTransactionCommand cmd@SetTransactionAllocations {..}) = do
  -- 1. Status check
  unless (transaction.status == Completed) $
    Left CannotEditUncompletedTransaction
  -- 2. Existing must be categorised
  case allocationsOf transaction.transferType of
    Nothing ->
      Left CannotSetAllocationsOnUncategorisedTransaction
    Just existingAllocs -> do
      let existingTotal = sumAllocationsUnchecked existingAllocs
      -- 3. Currency consistency / sum / positivity (defensive boundary checks)
      checkAllocationsAgainst existingTotal newAllocations
      -- 4. Emit
      Right
        [ TransactionAllocationsChangedTransactionEvent
            TransactionAllocationsChanged
              { transactionId  = cmd.transactionId
              , newAllocations = newAllocations
              }
        ]
```

> **Tightening (2026-05-31):** previous draft compared `kindOf newTransferType` against the existing kind. The new shape carries only allocations, so kind preservation is structural; the `CannotChangeKindOfCategorisedTransaction` branch is dropped from this arm.

- [ ] **Step 3: `AmendTransfer` arm — match master (rollback note)**

> **Rollback:** the `AmendTransfer` arm matches master verbatim. No kind-preservation check, no allocation-sum check — there are no allocations on the command. Keep only master's existing invariants: same-account rejection, zero-amount rejection, cancellation-in-progress rejection, Completed-state guard. Kind preservation is enforced structurally at the service layer; allocation rescale happens in the handler arm for `CompleteTransferAmendment` (Step 3a, below).

- [ ] **Step 3a: `CompleteTransferAmendment` arm — handler-computed rescale**

> **Refinement (2026-05-30):** the handler arm for `CompleteTransferAmendment` is the canonical site of the allocation rescale. The arm dispatches on `(kindOf, allocationsOf)` of the existing `transferType`:
>
> ```haskell
> let oldTransferType = transaction ^. #transferType
>     scaledAllocations :: Maybe Allocations
>     scaledAllocations = case (kindOf oldTransferType, allocationsOf oldTransferType) of
>       (IncomeKind, Just oldAllocs) ->
>         let oldTotal = sumAllocationsUnchecked oldAllocs
>          in Just $ if oldTotal /= newTargetAmount
>                      then rescaleAllocations oldTotal newTargetAmount oldAllocs
>                      else oldAllocs
>       (ExpenseKind, Just oldAllocs) ->
>         let oldTotal = sumAllocationsUnchecked oldAllocs
>          in Just $ if oldTotal /= newSourceAmount
>                      then rescaleAllocations oldTotal newSourceAmount oldAllocs
>                      else oldAllocs
>       _ -> Nothing  -- Transfer / Adjustment: no allocations to carry
> ```
>
> The arm then emits `TransferAmendmentCompleted` with `newAllocations = scaledAllocations` (and the other fields from the command). Projections / read models apply this via `replaceAllocations` on the existing kind (Task 8 / Task 11) — they do **not** re-derive the rescale.
>
> **Tightening (2026-05-31):** previous draft built a full `TransferType` via `rescaleTransferType`. The event carries only allocations now; the handler calls `rescaleAllocations` directly and wraps the result in `Just` (or emits `Nothing` for uncategorised existing kinds).

- [ ] **Step 4: Build**

```
just build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```
git add src/Domain/Transaction/CommandHandler.hs
git commit -m "feat(transaction): handler enforces allocation invariants on Initiate/Set/Amend"
```

---

## Task 8: Update `Projection` event arms

**Spec:** §5.

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs`

- [ ] **Step 1: Replace the `TransactionCategoryChangedTransactionEvent` arm**

Replace lines around `:317-318`:

```haskell
handleTransactionEvent transaction
  (TransactionAllocationsChangedTransactionEvent evt) =
  transaction
    { transferType =
        replaceAllocations evt.newAllocations transaction.transferType
    }
```

(No `case`-on-Income/Expense any more; the event carries only allocations and `replaceAllocations` rebuilds the full `TransferType` from the existing kind.)

- [ ] **Step 2: Update the `TransferAmendmentCompletedTransactionEvent` arm**

> **Refinement (2026-05-30):** the event carries `newAllocations :: Maybe (NonEmpty Allocation)` as a handler-computed fact (see Task 7 Step 3a). The projection arm applies it via `replaceAllocations` when `Just`, leaves the `transferType` unchanged when `Nothing` — no rescale logic in the projection.

```haskell
handleTransactionEvent transaction
  (TransferAmendmentCompletedTransactionEvent evt) =
  let newTT = case evt.newAllocations of
        Just allocs -> replaceAllocations allocs transaction.transferType
        Nothing     -> transaction.transferType
   in transaction
        { sourceAccountId      = evt.newSourceAccountId
        , targetAccountId      = evt.newTargetAccountId
        , sourceAmount         = evt.newSourceAmount
        , targetAmount         = evt.newTargetAmount
        , exchangeRate         = evt.newExchangeRate
        , transferType         = newTT
        , amendmentInProgress  = False
        , amendmentCount       = transaction.amendmentCount + 1
        }
```

Adjust to the actual record-update form in this file. The helpers `rescaleAllocations` / `rescaleTransferType` stay exported from `Domain.Core.Types` — they're now called by the handler instead of the projection. `replaceAllocations` is exported from the same module (see Task 2).

> **Tightening (2026-05-31):** previous draft set `transferType = evt.newTransferType` directly. Updated to call `replaceAllocations` on the existing kind, since the event now carries only allocations (and `Nothing` for uncategorised existing kinds).

- [ ] **Step 3: Update the `TransferAmendmentInitiatedTransactionEvent` arm** (if it currently snapshots category)

If the existing arm captures pre-image category data on the in-progress amendment, swap to capturing the full prior `transferType`. If it does not, no change.

- [ ] **Step 4: Build + sanity test**

```
just build
just test --test-option='--match' --test-option='Projection'
```

- [ ] **Step 5: Commit**

```
git add src/Domain/Transaction/Projection.hs
git commit -m "feat(transaction): projection handles TransactionAllocationsChanged"
```

---

## Task 9: Property tests for handler invariants

**Spec:** §3, Testing.

**Files:**
- Create or extend: `test/Domain/Transaction/CommandHandlerPropertySpec.hs` (use the existing file if it exists; otherwise create)

- [ ] **Step 1: Add kind-preservation property**

```haskell
prop "SetTransactionAllocations rejects any newTransferType of a different kind" $
  \existingType newType ->
    isCategorised existingType ==>
      kindOf existingType /= kindOf newType ==>
        let tx = completedTxWithType existingType
            cmd = SetTransactionAllocations tx.transactionId newType
        in handleTransactionCommand tx (SetTransactionAllocationsTransactionCommand cmd)
             === Left CannotChangeKindOfCategorisedTransaction
```

- [ ] **Step 2: Add auto-scale property on `TransferAmendmentCompleted`**

> **Rollback note:** the earlier "AmendTransfer rejects newTransferType …" property is gone — `AmendTransfer` no longer accepts allocations from the caller. Instead, test the projection's auto-scale behaviour.

```haskell
prop "TransferAmendmentCompleted rescales allocations proportionally on amount change" $
  \existingTx newAmount ->
    isCategorised existingTx.transferType ==>
      categorisedAmount existingTx.transferType /= Just newAmount ==>
        let evt = TransferAmendmentCompleted
                    { newSourceAccountId = existingTx.sourceAccountId
                    , newTargetAccountId = existingTx.targetAccountId
                    , newSourceAmount    = if isExpense existingTx then newAmount else existingTx.sourceAmount
                    , newTargetAmount    = if isIncome  existingTx then newAmount else existingTx.targetAmount
                    , newExchangeRate    = existingTx.exchangeRate
                    , amendedBy          = existingTx.initiatedBy
                    , transactionId      = existingTx.transactionId
                    }
            updated = handleTransactionEvent existingTx
                        (TransferAmendmentCompletedTransactionEvent evt)
        in categorisedAmount updated.transferType === Just newAmount
           .&&. -- ratio preservation
           ratioOfAllocations updated.transferType === ratioOfAllocations existingTx.transferType
```

Where `ratioOfAllocations` extracts the proportional shape (e.g., normalized list of amount fractions) for comparison. Property holds exactly because `rescaleAllocations` is exact `Rational` math.

- [ ] **Step 3: Add uncategorised-rejection property**

```haskell
prop "SetTransactionAllocations on Transfer/Adjustment is rejected" $ ...
```

- [ ] **Step 4: Run**

```
just test --test-option='--match' --test-option='CommandHandler.*[Pp]roperty'
```

- [ ] **Step 5: Commit**

```
git add test/Domain/Transaction/CommandHandlerPropertySpec.hs
git commit -m "test(transaction): kind-preservation and sum-consistency properties"
```

---

## Task 10: LiquidHaskell refinements on `Allocation` and the wrappers

**Spec:** §2.

**Files:**
- Modify: `src/Domain/Core/Types.hs`

- [ ] **Step 1: Refine `Allocation`**

`Money` has fields `amount :: Rational` and `currency :: Currency`. The LH refinement names the *rational* component as the positivity target:

```haskell
{-@
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: {m : Money | (amount m) > 0}
  }
@-}
```

`(amount m)` is the LH-syntax selector for the `Money.amount` field. If the project's existing convention uses a `measure moneyValue` (check existing `Money` refinements in this file), prefer the existing measure.

- [ ] **Step 2: Reflect helpers**

```haskell
{-@ measure allocationsCurrency @-}
allocationsCurrency :: NonEmpty Allocation -> Currency
allocationsCurrency xs = (NE.head xs).amount.currency

{-@ reflect sumAllocationsUnchecked @-}
-- Already defined in Task 2 Step 4
```

- [ ] **Step 3: Refine the smart-constructor return types**

```haskell
{-@ mkIncome
      :: m:Money
      -> {xs : NonEmpty Allocation
            | (amount (sumAllocationsUnchecked xs)) == (amount m)
            && (currency (sumAllocationsUnchecked xs)) == (currency m)}
      -> Either DomainError TransferType
@-}
```

- [ ] **Step 4: Verify**

```
just build      # LH runs as part of cabal build
```

If LH errors emerge, follow the project's pattern: prefer inlining the predicate expression to using a helper, and stage refinements in incrementally. Documented in CLAUDE.md.

- [ ] **Step 5: Commit**

```
git add src/Domain/Core/Types.hs
git commit -m "feat(domain): LiquidHaskell refinements for Allocation and TransferType"
```

> **If LH refinements are intractable** within a reasonable time-box (e.g., the inter-field refinement coupling allocations sum to an external `Money` argument fights the SMT solver), commit only the per-`Allocation` refinement (Step 1) and the measures (Step 2). Leave the constructor refinements as a follow-up issue. Note this on the spec.

---

## Task 11: Update `Application.ReadModels.Transaction`

**Spec:** §6.

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`

- [ ] **Step 1: Replace the `TransactionCategoryChangedEvent` event arm**

Replace lines around `:337` and `:345-346` so the arm applies `evt.newAllocations` via `replaceAllocations` on the row's existing `transferType` (mirrors the projection change).

- [ ] **Step 2: Update `findReferencingTransactions`**

Lines `:542-543` filter transactions referencing a `CategoryId`. Update to walk allocations:

```haskell
isReferencing tx =
  case allocationsOf tx.transferType of
    Just allocs -> any (\a -> a.categoryId == entryId) allocs
    Nothing -> False
```

- [ ] **Step 3: Update the `TransferAmendmentCompleted` event arm**

> **Refinement (2026-05-30):** the event carries `newAllocations :: Maybe (NonEmpty Allocation)` as a handler-computed fact (see Task 7 Step 3a). The read-model arm applies it via `replaceAllocations` when `Just`, leaving the `transferType` unchanged when `Nothing` — no rescale logic. Mirrors the projection's simplification (Task 8 Step 2).
>
> **Tightening (2026-05-31):** previous draft set `transferType = evt.newTransferType` directly. Updated to call `replaceAllocations` on the existing kind.

- [ ] **Step 4: Update imports and exports**

Swap `TransactionCategoryChangedEvent` ↦ `TransactionAllocationsChangedEvent` and the same in the event types re-export at the top of the module (`:77`, `:90`).

- [ ] **Step 5: Build + test**

```
just build
just test --test-option='--match' --test-option='ReadModels.Transaction'
```

- [ ] **Step 6: Commit**

```
git add src/Application/ReadModels/Transaction.hs
git commit -m "feat(read-model): TransactionList handles allocations"
```

---

## Task 12: Update `Application.Services.TransactionHistoryService`

**Spec:** §6.

**Files:**
- Modify: `src/Application/Services/TransactionHistoryService.hs`

- [ ] **Step 1: Rename the history variant**

Replace `HistoryCategoryChanged TransactionCategoryChanged` with `HistoryAllocationsChanged TransactionAllocationsChanged`. Update the event-arm match (line `:169`) accordingly.

- [ ] **Step 2: Build**

```
just build
```

- [ ] **Step 3: Commit**

```
git add src/Application/Services/TransactionHistoryService.hs
git commit -m "refactor(history): rename CategoryChanged history entry"
```

---

## Task 13: `TransactionService` — replace `changeTransactionCategory` with `setTransactionAllocations`; widen initiation entry points

**Spec:** §7.

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`

- [ ] **Step 1: Replace `changeTransactionCategory`**

Delete the function and any helpers used only by it. Add:

```haskell
setTransactionAllocations ::
  ( MonadReader env m, HasEventStore env, HasDbPool env
  , MonadError DomainError m, MonadIO m
  ) =>
  UserId ->
  TransactionId ->
  Allocations ->     -- newAllocations
  m TransactionData
setTransactionAllocations userId txId newAllocations = do
  -- 1. Authorization: Editor role on the relevant account(s)
  ...
  -- 2. Validate each CategoryId exists in the user's dictionary for the
  --    EXISTING kind (read from the read model).
  ExceptT (validateAllocationsAgainstDictionary userId (kindOf existing.transferType) newAllocations)
  -- 3. Cutoff-date gate (reuse existing helper used by other metadata edits)
  ...
  -- 4. Issue the command
  dispatchTransactionCommand txId
    (SetTransactionAllocationsTransactionCommand
       (SetTransactionAllocations txId newAllocations))
  -- 5. Return the updated TransactionData
  ...
```

> **Tightening (2026-05-31):** the service signature now takes `NonEmpty Allocation` instead of `TransferType`. The dictionary side picks `pickCategoryDictForKind (kindOf existing.transferType)` against the read-model transaction, so the kind comes from existing state — not from any new-payload field.

Where `validateAllocationsAgainstDictionary` is a new helper. Pattern-match on the `TransferType` constructor directly so totality is structural (no partial `error` branch):

```haskell
validateAllocationsAgainstDictionary userId tt = case tt of
  Income allocs ->
    ensureAll ConfigurationService.incomeCategoryDictId allocs
  Expense allocs ->
    ensureAll ConfigurationService.expenseCategoryDictId allocs
  Transfer   -> pure ()
  Adjustment -> pure ()
  where
    ensureAll dictId allocs =
      for_ allocs $ \a ->
        ConfigurationService.ensureCategoryExists userId dictId a.categoryId
```

This requires importing `Income (..)` / `Expense (..)` data constructors locally **only inside `Domain.Core.Types`'s neighbour modules** if the constructor export is limited. If the service layer cannot see the constructors (per the spec, only `Domain.Core.Types` destructures them), expose a helper `pickCategoryDict :: TransferType -> Maybe DictionaryId` (already in this module — see Step 3 below) and a per-allocation getter, or extend the `Domain.Core.Types` export list to include the constructors for trusted-callers' use. Pick one of:

  a. Export `Income`/`Expense` constructors and accept the rule narrows to "no destructuring outside `Domain.Core.Types` and `Domain.Core` neighbours" (looser); OR
  b. Add a small accessor combinator in `Domain.Core.Types` like:

  ```haskell
  withAllocations
    :: Applicative m
    => (DictionaryId -> Allocations -> m ())
    -> (TransferType -> m ())
  withAllocations f = \case
    Income  xs -> f incomeCategoryDictId  xs  -- ids passed in from caller
    Expense xs -> f expenseCategoryDictId xs
    Transfer   -> pure ()
    Adjustment -> pure ()
  ```

  Prefer (a) — it's the smaller change and the destructuring rule was already "no consumer outside this module" rather than a hard sandbox; the service layer is a trusted neighbour.

- [ ] **Step 2: Widen `initiateIncome` / `initiateExpense`**

Change signatures from `… -> CategoryId -> …` to `… -> NonEmpty Allocation -> …`. The amount parameter that previously implied "this is the whole categorised amount" stays; the allocations replace the single category id. At the call site that builds the `transferType`, use `mkIncome` / `mkExpense` smart constructors and surface the `DomainError` if they reject.

- [ ] **Step 3: Update `pickCategoryDict`**

Lines `:919-920` already pattern-match on `Income _` / `Expense _`. The match still works (we're matching the constructor regardless of payload), but the `_` should be made explicit or replaced with `kindOf`-based dispatch for clarity:

```haskell
pickCategoryDict tt = case kindOf tt of
  IncomeKind  -> Just ConfigurationService.incomeCategoryDictId
  ExpenseKind -> Just ConfigurationService.expenseCategoryDictId
  _ -> Nothing
```

- [ ] **Step 4: Amendment service — no `newTransferType` plumbing (rollback note)**

> **Rollback:** the `amendTransfer` service signature matches master verbatim. It does not take or thread `newTransferType`. Kind preservation is enforced by `validateAccountTypePreserved` (master). Allocations are not validated here — the projection rescales them on amount change.

- [ ] **Step 5: Build**

```
just build
just test --test-option='--match' --test-option='TransactionService'
```

- [ ] **Step 6: Commit**

```
git add src/Application/Services/TransactionService.hs
git commit -m "feat(transaction-service): setTransactionAllocations replaces changeTransactionCategory; initiation takes NonEmpty Allocation"
```

---

## Task 14: Update `BankImportService` to build length-1 allocations

**Spec:** Goal 3 ("Splits are supported at registration time … single command, no special 'import' path").

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`

- [ ] **Step 1: Wrap the imported category as a length-1 allocation**

At every site where the import service calls `initiateIncome` / `initiateExpense`, build:

```haskell
let allocs = NE.singleton
              (Allocation chosenCategoryId importedAmount)
in TransactionService.initiateExpense userId accountId importedAmount allocs ...
```

(Same for Income.) The single-allocation total equals the transaction amount — the smart constructor accepts.

- [ ] **Step 2: Build + test**

```
just build
just test --test-option='--match' --test-option='BankImport'
```

- [ ] **Step 3: Commit**

```
git add src/Application/Services/BankImportService.hs
git commit -m "feat(bank-import): emit length-1 allocations on import"
```

---

## Task 15: `TransferAmendmentManager` saga — no `newTransferType` plumbing (rollback note)

**Spec:** §3 (AmendTransfer), §4 (amendment events).

> **Rollback:** the saga state matches master verbatim. `TransferAmendmentData` does NOT carry `newTransferType`. The saga threads accounts / amounts / FX / `at` only. Completion command `CompleteTransferAmendment` is built from those fields. Allocations auto-rescale in the projection when the amount changes — saga state is unaware.

This task is effectively a no-op on top of master; keep it in the plan for documentation continuity.

---

## Task 16: Update Web layer DTOs, routes, and error mapping

**Spec:** §8.

> **Rollback note:** `AmendTransactionRequest` matches master verbatim — no `newTransferType` / `category` field. `amendTransferHandler` does NOT read the existing transaction's `transferType` before issuing `AmendTransfer`. The handler just maps the request body to `AmendTransfer` (accounts / amounts / FX / `amendedBy`) and dispatches.

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/TransactionAPI.hs`
- Modify: `src/Web/ErrorMapping.hs`

- [ ] **Step 1: Replace `ChangeTransactionCategoryRequest`**

In `src/Web/Types.hs`:

```haskell
-- DELETE:
data ChangeTransactionCategoryRequest = ChangeTransactionCategoryRequest { ... }

-- ADD:
data SetTransactionAllocationsRequest = SetTransactionAllocationsRequest
  { newAllocations :: Allocations }
  deriving (Show, Eq, Generic)

instance ToJSON   SetTransactionAllocationsRequest
instance FromJSON SetTransactionAllocationsRequest
```

> **Tightening (2026-05-31):** previous draft had `newTransferType :: TransferType`. The body now carries the flat allocation list since the kind cannot change on this endpoint.

Update the export list correspondingly.

- [ ] **Step 2: Update `transferTypeToText` / `transferTypeCategoryText`**

Lines `:1038-1046`. The `transferTypeToText` arms still work (matching on constructors regardless of payload). `transferTypeCategoryText` returned a single `CategoryId` — that no longer makes sense for multi-category transactions. Either:

   a. Delete `transferTypeCategoryText`; replace each call site with the appropriate use of `allocationsOf`.
   b. Reframe as `transferTypeCategoryListText :: TransferType -> [Text]` returning all category ids.

Pick (a) unless a caller needs a flat list — check call sites with `grep -n transferTypeCategoryText src/`.

- [ ] **Step 3: Replace the API route**

In `src/Web/API/TransactionAPI.hs`:

```haskell
-- DELETE the existing "category" sub-route:
:<|> Capture "id" TransactionId
     :> "category"
     :> ReqBody '[JSON] ChangeTransactionCategoryRequest
     :> ...

-- ADD:
:<|> Capture "id" TransactionId
     :> "allocations"
     :> ReqBody '[JSON] SetTransactionAllocationsRequest
     :> Patch '[JSON] TransactionData
```

Update the handler tuple to match. The handler delegates to `TransactionService.setTransactionAllocations`.

- [ ] **Step 4: Update error mapping**

In `src/Web/ErrorMapping.hs`, replace the `CannotChangeCategoryOnUncategorizedTransaction` arm with the new six error arms from Task 4. Status codes:

```
AllocationsDoNotSumToTotal                       → 400
AllocationAmountNotPositive                      → 400
AllocationCurrencyMismatch                       → 400
CannotChangeKindOfCategorisedTransaction         → 400
CannotSetAllocationsOnUncategorisedTransaction   → 400
TransactionMustBeCompletedForAllocationsEdit     → 409
```

- [ ] **Step 5: Build**

```
just build
just check
```

- [ ] **Step 6: Commit**

```
git add src/Web/Types.hs src/Web/API/TransactionAPI.hs src/Web/ErrorMapping.hs
git commit -m "feat(web): allocations endpoint + DTOs + error mapping"
```

---

## Task 17: Update Telegram bot

**Spec:** §8 closing paragraph.

**Files:**
- Modify: `src/Telegram/Commands.hs`

- [ ] **Step 1: Wherever the bot constructs `Income` / `Expense`**

Build a `NonEmpty Allocation` (typically length-1 from a user-chosen category):

```haskell
let allocs = NE.singleton (Allocation chosenCat amount)
    tt     = either (throwError . ...) id (mkIncome amount allocs)
```

If the bot calls `initiateIncome` / `initiateExpense` directly (and those service functions were widened in Task 13), just pass the `NonEmpty Allocation` through.

- [ ] **Step 2: Build + test**

```
just build
just test --test-option='--match' --test-option='Telegram'
```

- [ ] **Step 3: Commit**

```
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): use NonEmpty Allocation"
```

---

## Task 18: Sweep test files for renamed symbols

**Spec:** Testing (table).

**Files:**
- Modify: `test/Domain/Transaction/LabelsAndCategorySpec.hs`
- Modify: `test/Domain/Transaction/LabelsProjectionSpec.hs`
- Modify: `test/Application/ReadModels/TransactionListSpec.hs`
- Modify: `test/Application/ReadModels/TransactionListPropertySpec.hs`
- Modify: `test/Web/API/TransactionAPISpec.hs`
- **Delete** `test/Web/API/TransactionCategoryAPISpec.hs` and **create** `test/Web/API/TransactionAllocationsAPISpec.hs` (full coverage in Task 21)
- Optional rename: `test/Domain/Transaction/LabelsAndCategorySpec.hs` → `LabelsAndAllocationsSpec.hs` (mirrors the rename)

- [ ] **Step 1: For each file**

`grep -n 'ChangeTransactionCategory\|TransactionCategoryChanged\|HistoryCategoryChanged'` and replace with the new names. Update inline test data to use the new shape (single-allocation `NonEmpty.singleton (Allocation cat amount)`).

- [ ] **Step 2: Run the full test suite**

```
just test
```

Expected: PASS.

- [ ] **Step 3: Commit**

```
git add test/
git commit -m "test: update test suite for allocations rename"
```

---

## Task 19: Add `AllocationsSpec` worked examples

**Spec:** Testing.

**Files:**
- Create: `test/Domain/Transaction/AllocationsSpec.hs`

- [ ] **Step 1: Write the spec**

```haskell
{-# LANGUAGE OverloadedRecordDot #-}

module Domain.Transaction.AllocationsSpec (spec) where

import Domain.Core.Types
import qualified Data.List.NonEmpty as NE
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "Allocations — worked examples" $ do
    it "200 UAH food + 800 UAH housekeeping sums to 1000 UAH Expense" $ do
      let total = mkUah 1000
          a1    = Allocation foodCat       (mkUah 200)
          a2    = Allocation housekeepCat  (mkUah 800)
      mkExpense total (a1 :| [a2]) `shouldSatisfy` isRight

    it "rejects sum mismatch" $ do
      let total = mkUah 1000
          a1    = Allocation foodCat (mkUah 200)
          a2    = Allocation foodCat (mkUah 700)   -- 900 ≠ 1000
      mkExpense total (a1 :| [a2]) `shouldBe`
        Left AllocationsDoNotSumToTotal

    it "rejects currency mismatch" $ do
      let total = mkUah 1000
          a1    = Allocation foodCat (mkUah 200)
          a2    = Allocation foodCat (mkUsd 800)
      mkExpense total (a1 :| [a2]) `shouldBe`
        Left AllocationCurrencyMismatch

    it "rejects non-positive amount" $ do
      let total = mkUah 1000
          a1    = Allocation foodCat (mkUah 0)
      mkExpense total (NE.singleton a1) `shouldBe`
        Left AllocationAmountNotPositive

    it "degenerate length-1 case works" $ do
      let total = mkUah 100
          a1    = Allocation foodCat (mkUah 100)
      mkIncome total (NE.singleton a1) `shouldSatisfy` isRight

  where
    mkUah n = ... -- helper from Testkit
    mkUsd n = ...
    foodCat = ... -- mock CategoryId from Testkit.Helpers
    housekeepCat = ...
```

- [ ] **Step 2: Run**

```
just test --test-option='--match' --test-option='Allocations'
```

- [ ] **Step 3: Commit**

```
git add test/Domain/Transaction/AllocationsSpec.hs
git commit -m "test(allocations): worked examples"
```

---

## Task 20: Integration test

**Spec:** Testing (table — `TransactionAllocationsIntegrationSpec`).

**Files:**
- Create: `test/Application/Services/TransactionAllocationsIntegrationSpec.hs`

- [ ] **Step 1: Write the E2E scenario**

```haskell
spec :: Spec
spec = describe "Transaction allocations — end to end" $ do
  it "register → set → amend round-trips through reads" $ do
    -- 1. Register an Expense with two allocations (200 food + 800 housekeeping)
    txId <- registerExpense
              [Allocation foodCat (mkUah 200), Allocation housekeepCat (mkUah 800)]

    -- 2. GET — read model carries both allocations
    tx1 <- getTransaction txId
    allocationsOf tx1.transferType `shouldBe`
      Just (foodCat :| [housekeepCat] ... )  -- (or however we want to compare)

    -- 3. SetTransactionAllocations to three allocations (100 + 100 + 800)
    setAllocations txId
      [Allocation foodCat (mkUah 100)
      , Allocation foodCat (mkUah 100)
      , Allocation housekeepCat (mkUah 800)]
    tx2 <- getTransaction txId
    length (NE.toList (fromJust (allocationsOf tx2.transferType))) `shouldBe` 3

    -- 4. AmendTransfer changes the amount to 2000 and re-splits
    amendTransfer txId 2000
      [Allocation foodCat (mkUah 500), Allocation housekeepCat (mkUah 1500)]
    tx3 <- getTransaction txId
    sumAllocations (fromJust (allocationsOf tx3.transferType))
      `shouldBe` mkUah 2000
```

The helpers `registerExpense`, `getTransaction`, `setAllocations`, `amendTransfer` live in `test/Testkit/Helpers.hs` or are inline in the spec. Use the in-memory event store from `test/Testkit/InMemoryEventStore.hs`.

- [ ] **Step 2: Run**

```
just test --test-option='--match' --test-option='Integration.*Allocations'
```

- [ ] **Step 3: Commit**

```
git add test/Application/Services/TransactionAllocationsIntegrationSpec.hs
git commit -m "test(integration): allocations register→set→amend round-trip"
```

---

## Task 21: Update HTTP API tests

**Spec:** Testing.

**Files:**
- Modify: `test/Web/API/TransactionAPISpec.hs`

- [ ] **Step 1: Replace `PATCH /transactions/:id/category` tests**

For each old test exercising the category endpoint, write the equivalent for `PATCH /transactions/:id/allocations`. Include:

- Happy path: 200 + 800 UAH split, returns 200, GET reflects the change.
- Rejection: sum mismatch, returns 400 with `AllocationsDoNotSumToTotal`.
- Rejection: kind mismatch (Income → Expense), returns 400 with `CannotChangeKindOfCategorisedTransaction`.
- Rejection: applied to a Transfer transaction, returns 400 with `CannotSetAllocationsOnUncategorisedTransaction`.
- Rejection: applied to a Pending transaction, returns 409 with `TransactionMustBeCompletedForAllocationsEdit`.

- [ ] **Step 2: Update DTO encode/decode round-trip tests**

The `TransferType` JSON shape changed — every fixture that asserts the wire format needs the new shape (allocations array inside `contents`).

- [ ] **Step 3: Run**

```
just test --test-option='--match' --test-option='Web.API.Transaction'
```

- [ ] **Step 4: Commit**

```
git add test/Web/API/TransactionAPISpec.hs
git commit -m "test(api): allocations endpoint coverage"
```

---

## Task 22: Bump backend version

**Spec:** §9 (DB recreation note).

**Files:**
- Modify: `package.yaml`

- [ ] **Step 1: Bump version**

`version: 0.3.0` → `version: 0.4.0`. The change is breaking (event shape, DTO shape, DB).

- [ ] **Step 2: Regenerate cabal**

```
hpack
```

- [ ] **Step 3: Commit**

```
git add package.yaml backend.cabal
git commit -m "chore(version): 0.4.0 — transaction allocations"
```

---

## Task 23: Final verification

**Files:** —

- [ ] **Step 1: Full build with `-Werror`**

```
cabal build -fci
```

Expected: PASS, no warnings.

- [ ] **Step 2: Full test suite**

```
just test
```

Expected: all PASS.

- [ ] **Step 3: LiquidHaskell verification**

LH runs as part of `just build`. If any refinement was deferred in Task 10, file a follow-up issue and link it in the spec's "Open Questions" section.

- [ ] **Step 4: Format + lint clean**

```
just check
```

- [ ] **Step 5: Smoke-test locally**

```
just docker-up
just run
# In another shell — exercise the new endpoint:
curl -X POST http://localhost:8080/transactions \
  -H 'content-type: application/json' \
  -d '{ "sourceAccountId": "...", "targetAccountId": "...",
        "sourceAmount": {"currency":"UAH","value":"1000.00"},
        "targetAmount": {"currency":"UAH","value":"1000.00"},
        "exchangeRate": null,
        "description": "Grocery store",
        "initiatedBy": "...",
        "at": "2026-05-30T12:00:00Z",
        "transferType": {
          "tag": "Expense",
          "contents": [
            {"categoryId": "FOOD", "amount": {"currency":"UAH","value":"200.00"}},
            {"categoryId": "HOUSE", "amount": {"currency":"UAH","value":"800.00"}}
          ]
        },
        "externalTransactionId": null,
        "labels": []
      }'
```

- [ ] **Step 6: Update the spec's status to `in-progress`**

In `docs/specs/2026-05-30-transaction-allocations-design.md` frontmatter: `status: draft` → `status: in-progress`. Commit as `docs(transaction): mark allocations spec as in-progress`.

- [ ] **Step 7: Open the PR for real (not just draft) once green**

```
gh pr ready
```

> When the PR merges and the deploy runs, drop the eventium tables on the target environment so they auto-recreate against the new event shape. This is captured in the spec; no code or migration handles it.

---

## Done.

When all 23 tasks are checked off:
- All tests pass under `just test`.
- `cabal build -fci` succeeds without warnings.
- LH refinements verify (modulo any deferred per Task 10 follow-up).
- The new endpoint works under a manual smoke test.
- Backend version is `0.4.0`.
- The PR can move from draft → ready for review.
