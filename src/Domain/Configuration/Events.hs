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
    DefaultIncomeCategorySet (..),
    DefaultExpenseCategorySet (..),
    DefaultAccountSet (..),
    DefaultSubtypeAccountsSet (..),
    BankingMccExpenseCategoryMapSet (..),
    BooksClosedThroughSet (..),
    BankConnectionAdded (..),
    BankConnectionRenamed (..),
    BankConnectionCredentialChanged (..),
    BankConnectionEnabledSet (..),
    BankConnectionAccountMapSet (..),
    BankConnectionRemoved (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Banking.Types
  ( BankConnectionId,
    BankConnectionName,
    BankProviderId,
    ExternalAccountId,
  )
import Domain.Core.Types
  ( AccountId,
    AccountSubtypeKind,
    CategoryId,
    CreatedBy,
    Currency,
    DictionaryEntryId,
    DictionaryId,
    EntryName,
    MCC,
  )
import Infrastructure.Crypto.SecretBox (EncryptedSecret)
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
    ''DictionaryEntryRemoved,
    ''DefaultIncomeCategorySet,
    ''DefaultExpenseCategorySet,
    ''DefaultAccountSet,
    ''DefaultSubtypeAccountsSet,
    ''BankingMccExpenseCategoryMapSet,
    ''BooksClosedThroughSet,
    ''BankConnectionAdded,
    ''BankConnectionRenamed,
    ''BankConnectionCredentialChanged,
    ''BankConnectionEnabledSet,
    ''BankConnectionAccountMapSet,
    ''BankConnectionRemoved
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

-- | Event emitted when the default income category is set.
data DefaultIncomeCategorySet = DefaultIncomeCategorySet
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

-- | Event emitted when the default expense category is set.
data DefaultExpenseCategorySet = DefaultExpenseCategorySet
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

-- | Event emitted when the global default account is set.
newtype DefaultAccountSet = DefaultAccountSet
  { accountId :: AccountId
  }
  deriving (Show, Eq)

-- | Event emitted when the per-subtype default-account map is set (bulk replace).
newtype DefaultSubtypeAccountsSet = DefaultSubtypeAccountsSet
  { subtypeAccounts :: Map AccountSubtypeKind AccountId
  }
  deriving (Show, Eq)

-- | Event emitted when the banking MCC -> expense category map is set (bulk replace).
data BankingMccExpenseCategoryMapSet = BankingMccExpenseCategoryMapSet
  { mapping :: Map MCC CategoryId
  }
  deriving (Show, Eq)

-- | Event emitted when the books-closed-through cutoff is advanced.
--
-- The cutoff is advance-only: any attempt to set the cutoff to a value at or
-- before the current cutoff is rejected by the command handler, so only
-- advancing events ever reach the projection.
newtype BooksClosedThroughSet = BooksClosedThroughSet
  { -- | New books-closed-through cutoff (strictly later than the previous one).
    closedThrough :: UTCTime
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Bank Connection Events
-- -----------------------------------------------------------------------------

-- | Event emitted when a new bank connection is added.
--
-- The account map starts empty; it is populated later via
-- 'BankConnectionAccountMapSet'. The credential is OPTIONAL: connections to a
-- provider with no pull/API transport (e.g. a file-only provider) carry no
-- secret.
data BankConnectionAdded = BankConnectionAdded
  { -- | Unique identifier for the new connection
    connectionId :: BankConnectionId,
    -- | The external bank provider
    provider :: BankProviderId,
    -- | User-facing display name
    name :: BankConnectionName,
    -- | The encrypted provider secret, if any.
    encryptedSecret :: Maybe EncryptedSecret,
    -- | Non-secret hint to help the user recognise the secret, if any.
    secretHint :: Maybe Text,
    -- | Whether the connection is enabled for syncing
    enabled :: Bool
  }
  deriving (Show, Eq)

-- | Event emitted when a bank connection is renamed.
data BankConnectionRenamed = BankConnectionRenamed
  { connectionId :: BankConnectionId,
    name :: BankConnectionName
  }
  deriving (Show, Eq)

-- | Event emitted when a bank connection's credential is changed.
data BankConnectionCredentialChanged = BankConnectionCredentialChanged
  { connectionId :: BankConnectionId,
    encryptedSecret :: EncryptedSecret,
    secretHint :: Text
  }
  deriving (Show, Eq)

-- | Event emitted when a bank connection's enabled flag is set.
data BankConnectionEnabledSet = BankConnectionEnabledSet
  { connectionId :: BankConnectionId,
    enabled :: Bool
  }
  deriving (Show, Eq)

-- | Event emitted when a bank connection's account map is set (bulk replace).
data BankConnectionAccountMapSet = BankConnectionAccountMapSet
  { connectionId :: BankConnectionId,
    accountMap :: Map ExternalAccountId AccountId
  }
  deriving (Show, Eq)

-- | Event emitted when a bank connection is removed.
newtype BankConnectionRemoved = BankConnectionRemoved
  { connectionId :: BankConnectionId
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
deriveJSON defaultOptions ''DefaultIncomeCategorySet
deriveJSON defaultOptions ''DefaultExpenseCategorySet
deriveJSON defaultOptions ''DefaultAccountSet
deriveJSON defaultOptions ''DefaultSubtypeAccountsSet
deriveJSON defaultOptions ''BankingMccExpenseCategoryMapSet
deriveJSON defaultOptions ''BooksClosedThroughSet
deriveJSON defaultOptions ''BankConnectionAdded
deriveJSON defaultOptions ''BankConnectionRenamed
deriveJSON defaultOptions ''BankConnectionCredentialChanged
deriveJSON defaultOptions ''BankConnectionEnabledSet
deriveJSON defaultOptions ''BankConnectionAccountMapSet
deriveJSON defaultOptions ''BankConnectionRemoved
