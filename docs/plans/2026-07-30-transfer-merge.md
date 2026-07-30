# Transfer-Merge (Income + Expense → Transfer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user merge an existing Income + Expense pair (different accounts, equal amount, same currency, within a relaxed time window) into a single Transfer via the existing `POST /api/transactions/:id/merge` endpoint.

**Architecture:** Reuse the existing `InitiateTransactionMerge` command/event and `TransactionMergeManager` saga unchanged in shape. `TransactionService.mergeTransactions` gains a branch: when the target is an Income and its single source is an Expense, it builds a Transfer amend payload (source = expense's account, target = income's account, no allocations/contact) instead of the same-kind allocation merge. The generic "same movement?" criterion is extracted from bank import into a new pure Domain module `Domain.Transaction.TransferMatch` and shared by both import (strict window) and merge (relaxed window). The saga's amend leg gains an `allowOverdraft` flag (default False) so the merge-originated amend bypasses the balance guard during the transient double-debit.

**Tech Stack:** Haskell (GHC 9.10), RIO prelude, CQRS/event-sourcing (Eventium), Servant, Hspec + QuickCheck. Spec: `docs/specs/2026-07-30-transfer-merge-design.md`.

**Conventions (read before starting):**
- Enter the Nix shell first: `nix develop`. Build with `just build`, test with `just test`, format `just format`, lint `just lint`. `-fci` (`-Werror`) is enforced.
- `NoImplicitPrelude` (RIO), `NoFieldSelectors`, `DuplicateRecordFields`, `OverloadedRecordDot`, `StrictData`. Access fields via `record.field`; construct records explicitly (no positional). Never export data constructors via smart-constructor modules — but the Transaction command/event modules DO export constructors via `(..)` (see below); match the file you edit.
- Commands/events are registered in TH name lists (`transactionCommands` in `Commands.hs:63-83`; the analogous list in `Events.hs:77-85`). We add **no** new commands/events, so those lists are untouched.
- Ormolu splits `<$>`/`&&` operator chains onto their own lines in RIO modules — let it; run `just format` before every commit.
- Run specific tests: `cabal test all --test-option='--match' --test-option="/PATTERN/"`.
- After finishing, a definitive `-Werror` check needs `just rebuild` (warm `.o` cache masks regressions).

**File map (what each task creates/modifies):**
- Create `src/Domain/Transaction/TransferMatch.hs` — pure shared match predicate (Task 1).
- Modify `src/Infrastructure/Banking/Provider.hs` — default matcher delegates to `isTransferMatch` (Task 2).
- Modify `src/Domain/Transaction/Commands.hs`, `Events.hs`, `CommandHandler.hs` — add `allowOverdraft` to amend command+event (Task 3).
- Modify `src/Application/ProcessManagers/TransactionAmendmentManager.hs`, `TransactionMergeManager.hs` — thread/set `allowOverdraft` (Task 4).
- Modify `src/Domain/Core/Errors.hs` — new transfer-merge error constructors + render arms (Task 5).
- Modify `src/Application/Services/TransactionService.hs` — transfer-merge branch (Task 6).
- Modify `src/Application/Services/TransactionHistoryService.hs` — merge + relation history entries (Task 7).
- Tests under `test/Domain/Transaction/`, `test/Application/Services/`, `test/Integration/` (Tasks 1,3,6,7,8).

---

## Task 1: `Domain.Transaction.TransferMatch` — shared match predicate

**Files:**
- Create: `src/Domain/Transaction/TransferMatch.hs`
- Test: `test/Domain/Transaction/TransferMatchPropertySpec.hs`

- [ ] **Step 1: Write the failing property spec**

Create `test/Domain/Transaction/TransferMatchPropertySpec.hs` (module auto-discovered by hspec-discover; mirror the style of `test/Application/Services/BankImport/TransferPairingPropertySpec.hs`):

```haskell
module Domain.Transaction.TransferMatchPropertySpec (spec) where

import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Transaction.TransferMatch
  ( TransferDirection (..),
    TransferLeg (..),
    isTransferMatch,
  )
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- A fixed 5-minute window for the properties.
window :: NominalDiffTime
window = 300

genLeg :: Gen (TransferLeg Int)
genLeg = do
  dir <- elements [DebitLeg, CreditLeg]
  mag <- elements [50, 100, 250] :: Gen Rational
  cur <- elements [840, 980]
  secs <- choose (1700000000, 1700002000) :: Gen Integer
  pure (TransferLeg dir mag cur (posixSecondsToUTCTime (fromIntegral secs)))

spec :: Spec
spec = describe "Domain.Transaction.TransferMatch.isTransferMatch" $ do
  prop "is symmetric" $
    forAll genLeg $ \a ->
      forAll genLeg $ \b ->
        isTransferMatch window a b === isTransferMatch window b a

  prop "never matches two legs of the same direction" $
    forAll genLeg $ \a ->
      forAll genLeg $ \b ->
        a.direction == b.direction ==> not (isTransferMatch window a b)

  prop "requires equal magnitude" $
    forAll genLeg $ \a ->
      forAll genLeg $ \b ->
        a.magnitude /= b.magnitude ==> not (isTransferMatch window a b)

  prop "requires equal currency" $
    forAll genLeg $ \a ->
      forAll genLeg $ \b ->
        a.currency /= b.currency ==> not (isTransferMatch window a b)

  it "matches an opposite-direction, equal-magnitude, same-currency pair at the window boundary" $ do
    let t0 = posixSecondsToUTCTime 1700000000
        t1 = posixSecondsToUTCTime 1700000300 -- exactly +300s
        a = TransferLeg DebitLeg 100 (840 :: Int) t0
        b = TransferLeg CreditLeg 100 840 t1
    isTransferMatch window a b `shouldBe` True

  it "rejects a pair just outside the window" $ do
    let t0 = posixSecondsToUTCTime 1700000000
        t1 = posixSecondsToUTCTime 1700000301 -- +301s
        a = TransferLeg DebitLeg 100 (840 :: Int) t0
        b = TransferLeg CreditLeg 100 840 t1
    isTransferMatch window a b `shouldBe` False
```

- [ ] **Step 2: Run the spec, verify it fails to compile (module missing)**

Run: `cabal test all --test-option='--match' --test-option="/TransferMatch/"`
Expected: build error — `Could not find module 'Domain.Transaction.TransferMatch'`.

- [ ] **Step 3: Create the module**

Create `src/Domain/Transaction/TransferMatch.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Domain.Transaction.TransferMatch
-- Description : Pure, provider-independent criterion for "are these two legs the
--               same money movement?" — shared by bank-import internal-transfer
--               detection and the manual income+expense → transfer merge.
--
-- A movement is one debit leg on one account and one credit leg on another, of
-- equal magnitude and currency, close in time. The type is parameterised over the
-- currency representation @c@ (bank legs use the ISO numeric code 'Int'; domain
-- legs use 'Domain.Core.Types.Currency') because the two are never compared
-- cross-side — each call site matches like-with-like.
module Domain.Transaction.TransferMatch
  ( TransferDirection (..),
    TransferLeg (..),
    isTransferMatch,
  )
where

import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import RIO

-- | Which side of a movement a leg is: money leaving (debit) or arriving (credit).
data TransferDirection = DebitLeg | CreditLeg
  deriving (Show, Eq)

-- | A normalised transfer leg. @magnitude@ is the absolute amount in major units;
-- @currency@ is any 'Eq' token consistent within a call site; @time@ is when it
-- occurred.
data TransferLeg c = TransferLeg
  { direction :: TransferDirection,
    magnitude :: Rational,
    currency :: c,
    time :: UTCTime
  }
  deriving (Show, Eq)

-- | True when @a@ and @b@ are opposite-direction legs of the same movement:
-- opposite directions, equal magnitude, equal currency, and within @window@ of
-- each other. Symmetric in its two leg arguments.
isTransferMatch :: (Eq c) => NominalDiffTime -> TransferLeg c -> TransferLeg c -> Bool
isTransferMatch window a b =
  a.direction /= b.direction
    && a.magnitude == b.magnitude
    && a.currency == b.currency
    && abs (diffUTCTime a.time b.time) <= window
```

- [ ] **Step 4: Format, run the spec, verify it passes**

Run: `just format && cabal test all --test-option='--match' --test-option="/TransferMatch/"`
Expected: PASS (all props + both examples).

- [ ] **Step 5: Verify no LiquidHaskell regression**

This project expects LH refinements on domain types, but `TransferMatch` is a total pure predicate over primitives. Run `just build` and confirm the LH pass (if any runs in-build) does not reject the module. If it demands refinements, add a minimal `{-@ measure @-}`-free module (the functions are total; no smart constructors needed) — do NOT add speculative refinements.

Run: `just build`
Expected: builds clean, no `-Werror`/LH failure.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Transaction/TransferMatch.hs test/Domain/Transaction/TransferMatchPropertySpec.hs
git commit -m "feat(transaction): shared TransferMatch criterion for import + merge"
```

---

## Task 2: Bank import default matcher delegates to `isTransferMatch`

Extract the generic criterion out of `defaultTransferMatcher` so import reuses the shared predicate. Behaviour is unchanged — existing `#143` tests are the regression guard.

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs:163-185`
- Existing tests (must stay green): `test/Application/Services/BankImport/TransferPairingSpec.hs`, `TransferPairingPropertySpec.hs`, `test/Infrastructure/Banking/TransferMatcherSpec.hs`

- [ ] **Step 1: Run the existing matcher tests to confirm the green baseline**

Run: `cabal test all --test-option='--match' --test-option="/TransferMatcher/" --test-option='--match' --test-option="/pairInternalTransfers/"`
Expected: PASS (baseline before refactor).

- [ ] **Step 2: Rewrite `defaultTransferMatcher` to project + delegate**

In `src/Infrastructure/Banking/Provider.hs`, add an import at the top with the others:

```haskell
import Domain.Transaction.TransferMatch (TransferDirection (..), TransferLeg (..), isTransferMatch)
```

Replace `defaultTransferMatcher` (lines 169-179) with a version that projects `BankTransaction → TransferLeg Int` and calls the shared predicate. Keep `defaultTransferPairingWindow = 300` (lines 163-164) unchanged:

```haskell
-- | Project a bank transaction onto a normalised transfer leg. Sign gives
-- direction; the ISO numeric currency code is the match token.
bankTransactionLeg :: BankTransaction -> TransferLeg Int
bankTransactionLeg tx =
  TransferLeg
    { direction = if tx.amount < 0 then DebitLeg else CreditLeg,
      magnitude = abs tx.amount,
      currency = tx.currencyCode,
      time = tx.time
    }

defaultTransferMatcher :: NominalDiffTime -> TransferMatcher
defaultTransferMatcher window =
  TransferMatcher $ \a b ->
    isTransferMatch window (bankTransactionLeg a) (bankTransactionLeg b)
```

Note: the old matcher compared `signum a.amount /= signum b.amount`; the new one uses `direction /= direction` from the sign. For any non-zero amount these agree. Zero-amount bank legs do not occur in statements (and the old `abs a.amount == abs b.amount` would have matched two zeros regardless of sign — the new version treats a zero as `CreditLeg`, so two zeros no longer match; this is strictly more correct and not exercised by real data).

- [ ] **Step 3: Format, run the matcher + pairing tests**

Run: `just format && cabal test all --test-option='--match' --test-option="/TransferMatcher/" --test-option='--match' --test-option="/pairInternalTransfers/" --test-option='--match' --test-option="/PrivatBank/"`
Expected: PASS — identical behaviour, plus PrivatBank matcher (which delegates to `defaultTransferMatcher`) still green.

- [ ] **Step 4: Commit**

```bash
git add src/Infrastructure/Banking/Provider.hs
git commit -m "refactor(banking): default transfer matcher delegates to shared TransferMatch"
```

---

## Task 3: Add `allowOverdraft` to the amend command + event

The amend leg must be able to skip the balance guard. Add the flag to the command, the event, and the command→event handler. Adding a record field breaks every construction site at once, so Step 3 updates them all in one pass.

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs:324-343` (add field)
- Modify: `src/Domain/Transaction/Events.hs:242-263` (add field)
- Modify: `src/Domain/Transaction/CommandHandler.hs:347-383` (map command→event)
- Modify all other construction sites (see Step 3)
- Test: `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs`

- [ ] **Step 1: Write the failing handler test**

Add to `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` an assertion that the emitted `TransactionAmendmentInitiated` carries `allowOverdraft` from the command. Mirror the file's existing style (find an existing amendment test and copy its arrange/act). The new `it`:

```haskell
  it "carries allowOverdraft from the amend command into the emitted event" $ do
    -- arrange: a Completed transfer aggregate `tx` (reuse the file's existing fixture)
    let cmd = <existing valid InitiateTransactionAmendment fixture> {allowOverdraft = True}
    case handleTransactionCommand tx (InitiateTransactionAmendmentTransactionCommand cmd) of
      Right [TransactionAmendmentInitiatedTransactionEvent evt] ->
        evt.allowOverdraft `shouldBe` True
      other -> expectationFailure ("unexpected: " <> show other)
```

- [ ] **Step 2: Run it, verify it fails to compile (`allowOverdraft` not a field)**

Run: `cabal test all --test-option='--match' --test-option="/carries allowOverdraft/"`
Expected: build error — `allowOverdraft` is not a field of `InitiateTransactionAmendment`/`TransactionAmendmentInitiated`.

- [ ] **Step 3: Add the field everywhere**

1. `src/Domain/Transaction/Commands.hs` — in `InitiateTransactionAmendment` (after `by :: UserId`, or before it; keep `by` last for consistency with siblings — place `allowOverdraft` before `by`):

```haskell
    -- | Skip the source-account balance guard on the amend's debit. Default
    -- 'False' for user-initiated amendments; the merge saga sets 'True' because
    -- a merge only reshapes already-settled transactions.
    allowOverdraft :: Bool,
    by :: UserId
```

2. `src/Domain/Transaction/Events.hs` — the same field in `TransactionAmendmentInitiated` (before `by :: UserId`).

3. `src/Domain/Transaction/CommandHandler.hs` — in the amendment handler's event construction (lines ~360-372), add `allowOverdraft = allowOverdraft,` (the `InitiateTransactionAmendment {..}` pattern already binds it).

4. Update every other construction site of **both** the command `InitiateTransactionAmendment` **and** the event `TransactionAmendmentInitiated`. Find them (grep both names — the event has its own construction sites in tests that will break under `-Werror`/`-Wmissing-fields`):

```bash
grep -rn "InitiateTransactionAmendment\b\|TransactionAmendmentInitiated\b" src test
```

Set `allowOverdraft = False` at each of these (all are user-initiated except the merge saga, handled in Task 4):

Command sites:
- `src/Application/Services/TransactionService.hs` — `resolveAmendment`'s output record (~line 730): `allowOverdraft = amendCmd.allowOverdraft` (pass through).
- `src/Application/Services/TransactionService.hs` — `mergeTransactions` same-kind `amendCmd` (~line 848): `allowOverdraft = False`.
- `src/Web/API/TransactionAPI.hs` — `amendTransactionHandler` (line ~475): `allowOverdraft = False`.
- `src/Application/ProcessManagers/TransactionMergeManager.hs` — `amendEffect` (line ~222): `allowOverdraft = True` (Task 4 covers the test; set it here now so it compiles).

Event sites (build the `TransactionAmendmentInitiated` record directly — patch proactively, do not wait for the Step 5 build to find them):
- `test/Domain/Transaction/AmendmentPropertySpec.hs:191`
- `test/Domain/Transaction/CancellationPropertySpec.hs:238`
- `test/Application/ProcessManagers/TransactionAmendmentManagerSpec.hs:156, 178`
- `test/Application/ProcessManagers/TransactionAmendmentManagerPropertySpec.hs:81`
- Plus `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` (command sites) — `allowOverdraft = False` unless the test targets the flag.

- [ ] **Step 4: Format, run the handler test**

Run: `just format && cabal test all --test-option='--match' --test-option="/carries allowOverdraft/"`
Expected: PASS.

- [ ] **Step 5: Full build (field touches many sites)**

Run: `just build`
Expected: builds clean (all construction sites updated).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(transaction): add allowOverdraft flag to amendment command and event"
```

---

## Task 4: Thread `allowOverdraft` through the amend saga; merge sets it True

**Files:**
- Modify: `src/Application/ProcessManagers/TransactionAmendmentManager.hs:141-161` (data), `:271-291` (event→data), `:324-347` + `:405-434` (effect)
- Modify: `src/Application/ProcessManagers/TransactionMergeManager.hs:215-237` (already set True in Task 3 Step 3 — verify)
- Test: `test/Integration/TransactionMergeIntegrationSpec.hs` (or the merge-manager spec)

- [ ] **Step 1: Write the failing bypass test**

Add an integration/manager test proving a merge whose amend debit would overdraft the source still completes. In `test/Integration/TransactionMergeIntegrationSpec.hs` (reuse its Testkit setup), construct a same-kind two-expense merge on an account with just enough balance for one expense so the combined debit would exceed balance, and assert the merge succeeds (status `Completed`). (This exercises the saga's amend bypass directly and does not depend on Task 6.)

```haskell
  it "completes a merge even when the combined amend debit exceeds the source balance" $ do
    -- arrange: account funded for exactly one expense; two expenses that together
    -- exceed the balance; merge them.
    -- assert: Right result with status Completed (bypass let the transient debit through)
```

- [ ] **Step 2: Run it — expect FAIL (amend rejected by the balance guard)**

Run: `cabal test all --test-option='--match' --test-option="/exceeds the source balance/"`
Expected: FAIL — merge returns a failure/`Failed` status because `fallibleLegToEffect` hard-codes `allowOverdraft = False`.

- [ ] **Step 3: Thread the flag**

1. `TransactionAmendmentManager.hs` `TransactionAmendmentData` (lines 141-161): add `allowOverdraft :: Bool,` (before `at` or `phase`).

2. `handleTransactionAmendmentEvent` (lines 271-291): set `allowOverdraft = evt.allowOverdraft,` in the `TransactionAmendmentData {..}` construction.

3. `fallibleLegToEffect` (lines 324-347): change its signature to take the flag and use it:

```haskell
fallibleLegToEffect :: Bool -> FallibleLeg -> ProcessManagerEffect AccountingCommand
fallibleLegToEffect allowOverdraft (DebitNewSource (acct, amt, txId)) =
  IssueCommandWithCompensation
    (unAccountId acct)
    ( embedWith
        accountCommandEmbedding
        ( DebitAccountAccountCommand
            DebitAccount {amount = amt, transactionId = txId, allowOverdraft = allowOverdraft}
        )
    )
    id
    ( \(RejectionReason rejReason) ->
        [ IssueCommand
            (unTransactionId txId)
            ( embedWith
                transactionCommandEmbedding
                (FailTransactionAmendmentTransactionCommand FailTransactionAmendment {reason = rejReason})
            )
            id
        ]
    )
```

4. `reactToTransactionAmendmentEvent` (lines 405-434): both call sites of `fallibleLegToEffect debit` become `fallibleLegToEffect amend.allowOverdraft debit`. (The function has `amend` in scope in the `AwaitingDebit` arm; the `AccountDebitedEvent` arm reaches `ReadyToFinalize` which has no fallible leg — no change needed there.)

- [ ] **Step 4: Verify the merge saga sets True**

Confirm `TransactionMergeManager.amendEffect` (line ~226) has `allowOverdraft = True` (added in Task 3). Add a code comment:

```haskell
                -- A merge only reshapes already-settled transactions; bypass the
                -- balance guard so the transient double-debit (amend before the
                -- source cancel reverses it) cannot spuriously fail the merge.
                allowOverdraft = True,
```

- [ ] **Step 5: Format, run the bypass test**

Run: `just format && cabal test all --test-option='--match' --test-option="/exceeds the source balance/"`
Expected: PASS.

- [ ] **Step 6: Amend-guard regression — ordinary amend still guarded**

Add/confirm a test that an ordinary user amendment (default `allowOverdraft = False`) still rejects an over-balance debit, proving the guard was not flipped globally. Put it alongside the existing amendment tests.

Run: `cabal test all --test-option='--match' --test-option="/Amendment/"`
Expected: PASS (including the still-guarded case).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(transaction): merge-originated amend bypasses the balance guard"
```

---

## Task 5: New transfer-merge error constructors

**Files:**
- Modify: `src/Domain/Core/Errors.hs` — add constructors before line 238 (`deriving`), render arms near lines 386-394

- [ ] **Step 1: Add the constructors**

In `src/Domain/Core/Errors.hs`, immediately before `CannotMergeTransactionWithItself` / the closing `deriving (Show, Eq, Generic)` (line ~237), add:

```haskell
  | -- tracker#44: the two legs are on the same account, so they are not a transfer
    TransferMergeSameAccount
  | -- tracker#44: the selected legs are not an equal-magnitude, same-currency,
    -- opposite-direction pair within the merge time window
    TransferMergeLegsDoNotMatch
```

- [ ] **Step 2: Add the render arms**

Near the existing `CannotMerge*` renderer arms (lines ~386-394), add human-readable messages:

```haskell
  TransferMergeSameAccount -> "Cannot merge into a transfer: both transactions are on the same account"
  TransferMergeLegsDoNotMatch -> "Cannot merge into a transfer: the transactions are not a matching income/expense pair"
```

- [ ] **Step 3: Build**

Run: `just build`
Expected: builds clean (the `case` on `DomainError` is now exhaustive again).

- [ ] **Step 4: Commit**

```bash
git add src/Domain/Core/Errors.hs
git commit -m "feat(errors): transfer-merge domain errors"
```

---

## Task 6: Transfer-merge branch in `mergeTransactions`

Dispatch: when the target is an Income and its single source is an Expense, route to the transfer branch. Otherwise keep the existing same-kind path. The two branches share the common guards (access, Completed, self-merge, books-closed) and the final `InitiateTransactionMerge` dispatch.

**Files:**
- Modify: `src/Application/Services/TransactionService.hs:808-884` (mergeTransactions), add helpers near the merge helpers (~898)
- Test: `test/Application/Services/TransactionMergeSpec.hs` (add a transfer-merge describe block)

- [ ] **Step 1: Write the failing service tests**

Add to `test/Application/Services/TransactionMergeSpec.hs` a `transferMergeSpec` block (register it in the top-level `spec` list). Reuse `Testkit.Fixtures` helpers (`setupMetadataFixture`, `postIncome`, `postExpense`, `createAccount`) and `Testkit.InMemoryEventStore`.

```haskell
transferMergeSpec :: Spec
transferMergeSpec = describe "transfer-merge (income target + expense source)" $ do
  it "amends the income into a Transfer, cancels the expense, and links a Merge edge" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "transfer-merge@test.com"
    -- two regular accounts A (expense) and B (income); equal amount, close time
    incomeId <- postIncome env fx 500 Nothing   -- credited to B
    expenseId <- postExpense env fx 500 Nothing  -- debited from A
    result <- runMerge env fx.userId incomeId (expenseId :| [])
    case result of
      Left err -> expectationFailure ("expected Right, got: " <> show err)
      Right td -> do
        kindOf td.transactionType `shouldBe` TransferKind
        td.status `shouldBe` Completed
    statusOf env expenseId >>= (`shouldBe` Cancelled)
    -- lineage edge lives on the cancelled expense, pointing at the survivor
    runAppM env (getOutboundRelations expenseId) >>= (`shouldBe` [(incomeId, Merge)])

  it "rejects when the two legs are on the same account" $ do
    -- income and expense on the same regular account → TransferMergeSameAccount
    ...

  it "rejects when amounts differ" $ do
    -- income 500, expense 400 → TransferMergeLegsDoNotMatch
    ...
```

(Fill the arrange steps using the fixture helpers that create distinct regular accounts; check `Testkit.Fixtures` for the helper that posts income/expense against a chosen account — mirror the same-kind tests above in this file.)

- [ ] **Step 2: Run — expect FAIL (currently `CannotMergeIncompatibleKinds`)**

Run: `cabal test all --test-option='--match' --test-option="/transfer-merge/"`
Expected: FAIL — the happy case returns `Left CannotMergeIncompatibleKinds` (opposite kinds hit `guardMergeCompatible`).

- [ ] **Step 3: Add the dispatch + transfer branch**

In `src/Application/Services/TransactionService.hs`:

1. Add a top-level constant (near the merge helpers) — the relaxed window:

```haskell
-- | Time tolerance for a manual income/expense → transfer merge. More relaxed
-- than import's 5-minute pairing window: a manually-reconciled transfer may have
-- legs dated further apart (settlement lag, hand-entered dates). Tunable.
mergeTransferWindow :: NominalDiffTime
mergeTransferWindow = 24 * 60 * 60 -- 24h
```

2. Add a classifier helper:

```haskell
-- | When the target is an Income and its single source is an Expense, this is a
-- transfer-merge; returns that expense. Otherwise 'Nothing' (same-kind path).
asTransferMerge :: TransactionData -> [TransactionData] -> Maybe TransactionData
asTransferMerge target [src]
  | kindOf target.transactionType == IncomeKind,
    kindOf src.transactionType == ExpenseKind =
      Just src
asTransferMerge _ _ = Nothing
```

3. Add the leg projection + branch:

```haskell
-- | Project a domain transaction leg for 'isTransferMatch'. The income's real
-- account is its target (credit) side; the expense's is its source (debit) side.
transferLegOf :: TransferDirection -> Money -> UTCTime -> TransferLeg Currency
transferLegOf dir m t =
  TransferLeg {direction = dir, magnitude = unMoney m, currency = moneyCurrency m, time = t}

-- | The transfer-merge branch: validate the pair, then reshape the income into a
-- Transfer and fold in the expense via the shared merge saga.
transferMerge ::
  UserId -> TransactionData -> TransactionData -> AppM (Either DomainError TransactionData)
transferMerge userId income expense = runExceptT $ do
  let incomeAcc = income.targetAccountId -- credited (real) account
      expenseAcc = expense.sourceAccountId -- debited (real) account
      incomeLeg = transferLegOf CreditLeg income.targetAmount income.date
      expenseLeg = transferLegOf DebitLeg expense.sourceAmount expense.date
  guardE (incomeAcc /= expenseAcc) TransferMergeSameAccount
  guardE (isTransferMatch mergeTransferWindow incomeLeg expenseLeg) TransferMergeLegsDoNotMatch
  let amendCmd =
        InitiateTransactionAmendment
          { transactionId = income.transactionId,
            newSourceAccountId = expenseAcc,
            newTargetAccountId = incomeAcc,
            newSourceAmount = income.targetAmount,
            newTargetAmount = income.targetAmount,
            newExchangeRate = Nothing,
            newAllocations = Nothing,
            newTransactionType = Transfer,
            contactId = Nothing,
            allowOverdraft = False, -- discarded; the saga's amendEffect sets True
            by = userId
          }
  resolved <- ExceptT (resolveAmendment userId income amendCmd)
  let mergeCmd =
        InitiateTransactionMerge
          { newSourceAccountId = resolved.newSourceAccountId,
            newTargetAccountId = resolved.newTargetAccountId,
            newSourceAmount = resolved.newSourceAmount,
            newTargetAmount = resolved.newTargetAmount,
            newExchangeRate = resolved.newExchangeRate,
            newAllocations = resolved.newAllocations,
            newTransactionType = resolved.newTransactionType,
            contactId = resolved.contactId,
            sourceTransactionIds = [expense.transactionId],
            by = userId
          }
  ExceptT (dispatchAndAwaitMerge income.transactionId (InitiateTransactionMergeTransactionCommand mergeCmd))
```

4. Wire the dispatch into `mergeTransactions`. After the sources are loaded and the common guards (access/Completed/self-merge/books-closed) run, branch before `guardMergeCompatible`:

```haskell
  -- ... after sourceTxns loaded + books-closed gate ...
  case asTransferMerge target sourceTxns of
    Just expense -> ExceptT (transferMerge userId target expense)
    Nothing -> do
      -- existing same-kind path: guardMergeCompatible, combined allocations, amend, dispatch
      ...
```

Keep the books-closed gate applied to `target` and all `sourceTxns` **before** the branch so both paths honour it. Note: this moves the books-closed gate ahead of `guardMergeCompatible`, so a same-kind merge that is both closed-books AND incompatible-kind now returns the books-closed error first (previously `CannotMergeIncompatibleKinds`). Harmless, but if an existing same-kind test pins that error ordering, update it. Add the imports:

```haskell
import Domain.Transaction.TransferMatch (TransferDirection (..), TransferLeg (..), isTransferMatch)
import Data.Time (NominalDiffTime)
-- Currency, unMoney, moneyCurrency, kindOf, TransferKind already come from Domain.Core.Types
```

- [ ] **Step 4: Format, run the transfer-merge tests**

Run: `just format && cabal test all --test-option='--match' --test-option="/transfer-merge/"`
Expected: PASS (happy + both rejections).

- [ ] **Step 5: Run the whole merge spec (no regression to same-kind merge)**

Run: `cabal test all --test-option='--match' --test-option="/mergeTransactions/"`
Expected: PASS (existing same-kind cases unchanged).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(transaction): merge income+expense into a transfer"
```

---

## Task 7: Audit-history parity for merge + relation events

Map the merge and relation events in `toHistoryEntry` so a transfer-merge is auditable on both legs.

**Files:**
- Modify: `src/Application/Services/TransactionHistoryService.hs:103-121` (entries), `:162-177` (mapping)
- Test: `test/Application/Services/TransactionHistoryServiceSpec.hs` (or wherever history is tested — grep `getTransactionHistory`)

- [ ] **Step 1: Write the failing history test**

Add a test: after a transfer-merge, `getTransactionHistory` on the survivor includes a merge-completed entry, and on the cancelled expense includes a relation-added entry. Mirror the existing history spec's setup.

```haskell
  it "records the merge and relation events in the transaction history" $ do
    -- arrange: perform a transfer-merge (as in Task 6 happy path)
    -- act: getTransactionHistory on survivor and on the cancelled expense
    -- assert: survivor entries contain a HistoryMergeCompleted; expense entries contain a HistoryRelationAdded (Merge)
```

- [ ] **Step 2: Run — expect FAIL (events dropped by the catch-all)**

Run: `cabal test all --test-option='--match' --test-option="/records the merge and relation events/"`
Expected: FAIL — merge/relation entries absent (current `_ -> Nothing`).

- [ ] **Step 3: Add the entry constructors + mapping**

1. `TransactionHistoryEntry` (lines 103-121): add constructors (import the events at the top of the module if not already):

```haskell
  | HistoryMergeInitiated TransactionMergeInitiated
  | HistoryMergeCompleted TransactionMergeCompleted
  | HistoryMergeFailed TransactionMergeFailed
  | HistoryRelationAdded TransactionRelationAdded
  | HistoryRelationRemoved TransactionRelationRemoved
```

2. `toHistoryEntry` (lines 162-177): add arms **above** the `_ -> Nothing` catch-all:

```haskell
  TransactionMergeInitiatedEvent e -> Just (HistoryMergeInitiated e)
  TransactionMergeCompletedEvent e -> Just (HistoryMergeCompleted e)
  TransactionMergeFailedEvent e -> Just (HistoryMergeFailed e)
  TransactionRelationAddedEvent e -> Just (HistoryRelationAdded e)
  TransactionRelationRemovedEvent e -> Just (HistoryRelationRemoved e)
```

Ensure imports are extended in **two** lists in this module: (1) the raw event payload types (`TransactionMergeInitiated`, `TransactionMergeCompleted`, `TransactionMergeFailed`, `TransactionRelationAdded`, `TransactionRelationRemoved`) from `Domain.Transaction.Events`; and (2) the `AccountingEvent(..)` wrapper constructors matched in `toHistoryEntry` (`TransactionMergeInitiatedEvent`, `TransactionMergeCompletedEvent`, `TransactionMergeFailedEvent`, `TransactionRelationAddedEvent`, `TransactionRelationRemovedEvent`) from the `Domain.Models` import list. Both must be present or the build fails.

- [ ] **Step 4: Format, run the history test**

Run: `just format && cabal test all --test-option='--match' --test-option="/records the merge and relation events/"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(transaction): surface merge and relation events in transaction history"
```

---

## Task 8: End-to-end integration + balance correctness

**Files:**
- Test: `test/Integration/TransactionMergeIntegrationSpec.hs` (add a transfer-merge scenario)

- [ ] **Step 1: Write the integration test**

Add an end-to-end scenario using the integration Testkit (real in-memory event store + process managers):

```haskell
  it "merges a cross-account income+expense into a single transfer with correct balances" $ do
    -- arrange: account A funded; post Expense A→External (X); post Income External→B (X), close in time
    -- act: mergeTransactions user incomeId [expenseId]
    -- assert:
    --   * survivor is a Transfer A→B of amount X
    --   * expense is Cancelled, carries a Merge edge to the survivor
    --   * balance(A) reflects exactly one debit of X (not two, not zero)
    --   * balance(B) reflects exactly one credit of X
```

- [ ] **Step 2: Run — expect PASS (feature already implemented in Tasks 1-7)**

This is a coverage/acceptance test over the completed feature, not a red-green driver.

Run: `cabal test all --test-option='--match' --test-option="/correct balances/"`
Expected: PASS. If balances are wrong, debug the amend/cancel ordering (see spec §"Balance guard") before proceeding.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test(transaction): end-to-end transfer-merge balance correctness"
```

---

## Task 9: Full verification

- [ ] **Step 1: Format + lint**

Run: `just check`
Expected: no ormolu diffs, no hlint findings.

- [ ] **Step 2: Clean `-Werror` build (warm cache can mask regressions)**

Run: `just rebuild`
Expected: clean build with `-fci`.

- [ ] **Step 3: Full test suite**

Run: `just test`
Expected: all green (note: full `cabal test all` needs a local `eventium_test` Postgres DB; the ~28 DB-dependent failures are environmental, not regressions — see project memory).

- [ ] **Step 4: Manual verification per the `verify` skill**

Drive the real endpoint if feasible (`POST /api/transactions/:incomeId/merge` with `{sourceTransactionIds:[expenseId]}`) and confirm the survivor is a Transfer and the expense is Cancelled. Otherwise rely on the integration test as the behavioural evidence.

- [ ] **Step 5: Final commit / branch is ready for PR**

```bash
git add -A && git commit -m "chore: transfer-merge verification pass" --allow-empty
```

---

## Notes / risks

- **`mergeTransferWindow = 24h` is the one product-tunable.** Settlement lag can exceed a day; if legitimate merges get rejected, widen it. It is a single named constant.
- **`amendEffect` now sets `allowOverdraft = True` for ALL merges** (same-kind #30 too). This is intended: a merge only reshapes settled transactions, and the transient over-debit during the amend-before-cancel window should never fail a merge. The Task 4 bypass test locks this in; the Task 4 regression test locks in that ordinary amends stay guarded.
- **Event JSON change:** `TransactionAmendmentInitiated` gains `allowOverdraft`. Under the no-backward-compat policy this is a clean shape change; a dev DB with pre-existing amendment events would need a reset (no upcaster).
- **LiquidHaskell:** `TransferMatch` is a total predicate over primitives; add refinements only if the in-build LH pass demands them (Task 1 Step 5).
- **Orientation is fixed:** the survivor is always the Income (`:id`), per the design. A client passing an Expense as `:id` with an Income source falls through to the same-kind path and returns `CannotMergeIncompatibleKinds`; the web client is responsible for passing the Income as the target.
