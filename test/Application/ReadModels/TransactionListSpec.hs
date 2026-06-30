{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionListSpec
-- Description : Unit tests for Application.ReadModels.Transaction.listTransactions
--
-- Tests are driven by feeding synthesized GlobalStreamEvent values through the
-- read model's own apply function ('applyTransactionEvent'), into the persistent
-- @transactions@ / @transaction_labels@ tables of a fresh test environment. The
-- seeding path mirrors production exactly — no test-only insertion hole — and
-- queries run as indexed SQL via 'runDbIn'.
module Application.ReadModels.TransactionListSpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    applyTransactionEvent,
    emptyTransactionFilter,
    getTransaction,
    listTransactions,
    mkTransactionFilter,
  )
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Page (Page (..), defaultLimit)
import Domain.Core.Range (Range (..))
import Domain.Core.Types
  ( AccountId,
    LabelId,
    TransactionId,
    TransactionType (..),
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionCancellationCompleted (..),
    TransactionDateChanged (..),
    TransactionDescriptionChanged (..),
    TransactionLabelsSet (..),
    TransactionPostingFailed (..),
  )
import Domain.Transaction.Projection (StatusKind (..))
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
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.TransactionEvents (postingInitiatedGlobal, transactionEditGlobal)

acctA, acctB, acctC :: AccountId
acctA = mockAccountId (UUID.fromWords 1 0 0 0)
acctB = mockAccountId (UUID.fromWords 2 0 0 0)
acctC = mockAccountId (UUID.fromWords 3 0 0 0)

tx :: Word32 -> TransactionId
tx n = mockTransactionId (UUID.fromWords n 0 0 0)

lbl :: Word32 -> LabelId
lbl n = mockDictionaryEntryId (UUID.fromWords n 0 0 0)

-- | The all-rows page: default limit, no offset.
allPage :: Page
allPage = Page defaultLimit 0

-- | A 'Transfer' posting-initiated event (no labels); see
-- 'postingInitiatedGlobal'. @businessAt@ is the payload date, @persistedAt@ the
-- metadata createdAt (they differ for the backdated regression guard).
mkInitiatedEvent ::
  TransactionId ->
  AccountId -> -- source
  AccountId -> -- target
  UTCTime -> -- business time (TransactionPostingInitiated.at)
  UTCTime -> -- persistedAt (createdAt)
  Eventium.SequenceNumber -> -- global sequence number
  Eventium.GlobalStreamEvent AccountingEvent
mkInitiatedEvent txId src tgt = postingInitiatedGlobal txId src tgt Transfer Set.empty

-- | A single-payload edit/terminal GlobalStreamEvent for an existing
-- transaction stream; see 'transactionEditGlobal'.
mkEditEvent ::
  TransactionId ->
  AccountingEvent ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
mkEditEvent = transactionEditGlobal

-- | Cancellation edit event for @txId@.
mkCancelledEvent :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
mkCancelledEvent txId =
  mkEditEvent
    txId
    ( TransactionCancellationCompletedEvent
        TransactionCancellationCompleted
          { transactionId = txId,
            by = mockUserId (UUID.fromWords 9 0 0 0)
          }
    )

-- | Posting-failed edit event for @txId@.
mkFailedEvent :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
mkFailedEvent txId =
  mkEditEvent txId (TransactionPostingFailedEvent (TransactionPostingFailed "boom"))

-- | Label-set edit event for @txId@.
mkLabelsEvent :: TransactionId -> Set LabelId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
mkLabelsEvent txId labelSet =
  mkEditEvent
    txId
    (TransactionLabelsSetEvent TransactionLabelsSet {transactionId = txId, labels = labelSet})

-- | Fresh environment with the synthesized events applied to the persistent
-- transaction tables (via the read model's own apply function).
seedEnv :: [Eventium.GlobalStreamEvent AccountingEvent] -> IO AppEnv
seedEnv events = do
  env <- createTestAppEnvWithProcessManager
  runDbIn env (mapM_ applyTransactionEvent events)
  pure env

t :: Integer -> Int -> Int -> UTCTime
t y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "listTransactions / visibility set" $ do
    it "includes transactions whose source is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      env <- seedEnv [e]
      (total, results) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter allPage)
      map fst results `shouldBe` [tx 1]
      total `shouldBe` 1

    it "includes transactions whose target is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      env <- seedEnv [e]
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctB) emptyTransactionFilter allPage)
      map fst results `shouldBe` [tx 1]

    it "excludes transactions where neither side is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      env <- seedEnv [e]
      (total, results) <- runDbIn env (listTransactions (Set.singleton acctC) emptyTransactionFilter allPage)
      results `shouldBe` []
      total `shouldBe` 0

  describe "listTransactions / accountId filter" $ do
    it "narrows to a single account (source match)" $ do
      let e1 = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          e2 = mkInitiatedEvent (tx 2) acctB acctC (t 2026 1 16) (t 2026 1 16) 1
      env <- seedEnv [e1, e2]
      let f = mkTransactionFilter (Just acctA) Nothing Nothing Nothing
      (_, results) <- runDbIn env (listTransactions (Set.fromList [acctA, acctB, acctC]) f allPage)
      map fst results `shouldBe` [tx 1]

    it "returns empty when the account is outside the visibility set" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      env <- seedEnv [e]
      let f = mkTransactionFilter (Just acctC) Nothing Nothing Nothing
      (_, results) <- runDbIn env (listTransactions (Set.fromList [acctA, acctB]) f allPage)
      results `shouldBe` []

  describe "listTransactions / date bounds" $ do
    let dateFilter mfrom mto = mkTransactionFilter Nothing (Just (Range mfrom mto)) Nothing Nothing
    it "is inclusive on the from boundary" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      env <- seedEnv [e]
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) (dateFilter (Just (t 2026 1 15)) Nothing) allPage)
      map fst results `shouldBe` [tx 1]

    it "is inclusive on the to boundary" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      env <- seedEnv [e]
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) (dateFilter Nothing (Just (t 2026 1 15))) allPage)
      map fst results `shouldBe` [tx 1]

    it "excludes entries outside the bounds" $ do
      let earlier = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 10) (t 2026 1 10) 0
          inside = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 15) (t 2026 1 15) 1
          later' = mkInitiatedEvent (tx 3) acctA acctB (t 2026 1 20) (t 2026 1 20) 2
      env <- seedEnv [earlier, inside, later']
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) (dateFilter (Just (t 2026 1 12)) (Just (t 2026 1 17))) allPage)
      map fst results `shouldBe` [tx 2]

  describe "listTransactions / ordering" $ do
    it "sorts by business timestamp descending" $ do
      let older = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 10) (t 2026 1 10) 0
          newer = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 20) (t 2026 1 20) 1
      env <- seedEnv [older, newer]
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter allPage)
      map fst results `shouldBe` [tx 2, tx 1]

  describe "listTransactions / status filter (IN; absent = all)" $ do
    -- tx1 Pending, tx2 Failed, tx3 Cancelled
    let seed =
          seedEnv
            [ mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 11) (t 2026 1 11) 0,
              mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 12) (t 2026 1 12) 1,
              mkFailedEvent (tx 2) 2,
              mkInitiatedEvent (tx 3) acctA acctB (t 2026 1 13) (t 2026 1 13) 3,
              mkCancelledEvent (tx 3) 4
            ]

    it "omitting status returns ALL statuses (incl. Failed/Cancelled)" $ do
      env <- seed
      (total, results) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter allPage)
      Set.fromList (map fst results) `shouldBe` Set.fromList [tx 1, tx 2, tx 3]
      total `shouldBe` 3

    it "status=failed,cancelled returns exactly those" $ do
      env <- seed
      let f = mkTransactionFilter Nothing Nothing (Just (FailedKind NE.:| [CancelledKind])) Nothing
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) f allPage)
      Set.fromList (map fst results) `shouldBe` Set.fromList [tx 2, tx 3]

    it "status=pending returns only Pending" $ do
      env <- seed
      let f = mkTransactionFilter Nothing Nothing (Just (PendingKind NE.:| [])) Nothing
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) f allPage)
      map fst results `shouldBe` [tx 1]

  describe "listTransactions / label filter (set overlap)" $ do
    it "matches a transaction carrying any requested label" $ do
      let e1 = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          e2 = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 16) (t 2026 1 16) 2
          l1 = mkLabelsEvent (tx 1) (Set.fromList [lbl 7, lbl 8]) 1
          l2 = mkLabelsEvent (tx 2) (Set.fromList [lbl 9]) 3
      env <- seedEnv [e1, l1, e2, l2]
      let f = mkTransactionFilter Nothing Nothing Nothing (Just (lbl 7 NE.:| []))
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) f allPage)
      map fst results `shouldBe` [tx 1]

    it "excludes transactions sharing no requested label" $ do
      let e1 = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          l1 = mkLabelsEvent (tx 1) (Set.fromList [lbl 7]) 1
      env <- seedEnv [e1, l1]
      let f = mkTransactionFilter Nothing Nothing Nothing (Just (lbl 99 NE.:| []))
      (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) f allPage)
      results `shouldBe` []

  describe "listTransactions / pagination" $ do
    -- Five transactions on distinct ascending dates -> sorted desc: tx5..tx1.
    let seed =
          seedEnv
            [ mkInitiatedEvent (tx n) acctA acctB (t 2026 1 (fromIntegral n)) (t 2026 1 (fromIntegral n)) (fromIntegral n - 1)
            | n <- [1 .. 5]
            ]
        sortedDesc = [tx 5, tx 4, tx 3, tx 2, tx 1]

    it "slice length is bounded by limit; total is the full match count" $ do
      env <- seed
      (total, results) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter (Page 2 0))
      total `shouldBe` 5
      map fst results `shouldBe` take 2 sortedDesc

    it "offset past the end yields an empty slice with total unchanged" $ do
      env <- seed
      (total, results) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter (Page 2 10))
      total `shouldBe` 5
      results `shouldBe` []

    it "successive pages reconstruct the full sorted result" $ do
      env <- seed
      (_, p0) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter (Page 2 0))
      (_, p1) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter (Page 2 2))
      (_, p2) <- runDbIn env (listTransactions (Set.singleton acctA) emptyTransactionFilter (Page 2 4))
      map fst (p0 <> p1 <> p2) `shouldBe` sortedDesc

  describe "metadata edit folds" $ do
    it "TransactionDescriptionChanged replaces description on the matching row" $ do
      let initiated = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          edit =
            mkEditEvent
              (tx 1)
              ( TransactionDescriptionChangedEvent
                  TransactionDescriptionChanged
                    { transactionId = tx 1,
                      newDescription = "updated description"
                    }
              )
              1
      env <- seedEnv [initiated, edit]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.description) <$> mTd `shouldBe` Just "updated description"

    it "TransactionDateChanged replaces business date on the matching row" $ do
      let initiated = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          edit =
            mkEditEvent
              (tx 1)
              ( TransactionDateChangedEvent
                  TransactionDateChanged
                    { transactionId = tx 1,
                      newAt = t 2026 2 20
                    }
              )
              1
      env <- seedEnv [initiated, edit]
      mTd <- runDbIn env (getTransaction (tx 1))
      (.date) <$> mTd `shouldBe` Just (t 2026 2 20)

  describe "listTransactions / business-time filter (backdated regression guard)" $ do
    let dateFilter mfrom mto = mkTransactionFilter Nothing (Just (Range mfrom mto)) Nothing Nothing
    it "matches the payload at window, NOT the createdAt window" $ do
      let occurredPast = t 2026 1 15
          createdNow = t 2026 4 18
          e = mkInitiatedEvent (tx 1) acctA acctB occurredPast createdNow 0
      env <- seedEnv [e]

      (_, resultsBusiness) <-
        runDbIn env (listTransactions (Set.singleton acctA) (dateFilter (Just (t 2026 1 14)) (Just (t 2026 1 16))) allPage)
      map fst resultsBusiness `shouldBe` [tx 1]

      (_, resultsPersist) <-
        runDbIn env (listTransactions (Set.singleton acctA) (dateFilter (Just (t 2026 4 17)) (Just (t 2026 4 19))) allPage)
      resultsPersist `shouldBe` []
