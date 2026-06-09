{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.RangeSpec
-- Description : Unit + property tests for the reusable inclusive Range.
module Domain.Core.RangeSpec (spec) where

import Domain.Core.Range (Range (..), mkRange, within)
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

spec :: Spec
spec = do
  describe "mkRange" $ do
    it "both absent -> Right Nothing (no constraint)" $
      mkRange (Nothing :: Maybe Int) Nothing `shouldBe` Right Nothing

    it "only-from -> Right (Just ..)" $
      mkRange (Just (1 :: Int)) Nothing `shouldBe` Right (Just (Range (Just 1) Nothing))

    it "from == to accepted" $
      mkRange (Just (5 :: Int)) (Just 5) `shouldBe` Right (Just (Range (Just 5) (Just 5)))

    it "from > to rejected" $
      mkRange (Just (9 :: Int)) (Just 1) `shouldSatisfy` isLeft

  describe "within" $ do
    prop "matches the bound semantics" $ \(mf :: Maybe Int) mt x ->
      within (Range mf mt) x
        == (maybe True (<= x) mf && maybe True (x <=) mt)
