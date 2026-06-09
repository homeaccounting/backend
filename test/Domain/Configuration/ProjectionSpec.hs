{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.ProjectionSpec
-- Description : Unit tests for Configuration projection
--
-- This module tests that the Configuration projection correctly folds events
-- into aggregate state.
--
-- Test Coverage:
--   - ConfigurationCreated sets all fields
--   - BaseCurrencyChanged updates base currency
--   - DefaultCurrencyChanged updates default currency
--   - DictionaryEntryAdded adds entry (including auto-creating dict)
--   - DictionaryEntryRenamed renames entry
--   - DictionaryEntryRemoved removes entry
module Domain.Configuration.ProjectionSpec (spec) where

import qualified Data.Map.Strict as Map
import Domain.Banking.Types (BankConnectionId, BankProvider (..), unsafeBankConnectionId)
import Domain.Configuration
import Domain.Configuration.Events
  ( BankConnectionAccountMapSet (..),
    BankConnectionAdded (..),
    BankConnectionEnabledSet (..),
    BankConnectionRemoved (..),
    BankConnectionRenamed (..),
    BankConnectionTokenChanged (..),
    BankingDefaultExpenseCategorySet (..),
    BankingDefaultIncomeCategorySet (..),
    BankingMccExpenseCategoryMapSet (..),
    ConfigurationCreated (..),
  )
import Domain.Core.Types
import Eventium (latestProjection)
import Infrastructure.Crypto.SecretBox (EncryptedSecret (..))
import RIO
import Test.Hspec
import Testkit.Generators ()
import Testkit.Helpers
import Prelude (head, read, (!!))

spec :: Spec
spec = do
  configurationDefaultSpec
  configurationCreatedSpec
  baseCurrencyChangedSpec
  defaultCurrencyChangedSpec
  dictionaryEntryAddedSpec
  dictionaryEntryRenamedSpec
  dictionaryEntryRemovedSpec
  bankingProjectionSpec
  bankConnectionProjectionSpec

-- -----------------------------------------------------------------------------
-- configurationDefault Tests
-- -----------------------------------------------------------------------------

configurationDefaultSpec :: Spec
configurationDefaultSpec =
  describe "configurationDefault" $ do
    it "has an empty banking configuration" $ do
      let b = configurationDefault.banking
      b.defaultIncomeCategory `shouldBe` Nothing
      b.defaultExpenseCategory `shouldBe` Nothing
      b.mccExpenseCategoryMap `shouldBe` Map.empty

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get configuration state
applyEvents :: [ConfigurationEvent] -> Configuration
applyEvents = latestProjection configurationProjection

-- | Test IDs
testUserId :: UserId
testUserId = mockUserId (read "11111111-1111-1111-1111-111111111111")

testConfigId :: ConfigurationId
testConfigId = mockConfigurationId (read "22222222-2222-2222-2222-222222222222")

testEntryId1 :: DictionaryEntryId
testEntryId1 = mockDictionaryEntryId (read "33333333-3333-3333-3333-333333333333")

testEntryId2 :: DictionaryEntryId
testEntryId2 = mockDictionaryEntryId (read "44444444-4444-4444-4444-444444444444")

testDictId :: DictionaryId
testDictId = DictionaryId "expense-category"

testEntryName1 :: EntryName
testEntryName1 = mockEntryName "Food"

testEntryName2 :: EntryName
testEntryName2 = mockEntryName "Transport"

testEntryName3 :: EntryName
testEntryName3 = mockEntryName "Rent"

-- | Base created event
createdEvent :: ConfigurationEvent
createdEvent =
  ConfigurationCreatedConfigurationEvent
    ConfigurationCreated
      { baseCurrency = UAH,
        defaultCurrency = UAH,
        createdBy = System
      }

-- -----------------------------------------------------------------------------
-- ConfigurationCreated Tests
-- -----------------------------------------------------------------------------

configurationCreatedSpec :: Spec
configurationCreatedSpec = describe "ConfigurationCreated event" $ do
  it "sets baseCurrency" $ do
    let config = applyEvents [createdEvent]
    config.baseCurrency `shouldBe` UAH

  it "sets defaultCurrency" $ do
    let config = applyEvents [createdEvent]
    config.defaultCurrency `shouldBe` UAH

  it "sets createdBy" $ do
    let config = applyEvents [createdEvent]
    config.createdBy `shouldBe` System

  it "sets isCreated to True" $ do
    let config = applyEvents [createdEvent]
    config.isCreated `shouldBe` True

  it "initializes dictionaries as empty" $ do
    let config = applyEvents [createdEvent]
    config.dictionaries `shouldBe` Map.empty

  it "supports ClonedBy creator" $ do
    let event =
          ConfigurationCreatedConfigurationEvent
            ConfigurationCreated
              { baseCurrency = USD,
                defaultCurrency = EUR,
                createdBy = ClonedBy testUserId testConfigId
              }
    let config = applyEvents [event]
    config.baseCurrency `shouldBe` USD
    config.defaultCurrency `shouldBe` EUR
    config.createdBy `shouldBe` ClonedBy testUserId testConfigId

-- -----------------------------------------------------------------------------
-- BaseCurrencyChanged Tests
-- -----------------------------------------------------------------------------

baseCurrencyChangedSpec :: Spec
baseCurrencyChangedSpec = describe "BaseCurrencyChanged event" $ do
  it "updates base currency" $ do
    let config =
          applyEvents
            [ createdEvent,
              BaseCurrencyChangedConfigurationEvent
                BaseCurrencyChanged {baseCurrency = USD}
            ]
    config.baseCurrency `shouldBe` USD

  it "does not affect other fields" $ do
    let config =
          applyEvents
            [ createdEvent,
              BaseCurrencyChangedConfigurationEvent
                BaseCurrencyChanged {baseCurrency = USD}
            ]
    config.defaultCurrency `shouldBe` UAH
    config.createdBy `shouldBe` System
    config.isCreated `shouldBe` True

-- -----------------------------------------------------------------------------
-- DefaultCurrencyChanged Tests
-- -----------------------------------------------------------------------------

defaultCurrencyChangedSpec :: Spec
defaultCurrencyChangedSpec = describe "DefaultCurrencyChanged event" $ do
  it "updates default currency" $ do
    let config =
          applyEvents
            [ createdEvent,
              DefaultCurrencyChangedConfigurationEvent
                DefaultCurrencyChanged {defaultCurrency = EUR}
            ]
    config.defaultCurrency `shouldBe` EUR

  it "does not affect other fields" $ do
    let config =
          applyEvents
            [ createdEvent,
              DefaultCurrencyChangedConfigurationEvent
                DefaultCurrencyChanged {defaultCurrency = EUR}
            ]
    config.baseCurrency `shouldBe` UAH
    config.createdBy `shouldBe` System

-- -----------------------------------------------------------------------------
-- DictionaryEntryAdded Tests
-- -----------------------------------------------------------------------------

dictionaryEntryAddedSpec :: Spec
dictionaryEntryAddedSpec = describe "DictionaryEntryAdded event" $ do
  it "auto-creates dictionary when adding first entry" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  }
            ]
    Map.member testDictId config.dictionaries `shouldBe` True

  it "adds entry to new dictionary" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict -> do
        length dict.entries `shouldBe` 1
        let entry = head dict.entries
        entry.entryId `shouldBe` testEntryId1
        entry.name `shouldBe` testEntryName1

  it "appends entry to existing dictionary" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict -> length dict.entries `shouldBe` 2

-- -----------------------------------------------------------------------------
-- DictionaryEntryRenamed Tests
-- -----------------------------------------------------------------------------

dictionaryEntryRenamedSpec :: Spec
dictionaryEntryRenamedSpec = describe "DictionaryEntryRenamed event" $ do
  it "renames the correct entry" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  },
              DictionaryEntryRenamedConfigurationEvent
                DictionaryEntryRenamed
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict -> do
        let entry = head dict.entries
        entry.name `shouldBe` testEntryName3
        entry.entryId `shouldBe` testEntryId1

  it "does not affect other entries" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2
                  },
              DictionaryEntryRenamedConfigurationEvent
                DictionaryEntryRenamed
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict -> do
        length dict.entries `shouldBe` 2
        let entry2 = dict.entries !! 1
        entry2.name `shouldBe` testEntryName2

-- -----------------------------------------------------------------------------
-- DictionaryEntryRemoved Tests
-- -----------------------------------------------------------------------------

dictionaryEntryRemovedSpec :: Spec
dictionaryEntryRemovedSpec = describe "DictionaryEntryRemoved event" $ do
  it "removes the correct entry" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryId = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2
                  },
              DictionaryEntryRemovedConfigurationEvent
                DictionaryEntryRemoved
                  { dictionaryId = testDictId,
                    entryId = testEntryId1
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict -> do
        length dict.entries `shouldBe` 1
        let entry = head dict.entries
        entry.entryId `shouldBe` testEntryId2
        entry.name `shouldBe` testEntryName2

-- -----------------------------------------------------------------------------
-- Banking Projection Tests
-- -----------------------------------------------------------------------------

bankingProjectionSpec :: Spec
bankingProjectionSpec = describe "banking projection" $ do
  it "BankingDefaultIncomeCategorySet sets the income slot" $ do
    let config =
          applyEvents
            [ createdEvent,
              BankingDefaultIncomeCategorySetConfigurationEvent
                BankingDefaultIncomeCategorySet
                  { categoryId = testEntryId1
                  }
            ]
    config.banking.defaultIncomeCategory `shouldBe` Just testEntryId1

  it "BankingDefaultExpenseCategorySet sets the expense slot" $ do
    let config =
          applyEvents
            [ createdEvent,
              BankingDefaultExpenseCategorySetConfigurationEvent
                BankingDefaultExpenseCategorySet
                  { categoryId = testEntryId2
                  }
            ]
    config.banking.defaultExpenseCategory `shouldBe` Just testEntryId2

  it "BankingMccExpenseCategoryMapSet replaces the mcc map wholesale" $ do
    let m1 = Map.singleton "5411" testEntryId1
        m2 = Map.singleton "5812" testEntryId2
        config =
          applyEvents
            [ createdEvent,
              BankingMccExpenseCategoryMapSetConfigurationEvent
                BankingMccExpenseCategoryMapSet
                  { mapping = m1
                  },
              BankingMccExpenseCategoryMapSetConfigurationEvent
                BankingMccExpenseCategoryMapSet
                  { mapping = m2
                  }
            ]
    config.banking.mccExpenseCategoryMap `shouldBe` m2

-- -----------------------------------------------------------------------------
-- Bank Connection Projection Tests
-- -----------------------------------------------------------------------------

testConnId :: BankConnectionId
testConnId = unsafeBankConnectionId (read "55555555-5555-5555-5555-555555555555")

testAccountId :: AccountId
testAccountId = unsafeAccountId (read "66666666-6666-6666-6666-666666666666")

testEncryptedToken :: EncryptedSecret
testEncryptedToken =
  EncryptedSecret
    { keyVersion = 1,
      nonce = "bm9uY2U=",
      ciphertext = "Y2lwaGVy",
      authTag = "dGFn"
    }

testEncryptedToken2 :: EncryptedSecret
testEncryptedToken2 =
  EncryptedSecret
    { keyVersion = 2,
      nonce = "bm9uY2Uy",
      ciphertext = "Y2lwaGVyMg==",
      authTag = "dGFnMg=="
    }

addConnEvent :: ConfigurationEvent
addConnEvent =
  BankConnectionAddedConfigurationEvent
    BankConnectionAdded
      { connectionId = testConnId,
        provider = Monobank,
        name = "My Monobank",
        encryptedToken = testEncryptedToken,
        tokenHint = "abc…xyz",
        enabled = True
      }

bankConnectionProjectionSpec :: Spec
bankConnectionProjectionSpec = describe "bank connection projection" $ do
  it "BankConnectionAdded inserts a connection with an empty account map" $ do
    let config = applyEvents [createdEvent, addConnEvent]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> do
        conn.connectionId `shouldBe` testConnId
        conn.provider `shouldBe` Monobank
        conn.name `shouldBe` "My Monobank"
        conn.encryptedToken `shouldBe` testEncryptedToken
        conn.tokenHint `shouldBe` "abc…xyz"
        conn.enabled `shouldBe` True
        conn.accountMap `shouldBe` Map.empty

  it "BankConnectionRenamed updates the name only" $ do
    let config =
          applyEvents
            [ createdEvent,
              addConnEvent,
              BankConnectionRenamedConfigurationEvent
                BankConnectionRenamed
                  { connectionId = testConnId,
                    name = "Renamed"
                  }
            ]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> do
        conn.name `shouldBe` "Renamed"
        conn.encryptedToken `shouldBe` testEncryptedToken

  it "BankConnectionTokenChanged updates encryptedToken and tokenHint" $ do
    let config =
          applyEvents
            [ createdEvent,
              addConnEvent,
              BankConnectionTokenChangedConfigurationEvent
                BankConnectionTokenChanged
                  { connectionId = testConnId,
                    encryptedToken = testEncryptedToken2,
                    tokenHint = "new…hint"
                  }
            ]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> do
        conn.encryptedToken `shouldBe` testEncryptedToken2
        conn.tokenHint `shouldBe` "new…hint"

  it "BankConnectionEnabledSet updates the enabled flag" $ do
    let config =
          applyEvents
            [ createdEvent,
              addConnEvent,
              BankConnectionEnabledSetConfigurationEvent
                BankConnectionEnabledSet
                  { connectionId = testConnId,
                    enabled = False
                  }
            ]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> conn.enabled `shouldBe` False

  it "BankConnectionAccountMapSet populates the account map" $ do
    let m = Map.singleton "ext-acc-1" testAccountId
        config =
          applyEvents
            [ createdEvent,
              addConnEvent,
              BankConnectionAccountMapSetConfigurationEvent
                BankConnectionAccountMapSet
                  { connectionId = testConnId,
                    accountMap = m
                  }
            ]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> conn.accountMap `shouldBe` m

  it "BankConnectionRemoved deletes the connection" $ do
    let config =
          applyEvents
            [ createdEvent,
              addConnEvent,
              BankConnectionRemovedConfigurationEvent
                BankConnectionRemoved
                  { connectionId = testConnId
                  }
            ]
    Map.member testConnId config.banking.connections `shouldBe` False
