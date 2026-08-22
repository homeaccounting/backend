{-# LANGUAGE OverloadedStrings #-}

module Domain.Localization.PluralSpec (spec) where

import qualified Data.Map.Strict as Map
import Domain.Localization.Language (Language (..))
import Domain.Localization.Plural (PluralCategory (..), pluralCategory, selectPluralTemplate)
import Test.Hspec

spec :: Spec
spec = do
  describe "pluralCategory En" $ do
    it "is One only for exactly 1" $
      pluralCategory En 1 `shouldBe` One
    it "is Other for 0 and everything above 1" $
      map (pluralCategory En) [0, 2, 5, 11, 21, 100] `shouldBe` replicate 6 Other

  describe "pluralCategory Uk (CLDR integer rules)" $ do
    it "One: n mod 10 == 1 and n mod 100 /= 11" $
      map (pluralCategory Uk) [1, 21, 31, 101] `shouldBe` replicate 4 One
    it "Few: n mod 10 in 2..4 and n mod 100 not in 12..14" $
      map (pluralCategory Uk) [2, 3, 4, 22, 23, 24, 104] `shouldBe` replicate 7 Few
    it "Many: 0, the 5..9 tail, and the 11..14 teens" $
      map (pluralCategory Uk) [0, 5, 9, 10, 11, 12, 13, 14, 25, 100] `shouldBe` replicate 10 Many

  describe "selectPluralTemplate" $ do
    let m =
          Map.fromList
            [ ("items_one", "{count} товар"),
              ("items_few", "{count} товари"),
              ("items_many", "{count} товарів"),
              ("bare", "plain")
            ]
    it "picks the category-specific key for the count/locale" $ do
      selectPluralTemplate Uk 1 m "items" `shouldBe` Just "{count} товар"
      selectPluralTemplate Uk 3 m "items" `shouldBe` Just "{count} товари"
      selectPluralTemplate Uk 5 m "items" `shouldBe` Just "{count} товарів"
      selectPluralTemplate Uk 11 m "items" `shouldBe` Just "{count} товарів"

    it "falls back to the bare key when a string is not pluralized" $
      selectPluralTemplate Uk 5 m "bare" `shouldBe` Just "plain"

    it "returns Nothing when neither a plural nor a bare key exists" $
      selectPluralTemplate Uk 5 m "missing" `shouldBe` Nothing
