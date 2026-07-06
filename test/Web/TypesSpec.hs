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

import Data.Aeson (object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.UUID as UUID
import RIO
import Test.Hspec
import Web.Types
  ( CategoryAmount (..),
    IncomeRequest (..),
    TransactionRelation (..),
    TransactionRelationsResponse (..),
  )

spec :: Spec
spec = do
  describe "TransactionRelation JSON" $ do
    it "round-trips through encode/decode" $ do
      let r =
            TransactionRelation
              { relatedTransactionId = UUID.nil,
                relationKind = "refund"
              }
      Aeson.decode (Aeson.encode r) `shouldBe` Just r

    it "encodes the expected field shape" $ do
      let r =
            TransactionRelation
              { relatedTransactionId = UUID.nil,
                relationKind = "refund"
              }
      Aeson.eitherDecode (Aeson.encode r)
        `shouldBe` ( Right
                       ( object
                           [ "relatedTransactionId" .= UUID.nil,
                             "relationKind" .= ("refund" :: Text)
                           ]
                       ) ::
                       Either String Aeson.Value
                   )

  describe "TransactionRelationsResponse JSON" $ do
    it "round-trips outbound + inbound edges" $ do
      let edge = TransactionRelation UUID.nil
          resp =
            TransactionRelationsResponse
              { outbound = [edge "refund"],
                inbound = [edge "merge"]
              }
      Aeson.decode (Aeson.encode resp) `shouldBe` Just resp

    it "encodes empty buckets as empty arrays" $ do
      let resp = TransactionRelationsResponse {outbound = [], inbound = []}
      Aeson.eitherDecode (Aeson.encode resp)
        `shouldBe` ( Right
                       ( object
                           [ "outbound" .= ([] :: [Aeson.Value]),
                             "inbound" .= ([] :: [Aeson.Value])
                           ]
                       ) ::
                       Either String Aeson.Value
                   )

  describe "IncomeRequest JSON" $ do
    it "decodes without relation (absent → Nothing)" $ do
      let json :: LBS.ByteString
          json =
            "{\"accountId\":\"00000001-0000-0000-0000-000000000000\""
              <> ",\"currency\":\"USD\""
              <> ",\"allocations\":{\"incomes\":[],\"expenses\":[]}"
              <> ",\"description\":\"pay\"}"
      case Aeson.eitherDecode json :: Either String IncomeRequest of
        Left err -> expectationFailure $ "decode failed: " <> err
        Right req -> req.relation `shouldBe` Nothing

    it "decodes with a nested relation present" $ do
      let json :: LBS.ByteString
          json =
            "{\"accountId\":\"00000001-0000-0000-0000-000000000000\""
              <> ",\"currency\":\"USD\""
              <> ",\"allocations\":{\"incomes\":[],\"expenses\":[]}"
              <> ",\"description\":\"pay\""
              <> ",\"relation\":{\"relatedTransactionId\":\"00000002-0000-0000-0000-000000000000\",\"relationKind\":\"associated\"}}"
      case Aeson.eitherDecode json :: Either String IncomeRequest of
        Left err -> expectationFailure $ "decode failed: " <> err
        Right req -> do
          fmap (.relatedTransactionId) req.relation
            `shouldBe` UUID.fromString "00000002-0000-0000-0000-000000000000"
          fmap (.relationKind) req.relation `shouldBe` Just "associated"

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
