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
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreditAccount (..), DebitAccount (..))
import Domain.Account.Events
  ( AccountCredited (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( Currency (..),
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
import Eventium (EventMetadata (..), ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import qualified Eventium (EventMetadata (occurredAt))
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
          { sourceAccountId = unsafeAccountId sourceAcctUuid,
            targetAccountId = unsafeAccountId targetAcctUuid,
            sourceAmount = unsafeMoney USD 200,
            targetAmount = unsafeMoney USD 200,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = unsafeUserId userUuid,
            transferType = Transfer
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
          { amount = unsafeMoney USD 200,
            transactionId = unsafeTransactionId txUuid,
            description = "Test transfer"
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
          { amount = unsafeMoney USD 200,
            transactionId = unsafeTransactionId txUuid,
            description = "Test transfer"
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
          td.sourceAmount `shouldBe` unsafeMoney USD 200
          td.description `shouldBe` "Test transfer"

    it "issues DebitAccount effect with compensation to source account" $ do
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          effects = reactToTransferEvent stateAfterInit mkTransferInitiatedEvent
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation targetId cmd _ onFailure] -> do
          targetId `shouldBe` sourceAcctUuid
          case cmd of
            DebitAccountCommand (DebitAccount amt txId rsn) -> do
              amt `shouldBe` unsafeMoney USD 200
              txId `shouldBe` unsafeTransactionId txUuid
              rsn `shouldBe` "Test transfer"
            other -> expectationFailure $ "Expected DebitAccountCommand, got: " ++ show other
          -- Verify compensation produces FailTransfer
          let compensationEffects = onFailure (RejectionReason "Insufficient funds")
          length compensationEffects `shouldBe` 1
          case compensationEffects of
            [IssueCommand failTarget failCmd _] -> do
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
                    { sourceAccountId = unsafeAccountId sourceAcctUuid,
                      targetAccountId = unsafeAccountId targetAcctUuid,
                      sourceAmount = unsafeMoney USD 100,
                      targetAmount = unsafeMoney USD 100,
                      exchangeRate = Nothing,
                      description = "Bad",
                      by = unsafeUserId userUuid,
                      transferType = Transfer
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
        [IssueCommand creditTarget creditCmd _, IssueCommand completeTarget completeCmd _] -> do
          -- First effect: CreditAccount to target
          creditTarget `shouldBe` targetAcctUuid
          case creditCmd of
            CreditAccountCommand (CreditAccount amt txId rsn) -> do
              amt `shouldBe` unsafeMoney USD 200
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

  describe "occurredAt Propagation" $ do
    it "propagates occurredAt from TransferInitiated to saga effects" $ do
      let pastTime = UTCTime (fromGregorian 2025 3 15) 0
          metadata = (emptyMetadata "") {Eventium.occurredAt = Just pastTime}
          event =
            StreamEvent
              txUuid
              0
              metadata
              ( TransferInitiatedEvent
                  TransferInitiated
                    { sourceAccountId = unsafeAccountId sourceAcctUuid,
                      targetAccountId = unsafeAccountId targetAcctUuid,
                      sourceAmount = unsafeMoney USD 200,
                      targetAmount = unsafeMoney USD 200,
                      exchangeRate = Nothing,
                      description = "Backdated transfer",
                      by = unsafeUserId userUuid,
                      transferType = Transfer
                    }
              )
          stateAfterInit = handleTransferEvent emptyTransferManager event
          effects = reactToTransferEvent stateAfterInit event
      case effects of
        [IssueCommandWithCompensation _ _ enricher onFailure] -> do
          (enricher (emptyMetadata "test")).occurredAt `shouldBe` Just pastTime
          -- Compensation effects should also carry the enricher
          let compensationEffects = onFailure (RejectionReason "Insufficient funds")
          case compensationEffects of
            [IssueCommand _ _ compEnricher] ->
              (compEnricher (emptyMetadata "test")).occurredAt `shouldBe` Just pastTime
            _ -> expectationFailure "Expected exactly 1 compensation effect"
        _ -> expectationFailure $ "Expected IssueCommandWithCompensation, got " ++ show (length effects) ++ " effects"

    it "propagates occurredAt from TransferData to AccountDebited reactions" $ do
      let pastTime = UTCTime (fromGregorian 2025 3 15) 0
          metadata = (emptyMetadata "") {Eventium.occurredAt = Just pastTime}
          initEvent =
            StreamEvent
              txUuid
              0
              metadata
              ( TransferInitiatedEvent
                  TransferInitiated
                    { sourceAccountId = unsafeAccountId sourceAcctUuid,
                      targetAccountId = unsafeAccountId targetAcctUuid,
                      sourceAmount = unsafeMoney USD 200,
                      targetAmount = unsafeMoney USD 200,
                      exchangeRate = Nothing,
                      description = "Backdated transfer",
                      by = unsafeUserId userUuid,
                      transferType = Transfer
                    }
              )
          stateAfterInit = handleTransferEvent emptyTransferManager initEvent
          stateAfterDebit = handleTransferEvent stateAfterInit mkAccountDebitedEvent
          effects = reactToTransferEvent stateAfterDebit mkAccountDebitedEvent
      case effects of
        [IssueCommand _ _ creditEnricher, IssueCommand _ _ completeEnricher] -> do
          (creditEnricher (emptyMetadata "test")).occurredAt `shouldBe` Just pastTime
          (completeEnricher (emptyMetadata "test")).occurredAt `shouldBe` Just pastTime
        _ -> expectationFailure $ "Expected 2 IssueCommand effects, got " ++ show (length effects)

    it "uses id enricher when occurredAt is Nothing" $ do
      let stateAfterInit = handleTransferEvent emptyTransferManager mkTransferInitiatedEvent
          effects = reactToTransferEvent stateAfterInit mkTransferInitiatedEvent
      case effects of
        [IssueCommandWithCompensation _ _ enricher _] ->
          (enricher (emptyMetadata "test")).occurredAt `shouldBe` Nothing
        _ -> expectationFailure "Expected IssueCommandWithCompensation"
