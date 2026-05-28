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
import Data.Maybe (mapMaybe)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( TransactionId,
    UserId,
    unTransactionId,
  )
import Domain.Models
  ( AccountingEvent
      ( TransactionCategoryChangedEvent,
        TransactionDateChangedEvent,
        TransactionDescriptionChangedEvent,
        TransactionLabelsSetEvent,
        TransferAmendmentCompletedEvent,
        TransferAmendmentFailedEvent,
        TransferAmendmentInitiatedEvent,
        TransferCompletedEvent,
        TransferFailedEvent,
        TransferInitiatedEvent
      ),
  )
import Domain.Transaction.Events
  ( TransactionCategoryChanged,
    TransactionDateChanged,
    TransactionDescriptionChanged,
    TransactionLabelsSet,
    TransferAmendmentCompleted,
    TransferAmendmentFailed,
    TransferAmendmentInitiated,
    TransferFailed,
    TransferInitiated,
  )
import Eventium (EventStoreReader (..), StreamEvent (..), VersionedStreamEvent, allEvents)
import GHC.Generics (Generic)
import Infrastructure.App
  ( AppM,
    HasReadModel (..),
    eventStoreReaderL,
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
  = HistoryInitiated TransferInitiated
  | HistoryCompleted
  | HistoryFailed TransferFailed
  | HistoryLabelsSet TransactionLabelsSet
  | HistoryCategoryChanged TransactionCategoryChanged
  | HistoryDescriptionChanged TransactionDescriptionChanged
  | HistoryDateChanged TransactionDateChanged
  | HistoryAmendmentInitiated TransferAmendmentInitiated
  | HistoryAmendmentCompleted TransferAmendmentCompleted
  | HistoryAmendmentFailed TransferAmendmentFailed
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
  txnRM <- lift (view transactionReadModelL)
  transaction <-
    liftMaybeM
      (NotFound "Transaction" (tshow transactionId))
      (liftIO (ReadModel.getTransaction txnRM transactionId))
  -- Access: caller has any role on either the current source or target.
  accountRM <- lift (view accountReadModelL)
  mSrc <- liftIO (AccountRM.getAccount accountRM transaction.sourceAccountId)
  mTgt <- liftIO (AccountRM.getAccount accountRM transaction.targetAccountId)
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
  TransferInitiatedEvent e -> Just (HistoryInitiated e)
  TransferCompletedEvent _ -> Just HistoryCompleted
  TransferFailedEvent e -> Just (HistoryFailed e)
  TransactionLabelsSetEvent e -> Just (HistoryLabelsSet e)
  TransactionCategoryChangedEvent e -> Just (HistoryCategoryChanged e)
  TransactionDescriptionChangedEvent e -> Just (HistoryDescriptionChanged e)
  TransactionDateChangedEvent e -> Just (HistoryDateChanged e)
  TransferAmendmentInitiatedEvent e -> Just (HistoryAmendmentInitiated e)
  TransferAmendmentCompletedEvent e -> Just (HistoryAmendmentCompleted e)
  TransferAmendmentFailedEvent e -> Just (HistoryAmendmentFailed e)
  _ -> Nothing
