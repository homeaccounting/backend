{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Configuration.CommandHandler
-- Description : Command handler for the Configuration aggregate
--
-- This module implements the command handler that validates configuration commands
-- against the current aggregate state and emits appropriate events.
--
-- Business Rules Enforced:
--   - CreateConfiguration: Cannot create if already created
--   - ChangeBaseCurrency: Configuration must exist
--   - ChangeDefaultCurrency: Configuration must exist
--   - AddDictionaryEntry: Configuration must exist, no duplicate entry names in same dictionary
--   - RenameDictionaryEntry: Configuration must exist, dictionary and entry must exist, no duplicate names
--   - RemoveDictionaryEntry: Configuration must exist, dictionary and entry must exist, cannot remove last entry
module Domain.Configuration.CommandHandler
  ( -- * Command Sum Type
    ConfigurationCommand (..),

    -- * Command Errors
    ConfigurationError (..),

    -- * Command Handler
    configurationCommandHandler,

    -- * Handler Function (exported for testing)
    handleConfigurationCommand,
  )
where

import qualified Data.Map.Strict as Map
import Domain.Configuration.Commands
import Domain.Configuration.Events
import Domain.Configuration.Projection
import Domain.Core.Types (Dictionary (..), DictionaryEntry (..), DictionaryEntryId, DictionaryId, EntryName)
import Eventium (CommandHandler (..))
import Eventium.TH.SumType (SumTypeTagOptions (AppendTypeNameToTags), constructSumType, defaultSumTypeOptions, withTagOptions)

-- -----------------------------------------------------------------------------
-- Command Errors
-- -----------------------------------------------------------------------------

-- | Errors that can occur when handling configuration commands.
data ConfigurationError
  = ConfigurationAlreadyExists
  | ConfigurationNotCreated
  | DictionaryNotFound
  | EntryNotFound
  | DuplicateEntryName
  | CannotRemoveLastEntry
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Command Sum Type Construction
-- -----------------------------------------------------------------------------

-- | Generate the ConfigurationCommand sum type from individual command types.
constructSumType
  "ConfigurationCommand"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  configurationCommands

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Check if a dictionary exists in the configuration.
dictionaryExists :: DictionaryId -> Configuration -> Bool
dictionaryExists dictId config = Map.member dictId config.dictionaries

-- | Check if an entry exists in a dictionary.
entryExists :: DictionaryEntryId -> DictionaryId -> Configuration -> Bool
entryExists eid dictId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.entryId == eid) dict.entries

-- | Check if a dictionary already has an entry with the given name.
hasDuplicateName :: EntryName -> DictionaryId -> Configuration -> Bool
hasDuplicateName ename dictId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.name == ename) dict.entries

-- | Check if an entry is the last entry in a dictionary.
isLastEntry :: DictionaryId -> Configuration -> Bool
isLastEntry dictId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> length dict.entries == 1

-- -----------------------------------------------------------------------------
-- Command Handler Function
-- -----------------------------------------------------------------------------

-- | Handle a configuration command and produce events.
--
-- This function implements the business logic for validating commands against
-- the current aggregate state. It is pure and deterministic.
handleConfigurationCommand :: Configuration -> ConfigurationCommand -> Either ConfigurationError [ConfigurationEvent]
-- Handle CreateConfiguration command
handleConfigurationCommand config (CreateConfigurationConfigurationCommand CreateConfiguration {..})
  | config.isCreated = Left ConfigurationAlreadyExists
  | otherwise =
      Right
        [ ConfigurationCreatedConfigurationEvent
            ConfigurationCreated
              { baseCurrency = baseCurrency,
                defaultCurrency = defaultCurrency,
                createdBy = createdBy
              }
        ]
-- Handle ChangeBaseCurrency command
handleConfigurationCommand config (ChangeBaseCurrencyConfigurationCommand ChangeBaseCurrency {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      Right
        [ BaseCurrencyChangedConfigurationEvent
            BaseCurrencyChanged
              { baseCurrency = baseCurrency
              }
        ]
-- Handle ChangeDefaultCurrency command
handleConfigurationCommand config (ChangeDefaultCurrencyConfigurationCommand ChangeDefaultCurrency {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      Right
        [ DefaultCurrencyChangedConfigurationEvent
            DefaultCurrencyChanged
              { defaultCurrency = defaultCurrency
              }
        ]
-- Handle AddDictionaryEntry command
handleConfigurationCommand config (AddDictionaryEntryConfigurationCommand AddDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | hasDuplicateName name dictionaryId config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryAddedConfigurationEvent
            DictionaryEntryAdded
              { dictionaryId = dictionaryId,
                entryId = entryId,
                name = name
              }
        ]
-- Handle RenameDictionaryEntry command
handleConfigurationCommand config (RenameDictionaryEntryConfigurationCommand RenameDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryId config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryId config) = Left EntryNotFound
  | hasDuplicateName newName dictionaryId config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryRenamedConfigurationEvent
            DictionaryEntryRenamed
              { dictionaryId = dictionaryId,
                entryId = entryId,
                newName = newName
              }
        ]
-- Handle RemoveDictionaryEntry command
handleConfigurationCommand config (RemoveDictionaryEntryConfigurationCommand RemoveDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryId config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryId config) = Left EntryNotFound
  | isLastEntry dictionaryId config = Left CannotRemoveLastEntry
  | otherwise =
      Right
        [ DictionaryEntryRemovedConfigurationEvent
            DictionaryEntryRemoved
              { dictionaryId = dictionaryId,
                entryId = entryId
              }
        ]

-- -----------------------------------------------------------------------------
-- Command Handler
-- -----------------------------------------------------------------------------

-- | The configuration command handler for eventium integration.
configurationCommandHandler :: CommandHandler Configuration ConfigurationEvent ConfigurationCommand ConfigurationError
configurationCommandHandler = CommandHandler handleConfigurationCommand configurationProjection
