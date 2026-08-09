{-# LANGUAGE OverloadedStrings #-}
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
    mockMoneyWith,
    mockAccountId,
    mockTransactionId,
    mockUserId,
    mockConfigurationId,
    mockDictionaryEntryId,
    mockEntryName,
    mockTelegramId,
    mockPasswordHash,
    mockExchangeRate,

    -- * Index-Based Id Builders
    mockAccountIdN,
    mockCategoryIdN,
    mockTransactionIdN,
    mockUserIdN,

    -- * Read-Model Fixture Builders
    fixtureTime,
    mockAccountData,
    mockTransactionData,
    mockTransactionDataWithCategory,
    mockTransactionDataWithContact,
    globalEvent,

    -- * Test Assertions
    shouldBeRight,
    shouldBeLeft,
    shouldSatisfyEither,

    -- * Utility Functions
    fromRight',
    fromLeft',

    -- * Allocation Helpers
    partitionMoney,
    singletonAllocation,
    expenseSingletonAllocation,
    singletonIncome,
    singletonExpense,
  )
where

import Application.ReadModels.Account (AccountData (..))
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Data.ByteString as BS
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact)
import Domain.Core.Types
import Domain.Models (AccountingEvent)
import Domain.Transaction.Projection (TransactionStatus (..))
import Eventium (EventVersion, GlobalStreamEvent, SequenceNumber, StreamEvent (..), emptyMetadata)
import RIO
import RIO.Time (UTCTime (..), fromGregorian)
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Mock Constructors
-- -----------------------------------------------------------------------------

-- | Create a Money value without validation (defaults to USD).
--
-- WARNING: Only use in tests where you need invalid values or want to bypass validation.
-- For valid test data, use the generators in Testkit.Generators.
--
-- >>> mockMoney 100
-- Money {amount = 100 % 1, currency = USD}
mockMoney :: Rational -> Money
mockMoney = unsafeMoney USD

-- | Create a Money value without validation in a specific currency.
--
-- WARNING: Only use in tests where you need invalid values or want to bypass validation.
-- For valid test data, use the generators in Testkit.Generators.
--
-- >>> mockMoneyWith USD 100
-- Money {amount = 100 % 1, currency = USD}
mockMoneyWith :: Currency -> Rational -> Money
mockMoneyWith = unsafeMoney

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

-- | Create a ConfigurationId without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
mockConfigurationId :: UUID -> ConfigurationId
mockConfigurationId = unsafeConfigurationId

-- | Create a DictionaryEntryId without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
mockDictionaryEntryId :: UUID -> DictionaryEntryId
mockDictionaryEntryId = unsafeDictionaryEntryId

-- | Create an EntryName without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
mockEntryName :: Text -> EntryName
mockEntryName = unsafeEntryName

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

-- | Create an ExchangeRate without validation.
--
-- WARNING: Only use in tests where you need to bypass validation.
--
-- >>> mockExchangeRate UAH USD 0.025
-- ExchangeRate {source = UAH, target = USD, rate = ...}
mockExchangeRate :: Currency -> Currency -> Rational -> ExchangeRate
mockExchangeRate = unsafeExchangeRate

-- -----------------------------------------------------------------------------
-- Index-Based Id Builders
-- -----------------------------------------------------------------------------

-- These build deterministic ids from a small 'Word32' index. Each entity type
-- occupies a distinct UUID word position so that, e.g., @mockAccountIdN 1@ and
-- @mockTransactionIdN 1@ never share an underlying UUID. Prefer these over
-- re-deriving @unsafe*Id . UUID.fromWords@ helpers inside individual specs.

-- | An 'AccountId' built from an index (occupies UUID word 0).
mockAccountIdN :: Word32 -> AccountId
mockAccountIdN n = unsafeAccountId (UUID.fromWords n 0 0 0)

-- | A 'CategoryId' built from an index (occupies UUID word 1).
mockCategoryIdN :: Word32 -> CategoryId
mockCategoryIdN n = unsafeDictionaryEntryId (UUID.fromWords 0 n 0 0)

-- | A 'TransactionId' built from an index (occupies UUID word 2).
mockTransactionIdN :: Word32 -> TransactionId
mockTransactionIdN n = unsafeTransactionId (UUID.fromWords 0 0 n 0)

-- | A 'UserId' built from an index (occupies UUID word 3).
mockUserIdN :: Word32 -> UserId
mockUserIdN n = unsafeUserId (UUID.fromWords 0 0 0 n)

-- -----------------------------------------------------------------------------
-- Read-Model Fixture Builders
-- -----------------------------------------------------------------------------

-- | A fixed timestamp (2026-06-01T00:00:00Z) used as the default date for
-- read-model fixtures. Tests that exercise date windows can override the
-- 'date' field with a record update.
fixtureTime :: UTCTime
fixtureTime = UTCTime (fromGregorian 2026 6 1) 0

-- | Build an 'AccountData' read-model row from its owner, type, status and
-- balance. Non-distinguishing fields take inert defaults (name @"fixture"@,
-- empty access list, no overdraft, no transactions, version 1).
mockAccountData :: UserId -> AccountType -> AccountStatus -> Money -> AccountData
mockAccountData owner ty st bal =
  AccountData
    { name = "fixture",
      balance = bal,
      createdBy = owner,
      accountType = ty,
      accessList = mempty,
      overdraftLimit = Nothing,
      hasTransactions = False,
      status = st,
      version = 1
    }

-- | Build a 'TransactionData' read-model row from its legs, optional exchange
-- rate and categorised type. Status defaults to 'Completed', date to
-- 'fixtureTime', and the remaining descriptive fields to inert defaults;
-- override with record updates where a test needs a specific value.
mockTransactionData ::
  AccountId ->
  AccountId ->
  Money ->
  Money ->
  Maybe ExchangeRate ->
  TransactionType ->
  TransactionData
mockTransactionData src tgt srcAmt tgtAmt rate tt =
  TransactionData
    { sourceAccountId = src,
      targetAccountId = tgt,
      sourceAmount = srcAmt,
      targetAmount = tgtAmt,
      exchangeRate = rate,
      description = "fixture",
      status = Completed,
      transactionType = tt,
      date = fixtureTime,
      category = Nothing,
      labels = mempty,
      contactId = Nothing,
      relations = [],
      amendmentCount = 0,
      providerContact = Nothing
    }

-- | Set the raw provider category signal on a 'TransactionData' fixture.
-- Lives here (rather than as an inline record update at the call site) because
-- the @category@ field name collides with 'Web.Types.CategoryAmount.category'
-- under DuplicateRecordFields; this module has no such collision, so the update
-- resolves unambiguously to 'TransactionData'.
mockTransactionDataWithCategory :: Maybe BankProviderCategory -> TransactionData -> TransactionData
mockTransactionDataWithCategory c td = td {category = c}

-- | Set the raw provider contact signal on a 'TransactionData' fixture.
-- Mirrors 'mockTransactionDataWithCategory'.
mockTransactionDataWithContact :: Maybe BankProviderContact -> TransactionData -> TransactionData
mockTransactionDataWithContact c td = td {providerContact = c}

-- | Wrap an 'AccountingEvent' as a 'GlobalStreamEvent' on the given stream
-- @UUID@ at a per-stream 'EventVersion' and global 'SequenceNumber' — the
-- two-layer 'StreamEvent' nesting the read-model specs otherwise repeat by
-- hand. Read-model applies ignore the wrapper metadata, so a fixed label is
-- used (specs needing a bespoke @createdAt@ build the event directly).
globalEvent :: UUID -> EventVersion -> AccountingEvent -> SequenceNumber -> GlobalStreamEvent AccountingEvent
globalEvent streamId ver payload seqNo =
  StreamEvent () seqNo (emptyMetadata "test") (StreamEvent streamId ver (emptyMetadata "test") payload)

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

-- -----------------------------------------------------------------------------
-- Allocation Helpers
-- -----------------------------------------------------------------------------

-- | Partition a 'Money' total into a 'NonEmpty' list of 'Allocation's,
-- one per supplied 'CategoryId', that sum exactly to 'total' and all
-- share its 'Currency'.
--
-- Splits the total into equal 'Rational' slices; the first allocation
-- absorbs the rounding residual so the sum is exact. Behaviour is
-- defined only when 'total' is strictly positive and the category list
-- is non-empty — both are precondition of any valid 'TransactionType'.
--
-- 'partitionMoney total (c :| [c1, c2])' produces three allocations
-- assigned to 'c', 'c1', 'c2'. For non-positive 'total' the function
-- raises 'error', so callers (typically property generators) must
-- guard with 'moneyIsPositive' first.
-- | The slices are placed in the @expenses@ bucket, which satisfies both
-- 'mkIncome' (both buckets allowed) and 'mkExpense' (empty income bucket
-- required) — so the same fixture works for either constructor.
partitionMoney :: Money -> NonEmpty DictionaryEntryId -> Allocations
partitionMoney total (c :| cs)
  | not (moneyIsPositive total) =
      error "partitionMoney: total must be strictly positive"
  | otherwise =
      let cur = moneyCurrency total
          totalRat = unMoney total
          n = 1 + length cs
          slice = totalRat / fromIntegral n
          residual = totalRat - slice * fromIntegral n
          firstAlloc = Allocation c (unsafeMoney cur (slice + residual)) Nothing
          rest = fmap (\ci -> Allocation ci (unsafeMoney cur slice) Nothing) cs
       in mkExpenseAllocations (firstAlloc :| rest)

-- | Build a degenerate single-allocation 'Allocations' for one category
-- and amount, placed in the @incomes@ bucket. Useful for income paths in
-- tests that pre-date the multi-category design. For expense-side fixtures
-- use 'expenseSingletonAllocation' (the buckets must match the category's
-- dictionary on dictionary-validated paths).
--
-- The amount is taken as-is — callers are responsible for ensuring it
-- is strictly positive.
singletonAllocation :: DictionaryEntryId -> Money -> Allocations
singletonAllocation c m = mkIncomeAllocations (Allocation c m Nothing :| [])

-- | Single-allocation 'Allocations' in the @expenses@ bucket — the
-- expense-side counterpart of 'singletonAllocation'.
expenseSingletonAllocation :: DictionaryEntryId -> Money -> Allocations
expenseSingletonAllocation c m = mkExpenseAllocations (Allocation c m Nothing :| [])

-- | Build an 'Income' 'TransactionType' with a single allocation. The
-- amount supplied IS the categorised total (degenerate length-1
-- allocation), so the sum invariant is trivially satisfied.
--
-- Delegates to 'mkIncome' so test fixtures go through the same
-- validation surface as production code; the call panics if the
-- amount is not strictly positive.
singletonIncome :: DictionaryEntryId -> Money -> TransactionType
singletonIncome c m =
  case mkIncome m (singletonAllocation c m) of
    Right tt -> tt
    Left err -> error ("singletonIncome: " <> show err)

-- | Build an 'Expense' 'TransactionType' with a single allocation. Same
-- semantics as 'singletonIncome'.
singletonExpense :: DictionaryEntryId -> Money -> TransactionType
singletonExpense c m =
  case mkExpense m (expenseSingletonAllocation c m) of
    Right tt -> tt
    Left err -> error ("singletonExpense: " <> show err)
