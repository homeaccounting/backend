---
status: draft
---

# Transaction Query Language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ad-hoc `includeFailed`/`includeCancelled` flags on `GET /api/transactions` with a standardized, uniformly-extensible query grammar (date range, `status` IN, `label` IN) plus offset/limit pagination.

**Architecture:** A payload-free `StatusKind` discriminator + two reusable pure value objects (`Domain.Core.Range`, `Domain.Core.Page`) underpin a typed `TransactionFilter`. A new `Web.Query` module parses comma-separated query params into `NonEmpty` lists. The in-memory read model filters with uniform `maybe True` predicates and slices with `drop`/`take`; the signature `(Int, [..])` (totalMatches, pageSlice) maps 1:1 onto a future `COUNT(*)` + `OFFSET/LIMIT` DB query.

**Tech Stack:** Haskell (GHC 9.10), Servant, Eventium, Aeson, QuickCheck, Hspec, RIO.

**Spec:** `docs/specs/2026-06-09-transaction-query-language-design.md`

---

## File Structure

**New modules** (auto-discovered — `source-dirs: src` globs; `just build` runs hpack):
- `src/Domain/Core/Range.hs` — pure inclusive range + `mkRange` + `within`.
- `src/Domain/Core/Page.hs` — pure pagination value object + `mkPage` + caps.
- `src/Web/Query.hs` — `CommaSep` parser + orphan `FromHttpApiData StatusKind`.

**Modified:**
- `src/Domain/Transaction/Projection.hs` — add `StatusKind` + codec.
- `src/Application/ReadModels/Transaction.hs` — `TransactionQuery` → `TransactionFilter`; new `listTransactions` signature/predicates/pagination.
- `src/Application/Services/TransactionService.hs` — `listTransactions` takes `TransactionFilter` + `Page`, returns `(Int, [..])`.
- `src/Web/Types.hs` — extend `TransactionListResponse` with `limit`/`offset`.
- `src/Web/API/TransactionAPI.hs` — new route query params + handler.

**New tests** (auto-discovered — hspec-discover):
- `test/Domain/Transaction/StatusKindSpec.hs`
- `test/Domain/Core/RangeSpec.hs`
- `test/Domain/Core/PageSpec.hs`
- `test/Web/QuerySpec.hs`
- `test/Application/ReadModels/TransactionFilterSpec.hs`

**Modified / deleted tests:**
- Delete `test/Application/ReadModels/TransactionQuerySpec.hs` (references removed symbols).
- Rewrite `test/Application/ReadModels/TransactionListSpec.hs`.
- Rewrite `test/Web/API/TransactionAPISpec.hs`.
- Extend `test/Testkit/Generators.hs` (Arbitrary `StatusKind`).

## Build strategy (red windows)

Tasks 1–4 are purely additive and end fully green. **Task 5** performs the type flip: between its first and last step the build is red, and `cabal build` is green only at the end. Task 5's verification runs the *read-model* specs only; the HTTP integration spec (`TransactionAPISpec`) is intentionally rewritten in **Task 6**, so a full `just test` is green only after Task 6. Task 7 is final cleanup + full verification.

## Conventions used below

- Project uses RIO in the Web/Application layers (`NoImplicitPrelude`) but the **standard Prelude** in `Application.ReadModels.Transaction`, `Domain.Transaction.Projection`, and `Domain.Core.*`. Match each file's existing prelude — noted per task.
- Records use unprefixed fields + dot access (`OverloadedRecordDot`, `NoFieldSelectors`, `DuplicateRecordFields` are global default-extensions). Export records as `T (..)` like the existing `TransactionData (..)`.
- `StatusKind` exports its constructors (it carries no invariant), mirroring the existing `TransactionStatus (..)` export. This is a deliberate, codebase-consistent refinement of the spec's "constructors not exported" note (which targets *validated* newtypes like IDs).

---

### Task 1: `StatusKind` discriminator + wire codec

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs` (export list ~line 27; add definitions after `TransactionStatus`, ~line 95)
- Test: `test/Domain/Transaction/StatusKindSpec.hs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/Domain/Transaction/StatusKindSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.StatusKindSpec
-- Description : Codec + totality tests for the StatusKind query discriminator.
module Domain.Transaction.StatusKindSpec (spec) where

import Domain.Transaction.Projection
  ( StatusKind (..),
    TransactionStatus (..),
    parseStatusKind,
    renderStatusKind,
    statusKind,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "statusKind" $ do
    it "maps every TransactionStatus to a payload-free kind" $ do
      statusKind Pending `shouldBe` PendingKind
      statusKind Completed `shouldBe` CompletedKind
      statusKind (Failed "boom") `shouldBe` FailedKind
      statusKind Cancelled `shouldBe` CancelledKind

  describe "parseStatusKind / renderStatusKind" $ do
    it "round-trips every kind" $
      forM_ [minBound .. maxBound] $ \k ->
        parseStatusKind (renderStatusKind k) `shouldBe` Just k

    it "parses lowercase tokens" $
      parseStatusKind "failed" `shouldBe` Just FailedKind

    it "trims and lowercases" $
      parseStatusKind "  Cancelled " `shouldBe` Just CancelledKind

    it "rejects unknown tokens" $
      parseStatusKind "bogus" `shouldBe` Nothing
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Domain.Transaction.StatusKind/'`
Expected: compile error — `StatusKind`, `parseStatusKind`, `renderStatusKind`, `statusKind` not in scope.

- [ ] **Step 3: Add the export-list entries**

In `src/Domain/Transaction/Projection.hs`, change the `-- * Transaction Status` export block to:

```haskell
    -- * Transaction Status
    TransactionStatus (..),
    StatusKind (..),
    statusKind,
    parseStatusKind,
    renderStatusKind,
```

- [ ] **Step 4: Add the definitions + ensure `Data.Text` import**

Confirm the module imports `import qualified Data.Text as T` and `import Data.Text (Text)`; add whichever is missing near the existing imports. Then add after the `TransactionStatus` `FromJSON` instance (~line 95):

```haskell
-- | Payload-free discriminator of 'TransactionStatus', used by query
-- filters. Unlike 'TransactionStatus' it carries no @Failed@ reason, so the
-- query layer never depends on write-side failure detail.
data StatusKind = PendingKind | CompletedKind | FailedKind | CancelledKind
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

-- | Project a 'TransactionStatus' onto its 'StatusKind'.
statusKind :: TransactionStatus -> StatusKind
statusKind Pending = PendingKind
statusKind Completed = CompletedKind
statusKind (Failed _) = FailedKind
statusKind Cancelled = CancelledKind

-- | Render a 'StatusKind' to its lowercase wire token.
renderStatusKind :: StatusKind -> Text
renderStatusKind PendingKind = "pending"
renderStatusKind CompletedKind = "completed"
renderStatusKind FailedKind = "failed"
renderStatusKind CancelledKind = "cancelled"

-- | Parse a wire token (trimmed, case-insensitive) to a 'StatusKind'.
parseStatusKind :: Text -> Maybe StatusKind
parseStatusKind raw = case T.toLower (T.strip raw) of
  "pending" -> Just PendingKind
  "completed" -> Just CompletedKind
  "failed" -> Just FailedKind
  "cancelled" -> Just CancelledKind
  _ -> Nothing
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Domain.Transaction.StatusKind/'`
Expected: PASS (5 examples).

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Transaction/Projection.hs test/Domain/Transaction/StatusKindSpec.hs
git commit -m "feat(transaction): add StatusKind query discriminator + codec"
```

---

### Task 2: `Domain.Core.Range` reusable inclusive range

**Files:**
- Create: `src/Domain/Core/Range.hs`
- Test: `test/Domain/Core/RangeSpec.hs`

Use `Domain/Core/Errors.hs` as the structural template (same pragmas, base Prelude).

- [ ] **Step 1: Write the failing test**

Create `test/Domain/Core/RangeSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.RangeSpec
-- Description : Unit + property tests for the reusable inclusive Range.
module Domain.Core.RangeSpec (spec) where

import Domain.Core.Range (Range (..), mkRange, within)
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

spec :: Spec
spec = do
  describe "mkRange" $ do
    it "both absent -> Right Nothing (no constraint)" $
      mkRange (Nothing :: Maybe Int) Nothing `shouldBe` Right Nothing

    it "only-from -> Right (Just ..)" $
      mkRange (Just (1 :: Int)) Nothing `shouldBe` Right (Just (Range (Just 1) Nothing))

    it "from == to accepted" $
      mkRange (Just (5 :: Int)) (Just 5) `shouldBe` Right (Just (Range (Just 5) (Just 5)))

    it "from > to rejected" $
      mkRange (Just (9 :: Int)) (Just 1) `shouldSatisfy` isLeft

  describe "within" $ do
    prop "matches the bound semantics" $ \(mf :: Maybe Int) mt x ->
      within (Range mf mt) x
        == (maybe True (<= x) mf && maybe True (x <=) mt)
```

- [ ] **Step 2: Run it to confirm failure**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Domain.Core.Range/'`
Expected: compile error — module `Domain.Core.Range` not found.

- [ ] **Step 3: Create the module**

Create `src/Domain/Core/Range.hs`:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Core.Range
-- Description : Reusable inclusive range value object for query filters.
--
-- A 'Range' carries optional lower/upper bounds. 'mkRange' validates that a
-- fully-bounded range is non-empty (@from <= to@) and collapses the
-- "no bounds" case to 'Nothing' so an absent filter carries no constraint.
module Domain.Core.Range
  ( Range (..),
    mkRange,
    within,
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Inclusive range with independently-optional bounds.
data Range a = Range {from :: Maybe a, to :: Maybe a}
  deriving (Show, Eq, Generic)

-- | Smart constructor. 'Right' 'Nothing' when both bounds are absent (no
-- constraint); 'Left' when both are present and @from > to@.
mkRange :: (Ord a) => Maybe a -> Maybe a -> Either Text (Maybe (Range a))
mkRange Nothing Nothing = Right Nothing
mkRange mf mt = case (mf, mt) of
  (Just f, Just t) | f > t -> Left "from must be <= to"
  _ -> Right (Just (Range mf mt))

-- | Inclusive membership test against both bounds.
within :: (Ord a) => Range a -> a -> Bool
within (Range mf mt) x = maybe True (<= x) mf && maybe True (x <=) mt
```

LiquidHaskell note: per CLAUDE.md, the inter-field invariant is "both bounds present ⇒ `from <= to`", attached to the inner `Range`. LiquidHaskell is **not** currently wired into the build (no `-fplugin` in `package.yaml`, no `just` recipe), so add the refinement annotation when the LH workflow is run; `mkRange` already enforces the invariant at runtime.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Domain.Core.Range/'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Domain/Core/Range.hs test/Domain/Core/RangeSpec.hs
git commit -m "feat(core): add reusable Range value object"
```

---

### Task 3: `Domain.Core.Page` pagination value object

**Files:**
- Create: `src/Domain/Core/Page.hs`
- Test: `test/Domain/Core/PageSpec.hs`

- [ ] **Step 1: Write the failing test**

Create `test/Domain/Core/PageSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.PageSpec
-- Description : Validation tests for offset/limit pagination.
module Domain.Core.PageSpec (spec) where

import Domain.Core.Page (Page (..), defaultLimit, maxLimit, mkPage)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "mkPage" $ do
  it "absent params -> defaultLimit / offset 0" $
    mkPage Nothing Nothing `shouldBe` Right (Page defaultLimit 0)

  it "accepts in-range values" $
    mkPage (Just 25) (Just 100) `shouldBe` Right (Page 25 100)

  it "accepts limit == maxLimit" $
    mkPage (Just maxLimit) Nothing `shouldBe` Right (Page maxLimit 0)

  it "rejects limit == 0" $
    mkPage (Just 0) Nothing `shouldSatisfy` isLeft

  it "rejects limit > maxLimit" $
    mkPage (Just (maxLimit + 1)) Nothing `shouldSatisfy` isLeft

  it "rejects negative offset" $
    mkPage Nothing (Just (-1)) `shouldSatisfy` isLeft
```

- [ ] **Step 2: Run it to confirm failure**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Domain.Core.Page/'`
Expected: compile error — module `Domain.Core.Page` not found.

- [ ] **Step 3: Create the module**

Create `src/Domain/Core/Page.hs`:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Core.Page
-- Description : Offset/limit pagination value object for read-model queries.
--
-- 'mkPage' applies defaults for absent params and validates bounds, rejecting
-- (rather than clamping) out-of-range input so a client bug surfaces as a 400.
module Domain.Core.Page
  ( Page (..),
    mkPage,
    defaultLimit,
    maxLimit,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | A validated page request: @limit@ rows starting at @offset@.
data Page = Page {limit :: Int, offset :: Int}
  deriving (Show, Eq, Generic)

-- | Default page size when @limit@ is omitted.
defaultLimit :: Int
defaultLimit = 50

-- | Hard cap on @limit@.
maxLimit :: Int
maxLimit = 200

-- | Smart constructor. Absent @limit@ -> 'defaultLimit'; absent @offset@ -> 0.
-- Rejects @limit@ outside @1 .. maxLimit@ and negative @offset@.
mkPage :: Maybe Int -> Maybe Int -> Either Text Page
mkPage mLimit mOffset
  | l < 1 = Left ("limit must be >= 1, got " <> tshow l)
  | l > maxLimit = Left ("limit must be <= " <> tshow maxLimit <> ", got " <> tshow l)
  | o < 0 = Left ("offset must be >= 0, got " <> tshow o)
  | otherwise = Right (Page l o)
  where
    l = fromMaybe defaultLimit mLimit
    o = fromMaybe 0 mOffset
    tshow = T.pack . show
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Domain.Core.Page/'`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
git add src/Domain/Core/Page.hs test/Domain/Core/PageSpec.hs
git commit -m "feat(core): add Page pagination value object"
```

---

### Task 4: `Web.Query` — comma-separated param parsing

**Files:**
- Create: `src/Web/Query.hs`
- Test: `test/Web/QuerySpec.hs`

- [ ] **Step 1: Write the failing test**

Create `test/Web/QuerySpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.QuerySpec
-- Description : Tests for comma-separated query-param parsing.
module Web.QuerySpec (spec) where

import qualified Data.List.NonEmpty as NE
import Domain.Transaction.Projection (StatusKind (..))
import RIO
import Servant (parseQueryParam)
import Test.Hspec
import Web.Query (CommaSep (..))

parseStatuses :: Text -> Either Text (NE.NonEmpty StatusKind)
parseStatuses = fmap (.values) . parseQueryParam

spec :: Spec
spec = do
  describe "CommaSep StatusKind" $ do
    it "parses a single value" $
      parseStatuses "failed" `shouldBe` Right (FailedKind NE.:| [])

    it "parses multiple values" $
      parseStatuses "failed,cancelled"
        `shouldBe` Right (FailedKind NE.:| [CancelledKind])

    it "trims whitespace around tokens" $
      parseStatuses " failed , cancelled "
        `shouldBe` Right (FailedKind NE.:| [CancelledKind])

    it "rejects an empty element" $
      parseStatuses "failed,,cancelled" `shouldSatisfy` isLeft

    it "rejects an empty string" $
      parseStatuses "" `shouldSatisfy` isLeft

    it "rejects an unknown token" $
      parseStatuses "failed,bogus" `shouldSatisfy` isLeft
```

- [ ] **Step 2: Run it to confirm failure**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Web.Query/'`
Expected: compile error — module `Web.Query` not found.

- [ ] **Step 3: Create the module**

Create `src/Web/Query.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.Query
-- Description : Reusable wire-parsing for comma-separated query params.
--
-- 'CommaSep' parses @a,b,c@ into a 'NonEmpty' of any element type that has a
-- 'FromHttpApiData' instance. The orphan 'FromHttpApiData' 'StatusKind' lives
-- here (not in Domain) so the Domain layer takes no web/wire dependency; the
-- orphan warning is silenced by @-fno-warn-orphans@ in the library options.
module Web.Query
  ( CommaSep (..),
  )
where

import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Domain.Transaction.Projection (StatusKind, parseStatusKind)
import RIO
import Servant (FromHttpApiData (..))

-- | A non-empty, comma-separated list of values parsed from one query param.
newtype CommaSep a = CommaSep {values :: NE.NonEmpty a}
  deriving (Show, Eq)

instance (FromHttpApiData a) => FromHttpApiData (CommaSep a) where
  parseQueryParam raw =
    let tokens = map T.strip (T.splitOn "," raw)
     in if any T.null tokens
          then Left "comma-separated list has an empty element"
          else do
            parsed <- traverse parseQueryParam tokens
            case NE.nonEmpty parsed of
              Nothing -> Left "comma-separated list is empty"
              Just ne -> Right (CommaSep ne)

instance FromHttpApiData StatusKind where
  parseQueryParam raw =
    maybe (Left ("unknown status: " <> raw)) Right (parseStatusKind raw)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Web.Query/'`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
git add src/Web/Query.hs test/Web/QuerySpec.hs
git commit -m "feat(web): add CommaSep query-param parser + StatusKind instance"
```

---

### Task 5: Migrate read model + service + web to `TransactionFilter` + `Page`

> **Red window:** the build is red between Step 3 and Step 12. This task verifies with `just build` + the read-model specs only. `TransactionAPISpec` is rewritten in Task 6.

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Modify: `src/Application/Services/TransactionService.hs`
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/TransactionAPI.hs`
- Modify: `src/Telegram/Commands.hs` (in-process caller of the service — must change to keep the library build green)
- Modify: `test/Testkit/Generators.hs`
- Create: `test/Application/ReadModels/TransactionFilterSpec.hs`
- Rewrite: `test/Application/ReadModels/TransactionListSpec.hs`
- Rewrite: `test/Integration/TransactionCancellationIntegrationSpec.hs` (in-process caller; its old "default hides cancelled" assertions are obsolete under "absent = all")
- Delete: `test/Application/ReadModels/TransactionQuerySpec.hs`

- [ ] **Step 1: Delete the obsolete smart-constructor spec**

```bash
git rm test/Application/ReadModels/TransactionQuerySpec.hs
```
(Its `TransactionQuery`/accessor coverage is replaced by `TransactionFilterSpec` + `mkRange`/`mkPage` specs.)

- [ ] **Step 2: Write the new read-model unit spec (`TransactionFilterSpec`)**

Create `test/Application/ReadModels/TransactionFilterSpec.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionFilterSpec
-- Description : Construction tests for TransactionFilter.
module Application.ReadModels.TransactionFilterSpec (spec) where

import Application.ReadModels.Transaction
  ( emptyTransactionFilter,
    mkTransactionFilter,
  )
import qualified Data.List.NonEmpty as NE
import Domain.Transaction.Projection (StatusKind (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "TransactionFilter" $ do
  it "emptyTransactionFilter has no constraints" $ do
    let f = emptyTransactionFilter
    f.accountId `shouldBe` Nothing
    f.date `shouldBe` Nothing
    f.status `shouldBe` Nothing
    f.label `shouldBe` Nothing

  it "mkTransactionFilter carries the status set" $ do
    let f = mkTransactionFilter Nothing Nothing (Just (FailedKind NE.:| [CancelledKind])) Nothing
    f.status `shouldBe` Just (FailedKind NE.:| [CancelledKind])
```

- [ ] **Step 3: Replace `TransactionQuery` with `TransactionFilter` in the read model**

In `src/Application/ReadModels/Transaction.hs`:

a. **Export list** — replace the `-- * Query Types` block:
```haskell
    -- * Query Types
    TransactionFilter (..),
    mkTransactionFilter,
    emptyTransactionFilter,
```
(removes `TransactionQuery`, `mkTransactionQuery`, `emptyTransactionQuery`, and the five `query*` accessors).

b. **Imports** — add:
```haskell
import Data.List.NonEmpty (NonEmpty)
import Domain.Core.Page (Page)
import Domain.Core.Range (Range, within)
```
and extend the existing `Domain.Transaction.Projection` import to:
```haskell
import Domain.Transaction.Projection (StatusKind, TransactionStatus (Cancelled, Completed, Failed, Pending), statusKind)
```

c. **Type + constructors** — replace the `TransactionQuery`/`mkTransactionQuery`/`emptyTransactionQuery` block (current lines ~149–191) with:
```haskell
-- | Standardized transaction query filter. Each field is an optional
-- constraint; 'Nothing' means "no constraint on this field".
data TransactionFilter = TransactionFilter
  { accountId :: Maybe AccountId,
    date :: Maybe (Range UTCTime),
    status :: Maybe (NonEmpty StatusKind),
    label :: Maybe (NonEmpty LabelId)
  }
  deriving (Show, Eq)

-- | Assemble a filter. Cross-field validation (date @from <= to@) is the
-- caller's responsibility via 'Domain.Core.Range.mkRange' at the boundary.
mkTransactionFilter ::
  Maybe AccountId ->
  Maybe (Range UTCTime) ->
  Maybe (NonEmpty StatusKind) ->
  Maybe (NonEmpty LabelId) ->
  TransactionFilter
mkTransactionFilter a d s l =
  TransactionFilter {accountId = a, date = d, status = s, label = l}

-- | A filter with no constraints (every visible transaction matches).
emptyTransactionFilter :: TransactionFilter
emptyTransactionFilter = TransactionFilter Nothing Nothing Nothing Nothing
```

- [ ] **Step 4: Replace `listTransactions` (signature, predicates, pagination)**

Replace the current `listTransactions` (lines ~465–502) with:

```haskell
-- | List transactions visible to the caller, filtered by 'TransactionFilter'
-- and paginated by 'Page'. Returns @(totalMatches, pageSlice)@ where
-- @totalMatches@ counts all matches before slicing. Order:
-- filter -> sort (date desc, TransactionId tiebreak) -> count -> slice.
listTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  Set AccountId ->
  TransactionFilter ->
  Page ->
  m (Int, [(TransactionId, TransactionData)])
listTransactions readModelTVar visible filt page = do
  model <- liftIO $ readTVarIO readModelTVar
  let matches =
        [ (txId, td)
        | (txId, td) <- Map.toList model.transactions,
          isVisible td,
          matchesAccount td,
          matchesDate td,
          matchesStatus td,
          matchesLabel td
        ]
      sorted = sortBy descendingByDate matches
      total = length sorted
      slice = take page.limit (drop page.offset sorted)
  pure (total, slice)
  where
    isVisible td =
      Set.member td.sourceAccountId visible
        || Set.member td.targetAccountId visible
    matchesAccount td = case filt.accountId of
      Nothing -> True
      Just a -> td.sourceAccountId == a || td.targetAccountId == a
    matchesDate td = maybe True (\r -> within r td.date) filt.date
    matchesStatus td =
      maybe True (\ks -> statusKind td.status `elem` ks) filt.status
    matchesLabel td =
      maybe
        True
        (\ls -> not (Set.disjoint td.labels (Set.fromList (NE.toList ls))))
        filt.label
    descendingByDate (idA, a) (idB, b) =
      compare b.date a.date <> compare idA idB
```

(`Set.disjoint` is already reachable via the existing `qualified Data.Set as Set` import; `NE.toList` via the existing `qualified Data.List.NonEmpty as NE`. The `Cancelled`/`Completed`/`Pending` imports are now unused by this function — keep them only if still referenced elsewhere in the module; otherwise drop them from the import to avoid `-Wunused-imports` under `-Werror`.)

- [ ] **Step 5: Update `TransactionService.listTransactions`**

In `src/Application/Services/TransactionService.hs`:

a. Replace the `TransactionQuery` import with `TransactionFilter`; add `import Domain.Core.Page (Page)`.

b. Replace the function (lines ~213–228) with:
```haskell
listTransactions ::
  UserId ->
  TransactionFilter ->
  Page ->
  AppM (Int, [(TransactionId, TransactionData)])
listTransactions userId filt page = do
  logDebug $ "Listing transactions for user " <> displayShow userId
  accountRM <- view accountReadModelL
  accessible <- AccountRM.getAccessibleAccounts accountRM userId
  let visible = Set.fromList [aid | (aid, _, _) <- accessible]
  if Set.null visible
    then do
      logDebug "User has no accessible accounts; returning empty list"
      pure (0, [])
    else do
      readModel <- view transactionReadModelL
      ReadModel.listTransactions readModel visible filt page
```

- [ ] **Step 6: Extend the response envelope**

In `src/Web/Types.hs`, replace the `TransactionListResponse` record (lines ~565–568) with:
```haskell
data TransactionListResponse = TransactionListResponse
  { transactions :: [TransactionResponse],
    -- | Count of ALL matches before pagination (clients compute page count).
    totalCount :: Int,
    -- | Effective page size applied (after defaulting).
    limit :: Int,
    -- | Effective offset applied.
    offset :: Int
  }
  deriving (Show, Eq, Generic)
```
(Instances and the `TransactionListResponse (..)` export are unchanged.)

- [ ] **Step 7: Update the Servant route**

In `src/Web/API/TransactionAPI.hs`, replace the list-transactions route block (lines ~126–135) with:
```haskell
    -- GET /api/transactions - List transactions visible to the caller.
    -- Filters: accountId, dateFrom/dateTo (inclusive), status (CSV IN),
    -- label (CSV IN, set overlap). Pagination: limit (default 50, max 200),
    -- offset (default 0). All optional. See
    -- docs/specs/2026-06-09-transaction-query-language-design.md.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> QueryParam "accountId" UUID
      :> QueryParam "dateFrom" UTCTime
      :> QueryParam "dateTo" UTCTime
      :> QueryParam "status" (CommaSep StatusKind)
      :> QueryParam "label" (CommaSep UUID)
      :> QueryParam "limit" Int
      :> QueryParam "offset" Int
      :> Get '[JSON] TransactionListResponse
```

- [ ] **Step 8: Update the handler imports**

In `src/Web/API/TransactionAPI.hs` imports:
- change `Application.ReadModels.Transaction (TransactionData (..), mkTransactionQuery)` to `Application.ReadModels.Transaction (TransactionData (..), mkTransactionFilter)`;
- add `import Domain.Core.Page (mkPage)`;
- add `import Domain.Core.Range (mkRange)`;
- add `import Domain.Transaction.Projection (StatusKind)`;
- add `import Web.Query (CommaSep (..))`;
- extend the `Domain.Core.Types` import to include `mkDictionaryEntryId`.

- [ ] **Step 9: Rewrite `listTransactionsHandler`**

Replace the handler (lines ~410–427) with:
```haskell
listTransactionsHandler ::
  AuthenticatedUser ->
  Maybe UUID ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe (CommaSep StatusKind) ->
  Maybe (CommaSep UUID) ->
  Maybe Int ->
  Maybe Int ->
  AppM TransactionListResponse
listTransactionsHandler user mAccount mFrom mTo mStatus mLabel mLimit mOffset = do
  let userId = user.userId
  accountId <- traverse (validateField "accountId" . mkAccountId) mAccount
  dateRange <- validateField "date" $ mkRange mFrom mTo
  labels <-
    traverse (traverse (validateField "label" . mkDictionaryEntryId) . (.values)) mLabel
  page <- validateField "page" $ mkPage mLimit mOffset
  let statuses = (.values) <$> mStatus
      filt = mkTransactionFilter accountId dateRange statuses labels
  (total, results) <- TransactionService.listTransactions userId filt page
  let responses = map (uncurry fromTransactionData) results
  pure $ TransactionListResponse responses total page.limit page.offset
```

- [ ] **Step 9b: Update the in-process caller `src/Telegram/Commands.hs`**

This module calls the service directly (not over HTTP). Replace the `mkTransactionQuery` import with `mkTransactionFilter`; add `import Domain.Core.Range (mkRange)`, `import Domain.Core.Page (Page (..))`, `import Domain.Transaction.Projection (StatusKind (..))`, `import Data.List.NonEmpty (NonEmpty (..))`. Replace the `case mkTransactionQuery ... of` block (lines ~402–423) to build a filter (preserving the bot's "Pending+Completed, last 30 days" behaviour) and adapt to the `(total, results)` return:

```haskell
      case mkRange (Just fromDate) (Just now) of
        Left err -> do
          logError $ "Failed to build transactions query: " <> display err
          sendMsg chatId "Failed to list transactions. Please try again."
        Right dateRange -> do
          let filt = mkTransactionFilter maybeAcctId dateRange (Just (PendingKind :| [CompletedKind])) Nothing
          (total, results) <- TransactionService.listTransactions userId filt (Page 50 0)
          entryNames <- getDictionaryEntryNames telegramId
          let header = case selected of
                Just (_, name) -> "Transactions for " <> name <> " (last 30 days):"
                Nothing -> "Your transactions (last 30 days):"
          if null results
            then sendMsg chatId $ header <> "\n\nNo transactions found."
            else do
              let maxItems = 20
                  shown = take maxItems results
                  overflow = total - length shown
                  body = T.unlines $ map (formatTransactionLine entryNames) shown
                  suffix =
                    if overflow > 0
                      then "\n... and " <> tshow overflow <> " more."
                      else ""
              sendMsg chatId $ header <> "\n\n" <> body <> suffix
```

- [ ] **Step 9c: Update the in-process caller `test/Integration/TransactionCancellationIntegrationSpec.hs`**

Replace the import `emptyTransactionQuery, mkTransactionQuery` with `emptyTransactionFilter, mkTransactionFilter`; add `StatusKind (..)` to the existing `Domain.Transaction.Projection (TransactionStatus (..))` import (line 61); add `import Domain.Core.Page (Page (..))` and `import Data.List.NonEmpty (NonEmpty (..))`. Replace the two helpers (lines ~108–118):

```haskell
-- | List with no status filter — every status (incl. cancelled) is returned.
listAll :: AppEnv -> UserId -> IO [(TransactionId, TransactionData)]
listAll env uid = snd <$> runAppM env (listTransactions uid emptyTransactionFilter (Page 50 0))

-- | List with a status filter that excludes cancelled.
listExcludingCancelled :: AppEnv -> UserId -> IO [(TransactionId, TransactionData)]
listExcludingCancelled env uid =
  snd <$> runAppM env (listTransactions uid filt (Page 50 0))
  where
    filt = mkTransactionFilter Nothing Nothing (Just (PendingKind :| [CompletedKind, FailedKind])) Nothing
```

Rewrite the two now-obsolete visibility tests (lines ~209–223) to the new semantics, and repoint the third (line ~229) to `listAll`:

```haskell
    it "a status filter excluding cancelled omits cancelled transactions" $ do
      cf <- setupCancelFixture "cancel-list-default@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 50
      _ <- runCancel cf.cfEnv cf.cfUserId txId
      txns <- listExcludingCancelled cf.cfEnv cf.cfUserId
      map fst txns `shouldNotContain` [txId]

    it "default listTransactions (no status filter) includes cancelled transactions" $ do
      cf <- setupCancelFixture "cancel-list-include@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 50
      _ <- runCancel cf.cfEnv cf.cfUserId txId
      txns <- listAll cf.cfEnv cf.cfUserId
      map fst txns `shouldContain` [txId]
```
(Update the comment block at lines ~21 / the `listDefault`/`listWithCancelled` call sites accordingly; the third test at ~229 uses `listAll`.)

- [ ] **Step 10: Add `Arbitrary StatusKind` to the test generators**

In `test/Testkit/Generators.hs`, add to the `Domain.Transaction.Projection` import: `StatusKind (..)`, and add an instance near the other `Arbitrary` instances:
```haskell
instance Arbitrary StatusKind where
  arbitrary = arbitraryBoundedEnum
```
(The module already has `{-# OPTIONS_GHC -Wno-orphans #-}` and imports `Test.QuickCheck`.)

- [ ] **Step 11: Rewrite `TransactionListSpec`**

Rewrite `test/Application/ReadModels/TransactionListSpec.hs`. Keep the existing event-seeding helpers (`mkInitiatedEvent`, `seedReadModel`, `t`, `acctA/B/C`, `tx`) verbatim, but:
- change the imports to use `emptyTransactionFilter`, `mkTransactionFilter` (drop `emptyTransactionQuery`, `mkTransactionQuery`); add `import Domain.Core.Page (Page (..), defaultLimit, mkPage)`, `import Domain.Core.Range (Range (..))`, `import Domain.Transaction.Projection (StatusKind (..))`, `import qualified Data.List.NonEmpty as NE`, and `TransactionPostingFailed`-style helpers already present;
- add a local default page helper `allPage = Page defaultLimit 0`;
- update every `listTransactions tvar visible q` call to `listTransactions tvar visible filt allPage` and assert against the returned tuple, e.g.:
```haskell
(total, results) <- listTransactions tvar (Set.singleton acctA) emptyTransactionFilter allPage
map fst results `shouldBe` [tx 1]
total `shouldBe` 1
```
- add new `describe` blocks:
  - **status filter**: seed Pending/Completed/Failed/Cancelled txns (use the existing `TransactionPostingFailed`/cancellation events); assert `mkTransactionFilter Nothing Nothing (Just (FailedKind NE.:| [CancelledKind])) Nothing` returns only those two; assert omitting status (`emptyTransactionFilter`) returns ALL four.
  - **label overlap**: seed txns with differing label sets; assert a filter listing one label returns every txn containing it.
  - **pagination**: seed N>limit txns; assert slice length == limit, `total == N`, `offset` past end yields `[]` with `total == N`, and concatenating successive pages reconstructs the full sorted id list.

Property block (in the same file or a new `TransactionListPropertySpec.hs`): using `Testkit.Generators`, for a random `Page` (via `mkPage`) over a seeded model, assert slice length `<= limit` and `total` is independent of the page.

- [ ] **Step 12: Build, then run all read-model + foundation specs**

Run: `just build`
Expected: compiles cleanly (no `-Werror` failures).

Run: `cabal test --test-show-details=direct --test-option='--match' --test-option='/Application.ReadModels.Transaction/'` then the foundation specs (`/Domain.Core/`, `/Web.Query/`, `/Domain.Transaction.StatusKind/`).
Expected: PASS. (A full `just test` still has stale `TransactionAPISpec` failures — fixed in Task 6.)

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "feat(transaction): migrate list endpoint to TransactionFilter + offset/limit pagination"
```

---

### Task 6: Rewrite the HTTP integration spec

**Files:**
- Rewrite: `test/Web/API/TransactionAPISpec.hs`

- [ ] **Step 1: Update the `GET /api/transactions` describe block**

Keep the existing fixtures/imports; extend `Web.Types` import to keep `TransactionListResponse (..)`. Replace/extend the cases to cover the new contract. Representative cases:

```haskell
it "returns 200 + empty list with echoed pagination for a user with no accounts" $ do
  token <- liftIO generateTestToken
  resp <- getJSONAuth "/api/transactions" token
  liftIO $ do
    simpleStatus resp `shouldBe` status200
    case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
      Left err -> expectationFailure $ "not a TransactionListResponse: " <> err
      Right body -> do
        body.transactions `shouldBe` []
        body.totalCount `shouldBe` 0
        body.limit `shouldBe` 50
        body.offset `shouldBe` 0

it "returns 400 when dateFrom > dateTo (field \"date\")" $ do
  token <- liftIO generateTestToken
  resp <-
    request "GET"
      "/api/transactions?dateFrom=2026-04-18T00:00:00Z&dateTo=2026-04-10T00:00:00Z"
      [bearerHeader token] ""
  liftIO $ do
    simpleStatus resp `shouldBe` status400
    case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
      Left err -> expectationFailure err
      Right env -> Map.lookup "date" env.fieldErrors `shouldBe` Just "from must be <= to"

it "returns 400 for an unknown status token" $ do
  token <- liftIO generateTestToken
  resp <- request "GET" "/api/transactions?status=bogus" [bearerHeader token] ""
  liftIO $ simpleStatus resp `shouldBe` status400

it "returns 400 for limit=0" $ do
  token <- liftIO generateTestToken
  resp <- request "GET" "/api/transactions?limit=0" [bearerHeader token] ""
  liftIO $ simpleStatus resp `shouldBe` status400
```

Add seeded-data cases (use the existing `seedTransfer`/fixtures already imported) verifying:
- omitting `status` returns Failed/Cancelled rows too (the behaviour flip);
- `status=completed` returns only completed rows;
- `label=<uuid>` returns only rows carrying that label;
- `limit`/`offset` slice results while `totalCount` reflects the full match count, and `limit`/`offset` are echoed.

- [ ] **Step 2: Run the full test suite**

Run: `just test`
Expected: PASS — entire suite green.

- [ ] **Step 3: Commit**

```bash
git add test/Web/API/TransactionAPISpec.hs
git commit -m "test(transaction): rewrite GET /api/transactions integration spec for query language + pagination"
```

---

### Task 7: Cleanup, straggler check, full verification

**Files:** (verification only; fixes as discovered)

- [ ] **Step 1: Hunt for stragglers referencing removed symbols**

Run:
```bash
rg -n "TransactionQuery|mkTransactionQuery|emptyTransactionQuery|includeFailed|includeCancelled|queryAccountId|queryFrom|queryTo" src test
```
Expected: no matches in `src`/`test` (the two in-process callers — `Telegram/Commands.hs` and `TransactionCancellationIntegrationSpec.hs` — were already migrated in Task 5). If any remain in docs or elsewhere, fix them. Separately, the Monobank resync verification script (if it calls the HTTP endpoint) must page via `totalCount` now that the default `limit` caps results at 50 — note in the PR description.

- [ ] **Step 2: Format + lint**

Run: `just format && just lint`
Expected: no changes needed / no hints. Fix any reported.

- [ ] **Step 3: Full clean build + test (CI parity)**

Run: `just build && just test`
Expected: build succeeds, full suite PASS.

- [ ] **Step 4: Verify `-Werror` (CI flag) build**

Run: `cabal build -fci`
Expected: succeeds with no warnings (catches unused imports left over from the migration).

- [ ] **Step 5: Final commit (if Steps 1–2 changed anything)**

```bash
git add -A
git commit -m "chore(transaction): clean up query-language migration stragglers"
```

---

## Done criteria

- `GET /api/transactions` accepts `accountId`, `dateFrom`, `dateTo`, `status` (CSV IN), `label` (CSV IN), `limit`, `offset`; rejects malformed/out-of-range input with 400.
- Omitting `status` returns all statuses; omitting `limit` returns the first 50.
- `TransactionListResponse` carries `transactions`, `totalCount` (all matches), `limit`, `offset`.
- `includeFailed`/`includeCancelled` and `TransactionQuery` are fully removed.
- `just build`, `just test`, `just lint`, and `cabal build -fci` all pass.
