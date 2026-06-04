{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ProcessManagers.TransactionAmendmentManager
-- Description : Process manager (saga) for amending completed transfers.
--
-- Sibling of 'TransactionPostingManager'. When a 'TransactionAmendmentInitiated' event
-- arrives, this saga diffs the snapshotted old postings against the new
-- payload (per spec §4.2's table) and issues the minimum set of leg
-- commands in order. The new-source debit is fallible; compensation
-- issues 'FailTransactionAmendment'. Other legs are guaranteed-success.
--
-- Saga state is tracked per-transaction in two maps:
--
--   * @amendments@ — in-flight saga state (set on
--     'TransactionAmendmentInitiated', cleared on
--     'TransactionAmendmentCompleted' / 'TransactionAmendmentFailed').
--
--   * @currentPostings@ — the current canonical posting snapshot used to
--     compute the diff for the next amendment. Updated by
--     'TransactionPostingInitiated' and 'TransactionAmendmentCompleted'.
module Application.ProcessManagers.TransactionAmendmentManager
  ( -- * Types
    TransactionAmendmentManager (..),
    TransactionAmendmentData (..),
    TransferPostings (..),
    FallibleLeg (..),
    NonFallibleLeg (..),
    TransactionAmendmentPhase (..),

    -- * Process Manager
    TransactionAmendmentProcessManager,
    transferAmendmentProcessManager,

    -- * Projection
    transactionAmendmentManagerProjection,

    -- * Internal (exported for testing)
    handleTransactionAmendmentEvent,
    reactToTransactionAmendmentEvent,
    diffAmendmentLegs,
  )
where

import Application.ProcessManagers.Snapshots
  ( TransferPostings (..),
    applyTransactionAmendmentCompleted,
    applyTransactionPostingInitiated,
  )
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Domain.Core.Types
  ( AccountId,
    ExchangeRate,
    Money,
    TransactionId,
    TransactionType,
    UserId,
    moneyIsPositive,
    subtractMoney,
    unAccountId,
    unTransactionId,
  )
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
import Optics (at, makeFieldLabelsNoPrefix, (%), (%~), (&), (?~), (^.))
import RIO hiding ((%~), (&), (.~), (^.))

-- -----------------------------------------------------------------------------
-- Leg effects
-- -----------------------------------------------------------------------------

-- | The single fallible leg of the amendment saga.
--
-- New-source debit: issued on either source amount-up (same account) or
-- source-account swap. Its rejection is compensated by issuing
-- 'FailTransactionAmendment' on the TX stream. Distinct from
-- 'NonFallibleLeg' so the compiler can prove the saga only ever attaches
-- compensation to this leg.
newtype FallibleLeg = DebitNewSource (AccountId, Money, TransactionId)
  deriving (Show, Eq)

-- | A guaranteed-success leg of the amendment saga (reversals plus the
-- new-target credit).
--
-- The saga emits zero or more of these *after* the fallible
-- 'FallibleLeg' lands (or immediately, when no fallible step is needed).
data NonFallibleLeg
  = -- | Reverse a prior credit on the old target. Issued on either
    -- target amount-down (same account) or target-account swap.
    ReverseOldTarget AccountId Money TransactionId UTCTime
  | -- | Reverse a prior debit on the old source. Issued on either
    -- source amount-down (same account) or source-account swap.
    ReverseOldSource AccountId Money TransactionId UTCTime
  | -- | New-target credit. Issued on either target amount-up (same
    -- account) or target-account swap.
    CreditNewTarget AccountId Money TransactionId
  deriving (Show, Eq)

-- | Saga lifecycle for an in-flight amendment.
--
-- The two phases capture exactly the two states the saga reacts from:
--
--   * 'AwaitingDebit' — the diff has a fallible new-source debit that
--     must land before any tail legs are issued. Carries the debit to
--     issue plus the tail legs to issue once the debit succeeds.
--   * 'ReadyToFinalize' — either the debit has landed or no fallible
--     step was needed; the remaining non-fallible legs are ready to be
--     issued together with the saga's completion command.
--
-- The transition 'AwaitingDebit' → 'ReadyToFinalize' happens on the
-- @AccountDebitedEvent@ that matches the saga's @transactionId@. The
-- amendment entry is removed from the saga map entirely when
-- 'TransactionAmendmentCompleted' lands.
data TransactionAmendmentPhase
  = AwaitingDebit FallibleLeg [NonFallibleLeg]
  | ReadyToFinalize [NonFallibleLeg]
  deriving (Show, Eq)

-- | Per-amendment tracking. Captures the saga phase plus the full new
-- payload so the react function can issue the completion command
-- without re-deriving it from snapshots.
--
-- 'newTransactionType' carries the synthesised kind ⊕ allocations value
-- from 'TransactionAmendmentInitiated', echoed onto
-- 'CompleteTransactionAmendment' at finalize.
data TransactionAmendmentData = TransactionAmendmentData
  { -- | The transaction being amended.
    transactionId :: TransactionId,
    -- | Full new payload (echoed onto 'CompleteTransactionAmendment' at saga end).
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    -- | Synthesised full new 'TransactionType' (kind ⊕ allocations).
    newTransactionType :: TransactionType,
    amendedBy :: UserId,
    -- | Snapshot of the @at@ business timestamp used on every reversal leg.
    at :: UTCTime,
    -- | Saga lifecycle state.
    phase :: TransactionAmendmentPhase
  }
  deriving (Show, Eq)

-- | Saga state. Holds both the in-flight amendment registry and the
-- per-transaction current-postings snapshot used to compute future diffs.
data TransactionAmendmentManager = TransactionAmendmentManager
  { amendments :: Map TransactionId TransactionAmendmentData,
    currentPostings :: Map TransactionId TransferPostings
  }
  deriving (Show)

makeFieldLabelsNoPrefix ''TransactionAmendmentManager

transactionAmendmentManagerDefault :: TransactionAmendmentManager
transactionAmendmentManagerDefault = TransactionAmendmentManager Map.empty Map.empty

-- -----------------------------------------------------------------------------
-- Pure diff
-- -----------------------------------------------------------------------------

-- | Compute the minimal leg set for an amendment.
--
-- The return shape encodes fallibility at the type level: the optional
-- 'FallibleLeg' head is the new-source debit (the only step that can be
-- rejected); the tail is the guaranteed-success
-- reverse-credit / reverse-debit / credit legs.
--
-- Decision rules (per spec §4.2):
--
--   * Same source account: amount up → 'DebitNewSource' (Δ); amount
--     down → 'ReverseOldSource' (|Δ|); equal → no source leg.
--   * Source-account swap: 'DebitNewSource' (full new amount) +
--     'ReverseOldSource' (full old amount).
--   * Target side: symmetric with 'CreditNewTarget' / 'ReverseOldTarget'.
--
-- Tail ordering matches spec §4.1: reverse-old-target →
-- reverse-old-source → new-target credit. Slots are skipped when their
-- side has no change.
diffAmendmentLegs ::
  TransferPostings ->
  TransactionAmendmentInitiated ->
  (Maybe FallibleLeg, [NonFallibleLeg])
diffAmendmentLegs old new =
  (sourceDebit, catMaybes [targetReverse, sourceReverse, targetCredit])
  where
    txId = new.transactionId
    oldAt = old.at

    sameSource = old.sourceAccountId == new.newSourceAccountId
    sameTarget = old.targetAccountId == new.newTargetAccountId

    sourceDebit :: Maybe FallibleLeg
    sourceDebit
      | not sameSource =
          Just (DebitNewSource (new.newSourceAccountId, new.newSourceAmount, txId))
      | otherwise =
          case subtractMoney new.newSourceAmount old.sourceAmount of
            Right delta
              | moneyIsPositive delta ->
                  Just (DebitNewSource (old.sourceAccountId, delta, txId))
            _ -> Nothing

    sourceReverse :: Maybe NonFallibleLeg
    sourceReverse
      | not sameSource =
          Just (ReverseOldSource old.sourceAccountId old.sourceAmount txId oldAt)
      | otherwise =
          case subtractMoney old.sourceAmount new.newSourceAmount of
            Right delta
              | moneyIsPositive delta ->
                  Just (ReverseOldSource old.sourceAccountId delta txId oldAt)
            _ -> Nothing

    targetCredit :: Maybe NonFallibleLeg
    targetCredit
      | not sameTarget =
          Just (CreditNewTarget new.newTargetAccountId new.newTargetAmount txId)
      | otherwise =
          case subtractMoney new.newTargetAmount old.targetAmount of
            Right delta
              | moneyIsPositive delta ->
                  Just (CreditNewTarget old.targetAccountId delta txId)
            _ -> Nothing

    targetReverse :: Maybe NonFallibleLeg
    targetReverse
      | not sameTarget =
          Just (ReverseOldTarget old.targetAccountId old.targetAmount txId oldAt)
      | otherwise =
          case subtractMoney old.targetAmount new.newTargetAmount of
            Right delta
              | moneyIsPositive delta ->
                  Just (ReverseOldTarget old.targetAccountId delta txId oldAt)
            _ -> Nothing

-- | Build the initial saga phase from a diff result.
initialPhase :: Maybe FallibleLeg -> [NonFallibleLeg] -> TransactionAmendmentPhase
initialPhase (Just debit) rest = AwaitingDebit debit rest
initialPhase Nothing rest = ReadyToFinalize rest

-- -----------------------------------------------------------------------------
-- Projection
-- -----------------------------------------------------------------------------

-- | State updates only — no side effects or command generation.
handleTransactionAmendmentEvent ::
  TransactionAmendmentManager ->
  VersionedStreamEvent AccountingEvent ->
  TransactionAmendmentManager
handleTransactionAmendmentEvent manager e@(StreamEvent _ _ _ (TransactionPostingInitiatedEvent _)) =
  manager & #currentPostings %~ applyTransactionPostingInitiated e
handleTransactionAmendmentEvent manager (StreamEvent _ _ _ (TransactionAmendmentInitiatedEvent evt)) =
  case manager ^. #currentPostings % at evt.transactionId of
    Nothing -> manager
    Just postings ->
      let (mDebit, rest) = diffAmendmentLegs postings evt
       in manager
            & #amendments
            % at evt.transactionId
            ?~ TransactionAmendmentData
              { transactionId = evt.transactionId,
                newSourceAccountId = evt.newSourceAccountId,
                newTargetAccountId = evt.newTargetAccountId,
                newSourceAmount = evt.newSourceAmount,
                newTargetAmount = evt.newTargetAmount,
                newExchangeRate = evt.newExchangeRate,
                newTransactionType = evt.newTransactionType,
                amendedBy = evt.amendedBy,
                at = postings.at,
                phase = initialPhase mDebit rest
              }
handleTransactionAmendmentEvent manager (StreamEvent _ _ _ (AccountDebitedEvent evt)) =
  case manager ^. #amendments % at evt.transactionId of
    Just amend
      | AwaitingDebit _ rest <- amend.phase ->
          manager
            & #amendments
            % at evt.transactionId
            ?~ (amend {phase = ReadyToFinalize rest} :: TransactionAmendmentData)
    _ -> manager
handleTransactionAmendmentEvent manager (StreamEvent _ _ _ (TransactionAmendmentCompletedEvent evt)) =
  manager
    & #amendments
    %~ Map.delete evt.transactionId
    & #currentPostings
    %~ applyTransactionAmendmentCompleted evt
handleTransactionAmendmentEvent manager (StreamEvent _ _ _ (TransactionAmendmentFailedEvent _)) =
  -- The aggregate id is not in the event payload; the saga clears its
  -- entry when the react function runs (no per-tx context here). In
  -- practice 'TransactionAmendmentFailed' is emitted via the compensation
  -- callback inside the same react cycle, so the @amendments@ entry is
  -- short-lived. We conservatively leave it intact here; the next
  -- successful saga overwrites it.
  manager
handleTransactionAmendmentEvent manager _ = manager

-- -----------------------------------------------------------------------------
-- React
-- -----------------------------------------------------------------------------

-- | Translate the fallible new-source debit into the effect that
-- issues it with compensation. The type guarantees this is the only
-- leg ever wired to 'IssueCommandWithCompensation'.
fallibleLegToEffect :: FallibleLeg -> ProcessManagerEffect AccountingCommand
fallibleLegToEffect (DebitNewSource (acct, amt, txId)) =
  IssueCommandWithCompensation
    (unAccountId acct)
    ( embedWith
        accountCommandEmbedding
        ( DebitAccountAccountCommand
            DebitAccount {amount = amt, transactionId = txId}
        )
    )
    id
    ( \(RejectionReason rejReason) ->
        [ IssueCommand
            (unTransactionId txId)
            ( embedWith
                transactionCommandEmbedding
                ( FailTransactionAmendmentTransactionCommand
                    FailTransactionAmendment {reason = rejReason}
                )
            )
            id
        ]
    )

-- | Translate a guaranteed-success leg into its 'IssueCommand' effect.
nonFallibleLegToEffect :: NonFallibleLeg -> ProcessManagerEffect AccountingCommand
nonFallibleLegToEffect (ReverseOldTarget acct amt txId t) =
  IssueCommand
    (unAccountId acct)
    ( embedWith
        accountCommandEmbedding
        ( ReverseAccountCreditAccountCommand
            ReverseAccountCredit {amount = amt, transactionId = txId, at = t}
        )
    )
    id
nonFallibleLegToEffect (ReverseOldSource acct amt txId t) =
  IssueCommand
    (unAccountId acct)
    ( embedWith
        accountCommandEmbedding
        ( ReverseAccountDebitAccountCommand
            ReverseAccountDebit {amount = amt, transactionId = txId, at = t}
        )
    )
    id
nonFallibleLegToEffect (CreditNewTarget acct amt txId) =
  IssueCommand
    (unAccountId acct)
    ( embedWith
        accountCommandEmbedding
        ( CreditAccountAccountCommand
            CreditAccount {amount = amt, transactionId = txId}
        )
    )
    id

-- | Build the 'CompleteTransactionAmendment' effect from the stored amendment data.
completeEffect :: TransactionAmendmentData -> ProcessManagerEffect AccountingCommand
completeEffect amend =
  IssueCommand
    (unTransactionId amend.transactionId)
    ( embedWith
        transactionCommandEmbedding
        ( CompleteTransactionAmendmentTransactionCommand
            CompleteTransactionAmendment
              { transactionId = amend.transactionId,
                newSourceAccountId = amend.newSourceAccountId,
                newTargetAccountId = amend.newTargetAccountId,
                newSourceAmount = amend.newSourceAmount,
                newTargetAmount = amend.newTargetAmount,
                newExchangeRate = amend.newExchangeRate,
                newTransactionType = amend.newTransactionType,
                amendedBy = amend.amendedBy
              }
        )
    )
    id

reactToTransactionAmendmentEvent ::
  TransactionAmendmentManager ->
  VersionedStreamEvent AccountingEvent ->
  [ProcessManagerEffect AccountingCommand]
reactToTransactionAmendmentEvent manager (StreamEvent _ _ _ (TransactionAmendmentInitiatedEvent evt)) =
  case manager ^. #amendments % at evt.transactionId of
    Nothing -> []
    Just amend -> case amend.phase of
      AwaitingDebit debit _ ->
        -- Fallible debit first. Tail legs + completion fire on the
        -- resulting AccountDebited event.
        [fallibleLegToEffect debit]
      ReadyToFinalize legs ->
        -- No fallible step needed. Issue everything (including the
        -- completion command) immediately. The amendments-map entry is
        -- cleared by the resulting 'TransactionAmendmentCompleted' event,
        -- so replays of the same Initiated event won't re-emit.
        (nonFallibleLegToEffect <$> legs) ++ [completeEffect amend]
reactToTransactionAmendmentEvent manager (StreamEvent _ _ _ (AccountDebitedEvent evt)) =
  case manager ^. #amendments % at evt.transactionId of
    Just amend
      | ReadyToFinalize legs <- amend.phase ->
          -- 'handleTransactionAmendmentEvent' has just transitioned the saga
          -- from 'AwaitingDebit' to 'ReadyToFinalize'. Idempotency on later
          -- AccountDebited replays is enforced by the
          -- 'TransactionAmendmentCompleted' event clearing the amendments-map
          -- entry below.
          (nonFallibleLegToEffect <$> legs) ++ [completeEffect amend]
    _ -> []
reactToTransactionAmendmentEvent _ _ = []

-- -----------------------------------------------------------------------------
-- Wiring
-- -----------------------------------------------------------------------------

transactionAmendmentManagerProjection ::
  Projection TransactionAmendmentManager (VersionedStreamEvent AccountingEvent)
transactionAmendmentManagerProjection =
  Projection
    transactionAmendmentManagerDefault
    handleTransactionAmendmentEvent

type TransactionAmendmentProcessManager =
  ProcessManager TransactionAmendmentManager AccountingEvent AccountingCommand

transferAmendmentProcessManager :: TransactionAmendmentProcessManager
transferAmendmentProcessManager =
  ProcessManager
    transactionAmendmentManagerProjection
    reactToTransactionAmendmentEvent
