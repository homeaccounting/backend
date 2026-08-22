{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Shared snapshot types and fold helpers used by transfer-amendment and
-- transaction-cancellation process managers. Both managers fold
-- TransactionPostingInitiated and TransactionAmendmentCompleted events identically
-- into their own currentPostings maps.
module Application.ProcessManagers.Snapshots
  ( TransferPostings (..),
    applyTransactionPostingInitiated,
    applyTransactionAmendmentCompleted,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Domain.Core.Types (AccountId, Money, TransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..), TransactionAmendmentCompleted (..), TransactionPostingInitiated (..))
import Eventium (StreamEvent (..), VersionedStreamEvent)
import Optics (at, makeFieldLabelsNoPrefix, (%~), (&), (?~))
import RIO hiding ((%~), (&), (.~), (^.))

-- | Snapshot of the canonical posting facts at the most recently
-- committed state of a transaction.
data TransferPostings = TransferPostings
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    at :: UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

makeFieldLabelsNoPrefix ''TransferPostings

-- | Fold a 'TransactionPostingInitiated' event into a postings map: inserts a fresh
-- snapshot keyed by transactionId. The TX UUID is decoded via
-- 'mkTransactionIdSafe'; an undecodable UUID leaves the map untouched.
applyTransactionPostingInitiated ::
  VersionedStreamEvent AccountingEvent ->
  Map TransactionId TransferPostings ->
  Map TransactionId TransferPostings
applyTransactionPostingInitiated (StreamEvent txUuid _ _ (TransactionPostingInitiatedEvent evt)) m =
  case mkTransactionIdSafe txUuid of
    Nothing -> m
    Just txId ->
      m
        & at txId
        ?~ TransferPostings
          { sourceAccountId = evt.sourceAccountId,
            targetAccountId = evt.targetAccountId,
            sourceAmount = evt.sourceAmount,
            targetAmount = evt.targetAmount,
            at = evt.at
          }
applyTransactionPostingInitiated _ m = m

-- | Fold a 'TransactionAmendmentCompleted' event into a postings map: updates
-- the entry for this transactionId (if present) with the amended source/
-- target accounts and amounts. The original @at@ is preserved.
applyTransactionAmendmentCompleted ::
  TransactionAmendmentCompleted ->
  Map TransactionId TransferPostings ->
  Map TransactionId TransferPostings
applyTransactionAmendmentCompleted evt m =
  m
    & at evt.transactionId
    %~ fmap
      ( \p ->
          TransferPostings
            { sourceAccountId = evt.newSourceAccountId,
              targetAccountId = evt.newTargetAccountId,
              sourceAmount = evt.newSourceAmount,
              targetAmount = evt.newTargetAmount,
              at = p.at
            }
      )
