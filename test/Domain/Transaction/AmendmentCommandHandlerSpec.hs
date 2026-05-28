{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.AmendmentCommandHandlerSpec
-- Description : Unit tests for AmendTransfer / CompleteTransferAmendment / FailTransferAmendment
--
-- Covers the pure business-rule enforcement in the command handler for the
-- three amendment-saga commands:
--
--   * AmendTransfer    – user-facing command; accepted only on Completed
--   * CompleteTransferAmendment – saga-internal; accepted only when an amendment is in progress
--   * FailTransferAmendment     – saga-internal; accepted only when an amendment is in progress
module Domain.Transaction.AmendmentCommandHandlerSpec (spec) where

import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    TransactionId,
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
  ( AmendTransfer (..),
    CompleteTransferAmendment (..),
    FailTransferAmendment (..),
  )
import Domain.Transaction.Events
  ( TransferAmendmentCompleted (..),
    TransferAmendmentFailed (..),
    TransferAmendmentInitiated (..),
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

amendedBy :: UserId
amendedBy = unsafeUserId (UUID.fromWords 1 0 0 0)

srcId :: AccountId
srcId = mockAccountId (UUID.fromWords 10 0 0 0)

tgtId :: AccountId
tgtId = mockAccountId (UUID.fromWords 20 0 0 0)

altSrcId :: AccountId
altSrcId = mockAccountId (UUID.fromWords 30 0 0 0)

altTgtId :: AccountId
altTgtId = mockAccountId (UUID.fromWords 40 0 0 0)

-- | A completed transaction (no amendment in progress).
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

-- | A pending transaction.
pendingTx :: Transaction
pendingTx = transactionDefault & #status .~ Pending

-- | A failed transaction.
failedTx :: Transaction
failedTx = transactionDefault & #status .~ Failed "reason"

-- | A completed transaction with an amendment already in progress.
--
-- Simulates the state after 'AmendTransfer' was accepted and a
-- 'TransferAmendmentInitiated' event was applied: 'amendmentInProgress = True'.
completedTxWithAmendmentInProgress :: Transaction
completedTxWithAmendmentInProgress =
  completedTx & #amendmentInProgress .~ True

-- -----------------------------------------------------------------------------
-- Commands
-- -----------------------------------------------------------------------------

-- | Minimal valid 'AmendTransfer' command payload.
validAmendCmd :: TransactionCommand
validAmendCmd =
  AmendTransferTransactionCommand
    AmendTransfer
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altTgtId,
        newSourceAmount = mockMoney 200,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        amendedBy = amendedBy
      }

-- | Valid 'CompleteTransferAmendment' saga command.
validCompleteAmendCmd :: TransactionCommand
validCompleteAmendCmd =
  CompleteTransferAmendmentTransactionCommand
    CompleteTransferAmendment
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altTgtId,
        newSourceAmount = mockMoney 200,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        amendedBy = amendedBy
      }

-- | Valid 'FailTransferAmendment' saga command.
validFailAmendCmd :: TransactionCommand
validFailAmendCmd =
  FailTransferAmendmentTransactionCommand
    FailTransferAmendment
      { reason = "Insufficient funds in new source account"
      }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "AmendTransfer" $ do
    it "accepted in Completed state and emits TransferAmendmentInitiated" $ do
      let result = handleTransactionCommand completedTx validAmendCmd
      case result of
        Right
          [ TransferAmendmentInitiatedTransactionEvent
              TransferAmendmentInitiated
                { newSourceAccountId = evtSrc,
                  newTargetAccountId = evtTgt,
                  newSourceAmount = evtSrcAmt,
                  newTargetAmount = evtTgtAmt,
                  newExchangeRate = evtRate,
                  amendedBy = evtAmendedBy,
                  transactionId = _
                }
            ] -> do
            evtSrc `shouldBe` altSrcId
            evtTgt `shouldBe` altTgtId
            evtSrcAmt `shouldBe` mockMoney 200
            evtTgtAmt `shouldBe` mockMoney 200
            evtRate `shouldBe` Nothing
            evtAmendedBy `shouldBe` amendedBy
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransferAmendmentInitiated], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err

    it "rejected in Pending state with CannotEditUncompletedTransaction"
      $ handleTransactionCommand pendingTx validAmendCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected in Failed state with CannotEditUncompletedTransaction"
      $ handleTransactionCommand failedTx validAmendCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected when newSourceAccountId == newTargetAccountId with AmendTransferToSameAccountPair" $ do
      let sameAccountCmd =
            AmendTransferTransactionCommand
              AmendTransfer
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altSrcId,
                  newSourceAmount = mockMoney 200,
                  newTargetAmount = mockMoney 200,
                  newExchangeRate = Nothing,
                  amendedBy = amendedBy
                }
      handleTransactionCommand completedTx sameAccountCmd
        `shouldBe` Left AmendTransferToSameAccountPair

    it "rejected when newSourceAmount is zero with AmendTransferToZeroAmount" $ do
      let zeroSrcCmd =
            AmendTransferTransactionCommand
              AmendTransfer
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altTgtId,
                  newSourceAmount = mockMoney 0,
                  newTargetAmount = mockMoney 200,
                  newExchangeRate = Nothing,
                  amendedBy = amendedBy
                }
      handleTransactionCommand completedTx zeroSrcCmd
        `shouldBe` Left AmendTransferToZeroAmount

    it "rejected when newTargetAmount is zero with AmendTransferToZeroAmount" $ do
      let zeroTgtCmd =
            AmendTransferTransactionCommand
              AmendTransfer
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altTgtId,
                  newSourceAmount = mockMoney 200,
                  newTargetAmount = mockMoney 0,
                  newExchangeRate = Nothing,
                  amendedBy = amendedBy
                }
      handleTransactionCommand completedTx zeroTgtCmd
        `shouldBe` Left AmendTransferToZeroAmount

  describe "CompleteTransferAmendment" $ do
    it "rejected when no amendment is in progress with NoAmendmentInProgress"
      $ handleTransactionCommand completedTx validCompleteAmendCmd
      `shouldBe` Left NoAmendmentInProgress

    it "accepted when amendment is in progress and emits TransferAmendmentCompleted" $ do
      let result = handleTransactionCommand completedTxWithAmendmentInProgress validCompleteAmendCmd
      case result of
        Right
          [ TransferAmendmentCompletedTransactionEvent
              TransferAmendmentCompleted
                { newSourceAccountId = evtSrc,
                  newTargetAccountId = evtTgt,
                  newSourceAmount = evtSrcAmt,
                  transactionId = _,
                  newTargetAmount = _,
                  newExchangeRate = _,
                  amendedBy = _
                }
            ] -> do
            evtSrc `shouldBe` altSrcId
            evtTgt `shouldBe` altTgtId
            evtSrcAmt `shouldBe` mockMoney 200
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransferAmendmentCompleted], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err

  describe "FailTransferAmendment" $ do
    it "rejected when no amendment is in progress with NoAmendmentInProgress"
      $ handleTransactionCommand completedTx validFailAmendCmd
      `shouldBe` Left NoAmendmentInProgress

    it "accepted when amendment is in progress and emits TransferAmendmentFailed" $ do
      let result = handleTransactionCommand completedTxWithAmendmentInProgress validFailAmendCmd
      case result of
        Right [TransferAmendmentFailedTransactionEvent (TransferAmendmentFailed failReason)] ->
          failReason `shouldBe` "Insufficient funds in new source account"
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransferAmendmentFailed], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err
