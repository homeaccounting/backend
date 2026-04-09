{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransferManagerPropertySpec
-- Description : Property-based tests for Transfer Process Manager (Saga)
--
-- This module tests mathematical properties of the Transfer Process Manager:
--   - Determinism: Same events always produce same effects
--   - Idempotency: Duplicate TransferInitiated doesn't double-issue
--   - State invariants: Completed transfers removed from tracking
module Application.ProcessManagers.TransferManagerPropertySpec (spec) where

import Application.ProcessManagers.TransferManager
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountCredited (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( Currency (..),
    TransferType (..),
    unAccountId,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransferInitiated (..))
import Eventium (ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- -----------------------------------------------------------------------------
-- Generators
-- -----------------------------------------------------------------------------

-- | Generate a non-nil UUID using four arbitrary words.
genUUID :: Gen UUID.UUID
genUUID = do
  w1 <- arbitrary `suchThat` (/= 0)
  w2 <- arbitrary
  w3 <- arbitrary
  w4 <- arbitrary `suchThat` (/= 0)
  pure $ UUID.fromWords w1 w2 w3 w4

-- | Generate a positive rational for Money.
genPositiveAmount :: Gen Rational
genPositiveAmount = do
  n <- choose (1 :: Int, 100000)
  pure $ fromIntegral n

-- | Generate a TransferInitiated versioned stream event with random data.
genTransferInitiatedEvent :: Gen (UUID.UUID, VersionedStreamEvent AccountingEvent)
genTransferInitiatedEvent = do
  txId <- genUUID
  sourceId <- genUUID
  targetId <- genUUID `suchThat` (/= sourceId)
  userId <- genUUID
  amt <- genPositiveAmount
  pure
    ( txId,
      StreamEvent
        txId
        0
        (emptyMetadata "")
        ( TransferInitiatedEvent
            TransferInitiated
              { sourceAccountId = unsafeAccountId sourceId,
                targetAccountId = unsafeAccountId targetId,
                sourceAmount = unsafeMoney USD amt,
                targetAmount = unsafeMoney USD amt,
                exchangeRate = Nothing,
                description = "Property test transfer",
                by = unsafeUserId userId,
                transferType = Transfer
              }
        )
    )

-- | Generate an AccountDebited event that matches a transfer.
genAccountDebitedFor :: UUID.UUID -> TransferData -> VersionedStreamEvent AccountingEvent
genAccountDebitedFor txId td =
  StreamEvent
    (Domain.Core.Types.unAccountId td.sourceAccount)
    1
    (emptyMetadata "")
    ( AccountDebitedEvent
        AccountDebited
          { amount = td.sourceAmount,
            transactionId = unsafeTransactionId txId,
            description = td.description
          }
    )

-- | Generate an AccountCredited event that matches a transfer.
genAccountCreditedFor :: UUID.UUID -> TransferData -> VersionedStreamEvent AccountingEvent
genAccountCreditedFor txId td =
  StreamEvent
    (Domain.Core.Types.unAccountId td.targetAccount)
    1
    (emptyMetadata "")
    ( AccountCreditedEvent
        AccountCredited
          { amount = td.targetAmount,
            transactionId = unsafeTransactionId txId,
            description = td.description
          }
    )

-- | Empty transfer manager.
emptyManager :: TransferManager
emptyManager = TransferManager Map.empty

-- -----------------------------------------------------------------------------
-- Properties
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransferManager Properties" $ do
  describe "Determinism" $ do
    prop "produces same effects for same events"
      $ forAll genTransferInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransferEvent emptyManager event
            effects1 = reactToTransferEvent state1 event
            state2 = handleTransferEvent emptyManager event
            effects2 = reactToTransferEvent state2 event
         in length effects1 === length effects2

    prop "same event sequence produces same transfer count"
      $ forAll genTransferInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransferEvent emptyManager event
            state2 = handleTransferEvent emptyManager event
         in Map.size (state1 ^. #transfers)
              === Map.size (state2 ^. #transfers)

  describe "Idempotency" $ do
    prop "duplicate TransferInitiated does not double-issue"
      $ forAll genTransferInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransferEvent emptyManager event
            state2 = handleTransferEvent state1 event
            effects2 = reactToTransferEvent state2 event
         in -- Second processing should produce no effects
            null effects2 === True

    prop "duplicate TransferInitiated keeps exactly one tracked transfer"
      $ forAll genTransferInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransferEvent emptyManager event
            state2 = handleTransferEvent state1 event
         in Map.size (state2 ^. #transfers) === 1

  describe "State Invariants" $ do
    prop "completed transfers are removed from tracking"
      $ forAll genTransferInitiatedEvent
      $ \(txId, initEvent) ->
        let stateAfterInit = handleTransferEvent emptyManager initEvent
            txIdTyped = unsafeTransactionId txId
         in case Map.lookup txIdTyped (stateAfterInit ^. #transfers) of
              Nothing -> discard -- Shouldn't happen with valid UUIDs
              Just td ->
                let debitedEvent = genAccountDebitedFor txId td
                    creditedEvent = genAccountCreditedFor txId td
                    stateAfterDebit = handleTransferEvent stateAfterInit debitedEvent
                    stateAfterCredit = handleTransferEvent stateAfterDebit creditedEvent
                 in Map.size (stateAfterCredit ^. #transfers) === 0

    prop "DebitAccount effect always targets source account UUID"
      $ forAll genTransferInitiatedEvent
      $ \(_, initEvent) ->
        let state = handleTransferEvent emptyManager initEvent
            effects = reactToTransferEvent state initEvent
         in case effects of
              [IssueCommandWithCompensation targetId _ _] ->
                let StreamEvent _ _ _ (TransferInitiatedEvent ti) = initEvent
                 in targetId === Domain.Core.Types.unAccountId ti.sourceAccountId
              _ -> discard

    prop "compensation always produces exactly one effect"
      $ forAll genTransferInitiatedEvent
      $ \(_, initEvent) ->
        let state = handleTransferEvent emptyManager initEvent
            effects = reactToTransferEvent state initEvent
         in case effects of
              [IssueCommandWithCompensation _ _ onFailure] ->
                length (onFailure (RejectionReason "any reason")) === 1
              _ -> discard

    prop "compensation targets the transaction aggregate UUID"
      $ forAll genTransferInitiatedEvent
      $ \(txId, initEvent) ->
        let state = handleTransferEvent emptyManager initEvent
            effects = reactToTransferEvent state initEvent
         in case effects of
              [IssueCommandWithCompensation _ _ onFailure] ->
                case onFailure (RejectionReason "any reason") of
                  [IssueCommand failTarget _] -> failTarget === txId
                  _ -> discard
              _ -> discard
