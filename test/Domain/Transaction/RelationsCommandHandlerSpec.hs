{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Domain.Transaction.RelationsCommandHandlerSpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( Currency (..),
    RelationKind (..),
    RelationSpec (..),
    TransactionId,
    TransactionType (..),
    parseRelationKind,
    renderRelationKind,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction
import Eventium (latestProjection)
import Test.Hspec

spec :: Spec
spec = do
  wireTokenSpec
  initiateRelationSpec
  addRelationSpec

-- -----------------------------------------------------------------------------
-- Wire token round-trip (moved here from Task 1)
-- -----------------------------------------------------------------------------

wireTokenSpec :: Spec
wireTokenSpec =
  describe "RelationKind wire token" $ do
    it "round-trips through render/parse for every constructor" $
      mapM_
        (\k -> parseRelationKind (renderRelationKind k) `shouldBe` Just k)
        [minBound .. maxBound]
    it "renders lowercase tokens" $ do
      renderRelationKind Refund `shouldBe` "refund"
      renderRelationKind Merge `shouldBe` "merge"
      renderRelationKind Split `shouldBe` "split"
    it "parse is case-insensitive and trims" $
      parseRelationKind "  Refund " `shouldBe` Just Refund
    it "rejects unknown tokens" $
      parseRelationKind "bogus" `shouldBe` Nothing

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

selfId :: TransactionId
selfId = unsafeTransactionId (UUID.fromWords 1 0 0 0)

otherId :: TransactionId
otherId = unsafeTransactionId (UUID.fromWords 2 0 0 0)

purchaseId :: TransactionId
purchaseId = unsafeTransactionId (UUID.fromWords 3 0 0 0)

-- | A valid Transfer 'InitiateTransaction' with no relation attached.
baseInitiate :: InitiateTransaction
baseInitiate =
  InitiateTransaction
    { sourceAccountId = unsafeAccountId (UUID.fromWords 10 0 0 0),
      targetAccountId = unsafeAccountId (UUID.fromWords 11 0 0 0),
      sourceAmount = unsafeMoney USD 100,
      targetAmount = unsafeMoney USD 100,
      exchangeRate = Nothing,
      description = "seed",
      initiatedBy = unsafeUserId (UUID.fromWords 99 0 0 0),
      at = mockTime,
      transactionType = Transfer,
      importInfo = Nothing,
      labels = Set.empty,
      relation = Nothing
    }

-- | A Completed transaction. The aggregate does not store its stream id (it is
-- carried only via the payload-free posting event); the state's status is
-- Completed, which is what the 'AddTransactionRelation' handler gates on.
completedTx :: Transaction
completedTx =
  latestProjection
    transactionProjection
    [ TransactionPostingInitiatedTransactionEvent
        TransactionPostingInitiated
          { sourceAccountId = unsafeAccountId (UUID.fromWords 10 0 0 0),
            targetAccountId = unsafeAccountId (UUID.fromWords 11 0 0 0),
            sourceAmount = unsafeMoney USD 100,
            targetAmount = unsafeMoney USD 100,
            exchangeRate = Nothing,
            description = "seed",
            by = unsafeUserId (UUID.fromWords 99 0 0 0),
            at = mockTime,
            transactionType = Transfer,
            importInfo = Nothing,
            labels = Set.empty
          },
      TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
    ]

-- -----------------------------------------------------------------------------
-- InitiateTransaction with a relation
-- -----------------------------------------------------------------------------

initiateRelationSpec :: Spec
initiateRelationSpec =
  describe "InitiateTransaction with a relation" $ do
    it "emits PostingInitiated then RelationAdded when relation is present" $ do
      let cmd = baseInitiate {relation = Just (RelationSpec purchaseId Refund)}
      case handleTransactionCommand transactionDefault (InitiateTransactionTransactionCommand cmd) of
        Right
          [ TransactionPostingInitiatedTransactionEvent _,
            TransactionRelationAddedTransactionEvent r
            ] -> do
            r.relatedTransactionId `shouldBe` purchaseId
            r.relationKind `shouldBe` Refund
        other -> expectationFailure ("unexpected: " <> show other)

    it "emits a single event when relation is Nothing (regression)" $ do
      let cmd = baseInitiate {relation = Nothing}
      case handleTransactionCommand transactionDefault (InitiateTransactionTransactionCommand cmd) of
        Right [TransactionPostingInitiatedTransactionEvent _] -> pure ()
        other -> expectationFailure ("unexpected: " <> show other)

-- -----------------------------------------------------------------------------
-- AddTransactionRelation
-- -----------------------------------------------------------------------------

addRelationSpec :: Spec
addRelationSpec =
  describe "AddTransactionRelation" $ do
    it "rejects a self-link" $ do
      let cmd = AddTransactionRelation selfId selfId Merge
      handleTransactionCommand completedTx (AddTransactionRelationTransactionCommand cmd)
        `shouldBe` Left RelationSelfLink

    it "emits a single TransactionRelationAdded on a Completed tx" $ do
      let cmd = AddTransactionRelation selfId otherId Merge
      case handleTransactionCommand completedTx (AddTransactionRelationTransactionCommand cmd) of
        Right [TransactionRelationAddedTransactionEvent r] -> do
          r.relatedTransactionId `shouldBe` otherId
          r.relationKind `shouldBe` Merge
        other -> expectationFailure ("unexpected: " <> show other)

    it "rejects on a non-Completed (Pending) tx" $ do
      let cmd = AddTransactionRelation selfId otherId Merge
      handleTransactionCommand transactionDefault (AddTransactionRelationTransactionCommand cmd)
        `shouldBe` Left CannotEditUncompletedTransaction
