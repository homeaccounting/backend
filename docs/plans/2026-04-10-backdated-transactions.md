# Backdated Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to create transfers with past dates, propagate `occurredAt` through the event pipeline, and maintain historical exchange rates via an event-sourced store.

**Architecture:** Two repos are modified. In eventium: add `occurredAt` field to `EventMetadata`, introduce `MetadataEnricher` type, and thread it through `applyCommandHandler` → `CommandDispatcher` → `ProcessManagerEffect` → `runProcessManagerEffects`. In the backend: replace the `IORef`-based exchange rate cache with an event-sourced rate store, add optional `date` field to transfer DTOs, and wire `occurredAt` propagation through the saga.

**Tech Stack:** Haskell (GHC 9.10.3), Cabal, eventium (event sourcing library), Servant, PostgreSQL, Hspec, QuickCheck

**Spec:** `docs/specs/2026-04-10-backdated-transactions-design.md`

**Cross-repo:** Tasks 1–3 are in `/Users/oleksandrsy/Projects/Self/eventium`. Tasks 4–8 are in `/Users/oleksandrsy/Projects/Self/HomeAccounting/backend`.

---

## Part A: Eventium Library Changes

### Task 1: Add `occurredAt` to `EventMetadata` and introduce `MetadataEnricher`

**Files:**
- Modify: `eventium-core/src/Eventium/Store/Types.hs:9-56`
- Modify: `eventium-core/src/Eventium.hs` (re-exports)

- [ ] **Step 1: Write failing test for `occurredAt` field**

In `eventium-memory/tests/Eventium/MetadataEnrichmentSpec.hs`, add a test after the existing `createdAt` test:

```haskell
    it "preserves occurredAt when set via enricher" $ do
      tvar <- eventMapTVar
      let taggedWriter = tvarEventStoreWriterTagged tvar
          enrichedWriter = metadataEnrichingEventStoreWriter testCodec (runEventStoreWriterUsing atomically taggedWriter)
          reader = runEventStoreReaderUsing atomically (tvarEventStoreReader tvar)
          uuid = uuidFromInteger 1
      _ <- enrichedWriter.storeEvents uuid NoStream [42 :: Int]
      events <- reader.getEvents (allEvents uuid)
      -- occurredAt should be Nothing by default (auto-enrichment doesn't set it)
      all (\e -> isNothing e.metadata.occurredAt) events `shouldBe` True
```

Add `isNothing` to imports from `Data.Maybe`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test eventium-memory --test-option='--match' --test-option='/Metadata enrichment/'`
Expected: Compilation error — `occurredAt` field does not exist on `EventMetadata`.

- [ ] **Step 3: Add `occurredAt` field and `MetadataEnricher` type**

In `eventium-core/src/Eventium/Store/Types.hs`:

Add `occurredAt` to `EventMetadata` (line 39-44):

```haskell
data EventMetadata = EventMetadata
  { eventType :: !Text,
    correlationId :: !(Maybe UUID),
    causationId :: !(Maybe UUID),
    createdAt :: !(Maybe UTCTime),
    occurredAt :: !(Maybe UTCTime)
  }
  deriving (Show, Eq, Generic)
```

Add `MetadataEnricher` type alias after `emptyMetadata`:

```haskell
-- | Builder function for customizing event metadata.
--
-- Used to inject application-level metadata (e.g. 'occurredAt') into events
-- at write time. The enricher is applied after the base metadata is generated.
-- Use 'id' when no enrichment is needed.
type MetadataEnricher = EventMetadata -> EventMetadata
```

Update `emptyMetadata` (line 55-56):

```haskell
emptyMetadata :: Text -> EventMetadata
emptyMetadata et = EventMetadata et Nothing Nothing Nothing Nothing
```

Add `MetadataEnricher` to the module export list.

- [ ] **Step 4: Fix compilation — update all sites constructing `EventMetadata`**

In `eventium-core/src/Eventium/Store/Class.hs`, `metadataEnrichingEventStoreWriter` (line 196):

```haskell
(EventMetadata (T.pack . show $ typeOf e) Nothing Nothing (Just now) Nothing)
```

In `eventium-core/src/Eventium/Store/Class.hs`, `tagEvents` (line 213):

```haskell
(EventMetadata (T.pack . show $ typeOf e) Nothing Nothing (Just now) Nothing)
```

In `eventium-core/src/Eventium/EventPublisher.hs`, any `emptyMetadata` usage should work as-is (it's a function call, not a constructor).

- [ ] **Step 5: Add re-export of `MetadataEnricher` from `Eventium` module**

The `Eventium` module already re-exports `Eventium.Store.Types` via `Eventium.Store.Class as X`. Verify `MetadataEnricher` is in the export list of `Eventium.Store.Types`.

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test eventium-memory --test-option='--match' --test-option='/Metadata enrichment/'`
Expected: All tests pass including the new `occurredAt` test.

- [ ] **Step 7: Run full test suite**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test all --test-show-details=direct`
Expected: All tests pass. Some may need `EventMetadata` constructor patterns updated to include the 5th field.

- [ ] **Step 8: Commit**

```bash
cd /Users/oleksandrsy/Projects/Self/eventium
git add -A
git commit -m "feat(eventium-core): add occurredAt to EventMetadata and MetadataEnricher type"
```

---

### Task 2: Thread `MetadataEnricher` through the command pipeline

**Files:**
- Modify: `eventium-core/src/Eventium/Store/Class.hs:185-215` — `metadataEnrichingEventStoreWriter`
- Modify: `eventium-core/src/Eventium/CommandHandler.hs:55-97` — `applyCommandHandler`, `applyCommandHandlerWithCache`
- Modify: `eventium-core/src/Eventium/ProcessManager.hs:58-145` — `ProcessManagerEffect`, `CommandDispatcher`, `runProcessManagerEffects`, `processManagerEventHandler`
- Modify: `eventium-core/src/Eventium/CommandDispatcher.hs:56-72` — `commandHandlerDispatcher`

- [ ] **Step 1: Write failing tests for `MetadataEnricher` threading**

In `eventium-memory/tests/Eventium/MetadataEnrichmentSpec.hs`, add:

```haskell
    it "applies MetadataEnricher to set occurredAt" $ do
      tvar <- eventMapTVar
      let pastTime = UTCTime (fromGregorian 2025 3 15) 0
          enricher = \m -> m { occurredAt = Just pastTime }
          taggedWriter = tvarEventStoreWriterTagged tvar
          enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher testCodec (runEventStoreWriterUsing atomically taggedWriter)
          reader = runEventStoreReaderUsing atomically (tvarEventStoreReader tvar)
          uuid = uuidFromInteger 1
      _ <- enrichedWriter.storeEvents uuid NoStream [42 :: Int]
      events <- reader.getEvents (allEvents uuid)
      map (\e -> e.metadata.occurredAt) events `shouldBe` [Just pastTime]

    it "id enricher leaves occurredAt as Nothing" $ do
      tvar <- eventMapTVar
      let taggedWriter = tvarEventStoreWriterTagged tvar
          enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher id testCodec (runEventStoreWriterUsing atomically taggedWriter)
          reader = runEventStoreReaderUsing atomically (tvarEventStoreReader tvar)
          uuid = uuidFromInteger 1
      _ <- enrichedWriter.storeEvents uuid NoStream [42 :: Int]
      events <- reader.getEvents (allEvents uuid)
      map (\e -> e.metadata.occurredAt) events `shouldBe` [Nothing]
```

Add `Data.Time` imports (`UTCTime`, `fromGregorian`).

In `eventium-memory/tests/Eventium/ProcessManagerSpec.hs`, add test for enricher threading:

```haskell
    it "should thread MetadataEnricher from IssueCommand to dispatch" $ do
      dispatchedRef <- newIORef ([] :: [(UUID, TestCommand, MetadataEnricher)])
      let dispatcher = CommandDispatcher $ \uuid cmd enricher -> do
            modifyIORef dispatchedRef (++ [(uuid, cmd, enricher)])
            pure CommandSucceeded

      let target = uuidFromInteger 2
          enricher = \m -> m { occurredAt = Just (UTCTime (fromGregorian 2025 3 15) 0) }
          effects = [IssueCommand target (AcceptCredit 50) enricher]

      runProcessManagerEffects dispatcher effects

      dispatched <- readIORef dispatchedRef
      length dispatched `shouldBe` 1
      let (_, cmd, enr) = head dispatched
      cmd `shouldBe` AcceptCredit 50
      -- Verify enricher actually sets occurredAt
      let enriched = enr (emptyMetadata "test")
      enriched.occurredAt `shouldBe` Just (UTCTime (fromGregorian 2025 3 15) 0)
```

In `eventium-core/tests/Eventium/CommandDispatcherSpec.hs`, update existing tests to pass `id` as enricher:

```haskell
      result <- dispatcher.dispatchCommand (uuidFromInteger 1) Increment id
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test all 2>&1 | head -40`
Expected: Compilation errors — new functions/signatures don't exist yet.

- [ ] **Step 3: Add `metadataEnrichingEventStoreWriterWithEnricher`**

In `eventium-core/src/Eventium/Store/Class.hs`, add alongside existing `metadataEnrichingEventStoreWriter`:

```haskell
-- | Like 'metadataEnrichingEventStoreWriter' but applies a 'MetadataEnricher'
-- after generating base metadata. Use this to inject application-level metadata
-- (e.g. 'occurredAt') at write time.
metadataEnrichingEventStoreWriterWithEnricher ::
  (MonadIO m, Typeable event) =>
  MetadataEnricher ->
  Codec event encoded ->
  EventStoreWriter key position m (TaggedEvent encoded) ->
  EventStoreWriter key position m event
metadataEnrichingEventStoreWriterWithEnricher enricher codec (EventStoreWriter write) =
  EventStoreWriter $ \key pos events -> do
    now <- liftIO getCurrentTime
    let tagged =
          map
            ( \e ->
                TaggedEvent
                  (enricher (EventMetadata (T.pack . show $ typeOf e) Nothing Nothing (Just now) Nothing))
                  (codec.encode e)
            )
            events
    write key pos tagged
```

Redefine `metadataEnrichingEventStoreWriter` in terms of the new function:

```haskell
metadataEnrichingEventStoreWriter ::
  (MonadIO m, Typeable event) =>
  Codec event encoded ->
  EventStoreWriter key position m (TaggedEvent encoded) ->
  EventStoreWriter key position m event
metadataEnrichingEventStoreWriter = metadataEnrichingEventStoreWriterWithEnricher id
```

Export `metadataEnrichingEventStoreWriterWithEnricher` from the module.

- [ ] **Step 4: Modify `CommandDispatcher` to accept `MetadataEnricher`**

**Design note:** `applyCommandHandler` signature stays unchanged — it takes a `VersionedEventStoreWriter m event` (already enriched). The enricher is applied at the *writer creation boundary*: `commandHandlerDispatcher` creates a per-dispatch enriched writer from a tagged writer + codec, and backend `apply*Command` functions do the same. `CommandDispatcher.dispatchCommand` and `ProcessManagerEffect` carry the enricher so it flows through the saga.

In `eventium-core/src/Eventium/ProcessManager.hs`:

```haskell
newtype CommandDispatcher m command = CommandDispatcher
  { dispatchCommand :: UUID -> command -> MetadataEnricher -> m CommandDispatchResult
  }
```

Update `mkCommandDispatcher`:

```haskell
mkCommandDispatcher ::
  (UUID -> command -> MetadataEnricher -> m CommandDispatchResult) ->
  CommandDispatcher m command
mkCommandDispatcher = CommandDispatcher
```

Update `fireAndForgetDispatcher`:

```haskell
fireAndForgetDispatcher ::
  (Monad m) =>
  (UUID -> command -> m ()) ->
  CommandDispatcher m command
fireAndForgetDispatcher f = CommandDispatcher $ \uuid cmd _enricher ->
  f uuid cmd >> pure CommandSucceeded
```

- [ ] **Step 5: Modify `ProcessManagerEffect` to carry `MetadataEnricher`**

In `eventium-core/src/Eventium/ProcessManager.hs`:

```haskell
data ProcessManagerEffect command
  = IssueCommand UUID command MetadataEnricher
  | IssueCommandWithCompensation UUID command MetadataEnricher (RejectionReason -> [ProcessManagerEffect command])
```

Update `Show` instance (enricher is opaque):

```haskell
instance (Show command) => Show (ProcessManagerEffect command) where
  show (IssueCommand uuid cmd _) = "IssueCommand " ++ show uuid ++ " " ++ show cmd
  show (IssueCommandWithCompensation uuid cmd _ _) =
    "IssueCommandWithCompensation " ++ show uuid ++ " " ++ show cmd ++ " <compensation>"
```

Update `Eq` instance:

```haskell
instance (Eq command) => Eq (ProcessManagerEffect command) where
  IssueCommand u1 c1 _ == IssueCommand u2 c2 _ = u1 == u2 && c1 == c2
  IssueCommandWithCompensation u1 c1 _ _ == IssueCommandWithCompensation u2 c2 _ _ = u1 == u2 && c1 == c2
  _ == _ = False
```

- [ ] **Step 6: Update `runProcessManagerEffects`**

In `eventium-core/src/Eventium/ProcessManager.hs`:

```haskell
runProcessManagerEffects ::
  (Monad m) =>
  CommandDispatcher m command ->
  [ProcessManagerEffect command] ->
  m ()
runProcessManagerEffects dispatcher = mapM_ go
  where
    go (IssueCommand uuid cmd enricher) =
      void $ dispatcher.dispatchCommand uuid cmd enricher
    go (IssueCommandWithCompensation uuid cmd enricher onFailure) = do
      result <- dispatcher.dispatchCommand uuid cmd enricher
      case result of
        CommandSucceeded -> pure ()
        CommandFailed reason -> mapM_ go (onFailure reason)
```

- [ ] **Step 7: Update `commandHandlerDispatcher` to thread enricher**

In `eventium-core/src/Eventium/CommandDispatcher.hs`:

The `commandHandlerDispatcher` creates a `CommandDispatcher`. It calls `applyCommandHandler` internally. Since `applyCommandHandler` doesn't take an enricher (it works with an already-enriched writer), and `commandHandlerDispatcher` receives a pre-enriched writer, the enricher needs to be applied here.

Change `commandHandlerDispatcher` to accept a tagged writer + codec instead of an enriched writer, and apply the enricher per-dispatch:

```haskell
commandHandlerDispatcher ::
  (MonadIO m, Typeable event) =>
  Codec event encoded ->
  EventStoreWriter UUID EventVersion m (TaggedEvent encoded) ->
  VersionedEventStoreReader m event ->
  [AggregateHandler event command] ->
  CommandDispatcher m command
commandHandlerDispatcher codec taggedWriter reader handlers =
  CommandDispatcher $ \uuid cmd enricher ->
    let writer = metadataEnrichingEventStoreWriterWithEnricher enricher codec taggedWriter
    in go handlers writer uuid cmd
  where
    go [] _ _ _ = pure CommandSucceeded
    go (AggregateHandler handler formatErr : rest) writer uuid cmd = do
      result <- applyCommandHandler writer reader handler uuid cmd
      case result of
        Right (_ : _) -> pure CommandSucceeded
        Left (CommandRejected err) -> pure (CommandFailed (formatErr err))
        Left (ConcurrencyConflict _) -> pure (CommandFailed "Concurrency conflict")
        Right [] -> go rest writer uuid cmd
```

Note: This changes the function signature — callers pass the raw tagged writer + codec instead of the pre-enriched writer. Import `metadataEnrichingEventStoreWriterWithEnricher` from `Eventium.Store.Class`.

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test all --test-show-details=direct`
Expected: All tests pass. Fix any remaining compilation errors from updated signatures.

- [ ] **Step 9: Commit**

```bash
cd /Users/oleksandrsy/Projects/Self/eventium
git add -A
git commit -m "feat(eventium-core): thread MetadataEnricher through command pipeline"
```

---

### Task 3: Update tests, docs, and bump versions

**Files:**
- Modify: `eventium-memory/tests/Eventium/MetadataEnrichmentSpec.hs`
- Modify: `eventium-memory/tests/Eventium/ProcessManagerSpec.hs`
- Modify: `eventium-core/tests/Eventium/CommandDispatcherSpec.hs`
- Modify: `docs/architecture.md`
- Modify: `eventium-core/package.yaml` (line 2)
- Modify: `eventium-memory/package.yaml` (line 2)
- Modify: `eventium-sql-common/package.yaml` (line 2)
- Modify: `eventium-postgresql/package.yaml` (line 2)
- Modify: `eventium-sqlite/package.yaml` (line 2)
- Modify: `eventium-testkit/package.yaml` (line 2)

- [ ] **Step 1: Verify all existing tests pass with updated signatures**

Some tests may need `IssueCommand uuid cmd` → `IssueCommand uuid cmd id` updates.

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test all --test-show-details=direct`
Fix any remaining compilation/test failures.

- [ ] **Step 2: Update `docs/architecture.md`**

In the **EventMetadata** description (around "Metadata on StreamEvent" section at the end), add `occurredAt` to the field list. Update the `ProcessManagerEffect` code block to show the `MetadataEnricher` parameter. Update `CommandDispatcher` code block. Add a new "MetadataEnricher" subsection:

```markdown
### MetadataEnricher

```haskell
type MetadataEnricher = EventMetadata -> EventMetadata
```

A builder function threaded through the command pipeline to customize event
metadata at write time. The enricher is applied after base metadata generation
(`eventType` from `Typeable`, `createdAt` from system clock).

Use `id` when no enrichment is needed. Compose enrichers with `.`:

```haskell
-- Set occurredAt for backdated events
let enricher = \m -> m { occurredAt = Just pastTime }

-- Compose multiple enrichments
let enricher = setOccurredAt . setCorrelationId
```

The enricher flows through `CommandDispatcher`, `ProcessManagerEffect`, and
`commandHandlerDispatcher`. `metadataEnrichingEventStoreWriterWithEnricher`
applies it at the writer level.
```

- [ ] **Step 3: Bump all package versions from 0.2.1 to 0.3.0**

In each `package.yaml`, change `version: 0.2.1` to `version: 0.3.0`.

Also update internal dependency constraints if any reference `== 0.2.*`.

- [ ] **Step 4: Run full test suite one final time**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test all --test-show-details=direct`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/oleksandrsy/Projects/Self/eventium
git add -A
git commit -m "feat: bump all packages to 0.3.0, update docs for MetadataEnricher"
```

---

## Part B: Backend Changes

### Task 4: Update backend to use new eventium API

**Files:**
- Modify: `src/Infrastructure/Eventium.hs:110-401`
- Modify: `cabal.project` or `package.yaml` (eventium dependency version)

- [ ] **Step 1: Update eventium dependency to 0.3.0**

In `package.yaml` or `cabal.project`, update eventium packages to `>= 0.3.0`.

- [ ] **Step 2: Update `commandDispatcher` in `Infrastructure.Eventium`**

The `commandDispatcher` function (line 272-285) currently calls `commandHandlerDispatcher writer reader handlers`. With the new API, it needs to pass the tagged writer + codec instead of the pre-enriched writer:

```haskell
commandDispatcher ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  CommandDispatcher m AccountingCommand
commandDispatcher taggedWriter reader =
  commandHandlerDispatcher
    jsonStringCodec  -- the codec used for AccountingEvent
    taggedWriter
    reader
    [ mkAggregateHandlerWith formatAccountError accountAccountingCommandHandler,
      mkAggregateHandler transactionAccountingCommandHandler,
      mkAggregateHandler userAccountingCommandHandler,
      mkAggregateHandler configurationAccountingCommandHandler
    ]
```

This requires exposing the tagged writer (before metadata enrichment) from the writer creation chain. Check `accountingEventStoreWriter` to understand the current writer chain and extract the tagged writer.

- [ ] **Step 3: Update `apply*Command` functions to accept `MetadataEnricher`**

Each `apply*Command` function (lines 340-401) needs to accept a `MetadataEnricher` and create an enriched writer per call:

```haskell
applyTransactionCommand ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  MetadataEnricher ->
  UUID ->
  TransactionCommand ->
  m (Either (CommandHandlerError TransactionError) [AccountingEvent])
applyTransactionCommand taggedWriter reader enricher txId cmd =
  let writer = metadataEnrichingEventStoreWriterWithEnricher enricher jsonStringCodec taggedWriter
  in applyCommandHandler writer reader transactionAccountingCommandHandler txId (embedWith transactionCommandEmbedding cmd)
```

Apply the same pattern to `applyAccountCommand`, `applyUserCommand`, `applyConfigurationCommand`.

- [ ] **Step 4: Update `transferManagerHandler` wiring**

The `transferManagerHandler` (line 256-263) passes a `commandDispatcher` to `processManagerEventHandler`. Update to pass the tagged writer:

```haskell
transferManagerHandler ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingGlobalEventStoreReader m ->
  AccountingVersionedEventStoreReader m ->
  AccountingEventHandler m
transferManagerHandler taggedWriter globalReader versionedReader =
  processManagerEventHandler transferProcessManager globalReader (commandDispatcher taggedWriter versionedReader)
```

- [ ] **Step 5: Update `accountingEventStoreWriter` to expose tagged writer**

Review the writer creation chain in `accountingEventStoreWriter` and refactor so the tagged writer is available separately. The enriched writer (with `id` enricher) is still used for the event bus publisher.

- [ ] **Step 6: Update all callers of `apply*Command` in `TransactionService`**

In `src/Application/Services/TransactionService.hs`, every call to `applyTransactionCommand` (e.g. line 110) needs to pass `id` as the enricher for now (will be replaced with the real enricher in Task 7):

```haskell
result <- liftIO $ applyTransactionCommand taggedWriter reader id transactionUuid (InitiateTransferTransactionCommand transferCmd)
```

Similarly update any callers of `applyAccountCommand`, `applyUserCommand`, `applyConfigurationCommand`.

- [ ] **Step 7: Update `Main.hs` wiring**

In `app/Main.hs`, the writer creation (lines 267-276) needs to pass the tagged writer to components that need per-call enrichment, and keep the enriched writer for the event bus.

- [ ] **Step 8: Build and run tests**

Run: `just build && just test`
Expected: All tests pass with the new eventium API.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: update to eventium 0.3.0 MetadataEnricher API"
```

---

### Task 5: Event-sourced exchange rate store

**Files:**
- Create: `src/Infrastructure/ExchangeRate/Store.hs`
- Modify: `src/Infrastructure/ExchangeRate/Provider.hs:88-133`
- Modify: `app/Main.hs:317-327`
- Create: `test/Infrastructure/ExchangeRate/StoreSpec.hs`
- Create: `test/Infrastructure/ExchangeRate/StorePropertySpec.hs`

- [ ] **Step 1: Write property tests for `lookupRate` nearest-date logic**

Create `test/Infrastructure/ExchangeRate/StorePropertySpec.hs`:

```haskell
module Infrastructure.ExchangeRate.StorePropertySpec (spec) where

import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time (Day, fromGregorian, diffDays)
import Infrastructure.ExchangeRate.Store (lookupNearestDate)

spec :: Spec
spec = describe "ExchangeRate.Store" $ do
  describe "lookupNearestDate" $ do
    prop "exact match always returns that date" $ do
      \(dates :: [Day]) (target :: Day) ->
        let dayMap = Map.fromList [(d, d) | d <- target : dates]
        in lookupNearestDate dayMap target === Just (target, target)

    prop "prefers earlier date over later when equidistant" $ do
      \(Positive n :: Positive Integer) ->
        let target = fromGregorian 2025 6 15
            earlier = fromGregorian 2025 6 (15 - n)
            later = fromGregorian 2025 6 (15 + n)
            dayMap = Map.fromList [(earlier, "early"), (later, "late")]
        in fmap fst (lookupNearestDate dayMap target) === Just earlier

    prop "returns Nothing for empty map" $ do
      \(target :: Day) ->
        lookupNearestDate (Map.empty :: Map Day ()) target === Nothing
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test all --test-option='--match' --test-option='/ExchangeRate.Store/'`
Expected: Compilation error — module doesn't exist.

- [ ] **Step 3: Implement `Infrastructure.ExchangeRate.Store`**

Create `src/Infrastructure/ExchangeRate/Store.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.Store
  ( ExchangeRateEvent (..),
    ExchangeRateHistory,
    ExchangeRateStore (..),
    newExchangeRateStore,
    lookupHistoricalRate,
    lookupNearestDate,
    publishRates,
    exchangeRateStreamId,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (Day, UTCTime, diffDays, getCurrentTime, utctDay)
import Domain.Core.Types (Currency, ExchangeRate)
import GHC.Generics (Generic)
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), getRate)
import RIO
import qualified RIO.Map as Map

-- | Well-known stream UUID for the exchange rate event stream.
-- Nil UUID with last byte set to 1, used as a namespace identifier.
exchangeRateStreamId :: UUID
exchangeRateStreamId = uuidFromInteger 1  -- from Eventium.UUID

-- | Exchange rate events.
data ExchangeRateEvent
  = ExchangeRatesPublished
      { date :: !Day,
        provider :: !Text,
        rates :: !ExchangeRateMap
      }
  deriving (Show, Eq, Generic)

instance ToJSON ExchangeRateEvent
instance FromJSON ExchangeRateEvent

-- | Historical exchange rates indexed by day.
type ExchangeRateHistory = Map Day ExchangeRateMap

-- | Event-sourced exchange rate store.
data ExchangeRateStore = ExchangeRateStore
  { historyRef :: !(IORef ExchangeRateHistory),
    rateProvider :: !RateProvider
  }

-- | Create a new empty store.
newExchangeRateStore :: RateProvider -> IO ExchangeRateStore
newExchangeRateStore prov = ExchangeRateStore <$> newIORef Map.empty <*> pure prov

-- | Replay events to populate the store.
replayRateEvents :: ExchangeRateStore -> [ExchangeRateEvent] -> IO ()
replayRateEvents store events =
  modifyIORef' store.historyRef $ \history ->
    foldl' (\h (ExchangeRatesPublished d _ r) -> Map.insert d r h) history events

-- | Look up a rate for a given date, using nearest-date fallback.
lookupHistoricalRate :: ExchangeRateStore -> Day -> Currency -> Currency -> IO (Maybe ExchangeRate)
lookupHistoricalRate store day src tgt = do
  history <- readIORef store.historyRef
  pure $ do
    (_, rateMap) <- lookupNearestDate history day
    getRate rateMap src tgt

-- | Find the nearest date in a map. Prefers earlier dates.
lookupNearestDate :: Map Day v -> Day -> Maybe (Day, v)
lookupNearestDate m target
  | Map.null m = Nothing
  | otherwise =
      let before = Map.lookupLE target m
          after = Map.lookupGE target m
      in case (before, after) of
           (Just (bDay, bVal), Just (aDay, aVal))
             | bDay == target -> Just (bDay, bVal)  -- exact match
             | diffDays target bDay <= diffDays aDay target -> Just (bDay, bVal)
             | otherwise -> Just (aDay, aVal)
           (Just bv, Nothing) -> Just bv
           (Nothing, Just av) -> Just av
           (Nothing, Nothing) -> Nothing

-- | Publish today's rates if not already present.
publishRates :: ExchangeRateStore -> IO (Either Text ExchangeRateEvent)
publishRates store = do
  today <- utctDay <$> getCurrentTime
  history <- readIORef store.historyRef
  case Map.lookup today history of
    Just _ -> pure $ Left "Rates already published for today"
    Nothing -> do
      result <- store.rateProvider.fetchRates
      case result of
        Left err -> pure $ Left err
        Right rates -> do
          let event = ExchangeRatesPublished today store.rateProvider.providerName rates
          modifyIORef' store.historyRef (Map.insert today rates)
          pure $ Right event
```

Adjust imports and UUID generation as needed (use `Data.UUID` or a namespace UUID).

- [ ] **Step 4: Run property tests**

Run: `cabal test all --test-option='--match' --test-option='/ExchangeRate.Store/'`
Expected: All property tests pass.

- [ ] **Step 5: Write unit tests for `lookupHistoricalRate`**

Create `test/Infrastructure/ExchangeRate/StoreSpec.hs` with tests for:
- Exact date match returns correct rate
- No exact match returns nearest earlier date
- No earlier date falls back to later date
- Empty history returns Nothing
- Same-currency returns Nothing (via `getRate`)

- [ ] **Step 6: Run all tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add event-sourced exchange rate store with nearest-date lookup"
```

---

### Task 6: Wire exchange rate store into startup and daily fetch

**Files:**
- Modify: `app/Main.hs:317-327`
- Modify: `src/Infrastructure/App.hs` (AppEnv — replace exchange rate cache with store)
- Modify: `src/Infrastructure/ExchangeRate/Provider.hs` (remove ExchangeRateCache)

- [ ] **Step 1: Replace `ExchangeRateCache` with `ExchangeRateStore` in `AppEnv`**

Update `HasExchangeRateCache` (or rename to `HasExchangeRateStore`) in `Infrastructure.App` to reference `ExchangeRateStore` instead of `ExchangeRateCache`.

- [ ] **Step 2: Implement event store integration for `ExchangeRateEvent`**

Add functions to `src/Infrastructure/ExchangeRate/Store.hs` for reading/writing rate events via the event store. The rate events live in a dedicated stream identified by `exchangeRateStreamId`, separate from the `AccountingEvent` streams.

Since `ExchangeRateEvent` is not part of the `AccountingEvent` sum type, it needs its own codec and writer. Use the raw tagged writer with a dedicated JSON codec:

```haskell
-- | Codec for exchange rate events (JSON serialization).
exchangeRateCodec :: Codec ExchangeRateEvent JSONString
exchangeRateCodec = Codec (encodeJSON) (decodeJSON)

-- | Replay all exchange rate events from the event store into the store.
replayRateEventsFromStore ::
  (MonadIO m) =>
  VersionedEventStoreReader (SqlPersistT m) JSONString ->
  ExchangeRateStore ->
  Pool SqlBackend ->
  m Int
replayRateEventsFromStore reader store pool = do
  events <- liftIO $ runSqlPool (reader.getEvents (allEvents exchangeRateStreamId)) pool
  let decoded = mapMaybe (\se -> exchangeRateCodec.decode se.payload) events
  liftIO $ replayRateEvents store decoded
  pure (length decoded)

-- | Store a new exchange rate event in the event store.
storeRateEvent ::
  (MonadIO m) =>
  EventStoreWriter UUID EventVersion (SqlPersistT m) (TaggedEvent JSONString) ->
  ExchangeRateEvent ->
  Pool SqlBackend ->
  m ()
storeRateEvent taggedWriter event pool = do
  now <- liftIO getCurrentTime
  let tagged = TaggedEvent
        (EventMetadata "ExchangeRatesPublished" Nothing Nothing (Just now) Nothing)
        (encodeJSON event)
  void $ liftIO $ runSqlPool (taggedWriter.storeEvents exchangeRateStreamId AnyPosition [tagged]) pool
```

Adjust imports: `Eventium.Store.Sql.JSONString` (`encodeJSON`, `decodeJSON`, `JSONString`), `Eventium.Store.Class`, `Database.Persist.Sql` (`runSqlPool`, `Pool`, `SqlBackend`).

- [ ] **Step 3: Update `Main.hs` initialization**

Replace the cache initialization (lines 317-327) with:

```haskell
-- 6b. Initialize exchange rate store
logInfo "Initializing exchange rate store..."
rateProvider <- case config.exchangeRate.provider of
  "nbu" -> pure nbuProvider
  "ecb" -> pure ecbProvider
  unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
exchangeRateStore <- liftIO $ newExchangeRateStore rateProvider

-- Replay historical rate events from event store
eventCount <- replayRateEventsFromStore sqlReader exchangeRateStore pool
logInfo $ "Exchange rate history loaded (" <> displayShow eventCount <> " events)"

-- Fetch today's rates if not present
publishResult <- liftIO $ publishRates exchangeRateStore
case publishResult of
  Right event -> do
    storeRateEvent sqlTaggedWriter event pool
    logInfo $ "Today's rates published from " <> display (config.exchangeRate.provider)
  Left msg -> logWarn $ "Rate publish skipped: " <> display msg
```

The `sqlReader` and `sqlTaggedWriter` are the raw SQL-level reader/writer (before codec wrapping), available from the existing event store setup at lines 267-276.

- [ ] **Step 4: Remove `ExchangeRateCache` type from `Provider.hs`**

Remove `ExchangeRateCache`, `newExchangeRateCache`, `getCachedRate`, `refreshCache` from `Infrastructure.ExchangeRate.Provider`. Keep `RateProvider`, `ExchangeRateMap`, `getRate`, `deriveCrossRates`.

- [ ] **Step 5: Update all callers of the old cache API**

Grep for `getCachedRate`, `ExchangeRateCache`, `exchangeRateCacheL` and update to use the new store.

- [ ] **Step 6: Build and test**

Run: `just build && just test`
Expected: All tests pass. Fix broken tests that relied on the old cache.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: wire event-sourced exchange rate store into startup"
```

---

### Task 7: Add `date` field to transfer DTOs and service

**Files:**
- Modify: `src/Web/Types.hs:333-376` (IncomeRequest, ExpenseRequest, InternalTransferRequest)
- Modify: `src/Web/Types.hs:418-438` (TransactionResponse)
- Modify: `src/Web/Types.hs:807-825` (fromTransactionData)
- Modify: `src/Web/API/TransactionAPI.hs:124-212` (handlers)
- Modify: `src/Application/Services/TransactionService.hs:146-392` (service functions, resolveAmounts)
- Modify: `src/Application/ReadModels/Transaction.hs:77-88` (TransactionData)

- [ ] **Step 1: Write tests for future-date validation**

Add test in the appropriate service test file:

```haskell
it "rejects dates in the future" $ do
  futureDate <- addUTCTime 3600 <$> getCurrentTime
  -- call service with futureDate, expect Left with validation error
```

- [ ] **Step 2: Add `date :: Maybe UTCTime` to request DTOs**

In `src/Web/Types.hs`, add to `IncomeRequest` (line 333-345):

```haskell
data IncomeRequest = IncomeRequest
  { accountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    description :: Text,
    date :: Maybe UTCTime
  }
```

Same for `ExpenseRequest` and `InternalTransferRequest`.

- [ ] **Step 3: Add `date :: Text` to `TransactionResponse`**

In `src/Web/Types.hs` (line 418-438):

```haskell
data TransactionResponse = TransactionResponse
  { id :: UUID,
    sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount :: Double,
    sourceCurrency :: Text,
    targetAmount :: Double,
    targetCurrency :: Text,
    exchangeRate :: Maybe Double,
    description :: Text,
    status :: Text,
    failureReason :: Maybe Text,
    transferType :: Text,
    category :: Maybe Text,
    date :: Text
  }
```

- [ ] **Step 4: Add `date :: UTCTime` to `TransactionData`**

In `src/Application/ReadModels/Transaction.hs` (line 77-88):

```haskell
data TransactionData = TransactionData
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    status :: TransactionStatus,
    transferType :: TransferType,
    date :: UTCTime
  }
```

Update the `processEvent` function (line 179-198) to populate `date` from the event metadata's `occurredAt`, falling back to `createdAt`:

```haskell
-- In the TransferInitiatedEvent case:
let eventDate = fromMaybe (fromMaybe (UTCTime (fromGregorian 1970 1 1) 0) versionedEvent.metadata.createdAt)
                           versionedEvent.metadata.occurredAt
    newEntry = TransactionData
      { -- ... existing fields ...
        date = eventDate
      }
```

- [ ] **Step 5: Update `fromTransactionData` to include `date`**

In `src/Web/Types.hs` (line 807-825), add:

```haskell
date = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" summary.date
```

Import `Data.Time.Format` (`formatTime`, `defaultTimeLocale`).

- [ ] **Step 6: Update handlers to parse `date` and validate**

In `src/Web/API/TransactionAPI.hs`, each handler (`incomeHandler`, `expenseHandler`, `transferHandler`) needs to:

1. Default `request.date` to `getCurrentTime` if `Nothing`
2. Validate date is not in the future
3. Pass date to service functions

- [ ] **Step 7: Update service functions to accept `UTCTime`**

In `src/Application/Services/TransactionService.hs`:

- `initiateIncome`, `initiateExpense`, `initiateInternalTransfer` gain a `UTCTime` parameter
- `resolveAmounts` gains a `Day` parameter for rate lookup
- The enricher is constructed: `\m -> m { occurredAt = Just transferDate }`
- Pass enricher to `applyTransactionCommand`

- [ ] **Step 8: Update test fixtures**

All existing tests that construct `TransactionData` need the new `date` field. Use a fixed date or `getCurrentTime` in test setup.

- [ ] **Step 9: Build and test**

Run: `just build && just test`
Expected: All tests pass.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: add date field to transfer DTOs and service layer"
```

---

### Task 8: Propagate `occurredAt` through the transfer saga

**Files:**
- Modify: `src/Application/ProcessManagers/TransferManager.hs:83-280`
- Modify: `test/Application/ProcessManagers/TransferManagerSpec.hs`
- Modify: `test/Application/ProcessManagers/TransferManagerPropertySpec.hs`

- [ ] **Step 1: Write test for `occurredAt` propagation**

In `test/Application/ProcessManagers/TransferManagerSpec.hs`, add:

```haskell
it "propagates occurredAt from TransferInitiated to saga effects" $ do
  let pastTime = UTCTime (fromGregorian 2025 3 15) 0
      metadata = (emptyMetadata "TransferInitiated") { occurredAt = Just pastTime }
      event = StreamEvent txUuid 0 metadata (TransferInitiatedEvent initiatedEvt)
      effects = reactToTransferEvent (handleTransferEvent transferManagerDefault event) event
  -- All effects should carry an enricher that sets occurredAt
  case effects of
    [IssueCommandWithCompensation _ _ enricher _] ->
      (enricher (emptyMetadata "test")).occurredAt `shouldBe` Just pastTime
    _ -> expectationFailure $ "Expected IssueCommandWithCompensation, got: " ++ show effects
```

- [ ] **Step 2: Add `occurredAt` to `TransferData`**

In `src/Application/ProcessManagers/TransferManager.hs` (line 103-117):

```haskell
data TransferData = TransferData
  { sourceAccount :: AccountId,
    targetAccount :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    description :: Text,
    phase :: TransferPhase,
    occurredAt :: Maybe UTCTime
  }
```

- [ ] **Step 3: Populate `occurredAt` from event metadata in `handleTransferEvent`**

In `handleTransferEvent` (line 145), when processing `TransferInitiatedEvent`:

```haskell
handleTransferEvent manager (StreamEvent txUuid _ metadata (TransferInitiatedEvent evt)) =
  case mkTransactionIdSafe txUuid of
    Nothing -> manager
    Just txId ->
      case manager ^. #transfers % at txId of
        Nothing ->
          manager
            & #transfers
            % at txId
            ?~ TransferData
              { sourceAccount = evt.sourceAccountId,
                targetAccount = evt.targetAccountId,
                sourceAmount = evt.sourceAmount,
                targetAmount = evt.targetAmount,
                description = evt.description,
                phase = AwaitingDebit,
                occurredAt = metadata.occurredAt
              }
        -- ... rest unchanged
```

- [ ] **Step 4: Build enricher from `occurredAt` in `reactToTransferEvent`**

In `reactToTransferEvent` (line 196), construct the enricher from the event metadata:

```haskell
reactToTransferEvent manager (StreamEvent txUuid _ metadata (TransferInitiatedEvent evt)) =
  case mkTransactionIdSafe txUuid of
    Nothing -> []
    Just txId ->
      let enricher = case metadata.occurredAt of
            Just t  -> \m -> m { occurredAt = Just t }
            Nothing -> id
      in case manager ^. #transfers % at txId of
           Just td
             | td.phase == AwaitingDebit ->
                 [ IssueCommandWithCompensation
                     (unAccountId evt.sourceAccountId)
                     (embedWith accountCommandEmbedding ...)
                     enricher
                     (\(RejectionReason rejReason) -> ...)
                 ]
           _ -> []
```

Similarly for `AccountDebitedEvent` reaction — read `occurredAt` from `TransferData`:

```haskell
reactToTransferEvent manager (StreamEvent _ _ _ (AccountDebitedEvent evt)) =
  case Map.lookup evt.transactionId (manager ^. #transfers) of
    Nothing -> []
    Just TransferData {..} ->
      let enricher = case occurredAt of
            Just t  -> \m -> m { Eventium.occurredAt = Just t }
            Nothing -> id
      in [ IssueCommand (unAccountId targetAccount) (...) enricher,
           IssueCommand (unTransactionId evt.transactionId) (...) enricher
         ]
```

- [ ] **Step 5: Update compensation effects to carry enricher**

The compensation function in `IssueCommandWithCompensation` also needs the enricher:

```haskell
(\(RejectionReason rejReason) ->
    [ IssueCommand
        (unTransactionId txId)
        (embedWith transactionCommandEmbedding (FailTransferTransactionCommand FailTransfer {reason = rejReason}))
        enricher
    ]
)
```

- [ ] **Step 6: Run tests**

Run: `just test`
Expected: All tests pass, including the new `occurredAt` propagation test.

- [ ] **Step 7: Run integration tests**

Run: `cabal test all --test-option='--match' --test-option='/Transfer/'`
Expected: Transfer workflow integration tests pass.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: propagate occurredAt through transfer saga via MetadataEnricher"
```

---

### Task 9: Final integration and cleanup

**Files:**
- Modify: `src/Infrastructure/ExchangeRate/Provider.hs` (remove dead code)
- Modify: `test/Infrastructure/ExchangeRate/CacheSpec.hs` (update or remove)

- [ ] **Step 1: Remove dead `ExchangeRateCache` tests**

Update or remove `test/Infrastructure/ExchangeRate/CacheSpec.hs` — the cache is replaced by the event-sourced store.

- [ ] **Step 2: Run full test suite**

Run: `just check && just test`
Expected: Formatting passes, linting passes, all tests pass.

- [ ] **Step 3: Run the application**

Run: `just docker-up && just run`
Expected: Application starts, exchange rate history loads, endpoints accept optional `date` field.

- [ ] **Step 4: Manual smoke test**

```bash
# Create a backdated income
curl -X POST http://localhost:8080/api/transactions/income \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"accountId":"...","amount":100,"currency":"UAH","category":"salary","description":"March salary","date":"2026-03-15T12:00:00Z"}'

# Verify the response includes the backdated date
# Verify the date field shows 2026-03-15T12:00:00Z, not today

# Create a transfer without date (should default to now)
curl -X POST http://localhost:8080/api/transactions/income \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{"accountId":"...","amount":50,"currency":"UAH","category":"salary","description":"Today income"}'

# Verify date is approximately now
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: clean up dead exchange rate cache code"
```
