{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.TransactionSummary
-- Description : Read model for optimized transaction queries
--
-- This module implements a read model that provides efficient queries for transaction
-- information without requiring event replay. The read model listens to the event
-- stream and maintains a denormalized view optimized for common query patterns.
--
-- Key Components:
--   - TransactionSummaryData: Denormalized transaction information
--   - TransactionSummaryReadModel: Map of transaction IDs to summary data
--   - Event handlers: Update the read model when events occur
--   - Query functions: Efficient lookups by transaction ID
--
-- Design Rationale:
--   - Separates read and write models (CQRS pattern)
--   - Optimizes for query performance
--   - Maintains eventual consistency with event stream
--   - Tracks sequence numbers for reliable event processing
--
-- The read model can be:
--   - Rebuilt from the event stream if corrupted
--   - Extended with additional denormalized fields
--   - Backed by in-memory or persistent storage
module Application.ReadModels.TransactionSummary
  ( -- * Read Model Types
    TransactionSummaryData (..),
    TransactionSummaryReadModel,

    -- * Read Model Creation
    createTransactionSummaryReadModel,

    -- * Event Handler
    handleTransactionSummaryEvents,

    -- * Query Functions
    getTransactionSummary,
    getAllTransactionSummaries,
    transactionExists,

    -- * Helper Functions
    transactionSummaryToMap,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, TransactionId, mkTransactionIdSafe)
import Domain.Models
  ( AccountingEvent (TransferCompletedEvent, TransferFailedEvent, TransferInitiatedEvent),
  )
import Domain.Transaction.Events
  ( TransferCompleted,
    TransferFailed (..),
    TransferInitiated (..),
  )
import Domain.Transaction.Projection (TransactionStatus (Completed, Failed, Pending))
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Denormalized transaction information for efficient querying.
--
-- This structure contains all the information needed for common transaction queries
-- without requiring event replay. It's optimized for read operations.
data TransactionSummaryData
  = TransactionSummaryData
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    amount :: Money,
    reason :: Text,
    status :: TransactionStatus
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionSummaryData

instance FromJSON TransactionSummaryData

-- | The read model state: a map from transaction IDs to their summary data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data TransactionSummaryReadModel
  = TransactionSummaryReadModel
  { latestSequence :: SequenceNumber,
    summaryData :: Map TransactionId TransactionSummaryData
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty transaction summary read model.
--
-- This initializes the read model with:
--  - Sequence number -1 (before any events)
--  - Empty map of transaction summaries
--
-- Example:
-- >>> readModel <- createTransactionSummaryReadModel
-- >>> summary <- getTransactionSummary readModel someTransactionId
createTransactionSummaryReadModel :: (MonadIO m) => m (TVar TransactionSummaryReadModel)
createTransactionSummaryReadModel =
  liftIO $
    newTVarIO $
      TransactionSummaryReadModel
        { latestSequence = -1,
          summaryData = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- This function:
--  1. Processes each event and updates the transaction summary accordingly
--  2. Tracks the highest sequence number seen
--  3. Updates the TVar atomically
--
-- Events handled:
--  - TransferInitiated: Adds new transaction with Pending status
--  - TransferCompleted: Updates status to Completed
--  - TransferFailed: Updates status to Failed with reason
--
-- The function is idempotent - replaying the same events produces the same result.
--
-- Example:
-- >>> handleTransactionSummaryEvents readModelTVar events
-- >>> summary <- getTransactionSummary readModelTVar transactionId
handleTransactionSummaryEvents ::
  (MonadIO m) =>
  TVar TransactionSummaryReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleTransactionSummaryEvents readModelTVar events = do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedData = foldl processEvent currentModel.summaryData events

  liftIO . atomically . writeTVar readModelTVar $
    currentModel
      { latestSequence = newSeq,
        summaryData = updatedData
      }

-- | Processes a single event and updates the transaction summary map.
--
-- GlobalStreamEvent is nested: StreamEvent () SequenceNumber (VersionedStreamEvent event)
-- where VersionedStreamEvent event = StreamEvent UUID EventVersion event
-- So we need to unwrap twice to get the payload and stream key (UUID).
processEvent ::
  Map TransactionId TransactionSummaryData ->
  GlobalStreamEvent AccountingEvent ->
  Map TransactionId TransactionSummaryData
processEvent summaries globalEvent =
  let versionedEvent = globalEvent.payload
      streamUuid = versionedEvent.key
      payload = versionedEvent.payload
   in case payload of
        TransferInitiatedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> summaries
            Just transactionId ->
              -- Use insertWith to avoid overwriting terminal states (Completed/Failed).
              -- In depth-first event bus dispatch, TransferCompleted/TransferFailed
              -- may be processed before TransferInitiated for the same transaction.
              -- The merge function keeps the existing entry if one already exists.
              let newEntry =
                    TransactionSummaryData
                      { fromAccountId = evt.fromAccountId,
                        toAccountId = evt.toAccountId,
                        amount = evt.amount,
                        reason = evt.reason,
                        status = Pending
                      }
               in Map.insertWith (\_ existing -> existing) transactionId newEntry summaries
        TransferCompletedEvent _evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> summaries
            Just transactionId ->
              Map.adjust
                (\summary -> summary {status = Completed})
                transactionId
                summaries
        TransferFailedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> summaries
            Just transactionId ->
              Map.adjust
                ( \summary ->
                    summary {status = Failed evt.reason}
                )
                transactionId
                summaries
        _ -> summaries -- Ignore account events

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieves the transaction summary for a specific transaction ID.
--
-- Returns 'Nothing' if the transaction doesn't exist in the read model.
--
-- Example:
-- >>> maybeSummary <- getTransactionSummary readModel transactionId
-- >>> case maybeSummary of
-- >>>   Just summary -> print (summary.status)
-- >>>   Nothing -> putStrLn "Transaction not found"
getTransactionSummary ::
  (MonadIO m) =>
  TVar TransactionSummaryReadModel ->
  TransactionId ->
  m (Maybe TransactionSummaryData)
getTransactionSummary readModelTVar transactionId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup transactionId model.summaryData

-- | Retrieves all transaction summaries in the read model.
--
-- Returns a map from TransactionId to TransactionSummaryData for all known transactions.
--
-- Example:
-- >>> allSummaries <- getAllTransactionSummaries readModel
-- >>> mapM_ print (Map.toList allSummaries)
getAllTransactionSummaries ::
  (MonadIO m) =>
  TVar TransactionSummaryReadModel ->
  m (Map TransactionId TransactionSummaryData)
getAllTransactionSummaries readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return model.summaryData

-- | Checks if a transaction exists in the read model.
--
-- This is more efficient than checking if 'getTransactionSummary' returns 'Just'.
--
-- Example:
-- >>> exists <- transactionExists readModel transactionId
-- >>> if exists then returnStatus else return404
transactionExists ::
  (MonadIO m) =>
  TVar TransactionSummaryReadModel ->
  TransactionId ->
  m Bool
transactionExists readModelTVar transactionId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member transactionId model.summaryData

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extracts the map of transaction summaries from the read model.
--
-- This is useful for testing and debugging.
--
-- Example:
-- >>> summaryMap <- transactionSummaryToMap readModel
-- >>> print $ Map.size summaryMap
transactionSummaryToMap ::
  (MonadIO m) =>
  TVar TransactionSummaryReadModel ->
  m (Map TransactionId TransactionSummaryData)
transactionSummaryToMap = getAllTransactionSummaries
