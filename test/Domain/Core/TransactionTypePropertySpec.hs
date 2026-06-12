{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Domain.Core.TransactionTypePropertySpec
-- Description : Property tests for 'TransactionType' smart constructors and accessors.
module Domain.Core.TransactionTypePropertySpec (spec) where

import qualified Data.List.NonEmpty as NE
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen,
    NonEmptyList (..),
    Property,
    arbitrary,
    counterexample,
    forAll,
    property,
    (===),
  )
import Testkit.Generators (genPositiveMoneyIn)
import Testkit.Helpers (partitionMoney)

-- | Build a valid (positive total, allocations) pair that satisfies the
-- smart-constructor invariants. All slices live in the @expenses@ bucket
-- (an empty @incomes@ bucket is valid for both 'mkIncome' and 'mkExpense').
genValid :: Gen (Money, Allocations)
genValid = do
  cur <- arbitrary
  total <- genPositiveMoneyIn cur
  NonEmpty cids <- arbitrary
  let allocs = partitionMoney total (NE.fromList cids)
  pure (total, allocs)

-- | Assert that a 'Left ValidationErr' was produced with the given field name.
expectValidationField :: Text -> Either DomainError TransactionType -> Property
expectValidationField expectedField result = case result of
  Left (ValidationErr ve) ->
    counterexample
      ("expected field " <> T.unpack expectedField <> ", got " <> show ve)
      (ve.validationField === expectedField)
  Left other ->
    counterexample ("expected ValidationErr, got " <> show other) (property False)
  Right tt ->
    counterexample ("expected Left, got Right " <> show tt) (property False)

spec :: Spec
spec = describe "TransactionType" $ do
  describe "mkIncome / mkExpense" $ do
    prop "accepts allocations summing to total with consistent currency" $
      forAll genValid $ \(total, allocs) ->
        case (mkIncome total allocs, mkExpense total allocs) of
          (Right (Income _), Right (Expense _)) -> True
          _ -> False

    prop "rejects allocations whose sum does not equal total" $
      forAll genValid $ \(total, allocs) ->
        let bumped = perturbExpenses (\m -> unsafeMoney (moneyCurrency m) (unMoney m + 1)) allocs
         in expectValidationField "allocations" (mkIncome total bumped)

    prop "rejects allocations with currency mismatch" $
      forAll genValid $ \(total, allocs) ->
        let cur = moneyCurrency total
            other = head [c | c <- [minBound .. maxBound], c /= cur]
            mismatched = perturbExpenses (unsafeMoney other . unMoney) allocs
         in expectValidationField "currency" (mkIncome total mismatched)

    prop "rejects allocations with non-positive amount" $
      forAll genValid $ \(total, allocs) ->
        let cur = moneyCurrency total
            zeroed = perturbExpenses (\_ -> unsafeMoney cur 0) allocs
         in expectValidationField "amount" (mkIncome total zeroed)

  describe "allocationsOf / isCategorised / kindOf" $ do
    prop "allocationsOf is Just iff kindOf is IncomeKind or ExpenseKind" $ \tt ->
      isJust (allocationsOf tt)
        === (kindOf tt == IncomeKind || kindOf tt == ExpenseKind)

    prop "isCategorised matches allocationsOf" $ \tt ->
      isCategorised tt === isJust (allocationsOf tt)

    prop "kindOf is total (every constructor maps to some kind)" $ \tt ->
      kindOf tt `seq` True

-- | Apply a money-transform to the first allocation of the @expenses@
-- bucket (where 'genValid' places its slices), leaving the rest intact.
perturbExpenses :: (Money -> Money) -> Allocations -> Allocations
perturbExpenses f a = case a.expenses of
  (Allocation cid m : rest) -> a {expenses = Allocation cid (f m) : rest}
  [] -> a
