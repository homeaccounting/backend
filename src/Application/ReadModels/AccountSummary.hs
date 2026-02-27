{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Application.ReadModels.AccountSummary
-- Description : Read model for optimized account queries
--
-- This module implements a read model that provides efficient queries for account
-- information without requiring event replay. The read model listens to the event
-- stream and maintains a denormalized view optimized for common query patterns.
--
-- Key Components:
--   - AccountSummaryData: Denormalized account information (with ownership and RBAC)
--   - AccountSummaryReadModel: Map of account IDs to summary data
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
module Application.ReadModels.AccountSummary
  ( -- * Read Model Types
    AccountSummaryData (..),
    AccountSummaryReadModel,

    -- * Read Model Creation
    createAccountSummaryReadModel,

    -- * Event Handler
    handleAccountSummaryEvents,

    -- * Query Functions
    getAccountSummary,
    getAccountSummaryForUser,
    getAllAccountSummaries,
    getAccessibleAccounts,
    accountExists,

    -- * Helper Functions
    accountSummaryToMap,
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
    subtractMoneyAllowNegative,
  )
import Domain.Models
  ( AccountingEvent (..),
  )
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
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
data AccountSummaryData = AccountSummaryData
  { -- | Human-readable account name
    accountSummaryDataName :: Text,
    -- | Current account balance
    accountSummaryDataBalance :: Money,
    -- | User who created the account (Owner)
    accountSummaryDataCreatedBy :: UserId,
    -- | Account type (Regular or External)
    accountSummaryDataType :: AccountType,
    -- | Access control list (users and their roles)
    accountSummaryDataAccessList :: [AccountAccess],
    -- | Version number from event stream for optimistic concurrency
    accountSummaryDataVersion :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountSummaryData

instance FromJSON AccountSummaryData

-- | Account summary with the requesting user's role included.
--
-- This is returned when querying for a specific user, indicating
-- what role they have on the account.
data AccountSummaryWithRole = AccountSummaryWithRole
  { -- | The account summary data
    accountSummaryWithRoleData :: AccountSummaryData,
    -- | The requesting user's role on this account
    accountSummaryWithRoleUserRole :: AccountRole
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountSummaryWithRole

instance FromJSON AccountSummaryWithRole

-- | The read model state: a map from account IDs to their summary data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data AccountSummaryReadModel = AccountSummaryReadModel
  { accountSummaryLatestSequence :: SequenceNumber,
    accountSummaryData :: Map AccountId AccountSummaryData
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
-- >>> readModel <- createAccountSummaryReadModel
-- >>> summary <- getAccountSummary readModel someAccountId
createAccountSummaryReadModel :: (MonadIO m) => m (TVar AccountSummaryReadModel)
createAccountSummaryReadModel =
  liftIO $
    newTVarIO $
      AccountSummaryReadModel
        { accountSummaryLatestSequence = -1,
          accountSummaryData = Map.empty
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
-- >>> handleAccountSummaryEvents readModelTVar events
-- >>> summary <- getAccountSummary readModelTVar accountId
handleAccountSummaryEvents ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleAccountSummaryEvents readModelTVar events = do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef (accountSummaryLatestSequence currentModel) (streamEventPosition <$> events)
      updatedData = foldl processEvent (accountSummaryData currentModel) events

  liftIO . atomically . writeTVar readModelTVar $
    currentModel
      { accountSummaryLatestSequence = newSeq,
        accountSummaryData = updatedData
      }

-- | Processes a single event and updates the account summary map.
--
-- GlobalStreamEvent is nested: StreamEvent () SequenceNumber (VersionedStreamEvent event)
-- where VersionedStreamEvent event = StreamEvent UUID EventVersion event
-- So we need to unwrap twice to get the payload and stream key (UUID).
processEvent ::
  Map AccountId AccountSummaryData ->
  GlobalStreamEvent AccountingEvent ->
  Map AccountId AccountSummaryData
processEvent summaries globalEvent =
  let versionedEvent = streamEventEvent globalEvent
      streamUuid = streamEventKey versionedEvent
      payload = streamEventEvent versionedEvent
   in case payload of
        AccountCreatedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              let initialAccess = AccountAccess (accountCreatedBy evt) Owner
               in Map.insert
                    accountId
                    AccountSummaryData
                      { accountSummaryDataName = accountCreatedName evt,
                        accountSummaryDataBalance = accountCreatedInitialBalance evt,
                        accountSummaryDataCreatedBy = accountCreatedBy evt,
                        accountSummaryDataType = accountCreatedType evt,
                        accountSummaryDataAccessList = [initialAccess],
                        accountSummaryDataVersion = 1
                      }
                    summaries
        AccountAccessGrantedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    let existingList = accountSummaryDataAccessList summary
                        withoutUser = filter (\a -> accessUserId a /= accountAccessGrantedUserId evt) existingList
                        newAccess = AccountAccess (accountAccessGrantedUserId evt) (accountAccessGrantedRole evt)
                     in summary
                          { accountSummaryDataAccessList = newAccess : withoutUser,
                            accountSummaryDataVersion = accountSummaryDataVersion summary + 1
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
                    let existingList = accountSummaryDataAccessList summary
                        withoutUser = filter (\a -> accessUserId a /= accountAccessRevokedUserId evt) existingList
                     in summary
                          { accountSummaryDataAccessList = withoutUser,
                            accountSummaryDataVersion = accountSummaryDataVersion summary + 1
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
                    summary
                      { accountSummaryDataBalance =
                          subtractMoneyAllowNegative (accountSummaryDataBalance summary) (accountDebitedAmount evt),
                        accountSummaryDataVersion = accountSummaryDataVersion summary + 1
                      }
                )
                accountId
                summaries
        AccountCreditedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    summary
                      { accountSummaryDataBalance =
                          accountSummaryDataBalance summary `addMoney` accountCreditedAmount evt,
                        accountSummaryDataVersion = accountSummaryDataVersion summary + 1
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
-- >>> maybeSummary <- getAccountSummary readModel accountId
-- >>> case maybeSummary of
-- >>>   Just summary -> print (accountSummaryDataBalance summary)
-- >>>   Nothing -> putStrLn "Account not found"
getAccountSummary ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  AccountId ->
  m (Maybe AccountSummaryData)
getAccountSummary readModelTVar accountId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup accountId (accountSummaryData model)

-- | Retrieves the account summary for a specific user.
--
-- Returns 'Nothing' if the account doesn't exist OR user doesn't have access.
-- This hides account existence from unauthorized users.
--
-- Example:
-- >>> maybeSummary <- getAccountSummaryForUser readModel accountId userId
-- >>> case maybeSummary of
-- >>>   Just (summary, role) -> displayAccount summary role
-- >>>   Nothing -> return404
getAccountSummaryForUser ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  AccountId ->
  UserId ->
  m (Maybe AccountSummaryWithRole)
getAccountSummaryForUser readModelTVar accountId userId = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup accountId (accountSummaryData model) of
    Nothing -> return Nothing
    Just summary ->
      case getUserRole userId (accountSummaryDataAccessList summary) of
        Nothing -> return Nothing -- User doesn't have access
        Just role ->
          return $
            Just
              AccountSummaryWithRole
                { accountSummaryWithRoleData = summary,
                  accountSummaryWithRoleUserRole = role
                }

-- | Retrieves all account summaries in the read model.
--
-- Returns a map from AccountId to AccountSummaryData for all known accounts.
-- This is for internal/admin use.
--
-- Example:
-- >>> allSummaries <- getAllAccountSummaries readModel
-- >>> mapM_ print (Map.toList allSummaries)
getAllAccountSummaries ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  m (Map AccountId AccountSummaryData)
getAllAccountSummaries readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ accountSummaryData model

-- | Retrieves all accounts accessible to a specific user.
--
-- Returns a list of (AccountId, AccountSummaryData, AccountRole) tuples
-- for all accounts where the user has access.
--
-- Example:
-- >>> accounts <- getAccessibleAccounts readModel userId
-- >>> mapM_ (\(id, data, role) -> displayAccount id data role) accounts
getAccessibleAccounts ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  UserId ->
  m [(AccountId, AccountSummaryData, AccountRole)]
getAccessibleAccounts readModelTVar userId = do
  model <- liftIO $ readTVarIO readModelTVar
  let allAccounts = Map.toList (accountSummaryData model)
      accessibleAccounts =
        [ (accountId, summary, role)
          | (accountId, summary) <- allAccounts,
            Just role <- [getUserRole userId (accountSummaryDataAccessList summary)]
        ]
  return accessibleAccounts

-- | Checks if an account exists in the read model.
--
-- This is more efficient than checking if 'getAccountSummary' returns 'Just'.
--
-- Example:
-- >>> exists <- accountExists readModel accountId
-- >>> if exists then proceedWithTransfer else rejectTransfer
accountExists ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  AccountId ->
  m Bool
accountExists readModelTVar accountId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member accountId (accountSummaryData model)

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extracts the map of account summaries from the read model.
--
-- This is useful for testing and debugging.
--
-- Example:
-- >>> summaryMap <- accountSummaryToMap readModel
-- >>> print $ Map.size summaryMap
accountSummaryToMap ::
  (MonadIO m) =>
  TVar AccountSummaryReadModel ->
  m (Map AccountId AccountSummaryData)
accountSummaryToMap = getAllAccountSummaries

-- | Get a user's role from an access list.
getUserRole :: UserId -> [AccountAccess] -> Maybe AccountRole
getUserRole userId accessList =
  accessRole <$> findAccess
  where
    findAccess = foldr matchUser Nothing accessList
    matchUser acc result =
      if accessUserId acc == userId
        then Just acc
        else result
