{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.Account
-- Description : Read model for optimized account queries
--
-- This module implements a read model that provides efficient queries for account
-- information without requiring event replay. The read model listens to the event
-- stream and maintains a denormalized view optimized for common query patterns.
--
-- Key Components:
--   - AccountData: Denormalized account information (with ownership and RBAC)
--   - AccountReadModel: Map of account IDs to account data
--   - Event handlers: Update the read model when events occur
--   - Query functions: Efficient lookups by account ID
--
-- Design Rationale:
--   - Separates read and write models (CQRS pattern)
--   - Optimizes for query performance
--   - Maintains eventual consistency with event stream
--   - Tracks sequence numbers for reliable event processing
--   - Includes RBAC data for authorization checks
--
-- The read model can be:
--   - Rebuilt from the event stream if corrupted
--   - Extended with additional denormalized fields
--   - Backed by in-memory or persistent storage
module Application.ReadModels.Account
  ( -- * Read Model Types
    AccountData (..),
    AccountReadModel,

    -- * Read Model Creation
    createAccountReadModel,

    -- * Event Handler
    handleAccountEvents,

    -- * Query Functions
    getAccount,
    getAccountForUser,
    getAllAccounts,
    getAccessibleAccounts,
    getUserRegularAccounts,
    accountExists,
    balanceAsOf,
    foldBalanceAsOf,

    -- * Helper Functions
    accountToMap,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountCreated (..),
    AccountCreditReversed (..),
    AccountCredited (..),
    AccountDebitReversed (..),
    AccountDebited (..),
    AccountRenamed (..),
    AccountSubtypeSet (..),
    OverdraftLimitSet (..),
  )
import Domain.Core.Types
  ( AccountAccess (..),
    AccountId,
    AccountRole (..),
    AccountType (..),
    Money,
    TransactionId,
    UserId,
    addMoney,
    mkAccountIdSafe,
    subtractMoney,
    unAccountId,
  )
import Domain.Models
  ( AccountingEvent (..),
  )
import Eventium (EventHandler (..), EventStoreReader (..), EventVersion, GlobalStreamEvent, SequenceNumber, StreamEvent (..), VersionedStreamEvent, allEvents)
import GHC.Generics (Generic)
import Infrastructure.Eventium (AccountingReadModelHandler)
import Infrastructure.Eventium.GlobalEvent (unpackGlobalEvent)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Denormalized account information for efficient querying.
--
-- This structure contains all the information needed for common account queries
-- without requiring event replay. It's optimized for read operations.
--
-- Now includes:
--   - Ownership (createdBy)
--   - Account type (Regular or External)
--   - Access list for RBAC
data AccountData = AccountData
  { -- | Human-readable account name
    name :: Text,
    -- | Current account balance
    balance :: Money,
    -- | User who created the account (Owner)
    createdBy :: UserId,
    -- | Account category (Regular with type, or External)
    accountType :: AccountType,
    -- | Access control list (users and their roles)
    accessList :: [AccountAccess],
    -- | Overdraft limit (Nothing = unlimited)
    overdraftLimit :: Maybe Money,
    -- | Version number from event stream for optimistic concurrency
    version :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountData

instance FromJSON AccountData

-- | Account with the requesting user's role included.
--
-- This is returned when querying for a specific user, indicating
-- what role they have on the account.
data AccountWithRole = AccountWithRole
  { -- | The account data
    account :: AccountData,
    -- | The requesting user's role on this account
    userRole :: AccountRole
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountWithRole

instance FromJSON AccountWithRole

-- | The read model state: a map from account IDs to their account data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data AccountReadModel = AccountReadModel
  { latestSequence :: SequenceNumber,
    accounts :: Map AccountId AccountData
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty account read model.
--
-- This initializes the read model with:
--   - Sequence number -1 (before any events)
--   - Empty map of accounts
--
-- Example:
-- >>> readModel <- createAccountReadModel
-- >>> account <- getAccount readModel someAccountId
createAccountReadModel :: (MonadIO m) => m (TVar AccountReadModel)
createAccountReadModel =
  liftIO $
    newTVarIO $
      AccountReadModel
        { latestSequence = -1,
          accounts = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- This function:
--   1. Processes each event and updates the account data accordingly
--   2. Tracks the highest sequence number seen
--   3. Updates the TVar atomically
--
-- Events handled:
--   - AccountCreated: Adds new account to the map (with owner and type)
--   - AccountAccessGranted: Updates access list
--   - AccountAccessRevoked: Updates access list
--   - AccountDebited: Decreases account balance (debit succeeded)
--   - AccountCredited: Increases account balance (credit succeeded)
--   - AccountDebitRejected: Ignored (no balance change)
--
-- The function is idempotent - replaying the same events produces the same result.
--
-- Example:
-- >>> handleAccountEvents readModelTVar events
-- >>> account <- getAccount readModelTVar accountId
handleAccountEvents ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  AccountingReadModelHandler m
handleAccountEvents readModelTVar = EventHandler $ \events -> do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedData = foldl processEvent currentModel.accounts events

  liftIO . atomically . writeTVar readModelTVar $
    currentModel
      { latestSequence = newSeq,
        accounts = updatedData
      }

-- | Processes a single event and updates the accounts map.
--
-- GlobalStreamEvent is nested: StreamEvent () SequenceNumber (VersionedStreamEvent event)
-- where VersionedStreamEvent event = StreamEvent UUID EventVersion event
-- So we need to unwrap twice to get the payload and stream key (UUID).
processEvent ::
  Map AccountId AccountData ->
  GlobalStreamEvent AccountingEvent ->
  Map AccountId AccountData
processEvent accounts globalEvent =
  let (streamUuid, payload) = unpackGlobalEvent globalEvent
   in case payload of
        AccountCreatedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              let initialAccess = AccountAccess evt.by Owner
               in Map.insert
                    accountId
                    AccountData
                      { name = evt.name,
                        balance = evt.initialBalance,
                        createdBy = evt.by,
                        accountType = evt.accountType,
                        accessList = [initialAccess],
                        overdraftLimit = evt.overdraftLimit,
                        version = 1
                      }
                    accounts
        AccountAccessGrantedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    let existingList = account.accessList
                        withoutUser = filter (\a -> a.userId /= evt.userId) existingList
                        newAccess = AccountAccess evt.userId evt.role
                     in account
                          { accessList = newAccess : withoutUser,
                            version = account.version + 1
                          }
                )
                accountId
                accounts
        AccountAccessRevokedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    let existingList = account.accessList
                        withoutUser = filter (\a -> a.userId /= evt.userId) existingList
                     in account
                          { accessList = withoutUser,
                            version = account.version + 1
                          }
                )
                accountId
                accounts
        AccountDebitedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    case subtractMoney account.balance evt.amount of
                      Right newBalance ->
                        account
                          { balance = newBalance,
                            version = account.version + 1
                          }
                      Left _ -> account -- Currency mismatch: should not happen for valid events
                )
                accountId
                accounts
        AccountCreditedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    case addMoney account.balance evt.amount of
                      Right newBalance ->
                        account
                          { balance = newBalance,
                            version = account.version + 1
                          }
                      Left _ -> account -- Currency mismatch: should not happen for valid events
                )
                accountId
                accounts
        AccountDebitReversedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    case addMoney account.balance evt.amount of
                      Right newBalance ->
                        account
                          { balance = newBalance,
                            version = account.version + 1
                          }
                      Left _ -> account
                )
                accountId
                accounts
        AccountCreditReversedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    case subtractMoney account.balance evt.amount of
                      Right newBalance ->
                        account
                          { balance = newBalance,
                            version = account.version + 1
                          }
                      Left _ -> account
                )
                accountId
                accounts
        OverdraftLimitSetEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    account
                      { overdraftLimit = evt.overdraftLimit,
                        version = account.version + 1
                      }
                )
                accountId
                accounts
        AccountSubtypeSetEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    account
                      { accountType = Regular evt.subtype,
                        version = account.version + 1
                      }
                )
                accountId
                accounts
        AccountRenamedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    account
                      { name = evt.newName,
                        version = account.version + 1
                      }
                )
                accountId
                accounts
        _ -> accounts -- Ignore other events (AccountDebitRejected, etc.)

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieves the account data for a specific account ID.
--
-- Returns 'Nothing' if the account doesn't exist in the read model.
-- This is for internal/admin use - does not check access permissions.
--
-- Example:
-- >>> maybeAccount <- getAccount readModel accountId
-- >>> case maybeAccount of
-- >>>   Just account -> print (account.balance)
-- >>>   Nothing -> putStrLn "Account not found"
getAccount ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  AccountId ->
  m (Maybe AccountData)
getAccount readModelTVar accountId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup accountId model.accounts

-- | Retrieves the account data for a specific user.
--
-- Returns 'Nothing' if the account doesn't exist OR user doesn't have access.
-- This hides account existence from unauthorized users.
--
-- Example:
-- >>> maybeAccount <- getAccountForUser readModel accountId userId
-- >>> case maybeAccount of
-- >>>   Just (account, role) -> displayAccount account role
-- >>>   Nothing -> return404
getAccountForUser ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  AccountId ->
  UserId ->
  m (Maybe AccountWithRole)
getAccountForUser readModelTVar accountId userId = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup accountId model.accounts of
    Nothing -> return Nothing
    Just account ->
      case getUserRole userId account.accessList of
        Nothing -> return Nothing -- User doesn't have access
        Just role ->
          return $
            Just
              AccountWithRole
                { account = account,
                  userRole = role
                }

-- | Retrieves all accounts in the read model.
--
-- Returns a map from AccountId to AccountData for all known accounts.
-- This is for internal/admin use.
--
-- Example:
-- >>> accounts <- getAllAccounts readModel
-- >>> mapM_ print (Map.toList accounts)
getAllAccounts ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  m (Map AccountId AccountData)
getAllAccounts readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return model.accounts

-- | Retrieves all accounts accessible to a specific user.
--
-- Returns a list of (AccountId, AccountData, AccountRole) tuples
-- for all accounts where the user has access.
--
-- Example:
-- >>> accounts <- getAccessibleAccounts readModel userId
-- >>> mapM_ (\(id, data, role) -> displayAccount id data role) accounts
getAccessibleAccounts ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  UserId ->
  m [(AccountId, AccountData, AccountRole)]
getAccessibleAccounts readModelTVar userId = do
  model <- liftIO $ readTVarIO readModelTVar
  let allAccounts = Map.toList model.accounts
      accessibleAccounts =
        [ (accountId, account, role)
        | (accountId, account) <- allAccounts,
          Just role <- [getUserRole userId account.accessList]
        ]
  return accessibleAccounts

-- | Retrieves a user's regular (non-External) accounts as (AccountId, name, balance) triples.
--
-- Filters accounts where the user is the creator and the account type is RegularAccount.
--
-- Example:
-- >>> accounts <- getUserRegularAccounts readModel userId
-- >>> mapM_ (\(id, name, bal) -> displayAccount id name bal) accounts
getUserRegularAccounts ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  UserId ->
  m [(AccountId, Text, Money)]
getUserRegularAccounts readModelTVar userId = do
  model <- liftIO $ readTVarIO readModelTVar
  let allAccounts = Map.toList model.accounts
  return
    [ (accId, acc.name, acc.balance)
    | (accId, acc) <- allAccounts,
      acc.createdBy == userId,
      isRegular acc.accountType
    ]
  where
    isRegular (Regular _) = True
    isRegular External = False

-- | Checks if an account exists in the read model.
--
-- This is more efficient than checking if 'getAccount' returns 'Just'.
--
-- Example:
-- >>> exists <- accountExists readModel accountId
-- >>> if exists then proceedWithTransfer else rejectTransfer
accountExists ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  AccountId ->
  m Bool
accountExists readModelTVar accountId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member accountId model.accounts

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extracts the map of accounts from the read model.
--
-- This is useful for testing and debugging.
--
-- Example:
-- >>> accountsMap <- accountToMap readModel
-- >>> print $ Map.size accountsMap
accountToMap ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  m (Map AccountId AccountData)
accountToMap = getAllAccounts

-- | Get a user's role from an access list.
getUserRole :: UserId -> [AccountAccess] -> Maybe AccountRole
getUserRole uid accessList =
  (.role) <$> findAccess
  where
    findAccess = foldr matchUser Nothing accessList
    matchUser acc result =
      if acc.userId == uid
        then Just acc
        else result

-- -----------------------------------------------------------------------------
-- Temporal balance query
-- -----------------------------------------------------------------------------

-- | Compute the account's balance as of business date @D@ by re-folding the
-- aggregate's event stream.
--
-- This is an on-demand event-store fold, not a maintained projection. It is
-- exposed alongside the read model because callers usually reach for it in
-- the same place they reach for current balance, but the live read-model
-- 'AccountReadModel' is not an input — the reader is passed explicitly,
-- mirroring 'Infrastructure.Eventium.loadUserAggregate'.
--
-- Returns 'Nothing' when the account has no events at all (i.e. does not
-- exist). The genesis balance is the @initialBalance@ from 'AccountCreated';
-- any 'AccountDebited' / 'AccountCredited' events with @at <= D@ are folded
-- in. Other event payloads do not affect balance.
--
-- Callers (typically the service layer) are responsible for lifting
-- 'Nothing' to a domain error such as @NotFound \"Account\" ...@.
--
-- The @lookupAt@ parameter resolves a 'TransactionId' to the authoritative
-- business date currently recorded on the Transaction aggregate (typically
-- backed by 'Application.ReadModels.Transaction'). It exists so that user
-- edits to a transaction's date (see
-- @docs/specs/2026-05-20-editable-transaction-metadata-design.md@ §4)
-- propagate into historical balance queries: the authoritative @at@ lives
-- on the TX aggregate. When @lookupAt@ returns 'Nothing' the leg is
-- skipped entirely; this is purely defensive, as valid event streams
-- produced by the command handler always have a corresponding TX entry.
balanceAsOf ::
  (Monad m) =>
  EventStoreReader UUID EventVersion m (VersionedStreamEvent AccountingEvent) ->
  (TransactionId -> Maybe UTCTime) ->
  AccountId ->
  UTCTime ->
  m (Maybe Money)
balanceAsOf (EventStoreReader readStream) lookupAt accountId asOf = do
  events <- readStream (allEvents (unAccountId accountId))
  pure (foldBalanceAsOf asOf lookupAt ((.payload) <$> events))

-- | Fold a list of 'AccountingEvent' payloads into a balance as of @D@.
--
-- Pure helper exposed for testability. Returns
-- 'Nothing' when no 'AccountCreated' event is present; otherwise folds
-- 'AccountCredited' / 'AccountDebited' events whose authoritative business
-- date (resolved via @lookupAt@ from the Transaction aggregate) is at or
-- before @asOf@. When @lookupAt@ returns 'Nothing' for a leg's
-- 'TransactionId', the leg is skipped entirely — this is purely defensive,
-- as valid event streams produced by the command handler always have a
-- corresponding TX entry in the lookup.
--
-- Currency-mismatch errors from 'addMoney' / 'subtractMoney' are silently
-- ignored, mirroring 'handleAccountEvents' — such mismatches cannot arise
-- from valid event streams produced by the command handler.
foldBalanceAsOf ::
  UTCTime ->
  (TransactionId -> Maybe UTCTime) ->
  [AccountingEvent] ->
  Maybe Money
foldBalanceAsOf asOf lookupAt events =
  case dropWhile (not . isAccountCreated) events of
    [] -> Nothing
    (AccountCreatedEvent c : rest) ->
      Just (foldl' (applyAsOf asOf lookupAt) c.initialBalance rest)
    _ -> Nothing
  where
    isAccountCreated (AccountCreatedEvent _) = True
    isAccountCreated _ = False

    applyAsOf :: UTCTime -> (TransactionId -> Maybe UTCTime) -> Money -> AccountingEvent -> Money
    applyAsOf cutoff lookup_ bal (AccountDebitedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          case subtractMoney bal e.amount of
            Right newBal -> newBal
            Left _ -> bal -- currency mismatch cannot occur in valid streams
    applyAsOf cutoff lookup_ bal (AccountCreditedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          case addMoney bal e.amount of
            Right newBal -> newBal
            Left _ -> bal
    applyAsOf cutoff lookup_ bal (AccountDebitReversedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          case addMoney bal e.amount of
            Right newBal -> newBal
            Left _ -> bal
    applyAsOf cutoff lookup_ bal (AccountCreditReversedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          case subtractMoney bal e.amount of
            Right newBal -> newBal
            Left _ -> bal
    applyAsOf _ _ bal _ = bal
