{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.ReportingServiceSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.Services.ReportingService as R
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Core.Types
import Domain.Transaction.Projection (TransactionStatus (..))
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountData,
    mockAccountIdN,
    mockCategoryIdN,
    mockTransactionData,
    mockTransactionIdN,
    mockUserIdN,
  )

-- | A single-category expense from a Regular account to External, used as the
-- canonical positive-spend fixture.
expenseTo :: CategoryId -> Rational -> TransactionData
expenseTo c amt =
  let m = unsafeMoney UAH amt
      tt = Expense (mkExpenseAllocations (Allocation c m :| []))
   in mockTransactionData (mockAccountIdN 1) (mockAccountIdN 9) m m Nothing tt

-- | A reimbursement: an Income txn that carries an expense-bucket (contra)
-- allocation against category @c@, exercising the spend-subtraction path.
reimbursementTo :: CategoryId -> Rational -> TransactionData
reimbursementTo c amt =
  let m = unsafeMoney UAH amt
      incSlice = Allocation (mockCategoryIdN 99) (unsafeMoney UAH 1)
      tt = Income (mkMixedAllocations (incSlice :| []) (Allocation c m :| []))
   in mockTransactionData (mockAccountIdN 9) (mockAccountIdN 1) (unsafeMoney UAH (amt + 1)) (unsafeMoney UAH (amt + 1)) Nothing tt

spec :: Spec
spec = describe "ReportingService pure aggregation" $ do
  it "allocationBase is identity when same-currency (exchangeRate Nothing)" $ do
    let m = unsafeMoney UAH 100
    R.allocationBase (expenseTo (mockCategoryIdN 1) 100) m `shouldBe` m

  it "allocationBase scales a cross-currency expense allocation by external/regular" $ do
    let Right er = mkExchangeRate USD UAH 40
        td =
          mockTransactionData
            (mockAccountIdN 1)
            (mockAccountIdN 9)
            (unsafeMoney USD 10)
            (unsafeMoney UAH 400)
            (Just er)
            (Expense (mkExpenseAllocations (Allocation (mockCategoryIdN 1) (unsafeMoney USD 10) :| [])))
    R.allocationBase td (unsafeMoney USD 10) `shouldBe` unsafeMoney UAH 400

  it "spending nets a reimbursement (expense-bucket on an Income txn) down" $ do
    let c = mockCategoryIdN 1
        m = R.aggregateSpending UAH [expenseTo c 100, reimbursementTo c 30]
    Map.lookup c m `shouldBe` Just (unsafeMoney UAH 70)

  it "income/expense respects buckets: net = income - expense" $ do
    let inc =
          mockTransactionData
            (mockAccountIdN 9)
            (mockAccountIdN 1)
            (unsafeMoney UAH 500)
            (unsafeMoney UAH 500)
            Nothing
            (Income (mkIncomeAllocations (Allocation (mockCategoryIdN 5) (unsafeMoney UAH 500) :| [])))
        (i, e, n) = R.aggregateIncomeExpense UAH [inc, expenseTo (mockCategoryIdN 2) 200]
    i `shouldBe` unsafeMoney UAH 500
    e `shouldBe` unsafeMoney UAH 200
    n `shouldBe` unsafeMoney UAH 300

  it "reportableTxns drops Pending/Cancelled, Transfers, and out-of-range" $ do
    let visible = Set.fromList [mockAccountIdN 1, mockAccountIdN 9]
        completed = expenseTo (mockCategoryIdN 1) 100
        pendingTd = (completed :: TransactionData) {status = Pending}
        transferTd = mockTransactionData (mockAccountIdN 1) (mockAccountIdN 2) (unsafeMoney UAH 5) (unsafeMoney UAH 5) Nothing Transfer
        m = Map.fromList [(mockTransactionIdN 1, completed), (mockTransactionIdN 2, pendingTd), (mockTransactionIdN 3, transferTd)]
    length (R.reportableTxns visible Nothing Nothing m) `shouldBe` 1
    all (isCategorised . (.transactionType)) (R.reportableTxns visible Nothing Nothing m) `shouldBe` True

  describe "ownedRegularOpened (net-worth scoping)" $ do
    let me = mockUserIdN 1
        other = mockUserIdN 2
        bal = unsafeMoney USD 100
        regularOpened = mockAccountData me (Regular defaultCash) Opened bal
        external = mockAccountData me External Opened bal
        closed = mockAccountData me (Regular defaultCash) Closed bal
        foreign_ = mockAccountData other (Regular defaultCash) Opened bal
        allAccts =
          [ (mockAccountIdN 1, regularOpened),
            (mockAccountIdN 2, external),
            (mockAccountIdN 3, closed),
            (mockAccountIdN 4, foreign_)
          ]

    it "keeps a Regular + Opened account owned by the user"
      $ map fst (R.ownedRegularOpened me allAccts)
      `shouldBe` [mockAccountIdN 1]

    it "excludes an External account"
      $ mockAccountIdN 2
      `notElem` map fst (R.ownedRegularOpened me allAccts)
      `shouldBe` True

    it "excludes a Closed account"
      $ mockAccountIdN 3
      `notElem` map fst (R.ownedRegularOpened me allAccts)
      `shouldBe` True

    it "excludes a Regular + Opened account owned by another user"
      $ mockAccountIdN 4
      `notElem` map fst (R.ownedRegularOpened me allAccts)
      `shouldBe` True
