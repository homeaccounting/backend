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
    TransactionFilter (..),
    mkTransactionFilter,
    emptyTransactionFilter,

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
    touchesVisible,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortBy)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime (..))
import Domain.Core.Page (Page (..))
import Domain.Core.Range (Range, within)
import Domain.Core.Types (AccountId, Allocation (..), DictionaryEntryId, ExchangeRate, LabelId, Money, TransactionId, TransactionType (..), allAllocations, allocationsOf, mkTransactionIdSafe, replaceAllocations)
import Domain.Models
  ( AccountingEvent
      ( TransactionAllocationsChangedEvent,
        TransactionAmendmentCompletedEvent,
        TransactionAmendmentFailedEvent,
        TransactionAmendmentInitiatedEvent,
        TransactionCancellationCompletedEvent,
        TransactionCancellationInitiatedEvent,
        TransactionDateChangedEvent,
        TransactionDescriptionChangedEvent,
        TransactionLabelsSetEvent,
        TransactionPostingCompletedEvent,
        TransactionPostingFailedEvent,
        TransactionPostingInitiatedEvent
      ),
  )
import qualified Domain.Transaction.Events
import Domain.Transaction.Projection (StatusKind, TransactionStatus (Cancelled, Completed, Failed, Pending), statusKind)
import Eventium (EventHandler (..), GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
import Infrastructure.Eventium (AccountingReadModelHandler)
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
    transactionType :: TransactionType,
    date :: UTCTime,
    labels :: Set LabelId,
    -- | Count of 'TransactionAmendmentCompleted' events folded on this
    -- transaction. @0@ when never amended.
    amendmentCount :: Word
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

-- | Standardized transaction query filter. Each field is an optional
-- constraint; 'Nothing' means "no constraint on this field". Build values via
-- 'mkTransactionFilter' or 'emptyTransactionFilter'; read fields via dot access.
data TransactionFilter = TransactionFilter
  { accountId :: Maybe AccountId,
    -- | Inclusive business-date range. Named 'dateRange' (not 'date') to
    -- avoid a 'DuplicateRecordFields' collision with 'TransactionData.date'.
    dateRange :: Maybe (Range UTCTime),
    -- | Status set (IN). Named 'statuses' (not 'status') to avoid a collision
    -- with 'TransactionData.status'.
    statuses :: Maybe (NonEmpty StatusKind),
    label :: Maybe (NonEmpty LabelId)
  }
  deriving (Show, Eq)

-- | Assemble a filter. Cross-field validation (date @from <= to@) is the
-- caller's responsibility via 'Domain.Core.Range.mkRange' at the boundary.
mkTransactionFilter ::
  Maybe AccountId ->
  Maybe (Range UTCTime) ->
  Maybe (NonEmpty StatusKind) ->
  Maybe (NonEmpty LabelId) ->
  TransactionFilter
mkTransactionFilter a d s l =
  TransactionFilter {accountId = a, dateRange = d, statuses = s, label = l}

-- | A filter with no constraints (every visible transaction matches).
emptyTransactionFilter :: TransactionFilter
emptyTransactionFilter = TransactionFilter Nothing Nothing Nothing Nothing

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
--  - TransactionPostingInitiated: Adds new transaction with Pending status
--  - TransactionPostingCompleted: Updates status to Completed
--  - TransactionPostingFailed: Updates status to Failed with reason
--  - TransactionLabelsSet: Replaces the labels set
--  - TransactionAllocationsChanged: Replaces the categorised TransactionType payload
--  - TransactionDescriptionChanged: Replaces the description
--  - TransactionDateChanged: Replaces the business date
--
-- The function is idempotent - replaying the same events produces the same result.
--
-- Example:
-- >>> handleTransactionEvents readModelTVar events
-- >>> transaction <- getTransaction readModelTVar transactionId
handleTransactionEvents ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  AccountingReadModelHandler m
handleTransactionEvents readModelTVar = EventHandler $ \events -> do
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
        TransactionPostingInitiatedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              -- Use insertWith to avoid overwriting terminal states (Completed/Failed).
              -- In depth-first event bus dispatch, TransactionPostingCompleted/TransactionPostingFailed
              -- may be processed before TransactionPostingInitiated for the same transaction.
              -- The merge function keeps the existing entry if one already exists.
              let newEntry =
                    TransactionData
                      { sourceAccountId = evt.sourceAccountId,
                        targetAccountId = evt.targetAccountId,
                        sourceAmount = evt.sourceAmount,
                        targetAmount = evt.targetAmount,
                        exchangeRate = evt.exchangeRate,
                        description = evt.description,
                        status = Pending,
                        transactionType = evt.transactionType,
                        date = evt.at,
                        labels = evt.labels,
                        amendmentCount = 0
                      }
               in Map.insertWith (\_ existing -> existing) transactionId newEntry transactions
        TransactionPostingCompletedEvent _evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                (\transaction -> transaction {status = Completed})
                transactionId
                transactions
        TransactionPostingFailedEvent evt ->
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
        TransactionAllocationsChangedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                ( \transaction ->
                    (transaction :: TransactionData)
                      { transactionType =
                          replaceAllocations evt.newAllocations transaction.transactionType
                      }
                )
                transactionId
                transactions
        TransactionDescriptionChangedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                (\transaction -> (transaction :: TransactionData) {description = evt.newDescription})
                transactionId
                transactions
        TransactionDateChangedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                (\transaction -> (transaction :: TransactionData) {date = evt.newAt})
                transactionId
                transactions
        TransactionAmendmentInitiatedEvent _evt -> transactions -- saga-internal marker
        TransactionAmendmentCompletedEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                ( \transaction ->
                    (transaction :: TransactionData)
                      { sourceAccountId = evt.newSourceAccountId,
                        targetAccountId = evt.newTargetAccountId,
                        sourceAmount = evt.newSourceAmount,
                        targetAmount = evt.newTargetAmount,
                        exchangeRate = evt.newExchangeRate,
                        transactionType = evt.newTransactionType,
                        amendmentCount = transaction.amendmentCount + 1
                      }
                )
                transactionId
                transactions
        TransactionAmendmentFailedEvent _evt -> transactions -- informational; no canonical change
        TransactionCancellationInitiatedEvent _evt -> transactions -- saga-internal marker; no canonical change
        TransactionCancellationCompletedEvent _evt ->
          case mkTransactionIdSafe streamUuid of
            Nothing -> transactions
            Just transactionId ->
              Map.adjust
                (\transaction -> (transaction :: TransactionData) {status = Cancelled})
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

-- | List transactions visible to the caller, filtered by 'TransactionFilter'
-- and paginated by 'Page'. Returns @(totalMatches, pageSlice)@ where
-- @totalMatches@ counts all matches before slicing.
--
-- Semantics (see docs/specs/2026-06-09-transaction-query-language-design.md):
--
--  1. Keep entries where at least one of sourceAccountId/targetAccountId is
--     in the visible set (access-control precondition supplied by the
--     service).
--  2. Apply each present filter field; absent fields impose no constraint.
--     Date bounds apply (inclusive) to 'TransactionData.date', the business
--     timestamp; @status@ matches by 'StatusKind'; @label@ matches by set
--     overlap.
--  3. Sort by date descending (ties broken by TransactionId), count, then
--     slice by @offset@/@limit@. This maps directly onto a future
--     @COUNT(*)@ + @ORDER BY .. OFFSET .. LIMIT@ DB query.
listTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  Set AccountId ->
  TransactionFilter ->
  Page ->
  m (Int, [(TransactionId, TransactionData)])
listTransactions readModelTVar visible filt page = do
  model <- liftIO $ readTVarIO readModelTVar
  let matches =
        [ (txId, td)
        | (txId, td) <- Map.toList model.transactions,
          touchesVisible visible td,
          matchesAccount td,
          matchesDate td,
          matchesStatus td,
          matchesLabel td
        ]
      sorted = sortBy descendingByDate matches
      total = length sorted
      slice = take page.limit (drop page.offset sorted)
  pure (total, slice)
  where
    matchesAccount td = case filt.accountId of
      Nothing -> True
      Just a -> td.sourceAccountId == a || td.targetAccountId == a
    matchesDate td = maybe True (\r -> within r td.date) filt.dateRange
    matchesStatus td =
      maybe True (\ks -> statusKind td.status `elem` ks) filt.statuses
    matchesLabel td =
      maybe
        True
        (not . Set.disjoint td.labels . Set.fromList . NE.toList)
        filt.label
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

-- | Whether a transaction touches at least one account in the visible set,
-- on either its source or target leg. This is the access-control visibility
-- predicate shared by 'listTransactions' and the reporting aggregations.
touchesVisible :: Set AccountId -> TransactionData -> Bool
touchesVisible visible td =
  Set.member td.sourceAccountId visible
    || Set.member td.targetAccountId visible

-- | Count transactions that reference the given dictionary entry id, either
-- as a label (via 'TransactionData.labels') or as the categorised
-- 'TransactionType' (Income / Expense).
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
      td.status /= Cancelled
        && ( Set.member entryId td.labels
               || referencesInAllocations td.transactionType
           )
    referencesInAllocations :: TransactionType -> Bool
    referencesInAllocations tt = case allocationsOf tt of
      Nothing -> False
      Just allocs -> any (\(Allocation cid _) -> cid == entryId) (allAllocations allocs)
