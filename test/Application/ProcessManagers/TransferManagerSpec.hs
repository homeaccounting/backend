{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransferManagerSpec
-- Description : Unit tests for Transfer Process Manager (Saga)
--
-- This module tests the Transfer Process Manager which coordinates money transfers
-- between accounts using the saga pattern. Tests exercise the pure handleTransferEvent
-- and reactToTransferEvent functions directly by constructing StreamEvent values.
--
-- Test Coverage:
--   - Initial state: Empty transfers map
--   - TransferInitiated: State tracking + DebitAccount effect
--   - AccountDebited: State update + CreditAccount + CompleteTransfer effects
--   - AccountCredited: Cleans up transfer tracking
--   - Idempotency: Duplicate events don't produce duplicate effects
--   - Unrelated events: No effects produced
module Application.ProcessManagers.TransferManagerSpec (spec) where

import Application.ProcessManagers.TransferManager
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreditAccount (..), DebitAccount (..))
import Domain.Account.Events
  ( AccountCredited (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( InternalCategory (..),
    TransferCategory (..),
    TransferType (..),
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Models
  ( AccountingCommand (..),
    AccountingEvent (..),
  )
import Domain.Transaction.Commands (CompleteTransfer (..), FailTransfer (..))
import Domain.Transaction.Events (TransferCompleted (..), TransferInitiated (..))
import Eventium (ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Test Helpers
-- -----------------------------------------------------------------------------

-- | Empty transfer manager for testing.
emptyTransferManager :: TransferManager
emptyTransferManager = TransferManager Map.empty

-- | Fixed UUIDs for deterministic testing.
txUuid :: UUID.UUID
txUuid = UUID.fromWords 1 0 0 1

sourceAcctUuid :: UUID.UUID
sourceAcctUuid = UUID.fromWords 2 0 0 2

targetAcctUuid :: UUID.UUID
targetAcctUuid = UUID.fromWords 3 0 0 3

userUuid :: UUID.UUID
userUuid = UUID.fromWords 4 0 0 4

-- | Construct a VersionedStreamEvent for a TransferInitiated event.
mkTransferInitiatedEvent :: VersionedStreamEvent AccountingEvent
mkTransferInitiatedEvent =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransferInitiatedEvent
        TransferInitiated
          { fromAccountId = unsafeAccountId sourceAcctUuid,
            toAccountId = unsafeAccountId targetAcctUuid,
            amount = unsafeMoney 200,
            reason = "Test transfer",
            by = unsafeUserId userUuid,
            transferType = InternalTransfer,
            category = InternalCat InternalOther
          }
    )

-- | Construct a VersionedStreamEvent for an AccountDebited event.
mkAccountDebitedEvent :: VersionedStreamEvent AccountingEvent
mkAccountDebitedEvent =
  StreamEvent
    sourceAcctUuid
    1
    (emptyMetadata "")
    ( AccountDebitedEvent
        AccountDebited
          { amount = unsafeMoney 200,
            transactionId = unsafeTransactionId txUuid,
            reason = "Test transfer"
          }
    )

-- | Construct a VersionedStreamEvent for an AccountCredited event.
mkAccountCreditedEvent :: VersionedStreamEvent AccountingEvent
mkAccountCreditedEvent =
  StreamEvent
    targetAcctUuid
    1
    (emptyMetadata "")
    ( AccountCreditedEvent
        AccountCredited
          { amount = unsafeMoney 200,
            transactionId = unsafeTransactionId txUuid,
            reason = "Test transfer"
          }
    )

-- | Construct a VersionedStreamEvent for an unrelated event.
mkUnrelatedEvent :: VersionedStreamEvent AccountingEvent
mkUnrelatedEvent =
  StreamEvent
    (UUID.fromWords 99 0 0 99)
    0
    (emptyMetadata "")
    ( TransferCompletedEvent
        TransferCompleted
    )

-- | Get the number of tracked transfers.
transferCount :: TransferManager -> Int
transferCount mgr = Map.size (mgr ^. #transfers)

-- -----------------------------------------------------------------------------
-- Test Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransferManager (Saga)" $ do
  describe "Initial State" $ do
    it "starts with empty transfers map" $ do
      let initialState = emptyTransferManager
      Map.null (initialState ^. #transfers) `shouldBe` True

  describe "Transfer Initiation (TransferInitiated)" $ do
    it "tracks transfer data in state" $ do
      let state = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
      transferCount state `shouldBe` 1
      let transfersMap = state ^. #transfers
          txId = unsafeTransactionId txUuid
      case Map.lookup txId transfersMap of
        Nothing -> expectationFailure "Transfer not found in tracking map"
        Just td -> do
          td.sourceAccount `shouldBe` unsafeAccountId sourceAcctUuid
          td.targetAccount `shouldBe` unsafeAccountId targetAcctUuid
          td.amount `shouldBe` unsafeMoney 200
          td.reason `shouldBe` "Test transfer"

    it "issues DebitAccount effect with compensation to source account" $ do
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          effects = reactToTransferEvent stateAfterInit mkTransferInitiatedEvent
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation targetId cmd onFailure] -> do
          targetId `shouldBe` sourceAcctUuid
          case cmd of
            DebitAccountCommand (DebitAccount amt txId rsn) -> do
              amt `shouldBe` unsafeMoney 200
              txId `shouldBe` unsafeTransactionId txUuid
              rsn `shouldBe` "Test transfer"
            other -> expectationFailure $ "Expected DebitAccountCommand, got: " ++ show other
          -- Verify compensation produces FailTransfer
          let compensationEffects = onFailure (RejectionReason "Insufficient funds")
          length compensationEffects `shouldBe` 1
          case compensationEffects of
            [IssueCommand failTarget failCmd] -> do
              failTarget `shouldBe` txUuid
              case failCmd of
                FailTransferCommand (FailTransfer rsn) ->
                  rsn `shouldBe` "Insufficient funds"
                other -> expectationFailure $ "Expected FailTransferCommand, got: " ++ show other
            _ -> expectationFailure "Expected exactly 1 compensation effect"
        _ -> expectationFailure "Expected exactly 1 IssueCommandWithCompensation effect"

    it "is idempotent for duplicate TransferInitiated events" $ do
      let state1 = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          state2 = handleTransferEvent state1 mkTransferInitiatedEvent
          effects = reactToTransferEvent state2 mkTransferInitiatedEvent
      -- Second event should produce no effects (already tracked)
      null effects `shouldBe` True

    it "produces no effects for invalid UUID" $ do
      let badEvent =
            StreamEvent
              UUID.nil
              0
              (emptyMetadata "")
              ( TransferInitiatedEvent
                  TransferInitiated
                    { fromAccountId = unsafeAccountId sourceAcctUuid,
                      toAccountId = unsafeAccountId targetAcctUuid,
                      amount = unsafeMoney 100,
                      reason = "Bad",
                      by = unsafeUserId userUuid,
                      transferType = InternalTransfer,
                      category = InternalCat InternalOther
                    }
              )
          state = handleTransferEvent emptyTransferManager badEvent
          effects = reactToTransferEvent state badEvent
      null effects `shouldBe` True

  describe "Debit Success (AccountDebited)" $ do
    it "issues CreditAccount and CompleteTransfer effects" $ do
      -- First, initiate a transfer to populate tracking
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          stateAfterDebit = handleTransferEvent stateAfterInit mkAccountDebitedEvent
          effects = reactToTransferEvent stateAfterDebit mkAccountDebitedEvent
      length effects `shouldBe` 2

      case effects of
        [IssueCommand creditTarget creditCmd, IssueCommand completeTarget completeCmd] -> do
          -- First effect: CreditAccount to target
          creditTarget `shouldBe` targetAcctUuid
          case creditCmd of
            CreditAccountCommand (CreditAccount amt txId rsn) -> do
              amt `shouldBe` unsafeMoney 200
              txId `shouldBe` unsafeTransactionId txUuid
              rsn `shouldBe` "Test transfer"
            other -> expectationFailure $ "Expected CreditAccountCommand, got: " ++ show other

          -- Second effect: CompleteTransfer to transaction
          completeTarget `shouldBe` txUuid
          case completeCmd of
            CompleteTransferCommand _ -> pure ()
            other -> expectationFailure $ "Expected CompleteTransferCommand, got: " ++ show other
        _ -> expectationFailure "Expected exactly 2 effects"

    it "produces no effects for untracked AccountDebited" $ do
      -- AccountDebited without prior TransferInitiated should be ignored
      let state = handleTransferEvent emptyTransferManager mkAccountDebitedEvent
          effects = reactToTransferEvent state mkAccountDebitedEvent
      null effects `shouldBe` True

  describe "Credit Success (AccountCredited)" $ do
    it "removes transfer from tracking on credit" $ do
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          stateAfterDebit = handleTransferEvent stateAfterInit mkAccountDebitedEvent
          stateAfterCredit = handleTransferEvent stateAfterDebit mkAccountCreditedEvent
      transferCount stateAfterCredit `shouldBe` 0

    it "produces no effects on credit (CompleteTransfer already issued)" $ do
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          stateAfterDebit = handleTransferEvent stateAfterInit mkAccountDebitedEvent
          stateAfterCredit = handleTransferEvent stateAfterDebit mkAccountCreditedEvent
          effects = reactToTransferEvent stateAfterCredit mkAccountCreditedEvent
      null effects `shouldBe` True

  describe "Unrelated Events" $ do
    it "produces no effects for unrelated events" $ do
      let state = handleTransferEvent emptyTransferManager mkUnrelatedEvent
          effects = reactToTransferEvent state mkUnrelatedEvent
      null effects `shouldBe` True

    it "does not change state for unrelated events" $ do
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          stateAfterUnrelated = handleTransferEvent stateAfterInit mkUnrelatedEvent
      -- State should remain unchanged (transfer still tracked)
      transferCount stateAfterUnrelated `shouldBe` 1
