{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.EventsSpec
-- Description : Backwards-compatibility tests for transaction event JSON
--
-- Events emitted before the @importInfo@ field was added (pre-bank-integration,
-- and events that predate grouping the external id under 'ImportInfo') must
-- still decode from the event store. These tests pin that contract: a
-- 'TransactionPostingInitiated' payload without the field decodes as 'Nothing',
-- and the round-trip preserves explicit 'Just' values.
module Domain.Transaction.EventsSpec (spec) where

import Data.Aeson (Value (Object), decode, eitherDecode, encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( ImportInfo (..),
    RelationKind (..),
    TransactionId,
    TransactionType (Transfer),
    unsafeDictionaryEntryId,
    unsafeExternalTransactionId,
    unsafeTransactionId,
  )
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionAmendmentInitiated (..),
    TransactionContactSet (..),
    TransactionPostingInitiated (..),
    TransactionRelationAdded (..),
  )
import RIO
import Test.Hspec
import Testkit.Helpers (mockAccountId, mockMoney, mockUserId, singletonIncome)

spec :: Spec
spec = do
  postingInitiatedSpec
  relationAddedSpec
  contactSetSpec
  amendmentInitiatedSpec
  amendmentCompletedSpec

postingInitiatedSpec :: Spec
postingInitiatedSpec = describe "TransactionPostingInitiated JSON" $ do
  it "decodes legacy payloads without importInfo as Nothing" $ do
    let legacy = stripKey "importInfo" (encode sampleEvent)
    case eitherDecode legacy :: Either String TransactionPostingInitiated of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.importInfo `shouldBe` Nothing

  it "round-trips TransactionPostingInitiated with Just importInfo carrying an mcc" $ do
    let evt =
          sampleEvent
            { importInfo =
                Just
                  ImportInfo
                    { externalTransactionId = unsafeExternalTransactionId "mono-tx-123",
                      mcc = Just "5411"
                    }
            }
    (eitherDecode (encode evt) :: Either String TransactionPostingInitiated)
      `shouldBe` Right evt

  it "decodes legacy payloads without labels as empty set" $ do
    let legacy = stripKey "labels" (encode sampleEvent)
    case eitherDecode legacy :: Either String TransactionPostingInitiated of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.labels `shouldBe` Set.empty

  it "decodes legacy payloads without contactId as Nothing" $ do
    let legacy = stripKey "contactId" (encode sampleEvent)
    case eitherDecode legacy :: Either String TransactionPostingInitiated of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.contactId `shouldBe` Nothing

  it "round-trips TransactionPostingInitiated with Just contactId" $ do
    let evt :: TransactionPostingInitiated
        evt = sampleEvent {contactId = Just (unsafeDictionaryEntryId (UUID.fromWords64 0 5))}
    (eitherDecode (encode evt) :: Either String TransactionPostingInitiated)
      `shouldBe` Right evt

relationAddedSpec :: Spec
relationAddedSpec = describe "TransactionRelationAdded JSON" $ do
  it "TransactionRelationAdded round-trips through JSON" $ do
    let evt = TransactionRelationAdded sampleRelatedTxId Refund
    (decode (encode evt) :: Maybe TransactionRelationAdded) `shouldBe` Just evt

contactSetSpec :: Spec
contactSetSpec = describe "TransactionContactSet JSON" $ do
  it "round-trips with Just contactId" $ do
    let evt =
          TransactionContactSet
            { transactionId = sampleRelatedTxId,
              contactId = Just (unsafeDictionaryEntryId (UUID.fromWords64 0 7))
            }
    (decode (encode evt) :: Maybe TransactionContactSet) `shouldBe` Just evt

  it "round-trips with Nothing contactId" $ do
    let evt =
          TransactionContactSet
            { transactionId = sampleRelatedTxId,
              contactId = Nothing
            }
    (decode (encode evt) :: Maybe TransactionContactSet) `shouldBe` Just evt

amendmentInitiatedSpec :: Spec
amendmentInitiatedSpec = describe "TransactionAmendmentInitiated JSON" $ do
  it "decodes legacy payloads without contactId as Nothing" $ do
    let legacy = stripKey "contactId" (encode sampleAmendmentInitiated)
    case eitherDecode legacy :: Either String TransactionAmendmentInitiated of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.contactId `shouldBe` Nothing

  it "round-trips with Just contactId" $ do
    let evt :: TransactionAmendmentInitiated
        evt =
          sampleAmendmentInitiated
            { contactId = Just (unsafeDictionaryEntryId (UUID.fromWords64 0 8))
            }
    (eitherDecode (encode evt) :: Either String TransactionAmendmentInitiated)
      `shouldBe` Right evt

amendmentCompletedSpec :: Spec
amendmentCompletedSpec = describe "TransactionAmendmentCompleted JSON" $ do
  it "decodes legacy payloads without contactId as Nothing" $ do
    let legacy = stripKey "contactId" (encode sampleAmendmentCompleted)
    case eitherDecode legacy :: Either String TransactionAmendmentCompleted of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.contactId `shouldBe` Nothing

  it "round-trips with Just contactId" $ do
    let evt :: TransactionAmendmentCompleted
        evt =
          sampleAmendmentCompleted
            { contactId = Just (unsafeDictionaryEntryId (UUID.fromWords64 0 9))
            }
    (eitherDecode (encode evt) :: Either String TransactionAmendmentCompleted)
      `shouldBe` Right evt

-- | A minimal valid 'TransactionAmendmentInitiated' for serialisation tests.
sampleAmendmentInitiated :: TransactionAmendmentInitiated
sampleAmendmentInitiated =
  TransactionAmendmentInitiated
    { transactionId = sampleRelatedTxId,
      newSourceAccountId = mockAccountId (UUID.fromWords64 0 1),
      newTargetAccountId = mockAccountId (UUID.fromWords64 0 2),
      newSourceAmount = mockMoney 10,
      newTargetAmount = mockMoney 10,
      newExchangeRate = Nothing,
      newTransactionType = Transfer,
      contactId = Nothing,
      by = mockUserId (UUID.fromWords64 0 3)
    }

-- | A minimal valid 'TransactionAmendmentCompleted' for serialisation tests.
sampleAmendmentCompleted :: TransactionAmendmentCompleted
sampleAmendmentCompleted =
  TransactionAmendmentCompleted
    { transactionId = sampleRelatedTxId,
      newSourceAccountId = mockAccountId (UUID.fromWords64 0 1),
      newTargetAccountId = mockAccountId (UUID.fromWords64 0 2),
      newSourceAmount = mockMoney 10,
      newTargetAmount = mockMoney 10,
      newExchangeRate = Nothing,
      newTransactionType = Transfer,
      contactId = Nothing,
      by = mockUserId (UUID.fromWords64 0 3)
    }

-- | A fixed related transaction id for the relation round-trip test.
sampleRelatedTxId :: TransactionId
sampleRelatedTxId = unsafeTransactionId (UUID.fromWords 99 0 0 0)

-- | A minimal valid 'TransactionPostingInitiated' for serialisation tests.
sampleEvent :: TransactionPostingInitiated
sampleEvent =
  TransactionPostingInitiated
    { sourceAccountId = mockAccountId (uuidFromInt 1),
      targetAccountId = mockAccountId (uuidFromInt 2),
      sourceAmount = mockMoney 10,
      targetAmount = mockMoney 10,
      exchangeRate = Nothing,
      description = "legacy test transfer",
      by = mockUserId (uuidFromInt 3),
      at = UTCTime (fromGregorian 2026 4 1) 0,
      transactionType = singletonIncome (unsafeDictionaryEntryId (uuidFromInt 4)) (mockMoney 10),
      importInfo = Nothing,
      labels = Set.empty,
      contactId = Nothing
    }
  where
    uuidFromInt :: Word64 -> UUID
    uuidFromInt = UUID.fromWords64 0

-- | Remove a top-level key from a JSON encoding. Returns the original
-- bytes unchanged if the encoding is not a JSON object.
stripKey :: Text -> LByteString -> LByteString
stripKey k bs = case decode bs :: Maybe Value of
  Just (Object kv) -> encode (Object (KM.delete (Key.fromText k) kv))
  _ -> bs
