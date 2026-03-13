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
import qualified Data.UUID as UUID
import Domain.Core.Types
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators

spec :: Spec
spec = do
  moneyPropertySpec
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
