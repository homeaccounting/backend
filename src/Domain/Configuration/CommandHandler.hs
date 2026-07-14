{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Configuration.CommandHandler
-- Description : Command handler for the Configuration aggregate
--
-- This module implements the command handler that validates configuration commands
-- against the current aggregate state and emits appropriate events.
--
-- Business Rules Enforced:
--   - CreateConfiguration: Cannot create if already created
--   - ChangeBaseCurrency: Configuration must exist
--   - ChangeDefaultCurrency: Configuration must exist
--   - AddDictionaryEntry: Configuration must exist, no duplicate entry names in same dictionary
--   - RenameDictionaryEntry: Configuration must exist, dictionary and entry must exist, no duplicate names
--   - RemoveDictionaryEntry: Configuration must exist, dictionary and entry must exist, cannot remove last entry,
--       cannot remove entry set as global default or referenced by MCC map
--   - SetDefaultIncomeCategory: Category must exist in income-category dictionary
--   - SetDefaultExpenseCategory: Category must exist in expense-category dictionary
--   - SetBankingMccExpenseCategoryMap: All map values must exist in expense-category dictionary
module Domain.Configuration.CommandHandler
  ( -- * Command Sum Type
    ConfigurationCommand (..),

    -- * Command Errors
    ConfigurationError (..),

    -- * Command Handler
    configurationCommandHandler,

    -- * Handler Function (exported for testing)
    handleConfigurationCommand,
  )
where

import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Domain.Banking.Types (BankConnectionId, ExternalAccountId)
import Domain.Configuration.Commands
import Domain.Configuration.Defaults (expenseCategoryDictId, incomeCategoryDictId)
import Domain.Configuration.Events
import Domain.Configuration.Projection
import Domain.Core.Types (AccountId, CategoryId, Dictionary (..), DictionaryEntry (..), DictionaryEntryId, DictionaryId (..), EntryName)
import Eventium (CommandHandler (..))
import Eventium.TH.SumType (SumTypeTagOptions (AppendTypeNameToTags), constructSumType, defaultSumTypeOptions, withTagOptions)

-- -----------------------------------------------------------------------------
-- Command Errors
-- -----------------------------------------------------------------------------

-- | Errors that can occur when handling configuration commands.
--
-- These are aggregate-local errors. The service layer translates them into
-- their 'Domain.Core.Errors.DomainError' counterparts before surfacing to
-- the HTTP layer.
data ConfigurationError
  = ConfigurationAlreadyExists
  | ConfigurationNotCreated
  | DictionaryNotFound
  | EntryNotFound
  | DuplicateEntryName
  | CannotRemoveLastEntry
  | EntryNotInDictionary
  | EntryIsGlobalDefault
  | EntryIsInMccMap
  | -- | 'CloseBooksThrough' would rewind (or leave unchanged) the cutoff.
    -- The cutoff is advance-only: @attempted@ must be strictly greater than
    -- @current@.
    CannotRewindBooksCloseDate
      { current :: UTCTime,
        attempted :: UTCTime
      }
  | -- | A bank-connection command targeted a connection that does not exist.
    BankConnectionNotFound
  | -- | A bank connection's account map references a local account that is
    -- already a target of a /different/ connection in this configuration.
    BankConnectionAccountConflict
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Command Sum Type Construction
-- -----------------------------------------------------------------------------

-- | Generate the ConfigurationCommand sum type from individual command types.
constructSumType
  "ConfigurationCommand"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  configurationCommands

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Check if a dictionary exists in the configuration.
dictionaryExists :: DictionaryId -> Configuration -> Bool
dictionaryExists dictId config = Map.member dictId config.dictionaries

-- | Check if an entry exists in a dictionary.
entryExists :: DictionaryEntryId -> DictionaryId -> Configuration -> Bool
entryExists eid dictId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.entryId == eid) dict.entries

-- | Check if a dictionary already has an entry with the given name.
hasDuplicateName :: EntryName -> DictionaryId -> Configuration -> Bool
hasDuplicateName ename dictId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.name == ename) dict.entries

-- | Dictionaries that must never become empty.
-- income-category and expense-category are required because every Income
-- and Expense transaction references exactly one entry.
-- The `labels` dictionary is optional — may be emptied freely.
requiresNonEmpty :: DictionaryId -> Bool
requiresNonEmpty (DictionaryId "income-category") = True
requiresNonEmpty (DictionaryId "expense-category") = True
requiresNonEmpty _ = False

-- | Check whether removing the targeted entry would empty a required dictionary.
wouldEmptyRequiredDictionary :: DictionaryId -> Configuration -> Bool
wouldEmptyRequiredDictionary dictId config
  | not (requiresNonEmpty dictId) = False
  | otherwise =
      case Map.lookup dictId config.dictionaries of
        Nothing -> False
        Just dict -> length dict.entries == 1

-- | Reject the command if the given entry is not a member of the given dictionary.
requireEntryIn :: DictionaryId -> CategoryId -> Configuration -> Either ConfigurationError ()
requireEntryIn dictId entryId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> Left EntryNotInDictionary
    Just dict
      | any (\e -> e.entryId == entryId) dict.entries -> Right ()
      | otherwise -> Left EntryNotInDictionary

-- | Check if an entry is currently set as a global default category.
isGlobalDefault :: CategoryId -> Configuration -> Bool
isGlobalDefault eid config =
  config.defaults.incomeCategory == Just eid
    || config.defaults.expenseCategory == Just eid

-- | Check if an entry is referenced as a value in the banking MCC expense category map.
isInMccMap :: CategoryId -> Configuration -> Bool
isInMccMap eid config = eid `elem` Map.elems config.banking.mccExpenseCategoryMap

-- | Reject the command if the targeted bank connection does not exist.
requireConnection :: BankConnectionId -> Configuration -> Either ConfigurationError ()
requireConnection connId config
  | Map.member connId config.banking.connections = Right ()
  | otherwise = Left BankConnectionNotFound

-- | Reject the command if any 'AccountId' in the proposed account map is already
-- a target of a /different/ connection's account map (within-config uniqueness).
requireNoAccountConflict ::
  BankConnectionId ->
  Map.Map ExternalAccountId AccountId ->
  Configuration ->
  Either ConfigurationError ()
requireNoAccountConflict connId proposed config
  | any (`elem` takenByOthers) (Map.elems proposed) = Left BankConnectionAccountConflict
  | otherwise = Right ()
  where
    takenByOthers :: [AccountId]
    takenByOthers =
      concatMap (Map.elems . (.accountMap)) $
        Map.elems $
          Map.delete connId config.banking.connections

-- -----------------------------------------------------------------------------
-- Command Handler Function
-- -----------------------------------------------------------------------------

-- | Handle a configuration command and produce events.
--
-- This function implements the business logic for validating commands against
-- the current aggregate state. It is pure and deterministic.
handleConfigurationCommand :: Configuration -> ConfigurationCommand -> Either ConfigurationError [ConfigurationEvent]
-- Handle CreateConfiguration command
handleConfigurationCommand config (CreateConfigurationConfigurationCommand CreateConfiguration {..})
  | config.isCreated = Left ConfigurationAlreadyExists
  | otherwise =
      Right
        [ ConfigurationCreatedConfigurationEvent
            ConfigurationCreated
              { baseCurrency = baseCurrency,
                defaultCurrency = defaultCurrency,
                createdBy = createdBy
              }
        ]
-- Handle ChangeBaseCurrency command
handleConfigurationCommand config (ChangeBaseCurrencyConfigurationCommand ChangeBaseCurrency {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      Right
        [ BaseCurrencyChangedConfigurationEvent
            BaseCurrencyChanged
              { baseCurrency = baseCurrency
              }
        ]
-- Handle ChangeDefaultCurrency command
handleConfigurationCommand config (ChangeDefaultCurrencyConfigurationCommand ChangeDefaultCurrency {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      Right
        [ DefaultCurrencyChangedConfigurationEvent
            DefaultCurrencyChanged
              { defaultCurrency = defaultCurrency
              }
        ]
-- Handle AddDictionaryEntry command
handleConfigurationCommand config (AddDictionaryEntryConfigurationCommand AddDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | hasDuplicateName name dictionaryId config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryAddedConfigurationEvent
            DictionaryEntryAdded
              { dictionaryId = dictionaryId,
                entryId = entryId,
                name = name
              }
        ]
-- Handle RenameDictionaryEntry command
handleConfigurationCommand config (RenameDictionaryEntryConfigurationCommand RenameDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryId config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryId config) = Left EntryNotFound
  | hasDuplicateName newName dictionaryId config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryRenamedConfigurationEvent
            DictionaryEntryRenamed
              { dictionaryId = dictionaryId,
                entryId = entryId,
                newName = newName
              }
        ]
-- Handle RemoveDictionaryEntry command
handleConfigurationCommand config (RemoveDictionaryEntryConfigurationCommand RemoveDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryId config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryId config) = Left EntryNotFound
  | wouldEmptyRequiredDictionary dictionaryId config = Left CannotRemoveLastEntry
  | isGlobalDefault entryId config = Left EntryIsGlobalDefault
  | isInMccMap entryId config = Left EntryIsInMccMap
  | otherwise =
      Right
        [ DictionaryEntryRemovedConfigurationEvent
            DictionaryEntryRemoved
              { dictionaryId = dictionaryId,
                entryId = entryId
              }
        ]
-- Handle SetDefaultIncomeCategory command
handleConfigurationCommand config (SetDefaultIncomeCategoryConfigurationCommand SetDefaultIncomeCategory {..}) = do
  requireEntryIn incomeCategoryDictId categoryId config
  Right
    [ DefaultIncomeCategorySetConfigurationEvent
        DefaultIncomeCategorySet
          { categoryId = categoryId
          }
    ]
-- Handle SetDefaultExpenseCategory command
handleConfigurationCommand config (SetDefaultExpenseCategoryConfigurationCommand SetDefaultExpenseCategory {..}) = do
  requireEntryIn expenseCategoryDictId categoryId config
  Right
    [ DefaultExpenseCategorySetConfigurationEvent
        DefaultExpenseCategorySet
          { categoryId = categoryId
          }
    ]
-- Handle SetDefaultAccount command (emitted unconditionally; account ownership
-- is validated in the service layer)
handleConfigurationCommand _ (SetDefaultAccountConfigurationCommand SetDefaultAccount {..}) =
  Right
    [ DefaultAccountSetConfigurationEvent
        DefaultAccountSet {accountId = accountId}
    ]
-- Handle SetDefaultSubtypeAccounts command (wholesale replace; ownership
-- validated in the service layer)
handleConfigurationCommand _ (SetDefaultSubtypeAccountsConfigurationCommand SetDefaultSubtypeAccounts {..}) =
  Right
    [ DefaultSubtypeAccountsSetConfigurationEvent
        DefaultSubtypeAccountsSet {subtypeAccounts = subtypeAccounts}
    ]
-- Handle SetBankingMccExpenseCategoryMap command
handleConfigurationCommand config (SetBankingMccExpenseCategoryMapConfigurationCommand SetBankingMccExpenseCategoryMap {..}) = do
  mapM_ (\cid -> requireEntryIn expenseCategoryDictId cid config) (Map.elems mapping)
  Right
    [ BankingMccExpenseCategoryMapSetConfigurationEvent
        BankingMccExpenseCategoryMapSet
          { mapping = mapping
          }
    ]
-- Handle CloseBooksThrough command (advance-only)
handleConfigurationCommand config (CloseBooksThroughConfigurationCommand CloseBooksThrough {..}) =
  case config.booksClosedThrough of
    Just cur
      | closedThrough <= cur ->
          Left
            CannotRewindBooksCloseDate
              { current = cur,
                attempted = closedThrough
              }
    _ ->
      Right
        [ BooksClosedThroughSetConfigurationEvent
            BooksClosedThroughSet
              { closedThrough = closedThrough
              }
        ]
-- Handle AddBankConnection command (no validation; fresh connectionId)
handleConfigurationCommand _ (AddBankConnectionConfigurationCommand AddBankConnection {..}) =
  Right
    [ BankConnectionAddedConfigurationEvent
        BankConnectionAdded
          { connectionId = connectionId,
            provider = provider,
            name = name,
            encryptedSecret = encryptedSecret,
            secretHint = secretHint,
            enabled = enabled
          }
    ]
-- Handle RenameBankConnection command
handleConfigurationCommand config (RenameBankConnectionConfigurationCommand RenameBankConnection {..}) = do
  requireConnection connectionId config
  Right
    [ BankConnectionRenamedConfigurationEvent
        BankConnectionRenamed
          { connectionId = connectionId,
            name = name
          }
    ]
-- Handle ChangeBankConnectionCredential command
handleConfigurationCommand config (ChangeBankConnectionCredentialConfigurationCommand ChangeBankConnectionCredential {..}) = do
  requireConnection connectionId config
  Right
    [ BankConnectionCredentialChangedConfigurationEvent
        BankConnectionCredentialChanged
          { connectionId = connectionId,
            encryptedSecret = encryptedSecret,
            secretHint = secretHint
          }
    ]
-- Handle SetBankConnectionEnabled command
handleConfigurationCommand config (SetBankConnectionEnabledConfigurationCommand SetBankConnectionEnabled {..}) = do
  requireConnection connectionId config
  Right
    [ BankConnectionEnabledSetConfigurationEvent
        BankConnectionEnabledSet
          { connectionId = connectionId,
            enabled = enabled
          }
    ]
-- Handle SetBankConnectionAccountMap command
handleConfigurationCommand config (SetBankConnectionAccountMapConfigurationCommand SetBankConnectionAccountMap {..}) = do
  requireConnection connectionId config
  requireNoAccountConflict connectionId accountMap config
  Right
    [ BankConnectionAccountMapSetConfigurationEvent
        BankConnectionAccountMapSet
          { connectionId = connectionId,
            accountMap = accountMap
          }
    ]
-- Handle RemoveBankConnection command
handleConfigurationCommand config (RemoveBankConnectionConfigurationCommand RemoveBankConnection {..}) = do
  requireConnection connectionId config
  Right
    [ BankConnectionRemovedConfigurationEvent
        BankConnectionRemoved
          { connectionId = connectionId
          }
    ]

-- -----------------------------------------------------------------------------
-- Command Handler
-- -----------------------------------------------------------------------------

-- | The configuration command handler for eventium integration.
configurationCommandHandler :: CommandHandler Configuration ConfigurationEvent ConfigurationCommand ConfigurationError
configurationCommandHandler = CommandHandler handleConfigurationCommand configurationProjection
