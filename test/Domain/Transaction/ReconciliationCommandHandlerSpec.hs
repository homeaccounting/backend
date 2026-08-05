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
--   - already-reconciled → 'TransactionAlreadyReconciled'
module Domain.Transaction.ReconciliationCommandHandlerSpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
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

-- | A Completed transfer between the two given accounts.
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
            by = mockUserIdN 1,
            at = mockTime,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty,
            contactId = Nothing
          },
      TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
    ]

fromAccount :: AccountId
fromAccount = mockAccountIdN 1

toAccount :: AccountId
toAccount = mockAccountIdN 2

txId :: TransactionId
txId = mockTransactionIdN 1

extId :: ExternalTransactionId
extId = unsafeExternalTransactionId "mono:stmt-42"

mockCategory :: BankProviderCategory
mockCategory = mkByMcc (unsafeMcc 5411)

reconcileCommand :: TransactionCommand
reconcileCommand =
  ReconcileTransactionImportTransactionCommand
    $ ReconcileTransactionImport
      { transactionId = txId,
        externalTransactionIds = extId :| [],
        category = Just mockCategory
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
                  category = Just mockCategory
                }
          ]

  context "Given a non-Completed transaction"
    $ it "Then rejects with CannotEditUncompletedTransaction"
    $ do
      let transaction = applyEvents [] -- default Pending state
      handleTransactionCommand transaction reconcileCommand
        `shouldBe` Left CannotEditUncompletedTransaction

  context "Given an already-reconciled Completed transaction"
    $ it "Then rejects with TransactionAlreadyReconciled"
    $ do
      let completed = completedTransaction fromAccount toAccount (mockMoney 500)
          reconciled =
            handleTransactionEvent
              completed
              ( TransactionImportReconciledTransactionEvent
                  TransactionImportReconciled
                    { transactionId = txId,
                      externalTransactionIds = extId :| [],
                      category = Just mockCategory
                    }
              )
      handleTransactionCommand reconciled reconcileCommand
        `shouldBe` Left TransactionAlreadyReconciled
