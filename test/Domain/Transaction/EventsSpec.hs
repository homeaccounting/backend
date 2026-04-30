{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.EventsSpec
-- Description : Backwards-compatibility tests for transaction event JSON
--
-- Events emitted before the @externalTransactionId@ field was added
-- (pre-bank-integration) must still decode from the event store. These
-- tests pin that contract: a 'TransferInitiated' payload without the
-- field decodes as 'Nothing', and the round-trip preserves explicit
-- 'Just' values.
module Domain.Transaction.EventsSpec (spec) where

import Data.Aeson (Value (Object), decode, eitherDecode, encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( TransferType (..),
    unsafeDictionaryEntryId,
    unsafeExternalTransactionId,
  )
import Domain.Transaction.Events (TransferInitiated (..))
import RIO
import Test.Hspec
import Testkit.Helpers (mockAccountId, mockMoney, mockUserId)

spec :: Spec
spec = describe "TransferInitiated JSON" $ do
  it "decodes legacy payloads without externalTransactionId as Nothing" $ do
    let legacy = stripKey "externalTransactionId" (encode sampleEvent)
    case eitherDecode legacy :: Either String TransferInitiated of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.externalTransactionId `shouldBe` Nothing

  it "round-trips TransferInitiated with Just externalTransactionId" $ do
    let evt =
          sampleEvent
            { externalTransactionId =
                Just (unsafeExternalTransactionId "mono-tx-123")
            }
    (eitherDecode (encode evt) :: Either String TransferInitiated)
      `shouldBe` Right evt

  it "decodes legacy payloads without labels as empty set" $ do
    let legacy = stripKey "labels" (encode sampleEvent)
    case eitherDecode legacy :: Either String TransferInitiated of
      Left err -> expectationFailure $ "legacy decode failed: " <> err
      Right decoded -> decoded.labels `shouldBe` Set.empty

-- | A minimal valid 'TransferInitiated' for serialisation tests.
sampleEvent :: TransferInitiated
sampleEvent =
  TransferInitiated
    { sourceAccountId = mockAccountId (uuidFromInt 1),
      targetAccountId = mockAccountId (uuidFromInt 2),
      sourceAmount = mockMoney 10,
      targetAmount = mockMoney 10,
      exchangeRate = Nothing,
      description = "legacy test transfer",
      by = mockUserId (uuidFromInt 3),
      at = UTCTime (fromGregorian 2026 4 1) 0,
      transferType = Income (unsafeDictionaryEntryId (uuidFromInt 4)),
      externalTransactionId = Nothing,
      labels = Set.empty
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
