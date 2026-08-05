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
--   * @configuration_bank_provider_expense_categories@ — one row per provider-category →
--     expense-category map entry,
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

    -- * Dictionary tree accessors
    dictionaryItems,
    dictionaryItemIds,
    dictionaryItemPaths,
    dictionaryGroupFallbacks,
    dictionaryEntriesParentFirst,

    -- * Read model
    configurationReadModel,
    configurationProjectionName,
    migrateConfiguration,
    resetConfiguration,
    applyConfigurationEvent,
    ConfigurationEntity (..),
    ConfigDictionaryEntryEntity (..),
    ConfigBankProviderExpenseCategoryEntity (..),
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
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.Persist
  ( Entity (..),
    Filter,
    SelectOpt (Asc, Desc),
    deleteWhere,
    getBy,
    insertUnique,
    insert_,
    replace,
    selectFirst,
    selectList,
    updateWhere,
    upsertBy,
    (=.),
    (==.),
  )
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Banking.Types (BankConnectionId, BankProviderId, unExternalAccountId, unsafeExternalAccountId)
import Domain.Configuration.Dictionary (DictionaryEntry (..), DictionaryKind, DictionaryNode (..), EntryRole (..), ItemPath, buildDictionaryTree, groupItemFallbacks, itemPaths)
import Domain.Configuration.Events
  ( BankConnectionAccountMapSet (..),
    BankConnectionAdded (..),
    BankConnectionCredentialChanged (..),
    BankConnectionEnabledSet (..),
    BankConnectionRemoved (..),
    BankConnectionRenamed (..),
    BankProviderExpenseCategoryMapSet (..),
    BaseCurrencyChanged (..),
    BooksClosedThroughSet (..),
    ConfigurationCreated (..),
    DefaultAccountSet (..),
    DefaultCurrencyChanged (..),
    DefaultExpenseCategorySet (..),
    DefaultIncomeCategorySet (..),
    DefaultSubtypeAccountsSet (..),
    DictionaryEntryAdded (..),
    DictionaryEntryMoved (..),
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
    EntryName,
    mkConfigurationIdSafe,
    parseBankProviderCategoryKey,
    renderBankProviderCategoryKey,
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
    dictionaries :: Map DictionaryKind DictionaryData,
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

-- | Denormalized dictionary data holding the already-materialised tree. The
-- flat @parentId@ adjacency stored in @configuration_dictionary_entries@ is
-- folded into roots-first 'DictionaryNode's by 'loadDictionaries' (via the
-- domain materialiser 'buildDictionaryTree'), so consumers read the tree
-- directly instead of re-deriving it. Use the accessors ('dictionaryItems',
-- 'dictionaryItemIds', 'dictionaryEntriesParentFirst') for the common
-- flat views.
newtype DictionaryData = DictionaryData
  { -- | Root-level nodes of the materialised dictionary tree.
    roots :: [DictionaryNode]
  }
  deriving (Show, Eq, Generic)

-- | Pre-order DFS collecting the tree's leaf items as @(id, name)@ pairs.
-- Groups contribute only through their descendants; an 'ItemNode' is always a
-- leaf. This is the set of entries a client may assign to a transaction.
dictionaryItems :: DictionaryData -> [(DictionaryEntryId, EntryName)]
dictionaryItems (DictionaryData ns) = concatMap go ns
  where
    go (ItemNode eid nm) = [(eid, nm)]
    go (GroupNode _ _ kids) = concatMap go kids

-- | Every assignable leaf paired with its group-qualified 'ItemPath' (e.g.
-- @"Food / Groceries"@), for a category picker or the LLM prompt. Delegates to
-- the domain materialiser so the path format lives in one place.
dictionaryItemPaths :: DictionaryData -> [(DictionaryEntryId, ItemPath)]
dictionaryItemPaths (DictionaryData ns) = itemPaths ns

-- | For each group, a @(first-descendant-item id, group 'ItemPath')@ pair, so a
-- category that names a group resolves to the group's first assignable item —
-- its curated primary, since sibling order is the persisted position — rather
-- than the global default. Groups with no items are omitted.
dictionaryGroupFallbacks :: DictionaryData -> [(DictionaryEntryId, ItemPath)]
dictionaryGroupFallbacks (DictionaryData ns) = groupItemFallbacks ns

-- | The assignable (item) entry ids of a dictionary — the ids from
-- 'dictionaryItems'. Groups are excluded (ADR 002).
dictionaryItemIds :: DictionaryData -> Set DictionaryEntryId
dictionaryItemIds = Set.fromList . map fst . dictionaryItems

-- | Pre-order DFS yielding every node with its structural role and parent id
-- (root parent is 'Nothing'). A parent always precedes its children, so the
-- clone path can replay @AddDictionaryEntry@ in this order without violating
-- the parent-exists guard.
dictionaryEntriesParentFirst ::
  DictionaryData ->
  [(DictionaryEntryId, EntryName, EntryRole, Maybe DictionaryEntryId)]
dictionaryEntriesParentFirst (DictionaryData ns) = concatMap (go Nothing) ns
  where
    go parent (ItemNode eid nm) = [(eid, nm, ItemRole, parent)]
    go parent (GroupNode eid nm kids) =
      (eid, nm, GroupRole, parent) : concatMap (go (Just eid)) kids

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
    dictionaryKind DictionaryKind
    entryId DictionaryEntryId
    name EntryName
    role EntryRole
    parentId DictionaryEntryId Maybe
    position Int
    UniqueConfigDictEntry configId dictionaryKind entryId
    deriving Show Eq
ConfigBankProviderExpenseCategoryEntity sql=configuration_bank_provider_expense_categories
    configId ConfigurationId
    bankProviderCategory Text
    categoryId DictionaryEntryId
    UniqueConfigBankProviderExpenseCategory configId bankProviderCategory
    deriving Show Eq
ConfigBankConnectionEntity sql=configuration_bank_connections
    configId ConfigurationId
    connectionId BankConnectionId
    provider BankProviderId
    name Text
    encryptedSecret EncryptedSecret Maybe
    secretHint Text Maybe
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
  deleteWhere ([] :: [Filter ConfigBankProviderExpenseCategoryEntity])
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
            whenConfig configId ver $ do
              -- Append order: one past the current max position within this
              -- (config, kind). Using max+1 (not count) keeps positions
              -- collision-free across removes and deterministic on replay.
              -- Not in the update list, so a re-applied Added never shifts it.
              mLast <-
                selectFirst
                  [ ConfigDictionaryEntryEntityConfigId ==. configId,
                    ConfigDictionaryEntryEntityDictionaryKind ==. evt.dictionaryKind
                  ]
                  [Desc ConfigDictionaryEntryEntityPosition]
              let nextPos = maybe 0 (\(Entity _ r) -> r.configDictionaryEntryEntityPosition + 1) mLast
              void $
                upsertBy
                  (UniqueConfigDictEntry configId evt.dictionaryKind evt.entryId)
                  (ConfigDictionaryEntryEntity configId evt.dictionaryKind evt.entryId evt.name evt.role evt.parentId nextPos)
                  [ ConfigDictionaryEntryEntityName =. evt.name,
                    ConfigDictionaryEntryEntityRole =. evt.role,
                    ConfigDictionaryEntryEntityParentId =. evt.parentId
                  ]
          DictionaryEntryRenamedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ ConfigDictionaryEntryEntityConfigId ==. configId,
                  ConfigDictionaryEntryEntityDictionaryKind ==. evt.dictionaryKind,
                  ConfigDictionaryEntryEntityEntryId ==. evt.entryId
                ]
                [ConfigDictionaryEntryEntityName =. evt.newName]
          DictionaryEntryRemovedEvent evt ->
            whenConfig configId ver $
              deleteWhere
                [ ConfigDictionaryEntryEntityConfigId ==. configId,
                  ConfigDictionaryEntryEntityDictionaryKind ==. evt.dictionaryKind,
                  ConfigDictionaryEntryEntityEntryId ==. evt.entryId
                ]
          DictionaryEntryMovedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ ConfigDictionaryEntryEntityConfigId ==. configId,
                  ConfigDictionaryEntryEntityDictionaryKind ==. evt.dictionaryKind,
                  ConfigDictionaryEntryEntityEntryId ==. evt.entryId
                ]
                [ConfigDictionaryEntryEntityParentId =. evt.newParentId]
          BankProviderExpenseCategoryMapSetEvent evt ->
            whenConfig configId ver $ do
              deleteWhere [ConfigBankProviderExpenseCategoryEntityConfigId ==. configId]
              forM_ (Map.toList evt.mapping) $ \(pc, cat) ->
                insert_ (ConfigBankProviderExpenseCategoryEntity configId (renderBankProviderCategoryKey pc) cat)
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
                  (ConfigBankConnectionEntity configId evt.connectionId evt.provider evt.name evt.encryptedSecret evt.secretHint evt.enabled)
                  [ ConfigBankConnectionEntityProvider =. evt.provider,
                    ConfigBankConnectionEntityName =. evt.name,
                    ConfigBankConnectionEntityEncryptedSecret =. evt.encryptedSecret,
                    ConfigBankConnectionEntitySecretHint =. evt.secretHint,
                    ConfigBankConnectionEntityEnabled =. evt.enabled
                  ]
          BankConnectionRenamedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ConfigBankConnectionEntityConfigId ==. configId, ConfigBankConnectionEntityConnectionId ==. evt.connectionId]
                [ConfigBankConnectionEntityName =. evt.name]
          BankConnectionCredentialChangedEvent evt ->
            whenConfig configId ver $
              updateWhere
                [ConfigBankConnectionEntityConfigId ==. configId, ConfigBankConnectionEntityConnectionId ==. evt.connectionId]
                [ ConfigBankConnectionEntityEncryptedSecret =. Just evt.encryptedSecret,
                  ConfigBankConnectionEntitySecretHint =. Just evt.secretHint
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
                insert_ (ConfigBankAccountMapEntity configId evt.connectionId (unExternalAccountId ext) acc)
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

-- | Assemble the configuration's dictionaries from their entry rows. The flat
-- rows are grouped per kind and materialised into a tree by 'buildDictionaryTree'.
loadDictionaries :: (MonadIO m) => ConfigurationId -> SqlPersistT m (Map DictionaryKind DictionaryData)
loadDictionaries configId = do
  rows <- selectList [ConfigDictionaryEntryEntityConfigId ==. configId] [Asc ConfigDictionaryEntryEntityPosition]
  pure $
    DictionaryData . buildDictionaryTree
      <$> Map.fromListWith
        (flip (<>))
        [ ( r.configDictionaryEntryEntityDictionaryKind,
            [ DictionaryEntry
                { entryId = r.configDictionaryEntryEntityEntryId,
                  name = r.configDictionaryEntryEntityName,
                  role = r.configDictionaryEntryEntityRole,
                  parentId = r.configDictionaryEntryEntityParentId
                }
            ]
          )
        | Entity _ r <- rows
        ]

-- | Assemble the configuration's banking configuration from the
-- provider-category-map, connection, and account-map rows.
loadBanking :: (MonadIO m) => ConfigurationId -> SqlPersistT m BankingConfiguration
loadBanking configId = do
  bankProviderCategoryRows <- selectList [ConfigBankProviderExpenseCategoryEntityConfigId ==. configId] []
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
            [ (unsafeExternalAccountId a.configBankAccountMapEntityExternalAccountId, a.configBankAccountMapEntityAccountId)
            | Entity _ a <- acctRows
            ]
    pure
      ( c.configBankConnectionEntityConnectionId,
        BankConnection
          { connectionId = c.configBankConnectionEntityConnectionId,
            provider = c.configBankConnectionEntityProvider,
            name = c.configBankConnectionEntityName,
            encryptedSecret = c.configBankConnectionEntityEncryptedSecret,
            secretHint = c.configBankConnectionEntitySecretHint,
            enabled = c.configBankConnectionEntityEnabled,
            accountMap = accountMap'
          }
      )
  pure
    emptyBankingConfiguration
      { bankProviderExpenseCategoryMap =
          Map.fromList
            [ (pc, m.configBankProviderExpenseCategoryEntityCategoryId)
            | Entity _ m <- bankProviderCategoryRows,
              Just pc <- [parseBankProviderCategoryKey m.configBankProviderExpenseCategoryEntityBankProviderCategory]
            ],
        connections = Map.fromList conns
      }
