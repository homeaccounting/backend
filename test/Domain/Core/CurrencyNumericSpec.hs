{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Core.CurrencyNumericSpec (spec) where

import Domain.Core.Types
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators ()

spec :: Spec
spec = describe "Currency Numeric Codes" $ do
  describe "currencyNumericCode" $ do
    it "returns 980 for UAH"
      $ currencyNumericCode UAH
      `shouldBe` 980
    it "returns 840 for USD"
      $ currencyNumericCode USD
      `shouldBe` 840
    it "returns 978 for EUR"
      $ currencyNumericCode EUR
      `shouldBe` 978
    it "returns 826 for GBP"
      $ currencyNumericCode GBP
      `shouldBe` 826

  describe "currencyFromNumericCode" $ do
    it "parses 980 to UAH"
      $ currencyFromNumericCode 980
      `shouldBe` Right UAH
    it "parses 840 to USD"
      $ currencyFromNumericCode 840
      `shouldBe` Right USD
    it "rejects unknown code"
      $ currencyFromNumericCode 999
      `shouldSatisfy` isLeft

  describe "roundtrip property"
    $ it "fromNumericCode . numericCode == Right for all currencies"
    $ property
    $ \c ->
      currencyFromNumericCode (currencyNumericCode c) === Right c
