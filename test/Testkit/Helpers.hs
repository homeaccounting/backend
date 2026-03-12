{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.Helpers
-- Description : Test helper functions and utilities
--
-- This module provides helper functions for testing, including:
--   - Mock constructors (bypassing validation)
--   - Test assertions
--   - Common test scenarios
--   - Utility functions
--
-- Usage:
--   Import this module in test files to access helper functions.
module Testkit.Helpers
  ( -- * Mock Constructors
    mockMoney,
    mockAccountId,
    mockTransactionId,
    mockUserId,
    mockTelegramId,
    mockPasswordHash,

    -- * Test Assertions
    shouldBeRight,
    shouldBeLeft,
    shouldSatisfyEither,

    -- * Utility Functions
    fromRight',
    fromLeft',
  )
where

import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.UUID (UUID)
import Domain.Core.Types
import RIO
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Mock Constructors
-- -----------------------------------------------------------------------------

-- | Create a Money value without validation.
--
-- WARNING: Only use in tests where you need invalid values or want to bypass validation.
-- For valid test data, use the generators in Testkit.Generators.
--
-- >>> mockMoney 100
-- Money (100 % 1)
mockMoney :: Rational -> Money
mockMoney = unsafeMoney

-- | Create an AccountId without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
--
-- >>> mockAccountId uuid
-- AccountId uuid
mockAccountId :: UUID -> AccountId
mockAccountId = unsafeAccountId

-- | Create a TransactionId without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
--
-- >>> mockTransactionId uuid
-- TransactionId uuid
mockTransactionId :: UUID -> TransactionId
mockTransactionId = unsafeTransactionId

-- | Create a UserId without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
--
-- >>> mockUserId uuid
-- UserId uuid
mockUserId :: UUID -> UserId
mockUserId = unsafeUserId

-- | Create a TelegramId.
--
-- >>> mockTelegramId 123456789
-- TelegramId 123456789
mockTelegramId :: Int64 -> TelegramId
mockTelegramId = TelegramId

-- | Create a PasswordHash from raw bytes.
--
-- WARNING: Only use in tests. Real password hashes should be created
-- through the Argon2 hashing infrastructure.
--
-- >>> mockPasswordHash "test-hash"
-- PasswordHash "test-hash"
mockPasswordHash :: BS.ByteString -> PasswordHash
mockPasswordHash = PasswordHash

-- -----------------------------------------------------------------------------
-- Test Assertions
-- -----------------------------------------------------------------------------

-- | Assert that an Either is Right.
--
-- >>> shouldBeRight (Right 42)
-- -- Passes
--
-- >>> shouldBeRight (Left "error")
-- -- Fails with message
shouldBeRight :: (Show a, Show b) => Either a b -> Expectation
shouldBeRight (Right _) = pure ()
shouldBeRight (Left err) = expectationFailure $ "Expected Right, got Left: " <> show err

-- | Assert that an Either is Left.
--
-- >>> shouldBeLeft (Left "error")
-- -- Passes
--
-- >>> shouldBeLeft (Right 42)
-- -- Fails with message
shouldBeLeft :: (Show a, Show b) => Either a b -> Expectation
shouldBeLeft (Left _) = pure ()
shouldBeLeft (Right val) = expectationFailure $ "Expected Left, got Right: " <> show val

-- | Assert that an Either satisfies a predicate.
--
-- >>> shouldSatisfyEither (Right 42) (\case Right x -> x > 0; _ -> False)
-- -- Passes
shouldSatisfyEither :: (Show a, Show b) => Either a b -> (Either a b -> Bool) -> Expectation
shouldSatisfyEither val predicate
  | predicate val = pure ()
  | otherwise = expectationFailure $ "Value did not satisfy predicate: " <> show val

-- -----------------------------------------------------------------------------
-- Utility Functions
-- -----------------------------------------------------------------------------

-- | Extract Right value or fail.
--
-- >>> fromRight' (Right 42)
-- 42
--
-- >>> fromRight' (Left "error")
-- -- Runtime error (for testing only)
fromRight' :: (Show a) => Either a b -> b
fromRight' (Right val) = val
fromRight' (Left err) = error $ "fromRight' called on Left: " <> show err

-- | Extract Left value or fail.
--
-- >>> fromLeft' (Left "error")
-- "error"
--
-- >>> fromLeft' (Right 42)
-- -- Runtime error (for testing only)
fromLeft' :: (Show b) => Either a b -> a
fromLeft' (Left err) = err
fromLeft' (Right val) = error $ "fromLeft' called on Right: " <> show val
