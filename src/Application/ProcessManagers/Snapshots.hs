{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Shared snapshot types and fold helpers used by transfer-amendment and
-- transaction-cancellation process managers. Both managers fold
-- TransferInitiated and TransferAmendmentCompleted events identically
-- into their own currentPostings maps.
module Application.ProcessManagers.Snapshots
  ( TransferPostings (..),
    applyTransferInitiated,
    applyTransferAmendmentCompleted,
  )
where

import Data.Time (UTCTime)
import Domain.Core.Types (AccountId, Money, TransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..), TransferAmendmentCompleted (..), TransferInitiated (..))
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
  deriving (Show, Eq)

makeFieldLabelsNoPrefix ''TransferPostings

-- | Fold a 'TransferInitiated' event into a postings map: inserts a fresh
-- snapshot keyed by transactionId. The TX UUID is decoded via
-- 'mkTransactionIdSafe'; an undecodable UUID leaves the map untouched.
applyTransferInitiated ::
  VersionedStreamEvent AccountingEvent ->
  Map TransactionId TransferPostings ->
  Map TransactionId TransferPostings
applyTransferInitiated (StreamEvent txUuid _ _ (TransferInitiatedEvent evt)) m =
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
applyTransferInitiated _ m = m

-- | Fold a 'TransferAmendmentCompleted' event into a postings map: updates
-- the entry for this transactionId (if present) with the amended source/
-- target accounts and amounts. The original @at@ is preserved.
applyTransferAmendmentCompleted ::
  TransferAmendmentCompleted ->
  Map TransactionId TransferPostings ->
  Map TransactionId TransferPostings
applyTransferAmendmentCompleted evt m =
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
