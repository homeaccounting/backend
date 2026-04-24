{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Configuration.DefaultsSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Domain.Configuration.Defaults
  ( DefaultEntry (entryId, entryName),
    ExpenseDefaults (food),
    IncomeDefaults (salary),
    defaultExpenseCategories,
    defaultIncomeCategories,
    defaultMccExpenseCategoryMap,
    expense,
    expenseCategoryDictId,
    income,
    incomeCategoryDictId,
    mkDeterministicEntryId,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Configuration.Defaults" $ do
  describe "record-dot lookups" $ do
    it "expense.food.entryName is \"Food\""
      $ (expense.food.entryName :: Text)
      `shouldBe` "Food"

    it "expense.food.entryId matches the deterministic UUIDv5"
      $ expense.food.entryId
      `shouldBe` mkDeterministicEntryId expenseCategoryDictId "Food"

    it "income.salary.entryName is \"Salary\""
      $ (income.salary.entryName :: Text)
      `shouldBe` "Salary"

    it "income.salary.entryId matches the deterministic UUIDv5"
      $ income.salary.entryId
      `shouldBe` mkDeterministicEntryId incomeCategoryDictId "Salary"

  describe "default category lists" $ do
    it "defaultExpenseCategories has the expected size and includes 'Food'" $ do
      length defaultExpenseCategories `shouldBe` 17
      let names = map (.entryName) defaultExpenseCategories
      names `shouldSatisfy` elem "Food"
      names `shouldSatisfy` elem "Transport"
      names `shouldSatisfy` elem "Other"

    it "defaultIncomeCategories has the expected size and includes 'Salary'" $ do
      length defaultIncomeCategories `shouldBe` 8
      let names = map (.entryName) defaultIncomeCategories
      names `shouldSatisfy` elem "Salary"
      names `shouldSatisfy` elem "Other"

  describe "defaultMccExpenseCategoryMap" $ do
    it "has all keys as non-empty text"
      $ Map.keys defaultMccExpenseCategoryMap
      `shouldSatisfy` (not . any T.null)

    it "every value is a CategoryId present in the default expense categories" $ do
      let expenseIds = map (.entryId) defaultExpenseCategories
      Map.elems defaultMccExpenseCategoryMap `shouldSatisfy` all (`elem` expenseIds)

    it "contains the canonical grocery MCC"
      $ Map.lookup "5411" defaultMccExpenseCategoryMap
      `shouldBe` Just expense.food.entryId
