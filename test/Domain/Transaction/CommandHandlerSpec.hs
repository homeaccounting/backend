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
--   - InitiateTransactionPosting: Transfer validation, business rules
--   - CompleteTransactionPosting: State transition validation
--   - FailTransactionPosting: State transition validation
--   - State machine enforcement
module Domain.Transaction.CommandHandlerSpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID.V4 as UUID
import Domain.Banking.Import (ImportInfo (..), importInfoExternalTransactionIds, unsafeExternalTransactionId)
import Domain.Core.Types
import Domain.Transaction
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Testkit.Generators ()
import Testkit.Helpers
import Prelude (head, read)

-- | Fixed business time used for all transfer fixtures.
mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

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
    [ TransactionPostingInitiatedTransactionEvent
        $ TransactionPostingInitiated
          { sourceAccountId = fromId,
            targetAccountId = toId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = testUserId,
            at = mockTime,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          }
    ]

-- | Create completed transaction
completedTransaction :: AccountId -> AccountId -> Money -> Transaction
completedTransaction fromId toId amt =
  applyEvents
    [ TransactionPostingInitiatedTransactionEvent
        $ TransactionPostingInitiated
          { sourceAccountId = fromId,
            targetAccountId = toId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = testUserId,
            at = mockTime,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          },
      TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
    ]

-- | Create failed transaction
failedTransaction :: AccountId -> AccountId -> Money -> Transaction
failedTransaction fromId toId amt =
  applyEvents
    [ TransactionPostingInitiatedTransactionEvent
        $ TransactionPostingInitiated
          { sourceAccountId = fromId,
            targetAccountId = toId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = testUserId,
            at = mockTime,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          },
      TransactionPostingFailedTransactionEvent $ TransactionPostingFailed "Insufficient funds"
    ]

-- -----------------------------------------------------------------------------
-- InitiateTransactionPosting Tests
-- -----------------------------------------------------------------------------

initiateTransferSpec :: Spec
initiateTransferSpec = describe "InitiateTransactionPosting Command" $ do
  context "Given empty transaction" $ do
    describe "When initiating valid transfer" $ do
      it "Then emits TransactionPostingInitiated event" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransactionPostingTransactionCommand
                $ InitiateTransactionPosting
                  { sourceAccountId = fromId,
                    targetAccountId = toId,
                    sourceAmount = mockMoney 500,
                    targetAmount = mockMoney 500,
                    exchangeRate = Nothing,
                    description = "Payment",
                    initiatedBy = testUserId,
                    at = mockTime,
                    transactionType = Transfer,
                    importInfo = Nothing,
                    labels = Set.empty,
                    contactId = Nothing,
                    relation = Nothing
                  }
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TransactionPostingInitiatedTransactionEvent initiated -> do
                initiated.sourceAccountId `shouldBe` fromId
                initiated.targetAccountId `shouldBe` toId
                initiated.sourceAmount `shouldBe` mockMoney 500
                initiated.description `shouldBe` "Payment"
              _ -> expectationFailure "Expected TransactionPostingInitiated event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then emits TransactionPostingInitiated carrying labels and import info when both are set" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        lbl1 <- mockDictionaryEntryId <$> UUID.nextRandom
        lbl2 <- mockDictionaryEntryId <$> UUID.nextRandom
        let transaction = emptyTransaction
            extTxId = unsafeExternalTransactionId "mono:stmt-42"
            labels = Set.fromList [lbl1, lbl2]
        let command =
              InitiateTransactionPostingTransactionCommand
                $ InitiateTransactionPosting
                  { sourceAccountId = fromId,
                    targetAccountId = toId,
                    sourceAmount = mockMoney 500,
                    targetAmount = mockMoney 500,
                    exchangeRate = Nothing,
                    description = "Bank import",
                    initiatedBy = testUserId,
                    at = mockTime,
                    transactionType = Transfer,
                    importInfo = Just ImportInfo {externalTransactionIds = extTxId :| [], category = Nothing, contact = Nothing},
                    labels = labels,
                    contactId = Nothing,
                    relation = Nothing
                  }
        case handleTransactionCommand transaction command of
          Right events -> case head events of
            TransactionPostingInitiatedTransactionEvent initiated -> do
              (importInfoExternalTransactionIds <$> initiated.importInfo) `shouldBe` Just (extTxId :| [])
              initiated.labels `shouldBe` labels
            _ -> expectationFailure "Expected TransactionPostingInitiated event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then transaction status becomes Pending" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransactionPostingTransactionCommand
                $ InitiateTransactionPosting
                  { sourceAccountId = fromId,
                    targetAccountId = toId,
                    sourceAmount = mockMoney 500,
                    targetAmount = mockMoney 500,
                    exchangeRate = Nothing,
                    description = "Test",
                    initiatedBy = testUserId,
                    at = mockTime,
                    transactionType = Transfer,
                    importInfo = Nothing,
                    labels = Set.empty,
                    contactId = Nothing,
                    relation = Nothing
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
              InitiateTransactionPostingTransactionCommand
                $ InitiateTransactionPosting
                  { sourceAccountId = accountId,
                    targetAccountId = accountId,
                    sourceAmount = mockMoney 500,
                    targetAmount = mockMoney 500,
                    exchangeRate = Nothing,
                    description = "Self-transfer",
                    initiatedBy = testUserId,
                    at = mockTime,
                    transactionType = Transfer,
                    importInfo = Nothing,
                    labels = Set.empty,
                    contactId = Nothing,
                    relation = Nothing
                  }
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

    describe "When amount is zero or negative" $ do
      it "Then rejects command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = emptyTransaction
        let command =
              InitiateTransactionPostingTransactionCommand
                $ InitiateTransactionPosting
                  { sourceAccountId = fromId,
                    targetAccountId = toId,
                    sourceAmount = mockMoney 0,
                    targetAmount = mockMoney 0,
                    exchangeRate = Nothing,
                    description = "Zero transfer",
                    initiatedBy = testUserId,
                    at = mockTime,
                    transactionType = Transfer,
                    importInfo = Nothing,
                    labels = Set.empty,
                    contactId = Nothing,
                    relation = Nothing
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
              InitiateTransactionPostingTransactionCommand
                $ InitiateTransactionPosting
                  { sourceAccountId = fromId2,
                    targetAccountId = toId2,
                    sourceAmount = mockMoney 200,
                    targetAmount = mockMoney 200,
                    exchangeRate = Nothing,
                    description = "Second attempt",
                    initiatedBy = testUserId,
                    at = mockTime,
                    transactionType = Transfer,
                    importInfo = Nothing,
                    labels = Set.empty,
                    contactId = Nothing,
                    relation = Nothing
                  }
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- CompleteTransactionPosting Tests
-- -----------------------------------------------------------------------------

completeTransferSpec :: Spec
completeTransferSpec = describe "CompleteTransactionPosting Command" $ do
  context "Given pending transaction" $ do
    describe "When completing transfer" $ do
      it "Then emits TransactionPostingCompleted event" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = CompleteTransactionPostingTransactionCommand CompleteTransactionPosting
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TransactionPostingCompletedTransactionEvent _ -> pure ()
              _ -> expectationFailure "Expected TransactionPostingCompleted event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then transaction status becomes Completed" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = CompleteTransactionPostingTransactionCommand CompleteTransactionPosting
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            let newTransaction = applyEvents $ [TransactionPostingInitiatedTransactionEvent $ TransactionPostingInitiated fromId toId (mockMoney 500) (mockMoney 500) Nothing "Test" testUserId mockTime Transfer Nothing Set.empty Nothing] <> events
            newTransaction ^. #status `shouldBe` Completed
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given completed transaction" $ do
    describe "When attempting to complete again" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = completedTransaction fromId toId (mockMoney 500)
        let command = CompleteTransactionPostingTransactionCommand CompleteTransactionPosting
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

  context "Given failed transaction" $ do
    describe "When attempting to complete" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = failedTransaction fromId toId (mockMoney 500)
        let command = CompleteTransactionPostingTransactionCommand CompleteTransactionPosting
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- FailTransactionPosting Tests
-- -----------------------------------------------------------------------------

failTransferSpec :: Spec
failTransferSpec = describe "FailTransactionPosting Command" $ do
  context "Given pending transaction" $ do
    describe "When failing transfer" $ do
      it "Then emits TransactionPostingFailed event" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = FailTransactionPostingTransactionCommand $ FailTransactionPosting "Insufficient funds"
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TransactionPostingFailedTransactionEvent failed ->
                failed.reason `shouldBe` "Insufficient funds"
              _ -> expectationFailure "Expected TransactionPostingFailed event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then transaction status becomes Failed" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = pendingTransaction fromId toId (mockMoney 500)
        let command = FailTransactionPostingTransactionCommand $ FailTransactionPosting "Error"
        let result = handleTransactionCommand transaction command

        case result of
          Right events -> do
            let newTransaction = applyEvents $ [TransactionPostingInitiatedTransactionEvent $ TransactionPostingInitiated fromId toId (mockMoney 500) (mockMoney 500) Nothing "Test" testUserId mockTime Transfer Nothing Set.empty Nothing] <> events
            newTransaction ^. #status `shouldBe` Failed "Error"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given completed transaction" $ do
    describe "When attempting to fail" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = completedTransaction fromId toId (mockMoney 500)
        let command = FailTransactionPostingTransactionCommand $ FailTransactionPosting "Too late"
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft

  context "Given failed transaction" $ do
    describe "When attempting to fail again" $ do
      it "Then ignores command (no events)" $ do
        fromId <- mockAccountId <$> UUID.nextRandom
        toId <- mockAccountId <$> UUID.nextRandom
        let transaction = failedTransaction fromId toId (mockMoney 500)
        let command = FailTransactionPostingTransactionCommand $ FailTransactionPosting "Another failure"
        let result = handleTransactionCommand transaction command

        result `shouldSatisfy` isLeft
