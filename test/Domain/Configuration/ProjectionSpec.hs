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
import Domain.Banking.Signal (mkByMcc, unsafeBankProviderContact, unsafeMcc)
import Domain.Banking.Types (BankConnectionId, unsafeBankConnectionId, unsafeBankProviderId, unsafeExternalAccountId)
import Domain.Configuration
import Domain.Configuration.Dictionary (Dictionary (..), DictionaryEntry (..), EntryRole (..))
import qualified Domain.Configuration.Dictionary as DictKind
import Domain.Configuration.Events
  ( BankConnectionAccountMapSet (..),
    BankConnectionAdded (..),
    BankConnectionCredentialChanged (..),
    BankConnectionEnabledSet (..),
    BankConnectionRemoved (..),
    BankConnectionRenamed (..),
    BankProviderContactMapSet (..),
    BankProviderExpenseCategoryMapSet (..),
    BankProviderIncomeCategoryMapSet (..),
    ConfigurationCreated (..),
    DefaultAccountSet (..),
    DefaultExpenseCategorySet (..),
    DefaultIncomeCategorySet (..),
    DefaultSubtypeAccountsSet (..),
  )
import Domain.Core.Types
import Eventium (latestProjection)
import Infrastructure.Crypto.SecretBox (EncryptedSecret (..))
import RIO
import RIO.List (find)
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
  dictionaryEntryMovedSpec
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
      configurationDefault.defaults.incomeCategory `shouldBe` Nothing
      configurationDefault.defaults.expenseCategory `shouldBe` Nothing
      configurationDefault.defaults.account `shouldBe` Nothing
      configurationDefault.defaults.subtypeAccounts `shouldBe` Map.empty
      b.expenseCategoryMap `shouldBe` Map.empty
      b.contactMap `shouldBe` Map.empty

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

testDictId :: DictKind.DictionaryKind
testDictId = DictKind.ExpenseKind

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
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  }
            ]
    Map.member testDictId config.dictionaries `shouldBe` True

  it "adds entry to new dictionary" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
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
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2,
                    role = ItemRole,
                    parentId = Nothing
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
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  },
              DictionaryEntryRenamedConfigurationEvent
                DictionaryEntryRenamed
                  { dictionaryKind = testDictId,
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
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2,
                    role = ItemRole,
                    parentId = Nothing
                  },
              DictionaryEntryRenamedConfigurationEvent
                DictionaryEntryRenamed
                  { dictionaryKind = testDictId,
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

  it "preserves the entry's role across a rename" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = GroupRole,
                    parentId = Nothing
                  },
              DictionaryEntryRenamedConfigurationEvent
                DictionaryEntryRenamed
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict -> do
        let entry = head dict.entries
        entry.name `shouldBe` testEntryName3
        entry.role `shouldBe` GroupRole

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
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2,
                    role = ItemRole,
                    parentId = Nothing
                  },
              DictionaryEntryRemovedConfigurationEvent
                DictionaryEntryRemoved
                  { dictionaryKind = testDictId,
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
-- DictionaryEntryMoved Tests
-- -----------------------------------------------------------------------------

dictionaryEntryMovedSpec :: Spec
dictionaryEntryMovedSpec = describe "DictionaryEntryMoved event" $ do
  it "reparents an entry under a new parent" $ do
    let config =
          applyEvents
            [ createdEvent,
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName2,
                    role = GroupRole,
                    parentId = Nothing
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = GroupRole,
                    parentId = Nothing
                  },
              DictionaryEntryMovedConfigurationEvent
                DictionaryEntryMoved
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    newParentId = Just testEntryId2
                  }
            ]
    case Map.lookup testDictId config.dictionaries of
      Nothing -> expectationFailure "Dictionary should exist"
      Just dict ->
        case find (\e -> e.entryId == testEntryId1) dict.entries of
          Nothing -> expectationFailure "Moved entry should exist"
          Just entry -> do
            entry.parentId `shouldBe` Just testEntryId2
            -- The move never carries a role; it must be preserved. Using a
            -- Group here exercises the role x move cell the rename test (Group)
            -- and add tests (both) leave otherwise uncovered for moves.
            entry.role `shouldBe` GroupRole

-- -----------------------------------------------------------------------------
-- Banking Projection Tests
-- -----------------------------------------------------------------------------

bankingProjectionSpec :: Spec
bankingProjectionSpec = describe "banking projection" $ do
  it "DefaultIncomeCategorySet sets the income slot" $ do
    let config =
          applyEvents
            [ createdEvent,
              DefaultIncomeCategorySetConfigurationEvent
                DefaultIncomeCategorySet
                  { categoryId = testEntryId1
                  }
            ]
    config.defaults.incomeCategory `shouldBe` Just testEntryId1

  it "DefaultExpenseCategorySet sets the expense slot" $ do
    let config =
          applyEvents
            [ createdEvent,
              DefaultExpenseCategorySetConfigurationEvent
                DefaultExpenseCategorySet
                  { categoryId = testEntryId2
                  }
            ]
    config.defaults.expenseCategory `shouldBe` Just testEntryId2

  it "DefaultAccountSet sets the global default account" $ do
    let config =
          applyEvents
            [ createdEvent,
              DefaultAccountSetConfigurationEvent
                DefaultAccountSet {accountId = testAccountId}
            ]
    config.defaults.account `shouldBe` Just testAccountId

  it "DefaultSubtypeAccountsSet replaces the subtype-account map wholesale" $ do
    let m1 = Map.singleton CashKind testAccountId
        m2 = Map.singleton BankAccountKind (mockAccountIdN 2)
        config =
          applyEvents
            [ createdEvent,
              DefaultSubtypeAccountsSetConfigurationEvent DefaultSubtypeAccountsSet {subtypeAccounts = m1},
              DefaultSubtypeAccountsSetConfigurationEvent DefaultSubtypeAccountsSet {subtypeAccounts = m2}
            ]
    config.defaults.subtypeAccounts `shouldBe` m2

  it "BankProviderExpenseCategoryMapSet replaces the provider-category map wholesale" $ do
    let m1 = Map.singleton (mkByMcc (unsafeMcc 5411)) testEntryId1
        m2 = Map.singleton (mkByMcc (unsafeMcc 5812)) testEntryId2
        config =
          applyEvents
            [ createdEvent,
              BankProviderExpenseCategoryMapSetConfigurationEvent
                BankProviderExpenseCategoryMapSet
                  { mapping = m1
                  },
              BankProviderExpenseCategoryMapSetConfigurationEvent
                BankProviderExpenseCategoryMapSet
                  { mapping = m2
                  }
            ]
    config.banking.expenseCategoryMap `shouldBe` m2

  it "BankProviderIncomeCategoryMapSet replaces the income provider-category map and leaves the expense map untouched" $ do
    let expenseMap = Map.singleton (mkByMcc (unsafeMcc 5411)) testEntryId1
        incomeMap = Map.singleton (mkByMcc (unsafeMcc 6011)) testEntryId2
        config =
          applyEvents
            [ createdEvent,
              BankProviderExpenseCategoryMapSetConfigurationEvent
                BankProviderExpenseCategoryMapSet
                  { mapping = expenseMap
                  },
              BankProviderIncomeCategoryMapSetConfigurationEvent
                BankProviderIncomeCategoryMapSet
                  { mapping = incomeMap
                  }
            ]
    config.banking.incomeCategoryMap `shouldBe` incomeMap
    config.banking.expenseCategoryMap `shouldBe` expenseMap

  it "BankProviderContactMapSet replaces the provider-contact map wholesale" $ do
    let m1 = Map.singleton (unsafeBankProviderContact "IVAN PETRENKO") testEntryId1
        m2 = Map.singleton (unsafeBankProviderContact "OKSANA KOVAL") testEntryId2
        config =
          applyEvents
            [ createdEvent,
              BankProviderContactMapSetConfigurationEvent
                BankProviderContactMapSet
                  { mapping = m1
                  },
              BankProviderContactMapSetConfigurationEvent
                BankProviderContactMapSet
                  { mapping = m2
                  }
            ]
    config.banking.contactMap `shouldBe` m2

-- -----------------------------------------------------------------------------
-- Bank Connection Projection Tests
-- -----------------------------------------------------------------------------

testConnId :: BankConnectionId
testConnId = unsafeBankConnectionId (read "55555555-5555-5555-5555-555555555555")

testAccountId :: AccountId
testAccountId = unsafeAccountId (read "66666666-6666-6666-6666-666666666666")

testEncryptedSecret :: EncryptedSecret
testEncryptedSecret =
  EncryptedSecret
    { keyVersion = 1,
      nonce = "bm9uY2U=",
      ciphertext = "Y2lwaGVy",
      authTag = "dGFn"
    }

testEncryptedSecret2 :: EncryptedSecret
testEncryptedSecret2 =
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
        provider = unsafeBankProviderId "monobank",
        name = "My Monobank",
        encryptedSecret = Just testEncryptedSecret,
        secretHint = Just "abc…xyz",
        enabled = True
      }

-- | A connection-added event for a file-only provider (no pull transport),
-- carrying no credential.
addFileOnlyConnEvent :: ConfigurationEvent
addFileOnlyConnEvent =
  BankConnectionAddedConfigurationEvent
    BankConnectionAdded
      { connectionId = testConnId,
        provider = unsafeBankProviderId "privatbank",
        name = "Privat File Import",
        encryptedSecret = Nothing,
        secretHint = Nothing,
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
        conn.provider `shouldBe` unsafeBankProviderId "monobank"
        conn.name `shouldBe` "My Monobank"
        conn.encryptedSecret `shouldBe` Just testEncryptedSecret
        conn.secretHint `shouldBe` Just "abc…xyz"
        conn.enabled `shouldBe` True
        conn.accountMap `shouldBe` Map.empty

  it "BankConnectionAdded for a file-only provider inserts a connection with no credential" $ do
    let config = applyEvents [createdEvent, addFileOnlyConnEvent]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> do
        conn.provider `shouldBe` unsafeBankProviderId "privatbank"
        conn.encryptedSecret `shouldBe` Nothing
        conn.secretHint `shouldBe` Nothing

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
        conn.encryptedSecret `shouldBe` Just testEncryptedSecret

  it "BankConnectionCredentialChanged updates encryptedSecret and secretHint" $ do
    let config =
          applyEvents
            [ createdEvent,
              addConnEvent,
              BankConnectionCredentialChangedConfigurationEvent
                BankConnectionCredentialChanged
                  { connectionId = testConnId,
                    encryptedSecret = testEncryptedSecret2,
                    secretHint = "new…hint"
                  }
            ]
    case Map.lookup testConnId config.banking.connections of
      Nothing -> expectationFailure "Connection should exist"
      Just conn -> do
        conn.encryptedSecret `shouldBe` Just testEncryptedSecret2
        conn.secretHint `shouldBe` Just "new…hint"

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
    let m = Map.singleton (unsafeExternalAccountId "ext-acc-1") testAccountId
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
