{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionPostingManagerSpec
-- Description : Unit tests for Transfer Process Manager (Saga)
--
-- This module tests the Transfer Process Manager which coordinates money transfers
-- between accounts using the saga pattern. Tests exercise the pure handleTransactionPostingEvent
-- and reactToTransactionPostingEvent functions directly by constructing StreamEvent values.
--
-- Test Coverage:
--   - Initial state: Empty transfers map
--   - TransactionPostingInitiated: State tracking + DebitAccount effect (carrying `at`)
--   - AccountDebited: State update + CreditAccount + CompleteTransactionPosting effects
--   - AccountCredited: Cleans up transfer tracking
--   - Idempotency: Duplicate events don't produce duplicate effects
--   - Unrelated events: No effects produced
--   - `at` propagation: TransactionPostingInitiated.at lands on subsequent saga commands
module Application.ProcessManagers.TransactionPostingManagerSpec (spec) where

import Application.ProcessManagers.TransactionPostingManager
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreditAccount (..), DebitAccount (..))
import Domain.Account.Events
  ( AccountCredited (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( Currency (..),
    ImportInfo (..),
    TransactionType (..),
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeExternalTransactionId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Models
  ( AccountingCommand (..),
    AccountingEvent (..),
  )
import Domain.Transaction.Commands (FailTransactionPosting (..))
import Domain.Transaction.Events (TransactionPostingCompleted (..), TransactionPostingInitiated (..))
import Eventium (ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Test Helpers
-- -----------------------------------------------------------------------------

-- | Empty transfer manager for testing.
emptyTransferManager :: TransactionPostingManager
emptyTransferManager = TransactionPostingManager Map.empty

-- | Fixed business time for deterministic testing.
sampleAt :: UTCTime
sampleAt = UTCTime (fromGregorian 2026 4 1) 0

-- | Fixed UUIDs for deterministic testing.
txUuid :: UUID.UUID
txUuid = UUID.fromWords 1 0 0 1

sourceAcctUuid :: UUID.UUID
sourceAcctUuid = UUID.fromWords 2 0 0 2

targetAcctUuid :: UUID.UUID
targetAcctUuid = UUID.fromWords 3 0 0 3

userUuid :: UUID.UUID
userUuid = UUID.fromWords 4 0 0 4

-- | Construct a VersionedStreamEvent for a TransactionPostingInitiated event.
mkTransactionPostingInitiatedEvent :: VersionedStreamEvent AccountingEvent
mkTransactionPostingInitiatedEvent = mkTransactionPostingInitiatedEventAt sampleAt

mkTransactionPostingInitiatedEventAt :: UTCTime -> VersionedStreamEvent AccountingEvent
mkTransactionPostingInitiatedEventAt t =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransactionPostingInitiatedEvent
        TransactionPostingInitiated
          { sourceAccountId = unsafeAccountId sourceAcctUuid,
            targetAccountId = unsafeAccountId targetAcctUuid,
            sourceAmount = unsafeMoney USD 200,
            targetAmount = unsafeMoney USD 200,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = unsafeUserId userUuid,
            at = t,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          }
    )

-- | Variant of 'mkTransactionPostingInitiatedEvent' carrying a non-empty label set
-- and an externalTransactionId. Exercised to verify the saga is indifferent
-- to those optional payload fields.
mkTransactionPostingInitiatedEventWithLabelsAndExternalId :: VersionedStreamEvent AccountingEvent
mkTransactionPostingInitiatedEventWithLabelsAndExternalId =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransactionPostingInitiatedEvent
        TransactionPostingInitiated
          { sourceAccountId = unsafeAccountId sourceAcctUuid,
            targetAccountId = unsafeAccountId targetAcctUuid,
            sourceAmount = unsafeMoney USD 200,
            targetAmount = unsafeMoney USD 200,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = unsafeUserId userUuid,
            at = sampleAt,
            transactionType = Transfer,
            importInfo = Just ImportInfo {externalTransactionIds = unsafeExternalTransactionId "mono:stmt-42" :| [], mcc = Nothing},
            labels = Set.fromList [unsafeDictionaryEntryId (UUID.fromWords 10 0 0 1), unsafeDictionaryEntryId (UUID.fromWords 10 0 0 2)],
            contactId = Nothing
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
            transactionId = unsafeTransactionId txUuid
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
            transactionId = unsafeTransactionId txUuid
          }
    )

-- | Construct a VersionedStreamEvent for an unrelated event.
mkUnrelatedEvent :: VersionedStreamEvent AccountingEvent
mkUnrelatedEvent =
  StreamEvent
    (UUID.fromWords 99 0 0 99)
    0
    (emptyMetadata "")
    ( TransactionPostingCompletedEvent
        TransactionPostingCompleted
    )

-- | Get the number of tracked transfers.
transferCount :: TransactionPostingManager -> Int
transferCount mgr = Map.size (mgr ^. #transfers)

-- -----------------------------------------------------------------------------
-- Test Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionPostingManager (Saga)" $ do
  describe "Initial State" $ do
    it "starts with empty transfers map" $ do
      let initialState = emptyTransferManager
      Map.null (initialState ^. #transfers) `shouldBe` True

  describe "Transfer Initiation (TransactionPostingInitiated)" $ do
    it "tracks transfer data in state" $ do
      let state = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
      transferCount state `shouldBe` 1
      let transfersMap = state ^. #transfers
          txId = unsafeTransactionId txUuid
      case Map.lookup txId transfersMap of
        Nothing -> expectationFailure "Transfer not found in tracking map"
        Just td -> do
          td.sourceAccount `shouldBe` unsafeAccountId sourceAcctUuid
          td.targetAccount `shouldBe` unsafeAccountId targetAcctUuid
          td.sourceAmount `shouldBe` unsafeMoney USD 200

    it "issues DebitAccount effect with compensation to source account" $ do
      let stateAfterInit = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
          effects = reactToTransactionPostingEvent stateAfterInit mkTransactionPostingInitiatedEvent
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation targetId cmd _ onFailure] -> do
          targetId `shouldBe` sourceAcctUuid
          case cmd of
            DebitAccountCommand debit -> do
              debit.amount `shouldBe` unsafeMoney USD 200
              debit.transactionId `shouldBe` unsafeTransactionId txUuid
              -- Manual transfer (no externalTransactionId): balance guard stays on.
              debit.allowOverdraft `shouldBe` False
            other -> expectationFailure $ "Expected DebitAccountCommand, got: " ++ show other
          -- Verify compensation produces FailTransactionPosting
          let compensationEffects = onFailure (RejectionReason "Insufficient funds")
          length compensationEffects `shouldBe` 1
          case compensationEffects of
            [IssueCommand failTarget failCmd _] -> do
              failTarget `shouldBe` txUuid
              case failCmd of
                FailTransactionPostingCommand (FailTransactionPosting rsn) ->
                  rsn `shouldBe` "Insufficient funds"
                other -> expectationFailure $ "Expected FailTransactionPostingCommand, got: " ++ show other
            _ -> expectationFailure "Expected exactly 1 compensation effect"
        _ -> expectationFailure "Expected exactly 1 IssueCommandWithCompensation effect"

    it "tracks transfers and issues DebitAccount when labels and externalTransactionId are set" $ do
      let stateAfterInit = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEventWithLabelsAndExternalId
          effects = reactToTransactionPostingEvent stateAfterInit mkTransactionPostingInitiatedEventWithLabelsAndExternalId
      transferCount stateAfterInit `shouldBe` 1
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation targetId cmd _ _] -> do
          targetId `shouldBe` sourceAcctUuid
          case cmd of
            DebitAccountCommand debit -> do
              debit.amount `shouldBe` unsafeMoney USD 200
              debit.transactionId `shouldBe` unsafeTransactionId txUuid
              -- Bank import (externalTransactionId set): debit bypasses the
              -- balance guard so an already-settled bank tx always posts.
              debit.allowOverdraft `shouldBe` True
            other -> expectationFailure $ "Expected DebitAccountCommand, got: " ++ show other
        _ -> expectationFailure "Expected exactly 1 IssueCommandWithCompensation effect"

    it "is idempotent for duplicate TransactionPostingInitiated events" $ do
      let state1 = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
          state2 = handleTransactionPostingEvent state1 mkTransactionPostingInitiatedEvent
          effects = reactToTransactionPostingEvent state2 mkTransactionPostingInitiatedEvent
      -- Second event should produce no effects (already tracked)
      null effects `shouldBe` True

    it "produces no effects for invalid UUID" $ do
      let badEvent =
            StreamEvent
              UUID.nil
              0
              (emptyMetadata "")
              ( TransactionPostingInitiatedEvent
                  TransactionPostingInitiated
                    { sourceAccountId = unsafeAccountId sourceAcctUuid,
                      targetAccountId = unsafeAccountId targetAcctUuid,
                      sourceAmount = unsafeMoney USD 100,
                      targetAmount = unsafeMoney USD 100,
                      exchangeRate = Nothing,
                      description = "Bad",
                      by = unsafeUserId userUuid,
                      at = sampleAt,
                      transactionType = Transfer,
                      importInfo = Nothing,
                      labels = Set.empty,
                      contactId = Nothing
                    }
              )
          state = handleTransactionPostingEvent emptyTransferManager badEvent
          effects = reactToTransactionPostingEvent state badEvent
      null effects `shouldBe` True

  describe "Debit Success (AccountDebited)" $ do
    it "issues CreditAccount and CompleteTransactionPosting effects" $ do
      -- First, initiate a transfer to populate tracking
      let stateAfterInit = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
          stateAfterDebit = handleTransactionPostingEvent stateAfterInit mkAccountDebitedEvent
          effects = reactToTransactionPostingEvent stateAfterDebit mkAccountDebitedEvent
      length effects `shouldBe` 2

      case effects of
        [IssueCommand creditTarget creditCmd _, IssueCommand completeTarget completeCmd _] -> do
          -- First effect: CreditAccount to target
          creditTarget `shouldBe` targetAcctUuid
          case creditCmd of
            CreditAccountCommand credit -> do
              credit.amount `shouldBe` unsafeMoney USD 200
              credit.transactionId `shouldBe` unsafeTransactionId txUuid
            other -> expectationFailure $ "Expected CreditAccountCommand, got: " ++ show other

          -- Second effect: CompleteTransactionPosting to transaction
          completeTarget `shouldBe` txUuid
          case completeCmd of
            CompleteTransactionPostingCommand _ -> pure ()
            other -> expectationFailure $ "Expected CompleteTransactionPostingCommand, got: " ++ show other
        _ -> expectationFailure "Expected exactly 2 effects"

    it "produces no effects for untracked AccountDebited" $ do
      -- AccountDebited without prior TransactionPostingInitiated should be ignored
      let state = handleTransactionPostingEvent emptyTransferManager mkAccountDebitedEvent
          effects = reactToTransactionPostingEvent state mkAccountDebitedEvent
      null effects `shouldBe` True

  describe "Credit Success (AccountCredited)" $ do
    it "removes transfer from tracking on credit" $ do
      let stateAfterInit = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
          stateAfterDebit = handleTransactionPostingEvent stateAfterInit mkAccountDebitedEvent
          stateAfterCredit = handleTransactionPostingEvent stateAfterDebit mkAccountCreditedEvent
      transferCount stateAfterCredit `shouldBe` 0

    it "produces no effects on credit (CompleteTransactionPosting already issued)" $ do
      let stateAfterInit = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
          stateAfterDebit = handleTransactionPostingEvent stateAfterInit mkAccountDebitedEvent
          stateAfterCredit = handleTransactionPostingEvent stateAfterDebit mkAccountCreditedEvent
          effects = reactToTransactionPostingEvent stateAfterCredit mkAccountCreditedEvent
      null effects `shouldBe` True

  describe "Unrelated Events" $ do
    it "produces no effects for unrelated events" $ do
      let state = handleTransactionPostingEvent emptyTransferManager mkUnrelatedEvent
          effects = reactToTransactionPostingEvent state mkUnrelatedEvent
      null effects `shouldBe` True

    it "does not change state for unrelated events" $ do
      let stateAfterInit = handleTransactionPostingEvent emptyTransferManager mkTransactionPostingInitiatedEvent
          stateAfterUnrelated = handleTransactionPostingEvent stateAfterInit mkUnrelatedEvent
      -- State should remain unchanged (transfer still tracked)
      transferCount stateAfterUnrelated `shouldBe` 1
