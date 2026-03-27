{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.NBUIntegrationSpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateSource, exchangeRateTarget, exchangeRateValue)
import Infrastructure.ExchangeRate.NBU (nbuProvider)
import Infrastructure.ExchangeRate.Provider (RateProvider (..), getRate)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.NBU (integration)" $ do
  describe "fetchRates" $ do
    it "fetches rates from NBU and contains USD" $ do
      result <- nbuProvider.fetchRates
      case result of
        Left err -> pendingWith $ "NBU unavailable: " <> show err
        Right rates -> do
          let usdRate = getRate rates UAH USD
          usdRate `shouldSatisfy` isJust

    it "derives cross-rate EUR/USD" $ do
      result <- nbuProvider.fetchRates
      case result of
        Left err -> pendingWith $ "NBU unavailable: " <> show err
        Right rates -> do
          let rate = getRate rates EUR USD
          rate `shouldSatisfy` isJust
          case rate of
            Just er -> do
              exchangeRateSource er `shouldBe` EUR
              exchangeRateTarget er `shouldBe` USD
              exchangeRateValue er `shouldSatisfy` (> 0)
            Nothing -> pure ()
