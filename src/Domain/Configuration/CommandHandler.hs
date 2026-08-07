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
--       cannot remove entry set as global default or referenced by the provider-category map
--   - SetDefaultIncomeCategory: Category must exist in income-category dictionary
--   - SetDefaultExpenseCategory: Category must exist in expense-category dictionary
--   - SetBankProviderExpenseCategoryMap: All map values must exist in expense-category dictionary
--   - SetBankProviderContactMap: All map values must exist in contact dictionary
module Domain.Configuration.CommandHandler
  ( -- * Command Sum Type
    ConfigurationCommand (..),

    -- * Command Errors
    ConfigurationError (..),

    -- * Command Handler
    configurationCommandHandler,

    -- * Handler Function (exported for testing)
    handleConfigurationCommand,

    -- * Tree helpers (exported for testing)
    maxDictionaryDepth,
    maxDepthForRole,
    isGroupEntry,
    entriesOf,
    lookupEntry,
    childrenOf,
    depthOf,
    descendantsOf,
    subtreeHeight,
  )
where

import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Time (UTCTime)
import Domain.Banking.Types (BankConnectionId, ExternalAccountId)
import Domain.Configuration.Commands
import Domain.Configuration.Defaults (expenseCategoryDictKind, incomeCategoryDictKind)
import Domain.Configuration.Dictionary (Dictionary (..), DictionaryEntry (..), DictionaryKind (..), EntryRole (..))
import Domain.Configuration.Events
import Domain.Configuration.Projection
import Domain.Core.Types (AccountId, CategoryId, ContactId, DictionaryEntryId, EntryName)
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
  | EntryIsInBankProviderExpenseCategoryMap
  | EntryIsInBankProviderContactMap
  | -- | An add/move named a parent entry that does not exist in the dictionary.
    ParentEntryNotFound
  | -- | An add/move named a parent that exists but is an item, not a group.
    -- Only groups may hold children (ADR 002).
    ParentNotAGroup
  | -- | A move would place an entry under itself or one of its own descendants,
    -- forming a cycle.
    MoveWouldCreateCycle
  | -- | An add/move would push a node beyond 'maxDictionaryDepth'.
    MaxDepthExceeded
  | -- | A remove targeted a group (a node that still has children).
    GroupNotEmpty
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
dictionaryExists :: DictionaryKind -> Configuration -> Bool
dictionaryExists kind config = Map.member kind config.dictionaries

-- | Check if an entry exists in a dictionary.
entryExists :: DictionaryEntryId -> DictionaryKind -> Configuration -> Bool
entryExists eid kind config =
  case Map.lookup kind config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.entryId == eid) dict.entries

-- | Look up an entry in a dictionary.
findEntry :: DictionaryEntryId -> DictionaryKind -> Configuration -> Maybe DictionaryEntry
findEntry eid kind config =
  case Map.lookup kind config.dictionaries of
    Nothing -> Nothing
    Just dict -> find (\e -> e.entryId == eid) dict.entries

-- | True if a sibling (same parent) in the dictionary already has this name.
-- @exclude@ skips a specific entry (used by rename so a no-op rename passes).
hasDuplicateSiblingName ::
  EntryName -> Maybe DictionaryEntryId -> Maybe DictionaryEntryId -> DictionaryKind -> Configuration -> Bool
hasDuplicateSiblingName ename parent exclude kind config =
  case Map.lookup kind config.dictionaries of
    Nothing -> False
    Just dict ->
      any
        (\e -> e.name == ename && e.parentId == parent && Just e.entryId /= exclude)
        dict.entries

-- -----------------------------------------------------------------------------
-- Tree helpers
-- -----------------------------------------------------------------------------

-- | Maximum nesting depth for dictionary entries. Root nodes are level 1; a
-- root group's items are level 2. Extend to 3 by bumping this constant and
-- relaxing the group rule (allow a group to hold sub-groups) — see
-- 'maxDepthForRole'.
maxDictionaryDepth :: Int
maxDictionaryDepth = 2 -- root nodes are level 1

-- | The deepest level at which a node of this role may sit. An item is a leaf
-- (may go to the full depth); a group must leave room for at least one level of
-- item children, so it is capped one level shallower. At 'maxDictionaryDepth'
-- = 2: items <= 2, groups <= 1 (root only). Bumping the constant to 3 lets
-- groups nest one level — the whole "extend to 3" change.
maxDepthForRole :: EntryRole -> Int
maxDepthForRole ItemRole = maxDictionaryDepth
maxDepthForRole GroupRole = maxDictionaryDepth - 1

-- | 'True' when the id resolves to a group entry in the list.
isGroupEntry :: DictionaryEntryId -> [DictionaryEntry] -> Bool
isGroupEntry eid es = maybe False (\e -> e.role == GroupRole) (lookupEntry eid es)

-- | All entries of a dictionary (empty when the dictionary is absent).
entriesOf :: DictionaryKind -> Configuration -> [DictionaryEntry]
entriesOf kind config = maybe [] (.entries) (Map.lookup kind config.dictionaries)

-- | Look up an entry by id within a flat entry list.
lookupEntry :: DictionaryEntryId -> [DictionaryEntry] -> Maybe DictionaryEntry
lookupEntry eid = find (\e -> e.entryId == eid)

-- | Direct children of a node within a flat entry list.
childrenOf :: DictionaryEntryId -> [DictionaryEntry] -> [DictionaryEntry]
childrenOf pid = filter (\e -> e.parentId == Just pid)

-- | Depth of a node counting itself: a root node is 1. Assumes the acyclic
-- invariant (enforced by the Add/Move parent-exists + cycle guards); the fuel
-- bound (the entry count) is a defensive backstop that also guarantees
-- termination. On fuel exhaustion — only reachable if stored data is corrupt
-- and cyclic — it fails SAFE by returning @maxDictionaryDepth + 1@, so the
-- depth guards reject (returning 'maxBound' here would overflow the callers'
-- @+ 1@ / @+ subtreeHeight@ into a negative and let the guard silently pass).
depthOf :: DictionaryEntryId -> [DictionaryEntry] -> Int
depthOf eid es = go (length es) eid
  where
    go 0 _ = maxDictionaryDepth + 1 -- fail safe: corrupt cycle in stored data
    go fuel x = case lookupEntry x es >>= (.parentId) of
      Nothing -> 1
      Just p -> 1 + go (fuel - 1) p

-- | All transitive descendants of a node (excludes the node itself). Assumes
-- the acyclic invariant (enforced by the Add/Move parent-exists + cycle
-- guards); unlike 'depthOf' it carries no fuel bound, so a corrupt cycle in
-- stored data would not terminate.
descendantsOf :: DictionaryEntryId -> [DictionaryEntry] -> [DictionaryEntryId]
descendantsOf eid es =
  let kids = map (.entryId) (childrenOf eid es)
   in kids <> concatMap (`descendantsOf` es) kids

-- | Height of the subtree rooted at a node counting itself: a leaf is 1.
subtreeHeight :: DictionaryEntryId -> [DictionaryEntry] -> Int
subtreeHeight eid es = case childrenOf eid es of
  [] -> 1
  kids -> 1 + maximum (map (\k -> subtreeHeight k.entryId es) kids)

-- | Dictionaries that must never become empty.
-- Income and expense categories are required because every Income
-- and Expense transaction references exactly one entry.
-- The labels dictionary is optional — may be emptied freely.
requiresNonEmpty :: DictionaryKind -> Bool
requiresNonEmpty IncomeKind = True
requiresNonEmpty ExpenseKind = True
requiresNonEmpty _ = False

-- | Check whether removing the targeted entry would empty a required dictionary.
wouldEmptyRequiredDictionary :: DictionaryKind -> Configuration -> Bool
wouldEmptyRequiredDictionary kind config
  | not (requiresNonEmpty kind) = False
  | otherwise =
      case Map.lookup kind config.dictionaries of
        Nothing -> False
        Just dict -> length dict.entries == 1

-- | Reject the command if the given entry is not a member of the given dictionary.
requireEntryIn :: DictionaryKind -> CategoryId -> Configuration -> Either ConfigurationError ()
requireEntryIn kind entryId config =
  case Map.lookup kind config.dictionaries of
    Nothing -> Left EntryNotInDictionary
    Just dict
      | any (\e -> e.entryId == entryId) dict.entries -> Right ()
      | otherwise -> Left EntryNotInDictionary

-- | Check if an entry is currently set as a global default category.
isGlobalDefault :: CategoryId -> Configuration -> Bool
isGlobalDefault eid config =
  config.defaults.incomeCategory == Just eid
    || config.defaults.expenseCategory == Just eid

-- | Check if an entry is referenced as a value in the banking provider-category map.
isInBankProviderExpenseCategoryMap :: CategoryId -> Configuration -> Bool
isInBankProviderExpenseCategoryMap eid config = eid `elem` Map.elems config.banking.bankProviderExpenseCategoryMap

-- | Check if an entry is referenced as a value in the banking provider-contact map.
isInBankProviderContactMap :: ContactId -> Configuration -> Bool
isInBankProviderContactMap eid config = eid `elem` Map.elems config.banking.bankProviderContactMap

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
  | hasDuplicateSiblingName name parentId Nothing dictionaryKind config = Left DuplicateEntryName
  | Just p <- parentId, isNothing (lookupEntry p es) = Left ParentEntryNotFound
  | Just p <- parentId, not (isGroupEntry p es) = Left ParentNotAGroup
  | parentDepth + 1 > maxDepthForRole role = Left MaxDepthExceeded
  | otherwise =
      Right
        [ DictionaryEntryAddedConfigurationEvent
            DictionaryEntryAdded
              { dictionaryKind = dictionaryKind,
                entryId = entryId,
                name = name,
                role = role,
                parentId = parentId
              }
        ]
  where
    es = entriesOf dictionaryKind config
    parentDepth = maybe 0 (`depthOf` es) parentId
-- Handle RenameDictionaryEntry command
handleConfigurationCommand config (RenameDictionaryEntryConfigurationCommand RenameDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryKind config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryKind config) = Left EntryNotFound
  | hasDuplicateSiblingName newName entryParent (Just entryId) dictionaryKind config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryRenamedConfigurationEvent
            DictionaryEntryRenamed
              { dictionaryKind = dictionaryKind,
                entryId = entryId,
                newName = newName
              }
        ]
  where
    entryParent = findEntry entryId dictionaryKind config >>= (.parentId)
-- Handle RemoveDictionaryEntry command
handleConfigurationCommand config (RemoveDictionaryEntryConfigurationCommand RemoveDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryKind config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryKind config) = Left EntryNotFound
  | wouldEmptyRequiredDictionary dictionaryKind config = Left CannotRemoveLastEntry
  | not (null (childrenOf entryId (entriesOf dictionaryKind config))) = Left GroupNotEmpty
  | isGlobalDefault entryId config = Left EntryIsGlobalDefault
  | isInBankProviderExpenseCategoryMap entryId config = Left EntryIsInBankProviderExpenseCategoryMap
  | isInBankProviderContactMap entryId config = Left EntryIsInBankProviderContactMap
  | otherwise =
      Right
        [ DictionaryEntryRemovedConfigurationEvent
            DictionaryEntryRemoved
              { dictionaryKind = dictionaryKind,
                entryId = entryId
              }
        ]
-- Handle MoveDictionaryEntry command. Enforces the full tree invariants:
-- entry exists, new parent exists, the move is cycle-free (new parent is neither
-- the entry itself nor one of its descendants), the resulting subtree stays
-- within the depth limit, and the moved name is unique among its new siblings.
handleConfigurationCommand config (MoveDictionaryEntryConfigurationCommand MoveDictionaryEntry {..})
  | not (entryExists entryId dictionaryKind config) = Left EntryNotFound
  | Just p <- newParentId, isNothing (lookupEntry p es) = Left ParentEntryNotFound
  | Just p <- newParentId, not (isGroupEntry p es) = Left ParentNotAGroup
  | Just p <- newParentId, p == entryId || p `elem` descendantsOf entryId es = Left MoveWouldCreateCycle
  | newParentDepth + requiredHeight > maxDictionaryDepth = Left MaxDepthExceeded
  | maybe False (\nm -> hasDuplicateSiblingName nm newParentId (Just entryId) dictionaryKind config) entryName =
      Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryMovedConfigurationEvent
            DictionaryEntryMoved
              { dictionaryKind = dictionaryKind,
                entryId = entryId,
                newParentId = newParentId
              }
        ]
  where
    es = entriesOf dictionaryKind config
    newParentDepth = maybe 0 (`depthOf` es) newParentId
    movedEntry = lookupEntry entryId es
    entryName = (.name) <$> movedEntry
    -- A group must reserve room for its items even when currently empty. The
    -- floor of 2 mirrors 'maxDepthForRole' GroupRole (one level for items); bump it
    -- alongside 'maxDictionaryDepth'/'maxDepthForRole' for the "extend to 3" change.
    requiredHeight = case (.role) <$> movedEntry of
      Just GroupRole -> max (subtreeHeight entryId es) 2
      _ -> subtreeHeight entryId es
-- Handle SetDefaultIncomeCategory command
handleConfigurationCommand config (SetDefaultIncomeCategoryConfigurationCommand SetDefaultIncomeCategory {..}) = do
  requireEntryIn incomeCategoryDictKind categoryId config
  Right
    [ DefaultIncomeCategorySetConfigurationEvent
        DefaultIncomeCategorySet
          { categoryId = categoryId
          }
    ]
-- Handle SetDefaultExpenseCategory command
handleConfigurationCommand config (SetDefaultExpenseCategoryConfigurationCommand SetDefaultExpenseCategory {..}) = do
  requireEntryIn expenseCategoryDictKind categoryId config
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
-- Handle SetBankProviderExpenseCategoryMap command
handleConfigurationCommand config (SetBankProviderExpenseCategoryMapConfigurationCommand SetBankProviderExpenseCategoryMap {..}) = do
  mapM_ (\cid -> requireEntryIn expenseCategoryDictKind cid config) (Map.elems mapping)
  Right
    [ BankProviderExpenseCategoryMapSetConfigurationEvent
        BankProviderExpenseCategoryMapSet
          { mapping = mapping
          }
    ]
-- Handle SetBankProviderContactMap command
handleConfigurationCommand config (SetBankProviderContactMapConfigurationCommand SetBankProviderContactMap {..}) = do
  mapM_ (\cid -> requireEntryIn ContactKind cid config) (Map.elems mapping)
  Right
    [ BankProviderContactMapSetConfigurationEvent
        BankProviderContactMapSet
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
