-- |
-- Module      : Domain.Configuration
-- Description : Public API for the Configuration aggregate
--
-- This module re-exports all Configuration aggregate components, providing a single
-- import point for working with configurations.
--
-- Usage:
-- >>> import Domain.Configuration
module Domain.Configuration
  ( -- * Command Handler
    module Domain.Configuration.CommandHandler,

    -- * Commands
    module Domain.Configuration.Commands,

    -- * Events (without field accessors that conflict with other modules)
    ConfigurationCreated (ConfigurationCreated),
    BaseCurrencyChanged (..),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRenamed (..),
    DictionaryEntryRemoved (..),
    DictionaryEntryMoved (..),
    configurationEvents,

    -- * Projection
    module Domain.Configuration.Projection,
  )
where

import Domain.Configuration.CommandHandler
import Domain.Configuration.Commands
import Domain.Configuration.Events
  ( BaseCurrencyChanged (..),
    ConfigurationCreated (ConfigurationCreated),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryMoved (..),
    DictionaryEntryRemoved (..),
    DictionaryEntryRenamed (..),
    configurationEvents,
  )
import Domain.Configuration.Projection
