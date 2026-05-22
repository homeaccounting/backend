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
    SetBankingDefaultIncomeCategory (..),
    SetBankingDefaultExpenseCategory (..),
    SetBankingMccExpenseCategoryMap (..),
    CloseBooksThrough (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Map.Strict (Map)
import Data.Time (UTCTime)
import Domain.Core.Types (CategoryId, CreatedBy, Currency, DictionaryEntryId, DictionaryId, EntryName, MCC)
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
    ''SetBankingDefaultIncomeCategory,
    ''SetBankingDefaultExpenseCategory,
    ''SetBankingMccExpenseCategoryMap,
    ''CloseBooksThrough
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
    dictionaryId :: DictionaryId,
    -- | Unique identifier for the new entry
    entryId :: DictionaryEntryId,
    -- | Display name of the new entry
    name :: EntryName
  }
  deriving (Show, Eq)

-- | Command to rename an entry in a dictionary.
--
-- If accepted, produces a DictionaryEntryRenamed event.
data RenameDictionaryEntry = RenameDictionaryEntry
  { -- | Dictionary containing the entry
    dictionaryId :: DictionaryId,
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
    dictionaryId :: DictionaryId,
    -- | Identifier of the entry to remove
    entryId :: DictionaryEntryId
  }
  deriving (Show, Eq)

-- | Command to set the banking default category for imported income transactions.
data SetBankingDefaultIncomeCategory = SetBankingDefaultIncomeCategory
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

-- | Command to set the banking default category for imported expense transactions.
data SetBankingDefaultExpenseCategory = SetBankingDefaultExpenseCategory
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

-- | Command to replace the banking MCC -> expense category map wholesale.
data SetBankingMccExpenseCategoryMap = SetBankingMccExpenseCategoryMap
  { mapping :: Map MCC CategoryId
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
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands
deriveJSON defaultOptions ''CreateConfiguration
deriveJSON defaultOptions ''ChangeBaseCurrency
deriveJSON defaultOptions ''ChangeDefaultCurrency
deriveJSON defaultOptions ''AddDictionaryEntry
deriveJSON defaultOptions ''RenameDictionaryEntry
deriveJSON defaultOptions ''RemoveDictionaryEntry
deriveJSON defaultOptions ''SetBankingDefaultIncomeCategory
deriveJSON defaultOptions ''SetBankingDefaultExpenseCategory
deriveJSON defaultOptions ''SetBankingMccExpenseCategoryMap
deriveJSON defaultOptions ''CloseBooksThrough
