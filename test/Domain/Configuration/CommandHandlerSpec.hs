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

import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import Domain.Configuration
import Domain.Configuration.Events
  ( ConfigurationCreated (..),
  )
import Domain.Core.Types
import Eventium (latestProjection)
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
          { dictionaryId = testDictId,
            entryId = testEntryId1,
            name = testEntryName1
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
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryAddedConfigurationEvent added -> do
                added.dictionaryId `shouldBe` testDictId
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
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
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
                  { dictionaryId = testDictId,
                    entryId = testEntryId2,
                    name = testEntryName1 -- Same name as existing entry
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left DuplicateEntryName

  context "Given uncreated aggregate" $ do
    describe "When attempting to add entry" $ do
      it "Then returns ConfigurationNotCreated error" $ do
        let config = configurationDefault
        let command =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    name = testEntryName1
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
                  { dictionaryId = testDictId,
                    entryId = testEntryId1,
                    newName = testEntryName3
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryRenamedConfigurationEvent renamed -> do
                renamed.dictionaryId `shouldBe` testDictId
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
                    entryId = testEntryId1
                  }
        let result = handleConfigurationCommand config command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              DictionaryEntryRemovedConfigurationEvent removed -> do
                removed.dictionaryId `shouldBe` testDictId
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
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
                  { dictionaryId = testDictId,
                    entryId = testEntryId1
                  }
        let result = handleConfigurationCommand config command

        result `shouldBe` Left ConfigurationNotCreated
