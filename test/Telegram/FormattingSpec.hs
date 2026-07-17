{-# LANGUAGE OverloadedStrings #-}

module Telegram.FormattingSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    CategoryId,
    Currency (..),
    LabelId,
    TransactionType (..),
    mkAllocation,
    mkExchangeRate,
    mkExpenseAllocations,
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
  )
import Domain.Transaction.Projection (TransactionStatus (..))
import Telegram.Formatting (formatRecordedTransaction, formatTransactionLine)
import Test.Hspec
import Testkit.Helpers (singletonExpense, singletonIncome)

uuidFromInt :: Int -> UUID.UUID
uuidFromInt n =
  let s = "00000000-0000-0000-0000-" <> replicate (12 - length (show n)) '0' <> show n
   in fromMaybe (error "bad uuid") (UUID.fromString s)

sampleTxn :: TransactionType -> TransactionData
sampleTxn tt =
  TransactionData
    { sourceAccountId = unsafeAccountId (uuidFromInt 1),
      targetAccountId = unsafeAccountId (uuidFromInt 2),
      sourceAmount = unsafeMoney USD 300,
      targetAmount = unsafeMoney USD 300,
      exchangeRate = Nothing,
      description = "McDonald's",
      status = Completed,
      transactionType = tt,
      date = UTCTime (fromGregorian 2026 4 18) (secondsToDiffTime (14 * 3600 + 30 * 60)),
      mcc = Nothing,
      labels = Set.empty,
      relations = [],
      amendmentCount = 0
    }

foodCat :: CategoryId
foodCat = unsafeDictionaryEntryId (uuidFromInt 10)

salaryCat :: CategoryId
salaryCat = unsafeDictionaryEntryId (uuidFromInt 11)

orphanCat :: CategoryId
orphanCat = unsafeDictionaryEntryId (uuidFromInt 99)

lunchLabel :: LabelId
lunchLabel = unsafeDictionaryEntryId (uuidFromInt 20)

kyivLabel :: LabelId
kyivLabel = unsafeDictionaryEntryId (uuidFromInt 21)

orphanLabel :: LabelId
orphanLabel = unsafeDictionaryEntryId (uuidFromInt 98)

names :: Map.Map CategoryId T.Text
names =
  Map.fromList
    [ (foodCat, "Food"),
      (salaryCat, "Salary"),
      (lunchLabel, "lunch"),
      (kyivLabel, "kyiv")
    ]

-- | Build an Expense TransactionType whose single allocation carries the
-- sample transaction's amount.
expenseFor :: CategoryId -> TransactionType
expenseFor c = singletonExpense c (unsafeMoney USD 300)

incomeFor :: CategoryId -> TransactionType
incomeFor c = singletonIncome c (unsafeMoney USD 300)

-- Account name map: account 1 = "Cash", account 2 = "Savings".
acctNames :: Map.Map AccountId T.Text
acctNames =
  Map.fromList
    [ (unsafeAccountId (uuidFromInt 1), "Cash"),
      (unsafeAccountId (uuidFromInt 2), "Savings")
    ]

-- A multi-allocation expense: 4.00 to Food (with a comment) and 16.00 to
-- Salary (no comment), totalling 20.00.
multiExpense :: TransactionType
multiExpense =
  let a1 = either (error . show) id (mkAllocation foodCat (unsafeMoney USD 4) (Just "latte"))
      a2 = either (error . show) id (mkAllocation salaryCat (unsafeMoney USD 16) Nothing)
   in Expense (mkExpenseAllocations (a1 :| [a2]))

spec :: Spec
spec = do
  lineSpec
  recordedSpec

lineSpec :: Spec
lineSpec = describe "formatTransactionLine" $ do
  it "annotates Expense rows with the resolved category name" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 5), sampleTxn (expenseFor foodCat))
    line `shouldSatisfy` T.isInfixOf "Expense \x00B7 Food"

  it "annotates Income rows with the resolved category name" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 6), sampleTxn (incomeFor salaryCat))
    line `shouldSatisfy` T.isInfixOf "Income \x00B7 Salary"

  it "leaves Transfer rows unannotated" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 7), sampleTxn Transfer)
    line `shouldSatisfy` T.isInfixOf "Transfer"
    line `shouldNotSatisfy` T.isInfixOf "\x00B7"

  it "renders the amount when the category isn't in the map" $ do
    -- With allocations, an unresolved category still renders the amount
    -- after the bullet separator (allocations always emit per-line money).
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 8), sampleTxn (expenseFor orphanCat))
    line `shouldSatisfy` T.isInfixOf "Expense \x00B7"
    line `shouldNotSatisfy` T.isInfixOf "Expense \x00B7 Food"

  it "omits the status marker for Completed rows" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 9), sampleTxn (expenseFor foodCat))
    line `shouldNotSatisfy` T.isInfixOf "[Completed]"
    line `shouldNotSatisfy` T.isInfixOf "["

  it "keeps the status marker for Pending rows" $ do
    let txn = (sampleTxn (expenseFor foodCat)) {status = Pending}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 10), txn)
    line `shouldSatisfy` T.isInfixOf "[Pending]"

  it "keeps the status marker with reason for Failed rows" $ do
    let txn = (sampleTxn (expenseFor foodCat)) {status = Failed "insufficient funds"}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 11), txn)
    line `shouldSatisfy` T.isInfixOf "[Failed: insufficient funds]"

  it "renders resolved labels as a comma-separated bracketed list" $ do
    let txn = (sampleTxn (expenseFor foodCat)) {labels = Set.fromList [lunchLabel, kyivLabel]}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 12), txn)
    line `shouldSatisfy` T.isInfixOf "[kyiv, lunch]"

  it "omits unresolved label ids and shows no marker when none resolve" $ do
    let txn = (sampleTxn (expenseFor foodCat)) {labels = Set.fromList [orphanLabel]}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 13), txn)
    line `shouldNotSatisfy` T.isInfixOf "["

recordedSpec :: Spec
recordedSpec = describe "formatRecordedTransaction" $ do
  it "renders an expense header, total-account line, bullet, and date" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn (expenseFor foodCat))
    out `shouldSatisfy` T.isInfixOf "\9989 Expense recorded"
    out `shouldSatisfy` T.isInfixOf "300.00 USD \xB7 Cash"
    out `shouldSatisfy` T.isInfixOf "\x2022 Food 300.00"
    out `shouldSatisfy` T.isInfixOf "2026-04-18 14:30"

  it "renders income against the target account" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn (incomeFor salaryCat))
    out `shouldSatisfy` T.isInfixOf "\9989 Income recorded"
    out `shouldSatisfy` T.isInfixOf "\x2022 Salary 300.00"

  it "renders one bullet per allocation with per-allocation comment" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn multiExpense)
    out `shouldSatisfy` T.isInfixOf "\x2022 Food 4.00 \x2014 latte"
    out `shouldSatisfy` T.isInfixOf "\x2022 Salary 16.00"
    out `shouldNotSatisfy` T.isInfixOf "Salary 16.00 \x2014"

  it "falls back to the bare amount when a category is unresolved" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn (expenseFor orphanCat))
    out `shouldSatisfy` T.isInfixOf "\x2022 300.00"

  it "omits the account suffix when the account is unresolved" $ do
    let out = formatRecordedTransaction names Map.empty (sampleTxn (expenseFor foodCat))
    out `shouldSatisfy` T.isInfixOf "300.00 USD"
    out `shouldNotSatisfy` T.isInfixOf "\xB7"

  it "renders a same-currency transfer with one amount and no rate" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn Transfer)
    out `shouldSatisfy` T.isInfixOf "\9989 Transfer recorded"
    out `shouldSatisfy` T.isInfixOf "Cash \x2192 Savings"
    out `shouldSatisfy` T.isInfixOf "300.00 USD"
    out `shouldNotSatisfy` T.isInfixOf "Rate:"

  it "renders a cross-currency transfer with both amounts and a rate" $ do
    let er = either (error . show) id (mkExchangeRate USD UAH (toRational (41.5 :: Double)))
        txn =
          (sampleTxn Transfer)
            { sourceAmount = unsafeMoney USD 100,
              targetAmount = unsafeMoney UAH 4150,
              exchangeRate = Just er
            }
        out = formatRecordedTransaction names acctNames txn
    out `shouldSatisfy` T.isInfixOf "100.00 USD \x2192 4150.00 UAH"
    out `shouldSatisfy` T.isInfixOf "Rate: 41.50"

  it "falls back to a short id for an unresolved transfer endpoint" $ do
    let out = formatRecordedTransaction names Map.empty (sampleTxn Transfer)
    out `shouldSatisfy` T.isInfixOf "00000000 \x2192 00000000"

  it "appends a Pending marker but not for Completed" $ do
    let completed = formatRecordedTransaction names acctNames (sampleTxn (expenseFor foodCat))
        pending = formatRecordedTransaction names acctNames ((sampleTxn (expenseFor foodCat)) {status = Pending})
    completed `shouldNotSatisfy` T.isInfixOf "["
    pending `shouldSatisfy` T.isInfixOf "[Pending]"

  it "appends resolved labels sorted and omits when empty" $ do
    let withLabels = (sampleTxn (expenseFor foodCat)) {labels = Set.fromList [kyivLabel, lunchLabel]}
        out = formatRecordedTransaction names acctNames withLabels
    out `shouldSatisfy` T.isInfixOf "Labels: kyiv, lunch"
    formatRecordedTransaction names acctNames (sampleTxn (expenseFor foodCat))
      `shouldNotSatisfy` T.isInfixOf "Labels:"
