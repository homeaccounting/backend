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
    TransferType (..),
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
  )
import Domain.Transaction.Projection (TransactionStatus (..))
import Telegram.Formatting (formatTransactionLine)
import Test.Hspec

uuidFromInt :: Int -> UUID.UUID
uuidFromInt n =
  let s = "00000000-0000-0000-0000-" <> replicate (12 - length (show n)) '0' <> show n
   in fromMaybe (error "bad uuid") (UUID.fromString s)

sampleTxn :: TransferType -> TransactionData
sampleTxn tt =
  TransactionData
    { sourceAccountId = unsafeAccountId (uuidFromInt 1),
      targetAccountId = unsafeAccountId (uuidFromInt 2),
      sourceAmount = unsafeMoney USD 300,
      targetAmount = unsafeMoney USD 300,
      exchangeRate = Nothing,
      description = "McDonald's",
      status = Completed,
      transferType = tt,
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

spec :: Spec
spec = describe "formatTransactionLine" $ do
  it "annotates Expense rows with the resolved category name" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 5), sampleTxn (Expense foodCat))
    line `shouldSatisfy` T.isInfixOf "Expense \x00B7 Food"

  it "annotates Income rows with the resolved category name" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 6), sampleTxn (Income salaryCat))
    line `shouldSatisfy` T.isInfixOf "Income \x00B7 Salary"

  it "leaves Transfer rows unannotated" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 7), sampleTxn Transfer)
    line `shouldSatisfy` T.isInfixOf "Transfer"
    line `shouldNotSatisfy` T.isInfixOf "\x00B7"

  it "falls back to the bare type label when the category isn't in the map" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 8), sampleTxn (Expense orphanCat))
    line `shouldSatisfy` T.isInfixOf "Expense  "
    line `shouldNotSatisfy` T.isInfixOf "\x00B7"

  it "omits the status marker for Completed rows" $ do
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 9), sampleTxn (Expense foodCat))
    line `shouldNotSatisfy` T.isInfixOf "[Completed]"
    line `shouldNotSatisfy` T.isInfixOf "["

  it "keeps the status marker for Pending rows" $ do
    let txn = (sampleTxn (Expense foodCat)) {status = Pending}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 10), txn)
    line `shouldSatisfy` T.isInfixOf "[Pending]"

  it "keeps the status marker with reason for Failed rows" $ do
    let txn = (sampleTxn (Expense foodCat)) {status = Failed "insufficient funds"}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 11), txn)
    line `shouldSatisfy` T.isInfixOf "[Failed: insufficient funds]"

  it "renders resolved labels as a comma-separated bracketed list" $ do
    let txn = (sampleTxn (Expense foodCat)) {labels = Set.fromList [lunchLabel, kyivLabel]}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 12), txn)
    line `shouldSatisfy` T.isInfixOf "[kyiv, lunch]"

  it "omits unresolved label ids and shows no marker when none resolve" $ do
    let txn = (sampleTxn (Expense foodCat)) {labels = Set.fromList [orphanLabel]}
    let line = formatTransactionLine names (unsafeTransactionId (uuidFromInt 13), txn)
    line `shouldNotSatisfy` T.isInfixOf "["
