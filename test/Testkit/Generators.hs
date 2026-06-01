{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Testkit.Generators
-- Description : QuickCheck generators for domain types
--
-- This module provides QuickCheck generators and Arbitrary instances for testing
-- domain types. These generators produce valid domain values that satisfy all
-- business invariants.
--
-- Usage:
--   - Import this module in property tests
--   - Use `arbitrary` to generate random valid values
--   - Use custom generators for specific test scenarios
module Testkit.Generators
  ( -- * Generators
    genCurrency,
    genMoney,
    genPositiveMoney,
    genMoneyIn,
    genPositiveMoneyIn,
    genAccountId,
    genTransactionId,
    genUserId,
    genConfigurationId,
    genDictionaryEntryId,
    genDictionaryId,
    genEntryName,
    genDictionaryEntry,
    genDictionary,
    genLabelSet,
    genCreatedBy,
    genTelegramId,
    genTelegramIdentity,
    genOAuthProvider,
    genOAuthIdentity,
    genPasswordHash,
    genEmail,
    genNonEmptyText,
    genTransferType,
    genExchangeRate,
    genPositiveRational,

    -- * Arbitrary Instances
  )
where

-- Instances are exported automatically

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List.NonEmpty (NonEmpty (..))
import Data.Ratio ((%))
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time.Calendar (Day, addDays, fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Types
import RIO
import Test.QuickCheck

-- -----------------------------------------------------------------------------
-- Currency Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid Currency value.
genCurrency :: Gen Currency
genCurrency = elements [UAH, USD, EUR, GBP]

instance Arbitrary Currency where
  arbitrary = genCurrency

-- -----------------------------------------------------------------------------
-- Money Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid Money value with a random currency.
--
-- Generates amounts from -1,000,000.00 to 1,000,000.00 with 2 decimal places.
-- Uses Rational for exact arithmetic.
genMoney :: Gen Money
genMoney = do
  cur <- genCurrency
  genMoneyIn cur

-- | Generate a positive Money value (> 0) with a random currency.
--
-- Useful for testing operations that require non-zero amounts.
--
-- Property:
--  forall m <- genPositiveMoney. unMoney m > 0
genPositiveMoney :: Gen Money
genPositiveMoney = do
  cur <- genCurrency
  genPositiveMoneyIn cur

-- | Generate a valid Money value in a specific currency.
--
-- Generates amounts from -1,000,000.00 to 1,000,000.00 with 2 decimal places.
genMoneyIn :: Currency -> Gen Money
genMoneyIn cur = do
  -- Generate cents (-100,000,000 to 100,000,000 cents = -1,000,000.00 to 1,000,000.00)
  cents <- choose (-100000000, 100000000) :: Gen Integer
  -- Convert to dollars: cents / 100
  let amt = fromInteger cents % 100
  pure $ unsafeMoney cur amt

-- | Generate a positive Money value (> 0) in a specific currency.
--
-- Useful for testing operations that require non-zero amounts.
genPositiveMoneyIn :: Currency -> Gen Money
genPositiveMoneyIn cur = do
  -- Generate cents (1 to 100,000,000 cents = 0.01 to 1,000,000.00)
  cents <- choose (1, 100000000) :: Gen Integer
  let amt = fromInteger cents % 100
  pure $ unsafeMoney cur amt

instance Arbitrary Money where
  arbitrary = genMoney

-- -----------------------------------------------------------------------------
-- Identifier Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid UUID.
--
-- Note: This is a pure generator that produces deterministic UUIDs based on
-- QuickCheck's random seed. For testing only.
genUUID :: Gen UUID
genUUID = do
  bytes <- vectorOf 16 (arbitrary :: Gen Word8)
  let byteString = BL.pack bytes
  pure $ fromMaybe UUID.nil $ UUID.fromByteString byteString

-- | Generate a valid AccountId.
--
-- Generates UUIDs that are not nil.
--
-- Property:
--  forall aid <- genAccountId. unAccountId aid /= UUID.nil
genAccountId :: Gen AccountId
genAccountId = do
  uuid <- genUUID `suchThat` (/= UUID.nil)
  case mkAccountId uuid of
    Right aid -> pure aid
    Left _ -> genAccountId -- Retry if invalid (shouldn't happen)

instance Arbitrary AccountId where
  arbitrary = genAccountId

-- | Generate a valid TransactionId.
--
-- Generates UUIDs that are not nil.
--
-- Property:
--  forall tid <- genTransactionId. unTransactionId tid /= UUID.nil
genTransactionId :: Gen TransactionId
genTransactionId = do
  uuid <- genUUID `suchThat` (/= UUID.nil)
  case mkTransactionId uuid of
    Right tid -> pure tid
    Left _ -> genTransactionId -- Retry if invalid (shouldn't happen)

instance Arbitrary TransactionId where
  arbitrary = genTransactionId

-- -----------------------------------------------------------------------------
-- Text Generators
-- -----------------------------------------------------------------------------

-- | Generate non-empty text.
--
-- Generates text with 1-100 alphanumeric characters.
--
-- Property:
--  forall t <- genNonEmptyText. not (T.null t)
genNonEmptyText :: Gen Text
genNonEmptyText = do
  len <- choose (1, 100)
  chars <- vectorOf len $ elements (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> [' ', '-', '_'])
  pure $ T.pack chars

instance Arbitrary Text where
  arbitrary = genNonEmptyText

-- -----------------------------------------------------------------------------
-- User Identifier Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid UserId.
--
-- Generates UUIDs that are not nil.
--
-- Property:
--  forall uid <- genUserId. unUserId uid /= UUID.nil
genUserId :: Gen UserId
genUserId = do
  uuid <- genUUID `suchThat` (/= UUID.nil)
  case mkUserId uuid of
    Right uid -> pure uid
    Left _ -> genUserId -- Retry if invalid (shouldn't happen)

instance Arbitrary UserId where
  arbitrary = genUserId

-- -----------------------------------------------------------------------------
-- Configuration Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid ConfigurationId.
genConfigurationId :: Gen ConfigurationId
genConfigurationId = unsafeConfigurationId <$> genUUID `suchThat` (/= UUID.nil)

-- | Generate a valid DictionaryEntryId.
genDictionaryEntryId :: Gen DictionaryEntryId
genDictionaryEntryId = unsafeDictionaryEntryId <$> genUUID `suchThat` (/= UUID.nil)

instance Arbitrary DictionaryEntryId where
  arbitrary = genDictionaryEntryId

-- | Generate a valid DictionaryId.
--
-- Restricted to the three well-known ids actually used by the domain
-- ('income-category', 'expense-category', and 'labels') so property
-- tests don't accidentally exercise dictionary ids that no command
-- handler knows about.
genDictionaryId :: Gen DictionaryId
genDictionaryId = DictionaryId <$> elements ["income-category", "expense-category", "labels"]

-- | Generate a valid EntryName.
genEntryName :: Gen EntryName
genEntryName =
  unsafeEntryName
    <$> elements
      ["Salary", "Food", "Transport", "Rent", "Gift", "Other", "Utilities", "Entertainment"]

-- | Generate a valid DictionaryEntry.
genDictionaryEntry :: Gen DictionaryEntry
genDictionaryEntry = DictionaryEntry <$> genDictionaryEntryId <*> genEntryName

-- | Generate a valid Dictionary with at least one entry.
genDictionary :: Gen Dictionary
genDictionary = Dictionary <$> listOf1 genDictionaryEntry

-- | Arbitrary label set for transaction generators, biased toward
-- small sizes so the \"optional\" path of the labels feature stays
-- well-covered.
genLabelSet :: Gen (Set DictionaryEntryId)
genLabelSet = sized $ \n ->
  Set.fromList <$> vectorOf (min n 4) genDictionaryEntryId

-- | Generate a valid CreatedBy value.
genCreatedBy :: Gen CreatedBy
genCreatedBy = oneof [pure System, ClonedBy <$> genUserId <*> genConfigurationId]

-- -----------------------------------------------------------------------------
-- Telegram Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid TelegramId.
--
-- Telegram IDs are positive 64-bit integers.
--
-- Property:
--  forall tid <- genTelegramId. unTelegramId tid > 0
genTelegramId :: Gen TelegramId
genTelegramId = do
  -- Telegram IDs are positive integers
  telegramIdValue <- choose (1, maxBound) :: Gen Int64
  pure $ TelegramId telegramIdValue

instance Arbitrary TelegramId where
  arbitrary = genTelegramId

-- | Generate a valid TelegramIdentity.
--
-- Generates a Telegram identity with ID, optional username, and first name.
genTelegramIdentity :: Gen TelegramIdentity
genTelegramIdentity = do
  tid <- genTelegramId
  username <- oneof [pure Nothing, Just <$> genTelegramUsername]
  TelegramIdentity tid username <$> genNonEmptyText
  where
    genTelegramUsername :: Gen Text
    genTelegramUsername = do
      len <- choose (5, 32) -- Telegram usernames are 5-32 characters
      chars <- vectorOf len $ elements (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> ['_'])
      pure $ T.pack chars

instance Arbitrary TelegramIdentity where
  arbitrary = genTelegramIdentity

-- -----------------------------------------------------------------------------
-- OAuth Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid OAuthProvider.
genOAuthProvider :: Gen OAuthProvider
genOAuthProvider = elements [Google, GitHub, Microsoft]

instance Arbitrary OAuthProvider where
  arbitrary = genOAuthProvider

-- | Generate a valid OAuthIdentity.
--
-- Generates an OAuth identity with provider and subject.
genOAuthIdentity :: Gen OAuthIdentity
genOAuthIdentity = do
  provider <- genOAuthProvider
  -- OAuth subjects are typically numeric or alphanumeric strings
  subjectLen <- choose (10, 50)
  subjectChars <- vectorOf subjectLen $ elements (['a' .. 'z'] <> ['0' .. '9'])
  let subject = T.pack subjectChars
  pure $ OAuthIdentity provider subject

instance Arbitrary OAuthIdentity where
  arbitrary = genOAuthIdentity

-- -----------------------------------------------------------------------------
-- Password Generators
-- -----------------------------------------------------------------------------

-- | Generate a PasswordHash.
--
-- Note: This generates random bytes that represent a password hash.
-- In real code, password hashes are created by the Argon2 algorithm.
genPasswordHash :: Gen PasswordHash
genPasswordHash = do
  -- Argon2 hashes are typically around 97 bytes
  hashLen <- choose (64, 128)
  hashBytes <- vectorOf hashLen (arbitrary :: Gen Word8)
  pure $ PasswordHash $ BS.pack hashBytes

instance Arbitrary PasswordHash where
  arbitrary = genPasswordHash

-- -----------------------------------------------------------------------------
-- Email Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid email address.
--
-- Generates emails in the format user@domain.tld
genEmail :: Gen Text
genEmail = do
  localLen <- choose (3, 20)
  localChars <- vectorOf localLen $ elements (['a' .. 'z'] <> ['0' .. '9'] <> ['.', '_'])
  domainLen <- choose (3, 15)
  domainChars <- vectorOf domainLen $ elements ['a' .. 'z']
  tld <- elements ["com", "org", "net", "io", "dev"]
  pure $ T.pack localChars <> T.pack "@" <> T.pack domainChars <> T.pack "." <> T.pack tld

-- -----------------------------------------------------------------------------
-- Transfer Category Generators
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- Allocation Generators
-- -----------------------------------------------------------------------------

-- | Generate a single 'Allocation' with a strictly positive amount in
-- a random currency. Matches the 'amount > 0' invariant enforced by
-- the 'TransferType' smart constructors.
instance Arbitrary Allocation where
  arbitrary = Allocation <$> arbitrary <*> genPositiveMoney

-- | Generate a list of allocations all sharing the given currency,
-- partitioning the total amount across them. The last allocation
-- absorbs the rounding residual so the sum equals 'total' exactly.
--
-- Returns 'Nothing' if 'total' is not strictly positive (would
-- violate the per-allocation positivity invariant).
genAllocationsSummingTo :: Money -> Gen (Maybe Allocations)
genAllocationsSummingTo total
  | not (moneyIsPositive total) = pure Nothing
  | otherwise = do
      n <- choose (1, 4 :: Int)
      cids <- vectorOf n genDictionaryEntryId
      -- Build n-1 random positive slices, then place the residual on the last.
      let cur = moneyCurrency total
          totalRat = unMoney total
      pure (partitionMoneyExact totalRat cur cids)

-- | Deterministic helper used by 'genAllocationsSummingTo' and by
-- callers that already chose the category ids and the total.
--
-- For 'n' category ids, splits the total into 'n' equal slices (using
-- the underlying 'Rational'), then bumps the last slice by the rounding
-- residual. The result is 'Just' iff each resulting slice is strictly
-- positive. (For 'total > 0' and 'n <= 4' this is always 'Just'.)
partitionMoneyExact ::
  Rational ->
  Currency ->
  [DictionaryEntryId] ->
  Maybe Allocations
partitionMoneyExact _ _ [] = Nothing
partitionMoneyExact totalRat cur (c : cs)
  | totalRat <= 0 = Nothing
  | otherwise =
      let n = 1 + length cs
          slice = totalRat / fromIntegral n
          residual = totalRat - slice * fromIntegral n
          firstAlloc = Allocation c (unsafeMoney cur (slice + residual))
          rest = fmap (\ci -> Allocation ci (unsafeMoney cur slice)) cs
       in if slice > 0
            then Just (firstAlloc :| rest)
            else Nothing

-- -----------------------------------------------------------------------------
-- Transfer Type Generators
-- -----------------------------------------------------------------------------

-- | Generate a valid TransferType. Income / Expense are constructed via
-- their smart constructors with allocations that satisfy the invariants;
-- generation falls back to Transfer / Adjustment if no positive amount
-- could be produced.
genTransferType :: Gen TransferType
genTransferType =
  oneof
    [ buildCategorised mkIncome,
      buildCategorised mkExpense,
      pure Transfer,
      pure Adjustment
    ]
  where
    buildCategorised mk = do
      total <- genPositiveMoney
      mAllocs <- genAllocationsSummingTo total
      case mAllocs of
        Just allocs -> case mk total allocs of
          Right tt -> pure tt
          Left _ -> pure Transfer
        Nothing -> pure Transfer

instance Arbitrary TransferType where
  arbitrary = genTransferType

-- -----------------------------------------------------------------------------
-- Exchange Rate Generators
-- -----------------------------------------------------------------------------

-- | Generate a positive Rational value.
genPositiveRational :: Gen Rational
genPositiveRational = do
  n <- chooseInteger (1, 1000000)
  d <- chooseInteger (1, 1000000)
  pure (n % d)

-- | Generate a valid ExchangeRate with different source and target currencies.
genExchangeRate :: Gen ExchangeRate
genExchangeRate = do
  src <- genCurrency
  tgt <- elements [c | c <- [minBound .. maxBound], c /= src]
  unsafeExchangeRate src tgt <$> genPositiveRational

instance Arbitrary ExchangeRate where
  arbitrary = genExchangeRate

-- -----------------------------------------------------------------------------
-- Time Generators
-- -----------------------------------------------------------------------------

-- | Generate a 'Day' in the range 2000–2030 with all valid months/days.
instance Arbitrary Day where
  arbitrary = fromGregorian <$> choose (2000, 2030) <*> choose (1, 12) <*> choose (1, 28)
  shrink day = [addDays (-1) day, addDays 1 day]
