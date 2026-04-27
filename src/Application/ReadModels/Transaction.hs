{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

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
--   - TransactionReadModel: Map of transaction IDs to transaction data
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

    -- * Query Types
    TransactionQuery,
    mkTransactionQuery,
    emptyTransactionQuery,
    queryAccountId,
    queryFrom,
    queryTo,

    -- * Read Model Creation
    createTransactionReadModel,

    -- * Event Handler
    handleTransactionEvents,

    -- * Query Functions
    getTransaction,
    getAllTransactions,
    transactionExists,
    listTransactions,
    findReferencingTransactions,

    -- * Helper Functions
    transactionToMap,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Domain.Core.Types (AccountId, DictionaryEntryId, ExchangeRate, LabelId, Money, TransactionId, TransferType (..), mkTransactionIdSafe)
import Domain.Models
  ( AccountingEvent
      ( TransactionCategoryChangedEvent,
        TransactionLabelsSetEvent,
        TransferCompletedEvent,
        TransferFailedEvent,
        TransferInitiatedEvent
      ),
  )
import Domain.Transaction.Events
  ( TransactionCategoryChanged (..),
    TransactionLabelsSet (..),
    TransferFailed (..),
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
    date :: UTCTime,
    labels :: Set LabelId
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionData

instance FromJSON TransactionData

-- | The read model state: a map from transaction IDs to their transaction data.
--
-- This is wrapped in a TVar for concurrent access and includes the latest
-- sequence number for reliable event processing.
data TransactionReadModel
  = TransactionReadModel
  { latestSequence :: SequenceNumber,
    transactions :: Map TransactionId TransactionData
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Query Types
-- -----------------------------------------------------------------------------

-- | Filter spec for 'listTransactions'.
--
-- The data constructor is deliberately hidden; build values via
-- 'mkTransactionQuery' (which enforces the 'from' <= 'to' invariant) or
-- 'emptyTransactionQuery' (no filters). Read fields via 'queryAccountId',
-- 'queryFrom', 'queryTo'.
data TransactionQuery = TransactionQuery
  { qAccountId :: Maybe AccountId,
    qFrom :: Maybe UTCTime,
    qTo :: Maybe UTCTime
  }
  deriving (Show, Eq)

-- | Build a 'TransactionQuery'. Fails with a human-readable message when
-- both bounds are present and 'from' > 'to'.
mkTransactionQuery ::
  Maybe AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Either Text TransactionQuery
mkTransactionQuery acct mFrom mTo =
  case (mFrom, mTo) of
    (Just f, Just t)
      | f > t ->
          Left "from must be <= to"
    _ ->
      Right
        TransactionQuery
          { qAccountId = acct,
            qFrom = mFrom,
            qTo = mTo
          }

-- | Query that matches every transaction (all filters unset).
emptyTransactionQuery :: TransactionQuery
emptyTransactionQuery =
  TransactionQuery
    { qAccountId = Nothing,
      qFrom = Nothing,
      qTo = Nothing
    }

-- | Account filter, if any.
queryAccountId :: TransactionQuery -> Maybe AccountId
queryAccountId q = q.qAccountId

-- | Lower bound on the transaction's business timestamp, inclusive.
queryFrom :: TransactionQuery -> Maybe UTCTime
queryFrom q = q.qFrom

-- | Upper bound on the transaction's business timestamp, inclusive.
queryTo :: TransactionQuery -> Maybe UTCTime
queryTo q = q.qTo

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty transaction read model.
--
-- This initializes the read model with:
--  - Sequence number -1 (before any events)
--  - Empty map of transactions
--
-- Example:
-- >>> readModel <- createTransactionReadModel
-- >>> transaction <- getTransaction readModel someTransactionId
createTransactionReadModel :: (MonadIO m) => m (TVar TransactionReadModel)
createTransactionReadModel =
  liftIO $
    newTVarIO $
      TransactionReadModel
        { latestSequence = -1,
          transactions = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- This function:
--  1. Processes each event and updates the transaction data accordingly
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
-- >>> transaction <- getTransaction readModelTVar transactionId
handleTransactionEvents ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleTransactionEvents readModelTVar events = do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedData = foldl processEvent currentModel.transactions events

  liftIO . atomically . writeTVar readModelTVar $
    currentModel
      { latestSequence = newSeq,
        transactions = updatedData
      }

-- | Processes a single event and updates the transactions map.
--
-- GlobalStreamEvent is nested: StreamEvent () SequenceNumber (VersionedStreamEvent event)
-- where VersionedStreamEvent event = StreamEvent UUID EventVersion event
-- So we need to unwrap twice to get the payload and stream key (UUID).
processEvent ::
  Map TransactionId TransactionData ->
  GlobalStreamEvent AccountingEvent ->
  Map TransactionId TransactionData
processEvent transactions globalEvent =
  let versionedEvent = globalEvent.payload
      streamUuid = versionedEvent.key
      payload = versionedEvent.payload
   in case payload of
        TransferInitiatedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
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
                        date = eventDate,
                        labels = evt.labels
                      }
               in Map.insertWith (\_ existing -> existing) transactionId newEntry transactions
        TransferCompletedEvent _evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                (\transaction -> transaction {status = Completed})
                transactionId
                transactions
        TransferFailedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                ( \transaction ->
                    transaction {status = Failed evt.reason}
                )
                transactionId
                transactions
        TransactionLabelsSetEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                (\transaction -> (transaction :: TransactionData) {labels = evt.labels})
                transactionId
                transactions
        TransactionCategoryChangedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                ( \transaction ->
                    (transaction :: TransactionData)
                      { transferType = case transaction.transferType of
                          Income _ -> Income evt.newCategory
                          Expense _ -> Expense evt.newCategory
                          Transfer -> Transfer
                      }
                )
                transactionId
                transactions
        _ -> transactions -- Ignore account events

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieves the transaction data for a specific transaction ID.
--
-- Returns 'Nothing' if the transaction doesn't exist in the read model.
--
-- Example:
-- >>> maybeTransaction <- getTransaction readModel transactionId
-- >>> case maybeTransaction of
-- >>>   Just transaction -> print (transaction.status)
-- >>>   Nothing -> putStrLn "Transaction not found"
getTransaction ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  TransactionId ->
  m (Maybe TransactionData)
getTransaction readModelTVar transactionId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup transactionId model.transactions

-- | Retrieves all transactions in the read model.
--
-- Returns a map from TransactionId to TransactionData for all known transactions.
--
-- Example:
-- >>> allTransactions <- getAllTransactions readModel
-- >>> mapM_ print (Map.toList allTransactions)
getAllTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  m (Map TransactionId TransactionData)
getAllTransactions readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return model.transactions

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
  return $ Map.member transactionId model.transactions

-- | List transactions visible to the caller, filtered by 'TransactionQuery'.
--
-- Semantics (see docs/specs/2026-04-18-list-transactions-endpoint-design.md):
--
--  1. Keep entries where at least one of sourceAccountId/targetAccountId is
--     in the visible set (access-control precondition supplied by the
--     service).
--  2. If the query carries an accountId, require the same id to appear on
--     source or target. An accountId outside the visible set therefore
--     naturally produces zero matches.
--  3. Apply inclusive from/to bounds to 'TransactionData.date', which is
--     the transaction's business timestamp (TransferInitiated event's
--     occurredAt, falling back to createdAt only when occurredAt is unset).
--  4. Sort by date descending; ties are broken by TransactionId.
listTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  Set AccountId ->
  TransactionQuery ->
  m [(TransactionId, TransactionData)]
listTransactions readModelTVar visible query = do
  model <- liftIO $ readTVarIO readModelTVar
  let matches =
        [ (txId, td)
        | (txId, td) <- Map.toList model.transactions,
          isVisible td,
          matchesAccount td,
          matchesFrom td,
          matchesTo td
        ]
  pure $ sortBy descendingByDate matches
  where
    isVisible td =
      Set.member td.sourceAccountId visible
        || Set.member td.targetAccountId visible
    matchesAccount td = case query.qAccountId of
      Nothing -> True
      Just a -> td.sourceAccountId == a || td.targetAccountId == a
    matchesFrom td = case query.qFrom of
      Nothing -> True
      Just f -> td.date >= f
    matchesTo td = case query.qTo of
      Nothing -> True
      Just t' -> td.date <= t'
    descendingByDate (idA, a) (idB, b) =
      compare b.date a.date <> compare idA idB

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extracts the map of transactions from the read model.
--
-- This is useful for testing and debugging.
--
-- Example:
-- >>> transactionsMap <- transactionToMap readModel
-- >>> print $ Map.size transactionsMap
transactionToMap ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  m (Map TransactionId TransactionData)
transactionToMap = getAllTransactions

-- | Count transactions that reference the given dictionary entry id, either
-- as a label (via 'TransactionData.labels') or as the categorised
-- 'TransferType' (Income / Expense).
--
-- Powers the service-layer in-use check that blocks deletion of a
-- dictionary entry while any transaction still references it. Performs a
-- linear scan of the read model — acceptable at current personal-accounting
-- volumes; a reverse index is a localised follow-up if measurements warrant it.
findReferencingTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  DictionaryEntryId ->
  m Int
findReferencingTransactions readModelTVar entryId = do
  model <- liftIO $ readTVarIO readModelTVar
  pure . length $ filter referencesEntry (Map.elems model.transactions)
  where
    referencesEntry td =
      Set.member entryId td.labels
        || case td.transferType of
          Income cid -> cid == entryId
          Expense cid -> cid == entryId
          Transfer -> False
