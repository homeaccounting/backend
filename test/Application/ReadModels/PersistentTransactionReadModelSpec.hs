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
--     labels and via allocation categories, including 'Cancelled' (still
--     retrievable via the API) but excluding 'Failed' (never posted).
module Application.ReadModels.PersistentTransactionReadModelSpec (spec) where

import Application.ReadModels.Transaction
  ( LegSide (..),
    TransactionData (..),
    applyTransactionEvent,
    countTransactions,
    emptyTransactionFilter,
    findReconciliationCandidates,
    findReferencingTransactions,
    findTransferReconciliationCandidates,
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
    ContactId,
    Currency (..),
    LabelId,
    Money,
    TransactionId,
    TransactionKind (..),
    TransactionType (..),
    mkExpenseAllocations,
    unsafeExternalTransactionId,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionCancellationCompleted (..),
    TransactionContactSet (..),
    TransactionImportReconciled (..),
    TransactionPostingCompleted (..),
    TransactionPostingFailed (..),
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

contact :: Word32 -> ContactId
contact n = mockDictionaryEntryId (UUID.fromWords n 0 0 0)

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
initiated txId src tgt tt labelSet sq = postingInitiatedGlobal txId src tgt tt labelSet day day sq Nothing

completed :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
completed txId = transactionEditGlobal txId (TransactionPostingCompletedEvent TransactionPostingCompleted)

cancelled :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
cancelled txId =
  transactionEditGlobal
    txId
    (TransactionCancellationCompletedEvent TransactionCancellationCompleted {transactionId = txId, by = mockUserId (UUID.fromWords 9 0 0 0)})

failed :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
failed txId =
  transactionEditGlobal
    txId
    (TransactionPostingFailedEvent (TransactionPostingFailed "boom"))

-- | An expense transaction type with a single allocation against @c@.
expenseOn :: CategoryId -> TransactionType
expenseOn c = Expense (mkExpenseAllocations (Allocation c (unsafeMoney USD 100) Nothing NE.:| []))

-- | A @TransactionImportReconciled@ global event attributing one external id
-- (and optional @mcc@) to @txId@'s stream.
reconciled ::
  TransactionId ->
  Maybe Text ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
reconciled txId mccVal =
  transactionEditGlobal
    txId
    ( TransactionImportReconciledEvent
        TransactionImportReconciled
          { transactionId = txId,
            externalTransactionIds = unsafeExternalTransactionId "ext-1" NE.:| [],
            mcc = mccVal
          }
    )

-- | A fixed calendar date at midnight UTC.
dayAt :: Integer -> Int -> Int -> UTCTime
dayAt y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

-- The seed fixtures ('postingInitiatedGlobal') fix both leg amounts at USD 100.
m100, m200 :: Money
m100 = unsafeMoney USD 100
m200 = unsafeMoney USD 200

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

  describe "contactId" $ do
    it "TransactionPostingInitiated with a contact projects it onto the row" $ do
      env <-
        seedEnv
          [postingInitiatedGlobal (tx 1) acctA acctB Transfer Set.empty day day 0 (Just (contact 5))]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.contactId) <$> mTd `shouldBe` Just (Just (contact 5))

    it "TransactionPostingInitiated without a contact leaves the row's contact as Nothing" $ do
      env <- seedEnv [initiated (tx 1) acctA acctB Transfer Set.empty 0]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.contactId) <$> mTd `shouldBe` Just Nothing

    it "TransactionContactSet updates the contact, and a subsequent Nothing clears it" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB Transfer Set.empty 0,
            transactionEditGlobal
              (tx 1)
              (TransactionContactSetEvent TransactionContactSet {transactionId = tx 1, contactId = Just (contact 5)})
              1
          ]
      mTdSet <- runDbIn env (getTransaction (tx 1))
      (.contactId) <$> mTdSet `shouldBe` Just (Just (contact 5))

      runDbIn
        env
        ( applyTransactionEvent
            ( transactionEditGlobal
                (tx 1)
                (TransactionContactSetEvent TransactionContactSet {transactionId = tx 1, contactId = Nothing})
                2
            )
        )
      mTdCleared <- runDbIn env (getTransaction (tx 1))
      (.contactId) <$> mTdCleared `shouldBe` Just Nothing

    it "TransactionAmendmentCompleted replaces the contact" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB Transfer Set.empty 0,
            transactionEditGlobal
              (tx 1)
              ( TransactionAmendmentCompletedEvent
                  TransactionAmendmentCompleted
                    { transactionId = tx 1,
                      newSourceAccountId = acctA,
                      newTargetAccountId = acctB,
                      newSourceAmount = unsafeMoney USD 100,
                      newTargetAmount = unsafeMoney USD 100,
                      newExchangeRate = Nothing,
                      newTransactionType = Transfer,
                      contactId = Just (contact 9),
                      by = mockUserId (UUID.fromWords 9 0 0 0)
                    }
              )
              1
          ]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.contactId) <$> mTd `shouldBe` Just (Just (contact 9))

  describe "findReferencingTransactions (in-use guard)" $ do
    it "counts a label reference from a cancelled transaction, but not from a failed one, and counts allocation categories" $ do
      env <-
        seedEnv
          [ -- tx1: carries label 7 and is cancelled → still counts (cancelled
            -- transactions remain retrievable via the API)
            initiated (tx 1) acctA acctB Transfer (Set.singleton (lbl 7)) 0,
            cancelled (tx 1) 1,
            -- tx2: carries label 8 but failed to post → excluded
            initiated (tx 2) acctA acctB Transfer (Set.singleton (lbl 8)) 2,
            failed (tx 2) 3,
            -- tx3: expense allocation against category 50 (completed, live)
            initiated (tx 3) acctA acctB (expenseOn (cat 50)) Set.empty 4,
            completed (tx 3) 5
          ]
      -- Label 7 is referenced only by the cancelled tx1 → still counts.
      runDbIn env (findReferencingTransactions (lbl 7)) `shouldReturn` 1
      -- Label 8 is referenced only by the failed tx2 → excluded.
      runDbIn env (findReferencingTransactions (lbl 8)) `shouldReturn` 0
      -- Category 50 is referenced by tx3's allocation.
      runDbIn env (findReferencingTransactions (cat 50)) `shouldReturn` 1
      -- An unreferenced entry has no users.
      runDbIn env (findReferencingTransactions (cat 99)) `shouldReturn` 0

    it "counts a contact reference from a cancelled transaction, but not from a failed one" $ do
      env <-
        seedEnv
          [ -- tx1: carries contact 5 and is cancelled → still counts
            postingInitiatedGlobal (tx 1) acctA acctB Transfer Set.empty day day 0 (Just (contact 5)),
            cancelled (tx 1) 1,
            -- tx2: carries contact 6 but failed to post → excluded
            postingInitiatedGlobal (tx 2) acctA acctB Transfer Set.empty day day 2 (Just (contact 6)),
            failed (tx 2) 3
          ]
      -- Contact 5 is referenced only by the cancelled tx1 → still counts.
      runDbIn env (findReferencingTransactions (contact 5)) `shouldReturn` 1
      -- Contact 6 is referenced only by the failed tx2 → excluded.
      runDbIn env (findReferencingTransactions (contact 6)) `shouldReturn` 0
      -- An unreferenced contact has no users.
      runDbIn env (findReferencingTransactions (contact 99)) `shouldReturn` 0

  describe "countTransactions (business-metric semantic)" $ do
    it "counts all transaction rows, including cancelled" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB Transfer Set.empty 0,
            initiated (tx 2) acctA acctB Transfer Set.empty 1,
            cancelled (tx 2) 2
          ]
      runDbIn env countTransactions `shouldReturn` 2

  describe "TransactionImportReconciled apply" $ do
    it "attributes the reconcile event's mcc onto a manual transaction row" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB (expenseOn (cat 50)) Set.empty 0,
            completed (tx 1) 1,
            reconciled (tx 1) (Just "5411") 2
          ]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.mcc) <$> mTd `shouldBe` Just (Just "5411")

    it "does not clobber an existing mcc when the reconcile carries none" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB (expenseOn (cat 50)) Set.empty 0,
            completed (tx 1) 1,
            reconciled (tx 1) (Just "5999") 2,
            reconciled (tx 1) Nothing 3
          ]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.mcc) <$> mTd `shouldBe` Just (Just "5999")

  describe "findReconciliationCandidates" $ do
    it "returns a completed manual leg matching account/side/amount/kind/window" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB (expenseOn (cat 50)) Set.empty 0,
            completed (tx 1) 1,
            -- tx2: same shape but never completed (Pending) → excluded on status.
            initiated (tx 2) acctA acctB (expenseOn (cat 50)) Set.empty 2
          ]
      let query acc side amt kind lo hi =
            map fst <$> runDbIn env (findReconciliationCandidates acc side amt kind lo hi)
      -- Exact match on the source leg.
      query acctA SourceLeg m100 ExpenseKind (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` [tx 1]
      -- Amount differs.
      query acctA SourceLeg m200 ExpenseKind (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` []
      -- Date outside the window.
      query acctA SourceLeg m100 ExpenseKind (dayAt 2026 2 1) (dayAt 2026 2 28)
        `shouldReturn` []
      -- Wrong kind.
      query acctA SourceLeg m100 IncomeKind (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` []
      -- Wrong account/leg (tx1's source is acctA, not acctB).
      query acctB SourceLeg m100 ExpenseKind (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` []

  describe "findTransferReconciliationCandidates" $ do
    it "returns a completed manual transfer matching the account pair/amount/window" $ do
      env <-
        seedEnv
          [ initiated (tx 1) acctA acctB Transfer Set.empty 0,
            completed (tx 1) 1
          ]
      let query src tgt amt lo hi =
            map fst <$> runDbIn env (findTransferReconciliationCandidates src tgt amt lo hi)
      query acctA acctB m100 (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` [tx 1]
      -- Wrong account pair (direction reversed).
      query acctB acctA m100 (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` []
      -- Amount differs.
      query acctA acctB m200 (dayAt 2026 1 10) (dayAt 2026 1 20)
        `shouldReturn` []
      -- Date outside the window.
      query acctA acctB m100 (dayAt 2026 2 1) (dayAt 2026 2 28)
        `shouldReturn` []
