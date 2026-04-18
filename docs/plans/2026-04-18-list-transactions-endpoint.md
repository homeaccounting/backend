---
status: draft
date: 2026-04-18
spec: docs/specs/2026-04-18-list-transactions-endpoint-design.md
issue: homeaccounting/backend#47
---

# List Transactions Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `GET /api/transactions?accountId=&from=&to=` returning every transaction the caller can see, scoped to accounts the caller has any role on, filtered by an optional `accountId` and inclusive date range (business time).

**Architecture:**
Filter-at-query-time against the existing `Application.ReadModels.Transaction` read model. No new events, no new projection, no new read-model state. The service layer computes the user-visible account set from `Application.ReadModels.Account.getAccessibleAccounts` and passes it alongside a `TransactionQuery` (the new CQRS-flavored filter record) to a new `listTransactions` read-model function. The HTTP handler validates inputs, wraps the result into a new `TransactionListResponse` DTO, and throws `ValidationErr` via the existing `validateField` helper on bad input.

**Tech Stack:** Haskell 9.10.3, RIO prelude, Servant, Hspec + QuickCheck, hspec-discover, in-memory read model (`TVar (Map …)`), `just` task runner, ormolu + hlint via `just check`.

**Branch:** `feat/list-transactions-endpoint` (already created during brainstorming — spec commits live here).

**Design reference:** `docs/specs/2026-04-18-list-transactions-endpoint-design.md`. Read sections §1–§6 before starting. The spec is authoritative; if the plan and spec disagree, flag it — do not silently diverge.

---

## File Map

Files created:

- `src/Application/ReadModels/Transaction.hs` — extended (see modifications below).
- `test/Application/ReadModels/TransactionQuerySpec.hs` — smart-constructor unit tests.
- `test/Application/ReadModels/TransactionListSpec.hs` — `listTransactions` unit tests (visibility, account filter, date bounds, sort, backdated, statuses).
- `test/Application/ReadModels/TransactionListPropertySpec.hs` — QuickCheck property: returned entries respect `from`/`to`.
- `test/Web/API/TransactionAPISpec.hs` — HTTP-level handler tests.

Files modified:

- `src/Application/ReadModels/Transaction.hs`
  - Add `Data.Set` import.
  - Add `TransactionQuery` type, `mkTransactionQuery`, `emptyTransactionQuery`, accessor functions.
  - Add `listTransactions` query function.
  - Update the module export list.
- `src/Web/Types.hs` — add `TransactionListResponse` record with `FromJSON`/`ToJSON` (mirrors `AccountListResponse`).
- `src/Application/Services/TransactionService.hs` — add `listTransactions` service function; import `getAccessibleAccounts` from `Application.ReadModels.Account` and `Data.Set`.
- `src/Web/API/TransactionAPI.hs`
  - Add `listTransactionsHandler`.
  - Add the new route to `TransactionAPI` **before** the `Capture "id" UUID` route so Servant picks it for bare `GET /api/transactions`.
  - Register the handler in `transactionServer`.
  - Export `listTransactionsHandler` from the module.

No changes to `package.yaml` / `backend.cabal`: `hspec-discover` auto-discovers any `*Spec.hs` under `test/`.

---

## Task 1 — `TransactionQuery` smart constructor

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Create: `test/Application/ReadModels/TransactionQuerySpec.hs`

- [ ] **Step 1.1: Update the module export list.**

Locate the `module Application.ReadModels.Transaction (...)` export list (currently at lines 29–48 of the file). Add a new section for the query type:

```haskell
module Application.ReadModels.Transaction
  ( -- * Read Model Types
    TransactionData (..),
    TransactionReadModel,

    -- * Read Model Creation
    createTransactionReadModel,

    -- * Event Handler
    handleTransactionEvents,

    -- * Query Types
    TransactionQuery,
    mkTransactionQuery,
    emptyTransactionQuery,
    queryAccountId,
    queryFrom,
    queryTo,

    -- * Query Functions
    getTransaction,
    getAllTransactions,
    transactionExists,
    listTransactions,

    -- * Helper Functions
    transactionToMap,
  )
where
```

> The data constructor for `TransactionQuery` is deliberately NOT exported — per CLAUDE.md "Never export data constructors or field selectors directly". `queryAccountId`, `queryFrom`, `queryTo` accessor functions are exported instead of raw selectors.

- [ ] **Step 1.2: Add the failing unit-test module.**

Create `test/Application/ReadModels/TransactionQuerySpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionQuerySpec
-- Description : Smart-constructor tests for TransactionQuery
module Application.ReadModels.TransactionQuerySpec (spec) where

import Application.ReadModels.Transaction
  ( emptyTransactionQuery,
    mkTransactionQuery,
    queryAccountId,
    queryFrom,
    queryTo,
  )
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types (AccountId)
import RIO
import Test.Hspec
import Testkit.Helpers (mockAccountId)

-- | Stable AccountId fixture.
sampleAccountId :: AccountId
sampleAccountId = mockAccountId (UUID.fromWords 1 0 0 0)

-- | 2026-01-15 00:00:00 UTC.
jan15 :: UTCTime
jan15 = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime 0)

-- | 2026-01-20 00:00:00 UTC.
jan20 :: UTCTime
jan20 = UTCTime (fromGregorian 2026 1 20) (secondsToDiffTime 0)

spec :: Spec
spec = describe "mkTransactionQuery" $ do
  it "accepts no bounds" $ do
    case mkTransactionQuery Nothing Nothing Nothing of
      Right q -> do
        queryAccountId q `shouldBe` Nothing
        queryFrom q `shouldBe` Nothing
        queryTo q `shouldBe` Nothing
      Left err -> expectationFailure $ "expected Right, got Left " <> show err

  it "accepts only-from" $
    mkTransactionQuery Nothing (Just jan15) Nothing `shouldSatisfy` isRight

  it "accepts only-to" $
    mkTransactionQuery Nothing Nothing (Just jan20) `shouldSatisfy` isRight

  it "accepts from == to" $
    mkTransactionQuery Nothing (Just jan15) (Just jan15) `shouldSatisfy` isRight

  it "accepts from < to" $
    mkTransactionQuery Nothing (Just jan15) (Just jan20) `shouldSatisfy` isRight

  it "rejects from > to" $ do
    case mkTransactionQuery Nothing (Just jan20) (Just jan15) of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected Left for from > to"

  it "preserves accountId filter" $
    case mkTransactionQuery (Just sampleAccountId) Nothing Nothing of
      Right q -> queryAccountId q `shouldBe` Just sampleAccountId
      Left err -> expectationFailure $ "expected Right, got Left " <> show err

  it "emptyTransactionQuery has no filters" $ do
    let q = emptyTransactionQuery
    queryAccountId q `shouldBe` Nothing
    queryFrom q `shouldBe` Nothing
    queryTo q `shouldBe` Nothing
```

- [ ] **Step 1.3: Run the test and confirm it fails.**

```bash
nix develop --command just build
```

Expected: compile error, `mkTransactionQuery` / `emptyTransactionQuery` / `queryAccountId` / `queryFrom` / `queryTo` not in scope.

- [ ] **Step 1.4: Implement the type and smart constructor.**

In `src/Application/ReadModels/Transaction.hs`, after the `TransactionReadModel` data declaration and before the `-- Read Model Creation` section, insert:

```haskell
-- -----------------------------------------------------------------------------
-- Query Types
-- -----------------------------------------------------------------------------

-- | Filter spec for 'listTransactions'.
--
-- The data constructor is deliberately hidden; build values via
-- 'mkTransactionQuery' (which enforces the 'from' <= 'to' invariant) or
-- 'emptyTransactionQuery' (no filters). Read fields via 'queryAccountId',
-- 'queryFrom', 'queryTo'.
data TransactionQuery = TransactionQuery
  { qAccountId :: Maybe AccountId,
    qFrom :: Maybe UTCTime,
    qTo :: Maybe UTCTime
  }
  deriving (Show, Eq)

-- | Build a 'TransactionQuery'. Fails with a human-readable message when
-- both bounds are present and 'from' > 'to'.
mkTransactionQuery ::
  Maybe AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Either Text TransactionQuery
mkTransactionQuery acct mFrom mTo =
  case (mFrom, mTo) of
    (Just f, Just t) | f > t ->
      Left "from must be <= to"
    _ ->
      Right
        TransactionQuery
          { qAccountId = acct,
            qFrom = mFrom,
            qTo = mTo
          }

-- | Query that matches every transaction (all filters unset).
emptyTransactionQuery :: TransactionQuery
emptyTransactionQuery =
  TransactionQuery
    { qAccountId = Nothing,
      qFrom = Nothing,
      qTo = Nothing
    }

-- | Account filter, if any.
queryAccountId :: TransactionQuery -> Maybe AccountId
queryAccountId = qAccountId

-- | Lower bound on the transaction's business timestamp, inclusive.
queryFrom :: TransactionQuery -> Maybe UTCTime
queryFrom = qFrom

-- | Upper bound on the transaction's business timestamp, inclusive.
queryTo :: TransactionQuery -> Maybe UTCTime
queryTo = qTo
```

- [ ] **Step 1.5: Run the test and confirm it passes.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='mkTransactionQuery'
```

Expected: all 8 `mkTransactionQuery` cases green.

- [ ] **Step 1.6: Run ormolu + hlint for the touched files.**

```bash
nix develop --command just check
```

Expected: clean.

- [ ] **Step 1.7: Commit.**

```bash
git add src/Application/ReadModels/Transaction.hs \
        test/Application/ReadModels/TransactionQuerySpec.hs
git commit -m "$(cat <<'EOF'
feat(read-models): add TransactionQuery smart constructor

Introduce the TransactionQuery filter type used by the upcoming
list-transactions endpoint (homeaccounting/backend#47). The smart
constructor enforces the from <= to cross-field invariant; an
emptyTransactionQuery escape hatch exists for callers and tests that
want the "match everything visible" query.
EOF
)"
```

---

## Task 2 — `listTransactions` read-model function (visibility + account filter)

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Create: `test/Application/ReadModels/TransactionListSpec.hs`

- [ ] **Step 2.1: Add the failing test module.**

Create `test/Application/ReadModels/TransactionListSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionListSpec
-- Description : Unit tests for Application.ReadModels.Transaction.listTransactions
--
-- Tests are driven by feeding synthesized GlobalStreamEvent values into the
-- read model's own event handler (handleTransactionEvents). This ensures the
-- seeding path mirrors production exactly — no test-only insertion hole.
module Application.ReadModels.TransactionListSpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    createTransactionReadModel,
    emptyTransactionQuery,
    handleTransactionEvents,
    listTransactions,
    mkTransactionQuery,
  )
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    TransactionId,
    TransferType (..),
    unTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransferInitiated (..))
import qualified Eventium
import Eventium (StreamEvent (..), emptyMetadata)
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountId,
    mockMoneyWith,
    mockTransactionId,
    mockUserId,
  )

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

acctA, acctB, acctC :: AccountId
acctA = mockAccountId (UUID.fromWords 1 0 0 0)
acctB = mockAccountId (UUID.fromWords 2 0 0 0)
acctC = mockAccountId (UUID.fromWords 3 0 0 0)

tx :: Word32 -> TransactionId
tx n = mockTransactionId (UUID.fromWords n 0 0 0)

-- | Build a TransferInitiated GlobalStreamEvent occurring at the given
-- real-world time. createdAt is set to @persistedAt@; occurredAt is set
-- to @businessAt@ (the field that listTransactions must filter on).
--
-- Shape matches @processEvent@ in Application.ReadModels.Transaction:
-- GlobalStreamEvent = StreamEvent () SequenceNumber (VersionedStreamEvent)
-- VersionedStreamEvent = StreamEvent UUID EventVersion AccountingEvent.
mkInitiatedEvent ::
  TransactionId ->
  AccountId -> -- source
  AccountId -> -- target
  UTCTime -> -- businessAt (occurredAt)
  UTCTime -> -- persistedAt (createdAt)
  Int64 -> -- global sequence number
  Eventium.GlobalStreamEvent AccountingEvent
mkInitiatedEvent txId src tgt businessAt persistedAt seqNo =
  let inner =
        StreamEvent
          (unTransactionId txId)
          0
          ( (emptyMetadata "TransferInitiated")
              { Eventium.createdAt = Just persistedAt,
                Eventium.occurredAt = Just businessAt
              }
          )
          ( TransferInitiatedEvent
              TransferInitiated
                { sourceAccountId = src,
                  targetAccountId = tgt,
                  sourceAmount = mockMoneyWith USD 100,
                  targetAmount = mockMoneyWith USD 100,
                  exchangeRate = Nothing,
                  description = "seed",
                  by = mockUserId (UUID.fromWords 9 0 0 0),
                  transferType = Transfer,
                  externalTransactionId = Nothing
                }
          )
   in StreamEvent () seqNo inner

-- | Seed a fresh TransactionReadModel TVar with the given events.
-- Return type is inferred so we don't have to name the opaque
-- @TransactionReadModel@ type.
seedReadModel events = do
  tvar <- createTransactionReadModel
  handleTransactionEvents tvar events
  pure tvar

-- Simple time fixtures.
t :: Integer -> Int -> Int -> UTCTime
t y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "listTransactions / visibility set" $ do
    it "includes transactions whose source is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      results <- listTransactions tvar (Set.singleton acctA) emptyTransactionQuery
      map fst results `shouldBe` [tx 1]

    it "includes transactions whose target is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      results <- listTransactions tvar (Set.singleton acctB) emptyTransactionQuery
      map fst results `shouldBe` [tx 1]

    it "excludes transactions where neither side is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      results <- listTransactions tvar (Set.singleton acctC) emptyTransactionQuery
      results `shouldBe` []

  describe "listTransactions / accountId filter" $ do
    it "narrows to a single account (source match)" $ do
      let e1 = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          e2 = mkInitiatedEvent (tx 2) acctB acctC (t 2026 1 16) (t 2026 1 16) 1
      tvar <- seedReadModel [e1, e2]
      q <- either (fail . show) pure $
             mkTransactionQuery (Just acctA) Nothing Nothing
      results <- listTransactions tvar (Set.fromList [acctA, acctB, acctC]) q
      map fst results `shouldBe` [tx 1]

    it "returns empty when the account is outside the visibility set" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      q <- either (fail . show) pure $
             mkTransactionQuery (Just acctC) Nothing Nothing
      results <- listTransactions tvar (Set.fromList [acctA, acctB]) q
      results `shouldBe` []

  describe "listTransactions / date bounds" $ do
    it "is inclusive on the from boundary" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      q <- either (fail . show) pure $
             mkTransactionQuery Nothing (Just (t 2026 1 15)) Nothing
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 1]

    it "is inclusive on the to boundary" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      q <- either (fail . show) pure $
             mkTransactionQuery Nothing Nothing (Just (t 2026 1 15))
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 1]

    it "excludes entries outside the bounds" $ do
      let before = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 10) (t 2026 1 10) 0
          inside = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 15) (t 2026 1 15) 1
          after' = mkInitiatedEvent (tx 3) acctA acctB (t 2026 1 20) (t 2026 1 20) 2
      tvar <- seedReadModel [before, inside, after']
      q <- either (fail . show) pure $
             mkTransactionQuery Nothing (Just (t 2026 1 12)) (Just (t 2026 1 17))
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 2]

  describe "listTransactions / ordering" $ do
    it "sorts by business timestamp descending" $ do
      let older = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 10) (t 2026 1 10) 0
          newer = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 20) (t 2026 1 20) 1
      tvar <- seedReadModel [older, newer]
      results <- listTransactions tvar (Set.singleton acctA) emptyTransactionQuery
      map fst results `shouldBe` [tx 2, tx 1]

  describe "listTransactions / business-time filter (backdated regression guard)" $ do
    it "matches the occurredAt window, NOT the createdAt window" $ do
      -- Created today, but happened long ago:
      let occurredPast = t 2026 1 15
          createdNow   = t 2026 4 18
          e = mkInitiatedEvent (tx 1) acctA acctB occurredPast createdNow 0
      tvar <- seedReadModel [e]

      -- Bracketing the business date must match.
      qBusiness <- either (fail . show) pure $
        mkTransactionQuery Nothing (Just (t 2026 1 14)) (Just (t 2026 1 16))
      resultsBusiness <- listTransactions tvar (Set.singleton acctA) qBusiness
      map fst resultsBusiness `shouldBe` [tx 1]

      -- Bracketing the persistence date must NOT match — this fails loudly
      -- if a future refactor accidentally filters on createdAt.
      qPersist <- either (fail . show) pure $
        mkTransactionQuery Nothing (Just (t 2026 4 17)) (Just (t 2026 4 19))
      resultsPersist <- listTransactions tvar (Set.singleton acctA) qPersist
      resultsPersist `shouldBe` []
```

- [ ] **Step 2.2: Run the test suite and confirm it fails to compile.**

```bash
nix develop --command just build
```

Expected: `listTransactions` not in scope.

- [ ] **Step 2.3: Implement `listTransactions` in the read model.**

In `src/Application/ReadModels/Transaction.hs`:

1. Add `import qualified Data.Set as Set` and `import Data.Set (Set)` to the imports.
2. Below the existing `transactionExists` query, add:

```haskell
-- | List transactions visible to the caller, filtered by 'TransactionQuery'.
--
-- Semantics (see docs/specs/2026-04-18-list-transactions-endpoint-design.md):
--
--  1. Keep entries where at least one of sourceAccountId/targetAccountId is in
--     the visible set (access-control precondition supplied by the service).
--  2. If the query carries an accountId, require the same id to appear on
--     source or target. An accountId outside the visible set therefore
--     naturally produces zero matches.
--  3. Apply inclusive from/to bounds to 'TransactionData.date', which is the
--     transaction's business timestamp (TransferInitiated event's occurredAt,
--     falling back to createdAt only when occurredAt is unset).
--  4. Sort by date descending; ties are broken by TransactionId.
listTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  Set AccountId ->
  TransactionQuery ->
  m [(TransactionId, TransactionData)]
listTransactions readModelTVar visible query = do
  model <- liftIO $ readTVarIO readModelTVar
  let matches =
        [ (txId, td)
        | (txId, td) <- Map.toList model.summaryData,
          isVisible td,
          matchesAccount td,
          matchesFrom td,
          matchesTo td
        ]
  pure $ sortBy descendingByDate matches
  where
    isVisible td =
      Set.member td.sourceAccountId visible
        || Set.member td.targetAccountId visible
    matchesAccount td = case qAccountId query of
      Nothing -> True
      Just a -> td.sourceAccountId == a || td.targetAccountId == a
    matchesFrom td = case qFrom query of
      Nothing -> True
      Just f -> td.date >= f
    matchesTo td = case qTo query of
      Nothing -> True
      Just t' -> td.date <= t'
    descendingByDate (idA, a) (idB, b) =
      compare (b.date, idA) (a.date, idB)
```

> `sortBy` comes from `Data.List` via RIO's re-exports (`import RIO.List (sortBy)` if the compiler complains).

- [ ] **Step 2.4: Run the test suite and confirm green.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='listTransactions'
```

Expected: all cases green, including the backdated-regression case.

- [ ] **Step 2.5: Run `just check`.**

```bash
nix develop --command just check
```

Expected: clean.

- [ ] **Step 2.6: Commit.**

```bash
git add src/Application/ReadModels/Transaction.hs \
        test/Application/ReadModels/TransactionListSpec.hs
git commit -m "$(cat <<'EOF'
feat(read-models): listTransactions with visibility + date filters

Adds Application.ReadModels.Transaction.listTransactions: a query
function that filters the in-memory transaction read model by the
caller's visible-account set, an optional accountId, and an inclusive
date range. Filtering is on TransactionData.date (business time,
populated from event metadata occurredAt with createdAt as the
"unset" fallback per #41) — never on the event persistence timestamp.
Results are sorted most-recent first with TransactionId as the
tie-break.
EOF
)"
```

---

## Task 3 — Date-range property test

**Files:**
- Create: `test/Application/ReadModels/TransactionListPropertySpec.hs`

- [ ] **Step 3.1: Write the property spec.**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionListPropertySpec
-- Description : QuickCheck property: date-range filter is sound
module Application.ReadModels.TransactionListPropertySpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    createTransactionReadModel,
    handleTransactionEvents,
    listTransactions,
    mkTransactionQuery,
  )
import qualified Data.Set as Set
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    TransactionId,
    TransferType (..),
    unTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransferInitiated (..))
import qualified Eventium
import Eventium (StreamEvent (..), emptyMetadata)
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Helpers
  ( mockAccountId,
    mockMoneyWith,
    mockTransactionId,
    mockUserId,
  )

-- | Duplicated locally so each Spec stays self-contained. If a third call
-- site lands, promote to @Testkit/Generators.hs@ as a follow-up PR.
mkInitiatedEvent ::
  TransactionId ->
  AccountId ->
  AccountId ->
  UTCTime ->
  UTCTime ->
  Int64 ->
  Eventium.GlobalStreamEvent AccountingEvent
mkInitiatedEvent txId src tgt businessAt persistedAt seqNo =
  let inner =
        StreamEvent
          (unTransactionId txId)
          0
          ( (emptyMetadata "TransferInitiated")
              { Eventium.createdAt = Just persistedAt,
                Eventium.occurredAt = Just businessAt
              }
          )
          ( TransferInitiatedEvent
              TransferInitiated
                { sourceAccountId = src,
                  targetAccountId = tgt,
                  sourceAmount = mockMoneyWith USD 100,
                  targetAmount = mockMoneyWith USD 100,
                  exchangeRate = Nothing,
                  description = "seed",
                  by = mockUserId (UUID.fromWords 9 0 0 0),
                  transferType = Transfer,
                  externalTransactionId = Nothing
                }
          )
   in StreamEvent () seqNo inner

-- | A random UTC instant inside a fixed 366-day window starting 2026-01-01.
-- Uses @addUTCTime@ so the day counter is normalised correctly.
genBoundedDay :: Gen UTCTime
genBoundedDay = do
  dayOffset <- choose (0 :: Int, 365)
  let base = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
      delta = fromIntegral (dayOffset * 86400) :: NominalDiffTime
  pure $ addUTCTime delta base

spec :: Spec
spec = describe "listTransactions / property" $ do
  it "every returned entry has from <= date <= to when both bounds are set" $
    property $ \(Positive n) -> ioProperty $ do
      let acctA = mockAccountId (UUID.fromWords 1 0 0 0)
          acctB = mockAccountId (UUID.fromWords 2 0 0 0)
      dates <- generate (vectorOf (min n 20) genBoundedDay)
      let events =
            [ mkInitiatedEvent
                (mockTransactionId (UUID.fromWords (fromIntegral i) 0 0 0))
                acctA
                acctB
                d
                d
                (fromIntegral i)
              | (i, d) <- zip [(1 :: Word32) ..] dates
            ]
      (fromD, toD) <- generate $ do
        a <- genBoundedDay
        b <- genBoundedDay
        pure (min a b, max a b)
      tvar <- createTransactionReadModel
      handleTransactionEvents tvar events
      q <-
        either (fail . show) pure $
          mkTransactionQuery Nothing (Just fromD) (Just toD)
      results <- listTransactions tvar (Set.singleton acctA) q
      pure $ all (\(_, td) -> td.date >= fromD && td.date <= toD) results
```

> `NominalDiffTime` comes from `Data.Time`; if the import trips on it, add it explicitly to the import list. `addUTCTime` is the standard way to shift a `UTCTime` — never arithmetic directly on the `DiffTime` component (which caps at 86400 seconds per day and won't carry).

- [ ] **Step 3.2: Run the property test.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='listTransactions / property'
```

Expected: green, 100+ QuickCheck runs.

- [ ] **Step 3.3: `just check` and commit.**

```bash
nix develop --command just check
git add test/Application/ReadModels/TransactionListPropertySpec.hs
git commit -m "test(read-models): property test for listTransactions date range"
```

---

## Task 4 — `TransactionListResponse` DTO

**Files:**
- Modify: `src/Web/Types.hs`

- [ ] **Step 4.1: Find the `TransactionResponse` declaration in `Web/Types.hs`.**

Look around line 422 for `data TransactionResponse = TransactionResponse …`.

- [ ] **Step 4.2: Add the new response DTO right after `TransactionResponse`'s `FromJSON` instance (around line 443).**

```haskell
-- | Response envelope for GET /api/transactions.
--
-- Modelled on 'AccountListResponse'; leaves room for adding
-- 'nextCursor'/'total' later without a breaking change.
--
-- Example JSON:
--
-- @
-- {
--   "transactions": [ ... ],
--   "totalCount": 2
-- }
-- @
data TransactionListResponse = TransactionListResponse
  { transactions :: [TransactionResponse],
    totalCount :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionListResponse

instance FromJSON TransactionListResponse
```

- [ ] **Step 4.3: Export `TransactionListResponse` from the module's export list.**

Scroll to the top of `src/Web/Types.hs` and add `TransactionListResponse (..),` next to `TransactionResponse (..),`.

- [ ] **Step 4.4: Build + check.**

```bash
nix develop --command just build
nix develop --command just check
```

Expected: clean.

- [ ] **Step 4.5: Commit.**

```bash
git add src/Web/Types.hs
git commit -m "feat(web): add TransactionListResponse DTO"
```

> No handler uses it yet — this is a deliberately tiny commit so the DTO review is isolated from the handler plumbing.

---

## Task 5 — Service layer `listTransactions`

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`

- [ ] **Step 5.1: Extend the module export list.**

At the top of `src/Application/Services/TransactionService.hs` (module exports around line 26–33), add `listTransactions,` after `getTransaction,`.

- [ ] **Step 5.2: Add imports.**

Near the existing imports, add:

```haskell
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction
  ( TransactionQuery,
  )
import qualified Application.ReadModels.Transaction as TransactionRM
import qualified Data.Set as Set
```

Remove any now-redundant imports (the file already imports `Application.ReadModels.Transaction` — consolidate rather than double-imports).

- [ ] **Step 5.3: Add the new service function at the end of the `Service Functions` section.**

```haskell
-- | List transactions visible to the given user, filtered by the provided
-- query. A transaction is visible when its source or target belongs to an
-- account the user has any role on (Owner / Editor / Viewer).
--
-- Returns '[]' — never an error — when the user has no accessible accounts
-- or when the query's accountId is outside the visible set. The HTTP layer
-- is free to surface this as a 200 empty list (see spec §4 "accountId
-- provided but user has no access").
listTransactions ::
  UserId ->
  TransactionQuery ->
  AppM [(TransactionId, TransactionData)]
listTransactions userId query = do
  logDebug $ "Listing transactions for user " <> displayShow userId
  accountRM <- view accountReadModelL
  accessible <- liftIO $ AccountRM.getAccessibleAccounts accountRM userId
  let visible = Set.fromList [aid | (aid, _, _) <- accessible]
  if Set.null visible
    then do
      logDebug "User has no accessible accounts; returning empty list"
      pure []
    else do
      readModel <- view transactionReadModelL
      TransactionRM.listTransactions readModel visible query
```

- [ ] **Step 5.4: Build + check.**

```bash
nix develop --command just build
nix develop --command just check
```

Expected: clean.

- [ ] **Step 5.5: Commit.**

```bash
git add src/Application/Services/TransactionService.hs
git commit -m "$(cat <<'EOF'
feat(services): TransactionService.listTransactions

Compose the visible-account set from getAccessibleAccounts and delegate
filtering to the read model. Short-circuits to an empty list when the
caller has no accessible accounts, so the HTTP handler can stay a thin
wrapper.
EOF
)"
```

---

## Task 6 — HTTP route + handler

**Files:**
- Modify: `src/Web/API/TransactionAPI.hs`

- [ ] **Step 6.1: Extend imports.**

Add:

```haskell
import Data.Time (UTCTime)
import Application.ReadModels.Transaction (emptyTransactionQuery, mkTransactionQuery)
import Web.Types
  ( ...,
    TransactionListResponse (..),
    ...
  )
```

Fold these into the existing `import Web.Types (...)` block instead of duplicating it. `emptyTransactionQuery` is imported even though the handler uses `mkTransactionQuery` directly; drop it if unused at the end of Task 6 to keep the import list tight.

- [ ] **Step 6.2: Extend the API type.**

Locate the `type TransactionAPI = ...` declaration. Insert the new route **before** the final `:<|> AuthProtect "jwt" :> "api" :> "transactions" :> Capture "id" UUID :> Get '[JSON] TransactionResponse` line:

```haskell
-- GET /api/transactions?accountId=&from=&to= - List transactions visible to the caller.
:<|> AuthProtect "jwt"
  :> "api"
  :> "transactions"
  :> QueryParam "accountId" UUID
  :> QueryParam "from" UTCTime
  :> QueryParam "to" UTCTime
  :> Get '[JSON] TransactionListResponse
```

Routing sanity: Servant's route parser requires the path to be fully consumed. Bare `GET /api/transactions` will match the new `QueryParam` route (query strings are not path segments), while `GET /api/transactions/<uuid>` still matches `Capture "id" UUID`. Declaring the list route first is belt-and-braces.

- [ ] **Step 6.3: Update `transactionServer`.**

Extend the `(:<|>)` chain to include the new handler **in the same position** as the new route in the API type:

```haskell
transactionServer :: ServerT TransactionAPI AppM
transactionServer =
  incomeHandler
    :<|> expenseHandler
    :<|> transferHandler
    :<|> listTransactionsHandler
    :<|> getTransactionHandler
```

- [ ] **Step 6.4: Implement the handler.**

Append to the `Handlers` section:

```haskell
-- | Handler for GET /api/transactions - list transactions visible to the caller.
--
-- See docs/specs/2026-04-18-list-transactions-endpoint-design.md.
listTransactionsHandler ::
  AuthenticatedUser ->
  Maybe UUID ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  AppM TransactionListResponse
listTransactionsHandler user maybeAccountUuid maybeFrom maybeTo = do
  let userId = user.userId
  accountIdDomain <- traverse (validateField "accountId" . mkAccountId) maybeAccountUuid
  query <- validateField "query" $ mkTransactionQuery accountIdDomain maybeFrom maybeTo
  results <- TransactionService.listTransactions userId query
  let responses = map (uncurry fromTransactionData) results
      totalCount = length responses
  pure $ TransactionListResponse responses totalCount
```

- [ ] **Step 6.5: Export the handler.**

In the module export list at the top of the file, add `listTransactionsHandler,` next to the existing handler exports so tests can import it directly.

- [ ] **Step 6.6: Build + check.**

```bash
nix develop --command just build
nix develop --command just check
```

Expected: clean.

- [ ] **Step 6.7: Commit.**

```bash
git add src/Web/API/TransactionAPI.hs
git commit -m "$(cat <<'EOF'
feat(api): GET /api/transactions with accountId, from, to filters

Adds the list-transactions endpoint (homeaccounting/backend#47). The
handler validates the optional accountId UUID, the optional
from/to ISO-8601 timestamps (from <= to is enforced via the
TransactionQuery smart constructor), and delegates to
TransactionService.listTransactions. Results are wrapped in the new
TransactionListResponse envelope.
EOF
)"
```

---

## Task 7 — HTTP-level handler tests

**Files:**
- Create: `test/Web/API/TransactionAPISpec.hs`

- [ ] **Step 7.1: Write the spec.**

Model it on `test/Web/API/BankingAPISpec.hs` (same file you already studied for the spec). Mandatory cases:

1. **Happy path — empty list.** Default `createTestAppEnv`, authenticated user with no accounts: hit `GET /api/transactions`, expect 200 with `{"transactions":[], "totalCount":0}`. `totalCount == length transactions` falls out trivially here.
2. **Malformed `accountId`.** `GET /api/transactions?accountId=not-a-uuid` → Servant returns 400 automatically; assert status code.
3. **`from > to`.** `GET /api/transactions?from=2026-04-18T00:00:00Z&to=2026-04-10T00:00:00Z` → 400 `ValidationErr` (JSON envelope with `code = "VALIDATION_ERROR"`). Decode via `ErrorResponse` from `Web.Types`, as `BankingAPISpec` does.
4. **Unknown / forbidden `accountId`.** `GET /api/transactions?accountId=<random uuid not in access list>` → 200 with empty list. Confirms the "hide existence" semantics chosen in the spec.

**Documented divergence from spec §6:** the spec lists "Happy path: returns a correctly scoped, date-sorted list" as a case. That scenario is already covered end-to-end by `TransactionListSpec` (which exercises `listTransactions` directly) plus `TransactionQuerySpec` (smart constructor) plus the property spec. Adding a seeded HTTP-level equivalent would require driving the full `AccountService.create` + `TransactionService.initiateTransfer` + projection-settle chain through a Warp request, for no additional semantic coverage — just HTTP plumbing, which is exercised by cases 1/3/4 above. The seeded-list HTTP case is therefore intentionally omitted from this PR. If a future regression indicates the handler's DTO conversion has drifted, add it then.

Starter skeleton — `generateTestToken` is copied verbatim from `BankingAPISpec.hs` since it's not yet in `Testkit/`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionAPISpec
-- Description : HTTP-level tests for GET /api/transactions
module Web.API.TransactionAPISpec (spec) where

import Data.Aeson (eitherDecode)
import Network.HTTP.Types (hAuthorization, status200, status400)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified Data.UUID.V4 as UUID
import Domain.Core.Types (mkUserIdSafe)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Test.Hspec
import Test.Hspec.Wai
import Testkit.InMemoryEventStore (createTestAppEnv)
import Web.Server (buildApplication)
import Web.Types (ErrorResponse (..), TransactionListResponse (..))

mkApp :: IO Application
mkApp = buildApplication <$> createTestAppEnv

-- | Copied verbatim from BankingAPISpec. Promote to @Testkit/@ only if a
-- third spec needs it — two call sites is still within YAGNI territory.
generateTestToken :: IO Text
generateTestToken = do
  uuid <- UUID.nextRandom
  uid <- case mkUserIdSafe uuid of
    Nothing -> throwString "generateTestToken: random UUID rejected by mkUserIdSafe"
    Just u -> pure u
  r <- generateToken defaultJWTConfig uid "test@example.com"
  case r of
    Left err -> throwString $ "generateTestToken: JWT signing failed: " <> show err
    Right tok -> pure tok

spec :: Spec
spec =
  describe "GET /api/transactions"
    $ with mkApp
    $ do
      it "returns 200 + empty list for a user with no accounts" $ do
        token <- liftIO generateTestToken
        let headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <- request "GET" "/api/transactions" headers ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "body is not a TransactionListResponse: " <> err
            Right body -> do
              body.transactions `shouldBe` []
              body.totalCount `shouldBe` 0

      it "returns 400 when from > to" $ do
        token <- liftIO generateTestToken
        let headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <-
          request
            "GET"
            "/api/transactions?from=2026-04-18T00:00:00Z&to=2026-04-10T00:00:00Z"
            headers
            ""
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
            Left err -> expectationFailure $ "400 body is not an ErrorResponse: " <> err
            Right env -> env.code `shouldBe` "VALIDATION_ERROR"

      it "returns 400 when accountId is not a UUID" $ do
        token <- liftIO generateTestToken
        let headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <- request "GET" "/api/transactions?accountId=not-a-uuid" headers ""
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 200 + empty list when accountId is unknown / forbidden" $ do
        token <- liftIO generateTestToken
        let uuid = "00000000-0000-4000-8000-000000000999"
            headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <-
          request
            "GET"
            ("/api/transactions?accountId=" <> fromString uuid)
            headers
            ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "body is not a TransactionListResponse: " <> err
            Right body -> do
              body.transactions `shouldBe` []
              body.totalCount `shouldBe` 0
```

- [ ] **Step 7.2: Run the HTTP spec.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='/api/transactions'
```

Expected: green.

- [ ] **Step 7.3: `just check`.**

```bash
nix develop --command just check
```

Expected: clean.

- [ ] **Step 7.4: Commit.**

```bash
git add test/Web/API/TransactionAPISpec.hs
git commit -m "test(api): HTTP tests for GET /api/transactions"
```

---

## Task 8 — Final verification + PR

- [ ] **Step 8.1: Full rebuild and full test pass.**

```bash
nix develop --command just rebuild
nix develop --command just test
```

Expected: every spec green, no warnings, no `-Wall -Werror` failures.

- [ ] **Step 8.2: `just check` one final time.**

```bash
nix develop --command just check
```

- [ ] **Step 8.3: Push and open the PR.**

```bash
git push -u origin feat/list-transactions-endpoint
gh pr create \
  --title "feat(api): list transactions endpoint with account and date filters" \
  --body "$(cat <<'EOF'
## Summary

Closes homeaccounting/backend#47.

- New endpoint `GET /api/transactions?accountId=&from=&to=` returns every
  transaction the caller can see, scoped to accounts they have any role on.
- All three query params are optional. `from` / `to` are inclusive; `from > to`
  is rejected with a 400 ValidationErr.
- Filter is applied to the transaction's **business** timestamp (event
  metadata `occurredAt`, with `createdAt` as the "unset" fallback per #41) —
  never the persistence timestamp.
- Unknown / forbidden `accountId` returns 200 with an empty list (no
  existence leak).
- Response envelope: new `TransactionListResponse { transactions, totalCount }`
  modeled on the existing `AccountListResponse`.

## Design

See `docs/specs/2026-04-18-list-transactions-endpoint-design.md` and the
accompanying plan `docs/plans/2026-04-18-list-transactions-endpoint.md`.

## Test plan

- [x] `mkTransactionQuery` smart-constructor unit tests
  (`test/Application/ReadModels/TransactionQuerySpec.hs`)
- [x] `listTransactions` unit tests, incl. backdated regression guard
  (`test/Application/ReadModels/TransactionListSpec.hs`)
- [x] `listTransactions` QuickCheck property: `from <= date <= to`
  (`test/Application/ReadModels/TransactionListPropertySpec.hs`)
- [x] HTTP-level handler tests: happy path, malformed UUID, `from > to`,
  unknown / forbidden `accountId`
  (`test/Web/API/TransactionAPISpec.hs`)
- [x] `just check` + `just test` both green against a fresh build.
EOF
)"
```

> The project CLAUDE.md and the user's global instructions both call for conventional-commits PR titles and frontmatter-stamped specs/plans. The title above follows that convention.

- [ ] **Step 8.4: Close out.**

Mark the design doc `status: in-progress` → `status: completed` once the PR merges. Do not do this at PR-open time.

---

## Risk Register / Things That Can Bite

1. **`Map.toList` ordering is by key.** `listTransactions` relies on the final `sortBy` to impose descending `date` order; do not assume `Map.toList` already does anything meaningful. Covered by the "sorts by business timestamp descending" test.
2. **Servant route order.** The list route *must* sit before `Capture "id" UUID`. If both orderings compile, the tests will still catch a mis-ordering because `GET /api/transactions` would hit the capture route and fail to parse the empty path segment — but the failure mode is obscure. Declaring the list route first keeps it obvious.
3. **`TransferInitiated.by` is the initiator field.** Confirmed in `src/Domain/Transaction/Events.hs:78` and used by `TransferManagerSpec.hs:88`. Don't "correct" it to `initiatedBy`.
4. **RIO imports vs. `Data.List.sortBy`.** RIO re-exports `sortBy` via `RIO.List`; if the first compile errors on `sortBy`, add `import RIO.List (sortBy)`.
5. **Hidden `qAccountId`/`qFrom`/`qTo` fields.** These are record fields of the unexported `TransactionQuery` constructor. Inside `Application.ReadModels.Transaction` itself, `listTransactions` is allowed to access them directly (record field selectors are in scope in the defining module even though they're not re-exported). Callers *outside* this module must use the exported `queryAccountId` / `queryFrom` / `queryTo` accessors. Task 6's handler uses `mkTransactionQuery` and does not read the fields at all.
6. **`Data.Set` import.** The read model module grows a new `Data.Set` import — do not drop the existing `Data.Map.Strict` qualified import.
7. **Don't refactor `processEvent`.** Tempting to normalize the read-model's event handler while you're there — don't. Strictly additive PR (project Change Philosophy).
