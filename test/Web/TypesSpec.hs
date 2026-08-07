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

import Data.Aeson (Value (Null, Object), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( Currency (USD),
    TransactionType (Transfer),
    mkBankProviderContact,
    mkByLabel,
    mkByMcc,
    unsafeMcc,
    unsafeMoney,
  )
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountId,
    mockTransactionData,
    mockTransactionDataWithCategory,
    mockTransactionDataWithContact,
    mockTransactionId,
  )
import Web.Types
  ( CategoryAmount (..),
    IncomeRequest (..),
    TransactionRelation (..),
    TransactionRelationsResponse (..),
    fromTransactionData,
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

  describe "TransactionResponse bankProviderCategory JSON" $ do
    let txId = mockTransactionId (UUID.fromWords 1 0 0 0)
        acc = mockAccountId (UUID.fromWords 2 0 0 0)
        amt = unsafeMoney USD 100
        baseTd = mockTransactionData acc acc amt amt Nothing Transfer
        -- Encode a response, then pull out just the @bankProviderCategory@ field.
        bankProviderCategoryField td =
          case Aeson.toJSON (fromTransactionData txId td) of
            Object o -> KeyMap.lookup "bankProviderCategory" o
            _ -> Nothing

    it "surfaces an MCC-based category as a tagged object" $ do
      let td = mockTransactionDataWithCategory (Just (mkByMcc (unsafeMcc 5411))) baseTd
      bankProviderCategoryField td
        `shouldBe` Just
          (object ["kind" .= ("mcc" :: Text), "value" .= ("5411" :: Text)])

    it "zero-pads a short MCC to four digits" $ do
      let td = mockTransactionDataWithCategory (Just (mkByMcc (unsafeMcc 742))) baseTd
      bankProviderCategoryField td
        `shouldBe` Just
          (object ["kind" .= ("mcc" :: Text), "value" .= ("0742" :: Text)])

    it "surfaces a label-based category as a tagged object" $ do
      let td = mockTransactionDataWithCategory (mkByLabel "eating_out") baseTd
      bankProviderCategoryField td
        `shouldBe` Just
          (object ["kind" .= ("label" :: Text), "value" .= ("eating_out" :: Text)])

    it "encodes an absent category as null" $ do
      let td = mockTransactionDataWithCategory Nothing baseTd
      bankProviderCategoryField td `shouldBe` Just Null

  describe "TransactionResponse bankProviderContact JSON" $ do
    let txId = mockTransactionId (UUID.fromWords 1 0 0 0)
        acc = mockAccountId (UUID.fromWords 2 0 0 0)
        amt = unsafeMoney USD 100
        baseTd = mockTransactionData acc acc amt amt Nothing Transfer
        -- Encode a response, then pull out just the @bankProviderContact@ field.
        bankProviderContactField td =
          case Aeson.toJSON (fromTransactionData txId td) of
            Object o -> KeyMap.lookup "bankProviderContact" o
            _ -> Nothing

    it "surfaces a provider contact token as a plain string" $ do
      let td = mockTransactionDataWithContact (mkBankProviderContact "MagazinREMONTI") baseTd
      bankProviderContactField td `shouldBe` Just (Aeson.String "MagazinREMONTI")

    it "encodes an absent contact as null" $ do
      let td = mockTransactionDataWithContact Nothing baseTd
      bankProviderContactField td `shouldBe` Just Null

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
