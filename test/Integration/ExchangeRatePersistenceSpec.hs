{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.ExchangeRatePersistenceSpec
-- Description : End-to-end persistence round-trip for exchange rates.
--
-- Closes the loop that motivates the feature: "rates published in an old
-- process must be available in a new one". The test:
--
--   1. Runs 'publishRates' once against an in-memory tagged store.
--   2. Discards the read model that observed the live publish.
--   3. Builds a fresh 'ExchangeRateReadModel' and replays every
--      persisted event through 'handleExchangeRateEvents'.
--   4. Asserts 'lookupHistoricalRate' on the fresh read model returns
--      the originally published rate.
--
-- The harness mirrors the production wiring used in
-- 'Testkit.InMemoryEventStore.createTestAppEnv' (tagged writer +
-- synchronous publisher), but keeps the writer/reader pieces local so
-- the test can construct a second read model against the same backing
-- store without touching 'AppEnv'.
module Integration.ExchangeRatePersistenceSpec (spec) where

import Application.ReadModels.ExchangeRate
  ( createExchangeRateReadModel,
    handleExchangeRateEvents,
    lookupHistoricalRate,
  )
import Application.Services.ExchangeRatePublisher
  ( providerStreamId,
    publishRates,
  )
import Data.Time (getCurrentTime, utctDay)
import qualified Data.UUID as UUID
import Domain.Core.Types (Currency (..), exchangeRateValue)
import Domain.ExchangeRate.Events (ExchangeRateMap, Provider)
import Domain.Models (AccountingEvent)
import Eventium
  ( Codec (..),
    EventHandler (..),
    EventStoreReader (..),
    EventStoreWriter (..),
    EventVersion,
    TaggedEvent (..),
    allEvents,
    publishingTaggedCodecEventStoreWriter,
    synchronousPublisher,
  )
import Eventium.Store.Memory (tvarTaggedEventStoreWriter)
import Eventium.Store.Postgresql (JSONString, jsonStringCodec)
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
  )
import Infrastructure.ExchangeRate.Provider (RateProvider (..))
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (mockExchangeRate)
import Testkit.InMemoryEventStore
  ( InMemoryEventStores (..),
    createInMemoryEventStores,
  )

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

-- | Everything a publish-then-replay test needs from the in-memory
-- store. Unlike 'Testkit.InMemoryEventStore.createTestAppEnv', the
-- tagged writer is backed by 'tvarTaggedEventStoreWriter' so that
-- 'EventMetadata.occurredAt' is preserved through to the persisted
-- event — the replayed read model relies on that metadata for its
-- business-day index.
data PersistenceHarness = PersistenceHarness
  { persistWriter :: !(AccountingTaggedEventStoreWriter IO),
    persistReader :: !(AccountingVersionedEventStoreReader IO),
    persistGlobalReader :: !(AccountingGlobalEventStoreReader IO)
  }

mkHarness :: IO PersistenceHarness
mkHarness = do
  stores <- createInMemoryEventStores
  let taggedBaseWriter =
        liftSTMTaggedEventWriter (tvarTaggedEventStoreWriter stores.inMemoryEventMap)
      -- No subscribers: the live read model is intentionally absent so
      -- the test cannot accidentally pass by reading from a model
      -- populated during publish.
      writer =
        publishingTaggedCodecEventStoreWriter
          (jsonStringCodec :: Codec AccountingEvent JSONString)
          (decodingTaggedWriter taggedBaseWriter)
          (synchronousPublisher (EventHandler $ \_ -> pure ()))
  pure
    PersistenceHarness
      { persistWriter = writer,
        persistReader = liftSTMVersionedReader stores.inMemoryReader,
        persistGlobalReader = liftSTMGlobalReader stores.inMemoryGlobalReader
      }

liftSTMTaggedEventWriter ::
  EventStoreWriter UUID.UUID EventVersion STM (TaggedEvent AccountingEvent) ->
  EventStoreWriter UUID.UUID EventVersion IO (TaggedEvent AccountingEvent)
liftSTMTaggedEventWriter (EventStoreWriter stmWrite) =
  EventStoreWriter $ \uuid expectedVersion events ->
    atomically $ stmWrite uuid expectedVersion events

liftSTMVersionedReader ::
  AccountingVersionedEventStoreReader STM ->
  AccountingVersionedEventStoreReader IO
liftSTMVersionedReader (EventStoreReader stmRead) =
  EventStoreReader $ \range -> atomically $ stmRead range

liftSTMGlobalReader ::
  AccountingGlobalEventStoreReader STM ->
  AccountingGlobalEventStoreReader IO
liftSTMGlobalReader (EventStoreReader stmRead) =
  EventStoreReader $ \range -> atomically $ stmRead range

-- | Preserve metadata when routing serialized tagged events back down
-- to the tagged domain-event writer. Matches the pattern in
-- 'Application.Services.ExchangeRatePublisherSpec'.
decodingTaggedWriter ::
  (Monad m) =>
  EventStoreWriter UUID.UUID EventVersion m (TaggedEvent AccountingEvent) ->
  AccountingTaggedEventStoreWriter m
decodingTaggedWriter (EventStoreWriter write) =
  EventStoreWriter $ \uuid expectedVersion taggedEvents ->
    case traverse decodeTagged taggedEvents of
      Nothing -> error "decodingTaggedWriter: codec decode failure"
      Just events -> write uuid expectedVersion events
  where
    decodeTagged (TaggedEvent meta encoded) =
      TaggedEvent meta <$> (jsonStringCodec :: Codec AccountingEvent JSONString).decode encoded

-- -----------------------------------------------------------------------------
-- Provider stub
-- -----------------------------------------------------------------------------

fixedRateProvider :: Provider -> ExchangeRateMap -> RateProvider
fixedRateProvider name rates =
  RateProvider
    { providerName = name,
      fetchRates = pure (Right rates)
    }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration.ExchangeRatePersistence" $ do
  it "replays a persisted ExchangeRatesPublishedEvent into a fresh read model" $ do
    PersistenceHarness writer reader globalReader <- mkHarness
    today <- utctDay <$> getCurrentTime

    -- 1. First "process": publish rates through the event store. The
    -- live read model is intentionally absent from the synchronous bus
    -- (see 'mkHarness'); the event must therefore be observable only
    -- via replay.
    let published = mockExchangeRate USD UAH 41
        rates = Map.singleton (USD, UAH) published
        prov = fixedRateProvider "ecb" rates
    liveRM <- createExchangeRateReadModel
    result <- publishRates prov writer reader liveRM
    result `shouldBe` Right ()

    -- Sanity: liveRM never saw the event, because the publishing
    -- writer was wired with a no-op subscriber.
    preReplay <- lookupHistoricalRate liveRM "ecb" today USD UAH
    preReplay `shouldBe` Nothing

    -- 2. Second "process": fresh read model, replay from the global
    -- stream (the same mechanism Main.hs uses at startup via
    -- 'replayReadModels').
    freshRM <- createExchangeRateReadModel
    let EventStoreReader readGlobal = globalReader
    globalEvents <- readGlobal (allEvents ())
    handleExchangeRateEvents freshRM globalEvents

    -- 3. The fresh model must now resolve the rate that was fetched
    -- by the provider stub in the first process.
    postReplay <- lookupHistoricalRate freshRM "ecb" today USD UAH
    case postReplay of
      Nothing ->
        expectationFailure
          "Expected freshly replayed read model to know today's USD→UAH rate"
      Just er ->
        exchangeRateValue er `shouldBe` exchangeRateValue published

  it "persists exactly one event on the provider's stream" $ do
    PersistenceHarness writer reader _globalReader <- mkHarness
    liveRM <- createExchangeRateReadModel
    let prov = fixedRateProvider "ecb" (Map.singleton (USD, UAH) (mockExchangeRate USD UAH 41))
    _ <- publishRates prov writer reader liveRM
    let EventStoreReader readStream = reader
    persisted <- readStream (allEvents (providerStreamId "ecb"))
    length persisted `shouldBe` 1
