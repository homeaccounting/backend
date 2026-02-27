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
--   - Money: Non-negativity, commutativity, associativity, identity
--   - Identifiers: Uniqueness, non-nil invariants
module Domain.Core.TypesPropertySpec (spec) where

import qualified Data.UUID as UUID
import Domain.Core.Types
import RIO
import Test.Hspec
import Test.QuickCheck
import TestSupport.Generators ()

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
    it "Then maintains non-negativity invariant"
      $ property
      $ \(m :: Money) ->
        unMoney m >= 0

    it "Then addition is commutative"
      $ property
      $ \(m1 :: Money) (m2 :: Money) ->
        addMoney m1 m2 === addMoney m2 m1

    it "Then addition is associative (exact equality)"
      $ property
      $ \(m1 :: Money) (m2 :: Money) (m3 :: Money) ->
        let result1 = addMoney (addMoney m1 m2) m3
            result2 = addMoney m1 (addMoney m2 m3)
         in result1 === result2

    it "Then zero is additive identity"
      $ property
      $ \(m :: Money) ->
        let zero = unsafeMoney 0
         in addMoney m zero === m

    it "Then subtraction maintains non-negativity when valid"
      $ property
      $ \(m1 :: Money) (m2 :: Money) ->
        unMoney m1 >= unMoney m2 ==>
          case subtractMoney m1 m2 of
            Right result -> unMoney result >= 0
            Left _ -> False

    it "Then subtraction fails when insufficient funds"
      $ property
      $ \(m1 :: Money) (m2 :: Money) ->
        unMoney m1 < unMoney m2 ==>
          case subtractMoney m1 m2 of
            Left _ -> True
            Right _ -> False

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
