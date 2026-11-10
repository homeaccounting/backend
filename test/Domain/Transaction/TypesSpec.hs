{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.TypesSpec
-- Description : Unit tests for Domain.Transaction.Types
module Domain.Transaction.TypesSpec (spec) where

import qualified Data.Aeson as Aeson
import Domain.Transaction.Types
import RIO
import Test.Hspec

spec :: Spec
spec = describe "TransactionType JSON" $ do
  it "round-trips Adjustment via Aeson Generic encoding" $ do
    let encoded = Aeson.encode Adjustment
    Aeson.decode encoded `shouldBe` Just Adjustment
  it "encodes Adjustment with a tag-only object (no category)"
    $ Aeson.encode Adjustment
    `shouldBe` "{\"tag\":\"Adjustment\"}"
