{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRateIntegrationSpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateSource, exchangeRateTarget, exchangeRateValue)
import Infrastructure.ExchangeRate.ECB (fetchEcbRates)
import Infrastructure.ExchangeRate.Provider (getRate)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.ExchangeRate" $ do
  describe "fetchEcbRates" $ do
    it "fetches rates from ECB and contains USD" $ do
      result <- fetchEcbRates
      case result of
        Left err -> pendingWith $ "ECB unavailable: " <> show err
        Right rates -> do
          let usdRate = getRate rates EUR USD
          usdRate `shouldSatisfy` isJust

    it "derives cross-rate GBP/USD" $ do
      result <- fetchEcbRates
      case result of
        Left err -> pendingWith $ "ECB unavailable: " <> show err
        Right rates -> do
          let rate = getRate rates GBP USD
          rate `shouldSatisfy` isJust
          case rate of
            Just er -> do
              exchangeRateSource er `shouldBe` GBP
              exchangeRateTarget er `shouldBe` USD
              exchangeRateValue er `shouldSatisfy` (> 0)
            Nothing -> pure ()
