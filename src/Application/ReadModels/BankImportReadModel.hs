{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.BankImportReadModel
-- Description : Read model for bank import deduplication
--
-- This module implements a read model that indexes external transaction IDs
-- from TransactionPostingInitiated events. It is used by the bank import service to
-- detect and prevent duplicate imports of bank transactions.
--
-- Key Components:
--   - BankImportReadModel: Map of external transaction IDs to transaction IDs
--   - isImported: Check if an external transaction has already been imported
--   - Event handlers: Update the index when TransactionPostingInitiated events occur
--
-- Design Rationale:
--   - Enables O(1) deduplication lookups during bank statement import
--   - Only indexes transactions that have an externalTransactionId
--   - Follows the same TVar-based pattern as other read models
module Application.ReadModels.BankImportReadModel
  ( BankImportReadModel (..),
    createBankImportReadModel,
    handleBankImportEvents,
    isImported,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Domain.Core.Types (ExternalTransactionId, TransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionPostingInitiated (..))
import Eventium (EventHandler (..), GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import Infrastructure.Eventium (AccountingReadModelHandler)
import Infrastructure.Eventium.GlobalEvent (unpackGlobalEvent)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Read model state for bank import deduplication.
--
-- Maps external transaction IDs (from bank providers) to internal transaction IDs.
-- Used to check whether a bank transaction has already been imported.
data BankImportReadModel = BankImportReadModel
  { latestSequence :: SequenceNumber,
    importedTransactions :: !(Map ExternalTransactionId TransactionId)
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty bank import read model.
createBankImportReadModel :: (MonadIO m) => m (TVar BankImportReadModel)
createBankImportReadModel =
  liftIO $
    newTVarIO $
      BankImportReadModel
        { latestSequence = -1,
          importedTransactions = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Checks whether an external transaction ID has already been imported.
isImported :: (MonadIO m) => TVar BankImportReadModel -> ExternalTransactionId -> m Bool
isImported rmTVar extId = do
  rm <- liftIO $ readTVarIO rmTVar
  return $ Map.member extId rm.importedTransactions

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- Processes TransactionPostingInitiated events that have an externalTransactionId,
-- indexing the mapping from external ID to internal transaction ID.
handleBankImportEvents ::
  (MonadIO m) =>
  TVar BankImportReadModel ->
  AccountingReadModelHandler m
handleBankImportEvents rmTVar = EventHandler $ \events -> do
  currentModel <- liftIO $ readTVarIO rmTVar
  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedMap = foldl processEvent currentModel.importedTransactions events
  liftIO . atomically . writeTVar rmTVar $
    currentModel
      { latestSequence = newSeq,
        importedTransactions = updatedMap
      }

-- | Processes a single event and updates the external transaction ID index.
--
-- Two cases matter:
--   * 'TransactionPostingInitiatedEvent' with an external transaction id -> record the
--     mapping so future imports of the same bank tx are deduplicated.
--   * 'TransactionPostingFailedEvent' -> drop any mapping that pointed at the failing
--     stream. The transfer saga emits 'TransactionPostingInitiated' before running the
--     debit/credit and 'TransactionPostingFailed' when a step (e.g. insufficient
--     funds) aborts the transfer. Without this eviction, a failed bank
--     import would be permanently marked as imported and could never be
--     retried, even after the user corrects the underlying issue
--     (overdraft, top-up, etc.).
processEvent ::
  Map ExternalTransactionId TransactionId ->
  GlobalStreamEvent AccountingEvent ->
  Map ExternalTransactionId TransactionId
processEvent txMap globalEvent =
  let (streamUuid, payload) = unpackGlobalEvent globalEvent
   in case payload of
        TransactionPostingInitiatedEvent evt ->
          case evt.externalTransactionId of
            Just extId ->
              case mkTransactionIdSafe streamUuid of
                Just txId -> Map.insert extId txId txMap
                Nothing -> txMap
            Nothing -> txMap
        TransactionPostingFailedEvent _ ->
          case mkTransactionIdSafe streamUuid of
            Just failedTxId -> Map.filter (/= failedTxId) txMap
            Nothing -> txMap
        _ -> txMap
