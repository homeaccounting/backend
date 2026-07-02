{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.StatusKindSpec
-- Description : Codec + totality tests for the StatusKind query discriminator.
module Domain.Transaction.StatusKindSpec (spec) where

import Domain.Transaction.Projection
  ( StatusKind (..),
    TransactionStatus (..),
    parseStatusKind,
    renderStatusKind,
    statusKind,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "statusKind" $ do
    it "maps every TransactionStatus to a payload-free kind" $ do
      statusKind Pending `shouldBe` PendingKind
      statusKind Completed `shouldBe` CompletedKind
      statusKind (Failed "boom") `shouldBe` FailedKind
      statusKind Cancelled `shouldBe` CancelledKind

  describe "parseStatusKind / renderStatusKind" $ do
    it "round-trips every kind"
      $ forM_ [minBound .. maxBound]
      $ \k ->
        parseStatusKind (renderStatusKind k) `shouldBe` Just k

    it "parses lowercase tokens"
      $ parseStatusKind "failed"
      `shouldBe` Just FailedKind

    it "trims and lowercases"
      $ parseStatusKind "  Cancelled "
      `shouldBe` Just CancelledKind

    it "rejects unknown tokens"
      $ parseStatusKind "bogus"
      `shouldBe` Nothing
