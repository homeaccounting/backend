{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.PersistentExchangeRateReadModelSpec
-- Description : Guarantees of the persistent, indexed exchange-rate read model.
--
-- Exercises the @exchange_rates@ projection, seeding synthesized events through
-- the read model's own 'applyExchangeRateEvent' (no test-only insertion hole):
--
--   * __Exact-date lookup__ — a published pair resolves on its business day.
--   * __Nearest-date fallback__ — a query day with no exact match falls back to
--     the nearest published day (earlier wins ties).
--   * __Per-provider isolation__ — one provider's rates never answer another's.
--   * __Same-currency__ — @source == target@ resolves to 'Nothing'.
--   * __Idempotency / republish__ — re-applying an event stream, or republishing
--     a day, leaves the day's rates as the last published set.
module Application.ReadModels.PersistentExchangeRateReadModelSpec (spec) where

import Application.ReadModels.ExchangeRate
  ( applyExchangeRateEvent,
    lookupHistoricalRate,
  )
import Data.Time (Day, fromGregorian)
import qualified Data.UUID as UUID
import Domain.Core.Types (Currency (..))
import Domain.ExchangeRate.Events (ExchangeRateMap, ExchangeRatesPublished (..), Provider)
import Domain.Models (AccountingEvent (..))
import qualified Eventium
import Infrastructure.App (AppEnv)
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (globalEvent, mockExchangeRate)
import Testkit.InMemoryEventStore (runDbIn, seedGlobals)

-- | A published-rates global event on an arbitrary stream (the projection keys
-- off the payload's @provider@, not the stream id). The business date is
-- carried on 'ExchangeRatesPublished.at'.
published ::
  Day ->
  Provider ->
  ExchangeRateMap ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
published day provider rates =
  globalEvent
    UUID.nil
    0
    ( ExchangeRatesPublishedEvent
        ExchangeRatesPublished
          { provider = provider,
            rates = rates,
            at = day
          }
    )

usdToUah :: Rational -> ExchangeRateMap
usdToUah r = Map.singleton (USD, UAH) (mockExchangeRate USD UAH r)

seedEnv :: [Eventium.GlobalStreamEvent AccountingEvent] -> IO AppEnv
seedEnv = seedGlobals applyExchangeRateEvent

spec :: Spec
spec = describe "Persistent ExchangeRate read model" $ do
  it "returns Nothing when the read model is empty" $ do
    env <- seedEnv []
    result <- runDbIn env (lookupHistoricalRate "ecb" (fromGregorian 2026 4 20) USD UAH)
    result `shouldBe` Nothing

  it "returns the exact-date rate after a single published event" $ do
    let day = fromGregorian 2026 4 20
        rate = mockExchangeRate USD UAH 41
    env <- seedEnv [published day "ecb" (Map.singleton (USD, UAH) rate) 0]
    result <- runDbIn env (lookupHistoricalRate "ecb" day USD UAH)
    result `shouldBe` Just rate

  it "isolates rate history per provider" $ do
    let day = fromGregorian 2026 4 20
    env <- seedEnv [published day "ecb" (usdToUah 41) 0]
    result <- runDbIn env (lookupHistoricalRate "nbu" day USD UAH)
    result `shouldBe` Nothing

  it "returns Nothing when source == target" $ do
    let day = fromGregorian 2026 4 20
    env <- seedEnv [published day "ecb" (usdToUah 41) 0]
    result <- runDbIn env (lookupHistoricalRate "ecb" day USD USD)
    result `shouldBe` Nothing

  it "falls back to the nearest earlier date when queried later" $ do
    let day1 = fromGregorian 2026 4 15
        day2 = fromGregorian 2026 4 18
        queryDay = fromGregorian 2026 4 20
        rate2 = mockExchangeRate USD UAH 41
    env <-
      seedEnv
        [ published day1 "ecb" (usdToUah 40) 0,
          published day2 "ecb" (Map.singleton (USD, UAH) rate2) 1
        ]
    result <- runDbIn env (lookupHistoricalRate "ecb" queryDay USD UAH)
    result `shouldBe` Just rate2

  it "re-applying the same stream leaves the same rate (idempotent)" $ do
    let day = fromGregorian 2026 4 20
        rate = mockExchangeRate USD UAH 41
        events = [published day "ecb" (Map.singleton (USD, UAH) rate) 0]
    env <- seedEnv (events <> events)
    result <- runDbIn env (lookupHistoricalRate "ecb" day USD UAH)
    result `shouldBe` Just rate

  it "republishing a day replaces that day's rates" $ do
    let day = fromGregorian 2026 4 20
        newRate = mockExchangeRate USD UAH 42
    env <-
      seedEnv
        [ published day "ecb" (usdToUah 41) 0,
          published day "ecb" (Map.singleton (USD, UAH) newRate) 1
        ]
    result <- runDbIn env (lookupHistoricalRate "ecb" day USD UAH)
    result `shouldBe` Just newRate
