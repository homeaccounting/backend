{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Configuration.DefaultsSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Domain.Configuration.Defaults
  ( DefaultEntry (entryId, entryName, parentId, role),
    ExpenseDefaults (beauty, dining, electronics, foodAndDining, groceries, healthWellness, housing, leisureTravel, other, pets, shopping, shoppingGoods, transport),
    IncomeDefaults (earned, other, passive, salary),
    defaultExpenseCategories,
    defaultIncomeCategories,
    defaultMccExpenseCategoryMap,
    expense,
    expenseCategoryDictKind,
    income,
    incomeCategoryDictKind,
    mkDeterministicEntryId,
  )
import Domain.Configuration.Dictionary (EntryRole (..))
import RIO
import qualified RIO.Set as Set
import Test.Hspec

spec :: Spec
spec = describe "Domain.Configuration.Defaults" $ do
  describe "record-dot lookups" $ do
    it "expense.groceries.entryName is \"Groceries\""
      $ (expense.groceries.entryName :: Text)
      `shouldBe` "Groceries"

    it "expense.groceries.entryId matches the deterministic UUIDv5"
      $ expense.groceries.entryId
      `shouldBe` mkDeterministicEntryId expenseCategoryDictKind "Groceries"

    it "income.salary.entryName is \"Salary\""
      $ (income.salary.entryName :: Text)
      `shouldBe` "Salary"

    it "income.salary.entryId matches the deterministic UUIDv5"
      $ income.salary.entryId
      `shouldBe` mkDeterministicEntryId incomeCategoryDictKind "Salary"

  describe "category tree structure" $ do
    it "nests Groceries and Dining under the Food group" $ do
      expense.foodAndDining.parentId `shouldBe` Nothing
      expense.foodAndDining.entryName `shouldBe` "Food"
      expense.groceries.parentId `shouldBe` Just expense.foodAndDining.entryId
      expense.dining.parentId `shouldBe` Just expense.foodAndDining.entryId

    it "nests Salary under the Earned income group" $ do
      income.earned.parentId `shouldBe` Nothing
      income.earned.entryName `shouldBe` "Earned"
      income.salary.parentId `shouldBe` Just income.earned.entryId

    it "leaves standalone roots parentless" $ do
      expense.other.parentId `shouldBe` Nothing
      expense.transport.parentId `shouldBe` Nothing
      income.other.parentId `shouldBe` Nothing

  describe "entry roles" $ do
    it "declares the five expense groups as parentless groups" $ do
      let groups =
            [ expense.foodAndDining,
              expense.housing,
              expense.healthWellness,
              expense.shoppingGoods,
              expense.leisureTravel
            ]
      map (.role) groups `shouldBe` replicate 5 GroupRole
      map (.parentId) groups `shouldBe` replicate 5 Nothing

    it "declares the two income groups as parentless groups" $ do
      let groups = [income.earned, income.passive]
      map (.role) groups `shouldBe` replicate 2 GroupRole
      map (.parentId) groups `shouldBe` replicate 2 Nothing

    it "declares nested children as items" $ do
      expense.groceries.role `shouldBe` ItemRole
      expense.dining.role `shouldBe` ItemRole
      income.salary.role `shouldBe` ItemRole

    it "declares standalone root leaves as items" $ do
      expense.other.role `shouldBe` ItemRole
      expense.transport.role `shouldBe` ItemRole
      income.other.role `shouldBe` ItemRole

    it "keeps the default forest within depth 2 (only groups have children)" $ do
      defaultExpenseCategories `shouldSatisfy` isDepth2
      defaultIncomeCategories `shouldSatisfy` isDepth2

  describe "default category lists" $ do
    it "defaultExpenseCategories has the expected size (22 leaves + 5 groups)" $ do
      length defaultExpenseCategories `shouldBe` 27
      let names = map (.entryName) defaultExpenseCategories
      names `shouldSatisfy` elem "Groceries"
      names `shouldSatisfy` elem "Food"
      names `shouldSatisfy` elem "Transport"
      names `shouldSatisfy` elem "Dining"
      names `shouldSatisfy` elem "Beauty & Personal Care"
      names `shouldSatisfy` elem "Pets"
      names `shouldSatisfy` elem "Electronics"
      names `shouldSatisfy` elem "Shopping"
      names `shouldSatisfy` elem "Other"

    it "defaultIncomeCategories has the expected size (8 leaves + 2 groups)" $ do
      length defaultIncomeCategories `shouldBe` 10
      let names = map (.entryName) defaultIncomeCategories
      names `shouldSatisfy` elem "Salary"
      names `shouldSatisfy` elem "Earned"
      names `shouldSatisfy` elem "Other"

    it "orders every child after its parent (seed parent-exists invariant)" $ do
      defaultExpenseCategories `shouldSatisfy` parentsBeforeChildren
      defaultIncomeCategories `shouldSatisfy` parentsBeforeChildren

  describe "defaultMccExpenseCategoryMap" $ do
    it "has all keys as non-empty text"
      $ Map.keys defaultMccExpenseCategoryMap
      `shouldSatisfy` (not . any T.null)

    it "every value is a CategoryId present in the default expense categories" $ do
      let expenseIds = map (.entryId) defaultExpenseCategories
      Map.elems defaultMccExpenseCategoryMap `shouldSatisfy` all (`elem` expenseIds)

    it "contains the canonical grocery MCC (mapped to the renamed Groceries leaf)"
      $ Map.lookup "5411" defaultMccExpenseCategoryMap
      `shouldBe` Just expense.groceries.entryId

    it "never targets a group node" $ do
      let groupIds =
            [ expense.foodAndDining.entryId,
              expense.housing.entryId,
              expense.healthWellness.entryId,
              expense.shoppingGoods.entryId,
              expense.leisureTravel.entryId
            ]
      Map.elems defaultMccExpenseCategoryMap `shouldSatisfy` all (`notElem` groupIds)

    it "maps dining MCCs to the Dining category (split from Food)" $ do
      Map.lookup "5812" defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId
      Map.lookup "5813" defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId
      Map.lookup "5814" defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId

    it "maps sample new-category MCCs to their categories" $ do
      Map.lookup "7230" defaultMccExpenseCategoryMap `shouldBe` Just expense.beauty.entryId
      Map.lookup "5995" defaultMccExpenseCategoryMap `shouldBe` Just expense.pets.entryId
      Map.lookup "5732" defaultMccExpenseCategoryMap `shouldBe` Just expense.electronics.entryId
      Map.lookup "5311" defaultMccExpenseCategoryMap `shouldBe` Just expense.shopping.entryId

-- | Every entry's parent (when it has one) must appear earlier in the list, so
-- the seed loop's parent-exists guard never rejects a child.
parentsBeforeChildren :: [DefaultEntry] -> Bool
parentsBeforeChildren = go Set.empty
  where
    go _ [] = True
    go seen (e : rest) =
      let ok = maybe True (`Set.member` seen) e.parentId
       in ok && go (Set.insert e.entryId seen) rest

-- | The forest is at most two levels deep: any entry that has a parent must sit
-- under a root-level group (a group whose own @parentId@ is 'Nothing').
isDepth2 :: [DefaultEntry] -> Bool
isDepth2 es = all childUnderRootGroup es
  where
    byId = Map.fromList [(e.entryId, e) | e <- es]
    childUnderRootGroup e = case e.parentId of
      Nothing -> True
      Just pid -> case Map.lookup pid byId of
        Just parent -> parent.role == GroupRole && isNothing parent.parentId
        Nothing -> False
