{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionCancellationManagerSpec
-- Description : Unit tests for the TransactionCancellationManager saga.
--
-- Covers each row of spec §4.2-§4.4:
--
--   * 'TransactionPostingInitiatedEvent' populates 'currentPostings'
--   * 'TransactionAmendmentCompletedEvent' updates the snapshot so a
--     subsequent cancellation reverses the amended amounts
--   * 'TransactionCancellationInitiatedEvent' emits exactly two reversal
--     commands with the snapshot's amounts and @at@
--   * Either reversal order (Debit then Credit, Credit then Debit) toggles
--     the corresponding flag; only the second reversal triggers
--     'CompleteTransactionCancellation'
--   * 'TransactionCancellationCompletedEvent' deletes both
--     @cancellations@ and @currentPostings@ entries
--   * Replay of 'AccountDebitReversedEvent' after 'Completed' is a no-op
--   * Initiated for an unknown transactionId does nothing
--   * Cancellations on different transactionIds do not interfere
module Application.ProcessManagers.TransactionCancellationManagerSpec (spec) where

import Application.ProcessManagers.TransactionCancellationManager
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Account.Commands
  ( ReverseAccountCredit (..),
    ReverseAccountDebit (..),
  )
import Domain.Account.Events
  ( AccountCreditReversed (..),
    AccountDebitReversed (..),
  )
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    unAccountId,
    unTransactionId,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Models
  ( AccountingCommand (..),
    AccountingEvent (..),
  )
import Domain.Transaction.Commands (CompleteTransactionCancellation (..))
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionCancellationCompleted (..),
    TransactionCancellationInitiated (..),
    TransactionPostingInitiated (..),
  )
import Eventium (ProcessManagerEffect (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

empty_ :: TransactionCancellationManager
empty_ = TransactionCancellationManager Map.empty Map.empty

sampleAt :: UTCTime
sampleAt = UTCTime (fromGregorian 2026 4 1) 0

txUuid :: UUID.UUID
txUuid = UUID.fromWords 1 0 0 1

txId :: TransactionId
txId = unsafeTransactionId txUuid

tx2Uuid :: UUID.UUID
tx2Uuid = UUID.fromWords 1 0 0 2

tx2Id :: TransactionId
tx2Id = unsafeTransactionId tx2Uuid

srcUuid, tgtUuid :: UUID.UUID
srcUuid = UUID.fromWords 10 0 0 1
tgtUuid = UUID.fromWords 20 0 0 1

src, tgt :: AccountId
src = unsafeAccountId srcUuid
tgt = unsafeAccountId tgtUuid

userId_ :: UserId
userId_ = unsafeUserId (UUID.fromWords 4 0 0 4)

m :: Rational -> Money
m = unsafeMoney USD

-- | Unwrap AccountId to its raw UUID.
acctUuid :: AccountId -> UUID.UUID
acctUuid = unAccountId

-- | 'TransactionPostingInitiated' seed event for a 100 USD transfer from 'src' to 'tgt'.
seedInitiated :: VersionedStreamEvent AccountingEvent
seedInitiated =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransactionPostingInitiatedEvent
        TransactionPostingInitiated
          { sourceAccountId = src,
            targetAccountId = tgt,
            sourceAmount = m 100,
            targetAmount = m 100,
            exchangeRate = Nothing,
            description = "seed",
            by = userId_,
            at = sampleAt,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          }
    )

-- | 'TransactionCancellationInitiated' event for 'txId'.
mkCancellationInitiated :: VersionedStreamEvent AccountingEvent
mkCancellationInitiated =
  StreamEvent
    txUuid
    1
    (emptyMetadata "")
    ( TransactionCancellationInitiatedEvent
        TransactionCancellationInitiated
          { transactionId = txId,
            by = userId_
          }
    )

-- | 'AccountDebitReversed' event correlated to 'txId'.
mkDebitReversed :: VersionedStreamEvent AccountingEvent
mkDebitReversed =
  StreamEvent
    srcUuid
    1
    (emptyMetadata "")
    ( AccountDebitReversedEvent
        AccountDebitReversed
          { amount = m 100,
            transactionId = txId,
            at = sampleAt
          }
    )

-- | 'AccountCreditReversed' event correlated to 'txId'.
mkCreditReversed :: VersionedStreamEvent AccountingEvent
mkCreditReversed =
  StreamEvent
    tgtUuid
    1
    (emptyMetadata "")
    ( AccountCreditReversedEvent
        AccountCreditReversed
          { amount = m 100,
            transactionId = txId,
            at = sampleAt
          }
    )

-- | 'TransactionCancellationCompleted' event for 'txId'.
mkCancellationCompleted :: VersionedStreamEvent AccountingEvent
mkCancellationCompleted =
  StreamEvent
    txUuid
    2
    (emptyMetadata "")
    ( TransactionCancellationCompletedEvent
        TransactionCancellationCompleted
          { transactionId = txId,
            by = userId_
          }
    )

-- | Run the projection through the given events from the empty state.
runProjection :: [VersionedStreamEvent AccountingEvent] -> TransactionCancellationManager
runProjection = foldl' handleTransactionCancellationEvent empty_

spec :: Spec
spec = describe "TransactionCancellationManager (Saga)" $ do
  describe "initial state"
    $ it "starts with empty maps"
    $ do
      Map.null (empty_ ^. #cancellations) `shouldBe` True
      Map.null (empty_ ^. #currentPostings) `shouldBe` True

  -- Test case 1: TransactionPostingInitiatedEvent populates currentPostings
  describe "TransactionPostingInitiated tracking"
    $ it "records the current postings snapshot"
    $ do
      let st = runProjection [seedInitiated]
      Map.size (st ^. #currentPostings) `shouldBe` 1
      case Map.lookup txId (st ^. #currentPostings) of
        Nothing -> expectationFailure "Expected currentPostings entry for txId"
        Just p -> do
          p.sourceAccountId `shouldBe` src
          p.targetAccountId `shouldBe` tgt
          p.sourceAmount `shouldBe` m 100
          p.targetAmount `shouldBe` m 100
          p.at `shouldBe` sampleAt

  -- Test case 2: TransactionAmendmentCompletedEvent updates the snapshot
  describe "TransactionAmendmentCompleted snapshot update" $ do
    let amendedSrcUuid = UUID.fromWords 11 0 0 1
        amendedTgtUuid = UUID.fromWords 21 0 0 1
        amendedSrc = unsafeAccountId amendedSrcUuid
        amendedTgt = unsafeAccountId amendedTgtUuid
        amendCompleted =
          StreamEvent
            txUuid
            1
            (emptyMetadata "")
            ( TransactionAmendmentCompletedEvent
                TransactionAmendmentCompleted
                  { transactionId = txId,
                    newSourceAccountId = amendedSrc,
                    newTargetAccountId = amendedTgt,
                    newSourceAmount = m 150,
                    newTargetAmount = m 140,
                    newExchangeRate = Nothing,
                    newTransactionType = Transfer,
                    contactId = Nothing,
                    by = userId_
                  }
            )

    it "updates source/target accounts and amounts, preserves at" $ do
      let st = runProjection [seedInitiated, amendCompleted]
      case Map.lookup txId (st ^. #currentPostings) of
        Nothing -> expectationFailure "Expected currentPostings entry after amendment"
        Just p -> do
          p.sourceAccountId `shouldBe` amendedSrc
          p.targetAccountId `shouldBe` amendedTgt
          p.sourceAmount `shouldBe` m 150
          p.targetAmount `shouldBe` m 140
          p.at `shouldBe` sampleAt -- original at preserved
    it "subsequent cancellation uses the amended amounts" $ do
      let st = runProjection [seedInitiated, amendCompleted, mkCancellationInitiated]
          effects = reactToTransactionCancellationEvent st mkCancellationInitiated
      length effects `shouldBe` 2
      case effects of
        [ IssueCommand _ (ReverseAccountDebitCommand rd) _,
          IssueCommand _ (ReverseAccountCreditCommand rc) _
          ] -> do
            rd.amount `shouldBe` m 150 -- amended source amount
            rc.amount `shouldBe` m 140 -- amended target amount
        _ -> expectationFailure "Expected [ReverseDebit, ReverseCredit] with amended amounts"

  -- Test case 3: TransactionCancellationInitiatedEvent creates saga entry and emits two commands
  describe "TransactionCancellationInitiated" $ do
    it "creates a cancellations entry with both flags False and the by field" $ do
      let st = runProjection [seedInitiated, mkCancellationInitiated]
      case Map.lookup txId (st ^. #cancellations) of
        Nothing -> expectationFailure "Expected cancellations entry"
        Just c -> do
          c.transactionId `shouldBe` txId
          c.by `shouldBe` userId_
          c.sourceReversed `shouldBe` False
          c.targetReversed `shouldBe` False

    it "emits ReverseAccountDebit on source and ReverseAccountCredit on target" $ do
      let st = runProjection [seedInitiated, mkCancellationInitiated]
          effects = reactToTransactionCancellationEvent st mkCancellationInitiated
      length effects `shouldBe` 2
      case effects of
        [ IssueCommand srcTarget (ReverseAccountDebitCommand rd) _,
          IssueCommand tgtTarget (ReverseAccountCreditCommand rc) _
          ] -> do
            srcTarget `shouldBe` acctUuid src
            rd.amount `shouldBe` m 100
            rd.transactionId `shouldBe` txId
            rd.at `shouldBe` sampleAt
            tgtTarget `shouldBe` acctUuid tgt
            rc.amount `shouldBe` m 100
            rc.transactionId `shouldBe` txId
            rc.at `shouldBe` sampleAt
        _ -> expectationFailure "Expected [ReverseAccountDebit, ReverseAccountCredit]"

  -- Test case 4: AccountDebitReversedEvent sets sourceReversed = True
  describe "AccountDebitReversed handling" $ do
    it "sets sourceReversed = True, emits no command while targetReversed = False" $ do
      let st0 = runProjection [seedInitiated, mkCancellationInitiated]
          st1 = handleTransactionCancellationEvent st0 mkDebitReversed
          effects = reactToTransactionCancellationEvent st1 mkDebitReversed
      case Map.lookup txId (st1 ^. #cancellations) of
        Nothing -> expectationFailure "Expected cancellations entry"
        Just c -> do
          c.sourceReversed `shouldBe` True
          c.targetReversed `shouldBe` False
      effects `shouldBe` []

  -- Test case 5: AccountCreditReversedEvent with both flags True triggers CompleteTransactionCancellation
  describe "AccountCreditReversed handling (debit then credit order)" $ do
    it "sets targetReversed = True; both flags True emits CompleteTransactionCancellation" $ do
      let st0 = runProjection [seedInitiated, mkCancellationInitiated]
          st1 = handleTransactionCancellationEvent st0 mkDebitReversed
          st2 = handleTransactionCancellationEvent st1 mkCreditReversed
          effects = reactToTransactionCancellationEvent st2 mkCreditReversed
      case Map.lookup txId (st2 ^. #cancellations) of
        Nothing -> expectationFailure "Expected cancellations entry"
        Just c -> do
          c.sourceReversed `shouldBe` True
          c.targetReversed `shouldBe` True
      length effects `shouldBe` 1
      case effects of
        [IssueCommand txTarget (CompleteTransactionCancellationCommand complete) _] -> do
          txTarget `shouldBe` unTransactionId txId
          complete.transactionId `shouldBe` txId
          complete.by `shouldBe` userId_
        _ -> expectationFailure "Expected one CompleteTransactionCancellation effect"

  -- Test case 6: Reversal order independence
  describe "Reversal order independence" $ do
    it "credit then debit: first reversal (credit) emits no command" $ do
      let st0 = runProjection [seedInitiated, mkCancellationInitiated]
          st1 = handleTransactionCancellationEvent st0 mkCreditReversed
          effects1 = reactToTransactionCancellationEvent st1 mkCreditReversed
      effects1 `shouldBe` []
      case Map.lookup txId (st1 ^. #cancellations) of
        Nothing -> expectationFailure "Expected cancellations entry"
        Just c -> do
          c.sourceReversed `shouldBe` False
          c.targetReversed `shouldBe` True

    it "credit then debit: second reversal (debit) emits CompleteTransactionCancellation" $ do
      let st0 = runProjection [seedInitiated, mkCancellationInitiated]
          st1 = handleTransactionCancellationEvent st0 mkCreditReversed
          st2 = handleTransactionCancellationEvent st1 mkDebitReversed
          effects2 = reactToTransactionCancellationEvent st2 mkDebitReversed
      length effects2 `shouldBe` 1
      case effects2 of
        [IssueCommand txTarget (CompleteTransactionCancellationCommand complete) _] -> do
          txTarget `shouldBe` unTransactionId txId
          complete.transactionId `shouldBe` txId
          complete.by `shouldBe` userId_
        _ -> expectationFailure "Expected CompleteTransactionCancellation on second reversal"

    it "debit then credit: only the second reversal emits the completion command" $ do
      let st0 = runProjection [seedInitiated, mkCancellationInitiated]
          st1 = handleTransactionCancellationEvent st0 mkDebitReversed
          effects1 = reactToTransactionCancellationEvent st1 mkDebitReversed
          st2 = handleTransactionCancellationEvent st1 mkCreditReversed
          effects2 = reactToTransactionCancellationEvent st2 mkCreditReversed
      effects1 `shouldBe` []
      length effects2 `shouldBe` 1

  -- Test case 7: TransactionCancellationCompletedEvent deletes both entries
  describe "TransactionCancellationCompleted cleanup" $ do
    it "deletes both cancellations and currentPostings entries" $ do
      let st =
            runProjection
              [ seedInitiated,
                mkCancellationInitiated,
                mkDebitReversed,
                mkCreditReversed,
                mkCancellationCompleted
              ]
      Map.member txId (st ^. #cancellations) `shouldBe` False
      Map.member txId (st ^. #currentPostings) `shouldBe` False

    it "replay of AccountDebitReversed after Completed produces no command" $ do
      let st =
            runProjection
              [ seedInitiated,
                mkCancellationInitiated,
                mkDebitReversed,
                mkCreditReversed,
                mkCancellationCompleted
              ]
          -- After Completed the cancellation entry is gone
          st' = handleTransactionCancellationEvent st mkDebitReversed
          effects = reactToTransactionCancellationEvent st' mkDebitReversed
      effects `shouldBe` []

  -- Test case 8: Unknown transaction is ignored
  describe "TransactionCancellationInitiated for unknown transaction" $ do
    it "does nothing when currentPostings has no entry for the transactionId" $ do
      -- empty_ has no currentPostings entry
      let unknownEvent =
            StreamEvent
              txUuid
              0
              (emptyMetadata "")
              ( TransactionCancellationInitiatedEvent
                  TransactionCancellationInitiated
                    { transactionId = txId,
                      by = userId_
                    }
              )
          st = handleTransactionCancellationEvent empty_ unknownEvent
          effects = reactToTransactionCancellationEvent st unknownEvent
      Map.null (st ^. #cancellations) `shouldBe` True
      effects `shouldBe` []

  -- Test case 9: Two concurrent cancellations on different transactionIds
  describe "Independence of cancellations on different transactionIds" $ do
    let src2Uuid = UUID.fromWords 30 0 0 1
        tgt2Uuid = UUID.fromWords 40 0 0 1
        src2 = unsafeAccountId src2Uuid
        tgt2 = unsafeAccountId tgt2Uuid
        seedInitiated2 =
          StreamEvent
            tx2Uuid
            0
            (emptyMetadata "")
            ( TransactionPostingInitiatedEvent
                TransactionPostingInitiated
                  { sourceAccountId = src2,
                    targetAccountId = tgt2,
                    sourceAmount = m 200,
                    targetAmount = m 200,
                    exchangeRate = Nothing,
                    description = "seed2",
                    by = userId_,
                    at = sampleAt,
                    transactionType = Transfer,
                    importInfo = Nothing,
                    labels = Set.empty,
                    contactId = Nothing
                  }
            )
        cancellationInitiated2 =
          StreamEvent
            tx2Uuid
            1
            (emptyMetadata "")
            ( TransactionCancellationInitiatedEvent
                TransactionCancellationInitiated
                  { transactionId = tx2Id,
                    by = userId_
                  }
            )
        debitReversed2 =
          StreamEvent
            src2Uuid
            1
            (emptyMetadata "")
            ( AccountDebitReversedEvent
                AccountDebitReversed
                  { amount = m 200,
                    transactionId = tx2Id,
                    at = sampleAt
                  }
            )

    it "cancellation of tx2 does not affect tx1 saga entry" $ do
      let st =
            runProjection
              [ seedInitiated,
                mkCancellationInitiated,
                seedInitiated2,
                cancellationInitiated2,
                debitReversed2
              ]
      -- tx1 cancellation entry should still have both flags False
      case Map.lookup txId (st ^. #cancellations) of
        Nothing -> expectationFailure "Expected tx1 cancellation entry"
        Just c -> do
          c.sourceReversed `shouldBe` False
          c.targetReversed `shouldBe` False
      -- tx2 should have sourceReversed = True after debitReversed2
      case Map.lookup tx2Id (st ^. #cancellations) of
        Nothing -> expectationFailure "Expected tx2 cancellation entry"
        Just c -> do
          c.sourceReversed `shouldBe` True
          c.targetReversed `shouldBe` False
