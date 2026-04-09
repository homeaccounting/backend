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
import Prelude (head, read, (!!))

spec :: Spec
spec = do
  configurationCreatedSpec
  baseCurrencyChangedSpec
  defaultCurrencyChangedSpec
  dictionaryEntryAddedSpec
  dictionaryEntryRenamedSpec
  dictionaryEntryRemovedSpec

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
