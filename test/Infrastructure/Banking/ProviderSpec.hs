{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.ProviderSpec (spec) where

import Infrastructure.Banking.Provider
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Banking.Provider" $ do
  describe "TransactionClassification" $ do
    it "shows ClassifiedIncome Nothing"
      $ show (ClassifiedIncome Nothing)
      `shouldBe` "ClassifiedIncome Nothing"

    it "shows ClassifiedExpense Nothing"
      $ show (ClassifiedExpense Nothing)
      `shouldBe` "ClassifiedExpense Nothing"
