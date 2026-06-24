{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.ReportingResponseSpec (spec) where

import qualified Data.Aeson as Aeson
import Data.ByteString (isInfixOf)
import Domain.Core.Types (Currency (UAH), unsafeMoney)
import RIO hiding (isInfixOf)
import Test.Hspec
import Web.Types
  ( CategorySpend (..),
    IncomeVsExpenseResponse (..),
    SpendingByCategoryResponse (..),
  )

spec :: Spec
spec = describe "Reporting DTOs" $ do
  it "CategorySpend renders amount as a nested Money object" $ do
    let cs = CategorySpend {categoryId = "cat-1", total = unsafeMoney UAH 1234}
        json = Aeson.encode cs
    json `shouldSatisfy` (\b -> "\"currency\":\"UAH\"" `isInfixOf` toStrictBytes b)
    json `shouldSatisfy` (\b -> "\"amount\":1234" `isInfixOf` toStrictBytes b)

  it "IncomeVsExpenseResponse carries income/expense/net as Money" $ do
    let r = IncomeVsExpenseResponse {income = unsafeMoney UAH 500, expense = unsafeMoney UAH 200, net = unsafeMoney UAH 300}
    Aeson.encode r `shouldSatisfy` (\b -> "\"net\":" `isInfixOf` toStrictBytes b)

  it "SpendingByCategoryResponse nests categories and a base total" $ do
    let r = SpendingByCategoryResponse {categories = [], total = unsafeMoney UAH 0}
    Aeson.encode r `shouldSatisfy` (\b -> "\"categories\":[]" `isInfixOf` toStrictBytes b)
