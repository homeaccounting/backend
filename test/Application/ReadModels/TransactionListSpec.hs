{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionListSpec
-- Description : Unit tests for Application.ReadModels.Transaction.listTransactions
--
-- Tests are driven by feeding synthesized GlobalStreamEvent values into the
-- read model's own event handler (handleTransactionEvents). This ensures the
-- seeding path mirrors production exactly — no test-only insertion hole.
module Application.ReadModels.TransactionListSpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    TransactionReadModel,
    createTransactionReadModel,
    emptyTransactionQuery,
    getTransaction,
    handleTransactionEvents,
    listTransactions,
    mkTransactionQuery,
  )
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    TransactionId,
    TransactionType (..),
    unTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionCancellationCompleted (..),
    TransactionDateChanged (..),
    TransactionDescriptionChanged (..),
    TransactionPostingInitiated (..),
  )
import Eventium (StreamEvent (..), emptyMetadata)
import qualified Eventium
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountId,
    mockMoneyWith,
    mockTransactionId,
    mockUserId,
  )

acctA, acctB, acctC :: AccountId
acctA = mockAccountId (UUID.fromWords 1 0 0 0)
acctB = mockAccountId (UUID.fromWords 2 0 0 0)
acctC = mockAccountId (UUID.fromWords 3 0 0 0)

tx :: Word32 -> TransactionId
tx n = mockTransactionId (UUID.fromWords n 0 0 0)

-- Shape: GlobalStreamEvent = StreamEvent () SequenceNumber (VersionedStreamEvent)
-- where VersionedStreamEvent = StreamEvent UUID EventVersion AccountingEvent.
mkInitiatedEvent ::
  TransactionId ->
  AccountId -> -- source
  AccountId -> -- target
  UTCTime -> -- business time (TransactionPostingInitiated.at)
  UTCTime -> -- persistedAt (createdAt) — kept on outer metadata for completeness
  Eventium.SequenceNumber -> -- global sequence number
  Eventium.GlobalStreamEvent AccountingEvent
mkInitiatedEvent txId src tgt businessAt persistedAt seqNo =
  let inner =
        StreamEvent
          (unTransactionId txId)
          0
          ( (emptyMetadata "TransactionPostingInitiated")
              { Eventium.createdAt = Just persistedAt
              }
          )
          ( TransactionPostingInitiatedEvent
              TransactionPostingInitiated
                { sourceAccountId = src,
                  targetAccountId = tgt,
                  sourceAmount = mockMoneyWith USD 100,
                  targetAmount = mockMoneyWith USD 100,
                  exchangeRate = Nothing,
                  description = "seed",
                  by = mockUserId (UUID.fromWords 9 0 0 0),
                  at = businessAt,
                  transactionType = Transfer,
                  externalTransactionId = Nothing,
                  labels = Set.empty
                }
          )
   in StreamEvent () seqNo (emptyMetadata "TransactionPostingInitiated") inner

-- | Build a single-payload GlobalStreamEvent for an AccountingEvent that targets
-- an existing transaction stream (description / date edits). The constructor
-- carries the new value; the stream UUID identifies which TransactionData to mutate.
mkEditEvent ::
  TransactionId ->
  AccountingEvent ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
mkEditEvent txId payload seqNo =
  let inner =
        StreamEvent
          (unTransactionId txId)
          1
          (emptyMetadata "edit")
          payload
   in StreamEvent () seqNo (emptyMetadata "edit") inner

seedReadModel ::
  [Eventium.GlobalStreamEvent AccountingEvent] ->
  IO (TVar TransactionReadModel)
seedReadModel events = do
  tvar <- createTransactionReadModel
  let h = handleTransactionEvents tvar
  h.handleEvent events
  pure tvar

t :: Integer -> Int -> Int -> UTCTime
t y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "listTransactions / visibility set" $ do
    it "includes transactions whose source is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      results <- listTransactions tvar (Set.singleton acctA) emptyTransactionQuery
      map fst results `shouldBe` [tx 1]

    it "includes transactions whose target is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      results <- listTransactions tvar (Set.singleton acctB) emptyTransactionQuery
      map fst results `shouldBe` [tx 1]

    it "excludes transactions where neither side is visible" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      results <- listTransactions tvar (Set.singleton acctC) emptyTransactionQuery
      results `shouldBe` []

  describe "listTransactions / accountId filter" $ do
    it "narrows to a single account (source match)" $ do
      let e1 = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          e2 = mkInitiatedEvent (tx 2) acctB acctC (t 2026 1 16) (t 2026 1 16) 1
      tvar <- seedReadModel [e1, e2]
      q <-
        either (fail . show) pure
          $ mkTransactionQuery (Just acctA) Nothing Nothing False
      results <- listTransactions tvar (Set.fromList [acctA, acctB, acctC]) q
      map fst results `shouldBe` [tx 1]

    it "returns empty when the account is outside the visibility set" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      q <-
        either (fail . show) pure
          $ mkTransactionQuery (Just acctC) Nothing Nothing False
      results <- listTransactions tvar (Set.fromList [acctA, acctB]) q
      results `shouldBe` []

  describe "listTransactions / date bounds" $ do
    it "is inclusive on the from boundary" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      q <-
        either (fail . show) pure
          $ mkTransactionQuery Nothing (Just (t 2026 1 15)) Nothing False
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 1]

    it "is inclusive on the to boundary" $ do
      let e = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
      tvar <- seedReadModel [e]
      q <-
        either (fail . show) pure
          $ mkTransactionQuery Nothing Nothing (Just (t 2026 1 15)) False
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 1]

    it "excludes entries outside the bounds" $ do
      let earlier = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 10) (t 2026 1 10) 0
          inside = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 15) (t 2026 1 15) 1
          later' = mkInitiatedEvent (tx 3) acctA acctB (t 2026 1 20) (t 2026 1 20) 2
      tvar <- seedReadModel [earlier, inside, later']
      q <-
        either (fail . show) pure
          $ mkTransactionQuery Nothing (Just (t 2026 1 12)) (Just (t 2026 1 17)) False
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 2]

  describe "listTransactions / ordering" $ do
    it "sorts by business timestamp descending" $ do
      let older = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 10) (t 2026 1 10) 0
          newer = mkInitiatedEvent (tx 2) acctA acctB (t 2026 1 20) (t 2026 1 20) 1
      tvar <- seedReadModel [older, newer]
      results <- listTransactions tvar (Set.singleton acctA) emptyTransactionQuery
      map fst results `shouldBe` [tx 2, tx 1]

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
      tvar <- seedReadModel [initiated, edit]
      mTd <- getTransaction tvar (tx 1)
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
      tvar <- seedReadModel [initiated, edit]
      mTd <- getTransaction tvar (tx 1)
      (.date) <$> mTd `shouldBe` Just (t 2026 2 20)

  describe "listTransactions / business-time filter (backdated regression guard)" $ do
    it "matches the payload at window, NOT the createdAt window" $ do
      let occurredPast = t 2026 1 15
          createdNow = t 2026 4 18
          e = mkInitiatedEvent (tx 1) acctA acctB occurredPast createdNow 0
      tvar <- seedReadModel [e]

      qBusiness <-
        either (fail . show) pure
          $ mkTransactionQuery Nothing (Just (t 2026 1 14)) (Just (t 2026 1 16)) False
      resultsBusiness <- listTransactions tvar (Set.singleton acctA) qBusiness
      map fst resultsBusiness `shouldBe` [tx 1]

      qPersist <-
        either (fail . show) pure
          $ mkTransactionQuery Nothing (Just (t 2026 4 17)) (Just (t 2026 4 19)) False
      resultsPersist <- listTransactions tvar (Set.singleton acctA) qPersist
      resultsPersist `shouldBe` []

  describe "listTransactions / cancelled status filter" $ do
    it "excludes cancelled transactions when qIncludeCancelled = False" $ do
      let initiated = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          cancelled =
            mkEditEvent
              (tx 1)
              ( TransactionCancellationCompletedEvent
                  TransactionCancellationCompleted
                    { transactionId = tx 1,
                      cancelledBy = mockUserId (UUID.fromWords 9 0 0 0)
                    }
              )
              1
      tvar <- seedReadModel [initiated, cancelled]
      results <- listTransactions tvar (Set.singleton acctA) emptyTransactionQuery
      results `shouldBe` []

    it "includes cancelled transactions when qIncludeCancelled = True" $ do
      let initiated = mkInitiatedEvent (tx 1) acctA acctB (t 2026 1 15) (t 2026 1 15) 0
          cancelled =
            mkEditEvent
              (tx 1)
              ( TransactionCancellationCompletedEvent
                  TransactionCancellationCompleted
                    { transactionId = tx 1,
                      cancelledBy = mockUserId (UUID.fromWords 9 0 0 0)
                    }
              )
              1
      tvar <- seedReadModel [initiated, cancelled]
      q <-
        either (fail . show) pure
          $ mkTransactionQuery Nothing Nothing Nothing True
      results <- listTransactions tvar (Set.singleton acctA) q
      map fst results `shouldBe` [tx 1]
