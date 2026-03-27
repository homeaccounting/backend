{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.TypesPropertySpec
-- Description : Property-based tests for Domain.Core.Types
--
-- This module tests mathematical properties and invariants of core domain types
-- using QuickCheck property-based testing.
--
-- Test Coverage:
--   - Money: Commutativity, associativity, identity, subtraction
--   - Identifiers: Uniqueness, non-nil invariants
module Domain.Core.TypesPropertySpec (spec) where

import qualified Data.Aeson as Aeson
import Data.Ratio ((%))
import qualified Data.UUID as UUID
import Domain.Core.Types
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators

spec :: Spec
spec = do
  moneyPropertySpec
  exchangeRatePropertySpec
  identifierPropertySpec

-- -----------------------------------------------------------------------------
-- Money Property Tests
-- -----------------------------------------------------------------------------
--
-- Money uses Rational internally for exact decimal arithmetic without
-- floating-point precision errors.

moneyPropertySpec :: Spec
moneyPropertySpec = describe "Money Properties" $ do
  describe "When performing arithmetic operations" $ do
    it "Then addition is commutative (same currency)"
      $ property
      $ forAll genCurrency
      $ \cur ->
        forAll (genMoneyIn cur) $ \m1 ->
          forAll (genMoneyIn cur) $ \m2 ->
            addMoney m1 m2 === addMoney m2 m1

    it "Then addition is associative (same currency, exact equality)"
      $ property
      $ forAll genCurrency
      $ \cur ->
        forAll (genMoneyIn cur) $ \m1 ->
          forAll (genMoneyIn cur) $ \m2 ->
            forAll (genMoneyIn cur) $ \m3 ->
              let result1 = addMoney m1 m2 >>= \r -> addMoney r m3
                  result2 = addMoney m2 m3 >>= \r -> addMoney m1 r
               in result1 === result2

    it "Then zero is additive identity"
      $ property
      $ forAll genCurrency
      $ \cur ->
        forAll (genMoneyIn cur) $ \m ->
          let zero = unsafeMoney cur 0
           in addMoney m zero === Right m

    it "Then subtraction always succeeds for same currency"
      $ property
      $ forAll genCurrency
      $ \cur ->
        forAll (genMoneyIn cur) $ \m1 ->
          forAll (genMoneyIn cur) $ \m2 ->
            case subtractMoney m1 m2 of
              Right result -> unMoney result === unMoney m1 - unMoney m2
              Left _ -> property False

  describe "When currencies differ" $ do
    it "Then addMoney returns Left"
      $ property
      $ forAll (genMoneyIn USD)
      $ \m1 ->
        forAll (genMoneyIn EUR) $ \m2 ->
          case addMoney m1 m2 of
            Left _ -> True
            Right _ -> False

    it "Then subtractMoney returns Left"
      $ property
      $ forAll (genMoneyIn USD)
      $ \m1 ->
        forAll (genMoneyIn EUR) $ \m2 ->
          case subtractMoney m1 m2 of
            Left _ -> True
            Right _ -> False

  describe "Currency" $ do
    it "Then JSON roundtrips correctly"
      $ property
      $ \(cur :: Currency) ->
        Aeson.fromJSON (Aeson.toJSON cur) === Aeson.Success cur

-- -----------------------------------------------------------------------------
-- ExchangeRate Property Tests
-- -----------------------------------------------------------------------------

exchangeRatePropertySpec :: Spec
exchangeRatePropertySpec = describe "ExchangeRate Properties" $ do
  describe "Smart constructor validation" $ do
    it "Then rejects zero rate"
      $ property
      $ forAll genCurrency
      $ \src ->
        forAll (elements [c | c <- [minBound .. maxBound], c /= src]) $ \tgt ->
          isLeft (mkExchangeRate src tgt 0)

    it "Then rejects negative rate"
      $ property
      $ forAll genCurrency
      $ \src ->
        forAll (elements [c | c <- [minBound .. maxBound], c /= src]) $ \tgt ->
          forAll genPositiveRational $ \r ->
            isLeft (mkExchangeRate src tgt (negate r))

    it "Then rejects same-currency pair"
      $ property
      $ forAll genCurrency
      $ \c ->
        forAll genPositiveRational $ \r ->
          isLeft (mkExchangeRate c c r)

    it "Then accepts valid rate"
      $ property
      $ forAll genCurrency
      $ \src ->
        forAll (elements [c | c <- [minBound .. maxBound], c /= src]) $ \tgt ->
          forAll genPositiveRational $ \r ->
            isRight (mkExchangeRate src tgt r)

  describe "convert" $ do
    it "Then produces target currency"
      $ property
      $ forAll genExchangeRate
      $ \er ->
        forAll genPositiveRational $ \r ->
          let srcMoney = unsafeMoney (exchangeRateSource er) r
           in moneyCurrency (convert er srcMoney) === exchangeRateTarget er

    it "Then preserves amount with rate 1"
      $ property
      $ forAll genCurrency
      $ \src ->
        forAll (elements [c | c <- [minBound .. maxBound], c /= src]) $ \tgt ->
          case mkExchangeRate src tgt 1 of
            Left _ -> property True -- impossible
            Right er ->
              forAll genPositiveRational $ \amt ->
                let srcMoney = unsafeMoney src amt
                 in unMoney (convert er srcMoney) === amt

    it "Then JSON roundtrips correctly"
      $ property
      $ forAll genExchangeRate
      $ \er ->
        case Aeson.fromJSON (Aeson.toJSON er) of
          Aeson.Success er' ->
            exchangeRateSource er' === exchangeRateSource er
              .&&. exchangeRateTarget er' === exchangeRateTarget er
          Aeson.Error _ -> property False
  where
    genPositiveRational :: Gen Rational
    genPositiveRational = do
      n <- chooseInteger (1, 1000000)
      d <- chooseInteger (1, 1000000)
      pure (n Data.Ratio.% d)

-- -----------------------------------------------------------------------------
-- Identifier Property Tests
-- -----------------------------------------------------------------------------

identifierPropertySpec :: Spec
identifierPropertySpec = describe "Identifier Properties" $ do
  describe "AccountId" $ do
    it "Then maintains non-nil invariant"
      $ property
      $ \(aid :: AccountId) ->
        unAccountId aid =/= UUID.nil

    it "Then preserves UUID through round-trip"
      $ property
      $ \(aid :: AccountId) ->
        let uuid = unAccountId aid
         in case mkAccountId uuid of
              Right aid' -> aid === aid'
              Left _ -> property False

  describe "TransactionId" $ do
    it "Then maintains non-nil invariant"
      $ property
      $ \(tid :: TransactionId) ->
        unTransactionId tid =/= UUID.nil

    it "Then preserves UUID through round-trip"
      $ property
      $ \(tid :: TransactionId) ->
        let uuid = unTransactionId tid
         in case mkTransactionId uuid of
              Right tid' -> tid === tid'
              Left _ -> property False
