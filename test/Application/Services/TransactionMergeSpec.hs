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
--   * Ordering invariant: the Merge edge exists on a now-Cancelled source.
--   * Overdraft bypass: the merge-originated amend intentionally bypasses
--     the balance guard (allowOverdraft = True on
--     'TransactionMergeManager.amendEffect'), so a transient double-debit
--     against a since-reversed source no longer fails the merge. (Prior to
--     that fix, the same scenario below produced
--     'InsufficientFundsForAmendment'; the guard firing was itself the bug.)
module Application.Services.TransactionMergeSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.ConfigurationService (closeBooksThrough)
import Application.Services.TransactionService
  ( getOutboundRelations,
    initiateExpense,
    initiateIncome,
    initiateTransfer,
    mergeTransactions,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    Money,
    RelationKind (..),
    TransactionId,
    TransactionKind (..),
    UserId,
    defaultCash,
    kindOf,
    unMoney,
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
    incomeAllocs,
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

-- | Read an account's current balance from the (in-memory) read model,
-- failing the test if the account is missing. Merge-spec glue for asserting
-- balance conservation across a transfer-merge.
getBalance :: AppEnv -> AccountId -> IO Money
getBalance env accId = do
  mAcc <- runDbIn env (AccountRM.getAccount accId)
  case mAcc of
    Just acc -> pure acc.balance
    Nothing -> fail $ "getBalance: account not found: " <> show accId

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
  overdraftBypassSpec
  transferMergeSpec

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

  -- tracker#44: Income target + Expense source is now the recognised
  -- transfer-merge shape (see 'transferMergeSpec'), so this case is
  -- expressed the other way round — Expense target + Income source is
  -- NOT auto-oriented into a transfer-merge and still falls through to
  -- the same-kind path.
  it "rejects mixed kinds (expense target + income source)" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-mixed@test.com"
    targetId <- postExpense env fx 25 Nothing
    sourceId <- postIncome env fx 25 Nothing
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
-- Transient overdraft during amend (guard bypass)
-- -----------------------------------------------------------------------------

-- | Prior to the fix threading 'TransactionAmendmentInitiated.allowOverdraft'
-- through the saga (the saga hard-coded @allowOverdraft = False@ on its
-- 'DebitAccount' regardless of the flag on the event), this exact scenario
-- produced 'InsufficientFundsForAmendment' and rolled the whole merge back.
-- That guard firing was itself the bug: the target amend's debit is only
-- ever transiently double-counted against the not-yet-reversed source, and
-- the merge amend now sets @allowOverdraft = True@ specifically to bypass
-- it. The merge completes and — since a merge only ever consolidates
-- already-settled amounts — the final balance nets back to what it was
-- before the merge.
amendFailsFirstSpec :: Spec
amendFailsFirstSpec =
  describe "transient overdraft during amend"
    $ it "completes the merge despite a transient debit that briefly overdraws the account"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx0 <- setupMetadataFixture env "merge-amend-overdraft@test.com"
      -- A low-balance account so the combined amount transiently overdraws it.
      lowAcc <- createAccount env fx0.userId "Low" defaultCash Core.USD 100
      let fx = fx0 {regularAccountId = lowAcc}
      -- Two expenses that fit individually (100 → 60 → 20) but whose combined
      -- amount (80) transiently overdraws the account when the target is
      -- amended up (before the source's debit is reversed by its cancel).
      targetId <- postExpense env fx 40 Nothing
      sourceId <- postExpense env fx 40 Nothing

      result <- runMerge env fx.userId targetId (sourceId :| [])
      case result of
        Left err -> expectationFailure $ "expected Right, got: " <> show err
        Right td -> do
          td.status `shouldBe` Completed
          td.sourceAmount `shouldBe` unsafeMoney Core.USD 80
          td.amendmentCount `shouldBe` 1
          allocAmounts td `shouldBe` [40, 40]

      -- The source was consumed into the merge as usual.
      srcStatus <- statusOf env sourceId
      srcStatus `shouldBe` Cancelled
      fwd <- runAppM env (getOutboundRelations sourceId)
      fwd `shouldBe` [(targetId, Merge)]
      rev <- runDbIn env (ReadModel.reverseRelations targetId Merge)
      rev `shouldBe` [sourceId]

      -- Balance nets back to the pre-merge value: the transient dip was
      -- harmless (a merge only consolidates already-settled amounts).
      balAfter <- runDbIn env (AccountRM.getAccount lowAcc)
      case balAfter of
        Just acc -> unMoney acc.balance `shouldBe` 20 -- 100 - 40 - 40
        Nothing -> expectationFailure "getAccount lowAcc: not found"

-- -----------------------------------------------------------------------------
-- Overdraft bypass (tracker#30 follow-up): merge-originated amend bypasses
-- the transient balance guard.
-- -----------------------------------------------------------------------------

-- | A Regular account allows no overdraft by default (overdraftLimit = Just
-- 0). The merge saga amends the target UP to the combined amount before the
-- source's own debit is reversed by its cancel, so the target account
-- transiently sees an extra debit on top of both settled expenses. That
-- transient dip must not block an otherwise-valid merge (see
-- 'TransactionMergeManager.amendEffect' — allowOverdraft = True).
overdraftBypassSpec :: Spec
overdraftBypassSpec =
  describe "overdraft bypass"
    $ it "completes a merge even when the combined amend debit exceeds the source balance"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx0 <- setupMetadataFixture env "merge-overdraft-bypass@test.com"
      -- A zero-balance account so we control the exact arithmetic (the
      -- fixture's default wallet starts pre-funded at 5000).
      zeroAcc <- createAccount env fx0.userId "Empty" defaultCash Core.USD 0
      let fx = fx0 {regularAccountId = zeroAcc}
      -- Fund the account to exactly 65, then spend it all: 65 -> 40 -> 0.
      _ <- postIncome env fx 65 Nothing
      targetId <- postExpense env fx 25 Nothing
      sourceId <- postExpense env fx 40 Nothing

      -- Merge raises the target from 25 to 65 (25 + 40): a transient +40
      -- debit on an account that is currently at 0.
      result <- runMerge env fx.userId targetId (sourceId :| [])
      case result of
        Left err -> expectationFailure $ "expected Right, got: " <> show err
        Right td -> do
          td.status `shouldBe` Completed
          td.sourceAmount `shouldBe` unsafeMoney Core.USD 65

      srcStatus <- statusOf env sourceId
      srcStatus `shouldBe` Cancelled

-- -----------------------------------------------------------------------------
-- Transfer-merge (tracker#44): income target + expense source -> Transfer
-- -----------------------------------------------------------------------------

transferMergeSpec :: Spec
transferMergeSpec = describe "transfer-merge (income target + expense source)" $ do
  it "amends the income into a Transfer, cancels the expense, and links a Merge edge" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-transfer-happy@test.com"
    -- Account A (fx's default wallet) is debited by the expense; account B is
    -- credited by the income. Equal amount, same currency.
    accB <- createAccount env fx.userId "Wallet B" defaultCash Core.USD 5000
    expenseId <- postExpense env fx 50 Nothing
    incomeRes <-
      runAppM env
        $ initiateIncome
          fx.userId
          accB
          (unsafeMoney Core.USD 50)
          (incomeAllocs fx (unsafeMoney Core.USD 50))
          Set.empty
          "Income"
          Nothing
          Nothing
          Nothing
    incomeId <- unwrapTx "initiateIncome" incomeRes

    result2 <- runMerge env fx.userId incomeId (expenseId :| [])
    case result2 of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> do
        kindOf td.transactionType `shouldBe` TransferKind
        td.status `shouldBe` Completed

    srcStatus <- statusOf env expenseId
    srcStatus `shouldBe` Cancelled
    fwd <- runAppM env (getOutboundRelations expenseId)
    fwd `shouldBe` [(incomeId, Merge)]

  it "merges a cross-account income+expense into one transfer with balances conserved" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-transfer-balances@test.com"
    -- Account A (fx's default wallet, funded at 5000) is debited by the
    -- expense; account B (also funded at 5000) is credited by the income.
    accB <- createAccount env fx.userId "Wallet B" defaultCash Core.USD 5000
    expenseId <- postExpense env fx 50 Nothing
    incomeRes <-
      runAppM env
        $ initiateIncome
          fx.userId
          accB
          (unsafeMoney Core.USD 50)
          (incomeAllocs fx (unsafeMoney Core.USD 50))
          Set.empty
          "Income"
          Nothing
          Nothing
          Nothing
    incomeId <- unwrapTx "initiateIncome" incomeRes

    -- Balances after posting but before the merge: A already debited once by
    -- the expense (5000 - 50 = 4950), B already credited once by the income
    -- (5000 + 50 = 5050).
    balABefore <- getBalance env fx.regularAccountId
    balBBefore <- getBalance env accB
    balABefore `shouldBe` unsafeMoney Core.USD 4950
    balBBefore `shouldBe` unsafeMoney Core.USD 5050

    result <- runMerge env fx.userId incomeId (expenseId :| [])
    case result of
      Left err -> expectationFailure $ "expected Right, got: " <> show err
      Right td -> do
        kindOf td.transactionType `shouldBe` TransferKind
        td.status `shouldBe` Completed

    -- The merge converts the two separate bookings into a single Transfer
    -- A -> B for the same amount: neither account's net balance may move,
    -- despite the saga's transient double-debit on A mid-cascade.
    balAAfter <- getBalance env fx.regularAccountId
    balBAfter <- getBalance env accB
    balAAfter `shouldBe` balABefore
    balBAfter `shouldBe` balBBefore

  it "rejects when the two legs are on the same account" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-transfer-sameacct@test.com"
    -- Both posted against the fixture's single wallet: the income's real
    -- (target) account and the expense's real (source) account coincide.
    targetId <- postIncome env fx 50 Nothing
    sourceId <- postExpense env fx 50 Nothing
    result <- runMerge env fx.userId targetId (sourceId :| [])
    result `shouldBe` Left TransferMergeSameAccount

  it "rejects when the amounts differ" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "merge-transfer-mismatch@test.com"
    accB <- createAccount env fx.userId "Wallet B" defaultCash Core.USD 5000
    expenseId <- postExpense env fx 400 Nothing
    incomeRes <-
      runAppM env
        $ initiateIncome
          fx.userId
          accB
          (unsafeMoney Core.USD 500)
          (incomeAllocs fx (unsafeMoney Core.USD 500))
          Set.empty
          "Income"
          Nothing
          Nothing
          Nothing
    incomeId <- unwrapTx "initiateIncome" incomeRes
    result <- runMerge env fx.userId incomeId (expenseId :| [])
    result `shouldBe` Left TransferMergeLegsDoNotMatch
