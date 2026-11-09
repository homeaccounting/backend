{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.ReportingServiceSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.Services.ReportingService as R
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (utctDay)
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
      tt = Expense (mkExpenseAllocations (Allocation c m Nothing :| []))
   in mockTransactionData (mockAccountIdN 1) (mockAccountIdN 9) m m Nothing tt

-- | A reimbursement: an Income txn that carries an expense-bucket (contra)
-- allocation against category @c@, exercising the spend-subtraction path.
reimbursementTo :: CategoryId -> Rational -> TransactionData
reimbursementTo c amt =
  let m = unsafeMoney UAH amt
      incSlice = Allocation (mockCategoryIdN 99) (unsafeMoney UAH 1) Nothing
      tt = Income (mkMixedAllocations (incSlice :| []) (Allocation c m Nothing :| []))
   in mockTransactionData (mockAccountIdN 9) (mockAccountIdN 1) (unsafeMoney UAH (amt + 1)) (unsafeMoney UAH (amt + 1)) Nothing tt

-- | A transfer carrying a single fee allocation in the fee's own currency.
feeTransfer :: CategoryId -> Money -> TransactionData
feeTransfer c fee =
  let tt = Transfer (Just (mkExpenseAllocations (Allocation c fee Nothing :| [])))
      src = unsafeMoney fee.currency 1000
   in mockTransactionData (mockAccountIdN 1) (mockAccountIdN 2) src src Nothing tt

spec :: Spec
spec = describe "ReportingService pure aggregation" $ do
  describe "transfer fees" $ do
    let c = mockCategoryIdN 3
        plain = mockTransactionData (mockAccountIdN 1) (mockAccountIdN 2) (unsafeMoney UAH 5) (unsafeMoney UAH 5) Nothing (Transfer Nothing)

    it "a UAH fee on a UAH transfer adds exactly the fee to expense and to its category" $ do
      let td = feeTransfer c (unsafeMoney UAH 5)
          (i, e, n) = R.aggregateIncomeExpense UAH Map.empty [td]
      e `shouldBe` unsafeMoney UAH 5
      i `shouldBe` unsafeMoney UAH 0
      n `shouldBe` unsafeMoney UAH (-5)
      Map.lookup c (R.aggregateSpending UAH Map.empty [td]) `shouldBe` Just (unsafeMoney UAH 5)

    it "a plain transfer adds nothing" $ do
      R.aggregateIncomeExpense UAH Map.empty [plain] `shouldBe` (unsafeMoney UAH 0, unsafeMoney UAH 0, unsafeMoney UAH 0)
      R.aggregateSpending UAH Map.empty [plain] `shouldBe` Map.empty

    it "a USD fee converts with the FeeRates rate" $ do
      let td = feeTransfer c (unsafeMoney USD 2)
          rates = Map.singleton (utctDay td.date, USD) (unsafeExchangeRate USD UAH 40)
      Map.lookup c (R.aggregateSpending UAH rates [td]) `shouldBe` Just (unsafeMoney UAH 80)
      (\(_, e, _) -> e) (R.aggregateIncomeExpense UAH rates [td]) `shouldBe` unsafeMoney UAH 80

    it "reportableTxns admits fee transfers and still drops plain ones" $ do
      let visible = Set.fromList [mockAccountIdN 1, mockAccountIdN 2]
          m = Map.fromList [(mockTransactionIdN 1, feeTransfer c (unsafeMoney UAH 5)), (mockTransactionIdN 2, plain)]
      length (R.reportableTxns visible Nothing Nothing m) `shouldBe` 1

  it "allocationBase is identity when same-currency (exchangeRate Nothing)" $ do
    let m = unsafeMoney UAH 100
    R.allocationBase (expenseTo (mockCategoryIdN 1) 100) m `shouldBe` m

  it "allocationBase scales a cross-currency expense allocation by external/regular" $ do
    let er = unsafeExchangeRate USD UAH 40
        td =
          mockTransactionData
            (mockAccountIdN 1)
            (mockAccountIdN 9)
            (unsafeMoney USD 10)
            (unsafeMoney UAH 400)
            (Just er)
            (Expense (mkExpenseAllocations (Allocation (mockCategoryIdN 1) (unsafeMoney USD 10) Nothing :| [])))
    R.allocationBase td (unsafeMoney USD 10) `shouldBe` unsafeMoney UAH 400

  it "sums two allocations on the same category into a single spending entry" $ do
    -- Two expense allocations on one category (distinct comments) must aggregate
    -- to a single Map entry summing their amounts; comments do not affect it.
    let c = mockCategoryIdN 1
        m = unsafeMoney UAH 200
        m' = unsafeMoney UAH 160
        tt =
          Expense
            ( mkExpenseAllocations
                (Allocation c m (Just "eggs") :| [Allocation c m' (Just "veg")])
            )
        td = mockTransactionData (mockAccountIdN 1) (mockAccountIdN 9) (unsafeMoney UAH 360) (unsafeMoney UAH 360) Nothing tt
        result = R.aggregateSpending UAH Map.empty [td]
    Map.lookup c result `shouldBe` Just (unsafeMoney UAH 360)
    Map.size result `shouldBe` 1

  it "spending nets a reimbursement (expense-bucket on an Income txn) down" $ do
    let c = mockCategoryIdN 1
        m = R.aggregateSpending UAH Map.empty [expenseTo c 100, reimbursementTo c 30]
    Map.lookup c m `shouldBe` Just (unsafeMoney UAH 70)

  it "income/expense respects buckets: net = income - expense" $ do
    let inc =
          mockTransactionData
            (mockAccountIdN 9)
            (mockAccountIdN 1)
            (unsafeMoney UAH 500)
            (unsafeMoney UAH 500)
            Nothing
            (Income (mkIncomeAllocations (Allocation (mockCategoryIdN 5) (unsafeMoney UAH 500) Nothing :| [])))
        (i, e, n) = R.aggregateIncomeExpense UAH Map.empty [inc, expenseTo (mockCategoryIdN 2) 200]
    i `shouldBe` unsafeMoney UAH 500
    e `shouldBe` unsafeMoney UAH 200
    n `shouldBe` unsafeMoney UAH 300

  it "reportableTxns drops Pending/Cancelled, Transfers, and out-of-range" $ do
    let visible = Set.fromList [mockAccountIdN 1, mockAccountIdN 9]
        completed = expenseTo (mockCategoryIdN 1) 100
        pendingTd = (completed :: TransactionData) {status = Pending}
        transferTd = mockTransactionData (mockAccountIdN 1) (mockAccountIdN 2) (unsafeMoney UAH 5) (unsafeMoney UAH 5) Nothing (Transfer Nothing)
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
