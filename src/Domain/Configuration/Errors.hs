{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Domain.Configuration.Errors
-- Description : Error types specific to the Configuration aggregate
--
-- This module defines error types that can occur during configuration operations.
-- These errors represent business rule violations or invalid states that
-- prevent commands from being executed.
--
-- Error Types:
--   - ConfigurationNotFound: Configuration does not exist in the system
--   - DictionaryNotFound: Dictionary does not exist in the configuration
--   - EntryNotFound: Entry does not exist in the dictionary
--   - DuplicateEntryName: Entry name already exists in the dictionary
--   - CannotRemoveLastEntry: Cannot remove the last entry from a dictionary
--
-- These errors are used at the API layer to provide meaningful feedback
-- to clients.
--
-- Usage Context:
--   - API Layer: Convert validation failures to errors for HTTP responses
--   - Query Side: Report errors when configurations cannot be found
--   - Service Layer: Business rule violation reporting
module Domain.Configuration.Errors
  ( -- * Configuration Error Types
    ConfigurationError (..),

    -- * Error Constructors
    mkConfigurationNotFound,
    mkDictionaryNotFound,
    mkEntryNotFound,
    mkDuplicateEntryName,
    mkCannotRemoveLastEntry,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Domain.Core.Types (ConfigurationId, DictionaryEntryId, DictionaryId, EntryName)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Configuration Error Types
-- -----------------------------------------------------------------------------

-- | Errors specific to configuration operations.
--
-- These errors represent violations of business rules or invalid states
-- in configuration operations. They are typically used at the API layer to
-- provide meaningful error responses to clients.
data ConfigurationError
  = -- | Configuration not found by ID
    ConfigurationNotFound
      { -- | The configuration ID that was not found
        configurationNotFoundId :: ConfigurationId
      }
  | -- | Dictionary not found within a configuration
    DictionaryNotFound
      { -- | The configuration ID containing the dictionary
        dictionaryNotFoundConfigId :: ConfigurationId,
        -- | The dictionary ID that was not found
        dictionaryNotFoundDictId :: DictionaryId
      }
  | -- | Entry not found within a dictionary
    EntryNotFound
      { -- | The dictionary ID containing the entry
        entryNotFoundDictId :: DictionaryId,
        -- | The entry ID that was not found
        entryNotFoundEntryId :: DictionaryEntryId
      }
  | -- | Duplicate entry name within a dictionary
    DuplicateEntryName
      { -- | The dictionary ID containing the duplicate
        duplicateEntryDictId :: DictionaryId,
        -- | The duplicate entry name
        duplicateEntryName :: EntryName
      }
  | -- | Cannot remove the last entry from a dictionary
    CannotRemoveLastEntry
      { -- | The dictionary ID with the last entry
        cannotRemoveLastDictId :: DictionaryId
      }
  deriving (Show, Eq, Generic)

-- JSON instances for API serialization
instance ToJSON ConfigurationError

instance FromJSON ConfigurationError

-- -----------------------------------------------------------------------------
-- Error Constructors
-- -----------------------------------------------------------------------------

-- | Create a ConfigurationNotFound error.
--
-- This error indicates that a configuration with the given ID does not exist
-- in the system.
mkConfigurationNotFound ::
  -- | Configuration ID that was not found
  ConfigurationId ->
  ConfigurationError
mkConfigurationNotFound configId =
  ConfigurationNotFound
    { configurationNotFoundId = configId
    }

-- | Create a DictionaryNotFound error.
--
-- This error indicates that a dictionary with the given ID does not exist
-- within the specified configuration.
mkDictionaryNotFound ::
  -- | Configuration ID containing the dictionary
  ConfigurationId ->
  -- | Dictionary ID that was not found
  DictionaryId ->
  ConfigurationError
mkDictionaryNotFound configId dictId =
  DictionaryNotFound
    { dictionaryNotFoundConfigId = configId,
      dictionaryNotFoundDictId = dictId
    }

-- | Create an EntryNotFound error.
--
-- This error indicates that an entry with the given ID does not exist
-- within the specified dictionary.
mkEntryNotFound ::
  -- | Dictionary ID containing the entry
  DictionaryId ->
  -- | Entry ID that was not found
  DictionaryEntryId ->
  ConfigurationError
mkEntryNotFound dictId entryId =
  EntryNotFound
    { entryNotFoundDictId = dictId,
      entryNotFoundEntryId = entryId
    }

-- | Create a DuplicateEntryName error.
--
-- This error indicates that an entry with the given name already exists
-- within the specified dictionary.
mkDuplicateEntryName ::
  -- | Dictionary ID containing the duplicate
  DictionaryId ->
  -- | The duplicate entry name
  EntryName ->
  ConfigurationError
mkDuplicateEntryName dictId name =
  DuplicateEntryName
    { duplicateEntryDictId = dictId,
      duplicateEntryName = name
    }

-- | Create a CannotRemoveLastEntry error.
--
-- This error indicates that the last entry in a dictionary cannot be removed.
mkCannotRemoveLastEntry ::
  -- | Dictionary ID with the last entry
  DictionaryId ->
  ConfigurationError
mkCannotRemoveLastEntry dictId =
  CannotRemoveLastEntry
    { cannotRemoveLastDictId = dictId
    }
