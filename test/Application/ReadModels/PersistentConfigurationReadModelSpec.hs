{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.PersistentConfigurationReadModelSpec
-- Description : Guarantees of the persistent Configuration read model's
--               bank-provider-contact map table.
--
-- Exercises the property that @configuration_bank_provider_contacts@ exists
-- to provide, seeding synthesized events through the read model's own
-- 'applyConfigurationEvent' (no test-only insertion hole):
--
--   * __Round-trip__ — after a 'BankProviderContactMapSet' event, the loaded
--     'bankProviderContactMap' equals the emitted mapping.
--   * __Full replace__ — a subsequent 'BankProviderContactMapSet' with a
--     different map fully replaces the rows (bulk-replace semantics, mirroring
--     the shipped provider-expense-category map).
module Application.ReadModels.PersistentConfigurationReadModelSpec (spec) where

import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    applyConfigurationEvent,
    getConfiguration,
  )
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Configuration.Events
  ( BankProviderContactMapSet (..),
    ConfigurationCreated (..),
  )
import Domain.Configuration.Projection (BankingConfiguration (..))
import Domain.Core.Types
  ( ConfigurationId,
    CreatedBy (..),
    Currency (..),
    unConfigurationId,
    unsafeBankProviderContact,
  )
import Domain.Models (AccountingEvent (..))
import qualified Eventium
import Infrastructure.App (AppEnv)
import RIO
import Test.Hspec
import Testkit.Helpers (globalEvent, mockConfigurationId, mockDictionaryEntryId)
import Testkit.InMemoryEventStore (runDbIn, seedGlobals)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

config :: Word32 -> ConfigurationId
config n = mockConfigurationId (UUID.fromWords n 0 0 0)

configGlobal ::
  ConfigurationId ->
  Eventium.EventVersion ->
  AccountingEvent ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
configGlobal cid = globalEvent (unConfigurationId cid)

created :: ConfigurationId -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
created cid ver =
  configGlobal
    cid
    ver
    ( ConfigurationCreatedEvent
        ConfigurationCreated
          { baseCurrency = USD,
            defaultCurrency = USD,
            createdBy = System
          }
    )

contactMapSet :: ConfigurationId -> [(Text, Word32)] -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
contactMapSet cid entries ver =
  configGlobal
    cid
    ver
    ( BankProviderContactMapSetEvent
        BankProviderContactMapSet
          { mapping =
              Map.fromList
                [ (unsafeBankProviderContact token, mockDictionaryEntryId (UUID.fromWords n 0 0 0))
                | (token, n) <- entries
                ]
          }
    )

seedEnv :: [Eventium.GlobalStreamEvent AccountingEvent] -> IO AppEnv
seedEnv = seedGlobals applyConfigurationEvent

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Persistent Configuration read model" $ do
  describe "bank-provider-contact map (configuration_bank_provider_contacts)" $ do
    it "round-trips a BankProviderContactMapSet mapping through getConfiguration" $ do
      let cid = config 1
          entries = [("wise:acme-corp", 10), ("wise:jane-doe", 11)]
      env <- seedEnv [created cid 0 0, contactMapSet cid entries 1 1]
      cfg <- runDbIn env (getConfiguration cid)
      let expected =
            Map.fromList
              [ (unsafeBankProviderContact token, mockDictionaryEntryId (UUID.fromWords n 0 0 0))
              | (token, n) <- entries
              ]
      case cfg of
        Nothing -> expectationFailure "Configuration not found in read model"
        Just c -> c.banking.bankProviderContactMap `shouldBe` expected

    it "fully replaces the map on a subsequent Set (bulk-replace, not merge)" $ do
      let cid = config 2
          firstEntries = [("wise:old-a", 20), ("wise:old-b", 21)]
          secondEntries = [("wise:new-only", 22)]
      env <-
        seedEnv
          [ created cid 0 0,
            contactMapSet cid firstEntries 1 1,
            contactMapSet cid secondEntries 2 2
          ]
      cfg <- runDbIn env (getConfiguration cid)
      let expected =
            Map.fromList
              [ (unsafeBankProviderContact token, mockDictionaryEntryId (UUID.fromWords n 0 0 0))
              | (token, n) <- secondEntries
              ]
      case cfg of
        Nothing -> expectationFailure "Configuration not found in read model"
        Just c -> c.banking.bankProviderContactMap `shouldBe` expected
