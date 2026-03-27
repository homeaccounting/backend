{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.NBUSpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateValue)
import Infrastructure.ExchangeRate.NBU (parseNbuResponse)
import Infrastructure.ExchangeRate.Provider (getRate)
import RIO
import Test.Hspec

sampleJson :: LByteString
sampleJson =
  "[{\"r030\":840,\"txt\":\"Dollar\",\"rate\":41.2345,\"cc\":\"USD\",\"exchangedate\":\"18.03.2026\"}"
    <> ",{\"r030\":978,\"txt\":\"Euro\",\"rate\":44.5678,\"cc\":\"EUR\",\"exchangedate\":\"18.03.2026\"}"
    <> ",{\"r030\":826,\"txt\":\"Pound\",\"rate\":52.1234,\"cc\":\"GBP\",\"exchangedate\":\"18.03.2026\"}]"

-- | JSON with missing required 'rate' field — aeson will fail to parse the entire array.
missingRateJson :: LByteString
missingRateJson = "[{\"r030\":840,\"txt\":\"USD\",\"cc\":\"USD\"}]"

partialJson :: LByteString
partialJson =
  "[{\"r030\":840,\"txt\":\"Dollar\",\"rate\":41.2345,\"cc\":\"USD\",\"exchangedate\":\"18.03.2026\"}"
    <> ",{\"r030\":978,\"txt\":\"Euro\",\"rate\":44.5678,\"cc\":\"EUR\",\"exchangedate\":\"18.03.2026\"}]"

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.NBU" $ do
  describe "parseNbuResponse" $ do
    it "parses valid JSON with all supported currencies" $ do
      let result = parseNbuResponse sampleJson
      case result of
        Left err -> expectationFailure $ "Parse failed: " <> show err
        Right rates -> do
          getRate rates USD EUR `shouldSatisfy` isJust
          getRate rates EUR USD `shouldSatisfy` isJust
          getRate rates GBP UAH `shouldSatisfy` isJust
          getRate rates UAH GBP `shouldSatisfy` isJust

    it "returns Left when JSON entry is missing required 'rate' field" $ do
      let result = parseNbuResponse missingRateJson
      result `shouldSatisfy` isLeft

    it "produces partial map when GBP is missing" $ do
      let result = parseNbuResponse partialJson
      case result of
        Left err -> expectationFailure $ "Parse failed: " <> show err
        Right rates -> do
          getRate rates USD EUR `shouldSatisfy` isJust
          getRate rates UAH USD `shouldSatisfy` isJust
          getRate rates GBP USD `shouldBe` Nothing
          getRate rates GBP EUR `shouldBe` Nothing

    it "rate values are positive" $ do
      let result = parseNbuResponse sampleJson
      case result of
        Left err -> expectationFailure $ "Parse failed: " <> show err
        Right rates -> do
          case getRate rates USD UAH of
            Just er -> exchangeRateValue er `shouldSatisfy` (> 0)
            Nothing -> expectationFailure "Expected USD/UAH rate"
