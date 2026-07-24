{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.RefundValidationSpec
-- Description : Service-level refund-target validation and the Merge/Split
--               relation hook ('addTransactionRelation').
--
-- Exercises the refund-target validation threaded through 'initiateIncome'
-- (Task 9d) and the generic 'addTransactionRelation' hook (Task 9e):
--
--   * a refund income linked to a Completed expense records a @Refund@ edge,
--     visible via 'getOutboundRelations';
--   * a refund whose target is an Income is rejected with
--     'RefundTargetMustBeExpense';
--   * a refund whose target is Cancelled is rejected with
--     'CannotRefundCancelledTransaction';
--   * a refund whose target is absent is rejected with 'NotFound';
--   * 'addTransactionRelation … Merge' on a Completed target records the
--     edge and the reverse index surfaces it.
--
-- Uses the in-memory event-store harness with the posting process manager so
-- income/expense flows reach the Completed state without Postgres.
module Application.Services.RefundValidationSpec (spec) where

import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.ConfigurationService
  ( expenseCategoryDictKind,
    incomeCategoryDictKind,
    seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( addTransactionRelation,
    cancelTransaction,
    getOutboundRelations,
    initiateExpense,
    initiateIncome,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    DictionaryEntryId,
    RelationKind (..),
    RelationSpec (..),
    TransactionId,
    UserId,
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
  incomeCat <- firstDictionaryEntry env uid incomeCategoryDictKind
  expenseCat <- firstDictionaryEntry env uid expenseCategoryDictKind
  accId <- createDefaultAccount env uid "Wallet"
  pure
    Fixture
      { userId = uid,
        regularAccountId = accId,
        incomeCategory = incomeCat,
        expenseCategory = expenseCat
      }

-- | Post an expense and return its id.
postExpense :: AppEnv -> Fixture -> IO TransactionId
postExpense env fx = do
  res <-
    runAppM env
      $ initiateExpense
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD 100)
        (expenseSingletonAllocation fx.expenseCategory (unsafeMoney Core.USD 100))
        Set.empty
        "Purchase"
        Nothing
        Nothing
        Nothing
  case res of
    Left err -> fail $ "initiateExpense failed: " <> show err
    Right (tid, _) -> pure tid

-- | Post a plain income (no refund edge) and return its id.
postIncome :: AppEnv -> Fixture -> IO TransactionId
postIncome env fx = do
  res <-
    runAppM env
      $ initiateIncome
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD 100)
        (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 100))
        Set.empty
        "Salary"
        Nothing
        Nothing
        Nothing
  case res of
    Left err -> fail $ "initiateIncome failed: " <> show err
    Right (tid, _) -> pure tid

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService refund + relation hooks" $ do
  describe "initiateIncome refund target validation" $ do
    it "records a Refund edge when the target is a Completed expense" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "refund-ok@test.com"
      expenseId <- postExpense env fx
      res <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 30)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 30))
            Set.empty
            "Refund"
            Nothing
            (Just (RelationSpec expenseId Refund))
            Nothing
      case res of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right (refundId, _) -> do
          edges <- runAppM env (getOutboundRelations refundId)
          edges `shouldBe` [(expenseId, Refund)]

    it "records the RelationSpec's kind verbatim (not forced to Refund)" $ do
      -- The service is generalised over 'RelationSpec': the recorded edge kind
      -- is whatever the caller supplies, proving it is no longer Refund-hardcoded.
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "income-split@test.com"
      originId <- postExpense env fx
      res <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 30)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 30))
            Set.empty
            "Split origin"
            Nothing
            (Just (RelationSpec originId Split))
            Nothing
      case res of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right (newTxId, _) -> do
          edges <- runAppM env (getOutboundRelations newTxId)
          edges `shouldBe` [(originId, Split)]

    it "rejects a refund whose target is an Income" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "refund-income@test.com"
      incomeId <- postIncome env fx
      res <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 30)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 30))
            Set.empty
            "Refund"
            Nothing
            (Just (RelationSpec incomeId Refund))
            Nothing
      res `shouldBe` Left RefundTargetMustBeExpense

    it "rejects a refund whose target is Cancelled" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "refund-cancelled@test.com"
      expenseId <- postExpense env fx
      cancelRes <- runAppM env (cancelTransaction fx.userId expenseId)
      case cancelRes of
        Left err -> fail $ "cancelTransaction failed: " <> show err
        Right _ -> pure ()
      res <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 30)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 30))
            Set.empty
            "Refund"
            Nothing
            (Just (RelationSpec expenseId Refund))
            Nothing
      res `shouldBe` Left CannotRefundCancelledTransaction

    it "rejects a refund whose target is invisible to the caller" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "refund-absent@test.com"
      -- An expense owned by a *different* user is not visible to fx.userId, so
      -- 'ensureVisibleAccess' surfaces it as an absent transaction (NotFound).
      otherFx <- setupFixture env "refund-absent-other@test.com"
      foreignExpense <- postExpense env otherFx
      res <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 30)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 30))
            Set.empty
            "Refund"
            Nothing
            (Just (RelationSpec foreignExpense Refund))
            Nothing
      case res of
        Left (NotFound "Transaction" _) -> pure ()
        other -> expectationFailure ("expected NotFound Transaction, got: " <> show other)

  describe "addTransactionRelation (Merge/Split hook)" $ do
    it "records a Merge edge on a Completed target and the reverse index shows it" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "merge-ok@test.com"
      fromId <- postExpense env fx
      toId <- postExpense env fx
      res <- runAppM env (addTransactionRelation fx.userId fromId toId Merge)
      case res of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right () -> do
          reverses <- runDbIn env (ReadModel.reverseRelations toId Merge)
          reverses `shouldBe` [fromId]

    it "records a generic Associated edge between transactions of any kinds" $ do
      -- 'Associated' places no restriction on endpoint kinds: here an income is
      -- linked to an expense, and the reverse index surfaces it.
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "associated-ok@test.com"
      incomeId <- postIncome env fx
      expenseId <- postExpense env fx
      res <- runAppM env (addTransactionRelation fx.userId incomeId expenseId Associated)
      case res of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right () -> do
          reverses <- runDbIn env (ReadModel.reverseRelations expenseId Associated)
          reverses `shouldBe` [incomeId]

    it "rejects a self-link" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "merge-self@test.com"
      txId <- postExpense env fx
      res <- runAppM env (addTransactionRelation fx.userId txId txId Merge)
      res `shouldBe` Left CannotRelateTransactionToItself

    it "rejects chaining onto a target that already declares an outbound edge (depth-1)" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "merge-chain@test.com"
      txA <- postExpense env fx
      txB <- postExpense env fx
      txC <- postExpense env fx
      -- A -> B (Merge): A now declares an outbound Merge edge.
      first <- runAppM env (addTransactionRelation fx.userId txA txB Merge)
      case first of
        Left err -> expectationFailure ("expected first edge to succeed, got: " <> show err)
        Right () -> pure ()
      -- C -> A (Merge): A is the target but already has an outbound Merge edge,
      -- so the depth-1 guard rejects the chain.
      second <- runAppM env (addTransactionRelation fx.userId txC txA Merge)
      second `shouldBe` Left CannotChainRelations
