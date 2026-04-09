{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Configuration.Events
-- Description : Events for the Configuration aggregate
--
-- This module defines all events that can occur in the Configuration aggregate's lifecycle.
-- Events represent immutable facts about state changes that have already occurred.
--
-- Key Events:
--   - ConfigurationCreated: A new configuration was created
--   - BaseCurrencyChanged: The base currency was changed
--   - DefaultCurrencyChanged: The default currency for new accounts was changed
--   - DictionaryEntryAdded: An entry was added to a dictionary
--   - DictionaryEntryRenamed: An entry in a dictionary was renamed
--   - DictionaryEntryRemoved: An entry was removed from a dictionary
--
-- All events use Template Haskell for integration with the eventium library
-- and include JSON serialization instances.
module Domain.Configuration.Events
  ( -- * Event List
    configurationEvents,

    -- * Configuration Events
    ConfigurationCreated (..),
    BaseCurrencyChanged (..),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRenamed (..),
    DictionaryEntryRemoved (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Domain.Core.Types (CreatedBy, Currency, DictionaryEntryId, DictionaryId, EntryName)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Event List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all configuration event type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the ConfigurationEvent sum type and related serialization code.
configurationEvents :: [Name]
configurationEvents =
  [ ''ConfigurationCreated,
    ''BaseCurrencyChanged,
    ''DefaultCurrencyChanged,
    ''DictionaryEntryAdded,
    ''DictionaryEntryRenamed,
    ''DictionaryEntryRemoved
  ]

-- -----------------------------------------------------------------------------
-- Configuration Events
-- -----------------------------------------------------------------------------

-- | Event emitted when a new configuration is created.
data ConfigurationCreated = ConfigurationCreated
  { -- | Base currency for reporting
    baseCurrency :: Currency,
    -- | Default currency for new accounts
    defaultCurrency :: Currency,
    -- | Who created this configuration
    createdBy :: CreatedBy
  }
  deriving (Show, Eq)

-- | Event emitted when the base currency is changed.
data BaseCurrencyChanged = BaseCurrencyChanged
  { -- | New base currency
    baseCurrency :: Currency
  }
  deriving (Show, Eq)

-- | Event emitted when the default currency for new accounts is changed.
data DefaultCurrencyChanged = DefaultCurrencyChanged
  { -- | New default currency
    defaultCurrency :: Currency
  }
  deriving (Show, Eq)

-- | Event emitted when an entry is added to a dictionary.
data DictionaryEntryAdded = DictionaryEntryAdded
  { -- | Dictionary to which the entry was added
    dictionaryId :: DictionaryId,
    -- | Unique identifier for the new entry
    entryId :: DictionaryEntryId,
    -- | Display name of the new entry
    name :: EntryName
  }
  deriving (Show, Eq)

-- | Event emitted when an entry in a dictionary is renamed.
data DictionaryEntryRenamed = DictionaryEntryRenamed
  { -- | Dictionary containing the entry
    dictionaryId :: DictionaryId,
    -- | Identifier of the entry being renamed
    entryId :: DictionaryEntryId,
    -- | New display name
    newName :: EntryName
  }
  deriving (Show, Eq)

-- | Event emitted when an entry is removed from a dictionary.
data DictionaryEntryRemoved = DictionaryEntryRemoved
  { -- | Dictionary from which the entry was removed
    dictionaryId :: DictionaryId,
    -- | Identifier of the removed entry
    entryId :: DictionaryEntryId
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all events
deriveJSON defaultOptions ''ConfigurationCreated
deriveJSON defaultOptions ''BaseCurrencyChanged
deriveJSON defaultOptions ''DefaultCurrencyChanged
deriveJSON defaultOptions ''DictionaryEntryAdded
deriveJSON defaultOptions ''DictionaryEntryRenamed
deriveJSON defaultOptions ''DictionaryEntryRemoved
