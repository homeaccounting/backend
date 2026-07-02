{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.PageSpec
-- Description : Validation tests for offset/limit pagination.
module Domain.Core.PageSpec (spec) where

import Domain.Core.Page (Page (..), defaultLimit, maxLimit, mkPage)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "mkPage" $ do
  it "absent params -> defaultLimit / offset 0"
    $ mkPage Nothing Nothing
    `shouldBe` Right (Page defaultLimit 0)

  it "accepts in-range values"
    $ mkPage (Just 25) (Just 100)
    `shouldBe` Right (Page 25 100)

  it "accepts limit == maxLimit"
    $ mkPage (Just maxLimit) Nothing
    `shouldBe` Right (Page maxLimit 0)

  it "rejects limit == 0"
    $ mkPage (Just 0) Nothing
    `shouldSatisfy` isLeft

  it "rejects limit > maxLimit"
    $ mkPage (Just (maxLimit + 1)) Nothing
    `shouldSatisfy` isLeft

  it "rejects negative offset"
    $ mkPage Nothing (Just (-1))
    `shouldSatisfy` isLeft
