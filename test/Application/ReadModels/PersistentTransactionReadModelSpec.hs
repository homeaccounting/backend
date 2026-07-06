{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.PersistentTransactionReadModelSpec
-- Description : Guarantees of the persistent, indexed Transaction read model.
--
-- Exercises the properties the @transactions@ / @transaction_labels@ projection
-- exists to provide, seeding synthesized events through the read model's own
-- 'applyTransactionEvent' (no test-only insertion hole):
--
--   * __Tenant isolation__ — a transaction touching only one tenant's accounts
--     never surfaces in another tenant's queries.
--   * __Idempotency__ — re-applying the same event stream yields the same row
--     and label set (insert-by-id + full label replacement), so startup
--     catch-up / replay is safe.
--   * __In-use guard__ — 'findReferencingTransactions' counts references via
--     labels and via allocation categories, excluding 'Cancelled'.
module Application.ReadModels.PersistentTransactionReadModelSpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    applyTransactionEvent,
    emptyTransactionFilter,
    findReferencingTransactions,
    getTransaction,
    listTransactions,
    reportableTransactions,
  )
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Database.Persist.Sql (Single (..), rawSql)
import Domain.Core.Page (Page (..), defaultLimit)
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    CategoryId,
    Currency (..),
    LabelId,
    TransactionId,
    TransactionType (..),
    mkExpenseAllocations,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionCancellationCompleted (..),
    TransactionPostingCompleted (..),
  )
import qualified Eventium
import Infrastructure.App (AppEnv)
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountId,
    mockDictionaryEntryId,
    mockTransactionId,
    mockUserId,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn, seedGlobals)
import Testkit.TransactionEvents (postingInitiatedGlobal, transactionEditGlobal)

acctA, acctB :: AccountId
acctA = mockAccountId (UUID.fromWords 1 0 0 0)
acctB = mockAccountId (UUID.fromWords 2 0 0 0)

tx :: Word32 -> TransactionId
tx n = mockTransactionId (UUID.fromWords n 0 0 0)

lbl :: Word32 -> LabelId
lbl n = mockDictionaryEntryId (UUID.fromWords n 0 0 0)

cat :: Word32 -> CategoryId
cat n = mockDictionaryEntryId (UUID.fromWords n 0 0 0)

allPage :: Page
allPage = Page defaultLimit 0

day :: UTCTime
day = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime 0)

-- | A @TransactionPostingInitiated@ global event with a given type and labels
-- (fixed business/persisted date); see 'postingInitiatedGlobal'.
initiated ::
  TransactionId ->
  AccountId ->
  AccountId ->
  TransactionType ->
  Set LabelId ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
initiated txId src tgt tt labelSet = postingInitiatedGlobal txId src tgt tt labelSet day day

completed :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
completed txId = transactionEditGlobal txId (TransactionPostingCompletedEvent TransactionPostingCompleted)

cancelled :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
cancelled txId =
  transactionEditGlobal
    txId
    (TransactionCancellationCompletedEvent TransactionCancellationCompleted {transactionId = txId, by = mockUserId (UUID.fromWords 9 0 0 0)})

-- | An expense transaction type with a single allocation against @c@.
expenseOn :: CategoryId -> TransactionType
expenseOn c = Expense (mkExpenseAllocations (Allocation c (unsafeMoney USD 100) Nothing NE.:| []))

seedEnv :: [Eventium.GlobalStreamEvent AccountingEvent] -> IO AppEnv
seedEnv = seedGlobals applyTransactionEvent

spec :: Spec
spec = describe "Persistent Transaction read model" $ do
  describe "hot-query indexes" $ do
    it "creates secondary indexes backing the visible-account / date / label hot paths" $ do
      env <- createTestAppEnvWithProcessManager
      -- The read model's 'initialize' runs migrate + createTransactionIndexes;
      -- introspect SQLite's catalogue to prove every hot-path index is present.
      -- Scoped to @idx_transaction%@ so other read models' indexes (e.g. the
      -- User model's @idx_user_oauth_user@) don't leak into the assertion.
      idxRows <-
        runDbIn env
          $ rawSql
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_transaction%'"
            []
      let names = Set.fromList [n | Single n <- idxRows] :: Set Text
      names
        `shouldBe` Set.fromList
          [ "idx_transactions_source",
            "idx_transactions_target",
            "idx_transactions_date",
            "idx_transaction_labels_label",
            "idx_transaction_relations_from",
            "idx_transaction_relations_to_kind"
          ]

  describe "tenant isolation" $ do
    it "a transaction touching only tenant B's accounts never surfaces for tenant A" $ do
      -- tx1 is A<->A-visible (touches acctA); tx2 lives entirely on acctB.
      let acctB2 = mockAccountId (UUID.fromWords 22 0 0 0)
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB Transfer Set.empty 0,
            initiated (tx 2) acctB acctB2 Transfer Set.empty 1
          ]
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter allPage)
      map fst results `shouldBe` [tx 1]

    it "reportableTransactions is scoped to the visible set" $ do
      let acctB2 = mockAccountId (UUID.fromWords 22 0 0 0)
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB Transfer Set.empty 0,
            completed (tx 1) 1,
            initiated (tx 2) acctB acctB2 Transfer Set.empty 2,
            completed (tx 2) 3
          ]
      reportA <- runDbIn env (reportableTransactions (Set.singleton acctA) Nothing Nothing)
      map (.sourceAccountId) reportA `shouldBe` [acctA]

  describe "idempotency (re-apply == apply once)" $ do
    it "re-applying the same event stream leaves one row with the same fields and labels" $ do
      let events =
            [ initiated (tx 1) acctA acctB Transfer (Set.fromList [lbl 7, lbl 8]) 0,
              completed (tx 1) 1
            ]
      -- Apply the whole stream twice.
      env <- seedEnv (events <> events)
      (total, _) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter allPage)
      total `shouldBe` 1
      mTd <- runDbIn env (getTransaction (tx 1))
      (.labels) <$> mTd `shouldBe` Just (Set.fromList [lbl 7, lbl 8])

  describe "findReferencingTransactions (in-use guard)" $ do
    it "counts a label reference but not a cancelled one, and counts allocation categories" $ do
      env <-
        seedEnv
          [ -- tx1: carries label 7 (live)
            initiated (tx 1) acctA acctB Transfer (Set.singleton (lbl 7)) 0,
            -- tx2: expense allocation against category 50 (live)
            initiated (tx 2) acctA acctB (expenseOn (cat 50)) Set.empty 1,
            completed (tx 2) 2,
            -- tx3: carries label 7 but is cancelled → excluded
            initiated (tx 3) acctA acctB Transfer (Set.singleton (lbl 7)) 3,
            cancelled (tx 3) 4
          ]
      -- Label 7 is referenced by tx1 (live) and tx3 (cancelled) → only tx1 counts.
      runDbIn env (findReferencingTransactions (lbl 7)) `shouldReturn` 1
      -- Category 50 is referenced by tx2's allocation.
      runDbIn env (findReferencingTransactions (cat 50)) `shouldReturn` 1
      -- An unreferenced entry has no users.
      runDbIn env (findReferencingTransactions (cat 99)) `shouldReturn` 0
