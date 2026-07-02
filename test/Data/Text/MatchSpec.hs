{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Text.MatchSpec (spec) where

import Data.Text.Match (MatchResult (..), matchByName, normalizeName)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Data.Text.Match" $ do
  describe "matchByName" $ do
    let cs = ["Cash", "Bank", "Card"] :: [Text]
    it "exact match (case/space-insensitive)"
      $ matchByName id "  cASH " cs
      `shouldBe` Matched "Cash"
    it "canonical name returned verbatim"
      $ matchByName id "Cash" cs
      `shouldBe` Matched "Cash"
    it "unambiguous substring match"
      $ matchByName id "ban" cs
      `shouldBe` Matched "Bank"
    it "no match"
      $ matchByName id "wallet" cs
      `shouldBe` (NoMatch :: MatchResult Text)
    it "ambiguous exact duplicates"
      $ matchByName id "cash" (["Cash", "cash"] :: [Text])
      `shouldBe` Ambiguous ["Cash", "cash"]
    it "ambiguous substring"
      $ matchByName id "car" (["Card", "Carwash"] :: [Text])
      `shouldBe` Ambiguous ["Card", "Carwash"]
    it "empty query is NoMatch"
      $ matchByName id "" cs
      `shouldBe` (NoMatch :: MatchResult Text)
    it "exact match beats a longer substring candidate"
      $ matchByName id "Car" (["Car", "Card"] :: [Text])
      `shouldBe` Matched "Car"
    it "blank/whitespace query is NoMatch even with a blank candidate"
      $ matchByName id "   " (["   "] :: [Text])
      `shouldBe` (NoMatch :: MatchResult Text)
  describe "normalizeName"
    $ it "casefolds, trims, collapses whitespace"
    $ normalizeName "  Foo   Bar "
    `shouldBe` "foo bar"
