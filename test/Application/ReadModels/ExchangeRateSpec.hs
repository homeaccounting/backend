{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.ExchangeRateSpec
-- Description : Failing (red) unit tests for the exchange-rate read model.
--
-- These tests describe the behaviour of
-- @Application.ReadModels.ExchangeRate@ before it is implemented. The
-- module does not yet exist, so this spec intentionally fails at the
-- import / compile step — that is the success condition for Task 3 of
-- the persistable-exchange-rates plan.
--
-- Seeding mirrors production: we synthesize
-- @GlobalStreamEvent AccountingEvent@ values (the same type
-- 'handleAccountEvents' receives) and feed them to the read model's
-- own handler. This keeps the test path identical to what the event
-- bus will deliver at runtime.
module Application.ReadModels.ExchangeRateSpec (spec) where

import Application.ReadModels.ExchangeRate
  ( createExchangeRateReadModel,
    handleExchangeRateEvents,
    lookupHistoricalRate,
  )
import Data.Time (Day, UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types (Currency (..))
import Domain.ExchangeRate.Events (ExchangeRateMap, ExchangeRatesPublished (..), Provider)
import Domain.Models (AccountingEvent (..))
import Eventium (StreamEvent (..), emptyMetadata)
import qualified Eventium
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (mockExchangeRate)

-- | Shape identical to mkInitiatedEvent in TransactionListSpec: the
-- GlobalStreamEvent is a StreamEvent () SequenceNumber (VersionedStreamEvent)
-- where the inner VersionedStreamEvent = StreamEvent UUID EventVersion
-- AccountingEvent. The business date (the day the rates apply to) is
-- carried on the inner VersionedStreamEvent's metadata.occurredAt, per
-- the spec.
mkPublishedEvent ::
  Day ->
  Provider ->
  ExchangeRateMap ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
mkPublishedEvent day providerName rates seqNo =
  let businessAt = UTCTime day (secondsToDiffTime 0)
      payload =
        ExchangeRatesPublishedEvent
          ExchangeRatesPublished
            { provider = providerName,
              rates = rates
            }
      inner =
        StreamEvent
          UUID.nil
          0
          ((emptyMetadata "ExchangeRatesPublished") {Eventium.occurredAt = Just businessAt})
          payload
   in StreamEvent () seqNo (emptyMetadata "ExchangeRatesPublished") inner

-- | Like 'mkPublishedEvent' but omits the business-date metadata.
-- Used to prove the handler tolerates events with no occurredAt.
mkPublishedEventNoDate ::
  Provider ->
  ExchangeRateMap ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
mkPublishedEventNoDate providerName rates seqNo =
  let payload =
        ExchangeRatesPublishedEvent
          ExchangeRatesPublished
            { provider = providerName,
              rates = rates
            }
      inner =
        StreamEvent
          UUID.nil
          0
          (emptyMetadata "ExchangeRatesPublished")
          payload
   in StreamEvent () seqNo (emptyMetadata "ExchangeRatesPublished") inner

usdToUah :: Rational -> ExchangeRateMap
usdToUah r = Map.singleton (USD, UAH) (mockExchangeRate USD UAH r)

spec :: Spec
spec = describe "Application.ReadModels.ExchangeRate" $ do
  it "returns Nothing when the read model is empty" $ do
    rm <- createExchangeRateReadModel
    result <- lookupHistoricalRate rm "ecb" (fromGregorian 2026 4 20) USD UAH
    result `shouldBe` Nothing

  it "returns the exact-date rate after a single published event" $ do
    rm <- createExchangeRateReadModel
    let day = fromGregorian 2026 4 20
        rate = mockExchangeRate USD UAH 41
        rates = Map.singleton (USD, UAH) rate
    handleExchangeRateEvents rm [mkPublishedEvent day "ecb" rates 0]
    result <- lookupHistoricalRate rm "ecb" day USD UAH
    result `shouldBe` Just rate

  it "isolates rate history per provider" $ do
    rm <- createExchangeRateReadModel
    let day = fromGregorian 2026 4 20
    handleExchangeRateEvents rm [mkPublishedEvent day "ecb" (usdToUah 41) 0]
    resultNbu <- lookupHistoricalRate rm "nbu" day USD UAH
    resultNbu `shouldBe` Nothing

  it "falls back to the nearest earlier date when queried later" $ do
    rm <- createExchangeRateReadModel
    let day1 = fromGregorian 2026 4 15
        day2 = fromGregorian 2026 4 18
        queryDay = fromGregorian 2026 4 20
        rate2 = mockExchangeRate USD UAH 41
    handleExchangeRateEvents
      rm
      [ mkPublishedEvent day1 "ecb" (usdToUah 40) 0,
        mkPublishedEvent day2 "ecb" (Map.singleton (USD, UAH) rate2) 1
      ]
    result <- lookupHistoricalRate rm "ecb" queryDay USD UAH
    result `shouldBe` Just rate2

  it "skips events whose metadata has no occurredAt" $ do
    rm <- createExchangeRateReadModel
    let rates = usdToUah 41
    -- Handler must not throw, and the event must not populate history.
    handleExchangeRateEvents rm [mkPublishedEventNoDate "ecb" rates 0]
    result <- lookupHistoricalRate rm "ecb" (fromGregorian 2026 4 20) USD UAH
    result `shouldBe` Nothing
