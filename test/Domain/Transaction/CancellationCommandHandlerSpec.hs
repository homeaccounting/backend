{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.CancellationCommandHandlerSpec
-- Description : Unit tests for CancelTransaction / CompleteTransactionCancellation
--               and the amended AmendTransaction arm
--
-- Covers the pure business-rule enforcement in the command handler for the
-- two cancellation commands and verifies the cross-saga gating introduced
-- by adding @cancellationInProgress@ awareness to the existing @AmendTransaction@
-- arm:
--
--   * CancelTransaction              – user-facing command; accepted only on Completed
--                                      with both saga flags False
--   * CompleteTransactionCancellation – saga-internal; accepted only when
--                                       @cancellationInProgress = True@
--   * AmendTransaction (regression)     – verifies existing checks still fire when
--                                       @cancellationInProgress = False@, and
--                                       the new @CannotAmendDuringCancellation@
--                                       check fires when @cancellationInProgress = True@
--   * Existing edit commands on Cancelled state (regression)
module Domain.Transaction.CancellationCommandHandlerSpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    TransactionId,
    TransactionType (..),
    UserId,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    TransactionError (..),
    handleTransactionCommand,
  )
import Domain.Transaction.Commands
  ( AmendTransaction (..),
    CancelTransaction (..),
    ChangeTransactionDescription (..),
    CompleteTransactionCancellation (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Events
  ( TransactionCancellationCompleted (..),
    TransactionCancellationInitiated (..),
  )
import Domain.Transaction.Projection
  ( Transaction,
    TransactionEvent (..),
    TransactionStatus (..),
    transactionDefault,
  )
import Optics ((&), (.~))
import RIO hiding ((&), (.~))
import Test.Hspec
import Testkit.Helpers

-- -----------------------------------------------------------------------------
-- Shared fixtures
-- -----------------------------------------------------------------------------

txId :: TransactionId
txId = unsafeTransactionId (UUID.fromWords 100 0 0 0)

cancelledBy :: UserId
cancelledBy = unsafeUserId (UUID.fromWords 1 0 0 0)

amendedBy :: UserId
amendedBy = unsafeUserId (UUID.fromWords 2 0 0 0)

srcId :: AccountId
srcId = mockAccountId (UUID.fromWords 10 0 0 0)

tgtId :: AccountId
tgtId = mockAccountId (UUID.fromWords 20 0 0 0)

altSrcId :: AccountId
altSrcId = mockAccountId (UUID.fromWords 30 0 0 0)

altTgtId :: AccountId
altTgtId = mockAccountId (UUID.fromWords 40 0 0 0)

-- | A completed transaction with both saga flags False — happy-path base.
completedTx :: Transaction
completedTx =
  transactionDefault
    & #status
    .~ Completed
    & #sourceAccountId
    .~ srcId
    & #targetAccountId
    .~ tgtId
    & #amendmentInProgress
    .~ False
    & #cancellationInProgress
    .~ False

-- | Pending transaction — should be rejected by most edit commands.
pendingTx :: Transaction
pendingTx = transactionDefault & #status .~ Pending

-- | Failed transaction — should be rejected by most edit commands.
failedTx :: Transaction
failedTx = transactionDefault & #status .~ Failed "reason"

-- | Terminal Cancelled transaction.
cancelledTx :: Transaction
cancelledTx =
  transactionDefault
    & #status
    .~ Cancelled
    & #cancellationInProgress
    .~ False

-- | Completed transaction with an amendment already in progress.
completedTxWithAmendmentInProgress :: Transaction
completedTxWithAmendmentInProgress =
  completedTx & #amendmentInProgress .~ True

-- | Completed transaction with a cancellation already in progress.
completedTxWithCancellationInProgress :: Transaction
completedTxWithCancellationInProgress =
  completedTx & #cancellationInProgress .~ True

-- -----------------------------------------------------------------------------
-- Commands
-- -----------------------------------------------------------------------------

-- | Minimal valid 'CancelTransaction' command.
validCancelCmd :: TransactionCommand
validCancelCmd =
  CancelTransactionTransactionCommand
    CancelTransaction
      { transactionId = txId,
        by = cancelledBy
      }

-- | Saga-internal 'CompleteTransactionCancellation' command.
validCompleteCancelCmd :: TransactionCommand
validCompleteCancelCmd =
  CompleteTransactionCancellationTransactionCommand
    CompleteTransactionCancellation
      { transactionId = txId,
        by = cancelledBy
      }

-- | Minimal valid 'AmendTransaction' command (different accounts, non-zero amounts).
validAmendCmd :: TransactionCommand
validAmendCmd =
  AmendTransactionTransactionCommand
    AmendTransaction
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altTgtId,
        newSourceAmount = mockMoney 200,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        newAllocations = Nothing,
        newTransactionType = Transfer,
        contactId = Nothing,
        by = amendedBy
      }

-- | 'AmendTransaction' with the same account on both legs — should be rejected.
sameAccountAmendCmd :: TransactionCommand
sameAccountAmendCmd =
  AmendTransactionTransactionCommand
    AmendTransaction
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altSrcId,
        newSourceAmount = mockMoney 200,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        newAllocations = Nothing,
        newTransactionType = Transfer,
        contactId = Nothing,
        by = amendedBy
      }

-- | 'AmendTransaction' with zero source amount — should be rejected.
zeroSourceAmendCmd :: TransactionCommand
zeroSourceAmendCmd =
  AmendTransactionTransactionCommand
    AmendTransaction
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altTgtId,
        newSourceAmount = mockMoney 0,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        newAllocations = Nothing,
        newTransactionType = Transfer,
        contactId = Nothing,
        by = amendedBy
      }

-- | 'ChangeTransactionDescription' command — used for Cancelled-state regression.
changeDescriptionCmd :: TransactionCommand
changeDescriptionCmd =
  ChangeTransactionDescriptionTransactionCommand
    ChangeTransactionDescription
      { transactionId = txId,
        newDescription = "Updated description"
      }

-- | 'SetTransactionLabels' command — used for Cancelled-state regression.
setLabelsCmd :: TransactionCommand
setLabelsCmd =
  SetTransactionLabelsTransactionCommand
    SetTransactionLabels
      { transactionId = txId,
        labels = Set.empty
      }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "CancelTransaction" $ do
    it "accepted in Completed state (both flags False) and emits TransactionCancellationInitiated" $ do
      let result = handleTransactionCommand completedTx validCancelCmd
      case result of
        Right
          [ TransactionCancellationInitiatedTransactionEvent
              TransactionCancellationInitiated
                { transactionId = evtTxId,
                  by = evtCancelledBy
                }
            ] -> do
            evtTxId `shouldBe` txId
            evtCancelledBy `shouldBe` cancelledBy
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransactionCancellationInitiated], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err

    it "rejected in Pending state with CannotEditUncompletedTransaction"
      $ handleTransactionCommand pendingTx validCancelCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected in Failed state with CannotEditUncompletedTransaction"
      $ handleTransactionCommand failedTx validCancelCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected in Cancelled state with TransactionAlreadyCancelled"
      $ handleTransactionCommand cancelledTx validCancelCmd
      `shouldBe` Left TransactionAlreadyCancelled

    it "rejected when amendmentInProgress = True with CannotCancelDuringAmendment"
      $ handleTransactionCommand completedTxWithAmendmentInProgress validCancelCmd
      `shouldBe` Left CannotCancelDuringAmendment

    it "rejected when cancellationInProgress = True with CancellationAlreadyInProgress"
      $ handleTransactionCommand completedTxWithCancellationInProgress validCancelCmd
      `shouldBe` Left CancellationAlreadyInProgress

  describe "CompleteTransactionCancellation" $ do
    it "accepted when cancellationInProgress = True and emits TransactionCancellationCompleted" $ do
      let result = handleTransactionCommand completedTxWithCancellationInProgress validCompleteCancelCmd
      case result of
        Right
          [ TransactionCancellationCompletedTransactionEvent
              TransactionCancellationCompleted
                { transactionId = evtTxId,
                  by = evtCancelledBy
                }
            ] -> do
            evtTxId `shouldBe` txId
            evtCancelledBy `shouldBe` cancelledBy
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransactionCancellationCompleted], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err

    it "rejected when cancellationInProgress = False with NoCancellationInProgress"
      $ handleTransactionCommand completedTx validCompleteCancelCmd
      `shouldBe` Left NoCancellationInProgress

  describe "AmendTransaction (cross-saga gating)" $ do
    it "rejected when cancellationInProgress = True with CannotAmendDuringCancellation"
      $ handleTransactionCommand completedTxWithCancellationInProgress validAmendCmd
      `shouldBe` Left CannotAmendDuringCancellation

    it "rejected (regression) when newSourceAccountId == newTargetAccountId with AmendTransferToSameAccountPair"
      $ handleTransactionCommand completedTx sameAccountAmendCmd
      `shouldBe` Left AmendTransferToSameAccountPair

    it "rejected (regression) when newSourceAmount is zero with AmendTransferToZeroAmount"
      $ handleTransactionCommand completedTx zeroSourceAmendCmd
      `shouldBe` Left AmendTransferToZeroAmount

  describe "Existing edit commands on Cancelled state (regression)" $ do
    it "ChangeTransactionDescription rejected with CannotEditUncompletedTransaction"
      $ handleTransactionCommand cancelledTx changeDescriptionCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "SetTransactionLabels rejected with CannotEditUncompletedTransaction"
      $ handleTransactionCommand cancelledTx setLabelsCmd
      `shouldBe` Left CannotEditUncompletedTransaction
