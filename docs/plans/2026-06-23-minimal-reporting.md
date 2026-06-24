---
status: draft
date: 2026-06-23
issue: homeaccounting/tracker#24
spec: docs/specs/2026-06-23-minimal-reporting-design.md
---

# Minimal Reporting (backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three read-only HTTP reporting endpoints — spending-by-category, income-vs-expense, and net-worth — that aggregate existing event-sourced data, normalized to the base currency.

**Architecture:** No new read model. A new `Application.Services.ReportingService` folds on-the-fly over the existing Transaction / Account / Configuration / ExchangeRate read models. Pure aggregation helpers (exported from the same module) carry the arithmetic and are tested without IO; the `AppM` service functions do read-model access + FX lookup at the boundary. A new `Web.API.ReportingAPI` exposes the endpoints, mapping service results to DTOs that reuse the domain `Money` JSON instance.

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Servant, Hspec + QuickCheck, Cabal/Hpack, `just`.

---

## Background you must internalize before starting

Read the spec (`docs/specs/2026-06-23-minimal-reporting-design.md`) in full. The non-obvious domain facts the code below relies on:

- **Expense** (`Regular → External`): `sourceAmount` is the user-account-currency leg; **`targetAmount` is the base-currency leg**. Expense-bucket allocations sum to `sourceAmount`.
- **Income** (`External → Regular`): **`sourceAmount` is the base-currency leg**; `targetAmount` is the user-account-currency leg. Allocations sum to `targetAmount`.
- The External account is always denominated in `baseCurrency`; there is exactly one per user.
- `exchangeRate = Nothing` ⟺ the transaction is same-currency (both legs equal, and the user-account currency *is* the base currency).
- Money amounts are `Rational` (exact). Summation pattern in this codebase: sum the raw `Rational`s, then wrap with `unsafeMoney cur <rational>` (there is **no** `Semigroup`/`<>` for `Money`; `addMoney` returns `Either` and is awkward in folds).
- A `TransactionData` has fields `sourceAccountId, targetAccountId, sourceAmount, targetAmount, exchangeRate, description, status, transactionType, date, labels, amendmentCount`. **Allocations are NOT a top-level field** — get them via `allocationsOf td.transactionType :: Maybe Allocations`, or pattern-match `Income allocs` / `Expense allocs`.
- Base-currency conversion of one allocation (in user-account currency) uses the transaction's own leg ratio and is direction-agnostic:
  `base(alloc) = alloc.amount × (externalLeg.amount / regularLeg.amount)`, taken only when `exchangeRate` is `Just` (so `regularLeg.amount > 0` always — it is the sum of strictly-positive allocations). When `exchangeRate` is `Nothing`, `base(alloc) = alloc` unchanged.

### Reference file locations (read before editing)

- API pattern: `src/Web/API/TransactionAPI.hs` (type, server, handlers, `AuthProtect "jwt"`, optional `QueryParam "x" UTCTime`).
- API composition: `src/Web/API.hs` (`type API`, `server`, export list).
- Auth principal: `src/Web/Middleware/Auth.hs` — `AuthenticatedUser { userId :: UserId, email :: Text }`; extract with `user.userId`.
- Service patterns + capability lenses: `src/Application/Services/TransactionService.hs`, `src/Infrastructure/App.hs` (`HasReadModel`, `HasExchangeRateReadModel`, `HasAppConfig`, `AppM = RIO AppEnv`).
- Read models: `src/Application/ReadModels/Transaction.hs` (`getAllTransactions`, `TransactionData`), `src/Application/ReadModels/Account.hs` (`getAllAccounts`, `getAccessibleAccounts`, `AccountData`), `src/Application/ReadModels/Configuration.hs` (`getConfiguration`, `ConfigurationData.baseCurrency`).
- Config helper: `Application.Services.ConfigurationService.getConfigurationForUser :: UserId -> AppM (Either DomainError ConfigurationData)`.
- FX: `src/Application/ReadModels/ExchangeRate.hs` (`lookupHistoricalRate`), provider via `cfg.exchangeRate.provider` (`Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))`).
- Money/Currency helpers: `src/Domain/Core/Types.hs` — `Money(..)`, `unsafeMoney`, `unMoney`, `convert`, `Currency(UAH|USD|EUR|GBP)`, `Allocation { categoryId :: CategoryId, amount :: Money }`, `Allocations { incomes, expenses }`, `allAllocations`, `allocationsOf`, `isCategorised`, `TransactionType(Income|Expense|Transfer|Adjustment)`.
- Error 422: `Web.ErrorMapping.throwDomainError`, `DomainError(ExchangeRateUnavailable Text)` (already mapped to `err422`).
- DTO conventions: `src/Web/Types.hs` — `AllocationResponse.amount :: Money` reuses the domain `Money` JSON instance (`{ "amount": <number>, "currency": "UAH" }`); see how `categoryId :: Text` is rendered in `fromTransactionData`/allocation mapping — reuse that exact rendering.

### Commands

- Build (lib+exe, `-Werror` gate): `cabal build -fci` — MUST stay clean (see the `-fci` gate memory). Quick build: `just build`.
- Run a focused test: `cabal test all --test-option='--match' --test-option="/Application.Services.Reporting/"`.
- Full test suite: `just test`.
- Format + lint before each commit: `just check` (ormolu + hlint).
- After changing `package.yaml`: run `hpack` (or `just build`, which runs it) to regenerate `backend.cabal`.

---

## File structure

- **Create** `src/Web/Types/Reporting.hs`? — NO. Keep DTOs in `src/Web/Types.hs` (existing convention; all `*Response` live there). Add the new DTOs there.
- **Create** `src/Application/Services/ReportingService.hs` — pure aggregation helpers (exported for tests) + `AppM` orchestration functions.
- **Create** `src/Web/API/ReportingAPI.hs` — Servant `ReportingAPI` type, `reportingServer`, handlers, proxy.
- **Modify** `src/Web/API.hs` — compose `ReportingAPI`/`reportingServer` into `API`/`server`; add import + export.
- **Modify** `package.yaml` — (modules are auto-globbed under `src/` and `test/`, so likely **no change needed**; verify by checking whether `source-dirs` uses explicit module lists or globs. If explicit, add the new modules.)
- **Create** `test/Application/Services/ReportingServiceSpec.hs` — unit tests for pure helpers + service.
- **Create** `test/Application/Services/ReportingServicePropertySpec.hs` — QuickCheck invariants.
- **Create** `test/Integration/ReportingWorkflowIntegrationSpec.hs` — end-to-end over the in-memory event store.

> Before Task 1, confirm `package.yaml` autodiscovers modules: open `package.yaml`, check the `library` and `tests` stanzas. If they use `source-dirs: src` with no `exposed-modules:` list (hpack auto-discovery), new files need no manifest edit. If a module list is present, every task that creates a module MUST add it there and re-run `hpack`.

---

## Task 1: Reporting response DTOs

**Files:**
- Modify: `src/Web/Types.hs` (add DTOs near the other `*Response` types)
- Test: `test/Web/ReportingResponseSpec.hs` (create)

- [ ] **Step 1: Write the failing test** — assert the JSON shape reuses `Money` and omits a separate currency field.

Create `test/Web/ReportingResponseSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.ReportingResponseSpec (spec) where

import qualified Data.Aeson as Aeson
import Domain.Core.Types (Currency (UAH), unsafeMoney)
import RIO
import Test.Hspec
import Web.Types
  ( CategorySpend (..),
    IncomeVsExpenseResponse (..),
    SpendingByCategoryResponse (..),
  )

spec :: Spec
spec = describe "Reporting DTOs" $ do
  it "CategorySpend renders amount as a nested Money object" $ do
    let cs = CategorySpend {categoryId = "cat-1", total = unsafeMoney UAH 1234}
        json = Aeson.encode cs
    -- Money instance renders { "amount": <number>, "currency": "UAH" }
    json `shouldSatisfy` (\b -> "\"currency\":\"UAH\"" `isInfixOfBs` b)
    json `shouldSatisfy` (\b -> "\"amount\":1234" `isInfixOfBs` b)

  it "IncomeVsExpenseResponse carries income/expense/net as Money" $ do
    let r = IncomeVsExpenseResponse {income = unsafeMoney UAH 500, expense = unsafeMoney UAH 200, net = unsafeMoney UAH 300}
    Aeson.encode r `shouldSatisfy` (\b -> "\"net\":" `isInfixOfBs` b)

  it "SpendingByCategoryResponse nests categories and a base total" $ do
    let r = SpendingByCategoryResponse {categories = [], total = unsafeMoney UAH 0}
    Aeson.encode r `shouldSatisfy` (\b -> "\"categories\":[]" `isInfixOfBs` b)

isInfixOfBs :: ByteString -> LByteString -> Bool
isInfixOfBs needle hay = needle `isInfixOf` toStrictBytes hay
```

(If `isInfixOf`/`toStrictBytes` ergonomics fight you, simplify to decoding back into a `Value` and inspecting keys — the point is to pin the `Money` nesting, not the byte layout.)

- [ ] **Step 2: Run the test, verify it fails to compile** (types don't exist yet).

Run: `cabal test all --test-option='--match' --test-option="/Reporting DTOs/"`
Expected: compile failure — `SpendingByCategoryResponse` not in scope.

- [ ] **Step 3: Add the DTOs to `src/Web/Types.hs`.** Place beside the other response types. Mirror the existing `instance ToJSON X` (and `FromJSON` where present) style used by `AllocationResponse`.

```haskell
-- | Net spend for one expense category over the requested period, in the
-- base currency. May be ≤ 0 when reimbursements exceed spend.
data CategorySpend = CategorySpend
  { categoryId :: Text,   -- UUID-as-text, rendered exactly like AllocationResponse.categoryId
    total :: Money        -- reuses the domain Money JSON instance
  }
  deriving (Show, Eq, Generic)

instance ToJSON CategorySpend

instance FromJSON CategorySpend

-- | GET /api/reports/spending-by-category
data SpendingByCategoryResponse = SpendingByCategoryResponse
  { categories :: [CategorySpend],
    total :: Money        -- Σ categories[].total, in base currency
  }
  deriving (Show, Eq, Generic)

instance ToJSON SpendingByCategoryResponse

instance FromJSON SpendingByCategoryResponse

-- | GET /api/reports/income-vs-expense (all amounts in base currency)
data IncomeVsExpenseResponse = IncomeVsExpenseResponse
  { income :: Money,
    expense :: Money,
    net :: Money          -- income − expense
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeVsExpenseResponse

instance FromJSON IncomeVsExpenseResponse

-- | One owned account's contribution to net worth.
data AccountNetWorth = AccountNetWorth
  { accountId :: UUID,
    balance :: Money,     -- native balance + native currency
    baseBalance :: Money  -- converted to base currency
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountNetWorth

instance FromJSON AccountNetWorth

-- | GET /api/reports/net-worth
data NetWorthResponse = NetWorthResponse
  { accounts :: [AccountNetWorth],
    total :: Money        -- Σ accounts[].baseBalance, in base currency
  }
  deriving (Show, Eq, Generic)

instance ToJSON NetWorthResponse

instance FromJSON NetWorthResponse
```

Add `CategorySpend (..), SpendingByCategoryResponse (..), IncomeVsExpenseResponse (..), AccountNetWorth (..), NetWorthResponse (..)` to the `Web.Types` export list. (`NoFieldSelectors`/`DuplicateRecordFields` are on project-wide, so the repeated `total`/`balance` field names across records are fine — match how existing DTOs reuse field names.)

- [ ] **Step 4: Run the test, verify it passes.**

Run: `cabal test all --test-option='--match' --test-option="/Reporting DTOs/"`
Expected: PASS.

- [ ] **Step 5: Lint/format, then commit.**

```bash
just check
git add src/Web/Types.hs test/Web/ReportingResponseSpec.hs package.yaml backend.cabal
git commit -m "feat(reporting): response DTOs reusing domain Money (#24)"
```

---

## Task 2: Pure aggregation helpers (the testable core)

**Files:**
- Create: `src/Application/Services/ReportingService.hs` (helpers only this task)
- Test: `test/Application/Services/ReportingServiceSpec.hs` (create)
- Test: `test/Application/Services/ReportingServicePropertySpec.hs` (create)

The pure helpers to implement and export:

```haskell
-- The base-currency leg (Expense: targetAmount; Income: sourceAmount).
externalLeg :: TransactionData -> Money
-- The user-account-currency leg (Expense: sourceAmount; Income: targetAmount).
regularLeg :: TransactionData -> Money
-- Convert one allocation amount (in regularLeg currency) to base currency.
allocationBase :: TransactionData -> Money -> Money
-- Filter to Completed, categorised (Income/Expense) txns in [from,to] touching a visible account.
reportableTxns :: Set AccountId -> Maybe UTCTime -> Maybe UTCTime -> Map TransactionId TransactionData -> [TransactionData]
-- (income, expense, net) base totals; respects reimbursement contra (see spec §4).
aggregateIncomeExpense :: Currency -> [TransactionData] -> (Money, Money, Money)
-- Signed expense-bucket spend per category, base currency.
aggregateSpending :: Currency -> [TransactionData] -> Map CategoryId Money
```

- [ ] **Step 1: Write failing unit tests** in `test/Application/Services/ReportingServiceSpec.hs`.

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.ReportingServiceSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.Services.ReportingService as R
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
import Domain.Transaction.Projection (TransactionStatus (..))
import RIO
import qualified RIO.Time as Time
import Test.Hspec

-- A fixed business date for fixtures.
t0 :: UTCTime
t0 = Time.UTCTime (Time.fromGregorian 2026 6 1) 0

acct :: Word32 -> AccountId
acct n = unsafeAccountId (UUID.fromWords n 0 0 0)

cat :: Word32 -> CategoryId
cat n = unsafeDictionaryEntryId (UUID.fromWords 0 n 0 0)

txid :: Word32 -> TransactionId
txid n = unsafeTransactionId (UUID.fromWords 0 0 n 0)

-- Build a categorised TransactionData directly. `tt` is `Income`/`Expense`
-- carrying allocations; src/tgt are the two legs; rate Nothing ⇒ same-currency.
mkTd :: AccountId -> AccountId -> Money -> Money -> Maybe ExchangeRate -> TransactionType -> TransactionData
mkTd src tgt srcAmt tgtAmt rate tt =
  TransactionData
    { sourceAccountId = src,
      targetAccountId = tgt,
      sourceAmount = srcAmt,
      targetAmount = tgtAmt,
      exchangeRate = rate,
      description = "fixture",
      status = Completed,
      transactionType = tt,
      date = t0,
      labels = mempty,
      amendmentCount = 0
    }

-- Expense (Regular reg → External base). Same-currency when reg ccy == base ccy.
expenseTo :: CategoryId -> Rational -> TransactionData
expenseTo c amt =
  let m = unsafeMoney UAH amt
      tt = Expense (mkExpenseAllocations (Allocation c m :| []))
   in mkTd (acct 1) (acct 9) m m Nothing tt

-- Income reimbursement into the expense bucket (contra) on an Income txn.
reimbursementTo :: CategoryId -> Rational -> TransactionData
reimbursementTo c amt =
  let m = unsafeMoney UAH amt
      -- income with an empty income bucket is invalid; give a tiny income slice
      -- plus the reimbursement so both buckets are populated, summing to target.
      incSlice = Allocation (cat 99) (unsafeMoney UAH 1)
      tt = Income (mkMixedAllocations (incSlice :| []) (Allocation c m :| []))
   in mkTd (acct 9) (acct 1) (unsafeMoney UAH (amt + 1)) (unsafeMoney UAH (amt + 1)) Nothing tt

spec :: Spec
spec = describe "ReportingService pure aggregation" $ do
  it "allocationBase is identity when same-currency (exchangeRate Nothing)" $ do
    let m = unsafeMoney UAH 100
        td = expenseTo (cat 1) 100
    R.allocationBase td m `shouldBe` m

  it "allocationBase scales a cross-currency expense allocation by external/regular" $ do
    -- expense: source=USD 10 (regular leg), target=UAH 400 (base leg) → ratio 40
    let Right er = mkExchangeRate USD UAH 40
        td = mkTd (acct 1) (acct 9) (unsafeMoney USD 10) (unsafeMoney UAH 400) (Just er) (Expense (mkExpenseAllocations (Allocation (cat 1) (unsafeMoney USD 10) :| [])))
    R.allocationBase td (unsafeMoney USD 10) `shouldBe` unsafeMoney UAH 400

  it "spending nets a reimbursement (expense-bucket on an Income txn) down" $ do
    let c = cat 1
        m = R.aggregateSpending UAH [expenseTo c 100, reimbursementTo c 30]
    Map.lookup c m `shouldBe` Just (unsafeMoney UAH 70)

  it "income/expense respects buckets: net = income − expense" $ do
    -- one pure income of 500, one pure expense of 200
    let inc = mkTd (acct 9) (acct 1) (unsafeMoney UAH 500) (unsafeMoney UAH 500) Nothing (Income (mkIncomeAllocations (Allocation (cat 5) (unsafeMoney UAH 500) :| [])))
        (i, e, n) = R.aggregateIncomeExpense UAH [inc, expenseTo (cat 2) 200]
    i `shouldBe` unsafeMoney UAH 500
    e `shouldBe` unsafeMoney UAH 200
    n `shouldBe` unsafeMoney UAH 300

  it "reportableTxns drops Pending/Cancelled, Transfers, and out-of-range" $ do
    let visible = Set.fromList [acct 1, acct 9]
        completed = expenseTo (cat 1) 100
        pendingTd = completed {status = Pending}
        transferTd = mkTd (acct 1) (acct 2) (unsafeMoney UAH 5) (unsafeMoney UAH 5) Nothing Transfer
        m = Map.fromList [(txid 1, completed), (txid 2, pendingTd), (txid 3, transferTd)]
    map (.transactionType) (R.reportableTxns visible Nothing Nothing m)
      `shouldSatisfy` all isCategorised
    length (R.reportableTxns visible Nothing Nothing m) `shouldBe` 1
```

> Verify exact names while writing: `unsafeAccountId`, `unsafeTransactionId`, `unsafeDictionaryEntryId`, `mkExpenseAllocations`/`mkIncomeAllocations`/`mkMixedAllocations` (return `Allocations`, total — no `Either`), `mkExchangeRate` (returns `Either Text`), and the `:|` NonEmpty constructor (`import RIO.NonEmpty` or `Data.List.NonEmpty`). There is **no `Arbitrary TransactionData`** and no public smart constructor — the record constructor above (exported from `Application.ReadModels.Transaction`) is the way. `genIdentityAmendInputs` in `test/Testkit/Generators.hs` (~lines 493–529) is the reference for a known-good hand-built `TransactionData` if a field's type surprises you.

- [ ] **Step 2: Run, verify fail** (module/functions absent).

Run: `cabal test all --test-option='--match' --test-option="/ReportingService pure aggregation/"`
Expected: compile failure.

- [ ] **Step 3: Implement the helpers** in `src/Application/Services/ReportingService.hs`.

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.ReportingService
  ( -- pure helpers (exported for tests)
    externalLeg,
    regularLeg,
    allocationBase,
    reportableTxns,
    aggregateIncomeExpense,
    aggregateSpending,
    -- NOTE: the AppM service functions (spendingByCategory, incomeVsExpense,
    -- netWorth) are NOT exported here yet. Exporting a name with no top-level
    -- binding is a compile error, and Task 2's commit runs `cabal build -fci`.
    -- Each is added to THIS export list in the task that defines it (Task 3
    -- adds spendingByCategory + incomeVsExpense; Task 4 adds netWorth).
  )
where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Core.Types
import Domain.Transaction.Projection (TransactionStatus (..))
import RIO
-- (AppM-related imports added in Tasks 3-4)

externalLeg :: TransactionData -> Money
externalLeg td = case td.transactionType of
  Expense _ -> td.targetAmount
  Income _ -> td.sourceAmount
  _ -> td.targetAmount -- not reached for categorised txns

regularLeg :: TransactionData -> Money
regularLeg td = case td.transactionType of
  Expense _ -> td.sourceAmount
  Income _ -> td.targetAmount
  _ -> td.sourceAmount

allocationBase :: TransactionData -> Money -> Money
allocationBase td alloc = case td.exchangeRate of
  Nothing -> alloc -- same currency: regular leg already in base currency
  Just _ ->
    let ext = externalLeg td
        reg = regularLeg td
        ratio = unMoney ext / unMoney reg -- reg > 0: it is Σ of positive allocations
     in unsafeMoney ext.currency (unMoney alloc * ratio)

reportableTxns ::
  Set AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Map TransactionId TransactionData ->
  [TransactionData]
reportableTxns visible mFrom mTo = filter keep . Map.elems
  where
    keep td =
      td.status == Completed
        && isCategorised td.transactionType
        && (Set.member td.sourceAccountId visible || Set.member td.targetAccountId visible)
        && maybe True (<= td.date) mFrom
        && maybe True (td.date <=) mTo

aggregateIncomeExpense :: Currency -> [TransactionData] -> (Money, Money, Money)
aggregateIncomeExpense base txs =
  let incomeR = sum [unMoney (allocationBase td a.amount) | td <- txs, Income allocs <- [td.transactionType], a <- allocs.incomes]
      expensePos = [unMoney (allocationBase td a.amount) | td <- txs, Expense allocs <- [td.transactionType], a <- allocs.expenses]
      expenseNeg = [negate (unMoney (allocationBase td a.amount)) | td <- txs, Income allocs <- [td.transactionType], a <- allocs.expenses]
      expenseR = sum (expensePos ++ expenseNeg)
   in (unsafeMoney base incomeR, unsafeMoney base expenseR, unsafeMoney base (incomeR - expenseR))

aggregateSpending :: Currency -> [TransactionData] -> Map CategoryId Money
aggregateSpending base txs =
  let pos = [(a.categoryId, unMoney (allocationBase td a.amount)) | td <- txs, Expense allocs <- [td.transactionType], a <- allocs.expenses]
      neg = [(a.categoryId, negate (unMoney (allocationBase td a.amount))) | td <- txs, Income allocs <- [td.transactionType], a <- allocs.expenses]
   in Map.map (unsafeMoney base) (Map.fromListWith (+) (pos ++ neg))
```

> Verify the exact import path/constructors of `TransactionStatus` (`Completed`) and `CategoryId` (alias of `DictionaryEntryId`) while implementing; adjust imports to compile clean under `-Werror` (`cabal build -fci`). Remove unused imports.

- [ ] **Step 4: Run, verify pass.**

Run: `cabal test all --test-option='--match' --test-option="/ReportingService pure aggregation/"`
Expected: PASS.

- [ ] **Step 5: Write the QuickCheck property tests** in `test/Application/Services/ReportingServicePropertySpec.hs`.

Properties (reuse generators from `Testkit.Generators`; for `TransactionData`, write a local `genReportableTxn` modeled on `genIdentityAmendInputs`):

```haskell
-- 1. Exactness (no Rational drift): for any categorised txn, the sum of its
--    allocations converted to base equals its external leg amount.
prop "Σ allocationBase == externalLeg" $ \txn ->
  let allocs = maybe [] allAllocations (allocationsOf txn.transactionType)
      summed = sum [unMoney (R.allocationBase txn a.amount) | a <- allocs]
   in summed === unMoney (R.externalLeg txn)

-- 2. Conservation: net == income − expense for any txn list.
prop "net == income − expense" $ \txns ->
  let (i, e, n) = R.aggregateIncomeExpense UAH txns
   in unMoney n === unMoney i - unMoney e

-- 3. Same-currency invariance: when exchangeRate is Nothing, allocationBase is identity.
prop "same-currency allocationBase is identity" $ \txnSameCcy alloc ->
  R.allocationBase txnSameCcy alloc === alloc
```

> `genReportableTxn` must produce internally consistent txns: pick a kind, currencies, a positive regular-leg total, allocations summing to it (`genAllocationListSummingTo`), and a matching external leg (= regular × rate) with `exchangeRate = Nothing` iff currencies match. Without that consistency, property 1 is meaningless.

- [ ] **Step 6: Run properties, verify pass.**

Run: `cabal test all --test-option='--match' --test-option="/ReportingService pure aggregation/"` and the property module's describe label.
Expected: PASS (100 cases each).

- [ ] **Step 7: Confirm the `-Werror` gate is clean, then commit.**

```bash
cabal build -fci   # MUST be clean for lib+exe
just check
git add src/Application/Services/ReportingService.hs test/Application/Services/ReportingServiceSpec.hs test/Application/Services/ReportingServicePropertySpec.hs package.yaml backend.cabal
git commit -m "feat(reporting): pure aggregation helpers with property tests (#24)"
```

---

## Task 3: Service orchestration — spending-by-category & income-vs-expense

**Files:**
- Modify: `src/Application/Services/ReportingService.hs` (add `AppM` functions + `resolveBaseCurrency`, `visibleAccounts`)
- Test: `test/Integration/ReportingWorkflowIntegrationSpec.hs` (create; covers these two end-to-end)

- [ ] **Step 1: Write a failing integration test** for the two period reports.

Create `test/Integration/ReportingWorkflowIntegrationSpec.hs`. Mirror `test/Integration/TransferWorkflowSpec.hs` for setup: `createTestAppEnv`, append `CreateAccount` commands and income/expense commands via `applyAccountCommand`/`applyTransactionCommand env.eventStoreWriter env.eventStoreReader`, then run the service inside `runRIO env`.

```haskell
-- After seeding: one Regular USD account, one income (salary 500) and one expense (rent 200, same ccy),
-- assert:
result <- runRIO env (ReportingService.incomeVsExpense userId Nothing Nothing)
let (inc, expn, net) = result
inc `shouldBe` unsafeMoney baseCcy 500
expn `shouldBe` unsafeMoney baseCcy 200
net `shouldBe` unsafeMoney baseCcy 300
```

(Use `createTestAppEnvWithProcessManager` if you rely on the saga to drive transactions to `Completed`; otherwise issue the completion commands manually. Reports only count `Completed` txns — make sure the seeded txns reach `Completed` in the read model before asserting.)

- [ ] **Step 2: Run, verify fail** (`spendingByCategory`/`incomeVsExpense` not defined).

Run: `cabal test all --test-option='--match' --test-option="/Reporting workflow/"`
Expected: compile failure / unresolved name.

- [ ] **Step 3: Implement the `AppM` functions** (append to `ReportingService.hs`; add `spendingByCategory, incomeVsExpense,` to the module export list now that they are defined; add imports for `view`, the read-model lenses, `getAllTransactions`, `getAccessibleAccounts`, `getConfigurationForUser`).

```haskell
import Application.ReadModels.Account (getAccessibleAccounts)
import Application.ReadModels.Transaction (getAllTransactions)
import qualified Application.Services.ConfigurationService as ConfigurationService
import Infrastructure.App (AppM, accountReadModelL, transactionReadModelL)

-- baseCurrency for the user; defaults to USD if config somehow absent (mirrors AuthService).
resolveBaseCurrency :: UserId -> AppM Currency
resolveBaseCurrency userId = do
  res <- ConfigurationService.getConfigurationForUser userId
  pure $ either (const USD) (\c -> c.baseCurrency) res

visibleAccounts :: UserId -> AppM (Set AccountId)
visibleAccounts userId = do
  accountRM <- view accountReadModelL
  accessible <- getAccessibleAccounts accountRM userId
  pure $ Set.fromList [aid | (aid, _, _) <- accessible]

spendingByCategory :: UserId -> Maybe UTCTime -> Maybe UTCTime -> AppM (Money, [(CategoryId, Money)])
spendingByCategory userId mFrom mTo = do
  base <- resolveBaseCurrency userId
  visible <- visibleAccounts userId
  txRM <- view transactionReadModelL
  txs <- getAllTransactions txRM
  let perCat = aggregateSpending base (reportableTxns visible mFrom mTo txs)
      totalR = sum [unMoney m | m <- Map.elems perCat]
  pure (unsafeMoney base totalR, Map.toList perCat)

incomeVsExpense :: UserId -> Maybe UTCTime -> Maybe UTCTime -> AppM (Money, Money, Money)
incomeVsExpense userId mFrom mTo = do
  base <- resolveBaseCurrency userId
  visible <- visibleAccounts userId
  txRM <- view transactionReadModelL
  txs <- getAllTransactions txRM
  pure $ aggregateIncomeExpense base (reportableTxns visible mFrom mTo txs)
```

> Verify exact lens names (`accountReadModelL`, `transactionReadModelL`) and the `getConfigurationForUser` return type while wiring. Adjust the export list (already lists these names from Task 2).

- [ ] **Step 4: Run, verify pass.**

Run: `cabal test all --test-option='--match' --test-option="/Reporting workflow/"`
Expected: PASS.

- [ ] **Step 5: `-fci` clean, lint, commit.**

```bash
cabal build -fci
just check
git add src/Application/Services/ReportingService.hs test/Integration/ReportingWorkflowIntegrationSpec.hs package.yaml backend.cabal
git commit -m "feat(reporting): spending-by-category & income-vs-expense services (#24)"
```

---

## Task 4: Service orchestration — net-worth (owner-scoped, FX, 422)

**Files:**
- Modify: `src/Application/Services/ReportingService.hs` (add `netWorth`)
- Test: `test/Application/Services/ReportingServiceSpec.hs` (owner-scope/filter units) + `test/Integration/ReportingWorkflowIntegrationSpec.hs` (FX + 422)

- [ ] **Step 1: Write failing tests.**
  - Unit: a pure `ownedRegularOpened :: UserId -> [(AccountId, AccountData)] -> [(AccountId, AccountData)]` helper excludes External, Closed, and not-created-by-user accounts.
  - Integration: seed an owned EUR account + a published EUR→base rate, assert `netWorth` total is the converted sum; then seed an owned account in a currency with **no** rate and assert `netWorth` throws (catch the thrown `err422` / `ExchangeRateUnavailable`). Also seed an account shared *to* the user (created by someone else) and assert it is **excluded** from the total but its transactions still appear in `incomeVsExpense`.

- [ ] **Step 2: Run, verify fail.**

Run: `cabal test all --test-option='--match' --test-option="/net worth/"`
Expected: fail.

> **Layering (read first):** `Application.*` MUST NOT import `Web.*` — that creates the import cycle the project warns about. `throwDomainError` lives in `Web.ErrorMapping`, and it *would typecheck* in `AppM` (`MonadIO m => DomainError -> m a`), so the **compiler will not catch this** — only the layering rule does. Therefore `netWorth` returns `AppM (Either DomainError ...)` and the **handler** (Task 5) throws. This mirrors how `TransactionService` surfaces `ExchangeRateUnavailable` (returns `Left`, never imports Web). Spending/income services stay non-`Either` (they cannot fail).

- [ ] **Step 3: Implement** (add `netWorth,` to the module export list now that it is defined).

```haskell
import Application.ReadModels.Account (getAllAccounts)
import Application.ReadModels.ExchangeRate (lookupHistoricalRate)
import Control.Monad.Except (runExceptT, throwError)
import Data.Time (getCurrentTime, utctDay)
import Domain.Core.Errors (DomainError (..))
import Infrastructure.App (appConfigL, exchangeRateReadModelL)
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
-- NO import of Web.ErrorMapping — layering.

ownedRegularOpened :: UserId -> [(AccountId, AccountData)] -> [(AccountId, AccountData)]
ownedRegularOpened userId =
  filter (\(_, ad) -> ad.createdBy == userId && isRegular ad.accountType && ad.status == Opened)
  where
    isRegular (Regular _) = True
    isRegular External = False

netWorth :: UserId -> AppM (Either DomainError (Money, [(AccountId, Money, Money)]))
netWorth userId = do
  base <- resolveBaseCurrency userId
  accountRM <- view accountReadModelL
  allAccts <- getAllAccounts accountRM
  let owned = ownedRegularOpened userId (Map.toList allAccts)
  rm <- view exchangeRateReadModelL
  cfg <- view appConfigL
  now <- liftIO getCurrentTime
  let provider = cfg.exchangeRate.provider
      day = utctDay now
  runExceptT $ do
    rows <- forM owned $ \(aid, ad) -> do
      baseBal <- toBase rm provider day base ad.balance
      pure (aid, ad.balance, baseBal)
    pure (unsafeMoney base (sum [unMoney bb | (_, _, bb) <- rows]), rows)
  where
    -- runs in ExceptT DomainError AppM; lookupHistoricalRate is MonadIO so lift via liftIO-friendly context
    toBase rm provider day base bal
      | bal.currency == base = pure bal
      | otherwise = do
          mer <- lookupHistoricalRate rm provider day bal.currency base
          case mer of
            Just er -> pure (convert er bal)
            Nothing ->
              throwError . ExchangeRateUnavailable $
                "No rate for " <> tshow bal.currency <> " -> " <> tshow base
```

> Make sure `toBase` typechecks inside `runExceptT`'s `ExceptT DomainError AppM` monad: `lookupHistoricalRate` is `MonadIO m => ... -> m (Maybe ExchangeRate)`, which unifies with `ExceptT DomainError AppM` (it has a `MonadIO` instance). If the inference fights you, give `toBase` an explicit type `... -> ExceptT DomainError AppM Money`. Use `throwError` from `Control.Monad.Except`, NOT `throwDomainError`.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: `-fci` clean, lint, commit.**

```bash
cabal build -fci
just check
git add -A
git commit -m "feat(reporting): owner-scoped net-worth with base-currency normalization (#24)"
```

---

## Task 5: HTTP surface — `ReportingAPI` + wiring

**Files:**
- Create: `src/Web/API/ReportingAPI.hs`
- Modify: `src/Web/API.hs`

- [ ] **Step 1: Write a failing test** (integration, HTTP-level optional). At minimum, add an assertion in the integration spec that the wired `server` typechecks and a handler returns the expected DTO when called through `runRIO env (spendingByCategoryHandler authUser Nothing Nothing)`. (Full WAI request tests are optional; the service is already covered.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Create `src/Web/API/ReportingAPI.hs`.** Mirror `Web/API/TransactionAPI.hs` exactly.

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.API.ReportingAPI
  ( ReportingAPI,
    reportingAPI,
    reportingServer,
    spendingByCategoryHandler,
    incomeVsExpenseHandler,
    netWorthHandler,
  )
where

import qualified Application.Services.ReportingService as ReportingService
import Data.Time (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.Text as T
import Domain.Core.Types (AccountId, CategoryId, unAccountId, unDictionaryEntryId)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( AccountNetWorth (..),
    CategorySpend (..),
    IncomeVsExpenseResponse (..),
    NetWorthResponse (..),
    SpendingByCategoryResponse (..),
  )

type ReportingAPI =
  AuthProtect "jwt"
    :> "api" :> "reports" :> "spending-by-category"
    :> QueryParam "from" UTCTime
    :> QueryParam "to" UTCTime
    :> Get '[JSON] SpendingByCategoryResponse
    :<|> AuthProtect "jwt"
      :> "api" :> "reports" :> "income-vs-expense"
      :> QueryParam "from" UTCTime
      :> QueryParam "to" UTCTime
      :> Get '[JSON] IncomeVsExpenseResponse
    :<|> AuthProtect "jwt"
      :> "api" :> "reports" :> "net-worth"
      :> Get '[JSON] NetWorthResponse

reportingAPI :: Proxy ReportingAPI
reportingAPI = Proxy

reportingServer :: ServerT ReportingAPI AppM
reportingServer =
  spendingByCategoryHandler
    :<|> incomeVsExpenseHandler
    :<|> netWorthHandler

spendingByCategoryHandler :: AuthenticatedUser -> Maybe UTCTime -> Maybe UTCTime -> AppM SpendingByCategoryResponse
spendingByCategoryHandler user mFrom mTo = do
  (total, cats) <- ReportingService.spendingByCategory user.userId mFrom mTo
  pure
    SpendingByCategoryResponse
      { categories = [CategorySpend {categoryId = renderCategoryId cid, total = m} | (cid, m) <- cats],
        total = total
      }

incomeVsExpenseHandler :: AuthenticatedUser -> Maybe UTCTime -> Maybe UTCTime -> AppM IncomeVsExpenseResponse
incomeVsExpenseHandler user mFrom mTo = do
  (income, expense, net) <- ReportingService.incomeVsExpense user.userId mFrom mTo
  pure IncomeVsExpenseResponse {income = income, expense = expense, net = net}

netWorthHandler :: AuthenticatedUser -> AppM NetWorthResponse
netWorthHandler user = do
  result <- ReportingService.netWorth user.userId   -- AppM (Either DomainError ...) per Task 4 note
  (total, rows) <- either throwDomainError pure result
  pure
    NetWorthResponse
      { accounts = [AccountNetWorth {accountId = renderAccountId aid, balance = bal, baseBalance = bb} | (aid, bal, bb) <- rows],
        total = total
      }

-- These are NOT exported helpers in Web.Types — the category rendering is a
-- `where`-local inside `toAllocationResponse`. Inline the same expressions:
renderCategoryId :: CategoryId -> Text
renderCategoryId cid = T.pack (UUID.toString (unDictionaryEntryId cid))
  -- imports: import qualified Data.Text as T; import qualified Data.UUID as UUID;
  --          unDictionaryEntryId from Domain.Core.Types

renderAccountId :: AccountId -> UUID
renderAccountId = unAccountId   -- unAccountId :: AccountId -> UUID, from Domain.Core.Types
```

> The exact category expression `T.pack (UUID.toString (unDictionaryEntryId cid))` matches `Web.Types.toAllocationResponse`'s local rendering — copy it verbatim so the wire format is identical to existing allocation DTOs. Confirm `unDictionaryEntryId`/`unAccountId` are exported from `Domain.Core.Types` while wiring; adjust if the unwrap name differs.

- [ ] **Step 4: Wire into `src/Web/API.hs`** — add `import Web.API.ReportingAPI`, add `Web.API.ReportingAPI` to the module export list, add `:<|> ReportingAPI` to `type API` and `:<|> reportingServer` to `server` **at the same position**.

- [ ] **Step 5: Run build + tests, verify pass.**

Run: `cabal build -fci` then `cabal test all --test-option='--match' --test-option="/Reporting/"`
Expected: build clean, tests PASS.

- [ ] **Step 6: Lint, commit.**

```bash
just check
git add -A
git commit -m "feat(reporting): ReportingAPI endpoints wired into the server (#24)"
```

---

## Task 6: Full verification pass

- [ ] **Step 1:** `cabal build -fci` — confirm lib+exe `-Werror`-clean.
- [ ] **Step 2:** `just test` — confirm the whole suite passes (including the new property/unit/integration specs).
- [ ] **Step 3:** `just check` — ormolu + hlint clean (no new suppressions).
- [ ] **Step 4:** Manually smoke-test against a running server if convenient (use the `verify`/`run` skill or the existing test scripts): start the app, register a user, create accounts + income/expense, and `curl` each of the three endpoints with a bearer token; confirm JSON shape (`Money` nesting, base currency) and the 422 on a missing net-worth rate.
- [ ] **Step 5:** Update `docs/specs/2026-06-23-minimal-reporting-design.md` frontmatter `status: draft → completed` if the team convention is to flip it on merge; otherwise leave for the PR. Commit any doc change.
- [ ] **Step 6:** Open the PR per the user's git conventions: branch `feat/minimal-reporting`, Conventional-Commits title, base `master`, linking issue #24. Do **not** push/PR unless the user asks.

---

## Notes / risks

- **Layering** (Task 4): never import `Web.*` from `Application.*`. Net-worth returns `Either DomainError ...`; the handler throws. Verified pattern: `TransactionService` returns `Left` and handlers map.
- **`reg > 0` guarantee** (Task 2): division in `allocationBase` is only reached for `Just exchangeRate`, where the regular leg = Σ strictly-positive allocations > 0. Documented; do not add a partial guard that returns a bogus default — if you want belt-and-suspenders, treat `reg == 0` as same-currency identity, never `error`.
- **`-fci` masking**: the incremental `.o` cache can hide `-Werror` regressions. If in doubt, `just rebuild` before trusting a clean `-fci`.
- **Read-model staleness**: reports read in-memory projections (eventually consistent). In integration tests, ensure events have been projected (drive transactions to `Completed`) before asserting.
- **`package.yaml`**: if module lists are explicit (not globbed), every created module must be registered and `hpack` re-run, or the build won't see it.
