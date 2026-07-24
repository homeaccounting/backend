{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionMergeSpec
-- Description : Service-layer tests for 'mergeTransactions' (tracker#30).
--
-- Merge consolidates 2+ Completed transactions into one survivor (the
-- target). The target absorbs the combined amount and combined
-- allocations; each source records a 'Merge' lineage edge (source →
-- target) while still Completed, then is cancelled.
--
-- These specs mirror 'Application.Services.TransactionAmendmentSpec':
-- they drive the service directly against the synchronous in-memory
-- event store (no Postgres) and assert the read-model outcome.
--
-- Covered:
--
--   * Happy two-Expense fan-in: target = Σ amount, combined allocations,
--     sources Cancelled, Merge edge source → target present.
--   * Happy three-Income fan-in.
--   * Contact rule: all-none → none; one-source-has → merged has it;
--     two-different → 'CannotMergeConflictingContacts'.
--   * Rejections: different currency / different account / mixed kinds /
--     transfer source / self-merge or duplicate / non-Completed source /
--     closed period.
--   * Amend-fails-first: insufficient funds → sources stay Completed, no
--     edges, error surfaced.
--   * Ordering invariant: the Merge edge exists on a now-Cancelled source.
module Application.Services.TransactionMergeSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.ConfigurationService (closeBooksThrough)
import Application.Services.TransactionService
  ( getOutboundRelations,
    getTransaction,
    initiateExpense,
    initiateTransfer,
    mergeTransactions,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( RelationKind (..),
    TransactionId,
    UserId,
    defaultCash,
    unTransactionId,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Projection (TransactionStatus (..))
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    allocAmounts,
    createAccount,
    expenseAllocs,
    postExpense,
    postIncome,
    seedContact,
    seedExchangeRates,
    setupMetadataFixture,
    statusOf,
    unwrapTx,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.Time (utc)

-- -----------------------------------------------------------------------------
-- Local helpers
-- -----------------------------------------------------------------------------

-- | Run the merge service call and return its raw outcome. Merge-specific glue;
-- the reusable posting / query helpers live in 'Testkit.Fixtures'.
runMerge ::
  AppEnv ->
  UserId ->
  TransactionId ->
  NonEmpty TransactionId ->
  IO (Either DomainError TransactionData)
runMerge env uid target sources = runAppM env (mergeTransactions uid target sources)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService.mergeTransactions" $ do
  happyTwoExpenseSpec
  happyThreeIncomeSpec
  contactRuleSpec
  rejectionSpec
  amendFailsFirstSpec

-- -----------------------------------------------------------------------------
-- Happy: two expenses
-- -----------------------------------------------------------------------------

happyTwoExpenseSpec :: Spec
happyTwoExpenseSpec =
  describe "happy path — two expenses"
    $ it "sums the amount, concatenates allocations, cancels the source, and records the Merge edge"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "merge-2exp@test.com"
      targetId <- postExpense env fx 25 Nothing
      sourceId <- postExpense env fx 40 Nothing

      result <- runMerge env fx.userId targetId (sourceId :| [])
      case result of
        Left err -> expectationFailure $ "expected Right, got: " <> show err
        Right td -> do
          -- Combined categorised (source) amount 25 + 40 = 65.
          td.sourceAmount `shouldBe` unsafeMoney Core.USD 65
          td.status `shouldBe` Completed
          -- Combined allocations: one slice per input expense.
          allocAmounts td `shouldBe` [25, 40]

      -- The source is now Cancelled but still carries the Merge edge → target
      -- (ordering invariant: edge written while Completed, survives cancel).
      srcStatus <- statusOf env sourceId
      srcStatus `shouldBe` Cancelled
      fwd <- runAppM env (getOutboundRelations sourceId)
      fwd `shouldBe` [(targetId, Merge)]
      rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
      rev `shouldBe` [sourceId]

-- -----------------------------------------------------------------------------
-- Happy: three incomes fan-in
-- -----------------------------------------------------------------------------

happyThreeIncomeSpec :: Spec
happyThreeIncomeSpec =
  describe "happy path — three incomes"
    $ it "consolidates three incomes into one target with combined amount"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "merge-3inc@test.com"
      targetId <- postIncome env fx 10 Nothing
      s1 <- postIncome env fx 20 Nothing
      s2 <- postIncome env fx 30 Nothing

      result <- runMerge env fx.userId targetId (s1 :| [s2])
      case result of
        Left err -> expectationFailure $ "expected Right, got: " <> show err
        Right td -> do
          -- Income categorised leg is the target amount: 10 + 20 + 30 = 60.
          td.targetAmount `shouldBe` unsafeMoney Core.USD 60
          allocAmounts td `shouldBe` [10, 20, 30]

      for_ [s1, s2] $ \sid -> do
        st <- statusOf env sid
        st `shouldBe` Cancelled
      rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
      rev `shouldMatchList` [s1, s2]

-- -----------------------------------------------------------------------------
-- Contact rule
-- -----------------------------------------------------------------------------

contactRuleSpec :: Spec
contactRuleSpec = describe "contact rule" $ do
  it "leaves the merged contact empty when no input carries one" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-contact-none@test.com"
    targetId <- postExpense env fx 25 Nothing
    sourceId <- postExpense env fx 25 Nothing
    result <- runMerge env fx.userId targetId (sourceId :| [])
    case result of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> td.contactId `shouldBe` Nothing

  it "carries the single contact onto the survivor when only one input has it" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-contact-one@test.com"
    contact <- seedContact env fx.userId "Grocer"
    targetId <- postExpense env fx 25 Nothing
    sourceId <- postExpense env fx 25 (Just contact)
    result <- runMerge env fx.userId targetId (sourceId :| [])
    case result of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> td.contactId `shouldBe` Just contact

  it "rejects two different contacts with CannotMergeConflictingContacts" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-contact-two@test.com"
    c1 <- seedContact env fx.userId "Alice"
    c2 <- seedContact env fx.userId "Bob"
    targetId <- postExpense env fx 25 (Just c1)
    sourceId <- postExpense env fx 25 (Just c2)
    result <- runMerge env fx.userId targetId (sourceId :| [])
    result `shouldBe` Left CannotMergeConflictingContacts

-- -----------------------------------------------------------------------------
-- Rejections
-- -----------------------------------------------------------------------------

rejectionSpec :: Spec
rejectionSpec = describe "rejections" $ do
  it "rejects a different-currency source (CannotMergeDifferentCurrencies)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-cur@test.com"
    -- The UAH expense resolves its External (USD base) leg via the ECB rate.
    seedExchangeRates env [(Core.UAH, Core.USD, 1 / 40), (Core.USD, Core.UAH, 40)]
    targetId <- postExpense env fx 25 Nothing
    uahAcc <- createAccount env fx.userId "Hryvnia" defaultCash Core.UAH 1000
    uahRes <-
      runAppM env
        $ initiateExpense
          fx.userId
          uahAcc
          (unsafeMoney Core.UAH 100)
          (expenseAllocs fx (unsafeMoney Core.UAH 100))
          Set.empty
          "UAH expense"
          Nothing
          Nothing
          Nothing
    sourceId <- unwrapTx "initiateExpense UAH" uahRes
    result <- runMerge env fx.userId targetId (sourceId :| [])
    result `shouldBe` Left CannotMergeDifferentCurrencies

  it "rejects a different-account source (CannotMergeDifferentAccounts)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-acct@test.com"
    targetId <- postExpense env fx 25 Nothing
    otherAcc <- createAccount env fx.userId "Wallet2" defaultCash Core.USD 5000
    otherRes <-
      runAppM env
        $ initiateExpense
          fx.userId
          otherAcc
          (unsafeMoney Core.USD 30)
          (expenseAllocs fx (unsafeMoney Core.USD 30))
          Set.empty
          "Other-account expense"
          Nothing
          Nothing
          Nothing
    sourceId <- unwrapTx "initiateExpense other" otherRes
    result <- runMerge env fx.userId targetId (sourceId :| [])
    result `shouldBe` Left CannotMergeDifferentAccounts

  it "rejects mixed kinds (income target + expense source)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-mixed@test.com"
    targetId <- postIncome env fx 25 Nothing
    sourceId <- postExpense env fx 25 Nothing
    result <- runMerge env fx.userId targetId (sourceId :| [])
    result `shouldBe` Left CannotMergeIncompatibleKinds

  it "rejects a transfer source (CannotMergeIncompatibleKinds)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-transfer@test.com"
    targetId <- postExpense env fx 25 Nothing
    otherAcc <- createAccount env fx.userId "Wallet2" defaultCash Core.USD 5000
    transferRes <-
      runAppM env
        $ initiateTransfer
          fx.userId
          fx.regularAccountId
          otherAcc
          (unsafeMoney Core.USD 15)
          Set.empty
          "Transfer"
          Nothing
          Nothing
          Nothing
    sourceId <- unwrapTx "initiateTransfer" transferRes
    result <- runMerge env fx.userId targetId (sourceId :| [])
    result `shouldBe` Left CannotMergeIncompatibleKinds

  it "rejects merging a transaction with itself" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-self@test.com"
    targetId <- postExpense env fx 25 Nothing
    result <- runMerge env fx.userId targetId (targetId :| [])
    result `shouldBe` Left CannotMergeTransactionWithItself

  it "rejects duplicate source ids" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-dup@test.com"
    targetId <- postExpense env fx 25 Nothing
    sourceId <- postExpense env fx 25 Nothing
    result <- runMerge env fx.userId targetId (sourceId :| [sourceId])
    result `shouldBe` Left CannotMergeTransactionWithItself

  it "rejects a non-Completed source (already cancelled)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-cancelled-src@test.com"
    targetId <- postExpense env fx 25 Nothing
    sourceId <- postExpense env fx 25 Nothing
    -- Merge sourceId away first so it is Cancelled, then try to reuse it.
    _ <- runMerge env fx.userId targetId (sourceId :| [])
    targetId2 <- postExpense env fx 25 Nothing
    result <- runMerge env fx.userId targetId2 (sourceId :| [])
    result `shouldBe` Left CannotEditUncompletedTransaction

  it "rejects a merge that touches a closed period" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-closed@test.com"
    let backdated = utc 2026 3 10
    tgtRes <-
      runAppM env
        $ initiateExpense
          fx.userId
          fx.regularAccountId
          (unsafeMoney Core.USD 25)
          (expenseAllocs fx (unsafeMoney Core.USD 25))
          Set.empty
          "Backdated target"
          (Just backdated)
          Nothing
          Nothing
    targetId <- unwrapTx "initiateExpense backdated" tgtRes
    sourceId <- postExpense env fx 25 Nothing
    _ <- runAppM env (closeBooksThrough fx.userId (utc 2026 3 31))
    result <- runMerge env fx.userId targetId (sourceId :| [])
    case result of
      Left (CannotEditClosedPeriod _ _) -> pure ()
      other -> expectationFailure $ "expected CannotEditClosedPeriod, got: " <> show other

-- -----------------------------------------------------------------------------
-- Amend fails first (clean abort)
-- -----------------------------------------------------------------------------

amendFailsFirstSpec :: Spec
amendFailsFirstSpec =
  describe "atomicity — a failing leg rolls the whole merge back"
    $ it "forces the target amend to fail and asserts nothing changed (target unamended, source Completed, no edge)"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx0 <- setupMetadataFixture env "merge-amend-fail@test.com"
      -- A low-balance account so the combined amount overdraws it.
      lowAcc <- createAccount env fx0.userId "Low" defaultCash Core.USD 100
      let fx = fx0 {regularAccountId = lowAcc}
      -- Two expenses that fit individually (100 → 60 → 20) but whose combined
      -- amount (80) overdraws the account when the target is amended up.
      targetId <- postExpense env fx 40 Nothing
      sourceId <- postExpense env fx 40 Nothing

      result <- runMerge env fx.userId targetId (sourceId :| [])
      case result of
        Left (InsufficientFundsForAmendment _) -> pure ()
        other -> expectationFailure $ "expected InsufficientFundsForAmendment, got: " <> show other

      -- Target is NOT amended: still 40, amendmentCount still 0, still Completed.
      targetTd <- runAppM env (getTransaction (unTransactionId targetId))
      case targetTd of
        Left err -> expectationFailure $ "getTransaction target failed: " <> show err
        Right (_, td) -> do
          td.status `shouldBe` Completed
          td.sourceAmount `shouldBe` unsafeMoney Core.USD 40
          td.amendmentCount `shouldBe` 0
          allocAmounts td `shouldBe` [40]

      -- Nothing was consumed on the source: still Completed, no Merge edge.
      srcStatus <- statusOf env sourceId
      srcStatus `shouldBe` Completed
      fwd <- runAppM env (getOutboundRelations sourceId)
      fwd `shouldBe` []
      rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
      rev `shouldBe` []
