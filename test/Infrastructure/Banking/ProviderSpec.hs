{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.ProviderSpec (spec) where

import qualified Data.Set as Set
import Domain.Localization.Country (unsafeCountry)
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

  describe "providerInCountry" $ do
    let ua = unsafeCountry "UA"
        pl = unsafeCountry "PL"
        us = unsafeCountry "US"
        regionalUA = RegionalCoverage (Set.singleton ua)
        regionalUAPL = RegionalCoverage (Set.fromList [ua, pl])

    it "global coverage is in-country for any set country"
      $ providerInCountry (Just us) GlobalCoverage
      `shouldBe` True

    it "global coverage is in-country when country is unset"
      $ providerInCountry Nothing GlobalCoverage
      `shouldBe` True

    it "regional matches a member country"
      $ providerInCountry (Just ua) regionalUA
      `shouldBe` True

    it "regional excludes a non-member country"
      $ providerInCountry (Just us) regionalUA
      `shouldBe` False

    it "regional shows everything when country is unset"
      $ providerInCountry Nothing regionalUA
      `shouldBe` True

    it "multi-country regional matches every member" $ do
      providerInCountry (Just ua) regionalUAPL `shouldBe` True
      providerInCountry (Just pl) regionalUAPL `shouldBe` True

    it "multi-country regional excludes a non-member"
      $ providerInCountry (Just us) regionalUAPL
      `shouldBe` False

  describe "coverageCountries" $ do
    it "global projects to the empty list"
      $ coverageCountries GlobalCoverage
      `shouldBe` []

    it "regional projects to sorted ISO codes"
      $ coverageCountries (RegionalCoverage (Set.fromList [unsafeCountry "UA", unsafeCountry "PL"]))
      `shouldBe` ["PL", "UA"]
