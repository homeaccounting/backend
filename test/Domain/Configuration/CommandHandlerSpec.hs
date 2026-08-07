{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.CommandHandlerSpec
-- Description : Unit tests for Configuration command handler
--
-- This module tests the Configuration aggregate command handler business logic.
--
-- Test Coverage:
--   - CreateConfiguration: Creation on fresh/already-created aggregate
--   - ChangeBaseCurrency: Currency change on created/uncreated aggregate
--   - ChangeDefaultCurrency: Currency change on created/uncreated aggregate
--   - AddDictionaryEntry: Adding entries, duplicate name rejection
--   - RenameDictionaryEntry: Renaming entries, missing dictionary/entry rejection
--   - RemoveDictionaryEntry: Removing entries, last entry rejection
module Domain.Configuration.CommandHandlerSpec (spec) where

import qualified Data.Map.Strict as Map
import Domain.Banking.Types (BankConnectionId, unsafeBankConnectionId, unsafeBankProviderId, unsafeExternalAccountId)
import Domain.Configuration
import Domain.Configuration.Defaults (expenseCategoryDictKind, incomeCategoryDictKind)
import Domain.Configuration.Dictionary (EntryRole (..))
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
import Test.Hspec
import Testkit.Generators ()
import Testkit.Helpers
import Prelude (head, read)

spec :: Spec
spec = do
  createConfigurationSpec
  changeBaseCurrencySpec
  changeDefaultCurrencySpec
  addDictionaryEntrySpec
  renameDictionaryEntrySpec
  removeDictionaryEntrySpec
  setDefaultIncomeCategorySpec
  setDefaultExpenseCategorySpec
  setDefaultAccountSpec
  setDefaultSubtypeAccountsSpec
  setBankProviderExpenseCategoryMapSpec
  setBankProviderContactMapSpec
  removeDictionaryEntryBankingGuardSpec
  addTreeGuardSpec
  moveTreeGuardSpec
  removeGroupGuardSpec
  addBankConnectionSpec
  bankConnectionMissingSpec
  setBankConnectionAccountMapSpec

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

-- | Entry IDs used as CategoryIds in banking tests
testCategoryId1 :: CategoryId
testCategoryId1 = mockDictionaryEntryId (read "66666666-6666-6666-6666-666666666666")

testCategoryId2 :: CategoryId
testCategoryId2 = mockDictionaryEntryId (read "77777777-7777-7777-7777-777777777777")

testUnknownCategoryId :: CategoryId
testUnknownCategoryId = mockDictionaryEntryId (read "99999999-9999-9999-9999-999999999999")

-- | Entry IDs used as ContactIds in banking tests
testContactId1 :: ContactId
testContactId1 = mockDictionaryEntryId (read "88888888-8888-8888-8888-888888888888")

testContactId2 :: ContactId
testContactId2 = mockDictionaryEntryId (read "dddddddd-dddd-dddd-dddd-dddddddddddd")

testUnknownContactId :: ContactId
testUnknownContactId = mockDictionaryEntryId (read "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")

testEntryName1 :: EntryName
testEntryName1 = mockEntryName "Food"

testEntryName2 :: EntryName
testEntryName2 = mockEntryName "Transport"

testEntryName3 :: EntryName
testEntryName3 = mockEntryName "Rent"

-- | A created configuration with System as creator
createdConfig :: Configuration
createdConfig =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          }
    ]

-- | A created configuration with one dictionary entry
configWithOneEntry :: Configuration
configWithOneEntry =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = testDictId,
            entryId = testEntryId1,
            name = testEntryName1,
            role = ItemRole,
            parentId = Nothing
          }
    ]

-- | A created configuration with two dictionary entries
configWithTwoEntries :: Configuration
configWithTwoEntries =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
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

-- | A created configuration with one income-category entry (testCategoryId1)
configWithIncomeEntry :: Configuration
configWithIncomeEntry =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = incomeCategoryDictKind,
            entryId = testCategoryId1,
            name = mockEntryName "Salary",
            role = ItemRole,
            parentId = Nothing
          }
    ]

-- | A created configuration with one expense-category entry (testCategoryId1)
configWithExpenseEntry :: Configuration
configWithExpenseEntry =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId1,
            name = mockEntryName "Food",
            role = ItemRole,
            parentId = Nothing
          }
    ]

-- | A created configuration with two expense-category entries (testCategoryId1, testCategoryId2)
configWithTwoExpenseEntries :: Configuration
configWithTwoExpenseEntries =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId1,
            name = mockEntryName "Food",
            role = ItemRole,
            parentId = Nothing
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId2,
            name = mockEntryName "Transport",
            role = ItemRole,
            parentId = Nothing
          }
    ]

-- | Config with two income entries, defaultIncomeCategory set to testCategoryId1.
-- Two entries ensure CannotRemoveLastEntry does not fire before the banking guard.
configWithDefaultIncomeCategory :: Configuration
configWithDefaultIncomeCategory =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = incomeCategoryDictKind,
            entryId = testCategoryId1,
            name = mockEntryName "Salary",
            role = ItemRole,
            parentId = Nothing
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = incomeCategoryDictKind,
            entryId = testCategoryId2,
            name = mockEntryName "Freelance",
            role = ItemRole,
            parentId = Nothing
          },
      DefaultIncomeCategorySetConfigurationEvent
        DefaultIncomeCategorySet
          { categoryId = testCategoryId1
          }
    ]

-- | Config with two expense entries, defaultExpenseCategory set to testCategoryId1.
-- Two entries ensure CannotRemoveLastEntry does not fire before the banking guard.
configWithDefaultExpenseCategory :: Configuration
configWithDefaultExpenseCategory =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId1,
            name = mockEntryName "Food",
            role = ItemRole,
            parentId = Nothing
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId2,
            name = mockEntryName "Transport",
            role = ItemRole,
            parentId = Nothing
          },
      DefaultExpenseCategorySetConfigurationEvent
        DefaultExpenseCategorySet
          { categoryId = testCategoryId1
          }
    ]

-- | Config with two expense entries, MCC map referencing testCategoryId1.
-- Two entries ensure CannotRemoveLastEntry does not fire before the banking guard.
configWithMccMapEntry :: Configuration
configWithMccMapEntry =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId1,
            name = mockEntryName "Food",
            role = ItemRole,
            parentId = Nothing
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = expenseCategoryDictKind,
            entryId = testCategoryId2,
            name = mockEntryName "Transport",
            role = ItemRole,
            parentId = Nothing
          },
      BankProviderExpenseCategoryMapSetConfigurationEvent
        BankProviderExpenseCategoryMapSet
          { mapping = Map.fromList [(mkByMcc (unsafeMcc 5411), testCategoryId1)]
          }
    ]

-- | A created configuration with one contact-dictionary entry (testContactId1)
configWithContactEntry :: Configuration
configWithContactEntry =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = DictKind.ContactKind,
            entryId = testContactId1,
            name = mockEntryName "Ivan",
            role = ItemRole,
            parentId = Nothing
          }
    ]

-- | A created configuration with two contact-dictionary entries (testContactId1, testContactId2)
configWithTwoContactEntries :: Configuration
configWithTwoContactEntries =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = DictKind.ContactKind,
            entryId = testContactId1,
            name = mockEntryName "Ivan",
            role = ItemRole,
            parentId = Nothing
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = DictKind.ContactKind,
            entryId = testContactId2,
            name = mockEntryName "Oksana",
            role = ItemRole,
            parentId = Nothing
          }
    ]

-- | Config with two contact entries, contact map referencing testContactId1.
-- Two entries ensure CannotRemoveLastEntry does not fire before the banking guard.
configWithContactMapEntry :: Configuration
configWithContactMapEntry =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = DictKind.ContactKind,
            entryId = testContactId1,
            name = mockEntryName "Ivan",
            role = ItemRole,
            parentId = Nothing
          },
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = DictKind.ContactKind,
            entryId = testContactId2,
            name = mockEntryName "Oksana",
            role = ItemRole,
            parentId = Nothing
          },
      BankProviderContactMapSetConfigurationEvent
        BankProviderContactMapSet
          { mapping = Map.fromList [(unsafeBankProviderContact "IVAN PETRENKO", testContactId1)]
          }
    ]

-- -----------------------------------------------------------------------------
-- CreateConfiguration Tests
-- -----------------------------------------------------------------------------

createConfigurationSpec :: Spec
createConfigurationSpec = describe "CreateConfiguration Command" $ do
  context "Given fresh aggregate (configurationDefault)" $ do
    describe "When creating configuration with valid data" $ do
      it "Then emits ConfigurationCreated event" $ do
        let config = configurationDefault
        let command =
              CreateConfigurationConfigurationCommand
                CreateConfiguration
                  { baseCurrency = UAH,
                    defaultCurrency = UAH,
                    createdBy = System
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              ConfigurationCreatedConfigurationEvent created -> do
                created.baseCurrency `shouldBe` UAH
                created.defaultCurrency `shouldBe` UAH
                created.createdBy `shouldBe` System
              _ -> expectationFailure "Expected ConfigurationCreated event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then created configuration has correct state" $ do
        let config = configurationDefault
        let command =
              CreateConfigurationConfigurationCommand
                CreateConfiguration
                  { baseCurrency = USD,
                    defaultCurrency = EUR,
                    createdBy = ClonedBy testUserId testConfigId
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            let newConfig = applyEvents events
            newConfig.baseCurrency `shouldBe` USD
            newConfig.defaultCurrency `shouldBe` EUR
            newConfig.createdBy `shouldBe` ClonedBy testUserId testConfigId
            newConfig.isCreated `shouldBe` True
            newConfig.dictionaries `shouldBe` Map.empty
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given already-created aggregate" $ do
    describe "When attempting to create again" $ do
      it "Then returns ConfigurationAlreadyExists error" $ do
        let config = createdConfig
        let command =
              CreateConfigurationConfigurationCommand
                CreateConfiguration
                  { baseCurrency = USD,
                    defaultCurrency = USD,
                    createdBy = System
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationAlreadyExists

-- -----------------------------------------------------------------------------
-- ChangeBaseCurrency Tests
-- -----------------------------------------------------------------------------

changeBaseCurrencySpec :: Spec
changeBaseCurrencySpec = describe "ChangeBaseCurrency Command" $ do
  context "Given created configuration" $ do
    describe "When changing base currency" $ do
      it "Then emits BaseCurrencyChanged event" $ do
        let config = createdConfig
        let command =
              ChangeBaseCurrencyConfigurationCommand
                ChangeBaseCurrency
                  { baseCurrency = USD
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              BaseCurrencyChangedConfigurationEvent changed ->
                changed.baseCurrency `shouldBe` USD
              _ -> expectationFailure "Expected BaseCurrencyChanged event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given uncreated aggregate" $ do
    describe "When attempting to change base currency" $ do
      it "Then returns ConfigurationNotCreated error" $ do
        let config = configurationDefault
        let command =
              ChangeBaseCurrencyConfigurationCommand
                ChangeBaseCurrency
                  { baseCurrency = USD
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationNotCreated

-- -----------------------------------------------------------------------------
-- ChangeDefaultCurrency Tests
-- -----------------------------------------------------------------------------

changeDefaultCurrencySpec :: Spec
changeDefaultCurrencySpec = describe "ChangeDefaultCurrency Command" $ do
  context "Given created configuration" $ do
    describe "When changing default currency" $ do
      it "Then emits DefaultCurrencyChanged event" $ do
        let config = createdConfig
        let command =
              ChangeDefaultCurrencyConfigurationCommand
                ChangeDefaultCurrency
                  { defaultCurrency = EUR
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DefaultCurrencyChangedConfigurationEvent changed ->
                changed.defaultCurrency `shouldBe` EUR
              _ -> expectationFailure "Expected DefaultCurrencyChanged event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given uncreated aggregate" $ do
    describe "When attempting to change default currency" $ do
      it "Then returns ConfigurationNotCreated error" $ do
        let config = configurationDefault
        let command =
              ChangeDefaultCurrencyConfigurationCommand
                ChangeDefaultCurrency
                  { defaultCurrency = EUR
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationNotCreated

-- -----------------------------------------------------------------------------
-- AddDictionaryEntry Tests
-- -----------------------------------------------------------------------------

addDictionaryEntrySpec :: Spec
addDictionaryEntrySpec = describe "AddDictionaryEntry Command" $ do
  context "Given created configuration with no dictionaries" $ do
    describe "When adding first entry to a dictionary" $ do
      it "Then emits DictionaryEntryAdded event" $ do
        let config = createdConfig
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryAddedConfigurationEvent added -> do
                added.dictionaryKind `shouldBe` testDictId
                added.entryId `shouldBe` testEntryId1
                added.name `shouldBe` testEntryName1
              _ -> expectationFailure "Expected DictionaryEntryAdded event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then auto-creates the dictionary with the entry" $ do
        let baseEvents =
              [ ConfigurationCreatedConfigurationEvent
                  ConfigurationCreated
                    { baseCurrency = UAH,
                      defaultCurrency = UAH,
                      createdBy = System
                    }
              ]
        let config = applyEvents baseEvents
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  }
        case handleConfigurationCommand config command of
          Right events -> do
            let newConfig = applyEvents (baseEvents <> events)
            Map.member testDictId newConfig.dictionaries `shouldBe` True
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given configuration with existing entry" $ do
    describe "When adding entry with duplicate name in same dictionary" $ do
      it "Then returns DuplicateEntryName error" $ do
        let config = configWithOneEntry
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId2,
                    -- Same name as existing entry
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left DuplicateEntryName

  context "Given entries grouped under different parents" $ do
    let parentA = mockDictionaryEntryId (read "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        parentB = mockDictionaryEntryId (read "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        childA = mockDictionaryEntryId (read "cccccccc-cccc-cccc-cccc-cccccccccccc")
        otherName = mockEntryName "Other"
        siblingConfig =
          applyEvents
            [ ConfigurationCreatedConfigurationEvent
                ConfigurationCreated
                  { baseCurrency = UAH,
                    defaultCurrency = UAH,
                    createdBy = System
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = parentA,
                    name = mockEntryName "Group A",
                    role = GroupRole,
                    parentId = Nothing
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = parentB,
                    name = mockEntryName "Group B",
                    role = GroupRole,
                    parentId = Nothing
                  },
              DictionaryEntryAddedConfigurationEvent
                DictionaryEntryAdded
                  { dictionaryKind = testDictId,
                    entryId = childA,
                    name = otherName,
                    role = ItemRole,
                    parentId = Just parentA
                  }
            ]
    describe "When adding a name that already exists under a different parent" $ do
      it "Then succeeds (uniqueness is scoped to siblings)" $ do
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = otherName,
                    role = ItemRole,
                    parentId = Just parentB
                  }
        handleConfigurationCommand siblingConfig command `shouldSatisfy` isRight

    describe "When adding a name that already exists under the same parent" $ do
      it "Then returns DuplicateEntryName error" $ do
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = otherName,
                    role = ItemRole,
                    parentId = Just parentA
                  }
        handleConfigurationCommand siblingConfig command `shouldBe` Left DuplicateEntryName

  context "Given uncreated aggregate" $ do
    describe "When attempting to add entry" $ do
      it "Then returns ConfigurationNotCreated error" $ do
        let config = configurationDefault
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1,
                    role = ItemRole,
                    parentId = Nothing
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationNotCreated

-- -----------------------------------------------------------------------------
-- RenameDictionaryEntry Tests
-- -----------------------------------------------------------------------------

renameDictionaryEntrySpec :: Spec
renameDictionaryEntrySpec = describe "RenameDictionaryEntry Command" $ do
  context "Given configuration with dictionary entries" $ do
    describe "When renaming an existing entry" $ do
      it "Then emits DictionaryEntryRenamed event" $ do
        let config = configWithOneEntry
        let command =
              RenameDictionaryEntryConfigurationCommand
                RenameDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryRenamedConfigurationEvent renamed -> do
                renamed.dictionaryKind `shouldBe` testDictId
                renamed.entryId `shouldBe` testEntryId1
                renamed.newName `shouldBe` testEntryName3
              _ -> expectationFailure "Expected DictionaryEntryRenamed event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When renaming to a duplicate name" $ do
      it "Then returns DuplicateEntryName error" $ do
        let config = configWithTwoEntries
        let command =
              RenameDictionaryEntryConfigurationCommand
                RenameDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName2 -- Name already used by entry 2
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left DuplicateEntryName

  context "Given configuration with no such dictionary" $ do
    describe "When renaming entry in missing dictionary" $ do
      it "Then returns DictionaryNotFound error" $ do
        let config = createdConfig
        let command =
              RenameDictionaryEntryConfigurationCommand
                RenameDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left DictionaryNotFound

  context "Given configuration with dictionary but missing entry" $ do
    describe "When renaming non-existent entry" $ do
      it "Then returns EntryNotFound error" $ do
        let config = configWithOneEntry
        let command =
              RenameDictionaryEntryConfigurationCommand
                RenameDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId2, -- This entry doesn't exist
                    newName = testEntryName3
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left EntryNotFound

  context "Given uncreated aggregate" $ do
    describe "When attempting to rename entry" $ do
      it "Then returns ConfigurationNotCreated error" $ do
        let config = configurationDefault
        let command =
              RenameDictionaryEntryConfigurationCommand
                RenameDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationNotCreated

-- -----------------------------------------------------------------------------
-- RemoveDictionaryEntry Tests
-- -----------------------------------------------------------------------------

removeDictionaryEntrySpec :: Spec
removeDictionaryEntrySpec = describe "RemoveDictionaryEntry Command" $ do
  context "Given configuration with two entries in a dictionary" $ do
    describe "When removing one entry" $ do
      it "Then emits DictionaryEntryRemoved event" $ do
        let config = configWithTwoEntries
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryRemovedConfigurationEvent removed -> do
                removed.dictionaryKind `shouldBe` testDictId
                removed.entryId `shouldBe` testEntryId1
              _ -> expectationFailure "Expected DictionaryEntryRemoved event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given configuration with one entry in a dictionary" $ do
    describe "When attempting to remove the last entry" $ do
      it "Then returns CannotRemoveLastEntry error" $ do
        let config = configWithOneEntry
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left CannotRemoveLastEntry

  context "Given configuration with no such dictionary" $ do
    describe "When removing entry from missing dictionary" $ do
      it "Then returns DictionaryNotFound error" $ do
        let config = createdConfig
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left DictionaryNotFound

  context "Given configuration with dictionary but missing entry" $ do
    describe "When removing non-existent entry" $ do
      it "Then returns EntryNotFound error" $ do
        let config = configWithTwoEntries
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = mockDictionaryEntryId (read "55555555-5555-5555-5555-555555555555")
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left EntryNotFound

  context "Given uncreated aggregate" $ do
    describe "When attempting to remove entry" $ do
      it "Then returns ConfigurationNotCreated error" $ do
        let config = configurationDefault
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationNotCreated

-- -----------------------------------------------------------------------------
-- SetDefaultIncomeCategory Tests
-- -----------------------------------------------------------------------------

setDefaultIncomeCategorySpec :: Spec
setDefaultIncomeCategorySpec = describe "SetDefaultIncomeCategory Command" $ do
  context "Given config whose income-category dictionary does NOT contain the categoryId" $ do
    describe "When issuing SetDefaultIncomeCategory" $ do
      it "Then returns an error" $ do
        let config = configWithExpenseEntry -- has expense entry, NOT income entry for testCategoryId1
        let command =
              SetDefaultIncomeCategoryConfigurationCommand
                SetDefaultIncomeCategory
                  { categoryId = testUnknownCategoryId
                  }
        let result = handleConfigurationCommand config command

        result `shouldSatisfy` isLeft

  context "Given config whose income-category dictionary contains the categoryId" $ do
    describe "When issuing SetDefaultIncomeCategory" $ do
      it "Then emits DefaultIncomeCategorySet event" $ do
        let config = configWithIncomeEntry
        let command =
              SetDefaultIncomeCategoryConfigurationCommand
                SetDefaultIncomeCategory
                  { categoryId = testCategoryId1
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DefaultIncomeCategorySetConfigurationEvent evt ->
                evt.categoryId `shouldBe` testCategoryId1
              _ -> expectationFailure "Expected DefaultIncomeCategorySet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- SetDefaultExpenseCategory Tests
-- -----------------------------------------------------------------------------

setDefaultExpenseCategorySpec :: Spec
setDefaultExpenseCategorySpec = describe "SetDefaultExpenseCategory Command" $ do
  context "Given config whose expense-category dictionary does NOT contain the categoryId" $ do
    describe "When issuing SetDefaultExpenseCategory" $ do
      it "Then returns an error" $ do
        let config = configWithIncomeEntry -- has income entry, NOT expense entry for unknown id
        let command =
              SetDefaultExpenseCategoryConfigurationCommand
                SetDefaultExpenseCategory
                  { categoryId = testUnknownCategoryId
                  }
        let result = handleConfigurationCommand config command

        result `shouldSatisfy` isLeft

  context "Given config whose expense-category dictionary contains the categoryId" $ do
    describe "When issuing SetDefaultExpenseCategory" $ do
      it "Then emits DefaultExpenseCategorySet event" $ do
        let config = configWithExpenseEntry
        let command =
              SetDefaultExpenseCategoryConfigurationCommand
                SetDefaultExpenseCategory
                  { categoryId = testCategoryId1
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DefaultExpenseCategorySetConfigurationEvent evt ->
                evt.categoryId `shouldBe` testCategoryId1
              _ -> expectationFailure "Expected DefaultExpenseCategorySet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- SetDefaultAccount / SetDefaultSubtypeAccounts Tests
-- -----------------------------------------------------------------------------

-- | The pure handler emits the account defaults unconditionally; account
-- existence/ownership is validated in the service layer, not here.
setDefaultAccountSpec :: Spec
setDefaultAccountSpec = describe "SetDefaultAccount Command" $ do
  context "Given a created configuration" $ do
    describe "When issuing SetDefaultAccount" $ do
      it "Then emits DefaultAccountSet event unconditionally" $ do
        let config = createdConfig
            command =
              SetDefaultAccountConfigurationCommand
                SetDefaultAccount {accountId = mockAccountId (read "66666666-6666-6666-6666-666666666666")}
            result = handleConfigurationCommand config command
        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DefaultAccountSetConfigurationEvent evt ->
                evt.accountId `shouldBe` mockAccountId (read "66666666-6666-6666-6666-666666666666")
              _ -> expectationFailure "Expected DefaultAccountSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

setDefaultSubtypeAccountsSpec :: Spec
setDefaultSubtypeAccountsSpec = describe "SetDefaultSubtypeAccounts Command" $ do
  context "Given a created configuration" $ do
    describe "When issuing SetDefaultSubtypeAccounts" $ do
      it "Then emits DefaultSubtypeAccountsSet event unconditionally" $ do
        let m = Map.singleton CashKind (mockAccountId (read "66666666-6666-6666-6666-666666666666"))
            config = createdConfig
            command =
              SetDefaultSubtypeAccountsConfigurationCommand
                SetDefaultSubtypeAccounts {subtypeAccounts = m}
            result = handleConfigurationCommand config command
        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DefaultSubtypeAccountsSetConfigurationEvent evt ->
                evt.subtypeAccounts `shouldBe` m
              _ -> expectationFailure "Expected DefaultSubtypeAccountsSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- SetBankProviderExpenseCategoryMap Tests
-- -----------------------------------------------------------------------------

setBankProviderExpenseCategoryMapSpec :: Spec
setBankProviderExpenseCategoryMapSpec = describe "SetBankProviderExpenseCategoryMap Command" $ do
  context "Given map referencing a CategoryId NOT in expense-category dictionary" $ do
    describe "When issuing SetBankProviderExpenseCategoryMap" $ do
      it "Then returns an error" $ do
        let config = configWithExpenseEntry -- testCategoryId1 in expense dict
        let command =
              SetBankProviderExpenseCategoryMapConfigurationCommand
                SetBankProviderExpenseCategoryMap
                  { mapping = Map.fromList [(mkByMcc (unsafeMcc 5411), testUnknownCategoryId)]
                  }
        let result = handleConfigurationCommand config command

        result `shouldSatisfy` isLeft

  context "Given map whose values are all in expense-category dictionary" $ do
    describe "When issuing SetBankProviderExpenseCategoryMap" $ do
      it "Then emits BankProviderExpenseCategoryMapSet event" $ do
        let config = configWithTwoExpenseEntries
        let testMapping = Map.fromList [(mkByMcc (unsafeMcc 5411), testCategoryId1), (mkByMcc (unsafeMcc 4111), testCategoryId2)]
        let command =
              SetBankProviderExpenseCategoryMapConfigurationCommand
                SetBankProviderExpenseCategoryMap
                  { mapping = testMapping
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              BankProviderExpenseCategoryMapSetConfigurationEvent evt ->
                evt.mapping `shouldBe` testMapping
              _ -> expectationFailure "Expected BankProviderExpenseCategoryMapSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given an empty map" $ do
    describe "When issuing SetBankProviderExpenseCategoryMap" $ do
      it "Then accepts empty map (signals cleared)" $ do
        let config = configWithExpenseEntry
        let command =
              SetBankProviderExpenseCategoryMapConfigurationCommand
                SetBankProviderExpenseCategoryMap
                  { mapping = Map.empty
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              BankProviderExpenseCategoryMapSetConfigurationEvent evt ->
                evt.mapping `shouldBe` Map.empty
              _ -> expectationFailure "Expected BankProviderExpenseCategoryMapSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- SetBankProviderContactMap Tests
-- -----------------------------------------------------------------------------

setBankProviderContactMapSpec :: Spec
setBankProviderContactMapSpec = describe "SetBankProviderContactMap Command" $ do
  context "Given map referencing a ContactId NOT in the contact dictionary" $ do
    describe "When issuing SetBankProviderContactMap" $ do
      it "Then returns an error" $ do
        let config = configWithContactEntry -- testContactId1 in contact dict
        let command =
              SetBankProviderContactMapConfigurationCommand
                SetBankProviderContactMap
                  { mapping = Map.fromList [(unsafeBankProviderContact "IVAN PETRENKO", testUnknownContactId)]
                  }
        let result = handleConfigurationCommand config command

        result `shouldSatisfy` isLeft

  context "Given map whose values are all in the contact dictionary" $ do
    describe "When issuing SetBankProviderContactMap" $ do
      it "Then emits BankProviderContactMapSet event" $ do
        let config = configWithTwoContactEntries
        let testMapping =
              Map.fromList
                [ (unsafeBankProviderContact "IVAN PETRENKO", testContactId1),
                  (unsafeBankProviderContact "OKSANA KOVAL", testContactId2)
                ]
        let command =
              SetBankProviderContactMapConfigurationCommand
                SetBankProviderContactMap
                  { mapping = testMapping
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              BankProviderContactMapSetConfigurationEvent evt ->
                evt.mapping `shouldBe` testMapping
              _ -> expectationFailure "Expected BankProviderContactMapSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given an empty map" $ do
    describe "When issuing SetBankProviderContactMap" $ do
      it "Then accepts empty map (signals cleared)" $ do
        let config = configWithContactEntry
        let command =
              SetBankProviderContactMapConfigurationCommand
                SetBankProviderContactMap
                  { mapping = Map.empty
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              BankProviderContactMapSetConfigurationEvent evt ->
                evt.mapping `shouldBe` Map.empty
              _ -> expectationFailure "Expected BankProviderContactMapSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- RemoveDictionaryEntry Banking Guard Tests
-- -----------------------------------------------------------------------------

removeDictionaryEntryBankingGuardSpec :: Spec
removeDictionaryEntryBankingGuardSpec = describe "RemoveDictionaryEntry banking guard" $ do
  context "Given entry set as the global defaultIncomeCategory" $ do
    describe "When removing that entry" $ do
      it "Then returns EntryIsGlobalDefault" $ do
        let config = configWithDefaultIncomeCategory
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = incomeCategoryDictKind,
                    entryId = testCategoryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left EntryIsGlobalDefault

  context "Given entry set as the global defaultExpenseCategory" $ do
    describe "When removing that entry" $ do
      it "Then returns an error" $ do
        let config = configWithDefaultExpenseCategory
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = expenseCategoryDictKind,
                    entryId = testCategoryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldSatisfy` isLeft

  context "Given entry referenced in banking.mccExpenseCategoryMap" $ do
    describe "When removing that entry" $ do
      it "Then returns an error" $ do
        let config = configWithMccMapEntry
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = expenseCategoryDictKind,
                    entryId = testCategoryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldSatisfy` isLeft

  context "Given entry referenced in banking.bankProviderContactMap" $ do
    describe "When removing that entry" $ do
      it "Then returns EntryIsInBankProviderContactMap" $ do
        let config = configWithContactMapEntry
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = DictKind.ContactKind,
                    entryId = testContactId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left EntryIsInBankProviderContactMap

  context "Given entry that is NOT a banking default nor in MCC map" $ do
    describe "When removing that entry (two entries exist)" $ do
      it "Then emits DictionaryEntryRemoved event" $ do
        -- testCategoryId1 is the default expense; testCategoryId2 is free
        let config =
              applyEvents
                [ ConfigurationCreatedConfigurationEvent
                    ConfigurationCreated
                      { baseCurrency = UAH,
                        defaultCurrency = UAH,
                        createdBy = System
                      },
                  DictionaryEntryAddedConfigurationEvent
                    DictionaryEntryAdded
                      { dictionaryKind = expenseCategoryDictKind,
                        entryId = testCategoryId1,
                        name = mockEntryName "Food",
                        role = ItemRole,
                        parentId = Nothing
                      },
                  DictionaryEntryAddedConfigurationEvent
                    DictionaryEntryAdded
                      { dictionaryKind = expenseCategoryDictKind,
                        entryId = testCategoryId2,
                        name = mockEntryName "Transport",
                        role = ItemRole,
                        parentId = Nothing
                      },
                  DefaultExpenseCategorySetConfigurationEvent
                    DefaultExpenseCategorySet
                      { categoryId = testCategoryId1
                      }
                ]
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = expenseCategoryDictKind,
                    entryId = testCategoryId2 -- the free entry
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryRemovedConfigurationEvent removed ->
                removed.entryId `shouldBe` testCategoryId2
              _ -> expectationFailure "Expected DictionaryEntryRemoved event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- Dictionary Tree Guard Tests (parent-exists, parent-is-group, depth, cycle)
-- -----------------------------------------------------------------------------

-- | Entry ids for a valid depth-2 fixture: a root group @grpA@ holding one item
-- child @grpAChild@, an empty root group @grpB@, and a standalone root item
-- @rootItem@ — all in the same dictionary. @treeAbsent@ is never present.
treeGrpA, treeGrpAChild, treeGrpB, treeRootItem, treeAbsent :: DictionaryEntryId
treeGrpA = mockDictionaryEntryId (read "a1000000-0000-0000-0000-000000000001")
treeGrpAChild = mockDictionaryEntryId (read "a1000000-0000-0000-0000-000000000002")
treeGrpB = mockDictionaryEntryId (read "b1000000-0000-0000-0000-000000000001")
treeRootItem = mockDictionaryEntryId (read "b1000000-0000-0000-0000-000000000002")
treeAbsent = mockDictionaryEntryId (read "c1000000-0000-0000-0000-000000000099")

-- | A config whose expense dictionary holds two root groups (one with an item
-- child, one empty) and a standalone root item — the maximal depth-2 shape.
treeConfig :: Configuration
treeConfig =
  applyEvents
    ( ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          }
        : map
          addEntry
          [ (treeGrpA, "GA", GroupRole, Nothing),
            (treeGrpAChild, "GAC", ItemRole, Just treeGrpA),
            (treeGrpB, "GB", GroupRole, Nothing),
            (treeRootItem, "RootItem", ItemRole, Nothing)
          ]
    )
  where
    addEntry (eid, nm, entryRole, parent) =
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = testDictId,
            entryId = eid,
            name = mockEntryName nm,
            role = entryRole,
            parentId = parent
          }

addTreeGuardSpec :: Spec
addTreeGuardSpec = describe "AddDictionaryEntry tree guards" $ do
  context "Given a parent id that does not exist" $ do
    describe "When adding an entry under it" $ do
      it "Then returns ParentEntryNotFound" $ do
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = mockEntryName "New",
                    role = ItemRole,
                    parentId = Just treeAbsent
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left ParentEntryNotFound

  context "Given a parent that is an item, not a group" $ do
    describe "When adding an entry under it" $ do
      it "Then returns ParentNotAGroup" $ do
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = mockEntryName "UnderItem",
                    role = ItemRole,
                    parentId = Just treeRootItem
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left ParentNotAGroup

  context "Given a group parent at the root" $ do
    describe "When adding a nested group under it" $ do
      it "Then returns MaxDepthExceeded (groups may not nest at depth 2)" $ do
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = mockEntryName "NestedGroup",
                    role = GroupRole,
                    parentId = Just treeGrpA
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left MaxDepthExceeded

  context "Given a group parent at the root" $ do
    describe "When adding an item child under it" $ do
      it "Then succeeds (a group's items sit at depth 2)" $ do
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = testEntryId1,
                    name = mockEntryName "OkItem",
                    role = ItemRole,
                    parentId = Just treeGrpB
                  }
        handleConfigurationCommand treeConfig command `shouldSatisfy` isRight

moveTreeGuardSpec :: Spec
moveTreeGuardSpec = describe "MoveDictionaryEntry tree guards" $ do
  context "Given a target entry that does not exist" $ do
    describe "When moving an absent entry" $ do
      it "Then returns EntryNotFound" $ do
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeAbsent,
                    newParentId = Nothing
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left EntryNotFound

  context "Given a new parent id that does not exist" $ do
    describe "When moving to a missing new parent" $ do
      it "Then returns ParentEntryNotFound" $ do
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeGrpAChild,
                    newParentId = Just treeAbsent
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left ParentEntryNotFound

  context "Given a move under an item parent" $ do
    describe "When moving a node under an item" $ do
      it "Then returns ParentNotAGroup" $ do
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeGrpB,
                    newParentId = Just treeRootItem
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left ParentNotAGroup

  context "Given a move onto itself" $ do
    describe "When moving a group under itself" $ do
      it "Then returns MoveWouldCreateCycle" $ do
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeGrpA,
                    newParentId = Just treeGrpA
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left MoveWouldCreateCycle

  context "Given a group moved under another group" $ do
    describe "When the resulting depth would exceed the limit" $ do
      it "Then returns MaxDepthExceeded (no nested groups at depth 2)" $ do
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeGrpA,
                    newParentId = Just treeGrpB
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left MaxDepthExceeded

  context "Given a valid move within the depth limit" $ do
    describe "When moving a root item under a root group" $ do
      it "Then succeeds" $ do
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeRootItem,
                    newParentId = Just treeGrpB
                  }
        handleConfigurationCommand treeConfig command `shouldSatisfy` isRight

  context "Given the new parent already has a child with the moved entry's name" $ do
    describe "When moving the entry under that parent" $ do
      it "Then returns DuplicateEntryName" $ do
        -- parentP already has a child "Dup"; entryToMove (also "Dup") lives under
        -- parentQ. Moving it under parentP collides with the existing sibling.
        let parentP = mockDictionaryEntryId (read "d0000000-0000-0000-0000-000000000001")
            parentQ = mockDictionaryEntryId (read "d0000000-0000-0000-0000-000000000002")
            existingDup = mockDictionaryEntryId (read "d0000000-0000-0000-0000-000000000003")
            entryToMove = mockDictionaryEntryId (read "d0000000-0000-0000-0000-000000000004")
            dupConfig =
              applyEvents
                ( ConfigurationCreatedConfigurationEvent
                    ConfigurationCreated
                      { baseCurrency = UAH,
                        defaultCurrency = UAH,
                        createdBy = System
                      }
                    : map
                      ( \(eid, nm, entryRole, parent) ->
                          DictionaryEntryAddedConfigurationEvent
                            DictionaryEntryAdded
                              { dictionaryKind = testDictId,
                                entryId = eid,
                                name = mockEntryName nm,
                                role = entryRole,
                                parentId = parent
                              }
                      )
                      [ (parentP, "P", GroupRole, Nothing),
                        (parentQ, "Q", GroupRole, Nothing),
                        (existingDup, "Dup", ItemRole, Just parentP),
                        (entryToMove, "Dup", ItemRole, Just parentQ)
                      ]
                )
        let command =
              MoveDictionaryEntryConfigurationCommand
                MoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = entryToMove,
                    newParentId = Just parentP
                  }
        handleConfigurationCommand dupConfig command `shouldBe` Left DuplicateEntryName

-- -----------------------------------------------------------------------------
-- RemoveDictionaryEntry Group Guard Tests (non-empty group rejection)
-- -----------------------------------------------------------------------------

removeGroupGuardSpec :: Spec
removeGroupGuardSpec = describe "RemoveDictionaryEntry group guard" $ do
  context "Given an entry that still has children" $ do
    describe "When removing that group" $ do
      it "Then returns GroupNotEmpty" $ do
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeGrpA
                  }
        handleConfigurationCommand treeConfig command `shouldBe` Left GroupNotEmpty

  context "Given a leaf entry with no children" $ do
    describe "When removing that leaf" $ do
      it "Then emits DictionaryEntryRemoved event" $ do
        let command =
              RemoveDictionaryEntryConfigurationCommand
                RemoveDictionaryEntry
                  { dictionaryKind = testDictId,
                    entryId = treeGrpAChild
                  }
        handleConfigurationCommand treeConfig command `shouldSatisfy` isRight

-- -----------------------------------------------------------------------------
-- Bank Connection Test Fixtures
-- -----------------------------------------------------------------------------

-- | A connection id present in fixtures.
testConnectionId1 :: BankConnectionId
testConnectionId1 = unsafeBankConnectionId (read "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")

-- | A second connection id.
testConnectionId2 :: BankConnectionId
testConnectionId2 = unsafeBankConnectionId (read "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")

-- | A connection id that is never present.
testMissingConnectionId :: BankConnectionId
testMissingConnectionId = unsafeBankConnectionId (read "cccccccc-cccc-cccc-cccc-cccccccccccc")

testAccountId1 :: AccountId
testAccountId1 = mockAccountId (read "d1111111-1111-1111-1111-111111111111")

testAccountId2 :: AccountId
testAccountId2 = mockAccountId (read "d2222222-2222-2222-2222-222222222222")

-- | A deterministic encrypted-secret value for fixtures (opaque to the handler).
testEncryptedSecret :: EncryptedSecret
testEncryptedSecret =
  EncryptedSecret
    { keyVersion = 1,
      nonce = "bm9uY2U=",
      ciphertext = "Y2lwaGVy",
      authTag = "dGFn"
    }

-- | A created config with one bank connection (testConnectionId1), no account map.
configWithConnection :: Configuration
configWithConnection =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      BankConnectionAddedConfigurationEvent
        BankConnectionAdded
          { connectionId = testConnectionId1,
            provider = unsafeBankProviderId "monobank",
            name = "Mono",
            encryptedSecret = Just testEncryptedSecret,
            secretHint = Just "1234",
            enabled = True
          }
    ]

-- | A created config with two connections; connection 2 already maps an external
-- account to testAccountId1.
configWithTwoConnections :: Configuration
configWithTwoConnections =
  applyEvents
    [ ConfigurationCreatedConfigurationEvent
        ConfigurationCreated
          { baseCurrency = UAH,
            defaultCurrency = UAH,
            createdBy = System
          },
      BankConnectionAddedConfigurationEvent
        BankConnectionAdded
          { connectionId = testConnectionId1,
            provider = unsafeBankProviderId "monobank",
            name = "Mono A",
            encryptedSecret = Just testEncryptedSecret,
            secretHint = Just "1111",
            enabled = True
          },
      BankConnectionAddedConfigurationEvent
        BankConnectionAdded
          { connectionId = testConnectionId2,
            provider = unsafeBankProviderId "monobank",
            name = "Mono B",
            encryptedSecret = Just testEncryptedSecret,
            secretHint = Just "2222",
            enabled = True
          },
      BankConnectionAccountMapSetConfigurationEvent
        BankConnectionAccountMapSet
          { connectionId = testConnectionId2,
            accountMap = Map.fromList [(unsafeExternalAccountId "ext-b", testAccountId1)]
          }
    ]

-- -----------------------------------------------------------------------------
-- AddBankConnection Tests
-- -----------------------------------------------------------------------------

addBankConnectionSpec :: Spec
addBankConnectionSpec = describe "AddBankConnection Command" $ do
  context "Given a created configuration" $ do
    describe "When adding a bank connection with a credential" $ do
      it "Then emits BankConnectionAdded event" $ do
        let config = createdConfig
        let command =
              AddBankConnectionConfigurationCommand
                AddBankConnection
                  { connectionId = testConnectionId1,
                    provider = unsafeBankProviderId "monobank",
                    name = "Mono",
                    encryptedSecret = Just testEncryptedSecret,
                    secretHint = Just "1234",
                    enabled = True
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              BankConnectionAddedConfigurationEvent evt -> do
                evt.connectionId `shouldBe` testConnectionId1
                evt.secretHint `shouldBe` Just "1234"
                evt.enabled `shouldBe` True
              _ -> expectationFailure "Expected BankConnectionAdded event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When adding a bank connection for a file-only provider with no credential" $ do
      it "Then succeeds and projects a connection with no stored credential" $ do
        let baseEvents =
              [ ConfigurationCreatedConfigurationEvent
                  ConfigurationCreated
                    { baseCurrency = UAH,
                      defaultCurrency = UAH,
                      createdBy = System
                    }
              ]
        let config = applyEvents baseEvents
        let command =
              AddBankConnectionConfigurationCommand
                AddBankConnection
                  { connectionId = testConnectionId1,
                    provider = unsafeBankProviderId "privatbank",
                    name = "Privat File Import",
                    encryptedSecret = Nothing,
                    secretHint = Nothing,
                    enabled = True
                  }
        case handleConfigurationCommand config command of
          Right events -> do
            case head events of
              BankConnectionAddedConfigurationEvent evt -> do
                evt.encryptedSecret `shouldBe` Nothing
                evt.secretHint `shouldBe` Nothing
              _ -> expectationFailure "Expected BankConnectionAdded event"
            let newConfig = applyEvents (baseEvents <> events)
            case Map.lookup testConnectionId1 newConfig.banking.connections of
              Nothing -> expectationFailure "Connection should exist"
              Just conn -> do
                conn.encryptedSecret `shouldBe` Nothing
                conn.secretHint `shouldBe` Nothing
                conn.provider `shouldBe` unsafeBankProviderId "privatbank"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- Missing-connection rejection tests (rename/credential/enabled/map/remove)
-- -----------------------------------------------------------------------------

bankConnectionMissingSpec :: Spec
bankConnectionMissingSpec = describe "Bank connection commands on a missing connection" $ do
  context "Given a config without the target connection" $ do
    describe "When renaming the connection" $ do
      it "Then returns Left BankConnectionNotFound" $ do
        let command =
              RenameBankConnectionConfigurationCommand
                RenameBankConnection
                  { connectionId = testMissingConnectionId,
                    name = "New name"
                  }
        handleConfigurationCommand configWithConnection command
          `shouldBe` Left BankConnectionNotFound

    describe "When changing the credential" $ do
      it "Then returns Left BankConnectionNotFound" $ do
        let command =
              ChangeBankConnectionCredentialConfigurationCommand
                ChangeBankConnectionCredential
                  { connectionId = testMissingConnectionId,
                    encryptedSecret = testEncryptedSecret,
                    secretHint = "9999"
                  }
        handleConfigurationCommand configWithConnection command
          `shouldBe` Left BankConnectionNotFound

    describe "When setting enabled" $ do
      it "Then returns Left BankConnectionNotFound" $ do
        let command =
              SetBankConnectionEnabledConfigurationCommand
                SetBankConnectionEnabled
                  { connectionId = testMissingConnectionId,
                    enabled = False
                  }
        handleConfigurationCommand configWithConnection command
          `shouldBe` Left BankConnectionNotFound

    describe "When setting the account map" $ do
      it "Then returns Left BankConnectionNotFound" $ do
        let command =
              SetBankConnectionAccountMapConfigurationCommand
                SetBankConnectionAccountMap
                  { connectionId = testMissingConnectionId,
                    accountMap = Map.fromList [(unsafeExternalAccountId "ext-1", testAccountId1)]
                  }
        handleConfigurationCommand configWithConnection command
          `shouldBe` Left BankConnectionNotFound

    describe "When removing the connection" $ do
      it "Then returns Left BankConnectionNotFound" $ do
        let command =
              RemoveBankConnectionConfigurationCommand
                RemoveBankConnection
                  { connectionId = testMissingConnectionId
                  }
        handleConfigurationCommand configWithConnection command
          `shouldBe` Left BankConnectionNotFound

  context "Given a config WITH the target connection" $ do
    describe "When renaming the connection" $ do
      it "Then emits BankConnectionRenamed event" $ do
        let command =
              RenameBankConnectionConfigurationCommand
                RenameBankConnection
                  { connectionId = testConnectionId1,
                    name = "Renamed"
                  }
        case handleConfigurationCommand configWithConnection command of
          Right events -> case head events of
            BankConnectionRenamedConfigurationEvent evt -> do
              evt.connectionId `shouldBe` testConnectionId1
              evt.name `shouldBe` "Renamed"
            _ -> expectationFailure "Expected BankConnectionRenamed event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When changing the credential" $ do
      it "Then emits BankConnectionCredentialChanged event" $ do
        let command =
              ChangeBankConnectionCredentialConfigurationCommand
                ChangeBankConnectionCredential
                  { connectionId = testConnectionId1,
                    encryptedSecret = testEncryptedSecret,
                    secretHint = "9999"
                  }
        case handleConfigurationCommand configWithConnection command of
          Right events -> case head events of
            BankConnectionCredentialChangedConfigurationEvent evt -> do
              evt.connectionId `shouldBe` testConnectionId1
              evt.secretHint `shouldBe` "9999"
            _ -> expectationFailure "Expected BankConnectionCredentialChanged event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When setting enabled" $ do
      it "Then emits BankConnectionEnabledSet event" $ do
        let command =
              SetBankConnectionEnabledConfigurationCommand
                SetBankConnectionEnabled
                  { connectionId = testConnectionId1,
                    enabled = False
                  }
        case handleConfigurationCommand configWithConnection command of
          Right events -> case head events of
            BankConnectionEnabledSetConfigurationEvent evt -> do
              evt.connectionId `shouldBe` testConnectionId1
              evt.enabled `shouldBe` False
            _ -> expectationFailure "Expected BankConnectionEnabledSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When removing the connection" $ do
      it "Then emits BankConnectionRemoved event" $ do
        let command =
              RemoveBankConnectionConfigurationCommand
                RemoveBankConnection
                  { connectionId = testConnectionId1
                  }
        case handleConfigurationCommand configWithConnection command of
          Right events -> case head events of
            BankConnectionRemovedConfigurationEvent evt ->
              evt.connectionId `shouldBe` testConnectionId1
            _ -> expectationFailure "Expected BankConnectionRemoved event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

-- -----------------------------------------------------------------------------
-- SetBankConnectionAccountMap Tests
-- -----------------------------------------------------------------------------

setBankConnectionAccountMapSpec :: Spec
setBankConnectionAccountMapSpec = describe "SetBankConnectionAccountMap Command" $ do
  context "Given a map referencing an account already used by another connection" $ do
    describe "When setting the account map" $ do
      it "Then returns Left BankConnectionAccountConflict" $ do
        -- connection 2 already maps testAccountId1; connection 1 tries to map it too
        let command =
              SetBankConnectionAccountMapConfigurationCommand
                SetBankConnectionAccountMap
                  { connectionId = testConnectionId1,
                    accountMap = Map.fromList [(unsafeExternalAccountId "ext-a", testAccountId1)]
                  }
        handleConfigurationCommand configWithTwoConnections command
          `shouldBe` Left BankConnectionAccountConflict

  context "Given a map whose accounts are not used by another connection" $ do
    describe "When setting the account map" $ do
      it "Then emits BankConnectionAccountMapSet event" $ do
        let testMap = Map.fromList [(unsafeExternalAccountId "ext-a", testAccountId2)]
        let command =
              SetBankConnectionAccountMapConfigurationCommand
                SetBankConnectionAccountMap
                  { connectionId = testConnectionId1,
                    accountMap = testMap
                  }
        case handleConfigurationCommand configWithTwoConnections command of
          Right events -> case head events of
            BankConnectionAccountMapSetConfigurationEvent evt -> do
              evt.connectionId `shouldBe` testConnectionId1
              evt.accountMap `shouldBe` testMap
            _ -> expectationFailure "Expected BankConnectionAccountMapSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given the same connection re-maps the account it already owns" $ do
    describe "When setting the account map on connection 2 with its own account" $ do
      it "Then does NOT conflict and emits the event" $ do
        let testMap = Map.fromList [(unsafeExternalAccountId "ext-b", testAccountId1)]
        let command =
              SetBankConnectionAccountMapConfigurationCommand
                SetBankConnectionAccountMap
                  { connectionId = testConnectionId2,
                    accountMap = testMap
                  }
        case handleConfigurationCommand configWithTwoConnections command of
          Right events -> case head events of
            BankConnectionAccountMapSetConfigurationEvent evt ->
              evt.accountMap `shouldBe` testMap
            _ -> expectationFailure "Expected BankConnectionAccountMapSet event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err
