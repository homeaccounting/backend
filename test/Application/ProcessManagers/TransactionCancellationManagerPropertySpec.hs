{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionCancellationManagerPropertySpec
-- Description : Property-based tests for the TransactionCancellationManager saga.
--
-- Invariants checked:
--
--   * Exactly two reversal commands (one debit, one credit) are emitted per
--     cancellation, with amounts and @at@ taken from the postings snapshot.
--   * Permutation invariance: the two middle reversal events (Debit-then-Credit
--     vs Credit-then-Debit) produce the same final state and the same multiset
--     of issued commands.
--   * Per-transaction independence: two concurrent cancellations on different
--     transactionIds never affect each other's saga state.
module Application.ProcessManagers.TransactionCancellationManagerPropertySpec (spec) where

import Application.ProcessManagers.Snapshots (TransferPostings (..))
import Application.ProcessManagers.TransactionCancellationManager
  ( TransactionCancellationManager (..),
    handleTransactionCancellationEvent,
    reactToTransactionCancellationEvent,
  )
import Data.List (sort)
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
    Money,
    TransactionId,
    TransferType (..),
    UserId,
    unAccountId,
    unMoney,
    unTransactionId,
  )
import Domain.Models
  ( AccountingCommand (..),
    AccountingEvent (..),
  )
import Domain.Transaction.Events
  ( TransactionCancellationCompleted (..),
    TransactionCancellationInitiated (..),
    TransferInitiated (..),
  )
import Eventium (ProcessManagerEffect (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.Generators (genAccountId, genPositiveMoney, genTransactionId, genUserId)

-- -----------------------------------------------------------------------------
-- Generators
-- -----------------------------------------------------------------------------

-- | Generate a UTCTime in year 2026 (arbitrary day/seconds).
genUTCTime :: Gen UTCTime
genUTCTime = do
  month <- choose (1, 12) :: Gen Int
  dayOfMonth <- choose (1, 28) :: Gen Int
  secs <- choose (0, 86399) :: Gen Int
  pure $ UTCTime (fromGregorian 2026 month dayOfMonth) (fromIntegral secs)

-- | Generate a valid TransferPostings snapshot.
genTransferPostings :: Gen (AccountId, AccountId, TransferPostings)
genTransferPostings = do
  srcId <- genAccountId
  tgtId <- genAccountId `suchThat` (/= srcId)
  srcAmt <- genPositiveMoney
  tgtAmt <- genPositiveMoney
  at_ <- genUTCTime
  pure
    ( srcId,
      tgtId,
      TransferPostings
        { sourceAccountId = srcId,
          targetAccountId = tgtId,
          sourceAmount = srcAmt,
          targetAmount = tgtAmt,
          at = at_
        }
    )

-- | Build a TransferInitiated versioned stream event from a postings snapshot.
mkTransferInitiatedFor ::
  UUID.UUID ->
  AccountId ->
  AccountId ->
  Money ->
  Money ->
  UTCTime ->
  UserId ->
  VersionedStreamEvent AccountingEvent
mkTransferInitiatedFor txUuid src tgt srcAmt tgtAmt at_ by_ =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransferInitiatedEvent
        TransferInitiated
          { sourceAccountId = src,
            targetAccountId = tgt,
            sourceAmount = srcAmt,
            targetAmount = tgtAmt,
            exchangeRate = Nothing,
            description = "property test",
            by = by_,
            at = at_,
            transferType = Transfer,
            externalTransactionId = Nothing,
            labels = Set.empty
          }
    )

-- | Build a TransactionCancellationInitiated versioned stream event.
mkCancellationInitiatedFor ::
  UUID.UUID ->
  TransactionId ->
  UserId ->
  VersionedStreamEvent AccountingEvent
mkCancellationInitiatedFor txUuid txId cancelledBy_ =
  StreamEvent
    txUuid
    1
    (emptyMetadata "")
    ( TransactionCancellationInitiatedEvent
        TransactionCancellationInitiated
          { transactionId = txId,
            cancelledBy = cancelledBy_
          }
    )

-- | Build an AccountDebitReversed versioned stream event.
mkDebitReversedFor ::
  UUID.UUID ->
  TransactionId ->
  Money ->
  UTCTime ->
  VersionedStreamEvent AccountingEvent
mkDebitReversedFor srcUuid txId amt at_ =
  StreamEvent
    srcUuid
    1
    (emptyMetadata "")
    ( AccountDebitReversedEvent
        AccountDebitReversed
          { amount = amt,
            transactionId = txId,
            at = at_
          }
    )

-- | Build an AccountCreditReversed versioned stream event.
mkCreditReversedFor ::
  UUID.UUID ->
  TransactionId ->
  Money ->
  UTCTime ->
  VersionedStreamEvent AccountingEvent
mkCreditReversedFor tgtUuid txId amt at_ =
  StreamEvent
    tgtUuid
    1
    (emptyMetadata "")
    ( AccountCreditReversedEvent
        AccountCreditReversed
          { amount = amt,
            transactionId = txId,
            at = at_
          }
    )

-- | Build a TransactionCancellationCompleted versioned stream event.
mkCancellationCompletedFor ::
  UUID.UUID ->
  TransactionId ->
  UserId ->
  VersionedStreamEvent AccountingEvent
mkCancellationCompletedFor txUuid txId cancelledBy_ =
  StreamEvent
    txUuid
    2
    (emptyMetadata "")
    ( TransactionCancellationCompletedEvent
        TransactionCancellationCompleted
          { transactionId = txId,
            cancelledBy = cancelledBy_
          }
    )

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Fold a list of events through the projection from the empty state.
runProjection :: [VersionedStreamEvent AccountingEvent] -> TransactionCancellationManager
runProjection = foldl' handleTransactionCancellationEvent (TransactionCancellationManager Map.empty Map.empty)

-- | Run projection and collect all react outputs for each event in the list.
--
-- For each event, first apply it to the current state (projection step), then
-- call react on the updated state. This mirrors how the process manager
-- framework processes events: project first, then react.
collectEffects ::
  [VersionedStreamEvent AccountingEvent] ->
  [ProcessManagerEffect AccountingCommand]
collectEffects = snd . foldl' step (TransactionCancellationManager Map.empty Map.empty, [])
  where
    step (st, acc) evt =
      let st' = handleTransactionCancellationEvent st evt
          effects = reactToTransactionCancellationEvent st' evt
       in (st', acc <> effects)

-- | Render an effect as a comparable string label (for multiset equality).
effectLabel :: ProcessManagerEffect AccountingCommand -> String
effectLabel (IssueCommand uuid (ReverseAccountDebitCommand cmd) _) =
  "ReverseDebit:" <> show uuid <> ":" <> show (unMoney cmd.amount)
effectLabel (IssueCommand uuid (ReverseAccountCreditCommand cmd) _) =
  "ReverseCredit:" <> show uuid <> ":" <> show (unMoney cmd.amount)
effectLabel (IssueCommand uuid (CompleteTransactionCancellationCommand _) _) =
  "CompleteCancel:" <> show uuid
effectLabel (IssueCommand uuid _ _) =
  "OtherIssue:" <> show uuid
effectLabel _ = "OtherEffect"

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionCancellationManager Properties" $ do
  -- Property 1: Exactly two reversal commands per cancellation
  prop "emits exactly one ReverseAccountDebit and one ReverseAccountCredit on Initiated"
    $ forAll genTransferPostings
    $ \(src, tgt, postings) ->
      forAll genUserId $ \userId_ ->
        forAll genTransactionId $ \txId ->
          let txUuid = unTransactionId txId
              transferEvent = mkTransferInitiatedFor txUuid src tgt postings.sourceAmount postings.targetAmount postings.at userId_
              cancellationEvent = mkCancellationInitiatedFor txUuid txId userId_
              st = runProjection [transferEvent, cancellationEvent]
              effects = reactToTransactionCancellationEvent st cancellationEvent
           in counterexample ("effects = " <> show (map effectLabel effects))
                $ length effects
                === 2
                .&&. case effects of
                  [ IssueCommand srcTarget (ReverseAccountDebitCommand rd) _,
                    IssueCommand tgtTarget (ReverseAccountCreditCommand rc) _
                    ] ->
                      conjoin
                        [ srcTarget === unAccountId src,
                          rd.amount === postings.sourceAmount,
                          rd.transactionId === txId,
                          rd.at === postings.at,
                          tgtTarget === unAccountId tgt,
                          rc.amount === postings.targetAmount,
                          rc.transactionId === txId,
                          rc.at === postings.at
                        ]
                  _ -> property False

  -- Property 2: Permutation invariance (Debit-then-Credit vs Credit-then-Debit)
  prop "both entries are cleaned up and same multiset of commands for both reversal orderings"
    $ forAll genTransferPostings
    $ \(src, tgt, postings) ->
      forAll genUserId $ \userId_ ->
        forAll genTransactionId $ \txId ->
          let txUuid = unTransactionId txId
              transferEvent = mkTransferInitiatedFor txUuid src tgt postings.sourceAmount postings.targetAmount postings.at userId_
              cancelInitEvent = mkCancellationInitiatedFor txUuid txId userId_
              debitRevEvent = mkDebitReversedFor (unAccountId src) txId postings.sourceAmount postings.at
              creditRevEvent = mkCreditReversedFor (unAccountId tgt) txId postings.targetAmount postings.at
              completedEvent = mkCancellationCompletedFor txUuid txId userId_

              -- Ordering 1: debit reversed before credit
              eventsOrder1 = [transferEvent, cancelInitEvent, debitRevEvent, creditRevEvent, completedEvent]
              -- Ordering 2: credit reversed before debit
              eventsOrder2 = [transferEvent, cancelInitEvent, creditRevEvent, debitRevEvent, completedEvent]

              stateOrder1 = runProjection eventsOrder1
              stateOrder2 = runProjection eventsOrder2

              effectsOrder1 = collectEffects eventsOrder1
              effectsOrder2 = collectEffects eventsOrder2

              labelsOrder1 = sort (map effectLabel effectsOrder1)
              labelsOrder2 = sort (map effectLabel effectsOrder2)
           in counterexample
                ( "order1 effects: "
                    <> show labelsOrder1
                    <> "\norder2 effects: "
                    <> show labelsOrder2
                )
                $ conjoin
                  [ -- Final state: both entries removed regardless of reversal order
                    Map.member txId (stateOrder1 ^. #cancellations) === False,
                    Map.member txId (stateOrder2 ^. #cancellations) === False,
                    Map.member txId (stateOrder1 ^. #currentPostings) === False,
                    Map.member txId (stateOrder2 ^. #currentPostings) === False,
                    -- Multiset of issued commands is equal
                    labelsOrder1 === labelsOrder2
                  ]

  -- Property 3: Per-transaction independence
  prop "cancellations on different transactionIds do not interfere with each other"
    $ forAll genTransferPostings
    $ \(src1, tgt1, postings1) ->
      forAll genTransferPostings $ \(src2, tgt2, postings2) ->
        forAll genUserId $ \userId1 ->
          forAll genUserId $ \userId2 ->
            forAll genTransactionId $ \txId1 ->
              forAll (genTransactionId `suchThat` (/= txId1)) $ \txId2 ->
                let txUuid1 = unTransactionId txId1
                    txUuid2 = unTransactionId txId2

                    -- TX1 events
                    transfer1 = mkTransferInitiatedFor txUuid1 src1 tgt1 postings1.sourceAmount postings1.targetAmount postings1.at userId1
                    cancelInit1 = mkCancellationInitiatedFor txUuid1 txId1 userId1

                    -- TX2 events
                    transfer2 = mkTransferInitiatedFor txUuid2 src2 tgt2 postings2.sourceAmount postings2.targetAmount postings2.at userId2
                    cancelInit2 = mkCancellationInitiatedFor txUuid2 txId2 userId2
                    debitRev2 = mkDebitReversedFor (unAccountId src2) txId2 postings2.sourceAmount postings2.at

                    -- State with only TX1 events
                    stWithoutTx2 = runProjection [transfer1, cancelInit1]

                    -- State with TX1 + TX2 events interleaved
                    stWithTx2 = runProjection [transfer1, cancelInit1, transfer2, cancelInit2, debitRev2]

                    -- TX1 cancellation data from each state
                    tx1WithoutTx2 = Map.lookup txId1 (stWithoutTx2 ^. #cancellations)
                    tx1WithTx2 = Map.lookup txId1 (stWithTx2 ^. #cancellations)

                    -- TX1 postings from each state
                    postings1WithoutTx2 = Map.lookup txId1 (stWithoutTx2 ^. #currentPostings)
                    postings1WithTx2 = Map.lookup txId1 (stWithTx2 ^. #currentPostings)
                 in counterexample
                      ( "tx1 cancellation without tx2: "
                          <> show tx1WithoutTx2
                          <> "\ntx1 cancellation with tx2: "
                          <> show tx1WithTx2
                      )
                      $ conjoin
                        [ tx1WithoutTx2 === tx1WithTx2,
                          postings1WithoutTx2 === postings1WithTx2
                        ]
