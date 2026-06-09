{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ProcessManagers.TransactionCancellationManager
-- Description : Process manager (saga) for cancelling completed transfers.
--
-- Sibling of 'TransactionAmendmentManager'. When a
-- 'TransactionCancellationInitiated' event arrives, this saga reads the
-- snapshotted posting facts from @currentPostings@ and immediately issues
-- two guaranteed-success reversal commands:
--
--   * 'ReverseAccountDebit' on the source account (original source amount,
--     original @at@).
--   * 'ReverseAccountCredit' on the target account (original target
--     amount, original @at@).
--
-- The saga waits for **both** 'AccountDebitReversed' and
-- 'AccountCreditReversed' events (in any order) before issuing
-- 'CompleteTransactionCancellation' on the TX stream.
--
-- Unlike 'TransactionAmendmentManager', there is no fallible leg and
-- therefore no compensation path. All effects use 'IssueCommand'.
--
-- Saga state is tracked per-transaction in two maps:
--
--   * @cancellations@ — in-flight saga state (set on
--     'TransactionCancellationInitiated', cleared on
--     'TransactionCancellationCompleted').
--
--   * @currentPostings@ — the current canonical posting snapshot used to
--     derive reversal amounts and the @at@ timestamp. Updated by
--     'TransactionPostingInitiated' and 'TransactionAmendmentCompleted' so that a
--     cancellation following an amendment reverses the amended facts.
module Application.ProcessManagers.TransactionCancellationManager
  ( -- * Types
    TransactionCancellationManager (..),
    TransactionCancellationData (..),
    TransferPostings (..),

    -- * Process Manager
    TransactionCancellationProcessManager,
    transactionCancellationProcessManager,

    -- * Projection
    transactionCancellationManagerProjection,

    -- * Internal (exported for testing)
    handleTransactionCancellationEvent,
    reactToTransactionCancellationEvent,
  )
where

import Application.ProcessManagers.Snapshots
  ( TransferPostings (..),
    applyTransactionAmendmentCompleted,
    applyTransactionPostingInitiated,
  )
import qualified Data.Map.Strict as Map
import Domain.Account.Events (AccountCreditReversed (..), AccountDebitReversed (..))
import Domain.Core.Types
  ( TransactionId,
    UserId,
    unAccountId,
    unTransactionId,
  )
import Domain.Models
import Eventium
  ( ProcessManager (..),
    ProcessManagerEffect (..),
    Projection (..),
    StreamEvent (..),
    VersionedStreamEvent,
  )
import Infrastructure.Eventium (embedWith)
import Optics (at, makeFieldLabelsNoPrefix, (%), (%~), (&), (?~), (^.))
import RIO ()

-- -----------------------------------------------------------------------------
-- State types
-- -----------------------------------------------------------------------------

-- | Per-cancellation tracking. Progress is captured by two boolean flags
-- rather than a leg set because the saga always issues exactly two
-- guaranteed-success reversal commands; no ordering constraint exists.
data TransactionCancellationData = TransactionCancellationData
  { -- | The transaction being cancelled.
    transactionId :: TransactionId,
    -- | User who requested the cancellation (echoed onto the completion command).
    cancelledBy :: UserId,
    -- | True once 'AccountDebitReversed' matching this 'transactionId' lands.
    sourceReversed :: Bool,
    -- | True once 'AccountCreditReversed' matching this 'transactionId' lands.
    targetReversed :: Bool
  }
  deriving (Show, Eq)

-- | Saga state. Holds both the in-flight cancellation registry and the
-- per-transaction current-postings snapshot used to derive reversal amounts.
data TransactionCancellationManager = TransactionCancellationManager
  { cancellations :: Map.Map TransactionId TransactionCancellationData,
    currentPostings :: Map.Map TransactionId TransferPostings
  }
  deriving (Show)

makeFieldLabelsNoPrefix ''TransactionCancellationData
makeFieldLabelsNoPrefix ''TransactionCancellationManager

transactionCancellationManagerDefault :: TransactionCancellationManager
transactionCancellationManagerDefault = TransactionCancellationManager Map.empty Map.empty

-- -----------------------------------------------------------------------------
-- Projection
-- -----------------------------------------------------------------------------

-- | State updates only — no side effects or command generation.
handleTransactionCancellationEvent ::
  TransactionCancellationManager ->
  VersionedStreamEvent AccountingEvent ->
  TransactionCancellationManager
handleTransactionCancellationEvent manager e@(StreamEvent _ _ _ (TransactionPostingInitiatedEvent _)) =
  manager & #currentPostings %~ applyTransactionPostingInitiated e
handleTransactionCancellationEvent manager (StreamEvent _ _ _ (TransactionAmendmentCompletedEvent evt)) =
  manager & #currentPostings %~ applyTransactionAmendmentCompleted evt
handleTransactionCancellationEvent manager (StreamEvent _ _ _ (TransactionCancellationInitiatedEvent evt)) =
  case manager ^. #currentPostings % at evt.transactionId of
    Nothing -> manager
    Just _ ->
      manager
        & #cancellations
        % at evt.transactionId
        ?~ TransactionCancellationData
          { transactionId = evt.transactionId,
            cancelledBy = evt.cancelledBy,
            sourceReversed = False,
            targetReversed = False
          }
handleTransactionCancellationEvent manager (StreamEvent _ _ _ (AccountDebitReversedEvent evt)) =
  manager
    & #cancellations
    % at evt.transactionId
    %~ fmap (\c -> c {sourceReversed = True} :: TransactionCancellationData)
handleTransactionCancellationEvent manager (StreamEvent _ _ _ (AccountCreditReversedEvent evt)) =
  manager
    & #cancellations
    % at evt.transactionId
    %~ fmap (\c -> c {targetReversed = True} :: TransactionCancellationData)
handleTransactionCancellationEvent manager (StreamEvent _ _ _ (TransactionCancellationCompletedEvent evt)) =
  manager
    & #cancellations
    %~ Map.delete evt.transactionId
    & #currentPostings
    %~ Map.delete evt.transactionId
handleTransactionCancellationEvent manager _ = manager

-- -----------------------------------------------------------------------------
-- React
-- -----------------------------------------------------------------------------

-- | Issue 'CompleteTransactionCancellation' when both flags are True.
--
-- Called after 'handleTransactionCancellationEvent' has toggled the
-- appropriate flag, so the post-toggle state is visible. Whichever
-- reversal event flips the second flag triggers the completion command.
-- Re-emission on replay is prevented by
-- 'TransactionCancellationCompletedEvent' deleting the cancellation
-- entry: once deleted, this function returns @[]@.
completeIfReady ::
  TransactionCancellationManager ->
  TransactionId ->
  [ProcessManagerEffect AccountingCommand]
completeIfReady manager txId =
  case manager ^. #cancellations % at txId of
    Just c
      | c.sourceReversed && c.targetReversed ->
          [ IssueCommand
              (unTransactionId txId)
              ( embedWith
                  transactionCommandEmbedding
                  ( CompleteTransactionCancellationTransactionCommand
                      CompleteTransactionCancellation
                        { transactionId = txId,
                          cancelledBy = c.cancelledBy
                        }
                  )
              )
              id
          ]
    _ -> []

reactToTransactionCancellationEvent ::
  TransactionCancellationManager ->
  VersionedStreamEvent AccountingEvent ->
  [ProcessManagerEffect AccountingCommand]
reactToTransactionCancellationEvent manager (StreamEvent _ _ _ (TransactionCancellationInitiatedEvent evt)) =
  case (manager ^. #cancellations % at evt.transactionId, manager ^. #currentPostings % at evt.transactionId) of
    (Just _, Just postings) ->
      [ IssueCommand
          (unAccountId postings.sourceAccountId)
          ( embedWith
              accountCommandEmbedding
              ( ReverseAccountDebitAccountCommand
                  ReverseAccountDebit
                    { amount = postings.sourceAmount,
                      transactionId = evt.transactionId,
                      at = postings.at
                    }
              )
          )
          id,
        IssueCommand
          (unAccountId postings.targetAccountId)
          ( embedWith
              accountCommandEmbedding
              ( ReverseAccountCreditAccountCommand
                  ReverseAccountCredit
                    { amount = postings.targetAmount,
                      transactionId = evt.transactionId,
                      at = postings.at
                    }
              )
          )
          id
      ]
    _ -> []
reactToTransactionCancellationEvent manager (StreamEvent _ _ _ (AccountDebitReversedEvent evt)) =
  completeIfReady manager evt.transactionId
reactToTransactionCancellationEvent manager (StreamEvent _ _ _ (AccountCreditReversedEvent evt)) =
  completeIfReady manager evt.transactionId
reactToTransactionCancellationEvent _ _ = []

-- -----------------------------------------------------------------------------
-- Wiring
-- -----------------------------------------------------------------------------

transactionCancellationManagerProjection ::
  Projection TransactionCancellationManager (VersionedStreamEvent AccountingEvent)
transactionCancellationManagerProjection =
  Projection
    transactionCancellationManagerDefault
    handleTransactionCancellationEvent

type TransactionCancellationProcessManager =
  ProcessManager TransactionCancellationManager AccountingEvent AccountingCommand

transactionCancellationProcessManager :: TransactionCancellationProcessManager
transactionCancellationProcessManager =
  ProcessManager
    transactionCancellationManagerProjection
    reactToTransactionCancellationEvent
