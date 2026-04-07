{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.TransferCategoryPropertySpec
-- Description : Property-based tests for TransferCategory validation
--
-- This module tests that TransferCategory validation correctly accepts
-- matching type/category pairs and rejects mismatched ones.
--
-- Test Coverage:
--   - Income type accepts only IncomeCat categories
--   - Expense type accepts only ExpenseCat categories
--   - InternalTransfer type accepts only InternalCat categories
--   - Mismatched type/category pairs are rejected
module Domain.Core.TransferCategoryPropertySpec (spec) where

import Domain.Core.Types
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators ()

spec :: Spec
spec = describe "TransferCategory validation" $ do
  describe "validateTransferCategory" $ do
    it "accepts Income with IncomeCat"
      $ property
      $ \(cat :: IncomeCategory) ->
        validateTransferCategory Income (IncomeCat cat) === Right ()

    it "accepts Expense with ExpenseCat"
      $ property
      $ \(cat :: ExpenseCategory) ->
        validateTransferCategory Expense (ExpenseCat cat) === Right ()

    it "accepts InternalTransfer with InternalCat"
      $ validateTransferCategory InternalTransfer InternalCat
      `shouldBe` Right ()

    it "rejects mismatched type and category"
      $ property
      $ \(tt :: TransferType) (tc :: TransferCategory) ->
        not (isMatching tt tc) ==>
          isLeft (validateTransferCategory tt tc)

-- | Check if a TransferType and TransferCategory are a valid pair.
isMatching :: TransferType -> TransferCategory -> Bool
isMatching Income (IncomeCat _) = True
isMatching Expense (ExpenseCat _) = True
isMatching InternalTransfer InternalCat = True
isMatching _ _ = False
