{-# LANGUAGE OverloadedStrings #-}

module Domain.Localization.AccountCatalogSpec (spec) where

import Data.Text (Text)
import Domain.Localization.AccountCatalog (localizedAccountLabel)
import Domain.Localization.Language (Language (..))
import Test.Hspec

-- | Every slug 'Domain.Account.Naming' looks up: subtype kinds, then asset types.
slugs :: [Text]
slugs =
  [ "cash",
    "bankAccount",
    "eWallet",
    "asset",
    "loan",
    "property",
    "vehicle",
    "stocks",
    "retirementFund",
    "electronics",
    "equipment",
    "furniture"
  ]

spec :: Spec
spec = describe "localizedAccountLabel" $ do
  it "returns the English display name for En, keyed by slug" $
    localizedAccountLabel En "bankAccount" `shouldBe` "Bank account"

  it "translates a known slug for Uk" $
    localizedAccountLabel Uk "bankAccount" `shouldBe` "Банківський рахунок"

  it "falls back to the slug for an unknown key" $
    localizedAccountLabel Uk "nonexistent" `shouldBe` "nonexistent"

  it "has an En and a Uk name for every slug (completeness)" $ do
    let untranslated lang = [s | s <- slugs, localizedAccountLabel lang s == s]
    untranslated En `shouldBe` []
    untranslated Uk `shouldBe` []
