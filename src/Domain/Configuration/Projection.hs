{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Configuration.Projection
-- Description : Projection for rebuilding Configuration aggregate state from events
--
-- This module defines the Configuration aggregate state and how it is reconstructed
-- from the event stream. The projection implements event sourcing by folding
-- events over an initial state to produce the current state.
module Domain.Configuration.Projection
  ( -- * Configuration Aggregate
    Configuration (..),

    -- * Banking Sub-record
    BankingConfiguration (defaultIncomeCategory, defaultExpenseCategory, mccExpenseCategoryMap),
    emptyBankingConfiguration,

    -- * Event Sum Type
    ConfigurationEvent (..),

    -- * Projection
    configurationProjection,

    -- * Helper Functions
    configurationDefault,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Domain.Configuration.Events
  ( BankingDefaultExpenseCategorySet (..),
    BankingDefaultIncomeCategorySet (..),
    BankingMccExpenseCategoryMapSet (..),
    BaseCurrencyChanged (..),
    BooksClosedThroughSet (..),
    ConfigurationCreated (..),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRemoved (..),
    DictionaryEntryRenamed (..),
    configurationEvents,
  )
import Domain.Core.Types
  ( CategoryId,
    CreatedBy (..),
    Currency (..),
    Dictionary (..),
    DictionaryEntry (..),
    DictionaryId,
    EntryName,
    MCC,
  )
import Eventium (Projection (..))
import Eventium.TH.SumType (SumTypeTagOptions (..), constructSumType, defaultSumTypeOptions, withTagOptions)

-- -----------------------------------------------------------------------------
-- Configuration Aggregate State
-- -----------------------------------------------------------------------------

-- | Banking-specific configuration derived from banking-related events.
--
-- This sub-record collects all bank-import settings in one place so the
-- main 'Configuration' record stays readable. The field is empty on every
-- projection that has not yet received any banking events.
data BankingConfiguration = BankingConfiguration
  { -- | Default category for income transactions when none is inferred from MCC
    defaultIncomeCategory :: !(Maybe CategoryId),
    -- | Default category for expense transactions when none is inferred from MCC
    defaultExpenseCategory :: !(Maybe CategoryId),
    -- | Mapping from MCC codes to expense category IDs for automatic categorisation
    mccExpenseCategoryMap :: !(Map MCC CategoryId)
  }
  deriving (Show, Eq)

-- | The empty banking configuration used as the initial state.
emptyBankingConfiguration :: BankingConfiguration
emptyBankingConfiguration =
  BankingConfiguration
    { defaultIncomeCategory = Nothing,
      defaultExpenseCategory = Nothing,
      mccExpenseCategoryMap = Map.empty
    }

-- | The Configuration aggregate state.
--
-- This represents the current state of a configuration, reconstructed from its
-- event history. The state is immutable and can only be changed by applying
-- events through the projection.
--
-- Fields:
--   - baseCurrency: The base currency for reporting
--   - defaultCurrency: The default currency for new accounts
--   - dictionaries: Map of dictionary IDs to dictionaries
--   - banking: Banking-specific configuration (empty until banking events arrive)
--   - createdBy: Who created this configuration
--   - isCreated: Whether the configuration has been created
data Configuration = Configuration
  { -- | Base currency for reporting
    baseCurrency :: Currency,
    -- | Default currency for new accounts
    defaultCurrency :: Currency,
    -- | Map of dictionaries keyed by DictionaryId
    dictionaries :: Map DictionaryId Dictionary,
    -- | Banking-specific configuration
    banking :: BankingConfiguration,
    -- | Who created this configuration
    createdBy :: CreatedBy,
    -- | Whether the configuration has been created (initial event received)
    isCreated :: Bool,
    -- | Books-closed-through cutoff. 'Nothing' until 'CloseBooksThrough' has
    -- been accepted at least once. Advances monotonically.
    booksClosedThrough :: Maybe UTCTime
  }
  deriving (Show, Eq)

-- | Default initial state for a Configuration aggregate.
--
-- This represents an uninitialized configuration before the ConfigurationCreated
-- event has been applied. It serves as the seed for the projection.
configurationDefault :: Configuration
configurationDefault =
  Configuration
    { baseCurrency = USD,
      defaultCurrency = USD,
      dictionaries = Map.empty,
      banking = emptyBankingConfiguration,
      createdBy = System,
      isCreated = False,
      booksClosedThrough = Nothing
    }

-- -----------------------------------------------------------------------------
-- Event Sum Type Construction
-- -----------------------------------------------------------------------------

-- | Generate the ConfigurationEvent sum type from individual event types.
--
-- This Template Haskell splice creates:
--   data ConfigurationEvent
--     = ConfigurationCreatedConfigurationEvent ConfigurationCreated
--     | BaseCurrencyChangedConfigurationEvent BaseCurrencyChanged
--     | DefaultCurrencyChangedConfigurationEvent DefaultCurrencyChanged
--     | DictionaryEntryAddedConfigurationEvent DictionaryEntryAdded
--     | DictionaryEntryRenamedConfigurationEvent DictionaryEntryRenamed
--     | DictionaryEntryRemovedConfigurationEvent DictionaryEntryRemoved
constructSumType
  "ConfigurationEvent"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  configurationEvents

-- Derive Show and Eq instances for the generated ConfigurationEvent type
deriving instance Show ConfigurationEvent

deriving instance Eq ConfigurationEvent

-- -----------------------------------------------------------------------------
-- Event Handlers
-- -----------------------------------------------------------------------------

-- | Handle an event and update the configuration state.
handleConfigurationEvent :: Configuration -> ConfigurationEvent -> Configuration
handleConfigurationEvent config (ConfigurationCreatedConfigurationEvent ConfigurationCreated {..}) =
  config
    { baseCurrency = baseCurrency,
      defaultCurrency = defaultCurrency,
      createdBy = createdBy,
      isCreated = True
    }
handleConfigurationEvent Configuration {..} (BaseCurrencyChangedConfigurationEvent evt) =
  Configuration
    { baseCurrency = evt.baseCurrency,
      defaultCurrency = defaultCurrency,
      dictionaries = dictionaries,
      banking = banking,
      createdBy = createdBy,
      isCreated = isCreated,
      booksClosedThrough = booksClosedThrough
    }
handleConfigurationEvent Configuration {..} (DefaultCurrencyChangedConfigurationEvent evt) =
  Configuration
    { baseCurrency = baseCurrency,
      defaultCurrency = evt.defaultCurrency,
      dictionaries = dictionaries,
      banking = banking,
      createdBy = createdBy,
      isCreated = isCreated,
      booksClosedThrough = booksClosedThrough
    }
handleConfigurationEvent config (DictionaryEntryAddedConfigurationEvent DictionaryEntryAdded {..}) =
  let newEntry = DictionaryEntry {entryId = entryId, name = name}
      updatedDicts =
        Map.alter
          ( \case
              Nothing -> Just (Dictionary {entries = [newEntry]})
              Just dict -> Just dict {entries = dict.entries ++ [newEntry]}
          )
          dictionaryId
          config.dictionaries
   in config {dictionaries = updatedDicts}
handleConfigurationEvent config (DictionaryEntryRenamedConfigurationEvent DictionaryEntryRenamed {..}) =
  let renameEntry :: EntryName -> DictionaryEntry -> DictionaryEntry
      renameEntry n entry
        | entry.entryId == entryId = DictionaryEntry {entryId = entry.entryId, name = n}
        | otherwise = entry
      updatedDicts =
        Map.adjust
          (\dict -> dict {entries = map (renameEntry newName) dict.entries})
          dictionaryId
          config.dictionaries
   in config {dictionaries = updatedDicts}
handleConfigurationEvent config (DictionaryEntryRemovedConfigurationEvent DictionaryEntryRemoved {..}) =
  let updatedDicts =
        Map.adjust
          (\dict -> dict {entries = filter (\e -> e.entryId /= entryId) dict.entries})
          dictionaryId
          config.dictionaries
   in config {dictionaries = updatedDicts}
handleConfigurationEvent config (BankingDefaultIncomeCategorySetConfigurationEvent evt) =
  config {banking = config.banking {defaultIncomeCategory = Just evt.categoryId}}
handleConfigurationEvent config (BankingDefaultExpenseCategorySetConfigurationEvent evt) =
  config {banking = config.banking {defaultExpenseCategory = Just evt.categoryId}}
handleConfigurationEvent config (BankingMccExpenseCategoryMapSetConfigurationEvent evt) =
  config {banking = config.banking {mccExpenseCategoryMap = evt.mapping}}
handleConfigurationEvent config (BooksClosedThroughSetConfigurationEvent evt) =
  config {booksClosedThrough = Just evt.closedThrough}

-- -----------------------------------------------------------------------------
-- Projection Definition
-- -----------------------------------------------------------------------------

-- | The configuration projection that rebuilds aggregate state from events.
configurationProjection :: Projection Configuration ConfigurationEvent
configurationProjection = Projection configurationDefault handleConfigurationEvent
