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
    BankingConfiguration (mccExpenseCategoryMap, connections),
    emptyBankingConfiguration,

    -- * Defaults Sub-record
    ConfigurationDefaults (..),
    emptyConfigurationDefaults,

    -- * Bank Connections
    BankConnection (..),

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
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Banking.Types
  ( BankConnectionId,
    BankConnectionName,
    BankProvider,
    ExternalAccountId,
  )
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
    configurationEvents,
  )
import Domain.Core.Types
  ( AccountId,
    AccountSubtypeKind,
    CategoryId,
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
import Infrastructure.Crypto.SecretBox (EncryptedSecret)

-- -----------------------------------------------------------------------------
-- Configuration Aggregate State
-- -----------------------------------------------------------------------------

-- | Banking-specific configuration derived from banking-related events.
--
-- This sub-record collects all bank-import settings in one place so the
-- main 'Configuration' record stays readable. The field is empty on every
-- projection that has not yet received any banking events.
data BankingConfiguration = BankingConfiguration
  { -- | Mapping from MCC codes to expense category IDs for automatic categorisation
    mccExpenseCategoryMap :: !(Map MCC CategoryId),
    -- | Configured bank connections, keyed by connection ID
    connections :: !(Map BankConnectionId BankConnection)
  }
  deriving (Show, Eq)

-- | A configured bank connection (spec §2.1).
data BankConnection = BankConnection
  { -- | Unique identifier for the connection
    connectionId :: BankConnectionId,
    -- | The external bank provider
    provider :: BankProvider,
    -- | User-facing display name
    name :: BankConnectionName,
    -- | The encrypted provider token
    encryptedToken :: EncryptedSecret,
    -- | Non-secret hint to help the user recognise the token
    tokenHint :: Text,
    -- | Whether the connection is enabled for syncing
    enabled :: Bool,
    -- | Mapping from external account IDs to local account IDs
    accountMap :: Map ExternalAccountId AccountId
  }
  deriving (Show, Eq)

-- | The empty banking configuration used as the initial state.
emptyBankingConfiguration :: BankingConfiguration
emptyBankingConfiguration =
  BankingConfiguration
    { mccExpenseCategoryMap = Map.empty,
      connections = Map.empty
    }

-- | All per-configuration defaults, grouped in one sub-record (mirrors the
-- 'BankingConfiguration' sub-record).
--
--   * 'incomeCategory' / 'expenseCategory' — global default categories used when
--     none is inferred (e.g. from MCC or an NL prompt).
--   * 'account' — the global fallback account (no account named, or subtype
--     unidentifiable).
--   * 'subtypeAccounts' — the default account per account subtype.
data ConfigurationDefaults = ConfigurationDefaults
  { incomeCategory :: !(Maybe CategoryId),
    expenseCategory :: !(Maybe CategoryId),
    account :: !(Maybe AccountId),
    subtypeAccounts :: !(Map AccountSubtypeKind AccountId)
  }
  deriving (Show, Eq)

-- | The empty defaults used as the initial state.
emptyConfigurationDefaults :: ConfigurationDefaults
emptyConfigurationDefaults =
  ConfigurationDefaults
    { incomeCategory = Nothing,
      expenseCategory = Nothing,
      account = Nothing,
      subtypeAccounts = Map.empty
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
    booksClosedThrough :: Maybe UTCTime,
    -- | All per-configuration defaults (categories + accounts), grouped.
    defaults :: ConfigurationDefaults
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
      booksClosedThrough = Nothing,
      defaults = emptyConfigurationDefaults
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

-- | Apply a function to the connection with the given ID, leaving the rest of
-- the configuration unchanged. The explicit 'BankConnection' type on the
-- adjusting function disambiguates the duplicate record fields it updates.
adjustConnection ::
  BankConnectionId ->
  (BankConnection -> BankConnection) ->
  Configuration ->
  Configuration
adjustConnection connId f c =
  c {banking = c.banking {connections = Map.adjust f connId c.banking.connections}}

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
      booksClosedThrough = booksClosedThrough,
      defaults = defaults
    }
handleConfigurationEvent Configuration {..} (DefaultCurrencyChangedConfigurationEvent evt) =
  Configuration
    { baseCurrency = baseCurrency,
      defaultCurrency = evt.defaultCurrency,
      dictionaries = dictionaries,
      banking = banking,
      createdBy = createdBy,
      isCreated = isCreated,
      booksClosedThrough = booksClosedThrough,
      defaults = defaults
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
handleConfigurationEvent config (DefaultIncomeCategorySetConfigurationEvent evt) =
  config {defaults = config.defaults {incomeCategory = Just evt.categoryId}}
handleConfigurationEvent config (DefaultExpenseCategorySetConfigurationEvent evt) =
  config {defaults = config.defaults {expenseCategory = Just evt.categoryId}}
handleConfigurationEvent config (DefaultAccountSetConfigurationEvent evt) =
  config {defaults = config.defaults {account = Just evt.accountId}}
handleConfigurationEvent config (DefaultSubtypeAccountsSetConfigurationEvent evt) =
  -- Rebuild the sub-record explicitly: 'subtypeAccounts' is a duplicate field
  -- name (shared with the event/command), so a bare record update is ambiguous.
  let d = config.defaults
   in config
        { defaults =
            ConfigurationDefaults
              { incomeCategory = d.incomeCategory,
                expenseCategory = d.expenseCategory,
                account = d.account,
                subtypeAccounts = evt.subtypeAccounts
              }
        }
handleConfigurationEvent config (BankingMccExpenseCategoryMapSetConfigurationEvent evt) =
  config {banking = config.banking {mccExpenseCategoryMap = evt.mapping}}
handleConfigurationEvent config (BooksClosedThroughSetConfigurationEvent evt) =
  config {booksClosedThrough = Just evt.closedThrough}
handleConfigurationEvent c (BankConnectionAddedConfigurationEvent e) =
  let conn =
        BankConnection
          { connectionId = e.connectionId,
            provider = e.provider,
            name = e.name,
            encryptedToken = e.encryptedToken,
            tokenHint = e.tokenHint,
            enabled = e.enabled,
            accountMap = Map.empty
          }
   in c {banking = c.banking {connections = Map.insert e.connectionId conn c.banking.connections}}
handleConfigurationEvent c (BankConnectionRenamedConfigurationEvent e) =
  adjustConnection
    e.connectionId
    (\x -> x {connectionId = x.connectionId, provider = x.provider, name = e.name, encryptedToken = x.encryptedToken, tokenHint = x.tokenHint, enabled = x.enabled, accountMap = x.accountMap})
    c
handleConfigurationEvent c (BankConnectionTokenChangedConfigurationEvent e) =
  adjustConnection
    e.connectionId
    (\x -> x {connectionId = x.connectionId, provider = x.provider, name = x.name, encryptedToken = e.encryptedToken, tokenHint = e.tokenHint, enabled = x.enabled, accountMap = x.accountMap})
    c
handleConfigurationEvent c (BankConnectionEnabledSetConfigurationEvent e) =
  adjustConnection
    e.connectionId
    (\x -> x {connectionId = x.connectionId, provider = x.provider, name = x.name, encryptedToken = x.encryptedToken, tokenHint = x.tokenHint, enabled = e.enabled, accountMap = x.accountMap})
    c
handleConfigurationEvent c (BankConnectionAccountMapSetConfigurationEvent e) =
  adjustConnection
    e.connectionId
    (\x -> x {connectionId = x.connectionId, provider = x.provider, name = x.name, encryptedToken = x.encryptedToken, tokenHint = x.tokenHint, enabled = x.enabled, accountMap = e.accountMap})
    c
handleConfigurationEvent c (BankConnectionRemovedConfigurationEvent e) =
  c {banking = c.banking {connections = Map.delete e.connectionId c.banking.connections}}

-- -----------------------------------------------------------------------------
-- Projection Definition
-- -----------------------------------------------------------------------------

-- | The configuration projection that rebuilds aggregate state from events.
configurationProjection :: Projection Configuration ConfigurationEvent
configurationProjection = Projection configurationDefault handleConfigurationEvent
