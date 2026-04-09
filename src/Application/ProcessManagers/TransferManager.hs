{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ProcessManagers.TransferManager
-- Description : Process manager (saga) for coordinating money transfers
--
-- This module implements a process manager that coordinates money transfers
-- between accounts. It acts as a saga coordinator, ensuring that either both
-- the debit and credit operations complete successfully, or the transfer fails
-- with appropriate compensation.
--
-- The Transfer Saga Flow:
--
-- 1. User initiates transfer (TransferInitiated event on transaction stream)
-- 2. Process manager issues DebitAccount to source account
-- 3. If debit succeeds (AccountDebited event on source account stream):
--    - Issue CreditAccount command to target account
--    - Issue CompleteTransfer command to transaction
-- 4. If debit fails (CommandFailed from dispatcher):
--    - Compensation issues FailTransfer (declared in reactToTransferEvent)
-- 5. On AccountCredited (target account stream):
--    - Clean up transfer tracking (saga complete)
--
-- Note: Debit failure compensation is declared via IssueCommandWithCompensation
-- in reactToTransferEvent. The process manager handles its own compensation.
--
-- Key Components:
--   - TransferManager: Process manager state tracking transfers
--   - TransferData: Per-transfer tracking information
--   - transferManagerProjection: Projection handling state updates
--   - reactToTransferEvent: Pure react function returning effects
--   - transferProcessManager: Main process manager
module Application.ProcessManagers.TransferManager
  ( -- * Transfer Manager Types
    TransferManager (..),
    TransferData (..),

    -- * Process Manager
    TransferProcessManager,
    transferProcessManager,

    -- * Projection
    transferManagerProjection,

    -- * Internal (exported for testing)
    handleTransferEvent,
    reactToTransferEvent,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, TransactionId, mkTransactionIdSafe, unAccountId, unTransactionId)
import Domain.Models
import Eventium
  ( ProcessManager (..),
    ProcessManagerEffect (..),
    Projection (..),
    RejectionReason (..),
    StreamEvent (..),
    TypeEmbedding (..),
    VersionedStreamEvent,
  )
import Optics (at, makeFieldLabelsNoPrefix, (%), (%~), (&), (?~), (^.))

-- | Extract the embedding function from a 'TypeEmbedding'.
embedWith :: TypeEmbedding a b -> a -> b
embedWith (TypeEmbedding e _) = e

-- -----------------------------------------------------------------------------
-- Transfer Manager State
-- -----------------------------------------------------------------------------

-- | Transfer manager state.
--
-- The process manager maintains a map of active transfers, keyed by transaction ID.
-- For each transfer, it tracks the source and target accounts to coordinate the saga.
data TransferManager = TransferManager
  { -- | Map of transaction ID to transfer tracking data
    transfers :: Map TransactionId TransferData
  }
  deriving (Show)

-- | Phase of a transfer within the saga.
data TransferPhase
  = -- | Transfer initiated, awaiting debit
    AwaitingDebit
  | -- | Debit issued, awaiting debit confirmation
    DebitIssued
  | -- | Debit confirmed, credit and complete issued
    CreditIssued
  deriving (Show, Eq)

-- | Per-transfer tracking data.
--
-- Records the source and target accounts for a transfer so the process manager
-- can coordinate operations across both accounts.
data TransferData = TransferData
  { -- | Source account (being debited)
    sourceAccount :: AccountId,
    -- | Target account (being credited)
    targetAccount :: AccountId,
    -- | Amount debited from source account
    sourceAmount :: Money,
    -- | Amount credited to target account
    targetAmount :: Money,
    -- | Description of the transfer
    description :: Text,
    -- | Current phase of the transfer saga
    phase :: TransferPhase
  }
  deriving (Show, Eq)

-- Generate optics labels for TransferManager
makeFieldLabelsNoPrefix ''TransferManager

-- | Initial/default transfer manager state.
transferManagerDefault :: TransferManager
transferManagerDefault = TransferManager Map.empty

-- -----------------------------------------------------------------------------
-- Transfer Manager Projection (state updates only)
-- -----------------------------------------------------------------------------

-- | Projection for the transfer manager.
--
-- This projection only updates internal state. Command-issuing logic is in
-- 'reactToTransferEvent'.
transferManagerProjection :: Projection TransferManager (VersionedStreamEvent AccountingEvent)
transferManagerProjection =
  Projection
    transferManagerDefault
    handleTransferEvent

-- | Handle an event and update process manager state.
--
-- State updates only — no side effects or command generation.
handleTransferEvent :: TransferManager -> VersionedStreamEvent AccountingEvent -> TransferManager
-- Store transfer data when a new transfer is initiated
handleTransferEvent manager (StreamEvent txUuid _ _ (TransferInitiatedEvent evt)) =
  case mkTransactionIdSafe txUuid of
    Nothing -> manager
    Just txId ->
      case manager ^. #transfers % at txId of
        Nothing ->
          -- First time seeing this transfer: track it in AwaitingDebit phase
          manager
            & #transfers
            % at txId
            ?~ TransferData
              { sourceAccount = evt.sourceAccountId,
                targetAccount = evt.targetAccountId,
                sourceAmount = evt.sourceAmount,
                targetAmount = evt.targetAmount,
                description = evt.description,
                phase = AwaitingDebit
              }
        Just td
          | td.phase == AwaitingDebit ->
              -- Advance to DebitIssued after first reaction
              manager
                & #transfers
                % at txId
                ?~ td {phase = DebitIssued}
        _ -> manager
-- Clean up transfer tracking when credit succeeds (saga complete)
handleTransferEvent manager (StreamEvent _ _ _ (AccountCreditedEvent evt)) =
  manager & #transfers %~ Map.delete evt.transactionId
-- All other events: no state change
handleTransferEvent manager _ = manager

-- -----------------------------------------------------------------------------
-- React Function (pure command generation)
-- -----------------------------------------------------------------------------

-- | React to events by producing process manager effects.
--
-- This is the pure react function that determines what commands to issue
-- in response to events. It receives the state /after/ the projection has
-- processed the event.
--
-- Event reactions:
--  - TransferInitiated: Issue DebitAccount to source account
--  - AccountDebited: Issue CreditAccount to target + CompleteTransfer
--  - All others: No reaction
--
-- Note: Debit failure compensation is declared via IssueCommandWithCompensation.
-- The process manager handles its own compensation.
reactToTransferEvent :: TransferManager -> VersionedStreamEvent AccountingEvent -> [ProcessManagerEffect AccountingCommand]
-- TransferInitiated -> Issue DebitAccount to source (with compensation on failure)
reactToTransferEvent manager (StreamEvent txUuid _ _ (TransferInitiatedEvent evt)) =
  case mkTransactionIdSafe txUuid of
    Nothing -> []
    Just txId ->
      case manager ^. #transfers % at txId of
        Just td
          | td.phase == AwaitingDebit ->
              [ IssueCommandWithCompensation
                  (unAccountId evt.sourceAccountId)
                  ( embedWith
                      accountCommandEmbedding
                      ( DebitAccountAccountCommand
                          DebitAccount
                            { amount = evt.sourceAmount,
                              transactionId = txId,
                              description = evt.description
                            }
                      )
                  )
                  ( \(RejectionReason rejReason) ->
                      [ IssueCommand
                          (unTransactionId txId)
                          ( embedWith
                              transactionCommandEmbedding
                              ( FailTransferTransactionCommand
                                  FailTransfer {reason = rejReason}
                              )
                          )
                      ]
                  )
              ]
        _ -> [] -- Idempotency: not in AwaitingDebit phase
        -- AccountDebited -> Issue CreditAccount + CompleteTransfer
reactToTransferEvent manager (StreamEvent _ _ _ (AccountDebitedEvent evt)) =
  case Map.lookup evt.transactionId (manager ^. #transfers) of
    Nothing -> []
    Just TransferData {..} ->
      [ IssueCommand
          (unAccountId targetAccount)
          ( embedWith
              accountCommandEmbedding
              ( CreditAccountAccountCommand
                  CreditAccount
                    { amount = targetAmount,
                      transactionId = evt.transactionId,
                      description = description
                    }
              )
          ),
        IssueCommand
          (unTransactionId evt.transactionId)
          ( embedWith
              transactionCommandEmbedding
              (CompleteTransferTransactionCommand CompleteTransfer)
          )
      ]
-- All other events: no reaction
reactToTransferEvent _ _ = []

-- -----------------------------------------------------------------------------
-- Process Manager
-- -----------------------------------------------------------------------------

-- | Type alias for the transfer process manager.
type TransferProcessManager = ProcessManager TransferManager AccountingEvent AccountingCommand

-- | The transfer process manager.
--
-- Combines the projection (state tracking) with the react function (command generation).
--
-- Saga Flow:
--
-- Successful Transfer:
-- 1. TransferInitiated -> Store transfer data, issue DebitAccount to source
-- 2. AccountDebited -> Issue CreditAccount to target, issue CompleteTransfer
-- 3. AccountCredited -> Clean up tracking (saga complete)
--
-- Failed Transfer (Insufficient Funds):
-- 1. TransferInitiated -> Store transfer data, issue DebitAccount with compensation
-- 2. DebitAccount rejected -> Compensation issues FailTransfer to transaction
transferProcessManager :: TransferProcessManager
transferProcessManager =
  ProcessManager
    transferManagerProjection
    reactToTransferEvent
