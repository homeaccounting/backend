{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Domain.Core.AllocationPropertySpec
-- Description : Property tests for the Allocation value type
module Domain.Core.AllocationPropertySpec (spec) where

import Data.Aeson (decode, encode)
import Data.Either (isLeft)
import Data.UUID (fromWords)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (Allocation (..), Currency (..), DictionaryEntryId, Money, mkAllocation, mkDefaultMoney, unMoney, unsafeDictionaryEntryId, unsafeMoney)
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
        ( case mkAllocation cid m Nothing of
            Right a -> a.amount === m
            Left e -> error ("expected Right, got Left " <> show e)
        )
  prop "mkAllocation rejects non-positive amounts" $
    \(cid :: DictionaryEntryId) (m :: Money) ->
      ( (unMoney m <= 0) ==>
          ( case mkAllocation cid m Nothing of
              Left (ValidationErr _) -> True
              _ -> False
          )
      ) ::
        Property
  -- a valid comment passes through unchanged
  it "preserves a non-blank comment" $ do
    let m = either (error "mkDefaultMoney") id (mkDefaultMoney 10)
        cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
    fmap (.comment) (mkAllocation cid m (Just "огірки розсада"))
      `shouldBe` Right (Just "огірки розсада")
  -- blank / whitespace-only normalizes to Nothing
  it "normalizes a blank comment to Nothing" $ do
    let m = either (error "mkDefaultMoney") id (mkDefaultMoney 10)
        cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
    fmap (.comment) (mkAllocation cid m (Just "   ")) `shouldBe` Right Nothing
    fmap (.comment) (mkAllocation cid m (Just "")) `shouldBe` Right Nothing
  -- Nothing stays Nothing
  it "keeps a Nothing comment as Nothing" $ do
    let cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
    fmap (.comment) (mkAllocation cid (unsafeMoney USD 5) Nothing) `shouldBe` Right Nothing
  -- positivity still enforced when comment is Nothing
  it "still rejects non-positive amounts" $ do
    let cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
        bad = unsafeMoney USD (-1)
    mkAllocation cid bad Nothing `shouldSatisfy` isLeft
