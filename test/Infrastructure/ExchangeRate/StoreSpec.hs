{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.StoreSpec (spec) where

import Data.Time (fromGregorian)
import Domain.Core.Types (Currency (..), exchangeRateValue, unsafeExchangeRate)
import Infrastructure.ExchangeRate.Provider
  ( ExchangeRateMap,
    RateProvider (..),
  )
import Infrastructure.ExchangeRate.Store
  ( ExchangeRateEvent (..),
    lookupHistoricalRate,
    newExchangeRateStore,
    publishRates,
    replayRateEvents,
  )
import RIO
import qualified RIO.Map as Map
import Test.Hspec

-- | Dummy provider that never fetches (used only for store creation).
dummyProvider :: RateProvider
dummyProvider =
  RateProvider
    { providerName = "Dummy",
      fetchRates = pure (Left "Dummy: not implemented")
    }

-- | Build a simple rate map for testing.
mkTestRateMap :: Rational -> ExchangeRateMap
mkTestRateMap rate =
  Map.fromList
    [ ((USD, EUR), unsafeExchangeRate USD EUR rate),
      ((EUR, USD), unsafeExchangeRate EUR USD (1 / rate))
    ]

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.Store" $ do
  describe "lookupHistoricalRate" $ do
    it "returns exact date match" $ do
      store <- newExchangeRateStore dummyProvider
      let day = fromGregorian 2025 6 15
          rates = mkTestRateMap 0.9
          event = ExchangeRatesPublished day "Test" rates
      replayRateEvents store [event]
      result <- lookupHistoricalRate store day USD EUR
      case result of
        Just er -> exchangeRateValue er `shouldBe` 0.9
        Nothing -> expectationFailure "Expected Just, got Nothing"

    it "falls back to nearest earlier date" $ do
      store <- newExchangeRateStore dummyProvider
      let day1 = fromGregorian 2025 6 10
          day2 = fromGregorian 2025 6 20
          events =
            [ ExchangeRatesPublished day1 "Test" (mkTestRateMap 0.85),
              ExchangeRatesPublished day2 "Test" (mkTestRateMap 0.95)
            ]
      replayRateEvents store events
      -- Query for June 14: closer to June 10 (4 days) than June 20 (6 days)
      result <- lookupHistoricalRate store (fromGregorian 2025 6 14) USD EUR
      case result of
        Just er -> exchangeRateValue er `shouldBe` 0.85
        Nothing -> expectationFailure "Expected rate from earlier date"

    it "falls back to nearest later date when no earlier exists" $ do
      store <- newExchangeRateStore dummyProvider
      let day = fromGregorian 2025 6 15
          event = ExchangeRatesPublished day "Test" (mkTestRateMap 0.9)
      replayRateEvents store [event]
      -- Query for June 10: only June 15 available (later)
      result <- lookupHistoricalRate store (fromGregorian 2025 6 10) USD EUR
      case result of
        Just er -> exchangeRateValue er `shouldBe` 0.9
        Nothing -> expectationFailure "Expected rate from later date"

    it "returns Nothing for empty history" $ do
      store <- newExchangeRateStore dummyProvider
      result <- lookupHistoricalRate store (fromGregorian 2025 6 15) USD EUR
      result `shouldBe` Nothing

    it "returns Nothing for same-currency lookup" $ do
      store <- newExchangeRateStore dummyProvider
      let day = fromGregorian 2025 6 15
          event = ExchangeRatesPublished day "Test" (mkTestRateMap 0.9)
      replayRateEvents store [event]
      result <- lookupHistoricalRate store day USD USD
      result `shouldBe` Nothing

    it "returns Nothing for missing currency pair" $ do
      store <- newExchangeRateStore dummyProvider
      let day = fromGregorian 2025 6 15
          event = ExchangeRatesPublished day "Test" (mkTestRateMap 0.9)
      replayRateEvents store [event]
      -- UAH/GBP not in the test rate map
      result <- lookupHistoricalRate store day UAH GBP
      result `shouldBe` Nothing

  describe "replayRateEvents" $ do
    it "populates history from multiple events" $ do
      store <- newExchangeRateStore dummyProvider
      let events =
            [ ExchangeRatesPublished (fromGregorian 2025 6 10) "Test" (mkTestRateMap 0.85),
              ExchangeRatesPublished (fromGregorian 2025 6 11) "Test" (mkTestRateMap 0.86),
              ExchangeRatesPublished (fromGregorian 2025 6 12) "Test" (mkTestRateMap 0.87)
            ]
      replayRateEvents store events
      r1 <- lookupHistoricalRate store (fromGregorian 2025 6 10) USD EUR
      r2 <- lookupHistoricalRate store (fromGregorian 2025 6 12) USD EUR
      fmap exchangeRateValue r1 `shouldBe` Just 0.85
      fmap exchangeRateValue r2 `shouldBe` Just 0.87

    it "later event for same date overwrites earlier" $ do
      store <- newExchangeRateStore dummyProvider
      let day = fromGregorian 2025 6 15
          events =
            [ ExchangeRatesPublished day "Test" (mkTestRateMap 0.85),
              ExchangeRatesPublished day "Test" (mkTestRateMap 0.95)
            ]
      replayRateEvents store events
      result <- lookupHistoricalRate store day USD EUR
      fmap exchangeRateValue result `shouldBe` Just 0.95

  describe "publishRates" $ do
    it "returns Left when provider fails" $ do
      store <- newExchangeRateStore dummyProvider
      result <- publishRates store
      result `shouldSatisfy` isLeft
