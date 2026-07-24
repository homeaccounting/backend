{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ProcessManagers.TransactionMergeManager
-- Description : Process manager (saga) for the atomic single-transaction merge.
--
-- Sibling of 'TransactionAmendmentManager' / 'TransactionCancellationManager'.
-- When a 'TransactionMergeInitiated' event arrives on the target stream, this
-- saga drives the whole merge cascade — which, because Eventium's in-process
-- bus dispatches synchronously and depth-first inside a single write
-- transaction, runs to completion (or fails) before control returns to the
-- service. A failing leg therefore leaves no partial state: there is no
-- durable intermediate to recover.
--
-- Phases:
--
--   1. 'TransactionMergeInitiated' → issue 'InitiateTransactionAmendment' on the target
--      (the pre-resolved payload from the service). Saga state records the
--      target, the resolved amend fields, and the ordered source list.
--   2. 'TransactionAmendmentCompleted' for that target → per source, in order,
--      issue 'AddTransactionRelation' (Merge, source → target) THEN
--      'InitiateTransactionCancellation'. The edge must precede the cancel because
--      'AddTransactionRelation' only accepts a Completed from-aggregate.
--   3. 'TransactionCancellationCompleted' for the LAST source → issue
--      'CompleteTransactionMerge' on the target.
--   4. 'TransactionAmendmentFailed' for the target → issue
--      'FailTransactionMerge' (carrying the amend reason). Every fallible leg
--      is additionally wired with 'IssueCommandWithCompensation' → 'FailTransactionMerge'
--      so any command rejection surfaces cleanly rather than hanging the saga.
--
-- Saga state is a single map keyed by the target 'TransactionId', cleared on
-- 'TransactionMergeCompleted' / 'TransactionMergeFailed'.
module Application.ProcessManagers.TransactionMergeManager
  ( -- * Types
    TransactionMergeManager (..),
    TransactionMergeData (..),
    MergePhase (..),

    -- * Process Manager
    TransactionMergeProcessManager,
    transactionMergeProcessManager,

    -- * Projection
    transactionMergeManagerProjection,

    -- * Internal (exported for testing)
    handleTransactionMergeEvent,
    reactToTransactionMergeEvent,
  )
where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Core.Types
  ( AccountId,
    Allocations,
    ContactId,
    ExchangeRate,
    Money,
    RelationKind (Merge),
    TransactionId,
    TransactionType,
    UserId,
    mkTransactionIdSafe,
    unTransactionId,
  )
import Domain.Models
import Eventium
  ( ProcessManager (..),
    ProcessManagerEffect (..),
    Projection (..),
    RejectionReason (..),
    StreamEvent (..),
    UUID,
    VersionedStreamEvent,
  )
import Infrastructure.Eventium (embedWith)
import Optics (at, makeFieldLabelsNoPrefix, (%), (%~), (&), (?~), (^.))
import RIO hiding ((%~), (&), (.~), (^.))
import RIO.List (find)

-- -----------------------------------------------------------------------------
-- State types
-- -----------------------------------------------------------------------------

-- | Saga lifecycle for an in-flight merge.
--
--   * 'MergeAwaitingAmend' — the target 'InitiateTransactionAmendment' has been issued and
--     we are waiting for 'TransactionAmendmentCompleted' (or …Failed).
--   * 'MergeAwaitingCancellations' — the amend landed; per-source edges +
--     cancels have been issued. The set holds the sources whose
--     'TransactionCancellationCompleted' has not yet arrived; when it empties,
--     'CompleteTransactionMerge' fires.
data MergePhase
  = MergeAwaitingAmend
  | MergeAwaitingCancellations (Set TransactionId)
  deriving (Show, Eq)

-- | Per-merge tracking. Carries the fully-resolved amend payload (so the saga
-- can issue 'InitiateTransactionAmendment' without touching the read model) plus the
-- ordered source list and the saga phase.
data TransactionMergeData = TransactionMergeData
  { -- | The target (survivor) transaction — the stream key of the merge events.
    targetId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newAllocations :: Maybe Allocations,
    newTransactionType :: TransactionType,
    contactId :: Maybe ContactId,
    -- | Ordered source transactions to fold into the target.
    sources :: [TransactionId],
    by :: UserId,
    phase :: MergePhase
  }
  deriving (Show, Eq)

-- | Saga state: the in-flight merge registry keyed by target id.
newtype TransactionMergeManager = TransactionMergeManager
  { merges :: Map TransactionId TransactionMergeData
  }
  deriving (Show)

makeFieldLabelsNoPrefix ''TransactionMergeManager

transactionMergeManagerDefault :: TransactionMergeManager
transactionMergeManagerDefault = TransactionMergeManager Map.empty

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Find the target of the in-flight merge that owns the given source id.
findMergeBySource :: TransactionMergeManager -> TransactionId -> Maybe TransactionId
findMergeBySource manager src =
  fst
    <$> find (\(_, md) -> src `elem` md.sources) (Map.toList (manager ^. #merges))

-- | Drop a source from the remaining-cancellations set of a merge entry.
removeRemaining :: TransactionId -> TransactionMergeData -> TransactionMergeData
removeRemaining src md = case md.phase of
  MergeAwaitingCancellations remaining ->
    md {phase = MergeAwaitingCancellations (Set.delete src remaining)}
  _ -> md

-- -----------------------------------------------------------------------------
-- Projection
-- -----------------------------------------------------------------------------

-- | State updates only — no side effects or command generation.
handleTransactionMergeEvent ::
  TransactionMergeManager ->
  VersionedStreamEvent AccountingEvent ->
  TransactionMergeManager
handleTransactionMergeEvent manager (StreamEvent key _ _ (TransactionMergeInitiatedEvent evt)) =
  case mkTransactionIdSafe key of
    Nothing -> manager
    Just target ->
      manager
        & #merges
        % at target
        ?~ TransactionMergeData
          { targetId = target,
            newSourceAccountId = evt.newSourceAccountId,
            newTargetAccountId = evt.newTargetAccountId,
            newSourceAmount = evt.newSourceAmount,
            newTargetAmount = evt.newTargetAmount,
            newExchangeRate = evt.newExchangeRate,
            newAllocations = evt.newAllocations,
            newTransactionType = evt.newTransactionType,
            contactId = evt.contactId,
            sources = evt.sourceTransactionIds,
            by = evt.by,
            phase = MergeAwaitingAmend
          }
handleTransactionMergeEvent manager (StreamEvent _ _ _ (TransactionAmendmentCompletedEvent evt)) =
  case manager ^. #merges % at evt.transactionId of
    Just md
      | MergeAwaitingAmend <- md.phase ->
          manager
            & #merges
            % at evt.transactionId
            ?~ (md {phase = MergeAwaitingCancellations (Set.fromList md.sources)})
    _ -> manager
handleTransactionMergeEvent manager (StreamEvent _ _ _ (TransactionCancellationCompletedEvent evt)) =
  case findMergeBySource manager evt.transactionId of
    Just target -> manager & #merges % at target %~ fmap (removeRemaining evt.transactionId)
    Nothing -> manager
handleTransactionMergeEvent manager (StreamEvent key _ _ (TransactionMergeCompletedEvent _)) =
  clearByKey key manager
handleTransactionMergeEvent manager (StreamEvent key _ _ (TransactionMergeFailedEvent _)) =
  clearByKey key manager
handleTransactionMergeEvent manager _ = manager

-- | Delete the merge entry keyed by the given stream key (target UUID).
clearByKey :: UUID -> TransactionMergeManager -> TransactionMergeManager
clearByKey key manager = case mkTransactionIdSafe key of
  Just target -> manager & #merges %~ Map.delete target
  Nothing -> manager

-- -----------------------------------------------------------------------------
-- React
-- -----------------------------------------------------------------------------

-- | Issue the target 'InitiateTransactionAmendment' (fully-resolved payload). Wired with
-- compensation so a command-level rejection (a guard bug) fails the merge
-- cleanly; the amend SAGA's own failure surfaces separately as
-- 'TransactionAmendmentFailed'.
amendEffect :: TransactionMergeData -> ProcessManagerEffect AccountingCommand
amendEffect md =
  IssueCommandWithCompensation
    (unTransactionId md.targetId)
    ( embedWith
        transactionCommandEmbedding
        ( InitiateTransactionAmendmentTransactionCommand
            InitiateTransactionAmendment
              { transactionId = md.targetId,
                newSourceAccountId = md.newSourceAccountId,
                newTargetAccountId = md.newTargetAccountId,
                newSourceAmount = md.newSourceAmount,
                newTargetAmount = md.newTargetAmount,
                newExchangeRate = md.newExchangeRate,
                newAllocations = md.newAllocations,
                newTransactionType = md.newTransactionType,
                contactId = md.contactId,
                by = md.by
              }
        )
    )
    id
    (\(RejectionReason r) -> [failEffect md.targetId r])

-- | For one source: record the Merge edge (source → target) then cancel it.
-- Both are wired with compensation → 'FailTransactionMerge'.
sourceEffects :: TransactionId -> UserId -> TransactionId -> [ProcessManagerEffect AccountingCommand]
sourceEffects target by src =
  [ IssueCommandWithCompensation
      (unTransactionId src)
      ( embedWith
          transactionCommandEmbedding
          ( AddTransactionRelationTransactionCommand
              AddTransactionRelation
                { transactionId = src,
                  relatedTransactionId = target,
                  relationKind = Merge
                }
          )
      )
      id
      (\(RejectionReason r) -> [failEffect target r]),
    IssueCommandWithCompensation
      (unTransactionId src)
      ( embedWith
          transactionCommandEmbedding
          ( InitiateTransactionCancellationTransactionCommand
              InitiateTransactionCancellation {transactionId = src, by = by}
          )
      )
      id
      (\(RejectionReason r) -> [failEffect target r])
  ]

-- | Issue 'CompleteTransactionMerge' on the target.
completeEffect :: TransactionMergeData -> ProcessManagerEffect AccountingCommand
completeEffect md =
  IssueCommand
    (unTransactionId md.targetId)
    ( embedWith
        transactionCommandEmbedding
        ( CompleteTransactionMergeTransactionCommand
            CompleteTransactionMerge {by = md.by}
        )
    )
    id

-- | Issue 'FailTransactionMerge' on the target.
failEffect :: TransactionId -> Text -> ProcessManagerEffect AccountingCommand
failEffect target reason =
  IssueCommand
    (unTransactionId target)
    ( embedWith
        transactionCommandEmbedding
        ( FailTransactionMergeTransactionCommand
            FailTransactionMerge {reason = reason}
        )
    )
    id

reactToTransactionMergeEvent ::
  TransactionMergeManager ->
  VersionedStreamEvent AccountingEvent ->
  [ProcessManagerEffect AccountingCommand]
reactToTransactionMergeEvent manager (StreamEvent key _ _ (TransactionMergeInitiatedEvent _)) =
  case mkTransactionIdSafe key of
    Nothing -> []
    Just target -> case manager ^. #merges % at target of
      Just md | MergeAwaitingAmend <- md.phase -> [amendEffect md]
      _ -> []
reactToTransactionMergeEvent manager (StreamEvent _ _ _ (TransactionAmendmentCompletedEvent evt)) =
  case manager ^. #merges % at evt.transactionId of
    Just md
      | MergeAwaitingCancellations _ <- md.phase ->
          -- 'handleTransactionMergeEvent' has just transitioned the phase to
          -- 'MergeAwaitingCancellations'. Issue every source's edge + cancel in
          -- order; the LAST cancellation's completion fires the merge completion.
          concatMap (sourceEffects md.targetId md.by) md.sources
    _ -> []
reactToTransactionMergeEvent manager (StreamEvent _ _ _ (TransactionCancellationCompletedEvent evt)) =
  case findMergeBySource manager evt.transactionId of
    Just target -> case manager ^. #merges % at target of
      Just md
        | MergeAwaitingCancellations remaining <- md.phase,
          Set.null remaining ->
            [completeEffect md]
      _ -> []
    Nothing -> []
reactToTransactionMergeEvent manager (StreamEvent key _ _ (TransactionAmendmentFailedEvent (TransactionAmendmentFailed r))) =
  case mkTransactionIdSafe key of
    Nothing -> []
    Just target -> case manager ^. #merges % at target of
      Just md | MergeAwaitingAmend <- md.phase -> [failEffect md.targetId r]
      _ -> []
reactToTransactionMergeEvent _ _ = []

-- -----------------------------------------------------------------------------
-- Wiring
-- -----------------------------------------------------------------------------

transactionMergeManagerProjection ::
  Projection TransactionMergeManager (VersionedStreamEvent AccountingEvent)
transactionMergeManagerProjection =
  Projection
    transactionMergeManagerDefault
    handleTransactionMergeEvent

type TransactionMergeProcessManager =
  ProcessManager TransactionMergeManager AccountingEvent AccountingCommand

transactionMergeProcessManager :: TransactionMergeProcessManager
transactionMergeProcessManager =
  ProcessManager
    transactionMergeManagerProjection
    reactToTransactionMergeEvent
