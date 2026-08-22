{-# LANGUAGE OverloadedStrings #-}

module Telegram.I18nCompletenessSpec (spec) where

import Control.Monad (forM_, when)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text, unpack)
import Telegram.I18n (enCatalogs, ukCatalogs)
import Test.Hspec

spec :: Spec
spec = describe "Telegram.I18n locale catalogs" $ do
  it "loads a non-empty English catalog for every namespace" $
    forM_ enCatalogs $ \(ns, m) ->
      when (Map.null m) $
        expectationFailure ("English catalog for namespace is empty: " <> unpack ns)

  it "keeps the Ukrainian key set identical to English for every namespace" $
    forM_ enCatalogs $ \(ns, enMap) ->
      case lookup ns ukCatalogs of
        Nothing -> expectationFailure ("Missing Ukrainian namespace: " <> unpack ns)
        Just ukMap -> assertSameKeys ns (keysOf enMap) (keysOf ukMap)

  it "has no extra Ukrainian namespaces beyond English" $
    sort (map fst ukCatalogs) `shouldBe` sort (map fst enCatalogs)
  where
    keysOf :: Map.Map Text Text -> [Text]
    keysOf = sort . Map.keys

    -- Compare key sets, tagging any mismatch with the namespace for a readable failure.
    assertSameKeys :: Text -> [Text] -> [Text] -> Expectation
    assertSameKeys ns expected actual =
      when (actual /= expected) $
        expectationFailure $
          "Key-set mismatch in namespace "
            <> unpack ns
            <> ".\n  only in Ukrainian: "
            <> show [k | k <- actual, k `notElem` expected]
            <> "\n  missing from Ukrainian: "
            <> show [k | k <- expected, k `notElem` actual]
