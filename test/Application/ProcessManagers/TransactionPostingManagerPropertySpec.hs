{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionPostingManagerPropertySpec
-- Description : Property-based tests for Transfer Process Manager (Saga)
--
-- This module tests mathematical properties of the Transfer Process Manager:
--   - Determinism: Same events always produce same effects
--   - Idempotency: Duplicate TransactionPostingInitiated doesn't double-issue
--   - State invariants: Completed transfers removed from tracking
module Application.ProcessManagers.TransactionPostingManagerPropertySpec (spec) where

import Application.ProcessManagers.TransactionPostingManager
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountCredited (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( Currency (..),
    TransactionType (..),
    unAccountId,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionPostingInitiated (..))
import Eventium (ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import RIO.Time (UTCTime (..), fromGregorian)
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

-- | Generate a TransactionPostingInitiated versioned stream event with random data.
genTransactionPostingInitiatedEvent :: Gen (UUID.UUID, VersionedStreamEvent AccountingEvent)
genTransactionPostingInitiatedEvent = do
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
        ( TransactionPostingInitiatedEvent
            TransactionPostingInitiated
              { sourceAccountId = unsafeAccountId sourceId,
                targetAccountId = unsafeAccountId targetId,
                sourceAmount = unsafeMoney USD amt,
                targetAmount = unsafeMoney USD amt,
                exchangeRate = Nothing,
                description = "Property test transfer",
                by = unsafeUserId userId,
                transactionType = Transfer,
                importInfo = Nothing,
                labels = Set.empty,
                at = UTCTime (fromGregorian 2026 1 1) 0
              }
        )
    )

-- | Generate an AccountDebited event that matches a transfer.
genAccountDebitedFor :: UUID.UUID -> TransactionPostingData -> VersionedStreamEvent AccountingEvent
genAccountDebitedFor txId td =
  StreamEvent
    (Domain.Core.Types.unAccountId td.sourceAccount)
    1
    (emptyMetadata "")
    ( AccountDebitedEvent
        AccountDebited
          { amount = td.sourceAmount,
            transactionId = unsafeTransactionId txId
          }
    )

-- | Generate an AccountCredited event that matches a transfer.
genAccountCreditedFor :: UUID.UUID -> TransactionPostingData -> VersionedStreamEvent AccountingEvent
genAccountCreditedFor txId td =
  StreamEvent
    (Domain.Core.Types.unAccountId td.targetAccount)
    1
    (emptyMetadata "")
    ( AccountCreditedEvent
        AccountCredited
          { amount = td.targetAmount,
            transactionId = unsafeTransactionId txId
          }
    )

-- | Empty transfer manager.
emptyManager :: TransactionPostingManager
emptyManager = TransactionPostingManager Map.empty

-- -----------------------------------------------------------------------------
-- Properties
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionPostingManager Properties" $ do
  describe "Determinism" $ do
    prop "produces same effects for same events"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransactionPostingEvent emptyManager event
            effects1 = reactToTransactionPostingEvent state1 event
            state2 = handleTransactionPostingEvent emptyManager event
            effects2 = reactToTransactionPostingEvent state2 event
         in length effects1 === length effects2

    prop "same event sequence produces same transfer count"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransactionPostingEvent emptyManager event
            state2 = handleTransactionPostingEvent emptyManager event
         in Map.size (state1 ^. #transfers)
              === Map.size (state2 ^. #transfers)

  describe "Idempotency" $ do
    prop "duplicate TransactionPostingInitiated does not double-issue"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransactionPostingEvent emptyManager event
            state2 = handleTransactionPostingEvent state1 event
            effects2 = reactToTransactionPostingEvent state2 event
         in -- Second processing should produce no effects
            null effects2 === True

    prop "duplicate TransactionPostingInitiated keeps exactly one tracked transfer"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(_, event) ->
        let state1 = handleTransactionPostingEvent emptyManager event
            state2 = handleTransactionPostingEvent state1 event
         in Map.size (state2 ^. #transfers) === 1

  describe "State Invariants" $ do
    prop "completed transfers are removed from tracking"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(txId, initEvent) ->
        let stateAfterInit = handleTransactionPostingEvent emptyManager initEvent
            txIdTyped = unsafeTransactionId txId
         in case Map.lookup txIdTyped (stateAfterInit ^. #transfers) of
              Nothing -> discard -- Shouldn't happen with valid UUIDs
              Just td ->
                let debitedEvent = genAccountDebitedFor txId td
                    creditedEvent = genAccountCreditedFor txId td
                    stateAfterDebit = handleTransactionPostingEvent stateAfterInit debitedEvent
                    stateAfterCredit = handleTransactionPostingEvent stateAfterDebit creditedEvent
                 in Map.size (stateAfterCredit ^. #transfers) === 0

    prop "DebitAccount effect always targets source account UUID"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(_, initEvent) ->
        let state = handleTransactionPostingEvent emptyManager initEvent
            effects = reactToTransactionPostingEvent state initEvent
         in case effects of
              [IssueCommandWithCompensation targetId _ _ _] ->
                case initEvent of
                  StreamEvent _ _ _ (TransactionPostingInitiatedEvent ti) ->
                    targetId === Domain.Core.Types.unAccountId ti.sourceAccountId
                  _ -> discard
              _ -> discard

    prop "compensation always produces exactly one effect"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(_, initEvent) ->
        let state = handleTransactionPostingEvent emptyManager initEvent
            effects = reactToTransactionPostingEvent state initEvent
         in case effects of
              [IssueCommandWithCompensation _ _ _ onFailure] ->
                length (onFailure (RejectionReason "any reason")) === 1
              _ -> discard

    prop "compensation targets the transaction aggregate UUID"
      $ forAll genTransactionPostingInitiatedEvent
      $ \(txId, initEvent) ->
        let state = handleTransactionPostingEvent emptyManager initEvent
            effects = reactToTransactionPostingEvent state initEvent
         in case effects of
              [IssueCommandWithCompensation _ _ _ onFailure] ->
                case onFailure (RejectionReason "any reason") of
                  [IssueCommand failTarget _ _] -> failTarget === txId
                  _ -> discard
              _ -> discard
