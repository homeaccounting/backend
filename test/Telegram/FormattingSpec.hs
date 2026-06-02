{-# LANGUAGE OverloadedStrings #-}

module Telegram.FormattingSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( CategoryId,
    Currency (..),
    LabelId,
    TransactionType (..),
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
  )
import Domain.Transaction.Projection (TransactionStatus (..))
import Telegram.Formatting (formatTransactionLine)
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
      labels = Set.empty
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

spec :: Spec
spec = describe "formatTransactionLine" $ do
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
