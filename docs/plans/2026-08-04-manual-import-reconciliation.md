# Manual ↔ Import Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a bank import from double-booking a movement the user already recorded manually — on a confident fuzzy match, attach the incoming external id(s)+MCC onto the existing manual transaction instead of creating a second ledger entry.

**Architecture:** A pure `Domain.Transaction.Matching` namespace (extracted `Leg` kernel + relocated `Transfer` + new `Reconciliation`) decides matches. A new balance-neutral `TransactionImportReconciled` event carries the attribution onto the manual transaction's stream; the `BankImportReadModel` projects it into the `imported_transactions` dedup table (so re-syncs skip), the `Transaction` read model folds its MCC, and the audit history renders it. `BankImportService` runs the matcher between the failed `isImported` check and the fresh post, serialized under `withUserLock` on **both** import paths.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude), Servant, PostgreSQL via Eventium event store + persistent read models, Hspec + QuickCheck, `just` task runner. `-fci` (`-Werror`) is enforced.

**Spec:** `docs/specs/2026-08-04-manual-import-reconciliation-design.md`

---

## Conventions for every task

- Run the dev shell first: `nix develop` (puts `just`, `cabal`, `ormolu`, `hlint` on PATH).
- After package.yaml changes: `hpack` before building. New modules must be added to `package.yaml` (both `library` and, for tests, the `spec` component) — the project uses Hpack, so new `.hs` files under `src/`/`test/` are picked up by the globbed source dirs, but **verify** with `just build` / `just test`.
- TDD: write the failing test, run it red, implement minimally, run it green, then `just format && just lint`, then commit.
- Commit messages: Conventional Commits, scope `import`/`transaction`, reference `#148`.
- Final gate per task: `just build` (which passes `-fci`). Warm `.o` cache can mask `-Werror`; the whole-feature gate (Task 12) does a `just rebuild`.
- Actor field rule: `TransactionImportReconciled` carries **no `by`** (system-driven metadata attachment).

---

## File structure

**Create:**
- `src/Domain/Transaction/Matching/Leg.hs` — shared kernel: `Leg c`, `sameMovement`.
- `src/Domain/Transaction/Matching/Transfer.hs` — relocated `TransferDirection`, `TransferLeg`, `isTransferMatch`, rebuilt on `Leg`.
- `src/Domain/Transaction/Matching/Reconciliation.hs` — `isReconciliationMatch`, `reconcile`, `ReconciliationOutcome`.
- `test/Domain/Transaction/Matching/LegPropertySpec.hs`
- `test/Domain/Transaction/Matching/ReconciliationPropertySpec.hs`
- `test/fixtures/events/transaction-import-reconciled.json`

**Modify:**
- `src/Domain/Transaction/TransferMatch.hs` — **delete** (moved to `Matching/Transfer.hs`).
- `src/Infrastructure/Banking/Provider.hs` — repoint import to `Matching.Transfer`.
- `src/Application/Services/TransactionService.hs` — repoint import to `Matching.Transfer`; add `reconcileTransactionImport`.
- `src/Domain/Transaction/Events.hs` — add `TransactionImportReconciled`.
- `src/Domain/Transaction/Commands.hs` — add `ReconcileTransactionImport`.
- `src/Domain/Transaction/CommandHandler.hs` — handle `ReconcileTransactionImport`.
- `src/Domain/Transaction/Projection.hs` — `reconciled` flag + fold.
- `src/Application/ReadModels/BankImportReadModel.hs` — project the new event; `transaction_id` index; `isReconciled` query.
- `src/Application/ReadModels/Transaction.hs` — apply the new event (MCC, non-clobber); `findReconciliationCandidates` + `findTransferReconciliationCandidates`.
- `src/Application/Services/TransactionHistoryService.hs` — `HistoryImportReconciled` constructor + mapping.
- `src/Application/Services/BankImportService.hs` — reconciliation wiring; `AmbiguousReconciliation` skip reason.
- `test/**` — matching, handler, projection, schema, read-model, history, service, integration specs.

**Test-repoint (rename import only):**
- `test/Domain/Transaction/TransferMatchPropertySpec.hs` → point at `Matching.Transfer`.
- `test/Infrastructure/Banking/TransferMatcherSpec.hs` — unaffected (goes through `TransferMatcher`).

---

## Task 1: Extract the `Matching.Leg` kernel

**Files:**
- Create: `src/Domain/Transaction/Matching/Leg.hs`
- Test: `test/Domain/Transaction/Matching/LegPropertySpec.hs`

- [ ] **Step 1: Write the failing property test**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Domain.Transaction.Matching.LegPropertySpec (spec) where

import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Domain.Transaction.Matching.Leg (Leg (..), sameMovement)
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 8 4) (secondsToDiffTime 0)

spec :: Spec
spec = describe "Domain.Transaction.Matching.Leg.sameMovement" $ do
  it "matches equal magnitude+currency within the window" $
    sameMovement 86400 (Leg 250 "UAH" baseTime) (Leg 250 "UAH" (addUTCTime 3600 baseTime))
      `shouldBe` True

  it "rejects different magnitude" $
    sameMovement 86400 (Leg 250 "UAH" baseTime) (Leg 251 "UAH" baseTime) `shouldBe` False

  it "rejects different currency" $
    sameMovement 86400 (Leg 250 "UAH" baseTime) (Leg 250 "USD" baseTime) `shouldBe` False

  it "rejects outside the window" $
    sameMovement 3600 (Leg 250 "UAH" baseTime) (Leg 250 "UAH" (addUTCTime 7200 baseTime))
      `shouldBe` False

  prop "is symmetric in its leg arguments" $ \(m1 :: Integer) m2 c1 c2 dt ->
    let a = Leg (fromIntegral m1) (c1 :: Char) baseTime
        b = Leg (fromIntegral m2) c2 (addUTCTime (fromIntegral (dt :: Int)) baseTime)
     in sameMovement 86400 a b === sameMovement 86400 b a
```

- [ ] **Step 2: Run it and confirm it fails to compile (module missing)**

Run: `cabal test all --test-option='--match' --test-option="/Matching.Leg/"`
Expected: build error — `Domain.Transaction.Matching.Leg` not found.

- [ ] **Step 3: Implement the kernel**

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.Matching.Leg
-- Description : The shared "are these the same money movement?" kernel.
--
-- A movement leg is an absolute magnitude in some currency at a time. Two legs
-- are the "same movement" when magnitude and currency are equal and their times
-- are within a window. Parameterised over the currency token @c@ because bank
-- legs and domain legs are never compared cross-side (each call site matches
-- like-with-like). Both 'Domain.Transaction.Matching.Transfer' and
-- 'Domain.Transaction.Matching.Reconciliation' stand on this.
module Domain.Transaction.Matching.Leg
  ( Leg (..),
    sameMovement,
  )
where

import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import RIO

-- | A normalised movement leg. @magnitude@ is the absolute amount in major
-- units; @currency@ is any 'Eq' token consistent within a call site; @time@ is
-- when it occurred.
data Leg c = Leg
  { magnitude :: Rational,
    currency :: c,
    time :: UTCTime
  }
  deriving (Show, Eq)

-- | Equal magnitude, equal currency, and within @window@ of each other.
-- Symmetric in its two leg arguments.
sameMovement :: (Eq c) => NominalDiffTime -> Leg c -> Leg c -> Bool
sameMovement window a b =
  a.magnitude
    == b.magnitude
    && a.currency
    == b.currency
    && abs (diffUTCTime a.time b.time)
    <= window
```

- [ ] **Step 4: Register the module + run green**

Add `Domain.Transaction.Matching.Leg` and the new test module to `package.yaml` if the source globs don't auto-include (they should; re-run `hpack`). Run:
`cabal test all --test-option='--match' --test-option="/Matching.Leg/"`
Expected: PASS.

- [ ] **Step 5: format, lint, commit**

```bash
just format && just lint
git add src/Domain/Transaction/Matching/Leg.hs test/Domain/Transaction/Matching/LegPropertySpec.hs package.yaml backend.cabal
git commit -m "feat(transaction): add Matching.Leg same-movement kernel (#148)"
```

---

## Task 2: Relocate `TransferMatch` → `Matching.Transfer` on the kernel

**Files:**
- Create: `src/Domain/Transaction/Matching/Transfer.hs`
- Delete: `src/Domain/Transaction/TransferMatch.hs`
- Modify: `src/Infrastructure/Banking/Provider.hs:38`, `src/Application/Services/TransactionService.hs:165`
- Modify: `test/Domain/Transaction/TransferMatchPropertySpec.hs` (import line only)

- [ ] **Step 1: Create `Matching.Transfer` rebuilt on `Leg`**

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.Matching.Transfer
-- Description : Pure "are these two legs opposite sides of one transfer?" —
--               shared by bank-import internal-transfer detection and the
--               manual income+expense → transfer merge. Rebuilt on
--               'Domain.Transaction.Matching.Leg'.
module Domain.Transaction.Matching.Transfer
  ( TransferDirection (..),
    TransferLeg (..),
    isTransferMatch,
  )
where

import Data.Time (NominalDiffTime, UTCTime)
import Domain.Transaction.Matching.Leg (Leg (..), sameMovement)
import RIO

-- | Which side of a movement a leg is: money leaving (debit) or arriving (credit).
data TransferDirection = DebitLeg | CreditLeg
  deriving (Show, Eq)

-- | A transfer leg: a directioned movement leg.
data TransferLeg c = TransferLeg
  { direction :: TransferDirection,
    magnitude :: Rational,
    currency :: c,
    time :: UTCTime
  }
  deriving (Show, Eq)

-- | True when @a@ and @b@ are opposite-direction legs of the SAME movement:
-- opposite directions plus 'sameMovement'. Symmetric in its two arguments.
isTransferMatch :: (Eq c) => NominalDiffTime -> TransferLeg c -> TransferLeg c -> Bool
isTransferMatch window a b =
  a.direction /= b.direction && sameMovement window (legOf a) (legOf b)
  where
    legOf l = Leg {magnitude = l.magnitude, currency = l.currency, time = l.time}
```

- [ ] **Step 2: Repoint the two src call sites and the test import**

- `src/Infrastructure/Banking/Provider.hs:38`: change `import Domain.Transaction.TransferMatch (...)` → `import Domain.Transaction.Matching.Transfer (...)`.
- `src/Application/Services/TransactionService.hs:165`: same rename.
- `test/Domain/Transaction/TransferMatchPropertySpec.hs`: change the import to `Domain.Transaction.Matching.Transfer`.

- [ ] **Step 3: Delete the old module**

```bash
git rm src/Domain/Transaction/TransferMatch.hs
```
Remove `Domain.Transaction.TransferMatch` from `package.yaml`/`backend.cabal` exposed-modules if listed explicitly; re-run `hpack`.

- [ ] **Step 4: Build + run the transfer suites green**

Run: `just build`
Then: `cabal test all --test-option='--match' --test-option="/Transfer/"`
Expected: PASS (existing `TransferMatchPropertySpec` + `TransferMatcherSpec` pass unchanged in behavior). If `grep -rn "Domain.Transaction.TransferMatch" src test` returns anything, fix it.

- [ ] **Step 5: format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "refactor(transaction): relocate TransferMatch to Matching.Transfer on Leg kernel (#148)"
```

---

## Task 3: New `Matching.Reconciliation` matcher

**Files:**
- Create: `src/Domain/Transaction/Matching/Reconciliation.hs`
- Test: `test/Domain/Transaction/Matching/ReconciliationPropertySpec.hs`

Covers the acceptance-criteria matrix as pure property/unit tests.

- [ ] **Step 1: Write the failing tests**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Domain.Transaction.Matching.ReconciliationPropertySpec (spec) where

import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Domain.Transaction.Matching.Leg (Leg (..))
import Domain.Transaction.Matching.Reconciliation (ReconciliationOutcome (..), reconcile)
import RIO
import Test.Hspec

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 4) (secondsToDiffTime 0)

day :: Rational -> UTCTime
day n = addUTCTime (fromRational (n * 86400)) t0

window :: NominalDiffTime
window = 3 * 86400 -- ±3 days

leg :: Rational -> UTCTime -> Leg Text
leg m tm = Leg m "UAH" tm

spec :: Spec
spec = describe "Domain.Transaction.Matching.Reconciliation.reconcile" $ do
  it "returns UniqueMatch on exactly one exact candidate" $
    reconcile window (leg 250 t0) [("A" :: Text, leg 250 t0)] `shouldBe` UniqueMatch "A"

  it "returns UniqueMatch on a single near candidate within the window" $
    reconcile window (leg 250 t0) [("A", leg 250 (day 2))] `shouldBe` UniqueMatch "A"

  it "returns Ambiguous for two distinct same-amount same-day candidates" $
    reconcile window (leg 250 t0) [("A", leg 250 t0), ("B", leg 250 t0)]
      `shouldBe` Ambiguous ["A", "B"]

  it "returns NoMatch when the only candidate is outside the window" $
    reconcile window (leg 250 t0) [("A", leg 250 (day 5))] `shouldBe` NoMatch

  it "returns NoMatch on differing magnitude/currency" $ do
    reconcile window (leg 250 t0) [("A", leg 251 t0)] `shouldBe` NoMatch
    reconcile window (leg 250 t0) [("A", Leg 250 "USD" t0)] `shouldBe` NoMatch

  it "ignores non-matching candidates when exactly one matches" $
    reconcile window (leg 250 t0) [("A", leg 999 t0), ("B", leg 250 (day 1))]
      `shouldBe` UniqueMatch "B"
```

- [ ] **Step 2: Run red**

Run: `cabal test all --test-option='--match' --test-option="/Matching.Reconciliation/"`
Expected: build error — module missing.

- [ ] **Step 3: Implement**

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.Matching.Reconciliation
-- Description : Decide whether a just-imported bank leg is the SAME movement a
--               user already recorded manually — and, over a candidate set,
--               whether that match is unambiguous.
--
-- Unlike 'Domain.Transaction.Matching.Transfer' (opposite-direction legs of one
-- transfer), reconciliation matches a leg against a same-side manual entry:
-- same magnitude, currency, within window. Direction/account/leg-side are
-- enforced by the candidate SELECTION (the read-model query), exactly as
-- 'Application.Services.BankImport.TransferPairing' enforces "different local
-- accounts" outside the pure matcher; here the pure layer owns the
-- magnitude/currency/window predicate and the unique-vs-ambiguous decision.
module Domain.Transaction.Matching.Reconciliation
  ( ReconciliationOutcome (..),
    isReconciliationMatch,
    reconcile,
  )
where

import Data.Time (NominalDiffTime)
import Domain.Transaction.Matching.Leg (Leg, sameMovement)
import RIO

-- | Outcome of reconciling an imported leg against a candidate set.
data ReconciliationOutcome a
  = -- | No candidate matched — import as a fresh transaction.
    NoMatch
  | -- | Exactly one candidate matched — reconcile onto it.
    UniqueMatch a
  | -- | Two or more candidates matched — skip (never guess a merge). Carries
    -- the matched candidate keys for logging/diagnostics.
    Ambiguous [a]
  deriving (Show, Eq)

-- | Whether an imported leg and a candidate manual leg are the same movement.
-- Same-side by construction (candidate selection guarantees the correct leg on
-- the correct account), so this is exactly 'sameMovement'.
isReconciliationMatch :: (Eq c) => NominalDiffTime -> Leg c -> Leg c -> Bool
isReconciliationMatch = sameMovement

-- | Reconcile @imported@ against @candidates@ (keyed by @a@): none → 'NoMatch';
-- exactly one → 'UniqueMatch'; two or more → 'Ambiguous'.
reconcile ::
  (Eq c) =>
  NominalDiffTime ->
  Leg c ->
  [(a, Leg c)] ->
  ReconciliationOutcome a
reconcile window imported candidates =
  case [key | (key, cand) <- candidates, isReconciliationMatch window imported cand] of
    [] -> NoMatch
    [only] -> UniqueMatch only
    many -> Ambiguous many
```

- [ ] **Step 4: Run green**

Run: `cabal test all --test-option='--match' --test-option="/Matching.Reconciliation/"`
Expected: PASS.

- [ ] **Step 5: format, lint, commit**

```bash
just format && just lint
git add src/Domain/Transaction/Matching/Reconciliation.hs test/Domain/Transaction/Matching/ReconciliationPropertySpec.hs package.yaml backend.cabal
git commit -m "feat(transaction): add Matching.Reconciliation matcher (#148)"
```

---

## Task 4: `TransactionImportReconciled` event + `ReconcileTransactionImport` command + handler + projection

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`, `src/Domain/Transaction/Commands.hs`, `src/Domain/Transaction/CommandHandler.hs`, `src/Domain/Transaction/Projection.hs`
- Test: `test/Domain/Transaction/CommandHandlerSpec.hs` (add cases), new `test/Domain/Transaction/ReconciliationCommandHandlerSpec.hs`

The event is balance-neutral and carries the attribution. Payload mirrors `ImportInfo`.

- [ ] **Step 1: Add the event type (Events.hs)**

In `transactionEvents` list add `''TransactionImportReconciled`. Add to the export list. Define:

```haskell
-- | Event emitted when a bank import is recognised as the SAME movement as an
-- already-recorded manual transaction: it attaches the import attribution
-- (external id(s) + optional MCC) onto that transaction instead of booking a
-- second ledger entry. Balance-neutral — no leg/amount change; sibling in
-- spirit to 'TransactionContactSet'. No `by`: a system-driven metadata
-- attachment, not a whole-aggregate lifecycle action.
data TransactionImportReconciled = TransactionImportReconciled
  { -- | The manual transaction gaining import attribution. Carried in the
    -- payload for symmetry with 'TransactionContactSet'; the stream key is
    -- authoritative.
    transactionId :: TransactionId,
    -- | The external id(s) now attributed to this transaction (one for a plain
    -- income/expense reconcile; both legs for a transfer reconcile).
    externalTransactionIds :: NonEmpty ExternalTransactionId,
    -- | Provider MCC, if any (only some providers supply one).
    mcc :: Maybe MCC
  }
  deriving (Show, Eq)
```

Add imports `ExternalTransactionId, MCC` from `Domain.Core.Types` and `NonEmpty`. Add `deriveJSON defaultOptions ''TransactionImportReconciled` at the bottom.

- [ ] **Step 2: Add the command (Commands.hs)**

Add `''ReconcileTransactionImport` to `transactionCommands`, export it, and:

```haskell
-- | Attach import attribution (external id(s) + MCC) onto an existing completed
-- manual transaction — the reconcile leg of manual↔import dedup. Mirrors the
-- emitted 'TransactionImportReconciled'.
data ReconcileTransactionImport = ReconcileTransactionImport
  { transactionId :: TransactionId,
    externalTransactionIds :: NonEmpty ExternalTransactionId,
    mcc :: Maybe MCC
  }
```

Add `deriveJSON defaultOptions ''ReconcileTransactionImport` and the needed imports.

- [ ] **Step 3: Write the failing handler tests**

Create `test/Domain/Transaction/ReconciliationCommandHandlerSpec.hs`. Use the same fixture/mock helpers as `CommandHandlerSpec.hs` (inspect it for the completed-transaction builder). Assert:

```haskell
-- exact names follow CommandHandlerSpec conventions
spec :: Spec
spec = describe "ReconcileTransactionImport" $ do
  it "emits TransactionImportReconciled on a Completed transaction" $ do
    let tx = completedTransaction  -- from shared helper
        cmd = ReconcileTransactionImportTransactionCommand
                (ReconcileTransactionImport txId (extId :| []) (Just "5411"))
    handleTransactionCommand tx cmd
      `shouldBe` Right [TransactionImportReconciledTransactionEvent
                          (TransactionImportReconciled txId (extId :| []) (Just "5411"))]

  it "rejects when the transaction is not Completed" $
    handleTransactionCommand pendingTransaction cmd `shouldBe` Left CannotEditUncompletedTransaction

  it "rejects when already reconciled" $
    handleTransactionCommand alreadyReconciledTransaction cmd `shouldBe` Left <alreadyReconciledError>
```

Add a `TransactionAlreadyReconciled` constructor to the **handler-local** `TransactionError` sum **in `src/Domain/Transaction/CommandHandler.hs`**, alongside `CannotEditUncompletedTransaction` — NOT to `Domain.Transaction.Errors`. There are two same-named `TransactionError` types: the handler-side one (returned by `handleTransactionCommand :: … -> Either TransactionError [TransactionEvent]`, containing `CannotEditUncompletedTransaction`) and the API/JSON-side `Domain.Transaction.Errors.TransactionError`; Step 6 returns `Left TransactionAlreadyReconciled` from the handler, so it must live on the handler-side type or the clause won't compile. (`translateTransactionError` has a catch-all arm, so no dedicated user-facing message is strictly required; add an explicit arm there only if a specific message is wanted.)

- [ ] **Step 4: Run red**

Run: `cabal test all --test-option='--match' --test-option="/ReconcileTransactionImport/"`
Expected: build error / failures (handler clause + error constructor missing).

- [ ] **Step 5: Add the `reconciled` flag to the projection (Projection.hs)**

- Add field to `data Transaction`: `reconciled :: Bool` (doc: "True once a 'TransactionImportReconciled' event has been folded; gates re-reconciliation.").
- Add `reconciled = False` to `transactionDefault`.
- Add fold clause in `handleTransactionEvent`:

```haskell
handleTransactionEvent transaction (TransactionImportReconciledTransactionEvent _) =
  case transaction ^. #status of
    Completed -> transaction & #reconciled .~ True
    _ -> transaction
```

(`makeFieldLabelsNoPrefix` already generates the `#reconciled` optic; `deriveJSON` picks up the new field.)

- [ ] **Step 6: Implement the handler clause (CommandHandler.hs)**

Mirror `SetTransactionContact` (line ~275):

```haskell
handleTransactionCommand transaction (ReconcileTransactionImportTransactionCommand ReconcileTransactionImport {..}) =
  case transaction ^. #status of
    Completed
      | transaction ^. #reconciled -> Left TransactionAlreadyReconciled
      | otherwise ->
          Right
            [ TransactionImportReconciledTransactionEvent
                TransactionImportReconciled
                  { transactionId = transactionId,
                    externalTransactionIds = externalTransactionIds,
                    mcc = mcc
                  }
            ]
    _ -> Left CannotEditUncompletedTransaction
```

- [ ] **Step 7: Run green**

Run: `cabal test all --test-option='--match' --test-option="/ReconcileTransactionImport/"`
Expected: PASS. Also run `/Transaction.Projection/` and `/CommandHandler/` suites to confirm the new field/clause didn't break exhaustiveness.

- [ ] **Step 8: format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "feat(transaction): ReconcileTransactionImport command + TransactionImportReconciled event + projection fold (#148)"
```

---

## Task 5: Schema round-trip fixture for the new event

**Files:**
- Create: `test/fixtures/events/transaction-import-reconciled.json`
- Modify: `test/Infrastructure/Eventium/SchemaSpec.hs`

New event ⇒ no upcaster (schemaVersion v1); this proves encode/decode + tag stability. Model the fixture on `test/fixtures/events/transaction-posting-initiated-legacy-import.json` and the `AccountingEvent` `{ "tag": ..., "contents": {..} }` envelope.

- [ ] **Step 1: Inspect an existing case in `SchemaSpec.hs`** to copy its decode-through-registry + re-encode assertion shape.

- [ ] **Step 2: Write the failing fixture test** — add a `describe "TransactionImportReconciled"` that reads the fixture, decodes via `accountingEventCodec`, and round-trips. Author the fixture JSON (tag `"TransactionImportReconciled"`, `contents` with `transactionId`, `externalTransactionIds: ["mono-abc123"]`, `mcc: "5411"`).

- [ ] **Step 3: Run red**, then confirm the tag matches `eventTypeName @TransactionImportReconciled` (fix the fixture tag string if the assertion reports a mismatch).

Run: `cabal test all --test-option='--match' --test-option="/SchemaSpec/"`

- [ ] **Step 4: Run green.** No production code should be needed (new event auto-participates); if decoding fails, the event isn't wired into `AccountingEvent` — verify Task 4 Step 1 added it to `transactionEvents`.

- [ ] **Step 5: commit**

```bash
just format && just lint
git add test/fixtures/events/transaction-import-reconciled.json test/Infrastructure/Eventium/SchemaSpec.hs
git commit -m "test(transaction): schema round-trip for TransactionImportReconciled (#148)"
```

---

## Task 6: `BankImportReadModel` — project the event, index, `isReconciled`

**Files:**
- Modify: `src/Application/ReadModels/BankImportReadModel.hs`
- Test: `test/Application/**` (add a spec near the existing bank-import read-model coverage; inspect `test/Application/Services/BankImportServiceSpec.hs` and `test/Application/Services/BankImport/` for the in-memory/SQLite harness).

- [ ] **Step 1: Write the failing test** — applying a `TransactionImportReconciled` global event inserts one `imported_transactions` row per external id (both-leg transfer case inserts two, same tx id); `isImported` then returns True for each; `isReconciled txId` returns True. Re-applying is a no-op (`insertUnique`).

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement.**

Extend `applyBankImportEvent` (mirrors the `TransactionPostingInitiatedEvent` clause):

```haskell
        TransactionImportReconciledEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Just txId ->
              forM_ (importInfoExternalTransactionIdsOf evt) $ \extId ->
                void $ insertUnique (ImportedTransactionEntity extId txId)
            Nothing -> pure ()
```

(Use `evt.externalTransactionIds` directly via `OverloadedRecordDot`; add the `TransactionImportReconciled(..)` import.) Add the `transaction_id` index + query:

```haskell
-- add to a startup index step (mirror createTransactionIndexes; BankImport's
-- initialize currently only migrates — add a rawExecute for the index there):
--   CREATE INDEX IF NOT EXISTS idx_imported_transactions_tx
--     ON imported_transactions (transaction_id)

-- | Whether a transaction already carries import attribution (was imported or
-- reconciled). Reverse lookup used by reconciliation candidate exclusion.
isReconciled :: (MonadIO m) => TransactionId -> SqlPersistT m Bool
isReconciled txId =
  not . null <$> selectList [ImportedTransactionEntityTransactionId ==. txId] [LimitTo 1]
```

Export `isReconciled`. Add `selectList`, `(==.)`, `LimitTo` to the persistent import list.

- [ ] **Step 4: Run green** for the new spec + existing `BankImport` suites.

- [ ] **Step 5: commit**

```bash
just format && just lint
git add -A
git commit -m "feat(import): project TransactionImportReconciled into dedup table + isReconciled query (#148)"
```

---

## Task 7: `Transaction` read model — apply the event, candidate queries

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Test: `test/Application/ReadModels/` (inspect for the existing transaction read-model spec + SQLite harness).

- [ ] **Step 1: Write failing tests**
  - Applying `TransactionImportReconciled` with `mcc = Just "5411"` sets the row `mcc`; with `mcc = Nothing` leaves an existing `mcc` untouched (non-clobber).
  - `findReconciliationCandidates` returns only Completed rows on the correct leg for the account, exact amount+currency, matching kind, within the date range; excludes rows outside the window / wrong amount / wrong kind / non-Completed.

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement.**

Import `TransactionImportReconciled (..)` from `Domain.Models`. Add to `applyTransactionEvent`:

```haskell
          TransactionImportReconciledEvent evt ->
            modifyTx txId $ \e ->
              e
                { transactionEntityMcc = maybe e.transactionEntityMcc Just (importReconciledMcc evt),
                  transactionEntityVersion = ver
                }
```

where `importReconciledMcc evt = evt.mcc` (via record dot; keep the `maybe … Just` non-clobber shape so `Nothing` preserves the existing value).

Add the candidate query (indexed by the existing `idx_transactions_source`/`_target`/`_date`):

```haskell
-- | Which leg the local account sits on for the import direction.
data LegSide = SourceLeg | TargetLeg deriving (Show, Eq)

-- | Completed manual candidates on `account` on `legSide`, with exact
-- `amount` (currency-tagged Money), matching `kind`, business date within
-- [from, to]. Callers exclude already-reconciled ids via
-- 'BankImportReadModel.isReconciled'. Amount equality is exact (no fuzz).
findReconciliationCandidates ::
  (MonadIO m) =>
  AccountId ->
  LegSide ->
  Money ->
  TransactionKind ->
  UTCTime -> -- from
  UTCTime -> -- to
  SqlPersistT m [(TransactionId, TransactionData)]
findReconciliationCandidates account legSide amount kind from to = do
  let legFilter = case legSide of
        SourceLeg -> [TransactionEntitySourceAccountId ==. account, TransactionEntitySourceAmount ==. amount]
        TargetLeg -> [TransactionEntityTargetAccountId ==. account, TransactionEntityTargetAmount ==. amount]
      filters =
        legFilter
          ++ [ TransactionEntityStatusKind ==. CompletedKind,
               TransactionEntityDate >=. from,
               TransactionEntityDate <=. to
             ]
  rows <- selectList filters []
  -- kind is on the deserialized transactionType; filter in Haskell (kindOf).
  withLabels [r | r@(Entity _ e) <- rows, kindOf e.transactionEntityTransactionType == kind]
```

Add a sibling `findTransferReconciliationCandidates :: AccountId -> AccountId -> Money -> UTCTime -> UTCTime -> SqlPersistT m [(TransactionId, TransactionData)]` returning Completed `Transfer` rows with `sourceAccountId == dLocal`, `targetAccountId == cLocal`, `sourceAmount == money`, within window (kind `TransferKind`). Export `findReconciliationCandidates`, `findTransferReconciliationCandidates`, `LegSide (..)`. Import `TransactionKind`, `kindOf` from `Domain.Core.Types`.

- [ ] **Step 4: Run green** for new + existing transaction read-model suites.

- [ ] **Step 5: commit**

```bash
just format && just lint
git add -A
git commit -m "feat(transaction): read-model apply for reconcile + candidate queries (#148)"
```

---

## Task 8: Audit-history parity

**Files:**
- Modify: `src/Application/Services/TransactionHistoryService.hs:113-131`, `:178-197`
- Test: `test/Application/Services/TransactionHistoryServiceSpec.hs`

- [ ] **Step 1: Write the failing test** — a stream containing a `TransactionImportReconciled` event yields a `HistoryImportReconciled` entry (mirror the `isContactSet` predicate test at line 160).

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement** — add constructor `HistoryImportReconciled TransactionImportReconciled` to `TransactionHistoryEntry`, add the import, and the `toHistoryEntry` case:

```haskell
  TransactionImportReconciledEvent e -> Just (HistoryImportReconciled e)
```

(ToJSON/FromJSON are generically derived — no Web DTO change.)

- [ ] **Step 4: Run green.**

- [ ] **Step 5: commit**

```bash
just format && just lint
git add -A
git commit -m "feat(transaction): audit-history entry for import reconciliation (#148)"
```

---

## Task 9: `TransactionService.reconcileTransactionImport` + wire single-leg import

**Files:**
- Modify: `src/Application/Services/TransactionService.hs` (add `reconcileTransactionImport`), `src/Application/Services/BankImportService.hs`
- Test: `test/Application/Services/BankImportServiceSpec.hs`, `test/Integration/BankImportWorkflowSpec.hs`

- [ ] **Step 1: Add the service command-issuer** (mirror `setTransactionContact`, using `dispatchEdit`):

```haskell
reconcileTransactionImport ::
  TransactionId ->
  NonEmpty ExternalTransactionId ->
  Maybe MCC ->
  AppM (Either DomainError TransactionData)
reconcileTransactionImport transactionId externalIds mcc = runExceptT $ do
  let cmd = ReconcileTransactionImportTransactionCommand
              ReconcileTransactionImport { transactionId, externalTransactionIds = externalIds, mcc }
  ExceptT (dispatchEdit transactionId cmd)
```

Export it; add command import.

- [ ] **Step 2: Add the `AmbiguousReconciliation` skip reason** in `BankImportService.hs` `SkipReason` + `renderSkipReason` ("ambiguous duplicate; not auto-reconciled").

- [ ] **Step 3: Write the failing service/integration tests**
  - Manual expense recorded, then import the same movement (same account, amount, ±1 day) ⇒ exactly one ledger entry remains; the manual tx id now appears in `imported_transactions`; the import outcome is not a second transaction.
  - Two distinct manual expenses of the same amount same day, then import ⇒ `Skipped AmbiguousReconciliation`; no reconcile event; no new entry.
  - Re-run the import a second time ⇒ `Skipped AlreadyImported`; state unchanged (idempotency).
  - No manual candidate ⇒ imports fresh (today's behavior) — regression guard.

- [ ] **Step 4: Run red.**

- [ ] **Step 5: Implement the wiring** in `commitImport` (after the local-currency guard passes, before `commitMatchingCurrencyImport`). Pseudocode:

```haskell
-- direction = classify tx ; money in local currency C ; localAccId known
let legSide = case direction of ClassifiedExpense -> SourceLeg; ClassifiedIncome -> TargetLeg
    kind    = case direction of ClassifiedExpense -> ExpenseKind; ClassifiedIncome -> IncomeKind
    w       = reconciliationWindow           -- 3 days as NominalDiffTime
    (from, to) = (addUTCTime (negate w) tx.time, addUTCTime w tx.time)
candidates <- lift $ runDb (findReconciliationCandidates localAccId legSide money kind from to)
-- exclude already-reconciled
fresh <- lift $ filterM (\(tid, _) -> not <$> runDb (isReconciled tid)) candidates
let importedLeg = Leg (unMoney money) (moneyCurrency money) tx.time
    legOf td    = Leg (unMoney (legAmount legSide td)) (moneyCurrency (legAmount legSide td)) td.date
case reconcile w importedLeg [(tid, legOf td) | (tid, td) <- fresh] of
  UniqueMatch tid -> do
    _ <- lift (TransactionService.reconcileTransactionImport tid (tx.externalId :| []) tx.mcc)
    lift $ logInfo ("Reconciled import " <> display tx.externalId <> " onto manual tx " <> displayShow tid)
    pure (Imported tid)                      -- reuse Imported; the reconciled tx id
  Ambiguous _     -> pure (Skipped AmbiguousReconciliation)
  NoMatch         -> commitMatchingCurrencyImport userId externalAccId localAccId tx money direction
```

Add `reconciliationWindow :: NominalDiffTime` (a top-level constant = `3 * 86400`, documented as "±3 days, §1"). Add `legAmount SourceLeg td = td.sourceAmount ; legAmount TargetLeg td = td.targetAmount`. Import `Leg`, `reconcile`, `ReconciliationOutcome (..)`, `isReconciled`, `findReconciliationCandidates`, `LegSide (..)`, `IncomeKind`/`ExpenseKind`.

> New imports this module lacks today: `unMoney` from `Domain.Core.Types` (`Money -> Rational`, so `Leg (unMoney money) …` typechecks against `magnitude :: Rational`) and `addUTCTime` from `Data.Time` (the module currently imports only `UTCTime, utctDay`). `filterM`, `(:|)`, `moneyCurrency` are already in scope.

> Note: the candidate query already filters `Completed` + exact amount + window; the pure `reconcile` re-checks magnitude/currency/window as defense-in-depth and makes the ambiguity decision. Both layers agree.

- [ ] **Step 6: Run green** for the new tests and existing `BankImportServiceSpec` / `BankImportWorkflowSpec`.

- [ ] **Step 7: commit**

```bash
just format && just lint
git add -A
git commit -m "feat(import): reconcile a manual transaction on confident fuzzy match instead of double-booking (#148)"
```

---

## Task 10: Whole-pair transfer reconciliation

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (`importTransferPair`)
- Test: `test/Integration/BankImportWorkflowSpec.hs`

- [ ] **Step 1: Write the failing test** — a manual `Transfer` A→B (amount M, date T); import the detected internal-transfer pair (both legs) ⇒ no new Transfer; the manual transfer id gains **both** external ids in `imported_transactions`; re-sync ⇒ both legs `AlreadyImported`.

- [ ] **Step 2: Run red.**

- [ ] **Step 3: Implement** in `importTransferPair`, in the `else` branch (neither leg imported), before `postInternalTransfer`:

```haskell
    else do
      let money = ...                      -- reuse the resolved debit-leg Money
          w = reconciliationWindow
          (from, to) = (addUTCTime (negate w) dLeg.time, addUTCTime w dLeg.time)
      candidates <- runDb (findTransferReconciliationCandidates dLocal cLocal money from to)
      fresh <- filterM (\(tid, _) -> not <$> runDb (isReconciled tid)) candidates
      let importedLeg = Leg (unMoney money) (moneyCurrency money) dLeg.time
          legOf td = Leg (unMoney td.sourceAmount) (moneyCurrency td.sourceAmount) td.date
      case reconcile w importedLeg [(tid, legOf td) | (tid, td) <- fresh] of
        UniqueMatch tid -> do
          _ <- TransactionService.reconcileTransactionImport tid (dLeg.externalId :| [cLeg.externalId]) Nothing
          let out = Imported tid
          pure [(dLeg.externalAccountId, dLocal, out), (cLeg.externalAccountId, cLocal, out)]
        Ambiguous _ -> do
          let out = Skipped AmbiguousReconciliation
          pure [(dLeg.externalAccountId, dLocal, out), (cLeg.externalAccountId, cLocal, out)]
        NoMatch -> do                       -- unchanged: post fresh Transfer
          outcome <- postInternalTransfer userId dLocal cLocal dLeg cLeg
          pure [(dLeg.externalAccountId, dLocal, outcome), (cLeg.externalAccountId, cLocal, outcome)]
```

Note the `money`/currency resolution currently lives inside `postInternalTransfer`; lift the currency+`mkMoney` resolution so both reconcile and post can use it, or compute a lightweight debit-leg Money for the query. Keep the currency-skip semantics identical on the `NoMatch` path.

- [ ] **Step 4: Run green.**

- [ ] **Step 5: commit**

```bash
just format && just lint
git add -A
git commit -m "feat(import): reconcile a manual transfer against a later-imported pair (#148)"
```

---

## Task 11: Serialize both import paths under `withUserLock`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (relocate lock into `importMany`, drop from `importConnection`)
- Test: verify existing pull + file import suites stay green; add a note-level assertion if a lock-observing test exists.

The lock is **non-reentrant** (`Infrastructure.App`), so it must live at exactly one level. `importConnection` currently wraps `withUserLock` around fetch **and** `importMany`; the file path calls `importMany` unlocked.

- [ ] **Step 1: Move the lock into the shared sink.**
  - In `importMany`, wrap the body in `withUserLock userId $ do ...`.
  - In `importConnection`, remove its `withUserLock userId $` wrapper (its only write work is the `importMany` call; the provider fetch is read-only and is fine outside the lock). Keep the `logInfo` and regroup logic.
  - Confirm no other caller wraps `importMany` in `withUserLock` (would deadlock — non-reentrant). `grep -rn "withUserLock" src`.

- [ ] **Step 2: Build + run** the full `BankImport` + integration suites: `just build && cabal test all --test-option='--match' --test-option="/BankImport/"`. Expected: PASS, no deadlock/timeout.

- [ ] **Step 3: commit**

```bash
just format && just lint
git add -A
git commit -m "fix(import): serialize file-import path under withUserLock via shared importMany (#148)"
```

---

## Task 12: Whole-feature verification + docs

**Files:**
- Modify: `docs/architecture.md` (if it enumerates transaction events/read models — add `TransactionImportReconciled` and the reconciliation flow); mark the spec `status: completed`.

- [ ] **Step 1: Definitive `-Werror` build** (warm cache can mask regressions):

```bash
just rebuild
```
Expected: clean build, no warnings-as-errors.

- [ ] **Step 2: Full test suite**

```bash
just test
```
Expected: all green. (Note: full `cabal test all` needs a local `eventium_test` Postgres DB; ~28 failures there are environmental, per project memory — confirm the reconciliation/import/matching suites specifically pass.)

- [ ] **Step 3: Lint + format clean**

```bash
just check
```

- [ ] **Step 4: Update docs** — add the event + reconciliation flow to `docs/architecture.md` if it lists them; set the spec frontmatter `status: completed`.

- [ ] **Step 5: Final commit + PR**

```bash
git add -A
git commit -m "docs(transaction): record import-reconciliation flow; mark spec completed (#148)"
```
Then open the PR (base `master`, title `feat(import): reconcile manual entries with later bank import (#148)`), body summarizing the approach and linking the spec + tracker#50.

---

## Acceptance-criteria traceability

| Criterion (#148) | Covered by |
|---|---|
| No second ledger entry; balance once | Task 9/10 (reconcile) + Task 4 (balance-neutral event) |
| Deterministic, testable decision | Task 3 (`reconcile` pure total fn) |
| Re-syncs stay deduplicated | Task 6 (dedup projection) + Task 9/10 tests |
| Transfers covered | Task 10 (whole-pair); per-leg-of-pair deferred to tracker#44 (documented) |
| Property/integration coverage (exact, near, distinct-same-day, re-sync) | Tasks 3, 9 |
| Concurrency safety on both paths | Task 11 |
```
