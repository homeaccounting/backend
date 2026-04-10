{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.Transaction
-- Description : Read model for optimized transaction queries
--
-- This module implements a read model that provides efficient queries for transaction
-- information without requiring event replay. The read model listens to the event
-- stream and maintains a denormalized view optimized for common query patterns.
--
-- Key Components:
--   - TransactionData: Denormalized transaction information
--   - TransactionReadModel: Map of transaction IDs to summary data
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
module Application.ReadModels.Transaction
  ( -- * Read Model Types
    TransactionData (..),
    TransactionReadModel,

    -- * Read Model Creation
    createTransactionReadModel,

    -- * Event Handler
    handleTransactionEvents,

    -- * Query Functions
    getTransaction,
    getAllTransactions,
    transactionExists,

    -- * Helper Functions
    transactionToMap,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Domain.Core.Types (AccountId, ExchangeRate, Money, TransactionId, TransferType, mkTransactionIdSafe)
import Domain.Models
  ( AccountingEvent (TransferCompletedEvent, TransferFailedEvent, TransferInitiatedEvent),
  )
import Domain.Transaction.Events
  ( TransferFailed (..),
    TransferInitiated (..),
  )
import Domain.Transaction.Projection (TransactionStatus (Completed, Failed, Pending))
import Eventium (EventMetadata (..), GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Denormalized transaction information for efficient querying.
--
-- This structure contains all the information needed for common transaction queries
-- without requiring event replay. It's optimized for read operations.
data TransactionData
  = TransactionData
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    status :: TransactionStatus,
    transferType :: TransferType,
    date :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionData

instance FromJSON TransactionData

-- | The read model state: a map from transaction IDs to their summary data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data TransactionReadModel
  = TransactionReadModel
  { latestSequence :: SequenceNumber,
    summaryData :: Map TransactionId TransactionData
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
-- >>> readModel <- createTransactionReadModel
-- >>> summary <- getTransaction readModel someTransactionId
createTransactionReadModel :: (MonadIO m) => m (TVar TransactionReadModel)
createTransactionReadModel =
  liftIO $
    newTVarIO $
      TransactionReadModel
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
-- >>> handleTransactionEvents readModelTVar events
-- >>> summary <- getTransaction readModelTVar transactionId
handleTransactionEvents ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleTransactionEvents readModelTVar events = do
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
  Map TransactionId TransactionData ->
  GlobalStreamEvent AccountingEvent ->
  Map TransactionId TransactionData
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
              let eventDate =
                    fromMaybe
                      (fromMaybe (UTCTime (fromGregorian 1970 1 1) 0) versionedEvent.metadata.createdAt)
                      versionedEvent.metadata.occurredAt
                  newEntry =
                    TransactionData
                      { sourceAccountId = evt.sourceAccountId,
                        targetAccountId = evt.targetAccountId,
                        sourceAmount = evt.sourceAmount,
                        targetAmount = evt.targetAmount,
                        exchangeRate = evt.exchangeRate,
                        description = evt.description,
                        status = Pending,
                        transferType = evt.transferType,
                        date = eventDate
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
-- >>> maybeSummary <- getTransaction readModel transactionId
-- >>> case maybeSummary of
-- >>>   Just summary -> print (summary.status)
-- >>>   Nothing -> putStrLn "Transaction not found"
getTransaction ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  TransactionId ->
  m (Maybe TransactionData)
getTransaction readModelTVar transactionId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup transactionId model.summaryData

-- | Retrieves all transaction summaries in the read model.
--
-- Returns a map from TransactionId to TransactionData for all known transactions.
--
-- Example:
-- >>> allSummaries <- getAllTransactions readModel
-- >>> mapM_ print (Map.toList allSummaries)
getAllTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  m (Map TransactionId TransactionData)
getAllTransactions readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return model.summaryData

-- | Checks if a transaction exists in the read model.
--
-- This is more efficient than checking if 'getTransaction' returns 'Just'.
--
-- Example:
-- >>> exists <- transactionExists readModel transactionId
-- >>> if exists then returnStatus else return404
transactionExists ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
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
-- >>> summaryMap <- transactionToMap readModel
-- >>> print $ Map.size summaryMap
transactionToMap ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  m (Map TransactionId TransactionData)
transactionToMap = getAllTransactions
