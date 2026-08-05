{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.CategoryDefaultsSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Domain.Configuration.Defaults
  ( DefaultEntry (entryId),
    ExpenseDefaults (beauty, dining, electronics, foodAndDining, groceries, healthWellness, household, housing, leisureTravel, pets, shopping, shoppingGoods, utilities),
    defaultExpenseCategories,
    expense,
  )
import Domain.Core.Types (mkByLabel, mkByMcc, renderMcc, unsafeMcc)
import Infrastructure.Banking.CategoryDefaults (defaultBankProviderExpenseCategoryMap, defaultMccExpenseCategoryMap)
import qualified Infrastructure.Banking.PrivatBank as PrivatBank
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Banking.CategoryDefaults" $ do
  describe "defaultMccExpenseCategoryMap" $ do
    it "has all keys render as non-empty text"
      $ map renderMcc (Map.keys defaultMccExpenseCategoryMap)
      `shouldSatisfy` (not . any T.null)

    it "every value is a CategoryId present in the default expense categories" $ do
      let expenseIds = map (.entryId) defaultExpenseCategories
      Map.elems defaultMccExpenseCategoryMap `shouldSatisfy` all (`elem` expenseIds)

    it "contains the canonical grocery MCC (mapped to the Groceries leaf)"
      $ Map.lookup (unsafeMcc 5411) defaultMccExpenseCategoryMap
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

    it "maps dining MCCs to the Dining category" $ do
      Map.lookup (unsafeMcc 5812) defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId
      Map.lookup (unsafeMcc 5813) defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId
      Map.lookup (unsafeMcc 5814) defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId

    it "maps sample new-category MCCs to their categories" $ do
      Map.lookup (unsafeMcc 7230) defaultMccExpenseCategoryMap `shouldBe` Just expense.beauty.entryId
      Map.lookup (unsafeMcc 5995) defaultMccExpenseCategoryMap `shouldBe` Just expense.pets.entryId
      Map.lookup (unsafeMcc 5732) defaultMccExpenseCategoryMap `shouldBe` Just expense.electronics.entryId
      Map.lookup (unsafeMcc 5311) defaultMccExpenseCategoryMap `shouldBe` Just expense.shopping.entryId

  describe "defaultBankProviderExpenseCategoryMap" $ do
    it "includes the universal MCC defaults keyed as ByMcc"
      $ Map.lookup (mkByMcc (unsafeMcc 5411)) defaultBankProviderExpenseCategoryMap
      `shouldBe` Just expense.groceries.entryId

    it "includes each PrivatBank label default keyed as ByLabel" $ do
      Map.lookup (mkByLabel "Дім та ремонт" & fromMaybeKey) defaultBankProviderExpenseCategoryMap
        `shouldBe` Just expense.household.entryId
      Map.lookup (mkByLabel "Комуналка та Інтернет" & fromMaybeKey) defaultBankProviderExpenseCategoryMap
        `shouldBe` Just expense.utilities.entryId

    it "carries every PrivatBank label as a ByLabel key" $ do
      let present label =
            case mkByLabel label of
              Just pc -> Map.member pc defaultBankProviderExpenseCategoryMap
              Nothing -> False
      Map.keys PrivatBank.labelExpenseCategories `shouldSatisfy` all present

    it "contains one entry per MCC default plus one per PrivatBank label"
      $ Map.size defaultBankProviderExpenseCategoryMap
      `shouldBe` Map.size defaultMccExpenseCategoryMap + Map.size PrivatBank.labelExpenseCategories
  where
    -- The spec's fixed labels are all non-blank, so 'mkByLabel' is a 'Just';
    -- unwrap for a direct map lookup (an unexpected 'Nothing' fails the test via
    -- the impossible key lookup returning 'Nothing').
    fromMaybeKey = fromMaybe (mkByMcc (unsafeMcc 0))
