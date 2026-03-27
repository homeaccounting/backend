{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.CacheSpec (spec) where

import Data.Text (isInfixOf)
import Domain.Core.Types (Currency (..), exchangeRateValue)
import Infrastructure.ExchangeRate.Provider
  ( ExchangeRateMap,
    RateProvider (..),
    deriveCrossRates,
    getCachedRate,
    newExchangeRateCache,
    refreshCache,
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
spec = describe "Infrastructure.ExchangeRate.Provider (cache)" $ do
  describe "getCachedRate" $ do
    it "returns rate after refresh" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      void $ refreshCache cache
      result <- getCachedRate cache EUR USD
      case result of
        Right er -> exchangeRateValue er `shouldSatisfy` (> 0)
        Left err -> expectationFailure $ "Expected Right, got: " <> show err

    it "auto-refreshes on first call when cache is empty" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      -- No manual refresh — getCachedRate should trigger it
      result <- getCachedRate cache EUR USD
      case result of
        Right er -> exchangeRateValue er `shouldSatisfy` (> 0)
        Left err -> expectationFailure $ "Expected Right, got: " <> show err

    it "returns Left for same currency" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      result <- getCachedRate cache EUR EUR
      result `shouldSatisfy` isLeft

    it "returns Left when provider fails and cache is empty" $ do
      cache <- newExchangeRateCache failingProvider
      result <- getCachedRate cache EUR USD
      result `shouldSatisfy` isLeft

    it "includes provider name in error messages" $ do
      cache <- newExchangeRateCache failingProvider
      result <- getCachedRate cache EUR USD
      case result of
        Left err -> err `shouldSatisfy` ("Failing" `isInfixOf`)
        Right _ -> expectationFailure "Expected Left"

  describe "refreshCache" $ do
    it "returns Right on success" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      result <- refreshCache cache
      result `shouldBe` Right ()

    it "returns Left on provider failure" $ do
      cache <- newExchangeRateCache failingProvider
      result <- refreshCache cache
      result `shouldSatisfy` isLeft
