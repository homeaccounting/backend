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
--   - AccountReadModel: Map of account IDs to summary data
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
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountCreated (..),
    AccountCredited (..),
    AccountDebited (..),
    AccountSubtypeSet (..),
    OverdraftLimitSet (..),
  )
import Domain.Core.Types
  ( AccountAccess (..),
    AccountId,
    AccountRole (..),
    AccountType (..),
    Money,
    UserId,
    addMoney,
    mkAccountIdSafe,
    subtractMoney,
  )
import Domain.Models
  ( AccountingEvent (..),
  )
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
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

-- | Account summary with the requesting user's role included.
--
-- This is returned when querying for a specific user, indicating
-- what role they have on the account.
data AccountWithRole = AccountWithRole
  { -- | The account summary data
    summaryData :: AccountData,
    -- | The requesting user's role on this account
    userRole :: AccountRole
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountWithRole

instance FromJSON AccountWithRole

-- | The read model state: a map from account IDs to their summary data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data AccountReadModel = AccountReadModel
  { latestSequence :: SequenceNumber,
    summaryData :: Map AccountId AccountData
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty account summary read model.
--
-- This initializes the read model with:
--   - Sequence number -1 (before any events)
--   - Empty map of account summaries
--
-- Example:
-- >>> readModel <- createAccountReadModel
-- >>> summary <- getAccount readModel someAccountId
createAccountReadModel :: (MonadIO m) => m (TVar AccountReadModel)
createAccountReadModel =
  liftIO $
    newTVarIO $
      AccountReadModel
        { latestSequence = -1,
          summaryData = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- This function:
--   1. Processes each event and updates the account summary accordingly
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
-- >>> summary <- getAccount readModelTVar accountId
handleAccountEvents ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleAccountEvents readModelTVar events = do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedData = foldl processEvent currentModel.summaryData events

  liftIO . atomically . writeTVar readModelTVar $
    currentModel
      { latestSequence = newSeq,
        summaryData = updatedData
      }

-- | Processes a single event and updates the account summary map.
--
-- GlobalStreamEvent is nested: StreamEvent () SequenceNumber (VersionedStreamEvent event)
-- where VersionedStreamEvent event = StreamEvent UUID EventVersion event
-- So we need to unwrap twice to get the payload and stream key (UUID).
processEvent ::
  Map AccountId AccountData ->
  GlobalStreamEvent AccountingEvent ->
  Map AccountId AccountData
processEvent summaries globalEvent =
  let (streamUuid, payload) = unpackGlobalEvent globalEvent
   in case payload of
        AccountCreatedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
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
                    summaries
        AccountAccessGrantedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    let existingList = summary.accessList
                        withoutUser = filter (\a -> a.userId /= evt.userId) existingList
                        newAccess = AccountAccess evt.userId evt.role
                     in summary
                          { accessList = newAccess : withoutUser,
                            version = summary.version + 1
                          }
                )
                accountId
                summaries
        AccountAccessRevokedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    let existingList = summary.accessList
                        withoutUser = filter (\a -> a.userId /= evt.userId) existingList
                     in summary
                          { accessList = withoutUser,
                            version = summary.version + 1
                          }
                )
                accountId
                summaries
        AccountDebitedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    case subtractMoney summary.balance evt.amount of
                      Right newBalance ->
                        summary
                          { balance = newBalance,
                            version = summary.version + 1
                          }
                      Left _ -> summary -- Currency mismatch: should not happen for valid events
                )
                accountId
                summaries
        AccountCreditedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    case addMoney summary.balance evt.amount of
                      Right newBalance ->
                        summary
                          { balance = newBalance,
                            version = summary.version + 1
                          }
                      Left _ -> summary -- Currency mismatch: should not happen for valid events
                )
                accountId
                summaries
        OverdraftLimitSetEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    summary
                      { overdraftLimit = evt.overdraftLimit,
                        version = summary.version + 1
                      }
                )
                accountId
                summaries
        AccountSubtypeSetEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    summary
                      { accountType = Regular evt.subtype,
                        version = summary.version + 1
                      }
                )
                accountId
                summaries
        _ -> summaries -- Ignore other events (AccountDebitRejected, etc.)

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieves the account summary for a specific account ID.
--
-- Returns 'Nothing' if the account doesn't exist in the read model.
-- This is for internal/admin use - does not check access permissions.
--
-- Example:
-- >>> maybeSummary <- getAccount readModel accountId
-- >>> case maybeSummary of
-- >>>   Just summary -> print (summary.balance)
-- >>>   Nothing -> putStrLn "Account not found"
getAccount ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  AccountId ->
  m (Maybe AccountData)
getAccount readModelTVar accountId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup accountId model.summaryData

-- | Retrieves the account summary for a specific user.
--
-- Returns 'Nothing' if the account doesn't exist OR user doesn't have access.
-- This hides account existence from unauthorized users.
--
-- Example:
-- >>> maybeSummary <- getAccountForUser readModel accountId userId
-- >>> case maybeSummary of
-- >>>   Just (summary, role) -> displayAccount summary role
-- >>>   Nothing -> return404
getAccountForUser ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  AccountId ->
  UserId ->
  m (Maybe AccountWithRole)
getAccountForUser readModelTVar accountId userId = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup accountId model.summaryData of
    Nothing -> return Nothing
    Just summary ->
      case getUserRole userId summary.accessList of
        Nothing -> return Nothing -- User doesn't have access
        Just role ->
          return $
            Just
              AccountWithRole
                { summaryData = summary,
                  userRole = role
                }

-- | Retrieves all account summaries in the read model.
--
-- Returns a map from AccountId to AccountData for all known accounts.
-- This is for internal/admin use.
--
-- Example:
-- >>> allSummaries <- getAllAccounts readModel
-- >>> mapM_ print (Map.toList allSummaries)
getAllAccounts ::
  (MonadIO m) =>
  TVar AccountReadModel ->
  m (Map AccountId AccountData)
getAllAccounts readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return model.summaryData

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
  let allAccounts = Map.toList model.summaryData
      accessibleAccounts =
        [ (accountId, summary, role)
        | (accountId, summary) <- allAccounts,
          Just role <- [getUserRole userId summary.accessList]
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
  let allAccounts = Map.toList model.summaryData
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
  return $ Map.member accountId model.summaryData

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extracts the map of account summaries from the read model.
--
-- This is useful for testing and debugging.
--
-- Example:
-- >>> summaryMap <- accountToMap readModel
-- >>> print $ Map.size summaryMap
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
