{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.ProviderSpec (spec) where

import Infrastructure.Banking.Provider
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Banking.Provider" $ do
  describe "TransactionClassification" $ do
    it "shows ClassifiedIncome"
      $ show ClassifiedIncome
      `shouldBe` "ClassifiedIncome"

    it "shows ClassifiedExpense"
      $ show ClassifiedExpense
      `shouldBe` "ClassifiedExpense"
