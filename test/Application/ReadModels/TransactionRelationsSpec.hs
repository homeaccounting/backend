{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionRelationsSpec
-- Description : Query behaviour of the @transaction_relations@ read model.
--
-- Seeds relation edges through the read model's own 'applyTransactionEvent'
-- (the stream key is the "from" endpoint) and asserts the forward, batched, and
-- per-kind reverse queries. The key invariant under test is the kind-specific
-- cancelled-"from" skip: 'reverseRelations' drops a Cancelled source only for
-- 'Refund' edges; 'Merge'/'Split' lineage from a deliberately-cancelled source
-- is kept.
module Application.ReadModels.TransactionRelationsSpec (spec) where

import Application.ReadModels.Transaction
  ( applyTransactionEvent,
    relationsFrom,
    relationsFromMany,
    relationsTo,
    reverseRelations,
  )
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    RelationKind (..),
    TransactionId,
    TransactionType (..),
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionCancellationCompleted (..),
    TransactionRelationAdded (..),
  )
import qualified Eventium
import Infrastructure.App (AppEnv)
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountId,
    mockTransactionId,
    mockUserId,
  )
import Testkit.InMemoryEventStore (runDbIn, seedGlobals)
import Testkit.TransactionEvents (postingInitiatedGlobal, transactionEditGlobal)

acctA, acctB :: AccountId
acctA = mockAccountId (UUID.fromWords 1 0 0 0)
acctB = mockAccountId (UUID.fromWords 2 0 0 0)

tx :: Word32 -> TransactionId
tx n = mockTransactionId (UUID.fromWords n 0 0 0)

day :: UTCTime
day = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime 0)

-- | A @TransactionPostingInitiated@ global event (fixed type/labels/date). The
-- read-model row must exist for the cancelled-"from" filter to observe status.
initiated :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
initiated txId = postingInitiatedGlobal txId acctA acctB Transfer Set.empty day day

-- | A relation edge @from -> to@ of @kind@, keyed on the "from" stream.
relation ::
  TransactionId ->
  TransactionId ->
  RelationKind ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
relation fromId toId kind =
  transactionEditGlobal
    fromId
    (TransactionRelationAddedEvent (TransactionRelationAdded toId kind))

cancelled :: TransactionId -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
cancelled txId =
  transactionEditGlobal
    txId
    (TransactionCancellationCompletedEvent TransactionCancellationCompleted {transactionId = txId, by = mockUserId (UUID.fromWords 9 0 0 0)})

seedEnv :: [Eventium.GlobalStreamEvent AccountingEvent] -> IO AppEnv
seedEnv = seedGlobals applyTransactionEvent

spec :: Spec
spec = describe "Transaction relations read model" $ do
  describe "reverseRelations (per-kind reverse index)" $ do
    it "returns every live Refund 'from' pointing at a target" $ do
      -- A -> P (Refund), B -> P (Refund)
      env <-
        seedEnv
          [ initiated (tx 1) 0, -- A
            initiated (tx 2) 1, -- B
            initiated (tx 3) 2, -- P
            relation (tx 1) (tx 3) Refund 3,
            relation (tx 2) (tx 3) Refund 4
          ]
      froms <- runDbIn env (reverseRelations (tx 3) Refund)
      List.sort froms `shouldBe` List.sort [tx 1, tx 2]

    it "skips a Cancelled Refund 'from' (auto-orphan)" $ do
      env <-
        seedEnv
          [ initiated (tx 1) 0, -- A
            initiated (tx 2) 1, -- B
            initiated (tx 3) 2, -- P
            relation (tx 1) (tx 3) Refund 3,
            relation (tx 2) (tx 3) Refund 4,
            cancelled (tx 1) 5 -- cancel A
          ]
      froms <- runDbIn env (reverseRelations (tx 3) Refund)
      froms `shouldBe` [tx 2]

    it "keeps a Cancelled Merge 'from' (lineage survives)" $ do
      -- S -> T (Merge), then cancel S: the merge source is deliberately cancelled.
      env <-
        seedEnv
          [ initiated (tx 10) 0, -- S
            initiated (tx 11) 1, -- T
            relation (tx 10) (tx 11) Merge 2,
            cancelled (tx 10) 3 -- cancel S
          ]
      froms <- runDbIn env (reverseRelations (tx 11) Merge)
      froms `shouldBe` [tx 10]

  describe "relationsTo (all inbound edges)" $ do
    it "keeps live refunds and cancelled merges but drops cancelled refunds" $ do
      -- Inbound edges at T: X -> T (live Refund), Y -> T (Refund, cancel Y),
      -- Z -> T (Merge, cancel Z). relationsTo keeps X (live refund) and Z
      -- (merge lineage survives cancellation) but drops Y (cancelled refund).
      env <-
        seedEnv
          [ initiated (tx 20) 0, -- X
            initiated (tx 21) 1, -- Y
            initiated (tx 22) 2, -- Z
            initiated (tx 23) 3, -- T
            relation (tx 20) (tx 23) Refund 4,
            relation (tx 21) (tx 23) Refund 5,
            relation (tx 22) (tx 23) Merge 6,
            cancelled (tx 21) 7, -- cancel Y (refund source -> dropped)
            cancelled (tx 22) 8 -- cancel Z (merge source -> kept)
          ]
      inbound <- runDbIn env (relationsTo (tx 23))
      List.sort inbound `shouldBe` List.sort [(tx 20, Refund), (tx 22, Merge)]

  describe "relationsFrom (outbound edges)" $ do
    it "returns the (relatedTransactionId, kind) pairs a transaction declares" $ do
      env <-
        seedEnv
          [ initiated (tx 1) 0,
            initiated (tx 3) 1,
            relation (tx 1) (tx 3) Refund 2
          ]
      edges <- runDbIn env (relationsFrom (tx 1))
      edges `shouldBe` [(tx 3, Refund)]

  describe "relationsFromMany (batched outbound edges)" $ do
    it "groups outbound edges by 'from' transaction" $ do
      env <-
        seedEnv
          [ initiated (tx 1) 0, -- A
            initiated (tx 2) 1, -- B
            initiated (tx 3) 2, -- P
            relation (tx 1) (tx 3) Refund 3,
            relation (tx 2) (tx 3) Refund 4
          ]
      edgeMap <- runDbIn env (relationsFromMany [tx 1, tx 2])
      edgeMap
        `shouldBe` Map.fromList
          [ (tx 1, [(tx 3, Refund)]),
            (tx 2, [(tx 3, Refund)])
          ]
