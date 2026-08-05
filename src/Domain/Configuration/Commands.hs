{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Configuration.Commands
-- Description : Commands for the Configuration aggregate
--
-- This module defines all commands that can be issued to the Configuration aggregate.
-- Commands represent intentions to perform actions that may succeed or fail based
-- on the current aggregate state and business rules.
--
-- All commands use Template Haskell for integration with the eventium library
-- and include JSON serialization instances for API integration.
module Domain.Configuration.Commands
  ( -- * Command List
    configurationCommands,

    -- * Configuration Commands
    CreateConfiguration (..),
    ChangeBaseCurrency (..),
    ChangeDefaultCurrency (..),
    AddDictionaryEntry (..),
    RenameDictionaryEntry (..),
    RemoveDictionaryEntry (..),
    MoveDictionaryEntry (..),
    SetDefaultIncomeCategory (..),
    SetDefaultExpenseCategory (..),
    SetDefaultAccount (..),
    SetDefaultSubtypeAccounts (..),
    SetBankProviderExpenseCategoryMap (..),
    CloseBooksThrough (..),
    AddBankConnection (..),
    RenameBankConnection (..),
    ChangeBankConnectionCredential (..),
    SetBankConnectionEnabled (..),
    SetBankConnectionAccountMap (..),
    RemoveBankConnection (..),
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
import Domain.Configuration.Dictionary (DictionaryKind, EntryRole)
import Domain.Core.Types
  ( AccountId,
    AccountSubtypeKind,
    BankProviderCategory,
    CategoryId,
    CreatedBy,
    Currency,
    DictionaryEntryId,
    EntryName,
  )
import Infrastructure.Crypto.SecretBox (EncryptedSecret)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Command List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all configuration command type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the ConfigurationCommand sum type and related serialization code.
configurationCommands :: [Name]
configurationCommands =
  [ ''CreateConfiguration,
    ''ChangeBaseCurrency,
    ''ChangeDefaultCurrency,
    ''AddDictionaryEntry,
    ''RenameDictionaryEntry,
    ''RemoveDictionaryEntry,
    ''MoveDictionaryEntry,
    ''SetDefaultIncomeCategory,
    ''SetDefaultExpenseCategory,
    ''SetDefaultAccount,
    ''SetDefaultSubtypeAccounts,
    ''SetBankProviderExpenseCategoryMap,
    ''CloseBooksThrough,
    ''AddBankConnection,
    ''RenameBankConnection,
    ''ChangeBankConnectionCredential,
    ''SetBankConnectionEnabled,
    ''SetBankConnectionAccountMap,
    ''RemoveBankConnection
  ]

-- -----------------------------------------------------------------------------
-- Configuration Commands
-- -----------------------------------------------------------------------------

-- | Command to create a new configuration.
--
-- If accepted, produces a ConfigurationCreated event.
data CreateConfiguration = CreateConfiguration
  { -- | Base currency for reporting
    baseCurrency :: Currency,
    -- | Default currency for new accounts
    defaultCurrency :: Currency,
    -- | Who is creating this configuration
    createdBy :: CreatedBy
  }
  deriving (Show, Eq)

-- | Command to change the base currency.
--
-- If accepted, produces a BaseCurrencyChanged event.
data ChangeBaseCurrency = ChangeBaseCurrency
  { -- | New base currency
    baseCurrency :: Currency
  }
  deriving (Show, Eq)

-- | Command to change the default currency for new accounts.
--
-- If accepted, produces a DefaultCurrencyChanged event.
data ChangeDefaultCurrency = ChangeDefaultCurrency
  { -- | New default currency
    defaultCurrency :: Currency
  }
  deriving (Show, Eq)

-- | Command to add an entry to a dictionary.
--
-- If the dictionary does not exist, it is auto-created.
-- If accepted, produces a DictionaryEntryAdded event.
data AddDictionaryEntry = AddDictionaryEntry
  { -- | Dictionary to add the entry to
    dictionaryKind :: DictionaryKind,
    -- | Unique identifier for the new entry
    entryId :: DictionaryEntryId,
    -- | Display name of the new entry
    name :: EntryName,
    -- | Whether the new entry is a group (container) or item (leaf). Immutable.
    role :: EntryRole,
    -- | Parent group, or 'Nothing' for a root-level node
    parentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq)

-- | Command to rename an entry in a dictionary.
--
-- If accepted, produces a DictionaryEntryRenamed event.
data RenameDictionaryEntry = RenameDictionaryEntry
  { -- | Dictionary containing the entry
    dictionaryKind :: DictionaryKind,
    -- | Identifier of the entry to rename
    entryId :: DictionaryEntryId,
    -- | New display name
    newName :: EntryName
  }
  deriving (Show, Eq)

-- | Command to remove an entry from a dictionary.
--
-- If accepted, produces a DictionaryEntryRemoved event.
--
-- Business Rules:
--   - Cannot remove the last entry in a dictionary
data RemoveDictionaryEntry = RemoveDictionaryEntry
  { -- | Dictionary containing the entry
    dictionaryKind :: DictionaryKind,
    -- | Identifier of the entry to remove
    entryId :: DictionaryEntryId
  }
  deriving (Show, Eq)

-- | Command to move an entry to a new parent group (or to the root).
--
-- If accepted, produces a DictionaryEntryMoved event.
data MoveDictionaryEntry = MoveDictionaryEntry
  { -- | Dictionary containing the entry
    dictionaryKind :: DictionaryKind,
    -- | Identifier of the entry to move
    entryId :: DictionaryEntryId,
    -- | New parent group, or 'Nothing' to move to the root
    newParentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq)

-- | Command to set the default category for imported income transactions.
data SetDefaultIncomeCategory = SetDefaultIncomeCategory
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

-- | Command to set the default category for imported expense transactions.
data SetDefaultExpenseCategory = SetDefaultExpenseCategory
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

-- | Command to set the global default account. Account existence/ownership is
-- validated in the service layer (the aggregate has no account view).
newtype SetDefaultAccount = SetDefaultAccount
  { accountId :: AccountId
  }
  deriving (Show, Eq)

-- | Command to replace the per-subtype default-account map wholesale. Account
-- existence/ownership is validated in the service layer.
newtype SetDefaultSubtypeAccounts = SetDefaultSubtypeAccounts
  { subtypeAccounts :: Map AccountSubtypeKind AccountId
  }
  deriving (Show, Eq)

-- | Command to replace the banking provider-category -> expense category map
-- wholesale. Keys are 'BankProviderCategory' values (an MCC or a provider text
-- label); values are expense category ids.
data SetBankProviderExpenseCategoryMap = SetBankProviderExpenseCategoryMap
  { mapping :: Map BankProviderCategory CategoryId
  }
  deriving (Show, Eq)

-- | Command to advance the books-closed-through cutoff.
--
-- The cutoff is advance-only: the command handler rejects any value at or
-- before the configuration's current cutoff with
-- 'Domain.Configuration.CommandHandler.CannotRewindBooksCloseDate'.
--
-- If accepted, produces a 'Domain.Configuration.Events.BooksClosedThroughSet'
-- event.
newtype CloseBooksThrough = CloseBooksThrough
  { -- | Proposed new cutoff. Must be strictly greater than any previous cutoff.
    closedThrough :: UTCTime
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Bank Connection Commands
-- -----------------------------------------------------------------------------

-- | Command to add a new bank connection.
--
-- The secret is **already encrypted** by the time this command is issued —
-- encryption happens in the service layer, not the aggregate. The handler does
-- no validation beyond emitting the event; the @connectionId@ is freshly
-- generated by the caller.
--
-- The credential is OPTIONAL: providers with no pull/API transport (e.g. a
-- file-only provider) have no secret to store. Whether a credential is
-- required for a given provider is decided by the service/web layer (which
-- has access to the provider registry), not by the aggregate.
--
-- If accepted, produces a 'Domain.Configuration.Events.BankConnectionAdded'
-- event.
data AddBankConnection = AddBankConnection
  { -- | Freshly generated identifier for the new connection
    connectionId :: BankConnectionId,
    -- | The external bank provider
    provider :: BankProviderId,
    -- | User-facing display name
    name :: BankConnectionName,
    -- | The already-encrypted provider secret, if any. 'Nothing' for
    -- connections whose provider has no pull transport.
    encryptedSecret :: Maybe EncryptedSecret,
    -- | Non-secret hint to help the user recognise the secret, if any.
    secretHint :: Maybe Text,
    -- | Whether the connection is enabled for syncing
    enabled :: Bool
  }
  deriving (Show, Eq)

-- | Command to rename an existing bank connection.
--
-- If accepted, produces a 'Domain.Configuration.Events.BankConnectionRenamed'
-- event. Rejected with
-- 'Domain.Configuration.CommandHandler.BankConnectionNotFound' if the
-- connection does not exist.
data RenameBankConnection = RenameBankConnection
  { connectionId :: BankConnectionId,
    name :: BankConnectionName
  }
  deriving (Show, Eq)

-- | Command to change an existing bank connection's credential.
--
-- The secret is **already encrypted** (re-encrypted in the service layer).
-- If accepted, produces a
-- 'Domain.Configuration.Events.BankConnectionCredentialChanged' event.
data ChangeBankConnectionCredential = ChangeBankConnectionCredential
  { connectionId :: BankConnectionId,
    encryptedSecret :: EncryptedSecret,
    secretHint :: Text
  }
  deriving (Show, Eq)

-- | Command to enable or disable an existing bank connection.
--
-- If accepted, produces a
-- 'Domain.Configuration.Events.BankConnectionEnabledSet' event.
data SetBankConnectionEnabled = SetBankConnectionEnabled
  { connectionId :: BankConnectionId,
    enabled :: Bool
  }
  deriving (Show, Eq)

-- | Command to replace a bank connection's external-account map wholesale.
--
-- Within-config uniqueness is enforced by the handler: an 'AccountId' that is
-- already a target of a /different/ connection is rejected with
-- 'Domain.Configuration.CommandHandler.BankConnectionAccountConflict'.
data SetBankConnectionAccountMap = SetBankConnectionAccountMap
  { connectionId :: BankConnectionId,
    accountMap :: Map ExternalAccountId AccountId
  }
  deriving (Show, Eq)

-- | Command to remove an existing bank connection.
--
-- If accepted, produces a 'Domain.Configuration.Events.BankConnectionRemoved'
-- event.
newtype RemoveBankConnection = RemoveBankConnection
  { connectionId :: BankConnectionId
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands
deriveJSON defaultOptions ''CreateConfiguration
deriveJSON defaultOptions ''ChangeBaseCurrency
deriveJSON defaultOptions ''ChangeDefaultCurrency
deriveJSON defaultOptions ''AddDictionaryEntry
deriveJSON defaultOptions ''RenameDictionaryEntry
deriveJSON defaultOptions ''RemoveDictionaryEntry
deriveJSON defaultOptions ''MoveDictionaryEntry
deriveJSON defaultOptions ''SetDefaultIncomeCategory
deriveJSON defaultOptions ''SetDefaultExpenseCategory
deriveJSON defaultOptions ''SetDefaultAccount
deriveJSON defaultOptions ''SetDefaultSubtypeAccounts
deriveJSON defaultOptions ''SetBankProviderExpenseCategoryMap
deriveJSON defaultOptions ''CloseBooksThrough
deriveJSON defaultOptions ''AddBankConnection
deriveJSON defaultOptions ''RenameBankConnection
deriveJSON defaultOptions ''ChangeBankConnectionCredential
deriveJSON defaultOptions ''SetBankConnectionEnabled
deriveJSON defaultOptions ''SetBankConnectionAccountMap
deriveJSON defaultOptions ''RemoveBankConnection
