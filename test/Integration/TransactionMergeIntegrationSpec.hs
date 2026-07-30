{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionMergeIntegrationSpec
-- Description : End-to-end coverage of the merge operation (tracker#30).
--
-- Exercises 'mergeTransactions' through the full service + saga +
-- read-model stack using the synchronous in-memory event store (the same
-- harness as 'Integration.TransactionRelationsIntegrationSpec'). Every
-- command triggers the downstream event fan-out synchronously before
-- control returns, so the read model is fully up to date after each call.
--
-- Scenarios:
--   1. Merge two expenses → the target read-model row reflects the combined
--      amount and the concatenated allocations; both sources are Cancelled;
--      the reverse Merge index on the target lists both sources.
--   2. Balances net: total money moved is conserved by the merge.
--   3. The produced Merge edge is lineage and cannot be removed
--      ('removeTransactionRelation' → 'CannotRemoveLineageRelation').
--   4. A transient double-debit during the amend (source not yet reversed)
--      no longer fails the merge: 'TransactionMergeManager.amendEffect' sets
--      @allowOverdraft = True@ specifically to bypass that spurious guard
--      firing; the ledger nets back to its pre-merge balance.
module Integration.TransactionMergeIntegrationSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.ConfigurationService
  ( expenseCategoryDictKind,
    seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( getOutboundRelations,
    initiateExpense,
    mergeTransactions,
    removeTransactionRelation,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (CannotRemoveLineageRelation))
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    DictionaryEntryId,
    RelationKind (..),
    TransactionId,
    UserId,
    allAllocations,
    allocationsOf,
    defaultCash,
    unMoney,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Projection (TransactionStatus (..))
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (createAccount, createDefaultAccount, firstDictionaryEntry, registerUser)
import Testkit.Helpers (expenseSingletonAllocation)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

data Fixture = Fixture
  { userId :: !UserId,
    regularAccountId :: !AccountId,
    expenseCategory :: !DictionaryEntryId
  }

setupFixture :: AppEnv -> Text -> IO Fixture
setupFixture env email = do
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  expenseCat <- firstDictionaryEntry env uid expenseCategoryDictKind
  accId <- createDefaultAccount env uid "Wallet"
  pure Fixture {userId = uid, regularAccountId = accId, expenseCategory = expenseCat}

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
        Nothing
  case res of
    Left err -> fail $ "initiateExpense failed: " <> show err
    Right (tid, _) -> pure tid

balance :: AppEnv -> AccountId -> IO Rational
balance env aid = do
  m <- runDbIn env (AccountRM.getAccount aid)
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail "balance: account not found"

statusOf :: AppEnv -> TransactionId -> IO TransactionStatus
statusOf env tid = do
  m <- runDbIn env (ReadModel.getTransaction tid)
  case m of
    Just td -> pure td.status
    Nothing -> fail "statusOf: transaction not found"

allocAmounts :: TransactionData -> [Rational]
allocAmounts td = case allocationsOf td.transactionType of
  Just a -> [unMoney al.amount | al <- allAllocations a]
  Nothing -> []

spec :: Spec
spec = describe "Integration / TransactionMerge" $ do
  it "consolidates two expenses into the target and records lineage" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "merge-int-basic@test.com"
    targetId <- postExpense env fx 100
    sourceId <- postExpense env fx 100

    beforeBalance <- balance env fx.regularAccountId
    beforeBalance `shouldBe` 4800 -- 5000 - 100 - 100
    result <- runAppM env (mergeTransactions fx.userId targetId (sourceId :| []))
    case result of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> do
        td.sourceAmount `shouldBe` unsafeMoney Core.USD 200
        td.status `shouldBe` Completed
        allocAmounts td `shouldBe` [100, 100]

    -- Read-model row (re-read from the store, not the returned value).
    Just persisted <- runDbIn env (ReadModel.getTransaction targetId)
    persisted.sourceAmount `shouldBe` unsafeMoney Core.USD 200

    srcStatus <- statusOf env sourceId
    srcStatus `shouldBe` Cancelled

    rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
    rev `shouldBe` [sourceId]
    fwd <- runAppM env (getOutboundRelations sourceId)
    fwd `shouldBe` [(targetId, Merge)]

    -- Balances net: total money moved is conserved (still 4800).
    afterBalance <- balance env fx.regularAccountId
    afterBalance `shouldBe` 4800

  it "fans three expenses into one target" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "merge-int-fanin@test.com"
    targetId <- postExpense env fx 10
    s1 <- postExpense env fx 20
    s2 <- postExpense env fx 30

    result <- runAppM env (mergeTransactions fx.userId targetId (s1 :| [s2]))
    case result of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> td.sourceAmount `shouldBe` unsafeMoney Core.USD 60

    rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
    rev `shouldMatchList` [s1, s2]

  it "refuses to remove the produced Merge lineage edge" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupFixture env "merge-int-lineage@test.com"
    targetId <- postExpense env fx 100
    sourceId <- postExpense env fx 100
    _ <- runAppM env (mergeTransactions fx.userId targetId (sourceId :| []))

    removed <- runAppM env (removeTransactionRelation fx.userId sourceId targetId Merge)
    removed `shouldBe` Left CannotRemoveLineageRelation

  it "completes a merge despite a transient debit that briefly overdraws the account" $ do
    -- Regression for the fix threading 'allowOverdraft' through the amend
    -- saga: this exact scenario used to produce 'InsufficientFundsForAmendment'
    -- because the saga hard-coded 'allowOverdraft = False' on its
    -- 'DebitAccount' regardless of the flag on the amendment event. The
    -- guard firing here was itself the bug — the target amend's debit is
    -- only ever transiently double-counted against the not-yet-reversed
    -- source, and a merge only ever consolidates already-settled amounts.
    env <- createTestAppEnvWithProcessManager
    fx0 <- setupFixture env "merge-int-overdraft@test.com"
    -- Low-balance account: two 40 expenses fit (100 → 60 → 20) but the combined
    -- 80 transiently overdraws it when the target is amended up.
    lowAcc <- createAccount env fx0.userId "Low" defaultCash Core.USD 100
    let fx = fx0 {regularAccountId = lowAcc}
    targetId <- postExpense env fx 40
    sourceId <- postExpense env fx 40

    beforeBalance <- balance env lowAcc
    beforeBalance `shouldBe` 20 -- 100 - 40 - 40
    result <- runAppM env (mergeTransactions fx.userId targetId (sourceId :| []))
    case result of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> do
        td.sourceAmount `shouldBe` unsafeMoney Core.USD 80
        td.status `shouldBe` Completed

    -- Balance nets back to the pre-merge value: the transient dip was
    -- harmless (a merge only consolidates already-settled amounts).
    afterBalance <- balance env lowAcc
    afterBalance `shouldBe` 20

    Just persisted <- runDbIn env (ReadModel.getTransaction targetId)
    persisted.sourceAmount `shouldBe` unsafeMoney Core.USD 80
    persisted.status `shouldBe` Completed
    persisted.amendmentCount `shouldBe` 1

    srcStatus <- statusOf env sourceId
    srcStatus `shouldBe` Cancelled
    rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
    rev `shouldBe` [sourceId]
    fwd <- runAppM env (getOutboundRelations sourceId)
    fwd `shouldBe` [(targetId, Merge)]
