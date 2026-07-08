{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionRelationsIntegrationSpec
-- Description : End-to-end coverage of typed transaction relationships.
--
-- Exercises the Refund + Merge/Split relation substrate through the full
-- service + saga + read-model stack using a synchronous in-memory event
-- store (the same harness as
-- 'Integration.TransactionCancellationIntegrationSpec'). Every command
-- dispatched triggers the downstream event fan-out synchronously before
-- control returns, so the read model is fully up to date after each call.
--
-- Covers Task 13 of
-- @docs/plans/2026-07-05-transaction-relationships.md@.
--
-- Scenarios:
--   1. Post expense P + linked refund income R → reverse index P←R (Refund)
--      and forward index R→P (Refund).
--   2. Cancel the refund R → the reverse Refund index auto-orphans (empty),
--      because a Cancelled Refund "from" is skipped.
--   3. Record a Merge edge src→tgt then cancel src → the reverse Merge index
--      still lists src (Merge lineage from a cancelled source is KEPT — the
--      kind-specific filter applies only to Refund).
--   4. Refund netting end-to-end: expense (cat X, 100) + linked refund income
--      carrying an expense-bucket (contra) allocation against cat X (30) →
--      'spendingByCategory' reports X net = 70. The contra allocation nets
--      directly through 'aggregateSpending'; no separate netting pass is needed.
module Integration.TransactionRelationsIntegrationSpec (spec) where

import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.ConfigurationService
  ( expenseCategoryDictId,
    incomeCategoryDictId,
    seedDefaultConfiguration,
  )
import Application.Services.ReportingService (spendingByCategory)
import Application.Services.TransactionService
  ( cancelTransaction,
    getOutboundRelations,
    initiateExpense,
    initiateIncome,
    addTransactionRelation,
    removeTransactionRelation,
  )
import qualified Data.Set as Set
import Domain.Core.Errors
  ( DomainError
      ( CannotRemoveLineageRelation,
        RefundExceedsRefundableAmount,
        RefundSourceMustBeIncomeWithContra,
        RelationAlreadyExists,
        RelationNotFound
      ),
  )
import Domain.Core.Types
  ( AccountId,
    CategoryId,
    DictionaryEntryId,
    Money,
    RelationKind (..),
    RelationSpec (..),
    TransactionId,
    UserId,
    unMoney,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, firstDictionaryEntry, registerUser)
import Testkit.Helpers (expenseSingletonAllocation, singletonAllocation)
import Testkit.InMemoryEventStore
  ( createTestAppEnvWithProcessManager,
    runDbIn,
  )

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

data Fixture = Fixture
  { userId :: !UserId,
    regularAccountId :: !AccountId,
    incomeCategory :: !DictionaryEntryId,
    expenseCategory :: !DictionaryEntryId
  }

setupFixture :: AppEnv -> Text -> IO Fixture
setupFixture env email = do
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  incomeCat <- firstDictionaryEntry env uid incomeCategoryDictId
  expenseCat <- firstDictionaryEntry env uid expenseCategoryDictId
  accId <- createDefaultAccount env uid "Wallet"
  pure
    Fixture
      { userId = uid,
        regularAccountId = accId,
        incomeCategory = incomeCat,
        expenseCategory = expenseCat
      }

-- | Post an expense of the given amount against the fixture's expense category.
postExpense :: AppEnv -> Fixture -> Rational -> IO TransactionId
postExpense env fx amt = do
  res <-
    runAppM env
      $ initiateExpense
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (expenseSingletonAllocation fx.expenseCategory (unsafeMoney Core.USD amt))
        Set.empty
        "Purchase"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "initiateExpense failed: " <> show err
    Right (tid, _) -> pure tid

-- | Post a refund income of the given amount linked to a target expense.
postRefund :: AppEnv -> Fixture -> Rational -> TransactionId -> IO TransactionId
postRefund env fx amt targetId = do
  res <-
    runAppM env
      $ initiateIncome
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD amt))
        Set.empty
        "Refund"
        Nothing
        (Just (RelationSpec targetId Refund))
  case res of
    Left err -> fail $ "initiateIncome (refund) failed: " <> show err
    Right (tid, _) -> pure tid

-- | Post a refund income carrying an expense-bucket (contra) allocation against
-- the fixture's /expense/ category, linked to the target expense. This is the
-- shape that nets per-category spend automatically: an expense-bucket allocation
-- on an 'Income' transaction contributes @-spend@ to that category via
-- 'aggregateSpending', so no separate refund-netting pass is required.
postContraRefund :: AppEnv -> Fixture -> Rational -> TransactionId -> IO TransactionId
postContraRefund env fx amt targetId = do
  res <-
    runAppM env
      $ initiateIncome
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (expenseSingletonAllocation fx.expenseCategory (unsafeMoney Core.USD amt))
        Set.empty
        "Refund"
        Nothing
        (Just (RelationSpec targetId Refund))
  case res of
    Left err -> fail $ "initiateIncome (contra refund) failed: " <> show err
    Right (tid, _) -> pure tid

-- | Post an income carrying an expense-bucket (contra) allocation of the given
-- total, WITHOUT a relation in the create body. Same shape as 'postContraRefund'
-- but with no 'RelationSpec' — used to drive 'addTransactionRelation' directly.
postContraRefundNoRelation :: AppEnv -> Fixture -> Rational -> IO TransactionId
postContraRefundNoRelation env fx amt = do
  res <-
    runAppM env
      $ initiateIncome
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (expenseSingletonAllocation fx.expenseCategory (unsafeMoney Core.USD amt))
        Set.empty
        "Refund"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "initiateIncome (contra, no relation) failed: " <> show err
    Right (tid, _) -> pure tid

runCancel :: AppEnv -> UserId -> TransactionId -> IO ()
runCancel env uid txId = do
  res <- runAppM env (cancelTransaction uid txId)
  case res of
    Left err -> fail $ "cancelTransaction failed: " <> show err
    Right _ -> pure ()

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransactionRelations" $ do
  refundEdgeSpec
  cancelledRefundOrphanSpec
  mergeLineageSurvivesCancelSpec
  refundNettingSpec
  addRelationGuardSpec
  removeRelationGuardSpec

-- -----------------------------------------------------------------------------
-- 1. Refund edge appears in both directions
-- -----------------------------------------------------------------------------

refundEdgeSpec :: Spec
refundEdgeSpec =
  describe "Refund edge"
    $ it "links a refund income to its expense in both directions"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "rel-refund-edge@test.com"
      purchaseId <- postExpense env fx 100
      refundId <- postRefund env fx 30 purchaseId

      reverses <- runDbIn env (ReadModel.reverseRelations purchaseId Refund)
      reverses `shouldBe` [refundId]

      forward <- runAppM env (getOutboundRelations refundId)
      forward `shouldBe` [(purchaseId, Refund)]

-- -----------------------------------------------------------------------------
-- 2. Cancelled refund auto-orphans from the reverse index
-- -----------------------------------------------------------------------------

cancelledRefundOrphanSpec :: Spec
cancelledRefundOrphanSpec =
  describe "Cancelled refund"
    $ it "auto-orphans from the reverse Refund index once cancelled"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "rel-refund-orphan@test.com"
      purchaseId <- postExpense env fx 100
      refundId <- postRefund env fx 30 purchaseId

      before <- runDbIn env (ReadModel.reverseRelations purchaseId Refund)
      before `shouldBe` [refundId]

      runCancel env fx.userId refundId

      after <- runDbIn env (ReadModel.reverseRelations purchaseId Refund)
      after `shouldBe` []

-- -----------------------------------------------------------------------------
-- 3. Merge lineage from a cancelled source is kept
-- -----------------------------------------------------------------------------

mergeLineageSurvivesCancelSpec :: Spec
mergeLineageSurvivesCancelSpec =
  describe "Merge lineage"
    $ it "keeps the reverse Merge index even after the source is cancelled"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "rel-merge-lineage@test.com"
      srcId <- postExpense env fx 100
      tgtId <- postExpense env fx 100

      recordRes <- runAppM env (addTransactionRelation fx.userId srcId tgtId Merge)
      case recordRes of
        Left err -> fail $ "addTransactionRelation failed: " <> show err
        Right () -> pure ()

      before <- runDbIn env (ReadModel.reverseRelations tgtId Merge)
      before `shouldBe` [srcId]

      -- The merge source is deliberately cancelled; lineage must survive.
      runCancel env fx.userId srcId

      after <- runDbIn env (ReadModel.reverseRelations tgtId Merge)
      after `shouldBe` [srcId]

-- -----------------------------------------------------------------------------
-- 4. Refund netting through spendingByCategory
-- -----------------------------------------------------------------------------

refundNettingSpec :: Spec
refundNettingSpec =
  describe "Refund netting"
    $ it "nets a linked refund income out of per-category spend"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "rel-refund-netting@test.com"
      purchaseId <- postExpense env fx 100
      _refundId <- postContraRefund env fx 30 purchaseId

      (_total, perCat) <- runAppM env (spendingByCategory fx.userId Nothing Nothing)
      lookupCategory fx.expenseCategory perCat `shouldBe` Just 70

-- | Look up a category's net spend (as a plain Rational) in the breakdown.
lookupCategory :: CategoryId -> [(CategoryId, Money)] -> Maybe Rational
lookupCategory cat perCat = unMoney <$> lookup cat perCat

-- -----------------------------------------------------------------------------
-- 5. Service-path add guards (refund source/cap + duplicate/reciprocal)
-- -----------------------------------------------------------------------------

addRelationGuardSpec :: Spec
addRelationGuardSpec = describe "add relation guards" $ do
  it "rejects a Refund whose source is not an income-with-contra" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-src-notincome@test.com"
    purchaseId <- postExpense env fx 100
    plainId <- postExpense env fx 50
    res <- runAppM env (addTransactionRelation fx.userId plainId purchaseId Refund)
    res `shouldBe` Left RefundSourceMustBeIncomeWithContra

  it "rejects a Refund that exceeds the remaining refundable amount" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-overrefund@test.com"
    purchaseId <- postExpense env fx 100
    incomeId <- postContraRefundNoRelation env fx 150
    res <- runAppM env (addTransactionRelation fx.userId incomeId purchaseId Refund)
    res `shouldBe` Left RefundExceedsRefundableAmount

  it "rejects a duplicate forward edge" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-dup@test.com"
    purchaseId <- postExpense env fx 100
    incomeId <- postContraRefundNoRelation env fx 40
    _ <- runAppM env (addTransactionRelation fx.userId incomeId purchaseId Refund)
    res <- runAppM env (addTransactionRelation fx.userId incomeId purchaseId Refund)
    res `shouldBe` Left RelationAlreadyExists

  it "rejects a reciprocal Associated edge (B->A when A->B exists)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-recip@test.com"
    a <- postExpense env fx 10
    b <- postExpense env fx 20
    _ <- runAppM env (addTransactionRelation fx.userId a b Associated)
    res <- runAppM env (addTransactionRelation fx.userId b a Associated)
    res `shouldBe` Left RelationAlreadyExists

  it "allows a Refund whose contra exactly equals the refundable amount" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-exact@test.com"
    purchaseId <- postExpense env fx 100
    incomeId <- postContraRefundNoRelation env fx 100
    res <- runAppM env (addTransactionRelation fx.userId incomeId purchaseId Refund)
    res `shouldBe` Right ()

  it "caps cumulative refunds across a prior refund on the same expense" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-cumulative@test.com"
    purchaseId <- postExpense env fx 100
    -- First refund of 60 adds cleanly.
    firstId <- postContraRefundNoRelation env fx 60
    first <- runAppM env (addTransactionRelation fx.userId firstId purchaseId Refund)
    first `shouldBe` Right ()
    -- Second refund of 50 would push the cumulative total to 110 > 100, so it
    -- must be rejected via the reverseRelations/prior-sum path (priors = 60).
    secondId <- postContraRefundNoRelation env fx 50
    second <- runAppM env (addTransactionRelation fx.userId secondId purchaseId Refund)
    second `shouldBe` Left RefundExceedsRefundableAmount

  -- A Refund added explicitly (tracker#34) must point the SAME way as one
  -- created at income creation (tracker#33 / initiateIncome): from = the income,
  -- to = the expense. This pins the direction parity across both creation paths.
  it "adds a Refund with the same direction as an at-creation refund (income -> expense)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "add-direction-parity@test.com"
    -- Path A: refund recorded at income creation.
    purchaseA <- postExpense env fx 100
    refundA <- postRefund env fx 30 purchaseA
    -- Path B: refund added explicitly to a pre-existing income.
    purchaseB <- postExpense env fx 100
    incomeB <- postContraRefundNoRelation env fx 30
    addB <- runAppM env (addTransactionRelation fx.userId incomeB purchaseB Refund)
    addB `shouldBe` Right ()
    -- Both edges are outbound on the income and reverse-indexed on the expense.
    fwdA <- runAppM env (getOutboundRelations refundA)
    fwdB <- runAppM env (getOutboundRelations incomeB)
    fwdA `shouldBe` [(purchaseA, Refund)]
    fwdB `shouldBe` [(purchaseB, Refund)]
    revA <- runDbIn env (ReadModel.reverseRelations purchaseA Refund)
    revB <- runDbIn env (ReadModel.reverseRelations purchaseB Refund)
    revA `shouldBe` [refundA]
    revB `shouldBe` [incomeB]

-- -----------------------------------------------------------------------------
-- 6. Remove relation (unlink)
-- -----------------------------------------------------------------------------

removeRelationGuardSpec :: Spec
removeRelationGuardSpec = describe "remove relation" $ do
  it "removes an Associated edge from either endpoint" $ do
    -- a<->b associated (stored a->b); unlink initiated from b resolves a->b
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "unlink-assoc@test.com"
    a <- postExpense env fx 10
    b <- postExpense env fx 20
    _ <- runAppM env (addTransactionRelation fx.userId a b Associated)
    res <- runAppM env (removeTransactionRelation fx.userId b a Associated)
    res `shouldBe` Right ()
    fwd <- runAppM env (getOutboundRelations a)
    fwd `shouldBe` []

  it "returns RelationNotFound when no edge exists" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "unlink-none@test.com"
    a <- postExpense env fx 10
    b <- postExpense env fx 20
    res <- runAppM env (removeTransactionRelation fx.userId a b Associated)
    res `shouldBe` Left RelationNotFound

  it "is idempotent: second unlink is RelationNotFound" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "unlink-idem@test.com"
    a <- postExpense env fx 10
    b <- postExpense env fx 20
    _ <- runAppM env (addTransactionRelation fx.userId a b Associated)
    firstRemove <- runAppM env (removeTransactionRelation fx.userId a b Associated)
    firstRemove `shouldBe` Right ()
    secondRemove <- runAppM env (removeTransactionRelation fx.userId a b Associated)
    secondRemove `shouldBe` Left RelationNotFound

  it "refuses to remove Merge/Split lineage edges" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "unlink-lineage@test.com"
    srcId <- postExpense env fx 100
    tgtId <- postExpense env fx 100
    _ <- runAppM env (addTransactionRelation fx.userId srcId tgtId Merge)
    res <- runAppM env (removeTransactionRelation fx.userId srcId tgtId Merge)
    res `shouldBe` Left CannotRemoveLineageRelation

  it "removes an Associated edge from the forward (from) side" $ do
    -- a<->b associated (stored a->b); unlink initiated from a (forward side)
    -- resolves the same a->b edge via the forward branch.
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "unlink-assoc-fwd@test.com"
    a <- postExpense env fx 10
    b <- postExpense env fx 20
    _ <- runAppM env (addTransactionRelation fx.userId a b Associated)
    res <- runAppM env (removeTransactionRelation fx.userId a b Associated)
    res `shouldBe` Right ()
    fwd <- runAppM env (getOutboundRelations a)
    fwd `shouldBe` []

  it "removes a Refund edge" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "unlink-refund@test.com"
    expenseId <- postExpense env fx 100
    incomeId <- postContraRefundNoRelation env fx 40
    _ <- runAppM env (addTransactionRelation fx.userId incomeId expenseId Refund)
    res <- runAppM env (removeTransactionRelation fx.userId incomeId expenseId Refund)
    res `shouldBe` Right ()
    fwd <- runAppM env (getOutboundRelations incomeId)
    fwd `shouldBe` []
