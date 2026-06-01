{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Domain.Core.TransferTypePropertySpec
-- Description : Property tests for 'TransferType' smart constructors and accessors.
module Domain.Core.TransferTypePropertySpec (spec) where

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
-- smart-constructor invariants.
genValid :: Gen (Money, Allocations)
genValid = do
  cur <- arbitrary
  total <- genPositiveMoneyIn cur
  NonEmpty cids <- arbitrary
  let allocs = partitionMoney total (NE.fromList cids)
  pure (total, allocs)

-- | Assert that a 'Left ValidationErr' was produced with the given field name.
expectValidationField :: Text -> Either DomainError TransferType -> Property
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
spec = describe "TransferType" $ do
  describe "mkIncome / mkExpense" $ do
    prop "accepts allocations summing to total with consistent currency" $
      forAll genValid $ \(total, allocs) ->
        case (mkIncome total allocs, mkExpense total allocs) of
          (Right (Income _), Right (Expense _)) -> True
          _ -> False

    prop "rejects allocations whose sum does not equal total" $
      forAll genValid $ \(total, allocs) ->
        let bumped = case NE.uncons allocs of
              (Allocation cid m, rest) ->
                Allocation cid (unsafeMoney (moneyCurrency m) (unMoney m + 1))
                  NE.:| maybe [] NE.toList rest
         in expectValidationField "allocations" (mkIncome total bumped)

    prop "rejects allocations with currency mismatch" $
      forAll genValid $ \(total, allocs) ->
        let cur = moneyCurrency total
            other = head [c | c <- [minBound .. maxBound], c /= cur]
            mismatched = case NE.uncons allocs of
              (Allocation cid m, rest) ->
                Allocation cid (unsafeMoney other (unMoney m))
                  NE.:| maybe [] NE.toList rest
         in expectValidationField "currency" (mkIncome total mismatched)

    prop "rejects allocations with non-positive amount" $
      forAll genValid $ \(total, allocs) ->
        let cur = moneyCurrency total
            zeroed = case NE.uncons allocs of
              (Allocation cid _, rest) ->
                Allocation cid (unsafeMoney cur 0)
                  NE.:| maybe [] NE.toList rest
         in expectValidationField "amount" (mkIncome total zeroed)

  describe "allocationsOf / categorisedAmount / isCategorised / kindOf" $ do
    prop "allocationsOf is Just iff kindOf is IncomeKind or ExpenseKind" $ \tt ->
      isJust (allocationsOf tt)
        === (kindOf tt == IncomeKind || kindOf tt == ExpenseKind)

    prop "categorisedAmount equals sum of allocations when defined" $ \tt ->
      categorisedAmount tt === fmap sumAllocationsUnchecked (allocationsOf tt)

    prop "isCategorised matches allocationsOf" $ \tt ->
      isCategorised tt === isJust (allocationsOf tt)

    prop "kindOf is total (every constructor maps to some kind)" $ \tt ->
      kindOf tt `seq` True

  describe "allSameCurrency" $ do
    prop "holds for any TransferType returned by the smart constructors" $
      forAll genValid $ \(total, allocs) ->
        allSameCurrency (moneyCurrency total) allocs
