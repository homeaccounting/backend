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
import qualified Data.Map.Strict as Map
import Domain.Banking.Import (ExternalTransactionId, importInfoCategory, importInfoContact, importInfoExternalTransactionIds, unsafeExternalTransactionId)
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact, mkByLabel, mkByMcc, unsafeBankProviderContact, unsafeMcc)
import Domain.Configuration.Events (BankProviderContactMapSet (..), BankProviderExpenseCategoryMapSet (..), BankProviderIncomeCategoryMapSet (..), ConfigurationCreated (..))
import Domain.Core.Types (TransactionType (..))
import Domain.Localization.Language (Language (..))
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
import Testkit.BankingHelpers (byCounterparty, byLabel)
import Testkit.Helpers
  ( mockAccountIdN,
    mockCategoryIdN,
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

-- | The provider category carried by a decoded posting event's import info.
postingImportCategory :: AccountingEvent -> Maybe BankProviderCategory
postingImportCategory (TransactionPostingInitiatedEvent (TransactionPostingInitiated {importInfo = imp})) =
  imp >>= importInfoCategory
postingImportCategory _ = Nothing

-- | The provider contact signal carried by a decoded posting event's import info.
postingImportContact :: AccountingEvent -> Maybe BankProviderContact
postingImportContact (TransactionPostingInitiatedEvent (TransactionPostingInitiated {importInfo = imp})) =
  imp >>= importInfoContact
postingImportContact _ = Nothing

spec :: Spec
spec = describe "accountingEventCodec (schema evolution)" $ do
  -- Legacy-shape decode: a 'ConfigurationCreated' stored before the p13n signal
  -- foundation lacked 'language'/'country'. The v1->v2 upcaster injects
  -- language="en"/country=null; decoding must yield En/Nothing and round-trip.
  it "upcasts a v1 ConfigurationCreated (no language/country) to En/Nothing and round-trips" $ do
    stored <- loadStoredEvent "test/fixtures/events/configuration-created-v1.json"
    case accountingEventCodec.decode stored of
      Nothing -> expectationFailure "v1 ConfigurationCreated failed to decode"
      Just event -> do
        case event of
          ConfigurationCreatedEvent (ConfigurationCreated {language = lang, country = ctry}) -> do
            lang `shouldBe` En
            ctry `shouldBe` Nothing
          _ -> expectationFailure "decoded to the wrong event constructor"
        accountingEventCodec.decode (accountingEventCodec.encode event) `shouldBe` Just event

  it "round-trips a current amendment event, preserving allowOverdraft = True" $ do
    let ev = amendEvent True
    accountingEventCodec.decode (accountingEventCodec.encode ev) `shouldBe` Just ev

  -- Reads a current-shape stored posting event whose import info carries a
  -- provider category (an MCC value) and a provider contact signal from a
  -- fixture, decodes it, and confirms the decode -> encode -> decode loop is
  -- stable. The registry has no upcaster for this type any more (the historical
  -- scalar->list widening was cleared by the pre-launch DB recreate), so this
  -- exercises the current stored shape only.
  it "decodes a current import posting event carrying a provider category and contact and round-trips it" $ do
    stored <- loadStoredEvent "test/fixtures/events/transaction-posting-initiated-import.json"
    case accountingEventCodec.decode stored of
      Nothing -> expectationFailure "import posting event failed to decode"
      Just event -> do
        postingImportIds event `shouldBe` Just (unsafeExternalTransactionId "7IXfaQ8bpY5s7RO5Uw" :| [])
        postingImportCategory event `shouldBe` Just (mkByMcc (unsafeMcc 5411))
        postingImportContact event `shouldBe` Just (unsafeBankProviderContact "Магазин РЕМОНТІ")
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
                category = Just (mkByMcc (unsafeMcc 5411)),
                contact = Nothing
              }
    stored <- loadStoredEvent "test/fixtures/events/transaction-import-reconciled.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  -- Sibling of the above for the other 'BankProviderCategory' case: a reconciled
  -- event whose category is a provider text label (@ByLabel@). Pins the label
  -- value-shape @{"kind":"label", ...}@ and round-trips it.
  it "decodes a TransactionImportReconciled fixture carrying a label category and round-trips it" $ do
    let expected =
          TransactionImportReconciledEvent
            TransactionImportReconciled
              { transactionId = mockTransactionIdN 1,
                externalTransactionIds = unsafeExternalTransactionId "privat-xyz789" :| [],
                category = mkByLabel "eating_out",
                contact = Nothing
              }
    stored <- loadStoredEvent "test/fixtures/events/transaction-import-reconciled-label.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  -- Sibling covering the 'BankProviderContact' field: a reconciled event
  -- carrying both a provider category and a provider contact signal. Pins the
  -- contact value-shape — a plain string, unlike the tagged
  -- @{"kind":..., "value":...}@ category shape — and round-trips it.
  it "decodes a TransactionImportReconciled fixture carrying a contact and round-trips it" $ do
    let expected =
          TransactionImportReconciledEvent
            TransactionImportReconciled
              { transactionId = mockTransactionIdN 1,
                externalTransactionIds = unsafeExternalTransactionId "mono-def456" :| [],
                category = Just (mkByMcc (unsafeMcc 5411)),
                contact = Just (unsafeBankProviderContact "Магазин РЕМОНТІ")
              }
    stored <- loadStoredEvent "test/fixtures/events/transaction-import-reconciled-contact.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  -- 'BankProviderExpenseCategoryMapSet' serialises its 'BankProviderCategory' map keys in
  -- the tagged KEY form (@"mcc:0742"@ / @"label:eating_out"@), the other JSON
  -- form of a 'BankProviderCategory'. Reads a committed fixture, confirms both key
  -- kinds parse back, and confirms round-trip stability.
  it "decodes a BankProviderExpenseCategoryMapSet fixture with tagged category keys and round-trips it" $ do
    let labelKey = byLabel "eating_out"
        expected =
          BankProviderExpenseCategoryMapSetEvent
            BankProviderExpenseCategoryMapSet
              { mapping =
                  Map.fromList
                    [ (mkByMcc (unsafeMcc 742), mockCategoryIdN 1),
                      (labelKey, mockCategoryIdN 2)
                    ]
              }
    stored <- loadStoredEvent "test/fixtures/events/bank-provider-expense-category-map-set.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  -- 'BankProviderContactMapSet' serialises its 'BankProviderContact' map keys as
  -- the PLAIN provider token verbatim (no @mcc:@/@label:@ prefix, unlike
  -- 'BankProviderCategory' keys) — reads a committed fixture, confirms the
  -- plain-token keys parse back, and confirms round-trip stability.
  it "decodes a BankProviderContactMapSet fixture with plain-token contact keys and round-trips it" $ do
    let expected =
          BankProviderContactMapSetEvent
            BankProviderContactMapSet
              { mapping =
                  Map.fromList
                    [ (unsafeBankProviderContact "Магазин РЕМОНТІ", mockCategoryIdN 1),
                      (unsafeBankProviderContact "IVAN", mockCategoryIdN 2)
                    ]
              }
    stored <- loadStoredEvent "test/fixtures/events/bank-provider-contact-map-set.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  -- 'BankProviderIncomeCategoryMapSet' is the income-side sibling of
  -- 'BankProviderExpenseCategoryMapSet'; it serialises its 'BankProviderCategory'
  -- map keys in the same tagged KEY form (here a @"counterparty:..."@ token).
  -- Reads a committed fixture, confirms the key parses back, and confirms
  -- round-trip stability.
  it "decodes a BankProviderIncomeCategoryMapSet fixture with a counterparty category key and round-trips it" $ do
    let counterpartyKey = byCounterparty "12345678"
        expected =
          BankProviderIncomeCategoryMapSetEvent
            BankProviderIncomeCategoryMapSet
              { mapping =
                  Map.fromList
                    [ (counterpartyKey, mockCategoryIdN 3)
                    ]
              }
    stored <- loadStoredEvent "test/fixtures/events/bank-provider-income-category-map-set.json"
    accountingEventCodec.decode stored `shouldBe` Just expected
    accountingEventCodec.decode (accountingEventCodec.encode expected) `shouldBe` Just expected

  it "tags TransactionImportReconciled with its type-derived registry key" $ do
    let ev =
          TransactionImportReconciledEvent
            TransactionImportReconciled
              { transactionId = mockTransactionIdN 1,
                externalTransactionIds = unsafeExternalTransactionId "mono-abc123" :| [],
                category = Nothing,
                contact = Nothing
              }
        tagField = case toJSON ev of
          Object o -> KeyMap.lookup "tag" o
          _ -> Nothing
    tagField `shouldBe` Just (String (eventTypeName @TransactionImportReconciled))
