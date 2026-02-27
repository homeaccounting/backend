{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.TypesSpec
-- Description : Unit tests for Domain.Core.Types
--
-- This module tests the core domain types with validation, business rules,
-- and error handling.
--
-- Test Coverage:
--   - Money: Smart constructor validation, arithmetic operations
--   - AccountId: Smart constructor validation
--   - TransactionId: Smart constructor validation
module Domain.Core.TypesSpec (spec) where

import Data.Text (isInfixOf)
import Data.UUID (nil)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Core.Types
import RIO
import Test.Hspec
import TestSupport.Helpers

spec :: Spec
spec = do
  moneySpec
  accountIdSpec
  transactionIdSpec

-- -----------------------------------------------------------------------------
-- Money Tests
-- -----------------------------------------------------------------------------

moneySpec :: Spec
moneySpec = describe "Money" $ do
  describe "mkMoney" $ do
    context "Given valid amount" $ do
      it "Then creates Money value" $ do
        let result = mkMoney 100
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 100
          Left _ -> expectationFailure "Expected Right"

      it "Then accepts zero" $ do
        let result = mkMoney 0
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 0
          Left _ -> expectationFailure "Expected Right"

    context "Given negative amount" $ do
      it "Then rejects with error message" $ do
        let result = mkMoney (-10)
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "non-negative" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

  describe "addMoney" $ do
    it "Then adds two amounts correctly" $ do
      let m1 = mockMoney 100
      let m2 = mockMoney 50
      let result = addMoney m1 m2
      unMoney result `shouldBe` 150

    it "Then is commutative" $ do
      let m1 = mockMoney 100
      let m2 = mockMoney 50
      addMoney m1 m2 `shouldBe` addMoney m2 m1

    it "Then zero is identity element" $ do
      let m = mockMoney 100
      let zero = mockMoney 0
      addMoney m zero `shouldBe` m

  describe "subtractMoney" $ do
    context "Given sufficient funds" $ do
      it "Then subtracts correctly" $ do
        let m1 = mockMoney 100
        let m2 = mockMoney 50
        let result = subtractMoney m1 m2
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 50
          Left _ -> expectationFailure "Expected Right"

      it "Then handles exact match" $ do
        let m1 = mockMoney 100
        let m2 = mockMoney 100
        let result = subtractMoney m1 m2
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 0
          Left _ -> expectationFailure "Expected Right"

    context "Given insufficient funds" $ do
      it "Then returns error" $ do
        let m1 = mockMoney 50
        let m2 = mockMoney 100
        let result = subtractMoney m1 m2
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "Insufficient funds" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

-- -----------------------------------------------------------------------------
-- AccountId Tests
-- -----------------------------------------------------------------------------

accountIdSpec :: Spec
accountIdSpec = describe "AccountId" $ do
  describe "mkAccountId" $ do
    context "Given valid UUID" $ do
      it "Then creates AccountId" $ do
        uuid <- UUID.nextRandom
        let result = mkAccountId uuid
        shouldBeRight result
        case result of
          Right accountId -> unAccountId accountId `shouldBe` uuid
          Left _ -> expectationFailure "Expected Right"

    context "Given nil UUID" $ do
      it "Then rejects with error message" $ do
        let result = mkAccountId nil
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "cannot be nil" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

-- -----------------------------------------------------------------------------
-- TransactionId Tests
-- -----------------------------------------------------------------------------

transactionIdSpec :: Spec
transactionIdSpec = describe "TransactionId" $ do
  describe "mkTransactionId" $ do
    context "Given valid UUID" $ do
      it "Then creates TransactionId" $ do
        uuid <- UUID.nextRandom
        let result = mkTransactionId uuid
        shouldBeRight result
        case result of
          Right txId -> unTransactionId txId `shouldBe` uuid
          Left _ -> expectationFailure "Expected Right"

    context "Given nil UUID" $ do
      it "Then rejects with error message" $ do
        let result = mkTransactionId nil
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "cannot be nil" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"
