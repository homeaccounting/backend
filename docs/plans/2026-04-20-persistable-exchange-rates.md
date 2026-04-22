---
status: completed
---

# Persistable Exchange Rate History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist `ExchangeRatesPublished` events on the existing Eventium global event stream so exchange-rate history survives restarts, and reshape the in-memory store into a proper read model with a dedicated publisher service.

**Architecture:** Move `ExchangeRateEvent` into the Domain layer, make it a variant of `AccountingEvent`, add `ExchangeRateReadModel` keyed by provider + day of `EventMetadata.occurredAt`, and split the current monolithic `Infrastructure.ExchangeRate.Store` into a read model (`Application.ReadModels.ExchangeRate`) and a publisher service (`Application.Services.ExchangeRatePublisher`) that writes events and runs a daily scheduler via `threadDelay`/`async`.

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Eventium event store, Hspec + QuickCheck, `Data.Time`, no new cabal dependencies.

**Spec:** `docs/specs/2026-04-20-persistable-exchange-rates-design.md`

---

## Prerequisites

- Run `nix develop` to enter the dev shell (GHC, cabal, hpack, ormolu, hlint, just).
- `just docker-up` for integration tests that touch PostgreSQL.
- Read the spec at `docs/specs/2026-04-20-persistable-exchange-rates-design.md`.
- Familiarity with how existing read models work: skim `src/Application/ReadModels/BankImportReadModel.hs` and `src/Application/ReadModels/Account.hs` to see the TVar + handler pattern.
- Familiarity with how `MetadataEnricher` is used: see `src/Application/ProcessManagers/TransferManager.hs:188-192` for `mkEnricher`.

Invariants held throughout:
- Each commit must build cleanly: `just build` (or `cabal build -fci`) passes.
- Domain code imports nothing from Infrastructure or Application.
- `just format` and `just lint` pass before committing.

---

## File Structure

### Created
- `src/Domain/ExchangeRate/Events.hs` — `ExchangeRateEvent`, `ExchangeRateMap`, `exchangeRateEvents :: [Name]`
- `src/Application/ReadModels/ExchangeRate.hs` — read-model TVar, handler, lookup queries
- `src/Application/Services/ExchangeRatePublisher.hs` — `publishRates`, `spawnRatePublisher`, `providerStreamId`
- `test/Application/ReadModels/ExchangeRateSpec.hs` — unit + property tests for the read model
- `test/Application/Services/ExchangeRatePublisherSpec.hs` — publisher tests
- `test/Integration/ExchangeRatePersistenceSpec.hs` — end-to-end publish → replay → lookup

### Modified
- `src/Domain/Models.hs` — append `exchangeRateEvents` to `constructSumType` inputs, add `exchangeRateEventEmbedding`
- `src/Infrastructure/ExchangeRate/Provider.hs` — re-export `ExchangeRateMap` from `Domain.ExchangeRate.Events`
- `src/Infrastructure/Eventium.hs` — add `exchangeRate` field to `ReadModels`, handler, replay call
- `src/Infrastructure/App.hs` — rename `HasExchangeRateStore` → `HasExchangeRateReadModel`, retype field
- `src/Application/Services/TransactionService.hs` — use read model + provider name from config
- `app/Main.hs` — replace one-shot `publishRates` with `spawnRatePublisher`
- `test/Testkit/InMemoryEventStore.hs` — construct read-model TVar instead of old store
- `test/Application/Services/TransactionServiceSpec.hs` — swap store mock for read-model TVar
- `backend.cabal` / `package.yaml` — add new modules to `exposed-modules` and test suites (via `hpack`)

### Deleted
- `src/Infrastructure/ExchangeRate/Store.hs`
- `test/Infrastructure/ExchangeRate/StoreSpec.hs`, `StorePropertySpec.hs`, `StoreIntegrationSpec.hs` (logic preserved, moved under `Application/ReadModels/ExchangeRate*` where applicable)

---

## Task 1: Move `ExchangeRateEvent` / `ExchangeRateMap` into Domain layer

Foundational move — unblocks adding the event to `AccountingEvent`. Keeps the old module compiling by having it import from the new location.

**Files:**
- Create: `src/Domain/ExchangeRate/Events.hs`
- Modify: `src/Infrastructure/ExchangeRate/Store.hs`
- Modify: `src/Infrastructure/ExchangeRate/Provider.hs`
- Modify: `package.yaml` (then `just build` which runs `hpack`)

- [ ] **Step 1: Read existing event type location**

Run: `rg "data ExchangeRateEvent" src/`
Expected: finds `src/Infrastructure/ExchangeRate/Store.hs`.

Read `src/Infrastructure/ExchangeRate/Store.hs` lines 35–55 (event type + `ExchangeRateMap` usage) and `src/Infrastructure/ExchangeRate/Provider.hs` lines 37–40 (`ExchangeRateMap` type alias). These will be the things you move.

- [ ] **Step 2: Create `Domain/ExchangeRate/Events.hs`**

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.ExchangeRate.Events
-- Description : Exchange-rate-publication domain events.
--
-- The event payload does not carry a date field — the business date
-- (the day the rates are for) is carried in EventMetadata.occurredAt,
-- matching the pattern used by TransferInitiated and other domain
-- events since the backdated-transactions work.
module Domain.ExchangeRate.Events
  ( ExchangeRateEvent (..),
    ExchangeRateMap,
    exchangeRateEvents,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Domain.Core.Types (Currency, ExchangeRate)
import GHC.Generics (Generic)
import Language.Haskell.TH (Name)
import RIO

-- | Map of (source, target) -> ExchangeRate.
type ExchangeRateMap = Map (Currency, Currency) ExchangeRate

-- | Exchange rate events for event sourcing.
--
-- 'ExchangeRatesPublished' records that a provider published a set of
-- rates for a particular day. The day is on EventMetadata.occurredAt,
-- not the payload, so historical backfill is a metadata-only change.
data ExchangeRateEvent
  = ExchangeRatesPublished
      { provider :: !Text,
        rates :: !ExchangeRateMap
      }
  deriving (Show, Eq, Generic)

instance ToJSON ExchangeRateEvent

instance FromJSON ExchangeRateEvent

-- | TH name list consumed by Domain.Models.constructSumType.
--
-- Mirrors the shape of accountEvents, transactionEvents, userEvents,
-- configurationEvents. Add new event types to this list when adding
-- variants.
exchangeRateEvents :: [Name]
exchangeRateEvents = [''ExchangeRateEvent]
```

- [ ] **Step 3: Update `package.yaml` to expose the new module**

Open `package.yaml`, locate the `library.exposed-modules` list (follow existing alphabetical order under `Domain.`). Add:

```yaml
      - Domain.ExchangeRate.Events
```

- [ ] **Step 4: Update old `Store.hs` and `Provider.hs` to import from Domain**

In `src/Infrastructure/ExchangeRate/Store.hs`:
- Remove the local `ExchangeRateEvent` data declaration and its JSON instances (lines 43–54 of the current file).
- Add import: `import Domain.ExchangeRate.Events (ExchangeRateEvent (..), ExchangeRateMap)`.
- Remove the existing `import Domain.Core.Types (Currency, ExchangeRate)` if it becomes unused after the move.
- In the module export list keep `ExchangeRateEvent (..)` (re-export from Domain).
- `ExchangeRateHistory` stays as `type ExchangeRateHistory = Map Day ExchangeRateMap`.

In `src/Infrastructure/ExchangeRate/Provider.hs`:
- Remove the local `type ExchangeRateMap = ...` definition (lines 39–40 of the current file).
- Add import: `import Domain.ExchangeRate.Events (ExchangeRateMap)`.
- Module export list: `ExchangeRateMap` stays (re-export).

- [ ] **Step 5: Build and format**

Run:
```
just build
```
Expected: builds cleanly, no module-boundary violations.

Run:
```
just format
```

- [ ] **Step 6: Commit**

```
git add src/Domain/ExchangeRate/Events.hs \
        src/Infrastructure/ExchangeRate/Store.hs \
        src/Infrastructure/ExchangeRate/Provider.hs \
        package.yaml backend.cabal
git commit -m "refactor(exchange-rate): move event type to Domain layer"
```

---

## Task 2: Register `ExchangeRateEvent` as a variant of `AccountingEvent`

Makes the event persist-able via the existing tagged writer and codec.

**Files:**
- Modify: `src/Domain/Models.hs`

- [ ] **Step 1: Add the event list to the unified sum type**

In `src/Domain/Models.hs`:
- Add import: `import Domain.ExchangeRate.Events as X (ExchangeRateEvent (..), ExchangeRateMap, exchangeRateEvents)`.
- Extend the `constructSumType "AccountingEvent"` call (around line 121):

  ```haskell
  constructSumType
    "AccountingEvent"
    (withTagOptions (ConstructTagName (++ "Event")) defaultSumTypeOptions)
    (accountEvents ++ transactionEvents ++ userEvents ++ configurationEvents ++ exchangeRateEvents)
  ```

- Add a TH embedding after the configuration one (near line 291):

  ```haskell
  mkSumTypeEmbedding "exchangeRateEventEmbedding" ''ExchangeRateEvent ''AccountingEvent
  ```

- Add `exchangeRateEventEmbedding` and the re-export `module Domain.ExchangeRate.Events` to the module export list (the `Re-exports` section at line 79 uses `module X` pattern — the `as X` alias on the import carries it through).

- [ ] **Step 2: Build**

```
just build
```
Expected: success. The TH sum constructor will now include a new `ExchangeRatesPublishedEvent` variant. If GHC complains about exhaustiveness in any pattern match over `AccountingEvent`, those are reportable bugs — most handlers use `_ -> ...` fallbacks because they filter by variant, but verify none is affected.

Run: `rg "case .*AccountingEvent" src/` — inspect any non-exhaustive pattern. Expected: none; all handlers use wildcard defaults.

- [ ] **Step 3: Verify with `just check`**

```
just check
```
Expected: ormolu + hlint clean.

- [ ] **Step 4: Commit**

```
git add src/Domain/Models.hs
git commit -m "feat(exchange-rate): add ExchangeRatesPublished to AccountingEvent"
```

---

## Task 3: Write failing tests for the new read model

TDD — red first.

**Files:**
- Create: `test/Application/ReadModels/ExchangeRateSpec.hs`
- Create: `test/Application/ReadModels/ExchangeRatePropertySpec.hs`

- [ ] **Step 1: Read an existing read-model spec for test style**

Run: `ls test/Application/ReadModels/`. Open one of the existing `*Spec.hs` files to see the Hspec + TVar style.

- [ ] **Step 2: Write `ExchangeRateSpec.hs`**

Minimum cases (exact expected file shape — fill in the helper imports using Testkit helpers available in the project):

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.ReadModels.ExchangeRateSpec (spec) where

import Application.ReadModels.ExchangeRate
  ( createExchangeRateReadModel,
    handleExchangeRateEvents,
    lookupHistoricalRate,
  )
import Data.Time (Day, UTCTime (..), fromGregorian, secondsToDiffTime)
import Domain.Core.Types (mkExchangeRateUnsafe, USD, UAH)  -- adjust to whatever testkit exposes
import Domain.ExchangeRate.Events (ExchangeRateEvent (..))
import Domain.Models (AccountingEvent (..))
import Eventium (EventMetadata (..), StreamEvent (..), emptyMetadata)
import RIO
import qualified RIO.Map as Map
import Test.Hspec

spec :: Spec
spec = describe "ExchangeRateReadModel" $ do
  it "returns Nothing when empty" $ do
    rm <- createExchangeRateReadModel
    result <- lookupHistoricalRate rm "ecb" (fromGregorian 2026 4 20) USD UAH
    result `shouldBe` Nothing

  it "returns exact-date rate after single event" $ do
    rm <- createExchangeRateReadModel
    let day = fromGregorian 2026 4 20
        rate = mkExchangeRateUnsafe USD UAH 41
        rates = Map.singleton (USD, UAH) rate
        ev = mkEvent day "ecb" rates
    handleExchangeRateEvents rm [ev]
    result <- lookupHistoricalRate rm "ecb" day USD UAH
    result `shouldBe` Just rate

  it "isolates providers" $ do
    rm <- createExchangeRateReadModel
    let day = fromGregorian 2026 4 20
        rate = mkExchangeRateUnsafe USD UAH 41
        rates = Map.singleton (USD, UAH) rate
    handleExchangeRateEvents rm [mkEvent day "ecb" rates]
    resultNbu <- lookupHistoricalRate rm "nbu" day USD UAH
    resultNbu `shouldBe` Nothing

  it "falls back to the nearest earlier date" $ do
    rm <- createExchangeRateReadModel
    let day1 = fromGregorian 2026 4 15
        day2 = fromGregorian 2026 4 18
        queryDay = fromGregorian 2026 4 20
        rate1 = mkExchangeRateUnsafe USD UAH 40
        rate2 = mkExchangeRateUnsafe USD UAH 41
    handleExchangeRateEvents rm
      [ mkEvent day1 "ecb" (Map.singleton (USD, UAH) rate1),
        mkEvent day2 "ecb" (Map.singleton (USD, UAH) rate2)
      ]
    result <- lookupHistoricalRate rm "ecb" queryDay USD UAH
    result `shouldBe` Just rate2

  it "skips events without occurredAt" $ do
    rm <- createExchangeRateReadModel
    let rates = Map.singleton (USD, UAH) (mkExchangeRateUnsafe USD UAH 41)
        bogus = StreamEvent undefined 0 (emptyMetadata mempty) (AccountingExchangeRatesPublishedEvent (ExchangeRatesPublished "ecb" rates))
    -- handler must not throw
    handleExchangeRateEvents rm [bogus]
    result <- lookupHistoricalRate rm "ecb" (fromGregorian 2026 4 20) USD UAH
    result `shouldBe` Nothing

mkEvent :: Day -> Text -> _ -> _  -- helper producing a GlobalStreamEvent AccountingEvent with occurredAt set
mkEvent day prov rates =
  let meta = (emptyMetadata mempty) { occurredAt = Just (UTCTime day (secondsToDiffTime 0)) }
      payload = AccountingExchangeRatesPublishedEvent (ExchangeRatesPublished prov rates)
   in StreamEvent undefined 0 meta payload
```

Adjust imports/types (`USD`, `UAH`, `mkExchangeRateUnsafe`, the `GlobalStreamEvent` vs `VersionedStreamEvent` wrapper) against what the existing read-model specs use. The `Testkit/Helpers.hs` and `Testkit/Generators.hs` modules contain the pre-built currency constructors; match what's already there.

- [ ] **Step 3: Write a small property test file `ExchangeRatePropertySpec.hs`**

One property: for any arbitrary list of `(Day, ExchangeRateMap)` events, looking up a date `d` returns `Just` the rate from the day in the set closest to `d` (by absolute `diffDays`), preferring earlier on tie. Reuses the pure `lookupNearestDate` helper exposed from `Application.ReadModels.ExchangeRate`.

- [ ] **Step 4: Add the new spec files to the test suite**

Hspec-discover auto-picks files named `*Spec.hs` under `test/`; no manual wiring required if the module lives under a path that's already `other-modules:` in the test-suite stanza of `package.yaml`. Verify by opening `package.yaml` — the test suite uses `main-is: Spec.hs` with hspec-discover; the new files should be picked up automatically once `just build` runs.

- [ ] **Step 5: Run and confirm failure**

```
cabal test all --test-option='--match' --test-option='/ExchangeRateReadModel/'
```
Expected: compile error — `Application.ReadModels.ExchangeRate` does not exist yet.

- [ ] **Step 6: Commit (red tests only)**

```
git add test/Application/ReadModels/ExchangeRateSpec.hs \
        test/Application/ReadModels/ExchangeRatePropertySpec.hs
git commit -m "test(exchange-rate): failing read model specs"
```

---

## Task 4: Implement the read model

**Files:**
- Create: `src/Application/ReadModels/ExchangeRate.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Implement the module**

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.ExchangeRate
-- Description : In-memory projection of persisted exchange rate events.
--
-- Consumes 'AccountingExchangeRatesPublishedEvent' events and builds a
-- per-provider, per-day history. Lookups fall back to the nearest
-- available date using the same semantics as the previous
-- Infrastructure.ExchangeRate.Store.
module Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel (..),
    createExchangeRateReadModel,
    handleExchangeRateEvents,
    lookupHistoricalRate,
    lookupNearestDate,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Data.Time (Day, diffDays, utctDay)
import Domain.Core.Types (Currency, ExchangeRate)
import Domain.ExchangeRate.Events (ExchangeRateEvent (..), ExchangeRateMap)
import Domain.Models (AccountingEvent (..))
import Eventium (EventMetadata (..), StreamEvent (..))
import Infrastructure.ExchangeRate.Provider (getRate)
import RIO
import qualified RIO.Map as Map

-- | Per-provider day-indexed history.
newtype ExchangeRateReadModel = ExchangeRateReadModel
  { historyByProvider :: Map Text (Map Day ExchangeRateMap)
  }
  deriving (Show, Eq)

createExchangeRateReadModel :: (MonadIO m) => m (TVar ExchangeRateReadModel)
createExchangeRateReadModel =
  liftIO . newTVarIO $ ExchangeRateReadModel Map.empty

-- | Fold ExchangeRatesPublished events into the TVar.
--
-- Non-matching AccountingEvent variants are silently skipped. Events
-- without occurredAt are skipped (defensive — writes always set it).
handleExchangeRateEvents ::
  forall m streamEvent.
  (MonadIO m, StreamEventLike streamEvent) =>
  TVar ExchangeRateReadModel ->
  [streamEvent] ->
  m ()
handleExchangeRateEvents rm events =
  liftIO . atomically $ do
    current <- readTVar rm
    writeTVar rm $ foldl' apply current events
  where
    apply model ev = case extractRateEvent ev of
      Nothing -> model
      Just (day, ExchangeRatesPublished {provider, rates}) ->
        let inner = fromMaybe Map.empty (Map.lookup provider model.historyByProvider)
            inner' = Map.insert day rates inner
         in ExchangeRateReadModel (Map.insert provider inner' model.historyByProvider)

-- (Internal helper. Accept any StreamEvent carrying AccountingEvent.)
extractRateEvent :: StreamEventLike e => e -> Maybe (Day, ExchangeRateEvent)
extractRateEvent e = case (payloadOf e, occurredAtOf e) of
  (AccountingExchangeRatesPublishedEvent ev, Just t) -> Just (utctDay t, ev)
  _ -> Nothing

-- Abstract over VersionedStreamEvent / GlobalStreamEvent — whichever
-- shape the read-model registration passes. Mirror what existing read
-- models do; if they already define such a helper, reuse it.
class StreamEventLike e where
  payloadOf :: e -> AccountingEvent
  occurredAtOf :: e -> Maybe UTCTime

-- (Provide instances for the same StreamEvent types used by handleAccountEvents et al.)

lookupHistoricalRate ::
  (MonadIO m) =>
  TVar ExchangeRateReadModel ->
  Text ->
  Day ->
  Currency ->
  Currency ->
  m (Maybe ExchangeRate)
lookupHistoricalRate rm providerName day src tgt = liftIO $ do
  model <- readTVarIO rm
  pure $ do
    providerHistory <- Map.lookup providerName model.historyByProvider
    (_, rateMap) <- lookupNearestDate providerHistory day
    getRate rateMap src tgt

-- Same semantics as the old Store.lookupNearestDate — preferring
-- earlier on tie.
lookupNearestDate :: Map Day v -> Day -> Maybe (Day, v)
lookupNearestDate m target
  | Map.null m = Nothing
  | otherwise =
      let before = Map.lookupLE target m
          after = Map.lookupGE target m
       in case (before, after) of
            (Just (bDay, bVal), Just (aDay, aVal))
              | diffDays target bDay <= diffDays aDay target -> Just (bDay, bVal)
              | otherwise -> Just (aDay, aVal)
            (Just bv, Nothing) -> Just bv
            (Nothing, Just av) -> Just av
            (Nothing, Nothing) -> Nothing
```

**Important:** the `StreamEventLike` abstraction above is a sketch. Look at how `handleAccountEvents` receives its list in `src/Application/ReadModels/Account.hs` (or the similar `handleBankImportEvents`) and reuse the exact same input type. If existing read models take `[GlobalStreamEvent AccountingEvent]`, this handler should too — drop the class and inline the `case` on `StreamEvent _ _ metadata payload`.

- [ ] **Step 2: Add to `package.yaml`** under `library.exposed-modules` (alphabetical order):
```yaml
      - Application.ReadModels.ExchangeRate
```

- [ ] **Step 3: Build**

```
just build
```
Expected: clean compile.

- [ ] **Step 4: Run the failing tests**

```
cabal test all --test-option='--match' --test-option='/ExchangeRateReadModel/'
```
Expected: all green.

- [ ] **Step 5: Format + lint**

```
just check
```

- [ ] **Step 6: Commit**

```
git add src/Application/ReadModels/ExchangeRate.hs package.yaml backend.cabal
git commit -m "feat(exchange-rate): in-memory read model for published rates"
```

---

## Task 5: Register the read model on the event bus

Give the new read model startup-replay and live-update for free.

**Files:**
- Modify: `src/Infrastructure/Eventium.hs`

- [ ] **Step 1: Extend the `ReadModels` record**

At the `data ReadModels = ReadModels {…}` declaration around line 328, add a field:
```haskell
    exchangeRate :: TVar ExchangeRateReadModel
```

- [ ] **Step 2: Update `createReadModelHandlers`**

Around line 337, add creation and handler:
```haskell
exchangeRateRM <- createExchangeRateReadModel
...
let handlers =
      [ ...,
        mkHandler handleExchangeRateEvents exchangeRateRM
      ]
    readModels = ReadModels accountRM transactionRM userRM configRM bankImportRM exchangeRateRM
```

- [ ] **Step 3: Update `replayReadModels`**

Around line 492, add:
```haskell
handleExchangeRateEvents readModels.exchangeRate events
```

- [ ] **Step 4: Add the imports**

```haskell
import Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel,
    createExchangeRateReadModel,
    handleExchangeRateEvents,
  )
```

- [ ] **Step 5: Build**

```
just build
```
Expected: builds; no other sites of `ReadModels {}` construction fail (if they do — in tests — that's addressed in later tasks).

- [ ] **Step 6: Commit**

```
git add src/Infrastructure/Eventium.hs
git commit -m "feat(exchange-rate): register read model with event bus + replay"
```

---

## Task 6: Write failing tests for the publisher

**Files:**
- Create: `test/Application/Services/ExchangeRatePublisherSpec.hs`

- [ ] **Step 1: Write the spec**

```haskell
spec :: Spec
spec = describe "ExchangeRatePublisher" $ do
  it "writes one event to the provider's stream at version 0 when empty" $ do
    (writer, reader, readEvents) <- inMemoryTaggedStore
    rm <- createExchangeRateReadModel
    let prov = fixedRateProvider "ecb" sampleRates  -- test helper below
    result <- publishRates prov writer reader rm
    events <- readEvents
    length events `shouldBe` 1
    -- verify stream key == providerStreamId "ecb", version == 0

  it "sets occurredAt to today on the persisted event" $ do
    (writer, reader, readEvents) <- inMemoryTaggedStore
    rm <- createExchangeRateReadModel
    today <- utctDay <$> getCurrentTime
    let prov = fixedRateProvider "ecb" sampleRates
    _ <- publishRates prov writer reader rm
    [StreamEvent _ _ meta _] <- readEvents
    (utctDay <$> meta.occurredAt) `shouldBe` Just today

  it "is idempotent for the same day" $ do
    (writer, reader, readEvents) <- inMemoryTaggedStore
    rm <- createExchangeRateReadModel
    let prov = fixedRateProvider "ecb" sampleRates
    _ <- publishRates prov writer reader rm
    -- simulate read-model update (the real event bus would fire this)
    today <- utctDay <$> getCurrentTime
    primeReadModel rm "ecb" today sampleRates
    result <- publishRates prov writer reader rm
    isLeft result `shouldBe` True
    events <- readEvents
    length events `shouldBe` 1

  it "does not write when the provider errors" $ do
    (writer, reader, readEvents) <- inMemoryTaggedStore
    rm <- createExchangeRateReadModel
    let prov = failingRateProvider "ecb" "boom"
    _ <- publishRates prov writer reader rm
    events <- readEvents
    events `shouldBe` []
```

Helpers:
- `inMemoryTaggedStore` — construct a pair of writer/reader around the existing in-memory event store from `test/Testkit/InMemoryEventStore.hs`. If the in-memory store exposes only a full app env, extract just its tagged writer and versioned reader.
- `fixedRateProvider :: Text -> ExchangeRateMap -> RateProvider` — stub provider. Reuse whatever pattern `test/Infrastructure/ExchangeRate/ProviderPropertySpec.hs` already uses.
- `failingRateProvider :: Text -> Text -> RateProvider`.
- `primeReadModel` — writes straight into the TVar, simulating the event bus delivery.

- [ ] **Step 2: Run and confirm failure**

```
cabal test all --test-option='--match' --test-option='/ExchangeRatePublisher/'
```
Expected: compile error — `Application.Services.ExchangeRatePublisher` does not exist.

- [ ] **Step 3: Commit (red)**

```
git add test/Application/Services/ExchangeRatePublisherSpec.hs
git commit -m "test(exchange-rate): failing publisher specs"
```

---

## Task 7: Implement the publisher service

**Files:**
- Create: `src/Application/Services/ExchangeRatePublisher.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Implement `publishRates` and `providerStreamId`**

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.ExchangeRatePublisher
  ( publishRates,
    spawnRatePublisher,
    providerStreamId,
  )
where

import Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel (..),
    lookupHistoricalRate,
  )
import Data.Aeson (toJSON)
import Data.ByteString.Char8 (pack)
import Data.Time
  ( Day,
    UTCTime (..),
    addDays,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
    secondsToDiffTime,
    utctDay,
  )
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V5 as UUIDv5
import Domain.ExchangeRate.Events (ExchangeRateEvent (..), ExchangeRateMap)
import Domain.Models (AccountingEvent (..))
import Eventium
  ( EventMetadata (..),
    MetadataEnricher,
    QueryRange,
    TaggedEvent,
    allEvents,
    emptyMetadata,
    metadataEnrichingEventStoreWriterWithEnricher,
    readEvents, -- or whatever the project's helper is
    runEventStoreWriterUsing,
    storeEvents, -- ditto
  )
import Eventium.Store.Postgresql (JSONString, jsonStringCodec)
import Infrastructure.Eventium
  ( AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
  )
import Infrastructure.ExchangeRate.Provider (RateProvider (..))
import RIO

-- Deterministic UUID namespace for exchange-rate streams.
-- Generate once and freeze.
exchangeRateNamespace :: UUID
exchangeRateNamespace =
  fromJust $ UUID.fromString "0a1b2c3d-0000-0000-0000-000000000000"
  where
    fromJust = maybe (error "invalid namespace UUID") id

providerStreamId :: Text -> UUID
providerStreamId name = UUIDv5.generateNamed exchangeRateNamespace (unpack name)
  where
    unpack = pack . unpackText  -- use encodeUtf8 from RIO

publishRates ::
  (MonadIO m) =>
  RateProvider ->
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  TVar ExchangeRateReadModel ->
  m (Either Text ())
publishRates prov writer reader rm = liftIO $ do
  nowUtc <- getCurrentTime
  let today = utctDay nowUtc
  -- Idempotence: read model already has today?
  alreadyPresent <- isPublished rm prov.providerName today
  if alreadyPresent
    then pure (Left "Rates already published for today")
    else do
      result <- prov.fetchRates
      case result of
        Left err -> pure (Left err)
        Right rates -> writeEvent writer reader prov.providerName today nowUtc rates

isPublished :: TVar ExchangeRateReadModel -> Text -> Day -> IO Bool
isPublished rm providerName day = do
  model <- readTVarIO rm
  case Map.lookup providerName model.historyByProvider of
    Nothing -> pure False
    Just m -> pure (Map.member day m)

writeEvent ::
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  Text ->
  Day ->
  UTCTime ->
  ExchangeRateMap ->
  IO (Either Text ())
writeEvent writer reader providerName _today nowUtc rates = do
  let streamId = providerStreamId providerName
      payload = AccountingExchangeRatesPublishedEvent (ExchangeRatesPublished providerName rates)
      enricher = \m -> m {occurredAt = Just nowUtc}
  -- Determine next version by reading the stream
  existing <- runReader reader (allEvents streamId)
  let nextVersion = length existing
  -- Write through an enriched writer that sets occurredAt
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher jsonStringCodec writer
  -- Call the project's store helper. Look at Infrastructure.Eventium.applyAccountCommand
  -- for the exact signature — this is the same write path, just without going through
  -- a CommandHandler.
  storeOne enrichedWriter streamId nextVersion payload
  pure (Right ())

-- Implement storeOne by calling the tagged-writer store action directly.
-- See `EventStoreWriter` in Eventium: the writer takes (key, expectedVersion, [TaggedEvent]).
```

The exact API for writing a single event through the tagged writer without going through a `CommandHandler` may need a small helper. Verify against the `Eventium` API: the `applyAccountCommand`-style path in `Infrastructure.Eventium.hs` is the pattern to mimic — it builds an enriched writer and calls `applyCommandHandler`. For a direct append, use whatever primitive `postgresqlTaggedEventStoreWriter` exposes (a `storeEvents` or similar function on the `EventStoreWriter` record). If no direct primitive is available, introduce a tiny helper in this module.

- [ ] **Step 2: Implement `spawnRatePublisher`**

```haskell
spawnRatePublisher ::
  RateProvider ->
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  TVar ExchangeRateReadModel ->
  LogFunc ->
  IO (Async ())
spawnRatePublisher prov writer reader rm logFunc = async . runRIO logFunc . forever $ do
  result <- liftIO $ tryAny (publishRates prov writer reader rm)
  case result of
    Left e -> logError $ "rate publish failed: " <> displayShow e
    Right (Left msg) -> logWarn $ "rate publish skipped: " <> display msg
    Right (Right ()) -> logInfo $ "rates published from " <> display prov.providerName
  delayMicros <- liftIO microsUntilNextTick
  liftIO $ threadDelay delayMicros
  where
    microsUntilNextTick = do
      now <- getCurrentTime
      let tomorrow = addDays 1 (utctDay now)
          targetTime = UTCTime tomorrow (secondsToDiffTime (5 * 60))
          diffSec = realToFrac (diffUTCTime targetTime now) :: Double
      pure $ max 1 (ceiling (diffSec * 1_000_000))
```

- [ ] **Step 3: Expose and build**

Add to `package.yaml` under `library.exposed-modules`:
```yaml
      - Application.Services.ExchangeRatePublisher
```
Run:
```
just build
```

- [ ] **Step 4: Run failing tests and make them pass**

```
cabal test all --test-option='--match' --test-option='/ExchangeRatePublisher/'
```
Expected: all green.

- [ ] **Step 5: Format + lint**

```
just check
```

- [ ] **Step 6: Commit**

```
git add src/Application/Services/ExchangeRatePublisher.hs package.yaml backend.cabal
git commit -m "feat(exchange-rate): publisher service with daily scheduler"
```

---

## Task 8: Migrate `HasExchangeRateStore` → `HasExchangeRateReadModel`

Single structural refactor. Do it atomically so the build never breaks mid-rename.

**Files:**
- Modify: `src/Infrastructure/App.hs`
- Modify: `src/Application/Services/TransactionService.hs`
- Modify: `test/Testkit/InMemoryEventStore.hs`
- Modify: `test/Application/Services/TransactionServiceSpec.hs`

- [ ] **Step 1: Rewrite the typeclass and `AppEnv` field in `Infrastructure/App.hs`**

- Rename export `HasExchangeRateStore (..)` → `HasExchangeRateReadModel (..)`.
- Change field in `AppEnv` from `exchangeRateStore :: !ExchangeRateStore` to `exchangeRateReadModel :: !(TVar ExchangeRateReadModel)`.
- Rewrite class and instance at lines ~407–411:
  ```haskell
  class HasExchangeRateReadModel env where
    exchangeRateReadModelL :: Lens' env (TVar ExchangeRateReadModel)

  instance HasExchangeRateReadModel AppEnv where
    exchangeRateReadModelL = lens (.exchangeRateReadModel) (\x y -> x {exchangeRateReadModel = y})
  ```
- Update `initializeAppEnv` signature to take `TVar ExchangeRateReadModel` instead of `ExchangeRateStore`.

- [ ] **Step 2: Update `TransactionService.resolveAmounts`**

At `src/Application/Services/TransactionService.hs:411`:
- Change the constraint: `HasExchangeRateStore env` → `HasExchangeRateReadModel env, HasAppConfig env`.
- At the lookup site (line 428), replace:
  ```haskell
  store <- view exchangeRateStoreL
  maybeRate <- liftIO $ lookupHistoricalRate store rateDate srcCurrency tgtCurrency
  ```
  with:
  ```haskell
  rm <- view exchangeRateReadModelL
  cfg <- view appConfigL
  maybeRate <- lookupHistoricalRate rm cfg.exchangeRate.provider rateDate srcCurrency tgtCurrency
  ```
- Update imports: drop `Infrastructure.ExchangeRate.Store`, add `Application.ReadModels.ExchangeRate`.

- [ ] **Step 3: Update `test/Testkit/InMemoryEventStore.hs`**

At lines 296, 318, 436, 458:
- Replace `newExchangeRateStore ecbProvider` with `createExchangeRateReadModel`.
- Replace `exchangeRateStore = exchangeRateStore'` record-field with `exchangeRateReadModel = exchangeRateRM` (renaming the local binding).
- Update imports.

- [ ] **Step 4: Update `test/Application/Services/TransactionServiceSpec.hs`**

At line 87 (`return env {exchangeRateStore = store}`): replace with a construction of the read-model TVar primed with the test's rates (via `handleExchangeRateEvents` on a synthesized event), then `return env {exchangeRateReadModel = rm}`.

- [ ] **Step 5: Build**

```
just build
```
Expected: builds (there may still be a stale reference somewhere — grep for it):

```
rg 'exchangeRateStore|HasExchangeRateStore|ExchangeRateStore' src/ test/ app/
```
Expected: **only** matches in `src/Infrastructure/ExchangeRate/Store.hs` itself (to be deleted in a later task) and possibly `app/Main.hs` (addressed in the next task).

- [ ] **Step 6: Run the full test suite**

```
just test
```
Expected: all green except possibly still-to-migrate integration spec for the old `Store` (addressed in the test-migration task).

- [ ] **Step 7: Commit**

```
git add src/Infrastructure/App.hs \
        src/Application/Services/TransactionService.hs \
        test/Testkit/InMemoryEventStore.hs \
        test/Application/Services/TransactionServiceSpec.hs
git commit -m "refactor(exchange-rate): switch consumers to read-model interface"
```

---

## Task 9: Rewire `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Replace the one-shot publisher block**

At `app/Main.hs:320–332`, replace:

```haskell
rateProvider <- case config.exchangeRate.provider of
  "nbu" -> pure nbuProvider
  "ecb" -> pure ecbProvider
  unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
exchangeRateStore <- liftIO $ newExchangeRateStore rateProvider
-- TODO: persist ExchangeRatesPublished events and replay them here on startup
-- (similar to replayReadModels) so historical rates survive restarts
publishResult <- liftIO $ publishRates exchangeRateStore
case publishResult of
  Right _ -> logInfo $ "Today's rates published from " <> display (config.exchangeRate.provider)
  Left msg -> logWarn $ "Rate publish skipped: " <> display msg
```

with:

```haskell
rateProvider <- case config.exchangeRate.provider of
  "nbu" -> pure nbuProvider
  "ecb" -> pure ecbProvider
  unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
_publisherAsync <-
  liftIO $ spawnRatePublisher rateProvider writer reader readModels.exchangeRate logFunc
```

- [ ] **Step 2: Update imports**

- Remove: `Infrastructure.ExchangeRate.Store (newExchangeRateStore, publishRates)`.
- Add: `Application.Services.ExchangeRatePublisher (spawnRatePublisher)`.

- [ ] **Step 3: Pass the read model into `initializeAppEnv`**

Around line 368, replace `exchangeRateStore` with `readModels.exchangeRate`.

- [ ] **Step 4: Build + run**

```
just build
CONFIG_PATH=config/test.yaml cabal run backend
```
Expected: application starts, logs `"rates published from ecb"` (or similar). Ctrl-C to stop.

- [ ] **Step 5: Commit**

```
git add app/Main.hs
git commit -m "feat(exchange-rate): wire background publisher into Main"
```

---

## Task 10: Delete `Infrastructure.ExchangeRate.Store`

With all consumers migrated, the old module has no callers.

**Files:**
- Delete: `src/Infrastructure/ExchangeRate/Store.hs`
- Delete: `test/Infrastructure/ExchangeRate/StoreSpec.hs`
- Delete: `test/Infrastructure/ExchangeRate/StorePropertySpec.hs`
- Delete: `test/Infrastructure/ExchangeRate/StoreIntegrationSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Confirm no remaining references**

```
rg 'Infrastructure.ExchangeRate.Store|newExchangeRateStore|ExchangeRateStore' src/ test/ app/
```
Expected: no matches.

- [ ] **Step 2: Delete files**

```
git rm src/Infrastructure/ExchangeRate/Store.hs \
       test/Infrastructure/ExchangeRate/StoreSpec.hs \
       test/Infrastructure/ExchangeRate/StorePropertySpec.hs \
       test/Infrastructure/ExchangeRate/StoreIntegrationSpec.hs
```

- [ ] **Step 3: Remove from `package.yaml` `exposed-modules`**

Drop `Infrastructure.ExchangeRate.Store`.

- [ ] **Step 4: Build + test**

```
just check
just test
```
Expected: green.

- [ ] **Step 5: Commit**

```
git add package.yaml backend.cabal
git commit -m "refactor(exchange-rate): drop obsolete in-memory Store module"
```

---

## Task 11: End-to-end persistence integration test

**Files:**
- Create: `test/Integration/ExchangeRatePersistenceSpec.hs`

- [ ] **Step 1: Write the test**

Test scenario:
1. Use the in-memory event store from `Testkit/InMemoryEventStore.hs`.
2. Construct read-model A, construct publisher, call `publishRates` once with a stub provider that returns known rates.
3. Persisted events: ≥ 1.
4. Construct a fresh read-model B from the same store + writer + reader, run `replayReadModels` (or just `handleExchangeRateEvents` over `readEvents globalReader (allEvents ())`).
5. `lookupHistoricalRate rmB "ecb" today USD UAH` returns the rate originally fetched.

This closes the loop: "published in an old process, available in a new one."

- [ ] **Step 2: Run**

```
cabal test all --test-option='--match' --test-option='/ExchangeRatePersistence/'
```
Expected: green.

- [ ] **Step 3: Commit**

```
git add test/Integration/ExchangeRatePersistenceSpec.hs
git commit -m "test(exchange-rate): end-to-end persistence round-trip"
```

---

## Task 12: Documentation + architecture note

**Files:**
- Modify: `docs/architecture.md`
- Modify: `docs/specs/2026-04-20-persistable-exchange-rates-design.md` (flip `status: draft` → `status: completed`)

- [ ] **Step 1: Add a short section to `docs/architecture.md`** under the read-models list noting that exchange-rate history is a read model projected from `AccountingExchangeRatesPublishedEvent`, with the business date on `EventMetadata.occurredAt`.

- [ ] **Step 2: Update the spec status header**

- [ ] **Step 3: Commit**

```
git add docs/architecture.md docs/specs/2026-04-20-persistable-exchange-rates-design.md
git commit -m "docs(exchange-rate): mark design completed + architecture note"
```

---

## Task 13: Final verification

- [ ] **Step 1: Full check**

```
just check
just test
```
Expected: ormolu clean, hlint clean, all tests green.

- [ ] **Step 2: Smoke run**

```
just docker-up
CONFIG_PATH=config/test.yaml cabal run backend
```
Confirm logs show:
- Read models replayed (including exchange rate, event count 1 for the event just written in a previous run, or 0 on a clean DB).
- "rates published from ecb" from the publisher thread.

Stop the server with Ctrl-C. Restart; confirm the read model now loads the previously persisted event (event count ≥ 1).

- [ ] **Step 3: Verify cabal build with `-fci`** (project's CI flag for `-Werror`)

```
cabal build -fci
```
Expected: zero warnings, success.

- [ ] **Step 4: Push branch**

```
git push -u origin feat/persistable-exchange-rates
```

- [ ] **Step 5: Open a PR**

Title: `feat(exchange-rate): persist rate history on the global event stream (#43)`

Body points:
- Resolves homeaccounting/backend#43.
- Rate-publication events now persisted via Eventium; history survives restarts.
- Old `ExchangeRateStore` split into `ReadModels.ExchangeRate` + `Services.ExchangeRatePublisher`.
- Daily scheduler via `threadDelay`/`async`, no new libs.
- Rate date carried on `EventMetadata.occurredAt` (consistent with `TransferInitiated`), so future historical-backfill is metadata-only.
- Out of scope (future issues): historical backfill, provider fallback/merge, multi-node leader election.

---

## Out of Scope (future issues)

- **Historical backfill**: `fetchRatesForDate :: Day -> IO (Either Text ExchangeRateMap)` on `RateProvider`, plus a service that fills gaps on demand.
- **Provider composition** (fallback / merge), already described in `docs/specs/2026-03-18-pluggable-exchange-rate-providers-design.md`.
- **Multi-node leader election** for the publisher — optimistic concurrency currently handles accidental double-publishes, which is fine for home-scale deployments.

## Notes for the implementer

- When in doubt about the exact Eventium API for direct appends (Task 7 Step 1), open `src/Infrastructure/Eventium.hs:372-380` (`applyAccountCommand`) to see how the project builds `metadataEnrichingEventStoreWriterWithEnricher` and routes through the tagged writer. The publisher uses the same pieces, minus the command handler.
- Per CLAUDE.md project policy: push after each task. Don't batch commits until the end of the PR.
- If LiquidHaskell refinements apply to any new types you add (e.g. if you add a smart constructor around `providerName`), follow the pattern in `Domain.Core.Types` — smart constructor + `measure` + reflection.
