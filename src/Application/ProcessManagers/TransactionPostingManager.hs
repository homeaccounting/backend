{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ProcessManagers.TransactionPostingManager
-- Description : Process manager (saga) for coordinating money transfers
--
-- This module implements a process manager that coordinates money transfers
-- between accounts. It acts as a saga coordinator, ensuring that either both
-- the debit and credit operations complete successfully, or the transfer fails
-- with appropriate compensation.
--
-- The Transfer Saga Flow:
--
-- 1. User initiates transfer (TransactionPostingInitiated event on transaction stream)
-- 2. Process manager issues DebitAccount to source account
-- 3. If debit succeeds (AccountDebited event on source account stream):
--    - Issue CreditAccount command to target account
--    - Issue CompleteTransactionPosting command to transaction
-- 4. If debit fails (CommandFailed from dispatcher):
--    - Compensation issues FailTransactionPosting (declared in reactToTransactionPostingEvent)
-- 5. On AccountCredited (target account stream):
--    - Clean up transfer tracking (saga complete)
--
-- Note: Debit failure compensation is declared via IssueCommandWithCompensation
-- in reactToTransactionPostingEvent. The process manager handles its own compensation.
--
-- Key Components:
--   - TransactionPostingManager: Process manager state tracking transfers
--   - TransactionPostingData: Per-transfer tracking information
--   - transactionPostingManagerProjection: Projection handling state updates
--   - reactToTransactionPostingEvent: Pure react function returning effects
--   - transferProcessManager: Main process manager
module Application.ProcessManagers.TransactionPostingManager
  ( -- * Transfer Manager Types
    TransactionPostingManager (..),
    TransactionPostingData (..),

    -- * Process Manager
    TransactionPostingProcessManager,
    transferProcessManager,

    -- * Projection
    transactionPostingManagerProjection,

    -- * Internal (exported for testing)
    handleTransactionPostingEvent,
    reactToTransactionPostingEvent,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Domain.Core.Types (AccountId, Money, TransactionId, mkTransactionIdSafe, unAccountId, unTransactionId)
import Domain.Models
import Eventium
  ( ProcessManager (..),
    ProcessManagerEffect (..),
    Projection (..),
    RejectionReason (..),
    StreamEvent (..),
    VersionedStreamEvent,
  )
import Infrastructure.Eventium (embedWith)
import Infrastructure.Observability.Context (propagateContext)
import Optics (at, makeFieldLabelsNoPrefix, (%), (%~), (&), (?~), (^.))

-- -----------------------------------------------------------------------------
-- Transfer Manager State
-- -----------------------------------------------------------------------------

-- | Transfer manager state.
--
-- The process manager maintains a map of active transfers, keyed by transaction ID.
-- For each transfer, it tracks the source and target accounts to coordinate the saga.
data TransactionPostingManager = TransactionPostingManager
  { -- | Map of transaction ID to transfer tracking data
    transfers :: Map TransactionId TransactionPostingData
  }
  deriving (Show)

-- | Phase of a transfer within the saga.
data TransactionPostingPhase
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
data TransactionPostingData = TransactionPostingData
  { -- | Source account (being debited)
    sourceAccount :: AccountId,
    -- | Target account (being credited)
    targetAccount :: AccountId,
    -- | Amount debited from source account
    sourceAmount :: Money,
    -- | Amount credited to target account
    targetAmount :: Money,
    -- | Current phase of the transfer saga
    phase :: TransactionPostingPhase
  }
  deriving (Show, Eq)

-- Generate optics labels for TransactionPostingManager
makeFieldLabelsNoPrefix ''TransactionPostingManager

-- | Initial/default transfer manager state.
transactionPostingManagerDefault :: TransactionPostingManager
transactionPostingManagerDefault = TransactionPostingManager Map.empty

-- -----------------------------------------------------------------------------
-- Transfer Manager Projection (state updates only)
-- -----------------------------------------------------------------------------

-- | Projection for the transfer manager.
--
-- This projection only updates internal state. Command-issuing logic is in
-- 'reactToTransactionPostingEvent'.
transactionPostingManagerProjection :: Projection TransactionPostingManager (VersionedStreamEvent AccountingEvent)
transactionPostingManagerProjection =
  Projection
    transactionPostingManagerDefault
    handleTransactionPostingEvent

-- | Handle an event and update process manager state.
--
-- State updates only — no side effects or command generation.
handleTransactionPostingEvent :: TransactionPostingManager -> VersionedStreamEvent AccountingEvent -> TransactionPostingManager
-- Store transfer data when a new transfer is initiated
handleTransactionPostingEvent manager (StreamEvent txUuid _ _ (TransactionPostingInitiatedEvent evt)) =
  case mkTransactionIdSafe txUuid of
    Nothing -> manager
    Just txId ->
      case manager ^. #transfers % at txId of
        Nothing ->
          -- First time seeing this transfer: track it in AwaitingDebit phase
          manager
            & #transfers
            % at txId
            ?~ TransactionPostingData
              { sourceAccount = evt.sourceAccountId,
                targetAccount = evt.targetAccountId,
                sourceAmount = evt.sourceAmount,
                targetAmount = evt.targetAmount,
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
handleTransactionPostingEvent manager (StreamEvent _ _ _ (AccountCreditedEvent evt)) =
  manager & #transfers %~ Map.delete evt.transactionId
-- All other events: no state change
handleTransactionPostingEvent manager _ = manager

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
--  - TransactionPostingInitiated: Issue DebitAccount to source account
--  - AccountDebited: Issue CreditAccount to target + CompleteTransactionPosting
--  - All others: No reaction
--
-- Note: Debit failure compensation is declared via IssueCommandWithCompensation.
-- The process manager handles its own compensation.
reactToTransactionPostingEvent :: TransactionPostingManager -> VersionedStreamEvent AccountingEvent -> [ProcessManagerEffect AccountingCommand]
-- TransactionPostingInitiated -> Issue DebitAccount to source (with compensation on failure)
reactToTransactionPostingEvent manager (StreamEvent txUuid _ trigMeta (TransactionPostingInitiatedEvent evt)) =
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
                              -- A bank import carries 'importInfo'; such debits
                              -- bypass the balance guard so an already-settled
                              -- bank transaction always posts. Manual transfers
                              -- (no import info) keep the guard.
                              allowOverdraft = isJust evt.importInfo
                            }
                      )
                  )
                  (propagateContext trigMeta)
                  ( \(RejectionReason rejReason) ->
                      [ IssueCommand
                          (unTransactionId txId)
                          ( embedWith
                              transactionCommandEmbedding
                              ( FailTransactionPostingTransactionCommand
                                  FailTransactionPosting {reason = rejReason}
                              )
                          )
                          (propagateContext trigMeta)
                      ]
                  )
              ]
        _ -> [] -- Idempotency: not in AwaitingDebit phase
        -- AccountDebited -> Issue CreditAccount + CompleteTransactionPosting
reactToTransactionPostingEvent manager (StreamEvent _ _ trigMeta (AccountDebitedEvent evt)) =
  case Map.lookup evt.transactionId (manager ^. #transfers) of
    Nothing -> []
    Just td ->
      [ IssueCommand
          (unAccountId td.targetAccount)
          ( embedWith
              accountCommandEmbedding
              ( CreditAccountAccountCommand
                  CreditAccount
                    { amount = td.targetAmount,
                      transactionId = evt.transactionId
                    }
              )
          )
          (propagateContext trigMeta),
        IssueCommand
          (unTransactionId evt.transactionId)
          ( embedWith
              transactionCommandEmbedding
              (CompleteTransactionPostingTransactionCommand CompleteTransactionPosting)
          )
          (propagateContext trigMeta)
      ]
-- All other events: no reaction
reactToTransactionPostingEvent _ _ = []

-- -----------------------------------------------------------------------------
-- Process Manager
-- -----------------------------------------------------------------------------

-- | Type alias for the transfer process manager.
type TransactionPostingProcessManager = ProcessManager TransactionPostingManager AccountingEvent AccountingCommand

-- | The transfer process manager.
--
-- Combines the projection (state tracking) with the react function (command generation).
--
-- Saga Flow:
--
-- Successful Transfer:
-- 1. TransactionPostingInitiated -> Store transfer data, issue DebitAccount to source
-- 2. AccountDebited -> Issue CreditAccount to target, issue CompleteTransactionPosting
-- 3. AccountCredited -> Clean up tracking (saga complete)
--
-- Failed Transfer (Insufficient Funds):
-- 1. TransactionPostingInitiated -> Store transfer data, issue DebitAccount with compensation
-- 2. DebitAccount rejected -> Compensation issues FailTransactionPosting to transaction
transferProcessManager :: TransactionPostingProcessManager
transferProcessManager =
  ProcessManager
    transactionPostingManagerProjection
    reactToTransactionPostingEvent
