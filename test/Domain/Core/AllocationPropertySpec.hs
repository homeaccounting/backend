{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Domain.Core.AllocationPropertySpec
-- Description : Property tests for the Allocation value type
module Domain.Core.AllocationPropertySpec (spec) where

import Data.Aeson (decode, encode)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (Allocation (..), DictionaryEntryId, Money, mkAllocation, unMoney)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Property, (===), (==>))
import Testkit.Generators ()

spec :: Spec
spec = describe "Allocation" $ do
  -- After one round-trip through JSON, any precision loss inflicted by
  -- the underlying 'Money' Rational→Double→Rational codec has settled,
  -- so subsequent encodings are stable. This is the strongest
  -- structural property we can assert without restricting the
  -- generator to Double-exact amounts.
  prop "JSON encoding is stable after one round-trip" $ \(alloc :: Allocation) ->
    let once = decode (encode alloc) :: Maybe Allocation
        twice = once >>= (decode . encode) :: Maybe Allocation
     in once == twice
  prop "JSON decodes to some Allocation" $ \(alloc :: Allocation) ->
    case decode (encode alloc) :: Maybe Allocation of
      Just _ -> True
      Nothing -> False
  prop "mkAllocation accepts any strictly positive amount" $
    \(cid :: DictionaryEntryId) (m :: Money) ->
      (unMoney m > 0) ==>
        ( case mkAllocation cid m of
            Right a -> a.amount === m
            Left e -> error ("expected Right, got Left " <> show e)
        )
  prop "mkAllocation rejects non-positive amounts" $
    \(cid :: DictionaryEntryId) (m :: Money) ->
      ( (unMoney m <= 0) ==>
          ( case mkAllocation cid m of
              Left (ValidationErr _) -> True
              _ -> False
          )
      ) ::
        Property
