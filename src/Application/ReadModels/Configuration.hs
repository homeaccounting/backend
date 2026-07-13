{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Application.ReadModels.Configuration
-- Description : Persistent read model for configuration queries
--
-- A configuration is projected into five Postgres tables:
--
--   * @configurations@ — one row per configuration (currencies, default
--     categories, books-closed cutoff, creator, version),
--   * @configuration_dictionary_entries@ — one row per dictionary entry,
--   * @configuration_mcc_categories@ — one row per MCC → expense-category map
--     entry,
--   * @configuration_bank_connections@ — one row per bank connection, and
--   * @configuration_bank_account_map@ — one row per connection's
--     external→local account mapping.
--
-- The configuration projection is only ever fetched whole by id
-- ('getConfiguration'), so the child tables carry no secondary indexes beyond
-- their @configId@-leading unique keys. The projection is an eventium
-- 'ReadModel' ('configurationReadModel') driven synchronously in the
-- event-append transaction; the per-row @version@ is recorded from the event's
-- real per-stream 'EventVersion'.
module Application.ReadModels.Configuration
  ( -- * Read Model Query Types
    ConfigurationData (..),
    DictionaryData (..),

    -- * Read model
    configurationReadModel,
    configurationProjectionName,
    migrateConfiguration,
    resetConfiguration,
    applyConfigurationEvent,
    ConfigurationEntity (..),
    ConfigDictionaryEntryEntity (..),
    ConfigMccCategoryEntity (..),
    ConfigBankConnectionEntity (..),
    ConfigBankAccountMapEntity (..),

    -- * Query Functions (run via 'runDb')
    getConfiguration,
  )
where

import Control.Monad (forM, forM_, void)
import Control.Monad.IO.Class (MonadIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.Persist
  ( Entity (..),
    Filter,
    deleteWhere,
    getBy,
    insertUnique,
    insert_,
    replace,
    selectList,
    updateWhere,
    upsertBy,
    (=.),
    (==.),
  )
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Banking.Types (BankConnectionId, BankProviderId)
import Domain.Configuration.Events
  ( BankConnectionAccountMapSet (..),
    BankConnectionAdded (..),
    BankConnectionEnabledSet (..),
    BankConnectionRemoved (..),
    BankConnectionRenamed (..),
    BankConnectionTokenChanged (..),
    BankingMccExpenseCategoryMapSet (..),
    BaseCurrencyChanged (..),
    BooksClosedThroughSet (..),
    ConfigurationCreated (..),
    DefaultAccountSet (..),
    DefaultCurrencyChanged (..),
    DefaultExpenseCategorySet (..),
    DefaultIncomeCategorySet (..),
    DefaultSubtypeAccountsSet (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRemoved (..),
    DictionaryEntryRenamed (..),
  )
import Domain.Configuration.Projection
  ( BankConnection (..),
    BankingConfiguration (..),
    ConfigurationDefaults (..),
    emptyBankingConfiguration,
  )
import Domain.Core.Types
  ( AccountId,
    ConfigurationId,
    CreatedBy,
    Currency,
    DefaultSubtypeAccounts (..),
    DictionaryEntryId,
    DictionaryId,
    EntryName,
    mkConfigurationIdSafe,
    unDefaultSubtypeAccounts,
  )
import Domain.Models (AccountingEvent (..))
import Eventium
  ( EventHandler (..),
    EventVersion (..),
    GlobalStreamEvent,
    ReadModel (..),
    StreamEvent (..),
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import GHC.Generics (Generic)
import Infrastructure.Crypto.SecretBox (EncryptedSecret)
import Infrastructure.Database.Orphans ()

-- -----------------------------------------------------------------------------
-- Query result types
-- -----------------------------------------------------------------------------

-- | Denormalized configuration information returned by 'getConfiguration',
-- assembled from the five backing tables.
data ConfigurationData = ConfigurationData
  { -- | Base currency for reporting
    baseCurrency :: Currency,
    -- | Default currency for new accounts
    defaultCurrency :: Currency,
    -- | Dictionaries with their entries
    dictionaries :: Map DictionaryId DictionaryData,
    -- | Banking-specific configuration
    banking :: BankingConfiguration,
    -- | All per-configuration defaults (categories + accounts), grouped.
    defaults :: ConfigurationDefaults,
    -- | Advance-only books-closed-through cutoff. 'Nothing' means no cutoff.
    booksClosedThrough :: Maybe UTCTime,
    -- | Who created this configuration
    createdBy :: CreatedBy,
    -- | Version number from the event stream for optimistic concurrency
    version :: Int
  }
  deriving (Show, Eq, Generic)

-- | Denormalized dictionary data containing entries.
newtype DictionaryData = DictionaryData
  { -- | Map of entry IDs to entry names
    entries :: Map DictionaryEntryId EntryName
  }
  deriving (Show, Eq, Generic)

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateConfiguration"]
  [persistLowerCase|
ConfigurationEntity sql=configurations
    configId ConfigurationId
    baseCurrency Currency
    defaultCurrency Currency
    defaultIncomeCategory DictionaryEntryId Maybe
    defaultExpenseCategory DictionaryEntryId Maybe
    defaultAccount AccountId Maybe
    defaultSubtypeAccounts DefaultSubtypeAccounts
    booksClosedThrough UTCTime Maybe
    createdBy CreatedBy
    version Int
    UniqueConfiguration configId
    deriving Show Eq
ConfigDictionaryEntryEntity sql=configuration_dictionary_entries
    configId ConfigurationId
    dictionaryId DictionaryId
    entryId DictionaryEntryId
    name EntryName
    UniqueConfigDictEntry configId dictionaryId entryId
    deriving Show Eq
ConfigMccCategoryEntity sql=configuration_mcc_categories
    configId ConfigurationId
    mcc Text
    categoryId DictionaryEntryId
    UniqueConfigMcc configId mcc
    deriving Show Eq
ConfigBankConnectionEntity sql=configuration_bank_connections
    configId ConfigurationId
    connectionId BankConnectionId
    provider BankProviderId
    name Text
    encryptedToken EncryptedSecret
    tokenHint Text
    enabled Bool
    UniqueConfigConn configId connectionId
    deriving Show Eq
ConfigBankAccountMapEntity sql=configuration_bank_account_map
    configId ConfigurationId
    connectionId BankConnectionId
    externalAccountId Text
    accountId AccountId
    UniqueConfigConnAcct configId connectionId externalAccountId
    deriving Show Eq
|]

-- | Projection/checkpoint name for this read model.
configurationProjectionName :: CheckpointName
configurationProjectionName = CheckpointName "configuration"

-- | Clear all five configuration tables. The checkpoint is reset by
-- 'rebuildReadModel'.
resetConfiguration :: (MonadIO m) => SqlPersistT m ()
resetConfiguration = do
  deleteWhere ([] :: [Filter ConfigBankAccountMapEntity])
  deleteWhere ([] :: [Filter ConfigBankConnectionEntity])
  deleteWhere ([] :: [Filter ConfigMccCategoryEntity])
  deleteWhere ([] :: [Filter ConfigDictionaryEntryEntity])
  deleteWhere ([] :: [Filter ConfigurationEntity])

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

configurationReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
configurationReadModel =
  ReadModel
    { initialize = void (runMigrationSilent migrateConfiguration),
      eventHandler = EventHandler applyConfigurationEvent,
      checkpointStore = postgresqlCheckpointStore configurationProjectionName,
      reset = resetConfiguration
    }

-- | Apply a single global event to the configuration tables. The per-stream
-- version (@globalEvent.payload.position@) is recorded as the row @version@.
-- Mutations to a configuration's child rows also bump the parent row's version,
-- and are no-ops when the configuration row is absent (mirroring the old
-- in-memory @Map.adjust@).
applyConfigurationEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyConfigurationEvent globalEvent =
  let inner = globalEvent.payload
      EventVersion ver = inner.position
   in case mkConfigurationIdSafe inner.key of
        Nothing -> pure ()
        Just configId -> case inner.payload of
          ConfigurationCreatedEvent evt ->
            void $
              insertUnique
                ConfigurationEntity
                  { configurationEntityConfigId = configId,
                    configurationEntityBaseCurrency = evt.baseCurrency,
                    configurationEntityDefaultCurrency = evt.defaultCurrency,
                    configurationEntityDefaultIncomeCategory = Nothing,
                    configurationEntityDefaultExpenseCategory = Nothing,
                    configurationEntityDefaultAccount = Nothing,
                    configurationEntityDefaultSubtypeAccounts = DefaultSubtypeAccounts Map.empty,
                    configurationEntityBooksClosedThrough = Nothing,
                    configurationEntityCreatedBy = evt.createdBy,
                    configurationEntityVersion = ver
                  }
          BaseCurrencyChangedEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityBaseCurrency = evt.baseCurrency, configurationEntityVersion = ver})
          DefaultCurrencyChangedEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityDefaultCurrency = evt.defaultCurrency, configurationEntityVersion = ver})
          DefaultIncomeCategorySetEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityDefaultIncomeCategory = Just evt.categoryId, configurationEntityVersion = ver})
          DefaultExpenseCategorySetEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityDefaultExpenseCategory = Just evt.categoryId, configurationEntityVersion = ver})
          DefaultAccountSetEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityDefaultAccount = Just evt.accountId, configurationEntityVersion = ver})
          DefaultSubtypeAccountsSetEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityDefaultSubtypeAccounts = DefaultSubtypeAccounts evt.subtypeAccounts, configurationEntityVersion = ver})
          BooksClosedThroughSetEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityBooksClosedThrough = Just evt.closedThrough, configurationEntityVersion = ver})
          DictionaryEntryAddedEvent evt ->
            whenConfig configId ver $
              void $
                upsertBy
                  (UniqueConfigDictEntry configId evt.dictionaryId evt.entryId)
                  (ConfigDictionaryEntryEntity configId evt.dictionaryId evt.entryId evt.name)
                  [ConfigDictionaryEntryEntityName =. evt.name]
          DictionaryEntryRenamedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ ConfigDictionaryEntryEntityConfigId ==. configId,
                  ConfigDictionaryEntryEntityDictionaryId ==. evt.dictionaryId,
                  ConfigDictionaryEntryEntityEntryId ==. evt.entryId
                ]
                [ConfigDictionaryEntryEntityName =. evt.newName]
          DictionaryEntryRemovedEvent evt ->
            whenConfig configId ver $
              deleteWhere
                [ ConfigDictionaryEntryEntityConfigId ==. configId,
                  ConfigDictionaryEntryEntityDictionaryId ==. evt.dictionaryId,
                  ConfigDictionaryEntryEntityEntryId ==. evt.entryId
                ]
          BankingMccExpenseCategoryMapSetEvent evt ->
            whenConfig configId ver $ do
              deleteWhere [ConfigMccCategoryEntityConfigId ==. configId]
              forM_ (Map.toList evt.mapping) $ \(mcc, cat) ->
                insert_ (ConfigMccCategoryEntity configId mcc cat)
          BankConnectionAddedEvent evt ->
            whenConfig configId ver $ do
              -- Adding (re)initializes the connection with an empty account map.
              deleteWhere
                [ ConfigBankAccountMapEntityConfigId ==. configId,
                  ConfigBankAccountMapEntityConnectionId ==. evt.connectionId
                ]
              void $
                upsertBy
                  (UniqueConfigConn configId evt.connectionId)
                  (ConfigBankConnectionEntity configId evt.connectionId evt.provider evt.name evt.encryptedToken evt.tokenHint evt.enabled)
                  [ ConfigBankConnectionEntityProvider =. evt.provider,
                    ConfigBankConnectionEntityName =. evt.name,
                    ConfigBankConnectionEntityEncryptedToken =. evt.encryptedToken,
                    ConfigBankConnectionEntityTokenHint =. evt.tokenHint,
                    ConfigBankConnectionEntityEnabled =. evt.enabled
                  ]
          BankConnectionRenamedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ConfigBankConnectionEntityConfigId ==. configId, ConfigBankConnectionEntityConnectionId ==. evt.connectionId]
                [ConfigBankConnectionEntityName =. evt.name]
          BankConnectionTokenChangedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ConfigBankConnectionEntityConfigId ==. configId, ConfigBankConnectionEntityConnectionId ==. evt.connectionId]
                [ ConfigBankConnectionEntityEncryptedToken =. evt.encryptedToken,
                  ConfigBankConnectionEntityTokenHint =. evt.tokenHint
                ]
          BankConnectionEnabledSetEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ConfigBankConnectionEntityConfigId ==. configId, ConfigBankConnectionEntityConnectionId ==. evt.connectionId]
                [ConfigBankConnectionEntityEnabled =. evt.enabled]
          BankConnectionAccountMapSetEvent evt ->
            whenConfig configId ver $ do
              deleteWhere
                [ ConfigBankAccountMapEntityConfigId ==. configId,
                  ConfigBankAccountMapEntityConnectionId ==. evt.connectionId
                ]
              forM_ (Map.toList evt.accountMap) $ \(ext, acc) ->
                insert_ (ConfigBankAccountMapEntity configId evt.connectionId ext acc)
          BankConnectionRemovedEvent evt ->
            whenConfig configId ver $ do
              deleteWhere
                [ ConfigBankAccountMapEntityConfigId ==. configId,
                  ConfigBankAccountMapEntityConnectionId ==. evt.connectionId
                ]
              deleteWhere
                [ConfigBankConnectionEntityConfigId ==. configId, ConfigBankConnectionEntityConnectionId ==. evt.connectionId]
          _ -> pure ()

-- | Read-modify-write the configuration row (no-op if absent).
modifyConfig :: (MonadIO m) => ConfigurationId -> (ConfigurationEntity -> ConfigurationEntity) -> SqlPersistT m ()
modifyConfig configId f = do
  mEnt <- getBy (UniqueConfiguration configId)
  case mEnt of
    Nothing -> pure ()
    Just (Entity k e) -> replace k (f e)

-- | Run a child-row mutation only when the configuration exists, then advance
-- the configuration row's version. Mirrors the old in-memory @Map.adjust@,
-- which no-ops when the configuration is absent.
whenConfig :: (MonadIO m) => ConfigurationId -> Int -> SqlPersistT m () -> SqlPersistT m ()
whenConfig configId ver body = do
  mEnt <- getBy (UniqueConfiguration configId)
  case mEnt of
    Nothing -> pure ()
    Just _ -> do
      body
      updateWhere [ConfigurationEntityConfigId ==. configId] [ConfigurationEntityVersion =. ver]

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieve the configuration data for a specific configuration ID, or
-- 'Nothing' if it does not exist.
getConfiguration :: (MonadIO m) => ConfigurationId -> SqlPersistT m (Maybe ConfigurationData)
getConfiguration configId = do
  mEnt <- getBy (UniqueConfiguration configId)
  case mEnt of
    Nothing -> pure Nothing
    Just (Entity _ e) -> do
      dicts <- loadDictionaries configId
      bankingCfg <- loadBanking configId
      pure $
        Just
          ConfigurationData
            { baseCurrency = e.configurationEntityBaseCurrency,
              defaultCurrency = e.configurationEntityDefaultCurrency,
              dictionaries = dicts,
              banking = bankingCfg,
              defaults =
                ConfigurationDefaults
                  { incomeCategory = e.configurationEntityDefaultIncomeCategory,
                    expenseCategory = e.configurationEntityDefaultExpenseCategory,
                    account = e.configurationEntityDefaultAccount,
                    subtypeAccounts = unDefaultSubtypeAccounts e.configurationEntityDefaultSubtypeAccounts
                  },
              booksClosedThrough = e.configurationEntityBooksClosedThrough,
              createdBy = e.configurationEntityCreatedBy,
              version = e.configurationEntityVersion
            }

-- | Assemble the configuration's dictionaries from their entry rows.
loadDictionaries :: (MonadIO m) => ConfigurationId -> SqlPersistT m (Map DictionaryId DictionaryData)
loadDictionaries configId = do
  rows <- selectList [ConfigDictionaryEntryEntityConfigId ==. configId] []
  pure $
    Map.fromListWith
      mergeDict
      [ (r.configDictionaryEntryEntityDictionaryId, DictionaryData (Map.singleton r.configDictionaryEntryEntityEntryId r.configDictionaryEntryEntityName))
      | Entity _ r <- rows
      ]
  where
    mergeDict (DictionaryData a) (DictionaryData b) = DictionaryData (Map.union a b)

-- | Assemble the configuration's banking configuration from the MCC-map,
-- connection, and account-map rows.
loadBanking :: (MonadIO m) => ConfigurationId -> SqlPersistT m BankingConfiguration
loadBanking configId = do
  mccRows <- selectList [ConfigMccCategoryEntityConfigId ==. configId] []
  connRows <- selectList [ConfigBankConnectionEntityConfigId ==. configId] []
  conns <- forM connRows $ \(Entity _ c) -> do
    acctRows <-
      selectList
        [ ConfigBankAccountMapEntityConfigId ==. configId,
          ConfigBankAccountMapEntityConnectionId ==. c.configBankConnectionEntityConnectionId
        ]
        []
    let accountMap' =
          Map.fromList
            [ (a.configBankAccountMapEntityExternalAccountId, a.configBankAccountMapEntityAccountId)
            | Entity _ a <- acctRows
            ]
    pure
      ( c.configBankConnectionEntityConnectionId,
        BankConnection
          { connectionId = c.configBankConnectionEntityConnectionId,
            provider = c.configBankConnectionEntityProvider,
            name = c.configBankConnectionEntityName,
            encryptedToken = c.configBankConnectionEntityEncryptedToken,
            tokenHint = c.configBankConnectionEntityTokenHint,
            enabled = c.configBankConnectionEntityEnabled,
            accountMap = accountMap'
          }
      )
  pure
    emptyBankingConfiguration
      { mccExpenseCategoryMap =
          Map.fromList
            [ (m.configMccCategoryEntityMcc, m.configMccCategoryEntityCategoryId)
            | Entity _ m <- mccRows
            ],
        connections = Map.fromList conns
      }
