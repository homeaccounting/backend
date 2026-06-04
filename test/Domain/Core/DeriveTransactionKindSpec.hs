{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Core.DeriveTransactionKindSpec (spec) where

import Domain.Core.Types
  ( AccountSubtype (..),
    AccountType (..),
    TransactionKind (..),
    defaultCashProperties,
    deriveTransactionKind,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = describe "deriveTransactionKind" $ do
  let cash = Regular (Cash defaultCashProperties)
  it "Regular → External = ExpenseKind"
    $ deriveTransactionKind cash External
    `shouldBe` ExpenseKind
  it "External → Regular = IncomeKind"
    $ deriveTransactionKind External cash
    `shouldBe` IncomeKind
  it "Regular → Regular = TransferKind"
    $ deriveTransactionKind cash cash
    `shouldBe` TransferKind
  it "External → External = TransferKind (dead branch, total)"
    $ deriveTransactionKind External External
    `shouldBe` TransferKind
