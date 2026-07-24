{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionMergeManagerSpec
-- Description : Unit tests for the TransactionMergeManager saga.
--
-- Covers the phase machine:
--
--   * 'TransactionMergeInitiated' → issue 'AmendTransaction' on the target
--     (with compensation → 'FailTransactionMerge').
--   * 'TransactionAmendmentCompleted' for the target → per source, in order,
--     'AddTransactionRelation' (Merge) then 'CancelTransaction'.
--   * The LAST 'TransactionCancellationCompleted' → 'CompleteTransactionMerge';
--     earlier ones issue nothing.
--   * 'TransactionAmendmentFailed' for the target → 'FailTransactionMerge'.
--   * A self-rejecting guard would break the amend leg: the amend is issued
--     with compensation whose failure path emits 'FailTransactionMerge'.
module Application.ProcessManagers.TransactionMergeManagerSpec (spec) where

import Application.ProcessManagers.TransactionMergeManager
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Money,
    RelationKind (..),
    TransactionId,
    TransactionType (..),
    UserId,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Models
  ( AccountingCommand (..),
    AccountingEvent (..),
  )
import Domain.Transaction.Commands
  ( AddTransactionRelation (..),
    AmendTransaction (..),
    CancelTransaction (..),
    CompleteTransactionMerge (..),
    FailTransactionMerge (..),
  )
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionAmendmentFailed (..),
    TransactionCancellationCompleted (..),
    TransactionMergeCompleted (..),
    TransactionMergeInitiated (..),
  )
import Eventium (ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

empty_ :: TransactionMergeManager
empty_ = TransactionMergeManager Map.empty

targetUuid, s1Uuid, s2Uuid :: UUID.UUID
targetUuid = UUID.fromWords 1 0 0 1
s1Uuid = UUID.fromWords 2 0 0 1
s2Uuid = UUID.fromWords 3 0 0 1

targetId, s1Id, s2Id :: TransactionId
targetId = unsafeTransactionId targetUuid
s1Id = unsafeTransactionId s1Uuid
s2Id = unsafeTransactionId s2Uuid

srcUuid, tgtUuid :: UUID.UUID
srcUuid = UUID.fromWords 10 0 0 1
tgtUuid = UUID.fromWords 20 0 0 1

src, tgt :: AccountId
src = unsafeAccountId srcUuid
tgt = unsafeAccountId tgtUuid

userId_ :: UserId
userId_ = unsafeUserId (UUID.fromWords 4 0 0 4)

m :: Rational -> Money
m = unsafeMoney Core.USD

-- | 'TransactionMergeInitiated' event on the target stream, folding the given
-- sources; the resolved amend payload posts 65 USD source/target.
mkMergeInitiated :: [TransactionId] -> VersionedStreamEvent AccountingEvent
mkMergeInitiated sources =
  StreamEvent
    targetUuid
    1
    (emptyMetadata "")
    ( TransactionMergeInitiatedEvent
        TransactionMergeInitiated
          { newSourceAccountId = src,
            newTargetAccountId = tgt,
            newSourceAmount = m 65,
            newTargetAmount = m 65,
            newExchangeRate = Nothing,
            newAllocations = Nothing,
            newTransactionType = Transfer,
            contactId = Nothing,
            sourceTransactionIds = sources,
            by = userId_
          }
    )

-- | 'TransactionAmendmentCompleted' event for the target.
mkAmendmentCompleted :: VersionedStreamEvent AccountingEvent
mkAmendmentCompleted =
  StreamEvent
    targetUuid
    2
    (emptyMetadata "")
    ( TransactionAmendmentCompletedEvent
        TransactionAmendmentCompleted
          { transactionId = targetId,
            newSourceAccountId = src,
            newTargetAccountId = tgt,
            newSourceAmount = m 65,
            newTargetAmount = m 65,
            newExchangeRate = Nothing,
            newTransactionType = Transfer,
            contactId = Nothing,
            by = userId_
          }
    )

-- | 'TransactionAmendmentFailed' event on the target stream.
mkAmendmentFailed :: Text -> VersionedStreamEvent AccountingEvent
mkAmendmentFailed reason =
  StreamEvent
    targetUuid
    2
    (emptyMetadata "")
    (TransactionAmendmentFailedEvent (TransactionAmendmentFailed reason))

-- | 'TransactionCancellationCompleted' event for a source.
mkCancellationCompleted :: UUID.UUID -> TransactionId -> VersionedStreamEvent AccountingEvent
mkCancellationCompleted sUuid sId =
  StreamEvent
    sUuid
    3
    (emptyMetadata "")
    ( TransactionCancellationCompletedEvent
        TransactionCancellationCompleted {transactionId = sId, by = userId_}
    )

runProjection :: [VersionedStreamEvent AccountingEvent] -> TransactionMergeManager
runProjection = foldl' handleTransactionMergeEvent empty_

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionMergeManager (Saga)" $ do
  describe "initial state"
    $ it "starts with an empty merge registry"
    $ Map.null (empty_ ^. #merges)
    `shouldBe` True

  describe "TransactionMergeInitiated" $ do
    it "records a merge entry in the MergeAwaitingAmend phase" $ do
      let st = runProjection [mkMergeInitiated [s1Id]]
      case Map.lookup targetId (st ^. #merges) of
        Nothing -> expectationFailure "expected a merge entry for the target"
        Just md -> do
          md.targetId `shouldBe` targetId
          md.sources `shouldBe` [s1Id]
          md.phase `shouldBe` MergeAwaitingAmend

    it "issues AmendTransaction on the target (with compensation)" $ do
      let ev = mkMergeInitiated [s1Id]
          st = runProjection [ev]
          effects = reactToTransactionMergeEvent st ev
      case effects of
        [IssueCommandWithCompensation target (AmendTransactionCommand amend) _ _] -> do
          target `shouldBe` targetUuid
          amend.transactionId `shouldBe` targetId
          amend.newSourceAmount `shouldBe` m 65
          amend.newTargetAmount `shouldBe` m 65
        _ -> expectationFailure "expected a single AmendTransaction (with compensation)"

    it "compensation on the amend rejection issues FailTransactionMerge" $ do
      let ev = mkMergeInitiated [s1Id]
          st = runProjection [ev]
          effects = reactToTransactionMergeEvent st ev
      case effects of
        [IssueCommandWithCompensation _ _ _ onFail] ->
          case onFail (RejectionReason "boom") of
            [IssueCommand target (FailTransactionMergeCommand (FailTransactionMerge r)) _] -> do
              target `shouldBe` targetUuid
              r `shouldBe` "boom"
            _ -> expectationFailure "expected one FailTransactionMerge effect"
        _ -> expectationFailure "expected IssueCommandWithCompensation"

  describe "TransactionAmendmentCompleted (target)" $ do
    it "transitions to MergeAwaitingCancellations over all sources" $ do
      let st = runProjection [mkMergeInitiated [s1Id, s2Id], mkAmendmentCompleted]
      case Map.lookup targetId (st ^. #merges) of
        Just md -> md.phase `shouldBe` MergeAwaitingCancellations (Set.fromList [s1Id, s2Id])
        Nothing -> expectationFailure "expected a merge entry"

    it "issues per-source AddTransactionRelation(Merge) then CancelTransaction, in order" $ do
      let st = runProjection [mkMergeInitiated [s1Id, s2Id], mkAmendmentCompleted]
          effects = reactToTransactionMergeEvent st mkAmendmentCompleted
      length effects `shouldBe` 4
      case effects of
        [ IssueCommandWithCompensation e1 (AddTransactionRelationCommand edge1) _ _,
          IssueCommandWithCompensation c1 (CancelTransactionCommand cancel1) _ _,
          IssueCommandWithCompensation e2 (AddTransactionRelationCommand edge2) _ _,
          IssueCommandWithCompensation c2 (CancelTransactionCommand cancel2) _ _
          ] -> do
            e1 `shouldBe` s1Uuid
            edge1.transactionId `shouldBe` s1Id
            edge1.relatedTransactionId `shouldBe` targetId
            edge1.relationKind `shouldBe` Merge
            c1 `shouldBe` s1Uuid
            cancel1.transactionId `shouldBe` s1Id
            e2 `shouldBe` s2Uuid
            edge2.transactionId `shouldBe` s2Id
            cancel2.transactionId `shouldBe` s2Id
            (c2, edge2.relationKind) `shouldBe` (s2Uuid, Merge)
        _ -> expectationFailure "expected [edge s1, cancel s1, edge s2, cancel s2]"

  describe "TransactionCancellationCompleted" $ do
    it "issues nothing while sources remain, then CompleteTransactionMerge on the last" $ do
      let st0 = runProjection [mkMergeInitiated [s1Id, s2Id], mkAmendmentCompleted]
          cc1 = mkCancellationCompleted s1Uuid s1Id
          cc2 = mkCancellationCompleted s2Uuid s2Id
          st1 = handleTransactionMergeEvent st0 cc1
          effects1 = reactToTransactionMergeEvent st1 cc1
          st2 = handleTransactionMergeEvent st1 cc2
          effects2 = reactToTransactionMergeEvent st2 cc2
      effects1 `shouldBe` []
      length effects2 `shouldBe` 1
      case effects2 of
        [IssueCommand target (CompleteTransactionMergeCommand complete) _] -> do
          target `shouldBe` targetUuid
          complete.by `shouldBe` userId_
        _ -> expectationFailure "expected one CompleteTransactionMerge effect"

    it "deletes the merge entry once completed" $ do
      let st =
            runProjection
              [ mkMergeInitiated [s1Id],
                mkAmendmentCompleted,
                mkCancellationCompleted s1Uuid s1Id,
                StreamEvent targetUuid 4 (emptyMetadata "") (TransactionMergeCompletedEvent (TransactionMergeCompleted {by = userId_}))
              ]
      Map.member targetId (st ^. #merges) `shouldBe` False

  describe "TransactionAmendmentFailed (target)" $ do
    it "issues FailTransactionMerge carrying the amend reason" $ do
      let ev = mkAmendmentFailed "Insufficient funds"
          st = runProjection [mkMergeInitiated [s1Id], ev]
          effects = reactToTransactionMergeEvent st ev
      case effects of
        [IssueCommand target (FailTransactionMergeCommand (FailTransactionMerge r)) _] -> do
          target `shouldBe` targetUuid
          r `shouldBe` "Insufficient funds"
        _ -> expectationFailure "expected one FailTransactionMerge effect"
