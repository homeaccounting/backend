{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ExchangeRatePublisherSpec
-- Description : Failing (red) unit tests for the exchange-rate publisher service.
--
-- These tests describe the behaviour of
-- @Application.Services.ExchangeRatePublisher@ before it is implemented.
-- The module does not yet exist, so this spec intentionally fails at
-- the import / compile step — that is the success condition for Task 6
-- of the persistable-exchange-rates plan.
--
-- Wiring mirrors production: the in-memory tagged writer is composed
-- with 'synchronousPublisher' so that 'ExchangeRatesPublishedEvent's
-- written by 'publishRates' are delivered to the read-model TVar
-- automatically, enabling the idempotence assertion on a second call.
module Application.Services.ExchangeRatePublisherSpec (spec) where

import Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel,
    createExchangeRateReadModel,
    handleExchangeRateEvents,
  )
import Application.Services.ExchangeRatePublisher
  ( providerStreamId,
    publishRates,
  )
import Data.Time (getCurrentTime, utctDay)
import qualified Data.UUID as UUID
import Domain.Core.Types (Currency (..))
import Domain.ExchangeRate.Events (ExchangeRateMap, ExchangeRatesPublished (..), Provider)
import Domain.Models (AccountingEvent (..))
import Eventium
  ( Codec (..),
    EventHandler (..),
    EventMetadata (..),
    EventStoreReader (..),
    EventStoreWriter (..),
    EventVersion,
    StreamEvent (..),
    TaggedEvent (..),
    allEvents,
    emptyMetadata,
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
-- Spec harness — inline to avoid modifying Testkit modules.
-- -----------------------------------------------------------------------------

-- | Bundle the IO-lifted event-store pieces the publisher needs plus
-- the read-model TVar that the tagged writer feeds synchronously.
data PublisherHarness = PublisherHarness
  { harnessWriter :: !(AccountingTaggedEventStoreWriter IO),
    harnessReader :: !(AccountingVersionedEventStoreReader IO),
    harnessGlobalReader :: !(AccountingGlobalEventStoreReader IO),
    harnessReadModel :: !(TVar ExchangeRateReadModel)
  }

-- | Build a self-contained in-memory harness. The tagged writer is
-- wired through 'synchronousPublisher' so that every successfully
-- persisted 'ExchangeRatesPublishedEvent' also updates the read model
-- TVar — matching the production wiring in
-- 'Testkit.InMemoryEventStore.createTestAppEnv'.
mkHarness :: IO PublisherHarness
mkHarness = do
  stores <- createInMemoryEventStores
  rm <- createExchangeRateReadModel
  let reader = liftSTMVersionedReader stores.inMemoryReader
      globalReader = liftSTMGlobalReader stores.inMemoryGlobalReader
      taggedBaseWriter =
        liftSTMTaggedEventWriter (tvarTaggedEventStoreWriter stores.inMemoryEventMap)
      rmHandler = EventHandler $ \versionedEvent ->
        let globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
         in handleExchangeRateEvents rm [globalEvent]
      writer =
        publishingTaggedCodecEventStoreWriter
          (jsonStringCodec :: Codec AccountingEvent JSONString)
          (decodingTaggedWriter taggedBaseWriter)
          (synchronousPublisher rmHandler)
  pure
    PublisherHarness
      { harnessWriter = writer,
        harnessReader = reader,
        harnessGlobalReader = globalReader,
        harnessReadModel = rm
      }

-- | Lift an STM tagged (AccountingEvent) writer to IO. The tagged
-- variant preserves 'EventMetadata' through to the in-memory store —
-- unlike the versioned writer used in the broader testkit which
-- synthesises empty metadata.
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

-- | Adapt a tagged-domain-event writer to accept serialized
-- 'TaggedEvent' payloads by decoding each payload through the JSON
-- codec while preserving the associated 'EventMetadata'.
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
-- Provider stubs
-- -----------------------------------------------------------------------------

fixedRateProvider :: Provider -> ExchangeRateMap -> RateProvider
fixedRateProvider name rates =
  RateProvider
    { providerName = name,
      fetchRates = pure (Right rates)
    }

failingRateProvider :: Provider -> Text -> RateProvider
failingRateProvider name err =
  RateProvider
    { providerName = name,
      fetchRates = pure (Left err)
    }

-- | One-pair rate map used across tests.
sampleRates :: ExchangeRateMap
sampleRates = Map.singleton (USD, UAH) (mockExchangeRate USD UAH 41)

-- | Count the events currently persisted on a given stream.
streamEventCount ::
  AccountingVersionedEventStoreReader IO -> UUID.UUID -> IO Int
streamEventCount (EventStoreReader readRange) streamId =
  length <$> readRange (allEvents streamId)

-- | Fetch the single persisted event on a given stream (fails loudly
-- when the count is not exactly one — desired for the first-publish
-- assertions).
singleStreamEvent ::
  AccountingVersionedEventStoreReader IO ->
  UUID.UUID ->
  IO (StreamEvent UUID.UUID EventVersion AccountingEvent)
singleStreamEvent (EventStoreReader readRange) streamId = do
  events <- readRange (allEvents streamId)
  case events of
    [single] -> pure single
    _ -> error $ "singleStreamEvent: expected exactly one, got " <> show (length events)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Application.Services.ExchangeRatePublisher" $ do
  describe "publishRates" $ do
    it "appends exactly one ExchangeRatesPublishedEvent to the provider's stream on first publish" $ do
      h <- mkHarness
      let prov = fixedRateProvider "ecb" sampleRates
      result <- publishRates prov h.harnessWriter h.harnessReader h.harnessReadModel
      result `shouldBe` Right ()
      let streamId = providerStreamId "ecb"
      count <- streamEventCount h.harnessReader streamId
      count `shouldBe` 1
      persisted <- singleStreamEvent h.harnessReader streamId
      case persisted.payload of
        ExchangeRatesPublishedEvent published -> do
          published.provider `shouldBe` "ecb"
          published.rates `shouldBe` sampleRates
        other ->
          expectationFailure
            $ "Expected ExchangeRatesPublishedEvent, got: "
            <> show other

    it "stamps the persisted event's at field to today (UTC)" $ do
      h <- mkHarness
      today <- utctDay <$> getCurrentTime
      let prov = fixedRateProvider "ecb" sampleRates
      _ <- publishRates prov h.harnessWriter h.harnessReader h.harnessReadModel
      persisted <- singleStreamEvent h.harnessReader (providerStreamId "ecb")
      case persisted.payload of
        ExchangeRatesPublishedEvent published -> published.at `shouldBe` today
        other ->
          expectationFailure
            $ "Expected ExchangeRatesPublishedEvent, got: "
            <> show other

    it "is idempotent for the same day — second call returns Left and does not re-append" $ do
      h <- mkHarness
      let prov = fixedRateProvider "ecb" sampleRates
      firstResult <- publishRates prov h.harnessWriter h.harnessReader h.harnessReadModel
      firstResult `shouldBe` Right ()
      -- The read model was updated synchronously by the event bus when
      -- the first publish succeeded (see 'mkHarness'); no manual prime.
      secondResult <- publishRates prov h.harnessWriter h.harnessReader h.harnessReadModel
      secondResult `shouldSatisfy` isLeft
      count <- streamEventCount h.harnessReader (providerStreamId "ecb")
      count `shouldBe` 1

    it "propagates provider failures and writes nothing" $ do
      h <- mkHarness
      let prov = failingRateProvider "ecb" "boom"
      result <- publishRates prov h.harnessWriter h.harnessReader h.harnessReadModel
      result `shouldBe` Left "boom"
      count <- streamEventCount h.harnessReader (providerStreamId "ecb")
      count `shouldBe` 0

  describe "providerStreamId" $ do
    it "is deterministic for the same provider name"
      $ providerStreamId "ecb"
      `shouldBe` providerStreamId "ecb"

    it "produces distinct UUIDs for distinct provider names"
      $ providerStreamId "ecb"
      `shouldNotBe` providerStreamId "nbu"
