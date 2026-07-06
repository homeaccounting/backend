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
    recordTransactionRelation,
  )
import qualified Data.Set as Set
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

      recordRes <- runAppM env (recordTransactionRelation fx.userId srcId tgtId Merge)
      case recordRes of
        Left err -> fail $ "recordTransactionRelation failed: " <> show err
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
