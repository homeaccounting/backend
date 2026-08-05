{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Eventium.SchemaSpec
-- Description : Schema evolution for the accounting event store.
--
-- Verifies that older stored events still decode after an event type's shape
-- changes, via the upcast-on-read registry. The concrete case: a
-- 'TransactionAmendmentInitiated' event stored before the @allowOverdraft@
-- field existed must decode as @allowOverdraft = False@.
module Infrastructure.Eventium.SchemaSpec (spec) where

import Data.Aeson (Value (..), decodeStrict, toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import Domain.Core.Types
  ( ExternalTransactionId,
    TransactionType (..),
    importInfoExternalTransactionIds,
    unsafeExternalTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionAmendmentInitiated (..),
    TransactionImportReconciled (..),
    TransactionPostingInitiated (..),
  )
import Eventium.Codec (Codec (..))
import Eventium.Store.Postgresql (JSONString, encodeJSON)
import Eventium.Store.Types (eventTypeName)
import Infrastructure.Eventium.Schema (accountingEventCodec)
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountIdN,
    mockMoney,
    mockTransactionIdN,
    mockUserIdN,
  )

-- | An amendment event whose @allowOverdraft@ takes the given value. Uses a
-- 'Transfer' type so no allocation machinery is needed.
amendEvent :: Bool -> AccountingEvent
amendEvent allowOd =
  TransactionAmendmentInitiatedEvent
    TransactionAmendmentInitiated
      { transactionId = mockTransactionIdN 1,
        newSourceAccountId = mockAccountIdN 2,
        newTargetAccountId = mockAccountIdN 3,
        newSourceAmount = mockMoney 100,
        newTargetAmount = mockMoney 100,
        newExchangeRate = Nothing,
        newTransactionType = Transfer,
        contactId = Nothing,
        allowOverdraft = allowOd,
        by = mockUserIdN 4
      }

-- | Delete @allowOverdraft@ from the event's @contents@ object, reproducing the
-- pre-field (v1) stored shape from a real current encoding — so the test never
-- hardcodes the full field list.
stripAllowOverdraft :: Value -> Value
stripAllowOverdraft (Object o) = case KeyMap.lookup "contents" o of
  Just (Object c) -> Object (KeyMap.insert "contents" (Object (KeyMap.delete "allowOverdraft" c)) o)
  _ -> Object o
stripAllowOverdraft v = v

-- | Load a stored event payload from a committed JSON fixture — a verbatim copy
-- of a row's @payload@ as it sits in a production event store (no envelope, the
-- shape that release wrote). Read as an Aeson 'Value' and re-serialised through
-- 'encodeJSON' so it enters the codec exactly as a stored 'JSONString' would.
loadStoredEvent :: FilePath -> IO JSONString
loadStoredEvent path = do
  bytes <- readFileBinary path
  case decodeStrict bytes :: Maybe Value of
    Just v -> pure (encodeJSON v)
    Nothing -> throwString ("fixture is not valid JSON: " <> path)

-- | The import external ids carried by a decoded posting event (if any).
postingImportIds :: AccountingEvent -> Maybe (NonEmpty ExternalTransactionId)
postingImportIds (TransactionPostingInitiatedEvent (TransactionPostingInitiated {importInfo = imp})) =
  importInfoExternalTransactionIds <$> imp
postingImportIds _ = Nothing

spec :: Spec
spec = describe "accountingEventCodec (schema evolution)" $ do
  it "decodes a legacy amendment event with no allowOverdraft as allowOverdraft = False" $ do
    let expected = amendEvent False
        legacy = encodeJSON (stripAllowOverdraft (toJSON expected))
    accountingEventCodec.decode legacy `shouldBe` Just expected

  it "round-trips a current amendment event, preserving allowOverdraft = True" $ do
    let ev = amendEvent True
    accountingEventCodec.decode (accountingEventCodec.encode ev) `shouldBe` Just ev

  -- Reads a real pre-widening stored posting event (scalar @externalTransactionId@)
  -- from a fixture, upcasts it on read, re-encodes it at the current schema, and
  -- reads it again: the upcast must succeed (the field becomes a one-element
  -- list) and the write-back/read-again must be stable.
  it "upcasts a legacy import posting event from a fixture and round-trips it" $ do
    stored <- loadStoredEvent "test/fixtures/events/transaction-posting-initiated-legacy-import.json"
    case accountingEventCodec.decode stored of
      Nothing -> expectationFailure "legacy posting event failed to decode after upcast"
      Just event -> do
        postingImportIds event `shouldBe` Just (unsafeExternalTransactionId "7IXfaQ8bpY5s7RO5Uw" :| [])
        accountingEventCodec.decode (accountingEventCodec.encode event) `shouldBe` Just event

  -- Pins the compile-time-safe registry key: the type-derived 'eventTag' must
  -- equal the tag the codec actually writes. Both sides are derived (no literal),
  -- so this fails if the type-name-equals-JSON-tag convention ever diverges.
  it "derives the registry key from the event type, matching the stored JSON tag" $ do
    let tagField = case toJSON (amendEvent True) of
          Object o -> KeyMap.lookup "tag" o
          _ -> Nothing
    tagField `shouldBe` Just (String (eventTypeName @TransactionAmendmentInitiated))

  -- 'TransactionImportReconciled' is a brand-new (v1) event with no prior stored
  -- shape, so it needs no upcaster. This still pins its wire shape: reads a
  -- committed fixture, confirms it decodes to the expected event, and confirms
  -- the decode -> encode -> decode loop is stable.
  it "decodes a TransactionImportReconciled fixture and round-trips it" $ do
    let expected =
          TransactionImportReconciledEvent
            TransactionImportReconciled
              { transactionId = mockTransactionIdN 1,
                externalTransactionIds = unsafeExternalTransactionId "mono-abc123" :| [],
                mcc = Just "5411"
              }
    stored <- loadStoredEvent "test/fixtures/events/transaction-import-reconciled.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  it "tags TransactionImportReconciled with its type-derived registry key" $ do
    let ev =
          TransactionImportReconciledEvent
            TransactionImportReconciled
              { transactionId = mockTransactionIdN 1,
                externalTransactionIds = unsafeExternalTransactionId "mono-abc123" :| [],
                mcc = Nothing
              }
        tagField = case toJSON ev of
          Object o -> KeyMap.lookup "tag" o
          _ -> Nothing
    tagField `shouldBe` Just (String (eventTypeName @TransactionImportReconciled))
