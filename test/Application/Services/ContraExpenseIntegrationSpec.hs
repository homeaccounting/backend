{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ContraExpenseIntegrationSpec
-- Description : End-to-end contra-expense allocation tests.
--
-- Validates the full contra-expense flow end-to-end through the service
-- layer with the in-memory event store and transfer process manager:
--
--   1. Mixed Income (incomes + expenses buckets populated) posts at the
--      total amount; both buckets survive verbatim in 'TransactionData'.
--   2. Per-category netting: @expenseNet(Rent) = Σ(expense bucket on
--      Expense txns) − Σ(expense bucket on Income txns)@ is computed
--      in-test and verified to be zero when a $500 rent expense cancels
--      the $500 contra-expense slice of the mixed income.
--   3. Standalone refund: an Income with only an expenses bucket credits
--      the account at the full total and yields a negative
--      @expenseNet(Cat) = −total@.
--
-- The netting logic is an in-test helper — it is NOT production code;
-- it exists only to validate that the stored data supports the documented
-- reporting contract.
module Application.Services.ContraExpenseIntegrationSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TxRM
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    expenseCategoryDictKind,
    incomeCategoryDictKind,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Set as Set
import Domain.Configuration.Dictionary (EntryRole (ItemRole))
import Domain.Core.Errors (DomainError)
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Allocations (..),
    Currency (..),
    DictionaryEntryId,
    Money (..),
    TransactionId,
    TransactionType (..),
    UserId,
    allocationsOf,
    mkExpenseAllocations,
    mkMixedAllocations,
    unMoney,
    unsafeEntryName,
    unsafeMoney,
  )
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, registerUser)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

data Harness = Harness
  { harnessEnv :: !AppEnv,
    harnessUser :: !UserId,
    harnessAccount :: !AccountId,
    harnessSalary :: !DictionaryEntryId,
    harnessRent :: !DictionaryEntryId,
    harnessRefundCat :: !DictionaryEntryId
  }

setupHarness :: Text -> IO Harness
setupHarness email = do
  env <- createTestAppEnvWithProcessManager
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  accId <- createDefaultAccount env uid "Wallet USD"

  salaryId <- addIncomeEntry env uid "CE-Salary"
  rentId <- addExpenseEntry env uid "CE-Rent"
  refundCatId <- addExpenseEntry env uid "CE-Refundable"

  pure
    Harness
      { harnessEnv = env,
        harnessUser = uid,
        harnessAccount = accId,
        harnessSalary = salaryId,
        harnessRent = rentId,
        harnessRefundCat = refundCatId
      }

addIncomeEntry :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
addIncomeEntry env uid name = do
  res <- runAppM env $ addDictionaryEntry uid incomeCategoryDictKind (unsafeEntryName name) ItemRole Nothing
  unwrap ("addDictionaryEntry(income) " <> show name) res

addExpenseEntry :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
addExpenseEntry env uid name = do
  res <- runAppM env $ addDictionaryEntry uid expenseCategoryDictKind (unsafeEntryName name) ItemRole Nothing
  unwrap ("addDictionaryEntry(expense) " <> show name) res

unwrap :: String -> Either DomainError a -> IO a
unwrap ctx = either (\err -> fail $ ctx <> " failed: " <> show err) pure

ccy :: Currency
ccy = USD

money :: Rational -> Money
money = unsafeMoney ccy

-- | Read the balance of an account; fails the test if the account is absent.
balanceOf :: AppEnv -> AccountId -> IO Rational
balanceOf env aid = do
  m <- runDbIn env (AccountRM.getAccount aid)
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail "balanceOf: account not found"

-- | Retrieve a transaction from the read model; fails the test if absent.
getTx :: AppEnv -> TransactionId -> IO TransactionData
getTx env txId = do
  mTd <- runDbIn env (TxRM.getTransaction txId)
  case mTd of
    Nothing -> fail $ "getTx: transaction not found: " <> show txId
    Just td -> pure td

-- | Post an Income via the service layer. Returns (txId, TransactionData).
postIncome ::
  Harness ->
  Money ->
  Allocations ->
  IO (TransactionId, TransactionData)
postIncome h amt allocs = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateIncome
        h.harnessUser
        h.harnessAccount
        amt
        allocs
        Set.empty
        "Test income"
        Nothing
        Nothing
        Nothing
  unwrap "initiateIncome" res

-- | Post an Expense via the service layer. Returns (txId, TransactionData).
postExpense ::
  Harness ->
  Money ->
  Allocations ->
  IO (TransactionId, TransactionData)
postExpense h amt allocs = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateExpense
        h.harnessUser
        h.harnessAccount
        amt
        allocs
        Set.empty
        "Test expense"
        Nothing
        Nothing
        Nothing
  unwrap "initiateExpense" res

-- -----------------------------------------------------------------------------
-- In-test netting helper
-- -----------------------------------------------------------------------------

-- | Compute @expenseNet(catId)@ by folding over the full read model,
-- following the documented contract:
--
--   expenseNet(c) = Σ(expense-bucket amounts on Expense txns with catId c)
--                − Σ(expense-bucket amounts on Income  txns with catId c)
--
-- This is intentionally NOT production code — it exists only to prove that
-- the stored 'TransactionData' supports the contract.
expenseNet :: AppEnv -> AccountId -> DictionaryEntryId -> IO Rational
expenseNet env acct catId = do
  -- All reporting-eligible (Completed) transactions touching the account.
  txList <- runDbIn env (TxRM.reportableTransactions (Set.singleton acct) Nothing Nothing)
  let -- Sum the expense-bucket slices for 'catId' on one transaction.
      expenseSlices td = case allocationsOf td.transactionType of
        Nothing -> 0
        Just allocs -> sum [a.amount.amount | a <- allocs.expenses, a.categoryId == catId]
      expenseOnExpenseTxns = sum [expenseSlices td | td <- txList, isExpenseTxn td.transactionType]
      expenseOnIncomeTxns = sum [expenseSlices td | td <- txList, isIncomeTxn td.transactionType]
  pure (expenseOnExpenseTxns - expenseOnIncomeTxns)
  where
    isExpenseTxn (Expense _) = True
    isExpenseTxn _ = False
    isIncomeTxn (Income _) = True
    isIncomeTxn _ = False

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Application.Services / ContraExpense end-to-end" $ do
  it "1. Mixed Income posts at total only; both allocation buckets are intact" $ do
    h <- setupHarness "contra-mixed-income@test.com"

    let total = money 5500
        allocs =
          mkMixedAllocations
            (Allocation h.harnessSalary (money 5000) Nothing :| [])
            (Allocation h.harnessRent (money 500) Nothing :| [])

    balanceBefore <- balanceOf h.harnessEnv h.harnessAccount

    (txId, _) <- postIncome h total allocs

    -- (a) The Regular account was credited the FULL $5500 total.
    balanceAfter <- balanceOf h.harnessEnv h.harnessAccount
    (balanceAfter - balanceBefore) `shouldBe` 5500

    -- (b) Stored TransactionType is Income with both buckets intact.
    td <- getTx h.harnessEnv txId
    case td.transactionType of
      Income stored -> do
        stored `shouldBe` allocs
        let incomeSum = sum [a.amount.amount | a <- stored.incomes]
            expenseSum = sum [a.amount.amount | a <- stored.expenses]
        incomeSum `shouldBe` 5000
        expenseSum `shouldBe` 500
      other ->
        expectationFailure
          $ "expected Income transactionType, got: "
          <> show other

  it "2. Per-category netting: expenseNet(Rent) = 0 after mixed income + rent expense" $ do
    h <- setupHarness "contra-netting@test.com"

    -- Post mixed income with $500 rent reimbursement slice.
    let incomeTotal = money 5500
        incomeAllocs =
          mkMixedAllocations
            (Allocation h.harnessSalary (money 5000) Nothing :| [])
            (Allocation h.harnessRent (money 500) Nothing :| [])
    _ <- postIncome h incomeTotal incomeAllocs

    -- Post a standalone $500 rent expense.
    let expenseTotal = money 500
        expenseAllocs =
          mkExpenseAllocations
            (Allocation h.harnessRent expenseTotal Nothing :| [])
    _ <- postExpense h expenseTotal expenseAllocs

    -- expenseNet(Rent) = 500 (expense txn) − 500 (income txn contra slice) = 0
    net <- expenseNet h.harnessEnv h.harnessAccount h.harnessRent
    net `shouldBe` 0

  it "3. Standalone refund (pure-expense-bucket Income) credits account and yields negative expenseNet" $ do
    h <- setupHarness "contra-refund@test.com"

    let total = money 40
        allocs =
          mkExpenseAllocations
            (Allocation h.harnessRefundCat total Nothing :| [])

    balanceBefore <- balanceOf h.harnessEnv h.harnessAccount

    (txId, _) <- postIncome h total allocs

    -- (a) Account balance increased by $40 (the full posted amount).
    balanceAfter <- balanceOf h.harnessEnv h.harnessAccount
    (balanceAfter - balanceBefore) `shouldBe` 40

    -- Sanity: the stored type is Income with only the expenses bucket.
    td <- getTx h.harnessEnv txId
    case td.transactionType of
      Income stored -> do
        stored `shouldBe` allocs
        length stored.incomes `shouldBe` 0
        length stored.expenses `shouldBe` 1
      other ->
        expectationFailure
          $ "expected Income transactionType, got: "
          <> show other

    -- (b) expenseNet(RefundCat) = −$40 (contra-only, no prior expense).
    net <- expenseNet h.harnessEnv h.harnessAccount h.harnessRefundCat
    net `shouldBe` (-40)
