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
--   1. Runs 'publishRates' once against the SQLite-backed test env, whose
--      writer projects the persistent @exchange_rates@ read model in the
--      append transaction.
--   2. Wipes the read-model table ('resetExchangeRate') — simulating a fresh
--      process whose read model starts empty — and confirms the lookup misses.
--   3. Replays every persisted event through 'applyExchangeRateEvent' (the
--      mechanism @Main.hs@ uses at startup via 'catchUpReadModel').
--   4. Asserts 'lookupHistoricalRate' again returns the originally published
--      rate: the event store is the source of truth.
module Integration.ExchangeRatePersistenceSpec (spec) where

import Application.ReadModels.ExchangeRate
  ( applyExchangeRateEvent,
    lookupHistoricalRate,
    resetExchangeRate,
  )
import Application.Services.ExchangeRatePublisher
  ( providerStreamId,
    publishRates,
  )
import Data.Time (getCurrentTime, utctDay)
import Domain.Core.Types (Currency (..), exchangeRateValue)
import Domain.ExchangeRate.Events (ExchangeRateMap, Provider)
import Eventium (EventStoreReader (..), allEvents)
import Infrastructure.App (AppEnv (..))
import Infrastructure.ExchangeRate.Provider (RateProvider (..))
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (mockExchangeRate)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

-- -----------------------------------------------------------------------------
-- Provider stub
-- -----------------------------------------------------------------------------

fixedRateProvider :: Provider -> ExchangeRateMap -> RateProvider
fixedRateProvider name rates =
  RateProvider
    { providerName = name,
      fetchRates = pure (Right rates)
    }

-- | Publish @prov@'s rates through the env's writer/reader/pool.
publish :: AppEnv -> RateProvider -> IO (Either Text ())
publish env prov = publishRates prov env.eventStoreWriter env.eventStoreReader env.dbPool

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration.ExchangeRatePersistence" $ do
  it "restores a wiped read model by replaying persisted events" $ do
    env <- createTestAppEnv
    today <- utctDay <$> getCurrentTime

    -- 1. Publish rates. The writer projects the @exchange_rates@ table
    -- synchronously in the append transaction.
    let published = mockExchangeRate USD UAH 41
        rates = Map.singleton (USD, UAH) published
        prov = fixedRateProvider "ecb" rates
    result <- publish env prov
    result `shouldBe` Right ()

    live <- runDbIn env (lookupHistoricalRate "ecb" today USD UAH)
    (exchangeRateValue <$> live) `shouldBe` Just (exchangeRateValue published)

    -- 2. Simulate a fresh process whose read model is empty.
    runDbIn env resetExchangeRate
    wiped <- runDbIn env (lookupHistoricalRate "ecb" today USD UAH)
    wiped `shouldBe` Nothing

    -- 3. Replay from the global stream (as Main.hs does at startup).
    let EventStoreReader readGlobal = env.globalEventStoreReader
    globalEvents <- readGlobal (allEvents ())
    runDbIn env (mapM_ applyExchangeRateEvent globalEvents)

    -- 4. The rebuilt read model resolves the originally published rate.
    restored <- runDbIn env (lookupHistoricalRate "ecb" today USD UAH)
    (exchangeRateValue <$> restored) `shouldBe` Just (exchangeRateValue published)

  it "persists exactly one event on the provider's stream" $ do
    env <- createTestAppEnv
    let prov = fixedRateProvider "ecb" (Map.singleton (USD, UAH) (mockExchangeRate USD UAH 41))
    _ <- publish env prov
    let EventStoreReader readStream = env.eventStoreReader
    persisted <- readStream (allEvents (providerStreamId "ecb"))
    length persisted `shouldBe` 1
