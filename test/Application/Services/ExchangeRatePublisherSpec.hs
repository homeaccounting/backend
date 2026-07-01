{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ExchangeRatePublisherSpec
-- Description : Unit tests for the exchange-rate publisher service.
--
-- Wiring mirrors production: 'createTestAppEnv' builds a SQLite-backed env
-- whose event-store writer synchronously projects the persistent
-- @exchange_rates@ read model in the append transaction. So an
-- 'ExchangeRatesPublishedEvent' written by 'publishRates' immediately lands
-- in the table the publisher's idempotency guard ('ratesPublishedOn')
-- queries — enabling the second-call idempotence assertion.
module Application.Services.ExchangeRatePublisherSpec (spec) where

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
  ( EventStoreReader (..),
    EventVersion,
    StreamEvent (..),
    allEvents,
  )
import Infrastructure.App (AppEnv (..))
import Infrastructure.Eventium (AccountingVersionedEventStoreReader)
import Infrastructure.ExchangeRate.Provider (RateProvider (..))
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (mockExchangeRate)
import Testkit.InMemoryEventStore (createTestAppEnv)

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

-- | Publish @prov@'s rates against the env's writer/reader/pool — the same
-- three arguments 'publishRates' takes in production.
publish :: AppEnv -> RateProvider -> IO (Either Text ())
publish env prov = publishRates prov env.eventStoreWriter env.eventStoreReader env.dbPool

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
      env <- createTestAppEnv
      let prov = fixedRateProvider "ecb" sampleRates
      result <- publish env prov
      result `shouldBe` Right ()
      let streamId = providerStreamId "ecb"
      count <- streamEventCount env.eventStoreReader streamId
      count `shouldBe` 1
      persisted <- singleStreamEvent env.eventStoreReader streamId
      case persisted.payload of
        ExchangeRatesPublishedEvent published -> do
          published.provider `shouldBe` "ecb"
          published.rates `shouldBe` sampleRates
        other ->
          expectationFailure
            $ "Expected ExchangeRatesPublishedEvent, got: "
            <> show other

    it "stamps the persisted event's at field to today (UTC)" $ do
      env <- createTestAppEnv
      today <- utctDay <$> getCurrentTime
      let prov = fixedRateProvider "ecb" sampleRates
      _ <- publish env prov
      persisted <- singleStreamEvent env.eventStoreReader (providerStreamId "ecb")
      case persisted.payload of
        ExchangeRatesPublishedEvent published -> published.at `shouldBe` today
        other ->
          expectationFailure
            $ "Expected ExchangeRatesPublishedEvent, got: "
            <> show other

    it "is idempotent for the same day — second call returns Left and does not re-append" $ do
      env <- createTestAppEnv
      let prov = fixedRateProvider "ecb" sampleRates
      firstResult <- publish env prov
      firstResult `shouldBe` Right ()
      -- The @exchange_rates@ table was updated synchronously in the append
      -- transaction when the first publish succeeded; no manual prime.
      secondResult <- publish env prov
      secondResult `shouldSatisfy` isLeft
      count <- streamEventCount env.eventStoreReader (providerStreamId "ecb")
      count `shouldBe` 1

    it "propagates provider failures and writes nothing" $ do
      env <- createTestAppEnv
      let prov = failingRateProvider "ecb" "boom"
      result <- publish env prov
      result `shouldBe` Left "boom"
      count <- streamEventCount env.eventStoreReader (providerStreamId "ecb")
      count `shouldBe` 0

  describe "providerStreamId" $ do
    it "is deterministic for the same provider name"
      $ providerStreamId "ecb"
      `shouldBe` providerStreamId "ecb"

    it "produces distinct UUIDs for distinct provider names"
      $ providerStreamId "ecb"
      `shouldNotBe` providerStreamId "nbu"
