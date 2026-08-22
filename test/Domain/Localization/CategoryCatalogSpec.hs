{-# LANGUAGE OverloadedStrings #-}

module Domain.Localization.CategoryCatalogSpec (spec) where

import Domain.Configuration.Defaults (DefaultEntry (entryName, slug), defaultExpenseCategories, defaultIncomeCategories)
import Domain.Localization.CategoryCatalog (localizedCategoryName)
import Domain.Localization.Language (Language (..))
import Test.Hspec

spec :: Spec
spec = describe "localizedCategoryName" $ do
  it "returns the English display name for En, keyed by slug" $
    localizedCategoryName En "groceries" `shouldBe` "Groceries"

  it "translates a known slug for Uk" $
    localizedCategoryName Uk "groceries" `shouldBe` "Продукти"

  it "falls back to the slug for an unknown key" $
    localizedCategoryName Uk "nonexistent" `shouldBe` "nonexistent"

  it "has a Uk translation for every default category (completeness)" $ do
    let slugs = map (.slug) (defaultIncomeCategories <> defaultExpenseCategories)
        untranslated = [s | s <- slugs, localizedCategoryName Uk s == s]
    untranslated `shouldBe` []

  it "has an En display for every default category (completeness)" $ do
    let slugs = map (.slug) (defaultIncomeCategories <> defaultExpenseCategories)
        untranslated = [s | s <- slugs, localizedCategoryName En s == s]
    untranslated `shouldBe` []

  it "En display for every slug matches the seed's English entryName" $ do
    let mismatches =
          [ (e.slug, e.entryName, localizedCategoryName En e.slug)
          | e <- defaultIncomeCategories <> defaultExpenseCategories,
            localizedCategoryName En e.slug /= e.entryName
          ]
    mismatches `shouldBe` []
