{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.AmendmentCommandHandlerSpec
-- Description : Unit tests for InitiateTransactionAmendment / CompleteTransactionAmendment / FailTransactionAmendment
--
-- Covers the pure business-rule enforcement in the command handler for the
-- three amendment-saga commands:
--
--   * InitiateTransactionAmendment    – user-facing command; accepted only on Completed
--   * CompleteTransactionAmendment – saga-internal; accepted only when an amendment is in progress
--   * FailTransactionAmendment     – saga-internal; accepted only when an amendment is in progress
module Domain.Transaction.AmendmentCommandHandlerSpec (spec) where

import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Currency (..),
    DictionaryEntryId,
    TransactionId,
    TransactionType (..),
    UserId,
    mkMixedAllocations,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    TransactionError (..),
    handleTransactionCommand,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( CompleteTransactionAmendment (..),
    FailTransactionAmendment (..),
    InitiateTransactionAmendment (..),
  )
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionAmendmentFailed (..),
    TransactionAmendmentInitiated (..),
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

-- | Category IDs used for contra-income allocation fixtures.
incomeCat :: DictionaryEntryId
incomeCat = unsafeDictionaryEntryId (UUID.fromWords 50 0 0 0)

expenseCat :: DictionaryEntryId
expenseCat = unsafeDictionaryEntryId (UUID.fromWords 51 0 0 0)

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
-- Simulates the state after 'InitiateTransactionAmendment' was accepted and a
-- 'TransactionAmendmentInitiated' event was applied: 'amendmentInProgress = True'.
completedTxWithAmendmentInProgress :: Transaction
completedTxWithAmendmentInProgress =
  completedTx & #amendmentInProgress .~ True

-- -----------------------------------------------------------------------------
-- Commands
-- -----------------------------------------------------------------------------

-- | Minimal valid 'InitiateTransactionAmendment' command payload.
validAmendCmd :: TransactionCommand
validAmendCmd =
  InitiateTransactionAmendmentTransactionCommand
    InitiateTransactionAmendment
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altTgtId,
        newSourceAmount = mockMoney 200,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        newAllocations = Nothing,
        newTransactionType = Transfer,
        contactId = Nothing,
        allowOverdraft = False,
        by = amendedBy
      }

-- | Valid 'CompleteTransactionAmendment' saga command.
validCompleteAmendCmd :: TransactionCommand
validCompleteAmendCmd =
  CompleteTransactionAmendmentTransactionCommand
    CompleteTransactionAmendment
      { transactionId = txId,
        newSourceAccountId = altSrcId,
        newTargetAccountId = altTgtId,
        newSourceAmount = mockMoney 200,
        newTargetAmount = mockMoney 200,
        newExchangeRate = Nothing,
        newTransactionType = Transfer,
        contactId = Nothing,
        by = amendedBy
      }

-- | Valid 'FailTransactionAmendment' saga command.
validFailAmendCmd :: TransactionCommand
validFailAmendCmd =
  FailTransactionAmendmentTransactionCommand
    FailTransactionAmendment
      { reason = "Insufficient funds in new source account"
      }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "InitiateTransactionAmendment" $ do
    it "accepted in Completed state and emits TransactionAmendmentInitiated" $ do
      let result = handleTransactionCommand completedTx validAmendCmd
      case result of
        Right
          [ TransactionAmendmentInitiatedTransactionEvent
              TransactionAmendmentInitiated
                { newSourceAccountId = evtSrc,
                  newTargetAccountId = evtTgt,
                  newSourceAmount = evtSrcAmt,
                  newTargetAmount = evtTgtAmt,
                  newExchangeRate = evtRate,
                  by = evtAmendedBy,
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
            $ "Expected exactly [TransactionAmendmentInitiated], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err

    it "carries allowOverdraft from the amend command into the emitted event" $ do
      let cmd =
            InitiateTransactionAmendment
              { transactionId = txId,
                newSourceAccountId = altSrcId,
                newTargetAccountId = altTgtId,
                newSourceAmount = mockMoney 200,
                newTargetAmount = mockMoney 200,
                newExchangeRate = Nothing,
                newAllocations = Nothing,
                newTransactionType = Transfer,
                contactId = Nothing,
                allowOverdraft = True,
                by = amendedBy
              }
      case handleTransactionCommand completedTx (InitiateTransactionAmendmentTransactionCommand cmd) of
        Right [TransactionAmendmentInitiatedTransactionEvent evt] ->
          evt.allowOverdraft `shouldBe` True
        other -> expectationFailure ("unexpected: " <> show other)

    it "rejected in Pending state with CannotEditUncompletedTransaction"
      $ handleTransactionCommand pendingTx validAmendCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected in Failed state with CannotEditUncompletedTransaction"
      $ handleTransactionCommand failedTx validAmendCmd
      `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected when newSourceAccountId == newTargetAccountId with AmendTransferToSameAccountPair" $ do
      let sameAccountCmd =
            InitiateTransactionAmendmentTransactionCommand
              InitiateTransactionAmendment
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altSrcId,
                  newSourceAmount = mockMoney 200,
                  newTargetAmount = mockMoney 200,
                  newExchangeRate = Nothing,
                  newAllocations = Nothing,
                  newTransactionType = Transfer,
                  contactId = Nothing,
                  allowOverdraft = False,
                  by = amendedBy
                }
      handleTransactionCommand completedTx sameAccountCmd
        `shouldBe` Left AmendTransferToSameAccountPair

    it "rejected when newSourceAmount is zero with AmendTransferToZeroAmount" $ do
      let zeroSrcCmd =
            InitiateTransactionAmendmentTransactionCommand
              InitiateTransactionAmendment
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altTgtId,
                  newSourceAmount = mockMoney 0,
                  newTargetAmount = mockMoney 200,
                  newExchangeRate = Nothing,
                  newAllocations = Nothing,
                  newTransactionType = Transfer,
                  contactId = Nothing,
                  allowOverdraft = False,
                  by = amendedBy
                }
      handleTransactionCommand completedTx zeroSrcCmd
        `shouldBe` Left AmendTransferToZeroAmount

    it "rejected when newTargetAmount is zero with AmendTransferToZeroAmount" $ do
      let zeroTgtCmd =
            InitiateTransactionAmendmentTransactionCommand
              InitiateTransactionAmendment
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altTgtId,
                  newSourceAmount = mockMoney 200,
                  newTargetAmount = mockMoney 0,
                  newExchangeRate = Nothing,
                  newAllocations = Nothing,
                  newTransactionType = Transfer,
                  contactId = Nothing,
                  allowOverdraft = False,
                  by = amendedBy
                }
      handleTransactionCommand completedTx zeroTgtCmd
        `shouldBe` Left AmendTransferToZeroAmount

    -- The $40 income + $160 expense sum to $200 (== newSourceAmount), so
    -- checkAllocationsAgainst passes first; the contra-income guard then fires.
    --
    -- WHY it would fail if the guard were removed: without the
    --   "if null allocs.incomes then Right () else Left ContraIncomeNotSupported"
    -- branch, the handler would emit a Right [TransactionAmendmentInitiated...]
    -- instead of Left ContraIncomeNotSupported.
    it "rejected when newTransactionType is Expense with a non-empty incomes bucket (ContraIncomeNotSupported)" $ do
      let contraAllocs =
            mkMixedAllocations
              (Allocation incomeCat (unsafeMoney USD 40) Nothing :| [])
              (Allocation expenseCat (unsafeMoney USD 160) Nothing :| [])
          contraAmendCmd =
            InitiateTransactionAmendmentTransactionCommand
              InitiateTransactionAmendment
                { transactionId = txId,
                  newSourceAccountId = altSrcId,
                  newTargetAccountId = altTgtId,
                  newSourceAmount = mockMoney 200,
                  newTargetAmount = mockMoney 200,
                  newExchangeRate = Nothing,
                  newAllocations = Nothing,
                  newTransactionType = Expense contraAllocs,
                  contactId = Nothing,
                  allowOverdraft = False,
                  by = amendedBy
                }
      handleTransactionCommand completedTx contraAmendCmd
        `shouldBe` Left TxCh.ContraIncomeNotSupported

  describe "CompleteTransactionAmendment" $ do
    it "rejected when no amendment is in progress with NoAmendmentInProgress"
      $ handleTransactionCommand completedTx validCompleteAmendCmd
      `shouldBe` Left NoAmendmentInProgress

    it "accepted when amendment is in progress and emits TransactionAmendmentCompleted" $ do
      let result = handleTransactionCommand completedTxWithAmendmentInProgress validCompleteAmendCmd
      case result of
        Right
          [ TransactionAmendmentCompletedTransactionEvent
              TransactionAmendmentCompleted
                { newSourceAccountId = evtSrc,
                  newTargetAccountId = evtTgt,
                  newSourceAmount = evtSrcAmt,
                  transactionId = _,
                  newTargetAmount = _,
                  newExchangeRate = _,
                  newTransactionType = _,
                  by = _
                }
            ] -> do
            evtSrc `shouldBe` altSrcId
            evtTgt `shouldBe` altTgtId
            evtSrcAmt `shouldBe` mockMoney 200
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransactionAmendmentCompleted], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err

  describe "FailTransactionAmendment" $ do
    it "rejected when no amendment is in progress with NoAmendmentInProgress"
      $ handleTransactionCommand completedTx validFailAmendCmd
      `shouldBe` Left NoAmendmentInProgress

    it "accepted when amendment is in progress and emits TransactionAmendmentFailed" $ do
      let result = handleTransactionCommand completedTxWithAmendmentInProgress validFailAmendCmd
      case result of
        Right [TransactionAmendmentFailedTransactionEvent (TransactionAmendmentFailed failReason)] ->
          failReason `shouldBe` "Insufficient funds in new source account"
        Right evts ->
          expectationFailure
            $ "Expected exactly [TransactionAmendmentFailed], got "
            <> show (length evts)
            <> " events"
        Left err -> expectationFailure $ "Expected Right, got Left: " <> show err
