{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.CommandHandlerPropertySpec
-- Description : Property-based tests for Transaction command handler
--
-- This module tests mathematical properties and invariants of the Transaction
-- aggregate command handler using QuickCheck.
--
-- Test Coverage:
--   - Determinism: Same input produces same output
--   - State machine: Valid transitions only
--   - Idempotency: Multiple commands don't change terminal states
--   - Validation: Business rules enforcement
module Domain.Transaction.CommandHandlerPropertySpec (spec) where

import Data.Either (fromRight, isLeft)
import Domain.Core.Types
import Domain.Transaction
import Domain.Transaction.CommandHandler
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators ()
import Testkit.Helpers
import Prelude (read)

spec :: Spec
spec = do
  determinismSpec
  stateMachineSpec
  validationSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get transaction state
applyEvents :: [TransactionEvent] -> Transaction
applyEvents = latestProjection transactionProjection

-- | Test user ID for initiating transfers
testUserId :: UserId
testUserId = mockUserId (read "11111111-1111-1111-1111-111111111111")

-- | Create a pending transaction
createPendingTransaction :: AccountId -> AccountId -> Money -> Transaction
createPendingTransaction fromId toId amt =
  applyEvents
    [ TransferInitiatedTransactionEvent
        $ TransferInitiated
          { fromAccountId = fromId,
            toAccountId = toId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            reason = "Test transfer",
            by = testUserId,
            transferType = InternalTransfer,
            category = InternalCat InternalOther
          }
    ]

-- -----------------------------------------------------------------------------
-- Determinism Properties
-- -----------------------------------------------------------------------------

determinismSpec :: Spec
determinismSpec = describe "Determinism Properties" $ do
  describe "When handling commands" $ do
    it "Then InitiateTransfer produces same events"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) ->
        fromId /= toId && unMoney amt > 0 ==>
          let transaction = applyEvents []
              command = InitiateTransferTransactionCommand $ InitiateTransfer fromId toId amt amt Nothing rsn testUserId InternalTransfer (InternalCat InternalOther)
              events1 = handleTransactionCommand transaction command
              events2 = handleTransactionCommand transaction command
           in events1 === events2

    it "Then CompleteTransfer produces same events"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              command = CompleteTransferTransactionCommand CompleteTransfer
              events1 = handleTransactionCommand transaction command
              events2 = handleTransactionCommand transaction command
           in events1 === events2

    it "Then FailTransfer produces same events"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              command = FailTransferTransactionCommand $ FailTransfer rsn
              events1 = handleTransactionCommand transaction command
              events2 = handleTransactionCommand transaction command
           in events1 === events2

-- -----------------------------------------------------------------------------
-- State Machine Properties
-- -----------------------------------------------------------------------------

stateMachineSpec :: Spec
stateMachineSpec = describe "State Machine Properties" $ do
  describe "Terminal state immutability" $ do
    it "Then Completed transaction ignores all commands"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let initialEvents =
                [ TransferInitiatedTransactionEvent $ TransferInitiated fromId toId amt amt Nothing "Test" testUserId InternalTransfer (InternalCat InternalOther),
                  TransferCompletedTransactionEvent TransferCompleted
                ]
              transaction = applyEvents initialEvents

              -- Try to complete again
              result1 = handleTransactionCommand transaction (CompleteTransferTransactionCommand CompleteTransfer)

              -- Try to fail
              result2 = handleTransactionCommand transaction (FailTransferTransactionCommand $ FailTransfer "Too late")
           in isLeft result1 .&&. isLeft result2

    it "Then Failed transaction ignores all commands"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let initialEvents =
                [ TransferInitiatedTransactionEvent $ TransferInitiated fromId toId amt amt Nothing "Test" testUserId InternalTransfer (InternalCat InternalOther),
                  TransferFailedTransactionEvent $ TransferFailed "Error"
                ]
              transaction = applyEvents initialEvents

              -- Try to complete
              result1 = handleTransactionCommand transaction (CompleteTransferTransactionCommand CompleteTransfer)

              -- Try to fail again
              result2 = handleTransactionCommand transaction (FailTransferTransactionCommand $ FailTransfer "Another error")
           in isLeft result1 .&&. isLeft result2

  describe "Valid transitions" $ do
    it "Then Pending can transition to Completed"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              result = handleTransactionCommand transaction (CompleteTransferTransactionCommand CompleteTransfer)
           in case result of
                Right [TransferCompletedTransactionEvent _] -> property True
                _ -> property False

    it "Then Pending can transition to Failed"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              result = handleTransactionCommand transaction (FailTransferTransactionCommand $ FailTransfer rsn)
           in case result of
                Right [TransferFailedTransactionEvent _] -> property True
                _ -> property False

  describe "Status tracking" $ do
    it "Then new transaction starts in default state"
      $ property
      $ \(_ :: ()) ->
        let transaction = applyEvents []
         in transaction ^. #status === Pending
              .&&. unMoney (transaction ^. #sourceAmount) === 0

    it "Then initiated transaction is Pending"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId && unMoney amt > 0 ==>
          let transaction = createPendingTransaction fromId toId amt
           in transaction ^. #status === Pending

-- -----------------------------------------------------------------------------
-- Validation Properties
-- -----------------------------------------------------------------------------

validationSpec :: Spec
validationSpec = describe "Validation Properties" $ do
  describe "InitiateTransfer validation" $ do
    it "Then rejects same source and target"
      $ property
      $ \(accountId :: AccountId) (amt :: Money) ->
        unMoney amt > 0 ==>
          let transaction = applyEvents []
              command = InitiateTransferTransactionCommand $ InitiateTransfer accountId accountId amt amt Nothing "Self-transfer" testUserId InternalTransfer (InternalCat InternalOther)
              result = handleTransactionCommand transaction command
           in isLeft result

    it "Then rejects zero amount"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) ->
        fromId /= toId ==>
          let transaction = applyEvents []
              command = InitiateTransferTransactionCommand $ InitiateTransfer fromId toId (mockMoney 0) (mockMoney 0) Nothing "Zero" testUserId InternalTransfer (InternalCat InternalOther)
              result = handleTransactionCommand transaction command
           in isLeft result

    it "Then accepts valid transfer"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId && unMoney amt > 0 ==>
          let transaction = applyEvents []
              command = InitiateTransferTransactionCommand $ InitiateTransfer fromId toId amt amt Nothing "Valid" testUserId InternalTransfer (InternalCat InternalOther)
              result = handleTransactionCommand transaction command
           in case result of
                Right [TransferInitiatedTransactionEvent _] -> property True
                _ -> property False

  describe "Double initialization prevention" $ do
    it "Then ignores second InitiateTransfer"
      $ property
      $ \(fromId1 :: AccountId)
         (toId1 :: AccountId)
         (amount1 :: Money)
         (fromId2 :: AccountId)
         (toId2 :: AccountId)
         (amount2 :: Money) ->
          fromId1 /= toId1 && fromId2 /= toId2 ==>
            let transaction = createPendingTransaction fromId1 toId1 amount1
                command = InitiateTransferTransactionCommand $ InitiateTransfer fromId2 toId2 amount2 amount2 Nothing "Second" testUserId InternalTransfer (InternalCat InternalOther)
                result = handleTransactionCommand transaction command
             in isLeft result
