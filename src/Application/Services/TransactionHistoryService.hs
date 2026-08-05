{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionHistoryService
-- Description : Read service for the per-transaction audit history.
--
-- Returns the full ordered list of TX-aggregate events as a
-- 'TransactionHistory' DTO. Access requires at least Viewer on one of
-- the transaction's current source / target accounts (per spec §6.2);
-- amendments that change those accounts widen access automatically.
--
-- Implementation reads the TX-aggregate's stream directly via the
-- versioned event-store reader rather than from a maintained
-- projection. Audit views are low-frequency and need the canonical
-- stream, not a denormalised snapshot.
module Application.Services.TransactionHistoryService
  ( -- * Service
    getTransactionHistory,

    -- * DTOs
    TransactionHistory (..),
    TransactionHistoryEntry (..),
  )
where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.AuthorizationService (AccountAccessResult (..), AccountAuthData (..), canAccessAccount)
import Application.Services.Internal (guardE, liftMaybeM)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (FromJSON, ToJSON)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( TransactionId,
    UserId,
    unTransactionId,
  )
import Domain.Models
  ( AccountingEvent
      ( TransactionAllocationsChangedEvent,
        TransactionAmendmentCompletedEvent,
        TransactionAmendmentFailedEvent,
        TransactionAmendmentInitiatedEvent,
        TransactionCancellationCompletedEvent,
        TransactionCancellationInitiatedEvent,
        TransactionContactSetEvent,
        TransactionDateChangedEvent,
        TransactionDescriptionChangedEvent,
        TransactionImportReconciledEvent,
        TransactionLabelsSetEvent,
        TransactionMergeCompletedEvent,
        TransactionMergeFailedEvent,
        TransactionMergeInitiatedEvent,
        TransactionPostingCompletedEvent,
        TransactionPostingFailedEvent,
        TransactionPostingInitiatedEvent,
        TransactionRelationAddedEvent,
        TransactionRelationRemovedEvent
      ),
  )
import Domain.Transaction.Events
  ( TransactionAllocationsChanged,
    TransactionAmendmentCompleted,
    TransactionAmendmentFailed,
    TransactionAmendmentInitiated,
    TransactionCancellationCompleted,
    TransactionCancellationInitiated,
    TransactionContactSet,
    TransactionDateChanged,
    TransactionDescriptionChanged,
    TransactionImportReconciled,
    TransactionLabelsSet,
    TransactionMergeCompleted,
    TransactionMergeFailed,
    TransactionMergeInitiated,
    TransactionPostingFailed,
    TransactionPostingInitiated,
    TransactionRelationAdded,
    TransactionRelationRemoved,
  )
import Eventium (EventStoreReader (..), StreamEvent (..), VersionedStreamEvent, allEvents)
import Infrastructure.App
  ( AppM,
    eventStoreReaderL,
    runDb,
  )
import RIO

-- -----------------------------------------------------------------------------
-- DTOs
-- -----------------------------------------------------------------------------

-- | The transaction audit history.
--
-- Sorted chronologically by Eventium event version (the order in which
-- the events were appended to the TX stream).
data TransactionHistory = TransactionHistory
  { transactionId :: TransactionId,
    entries :: [TransactionHistoryEntry]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionHistory

instance FromJSON TransactionHistory

-- | A single entry in the audit history.
--
-- Constructors mirror the TX-aggregate events. Account-leg events
-- ('AccountDebited' etc.) are not exposed here — the audit endpoint is
-- per-transaction; account leg events live on the account streams.
data TransactionHistoryEntry
  = HistoryPostingInitiated TransactionPostingInitiated
  | HistoryPostingCompleted
  | HistoryPostingFailed TransactionPostingFailed
  | HistoryLabelsSet TransactionLabelsSet
  | HistoryContactSet TransactionContactSet
  | HistoryImportReconciled TransactionImportReconciled
  | HistoryAllocationsChanged TransactionAllocationsChanged
  | HistoryDescriptionChanged TransactionDescriptionChanged
  | HistoryDateChanged TransactionDateChanged
  | HistoryAmendmentInitiated TransactionAmendmentInitiated
  | HistoryAmendmentCompleted TransactionAmendmentCompleted
  | HistoryAmendmentFailed TransactionAmendmentFailed
  | HistoryCancellationInitiated TransactionCancellationInitiated
  | HistoryCancellationCompleted TransactionCancellationCompleted
  | HistoryMergeInitiated TransactionMergeInitiated
  | HistoryMergeCompleted TransactionMergeCompleted
  | HistoryMergeFailed TransactionMergeFailed
  | HistoryRelationAdded TransactionRelationAdded
  | HistoryRelationRemoved TransactionRelationRemoved
  deriving (Show, Eq, Generic)

instance ToJSON TransactionHistoryEntry

instance FromJSON TransactionHistoryEntry

-- -----------------------------------------------------------------------------
-- Service
-- -----------------------------------------------------------------------------

-- | Fetch the audit history for a given transaction.
--
-- Returns @Right Nothing@ when the transaction does not exist. Returns
-- @Left AccountError@ when the caller has no access (any-role) on the
-- transaction's current source or target accounts.
getTransactionHistory ::
  UserId ->
  TransactionId ->
  AppM (Either DomainError (Maybe TransactionHistory))
getTransactionHistory userId transactionId = runExceptT $ do
  transaction <-
    liftMaybeM
      (NotFound "Transaction" (tshow transactionId))
      (runDb (ReadModel.getTransaction transactionId))
  -- Access: caller has any role on either the current source or target.
  mSrc <- lift (runDb (AccountRM.getAccount transaction.sourceAccountId))
  mTgt <- lift (runDb (AccountRM.getAccount transaction.targetAccountId))
  let toAuthData acc =
        AccountAuthData
          { createdBy = acc.createdBy,
            accountType = acc.accountType,
            accessList = acc.accessList
          }
      allowed = any hasAccess (catMaybes [mSrc, mTgt])
      hasAccess acc = case canAccessAccount userId (toAuthData acc) of
        AccessGranted _ -> True
        AccessDenied -> False
  guardE allowed (AccountError "User does not have access to this transaction")
  EventStoreReader readStream <- lift (view eventStoreReaderL)
  events <- liftIO (readStream (allEvents (unTransactionId transactionId)))
  pure (Just (TransactionHistory transactionId (mapMaybe toHistoryEntry events)))

-- | Map a versioned stream event to a history entry; skips events that
-- are not TX-aggregate events (defensively — they should never appear
-- on a TX stream in practice).
toHistoryEntry :: VersionedStreamEvent AccountingEvent -> Maybe TransactionHistoryEntry
toHistoryEntry (StreamEvent _ _ _ payload) = case payload of
  TransactionPostingInitiatedEvent e -> Just (HistoryPostingInitiated e)
  TransactionPostingCompletedEvent _ -> Just HistoryPostingCompleted
  TransactionPostingFailedEvent e -> Just (HistoryPostingFailed e)
  TransactionLabelsSetEvent e -> Just (HistoryLabelsSet e)
  TransactionContactSetEvent e -> Just (HistoryContactSet e)
  TransactionImportReconciledEvent e -> Just (HistoryImportReconciled e)
  TransactionAllocationsChangedEvent e -> Just (HistoryAllocationsChanged e)
  TransactionDescriptionChangedEvent e -> Just (HistoryDescriptionChanged e)
  TransactionDateChangedEvent e -> Just (HistoryDateChanged e)
  TransactionAmendmentInitiatedEvent e -> Just (HistoryAmendmentInitiated e)
  TransactionAmendmentCompletedEvent e -> Just (HistoryAmendmentCompleted e)
  TransactionAmendmentFailedEvent e -> Just (HistoryAmendmentFailed e)
  TransactionCancellationInitiatedEvent e -> Just (HistoryCancellationInitiated e)
  TransactionCancellationCompletedEvent e -> Just (HistoryCancellationCompleted e)
  TransactionMergeInitiatedEvent e -> Just (HistoryMergeInitiated e)
  TransactionMergeCompletedEvent e -> Just (HistoryMergeCompleted e)
  TransactionMergeFailedEvent e -> Just (HistoryMergeFailed e)
  TransactionRelationAddedEvent e -> Just (HistoryRelationAdded e)
  TransactionRelationRemovedEvent e -> Just (HistoryRelationRemoved e)
  _ -> Nothing
