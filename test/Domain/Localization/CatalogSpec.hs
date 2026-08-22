{-# LANGUAGE OverloadedStrings #-}

module Domain.Localization.CatalogSpec (spec) where

import Domain.Localization.Catalog (resolve)
import Domain.Localization.Language (Language (..))
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Catalog.resolve" $ do
  let base k = "base:" <> k
      overrides Uk "hit" = Just "uk-hit"
      overrides _ _ = Nothing
      r = resolve overrides base

  it "returns the locale override when present" $
    r Uk "hit" `shouldBe` "uk-hit"

  it "falls back to the English base when the locale has no override" $
    r Uk "miss" `shouldBe` "base:miss"

  it "always uses the base for English (identity locale)" $
    r En "hit" `shouldBe` "base:hit"
