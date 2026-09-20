{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.ReconciliationCommandHandlerSpec
-- Description : Unit tests for the ReconcileTransactionImport command handler
--
-- Covers attaching import attribution onto an existing completed manual
-- transaction via 'ReconcileTransactionImport', including the state guards:
--   - Completed (not-yet-reconciled) → emits 'TransactionImportReconciled'
--   - non-Completed → 'CannotEditUncompletedTransaction'
--   - capacity exhausted → 'TransactionAlreadyReconciled'
--
-- Attribution capacity comes from 'importAttributionCapacity' and is counted in
-- external IDS, not attach events: an income/expense admits one, a transfer two
-- (one per leg). The capacity cases below pin both boundaries, and the
-- whole-pair case pins that a single two-id attach exhausts a transfer just as
-- two single-id attaches do.
module Domain.Transaction.ReconciliationCommandHandlerSpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Domain.Banking.Import (ExternalTransactionId, unsafeExternalTransactionId)
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact, mkByMcc, unsafeBankProviderContact, unsafeMcc)
import Domain.Core.Types
import Domain.Transaction
import Eventium (latestProjection)
import RIO
import Test.Hspec
import Testkit.Generators ()
import Testkit.Helpers

-- | Fixed business time used for all fixtures.
mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

-- | Apply events to get transaction state.
applyEvents :: [TransactionEvent] -> Transaction
applyEvents = latestProjection transactionProjection

-- | A Completed transaction of the given type between the two given accounts.
-- The type is what determines import-attribution capacity, so the capacity
-- cases pick it deliberately.
completedTransactionOfType :: TransactionType -> AccountId -> AccountId -> Money -> Transaction
completedTransactionOfType txType fromId toId amt =
  applyEvents
    [ TransactionPostingInitiatedTransactionEvent
        $ TransactionPostingInitiated
          { sourceAccountId = fromId,
            targetAccountId = toId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = mockUserIdN 1,
            at = mockTime,
            transactionType = txType,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          },
      TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
    ]

-- | A Completed transfer between the two given accounts — capacity 2, one
-- attribution per leg.
completedTransaction :: AccountId -> AccountId -> Money -> Transaction
completedTransaction = completedTransactionOfType Transfer

-- | A Completed expense between the two given accounts — capacity 1, the shape
-- every income/expense import reconciliation targets.
completedExpense :: AccountId -> AccountId -> Money -> Transaction
completedExpense fromId toId amt =
  completedTransactionOfType (singletonExpense (mockCategoryIdN 1) amt) fromId toId amt

-- | Fold one import attach carrying the given external ids onto a transaction,
-- so the capacity cases can build up attribution a leg at a time.
attachIds :: NonEmpty ExternalTransactionId -> Transaction -> Transaction
attachIds ids transaction =
  handleTransactionEvent
    transaction
    ( TransactionImportReconciledTransactionEvent
        TransactionImportReconciled
          { transactionId = txId,
            externalTransactionIds = ids,
            category = Just mockCategory,
            contact = Nothing
          }
    )

fromAccount :: AccountId
fromAccount = mockAccountIdN 1

toAccount :: AccountId
toAccount = mockAccountIdN 2

txId :: TransactionId
txId = mockTransactionIdN 1

extId :: ExternalTransactionId
extId = unsafeExternalTransactionId "mono:stmt-42"

-- | The opposite leg's id, for the two-attach transfer cases.
extId2 :: ExternalTransactionId
extId2 = unsafeExternalTransactionId "mono:stmt-43"

mockCategory :: BankProviderCategory
mockCategory = mkByMcc (unsafeMcc 5411)

mockContact :: BankProviderContact
mockContact = unsafeBankProviderContact "Магазин РЕМОНТІ"

reconcileCommand :: TransactionCommand
reconcileCommand =
  ReconcileTransactionImportTransactionCommand
    $ ReconcileTransactionImport
      { transactionId = txId,
        externalTransactionIds = extId :| [],
        category = Just mockCategory,
        contact = Just mockContact
      }

spec :: Spec
spec = describe "ReconcileTransactionImport Command" $ do
  context "Given a Completed, not-yet-reconciled transaction"
    $ it "Then emits a single TransactionImportReconciled event"
    $ do
      let transaction = completedTransaction fromAccount toAccount (mockMoney 500)
      handleTransactionCommand transaction reconcileCommand
        `shouldBe` Right
          [ TransactionImportReconciledTransactionEvent
              TransactionImportReconciled
                { transactionId = txId,
                  externalTransactionIds = extId :| [],
                  category = Just mockCategory,
                  contact = Just mockContact
                }
          ]

  context "Given a non-Completed transaction"
    $ it "Then rejects with CannotEditUncompletedTransaction"
    $ do
      let transaction = applyEvents [] -- default Pending state
      handleTransactionCommand transaction reconcileCommand
        `shouldBe` Left CannotEditUncompletedTransaction

  -- A capacity-1 transaction still reconciles exactly once. This is the
  -- invariant the original already-reconciled case protected; it was written
  -- against a Transfer fixture before capacity existed, and a transfer now
  -- legitimately admits a second leg, so the assertion moves to an expense
  -- rather than being dropped.
  context "Given an already-reconciled Completed expense (capacity 1)"
    $ it "Then rejects with TransactionAlreadyReconciled"
    $ do
      let reconciled = attachIds (extId :| []) (completedExpense fromAccount toAccount (mockMoney 500))
      handleTransactionCommand reconciled reconcileCommand
        `shouldBe` Left TransactionAlreadyReconciled

  -- The capacity-2 boundary, from both sides.
  context "Given a Completed transfer with one leg attached (capacity 2)"
    $ it "Then admits the opposite leg"
    $ do
      let oneLeg = attachIds (extId :| []) (completedTransaction fromAccount toAccount (mockMoney 500))
      handleTransactionCommand oneLeg reconcileCommand
        `shouldBe` Right
          [ TransactionImportReconciledTransactionEvent
              TransactionImportReconciled
                { transactionId = txId,
                  externalTransactionIds = extId :| [],
                  category = Just mockCategory,
                  contact = Just mockContact
                }
          ]

  context "Given a Completed transfer with both legs attached"
    $ it "Then rejects the third attach with TransactionAlreadyReconciled"
    $ do
      let bothLegs =
            attachIds (extId2 :| [])
              $ attachIds (extId :| []) (completedTransaction fromAccount toAccount (mockMoney 500))
      handleTransactionCommand bothLegs reconcileCommand
        `shouldBe` Left TransactionAlreadyReconciled

  -- Capacity counts IDS, not attach events: the whole-pair import path attaches
  -- both legs in one event, and that must exhaust the transfer exactly as two
  -- single-leg attaches do. Counting events would leave a free slot here.
  context "Given a Completed transfer attributed by one two-id attach"
    $ it "Then rejects a further attach with TransactionAlreadyReconciled"
    $ do
      let wholePair = attachIds (extId :| [extId2]) (completedTransaction fromAccount toAccount (mockMoney 500))
      handleTransactionCommand wholePair reconcileCommand
        `shouldBe` Left TransactionAlreadyReconciled
