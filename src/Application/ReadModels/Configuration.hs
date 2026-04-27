{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.Configuration
-- Description : Read model for optimized configuration queries
--
-- This module implements a read model that provides efficient queries for
-- configuration information without requiring event replay. The read model
-- listens to the event stream and maintains a denormalized view optimized
-- for common query patterns.
--
-- Key Components:
--   - ConfigurationData: Denormalized configuration information
--   - DictionaryData: Denormalized dictionary with entries
--   - ConfigurationReadModel: Map of configuration IDs to configuration data
--   - Event handlers: Update the read model when events occur
--   - Query functions: Efficient lookups by configuration ID
--
-- Design Rationale:
--   - Separates read and write models (CQRS pattern)
--   - Optimizes for query performance
--   - Maintains eventual consistency with event stream
--   - Tracks sequence numbers for reliable event processing
--
-- Note: This module processes events from the unified AccountingEvent type.
-- Configuration events must be integrated into AccountingEvent (Task 6)
-- before this module will compile.
module Application.ReadModels.Configuration
  ( -- * Read Model Types
    ConfigurationReadModel (..),
    ConfigurationData (..),
    DictionaryData (..),

    -- * Read Model Creation
    createConfigurationReadModel,

    -- * Event Handler
    handleConfigurationEvents,

    -- * Query Functions
    getConfiguration,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Domain.Configuration.Events
  ( BankingDefaultExpenseCategorySet (..),
    BankingDefaultIncomeCategorySet (..),
    BankingMccExpenseCategoryMapSet (..),
    BaseCurrencyChanged (..),
    ConfigurationCreated (..),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRemoved (..),
    DictionaryEntryRenamed (..),
  )
import Domain.Configuration.Projection (BankingConfiguration (defaultExpenseCategory, defaultIncomeCategory, mccExpenseCategoryMap), emptyBankingConfiguration)
import Domain.Core.Types
  ( ConfigurationId,
    CreatedBy,
    Currency,
    DictionaryEntryId,
    DictionaryId,
    EntryName,
    mkConfigurationIdSafe,
  )
import Domain.Models (AccountingEvent (..))
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
import Infrastructure.Eventium.GlobalEvent (unpackGlobalEvent)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Denormalized configuration information for efficient querying.
--
-- This structure contains all the information needed for common configuration
-- queries without requiring event replay.
data ConfigurationData = ConfigurationData
  { -- | Base currency for reporting
    baseCurrency :: Currency,
    -- | Default currency for new accounts
    defaultCurrency :: Currency,
    -- | Dictionaries with their entries
    dictionaries :: Map DictionaryId DictionaryData,
    -- | Banking-specific configuration
    banking :: BankingConfiguration,
    -- | Who created this configuration
    createdBy :: CreatedBy,
    -- | Version number from event stream for optimistic concurrency
    version :: Int
  }
  deriving (Show, Eq, Generic)

-- | Denormalized dictionary data containing entries.
data DictionaryData = DictionaryData
  { -- | Map of entry IDs to entry names
    entries :: Map DictionaryEntryId EntryName
  }
  deriving (Show, Eq, Generic)

-- | The read model state: a map from configuration IDs to their configuration data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data ConfigurationReadModel = ConfigurationReadModel
  { latestSequence :: SequenceNumber,
    configurations :: Map ConfigurationId ConfigurationData
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty configuration read model.
--
-- This initializes the read model with:
--   - Sequence number -1 (before any events)
--   - Empty map of configurations
--
-- Example:
-- >>> readModel <- createConfigurationReadModel
-- >>> config <- getConfiguration readModel someConfigId
createConfigurationReadModel :: (MonadIO m) => m (TVar ConfigurationReadModel)
createConfigurationReadModel =
  liftIO $
    newTVarIO $
      ConfigurationReadModel
        { latestSequence = -1,
          configurations = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- This function:
--   1. Processes each event and updates the configuration data accordingly
--   2. Tracks the highest sequence number seen
--   3. Updates the TVar atomically
--
-- Events handled:
--   - ConfigurationCreatedEvent: Adds new configuration to the map
--   - BaseCurrencyChangedEvent: Updates base currency
--   - DefaultCurrencyChangedEvent: Updates default currency
--   - DictionaryEntryAddedEvent: Adds entry to dictionary (auto-creates dict if absent)
--   - DictionaryEntryRenamedEvent: Renames an existing entry
--   - DictionaryEntryRemovedEvent: Removes an entry from a dictionary
--
-- The function is idempotent - replaying the same events produces the same result.
--
-- Example:
-- >>> handleConfigurationEvents readModelTVar events
-- >>> config <- getConfiguration readModelTVar configId
handleConfigurationEvents ::
  (MonadIO m) =>
  TVar ConfigurationReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleConfigurationEvents readModelTVar events = do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedData = foldl processConfigurationEvent currentModel.configurations events

  liftIO . atomically . writeTVar readModelTVar $
    currentModel
      { latestSequence = newSeq,
        configurations = updatedData
      }

-- | Processes a single event and updates the configurations map.
--
-- GlobalStreamEvent is nested: StreamEvent () SequenceNumber (VersionedStreamEvent event)
-- where VersionedStreamEvent event = StreamEvent UUID EventVersion event
-- So we need to unwrap twice to get the payload and stream key (UUID).
processConfigurationEvent ::
  Map ConfigurationId ConfigurationData ->
  GlobalStreamEvent AccountingEvent ->
  Map ConfigurationId ConfigurationData
processConfigurationEvent configurations globalEvent =
  let (streamUuid, payload) = unpackGlobalEvent globalEvent
   in case payload of
        ConfigurationCreatedEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.insert
                configId
                ConfigurationData
                  { baseCurrency = evt.baseCurrency,
                    defaultCurrency = evt.defaultCurrency,
                    dictionaries = Map.empty,
                    banking = emptyBankingConfiguration,
                    createdBy = evt.createdBy,
                    version = 1
                  }
                configurations
        BaseCurrencyChangedEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    config
                      { baseCurrency = evt.baseCurrency,
                        version = config.version + 1
                      }
                )
                configId
                configurations
        DefaultCurrencyChangedEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    config
                      { defaultCurrency = evt.defaultCurrency,
                        version = config.version + 1
                      }
                )
                configId
                configurations
        DictionaryEntryAddedEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    let dictMap = config.dictionaries
                        dict = Map.findWithDefault (DictionaryData Map.empty) evt.dictionaryId dictMap
                        updatedEntries = Map.insert evt.entryId evt.name dict.entries
                        updatedDict = dict {entries = updatedEntries}
                     in config
                          { dictionaries = Map.insert evt.dictionaryId updatedDict dictMap,
                            version = config.version + 1
                          }
                )
                configId
                configurations
        DictionaryEntryRenamedEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    let dictMap = config.dictionaries
                     in case Map.lookup evt.dictionaryId dictMap of
                          Nothing -> config
                          Just dict ->
                            let updatedEntries = Map.insert evt.entryId evt.newName dict.entries
                                updatedDict = dict {entries = updatedEntries}
                             in config
                                  { dictionaries = Map.insert evt.dictionaryId updatedDict dictMap,
                                    version = config.version + 1
                                  }
                )
                configId
                configurations
        DictionaryEntryRemovedEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    let dictMap = config.dictionaries
                     in case Map.lookup evt.dictionaryId dictMap of
                          Nothing -> config
                          Just dict ->
                            let updatedEntries = Map.delete evt.entryId dict.entries
                                updatedDict = dict {entries = updatedEntries}
                             in config
                                  { dictionaries = Map.insert evt.dictionaryId updatedDict dictMap,
                                    version = config.version + 1
                                  }
                )
                configId
                configurations
        BankingDefaultIncomeCategorySetEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    config
                      { banking = config.banking {defaultIncomeCategory = Just evt.categoryId},
                        version = config.version + 1
                      }
                )
                configId
                configurations
        BankingDefaultExpenseCategorySetEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    config
                      { banking = config.banking {defaultExpenseCategory = Just evt.categoryId},
                        version = config.version + 1
                      }
                )
                configId
                configurations
        BankingMccExpenseCategoryMapSetEvent evt ->
          case mkConfigurationIdSafe streamUuid of
            Nothing -> configurations
            Just configId ->
              Map.adjust
                ( \config ->
                    config
                      { banking = config.banking {mccExpenseCategoryMap = evt.mapping},
                        version = config.version + 1
                      }
                )
                configId
                configurations
        _ -> configurations -- Ignore other events

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieves the configuration data for a specific configuration ID.
--
-- Returns 'Nothing' if the configuration doesn't exist in the read model.
--
-- Example:
-- >>> maybeConfig <- getConfiguration readModel configId
-- >>> case maybeConfig of
-- >>>   Just config -> print (config.baseCurrency)
-- >>>   Nothing -> putStrLn "Configuration not found"
getConfiguration ::
  (MonadIO m) =>
  TVar ConfigurationReadModel ->
  ConfigurationId ->
  m (Maybe ConfigurationData)
getConfiguration readModelTVar configId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup configId model.configurations
