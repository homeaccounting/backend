{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.StoreIntegrationSpec (spec) where

import Data.Time (getCurrentTime, utctDay)
import Domain.Core.Types (Currency (..), exchangeRateValue)
import Infrastructure.ExchangeRate.Provider
  ( ExchangeRateMap,
    RateProvider (..),
    deriveCrossRates,
  )
import Infrastructure.ExchangeRate.Store
  ( lookupHistoricalRate,
    newExchangeRateStore,
    publishRates,
  )
import RIO
import qualified RIO.Map as Map
import Test.Hspec

-- | Mock provider returning fixed rates.
mockProvider :: ExchangeRateMap -> RateProvider
mockProvider rates =
  RateProvider
    { providerName = "Mock",
      fetchRates = pure (Right rates)
    }

-- | Mock provider that always fails.
failingProvider :: RateProvider
failingProvider =
  RateProvider
    { providerName = "Failing",
      fetchRates = pure (Left "Failing: intentional error")
    }

-- | Sample rate map: EUR-based with USD and GBP.
sampleRates :: ExchangeRateMap
sampleRates = deriveCrossRates EUR (Map.fromList [(USD, 1.1), (GBP, 0.85)])

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.Store" $ do
  describe "lookupHistoricalRate" $ do
    it "returns rate after publish" $ do
      store <- newExchangeRateStore (mockProvider sampleRates)
      void $ publishRates store
      today <- utctDay <$> getCurrentTime
      result <- lookupHistoricalRate store today EUR USD
      case result of
        Just er -> exchangeRateValue er `shouldSatisfy` (> 0)
        Nothing -> expectationFailure "Expected Just, got Nothing"

    it "returns Nothing for same currency" $ do
      store <- newExchangeRateStore (mockProvider sampleRates)
      void $ publishRates store
      today <- utctDay <$> getCurrentTime
      result <- lookupHistoricalRate store today EUR EUR
      result `shouldSatisfy` isNothing

    it "returns Nothing when provider fails and store is empty" $ do
      store <- newExchangeRateStore failingProvider
      void $ publishRates store
      today <- utctDay <$> getCurrentTime
      result <- lookupHistoricalRate store today EUR USD
      result `shouldSatisfy` isNothing

  describe "publishRates" $ do
    it "returns Right on success" $ do
      store <- newExchangeRateStore (mockProvider sampleRates)
      result <- publishRates store
      result `shouldSatisfy` isRight

    it "returns Left on provider failure" $ do
      store <- newExchangeRateStore failingProvider
      result <- publishRates store
      result `shouldSatisfy` isLeft

    it "returns Left when rates already published for today" $ do
      store <- newExchangeRateStore (mockProvider sampleRates)
      void $ publishRates store
      result <- publishRates store
      result `shouldSatisfy` isLeft
