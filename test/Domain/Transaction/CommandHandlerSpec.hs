{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.CommandHandlerSpec
-- Description : Unit tests for Transaction command handler
--
-- This module tests the Transaction aggregate command handler business logic.
--
-- Test Coverage:
--   - InitiateTransfer: Transfer validation, business rules
--   - CompleteTransfer: State transition validation
--   - FailTransfer: State transition validation
--   - State machine enforcement
module Domain.Transaction.CommandHandlerSpec (spec) where

import Data.Either (isLeft)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Types
import Domain.Transaction
import Domain.Transaction.CommandHandler
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import TestSupport.Generators ()
import TestSupport.Helpers
import Prelude (head, read)

spec :: Spec
spec = do
  initiateTransferSpec
  completeTransferSpec
  failTransferSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get transaction state
applyEvents :: [TransactionEvent] -> Transaction
applyEvents = latestProjection transactionProjection

-- | Create a default empty transaction (no events applied)
emptyTransaction :: Transaction
emptyTransaction = applyEvents []

-- | Test user ID for initiating transfers
testUserId :: UserId
testUserId = mockUserId (read "11111111-1111-1111-1111-111111111111")

-- | Create a pending transaction
pendingTransaction :: AccountId -> AccountId -> Money -> Transaction
pendingTransaction fromId toId amt =
  applyEvents
    [ TransferInitiatedTransactionEvent
        $ TransferInitiated
          { fromAccountId = fromId,
            toAccountId = toId,
            amount = amt,
            reason = "Test transfer",
            by = testUserId
          }
    ]

-- | Create completed transaction
completedTransaction :: AccountId -> AccountId -> Money -> Transaction
completedTransaction fromId toId amt =
  applyEvents
    [ TransferInitiatedTransactionEvent
        $ TransferInitiated
          { fromAccountId = fromId,
            toAccountId = toId,
            amount = amt,
            reason = "Test transfer",
            by = testUserId
          },
      TransferCompletedTransactionEvent TransferCompleted
    ]

-- | Create failed transaction
failedTransaction :: AccountId -> AccountId -> Money -> Transaction
failedTransaction fromId toId amt =
  applyEvents
    [ TransferInitiatedTransactionEvent
        $ TransferInitiated
          { fromAccountId = fromId,
            toAccountId = toId,
            amount = amt,
            reason = "Test transfer",
            by = testUserId
          },
      TransferFailedTransactionEvent $ TransferFailed "Insufficient funds"
    ]

-- -----------------------------------------------------------------------------
-- InitiateTransfer Tests
-- -----------------------------------------------------------------------------

initiateTransferSpec :: Spec
initiateTransferSpec = describe "InitiateTransfer Command" $ do
  context "Given empty transaction" $ do
    describe "When initiating valid transfer" $ do
      it "Then emits TransferInitiated event" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransferTransactionCommand
                $ InitiateTransfer
                  { fromAccountId = fromId,
                    toAccountId = toId,
                    amount = mockMoney 500,
                    reason = "Payment"
                  }
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TransferInitiatedTransactionEvent initiated -> do
                initiated.fromAccountId `shouldBe` fromId
                initiated.toAccountId `shouldBe` toId
                initiated.amount `shouldBe` mockMoney 500
                initiated.reason `shouldBe` "Payment"
              _ -> expectationFailure "Expected TransferInitiated event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then transaction status becomes Pending" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransferTransactionCommand
                $ InitiateTransfer
                  { fromAccountId = fromId,
                    toAccountId = toId,
                    amount = mockMoney 500,
                    reason = "Test"
                  }
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            let newTransaction = applyEvents events
            newTransaction ^. #status `shouldBe` Pending
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When source equals target" $ do
      it "Then rejects command (no events)" $ do
        accountId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransferTransactionCommand
                $ InitiateTransfer
                  { fromAccountId = accountId,
                    toAccountId = accountId,
                    amount = mockMoney 500,
                    reason = "Self-transfer"
                  }
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

    describe "When amount is zero or negative" $ do
      it "Then rejects command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransferTransactionCommand
                $ InitiateTransfer
                  { fromAccountId = fromId,
                    toAccountId = toId,
                    amount = mockMoney 0,
                    reason = "Zero transfer"
                  }
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

  context "Given already initiated transaction" $ do
    describe "When attempting to initiate again" $ do
      it "Then ignores command (no events)" $ do
        fromId1 <- mockAccountId <$> UUID.nextRandom
        toId1 <- mockAccountId <$> UUID.nextRandom
        fromId2 <- mockAccountId <$> UUID.nextRandom
        toId2 <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId1 toId1 (mockMoney 100)
        let command =
              InitiateTransferTransactionCommand
                $ InitiateTransfer
                  { fromAccountId = fromId2,
                    toAccountId = toId2,
                    amount = mockMoney 200,
                    reason = "Second attempt"
                  }
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- CompleteTransfer Tests
-- -----------------------------------------------------------------------------

completeTransferSpec :: Spec
completeTransferSpec = describe "CompleteTransfer Command" $ do
  context "Given pending transaction" $ do
    describe "When completing transfer" $ do
      it "Then emits TransferCompleted event" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = CompleteTransferTransactionCommand CompleteTransfer
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TransferCompletedTransactionEvent _ -> pure ()
              _ -> expectationFailure "Expected TransferCompleted event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then transaction status becomes Completed" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = CompleteTransferTransactionCommand CompleteTransfer
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            let newTransaction = applyEvents $ [TransferInitiatedTransactionEvent $ TransferInitiated fromId toId (mockMoney 500) "Test" testUserId] <> events
            newTransaction ^. #status `shouldBe` Completed
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given completed transaction" $ do
    describe "When attempting to complete again" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = completedTransaction fromId toId (mockMoney 500)
        let command = CompleteTransferTransactionCommand CompleteTransfer
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

  context "Given failed transaction" $ do
    describe "When attempting to complete" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = failedTransaction fromId toId (mockMoney 500)
        let command = CompleteTransferTransactionCommand CompleteTransfer
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- FailTransfer Tests
-- -----------------------------------------------------------------------------

failTransferSpec :: Spec
failTransferSpec = describe "FailTransfer Command" $ do
  context "Given pending transaction" $ do
    describe "When failing transfer" $ do
      it "Then emits TransferFailed event" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = FailTransferTransactionCommand $ FailTransfer "Insufficient funds"
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TransferFailedTransactionEvent failed ->
                failed.reason `shouldBe` "Insufficient funds"
              _ -> expectationFailure "Expected TransferFailed event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then transaction status becomes Failed" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = FailTransferTransactionCommand $ FailTransfer "Error"
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            let newTransaction = applyEvents $ [TransferInitiatedTransactionEvent $ TransferInitiated fromId toId (mockMoney 500) "Test" testUserId] <> events
            newTransaction ^. #status `shouldBe` Failed "Error"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given completed transaction" $ do
    describe "When attempting to fail" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = completedTransaction fromId toId (mockMoney 500)
        let command = FailTransferTransactionCommand $ FailTransfer "Too late"
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

  context "Given failed transaction" $ do
    describe "When attempting to fail again" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = failedTransaction fromId toId (mockMoney 500)
        let command = FailTransferTransactionCommand $ FailTransfer "Another failure"
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft
