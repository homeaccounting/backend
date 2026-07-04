{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.TypesSpec
-- Description : Unit tests for Web.Types conversion functions.
--
-- Covers the behaviour introduced with allocation comments:
--
--   @CategoryAmount.comment@ is optional in JSON (absent → 'Nothing',
--   present → 'Just').
--
-- End-to-end echo behaviour (allocations carry the comment through to the
-- response) is covered by 'Web.API.TransactionAllocationsAPISpec'.
module Web.TypesSpec (spec) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import RIO
import Test.Hspec
import Web.Types
  ( CategoryAmount (..),
  )

spec :: Spec
spec = do
  describe "CategoryAmount JSON" $ do
    it "decodes without comment field (backward-compatible)" $ do
      let json :: LBS.ByteString
          json = "{\"category\":\"00000001-0000-0000-0000-000000000000\",\"amount\":42.5}"
      case Aeson.eitherDecode json :: Either String CategoryAmount of
        Left err -> expectationFailure $ "decode failed: " <> err
        Right ca -> ca.comment `shouldBe` Nothing

    it "decodes with comment field present" $ do
      let json :: LBS.ByteString
          json =
            "{\"category\":\"00000001-0000-0000-0000-000000000000\""
              <> ",\"amount\":42.5"
              <> ",\"comment\":\"flowers\"}"
      case Aeson.eitherDecode json :: Either String CategoryAmount of
        Left err -> expectationFailure $ "decode failed: " <> err
        Right ca -> ca.comment `shouldBe` Just "flowers"
