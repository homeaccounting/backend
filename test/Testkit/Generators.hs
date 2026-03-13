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
    genTelegramId,
    genTelegramIdentity,
    genOAuthProvider,
    genOAuthIdentity,
    genPasswordHash,
    genEmail,
    genNonEmptyText,
    genIncomeCategory,
    genExpenseCategory,
    genInternalCategory,
    genTransferType,
    genTransferCategory,

    -- * Arbitrary Instances
  )
where

-- Instances are exported automatically

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
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
-- Generates non-negative amounts up to 1,000,000.00 with 2 decimal places.
-- Uses Rational for exact arithmetic.
--
-- Property:
--  forall m <- genMoney. unMoney m >= 0
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
-- Generates non-negative amounts up to 1,000,000.00 with 2 decimal places.
genMoneyIn :: Currency -> Gen Money
genMoneyIn cur = do
  -- Generate cents (0 to 100,000,000 cents = 0 to 1,000,000.00)
  cents <- choose (0, 100000000) :: Gen Integer
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

-- | Generate a valid IncomeCategory.
genIncomeCategory :: Gen IncomeCategory
genIncomeCategory = elements [Salary, Freelance, Investment, IncomeGift, IncomeOther]

instance Arbitrary IncomeCategory where
  arbitrary = genIncomeCategory

-- | Generate a valid ExpenseCategory.
genExpenseCategory :: Gen ExpenseCategory
genExpenseCategory = elements [Food, Transport, Utilities, Rent, Entertainment, ExpenseOther]

instance Arbitrary ExpenseCategory where
  arbitrary = genExpenseCategory

-- | Generate a valid InternalCategory.
genInternalCategory :: Gen InternalCategory
genInternalCategory = elements [Rebalance, Savings, InternalOther]

instance Arbitrary InternalCategory where
  arbitrary = genInternalCategory

-- | Generate a valid TransferType.
genTransferType :: Gen TransferType
genTransferType = elements [Income, Expense, InternalTransfer]

instance Arbitrary TransferType where
  arbitrary = genTransferType

-- | Generate a valid TransferCategory.
genTransferCategory :: Gen TransferCategory
genTransferCategory =
  oneof
    [ IncomeCat <$> arbitrary,
      ExpenseCat <$> arbitrary,
      InternalCat <$> arbitrary
    ]

instance Arbitrary TransferCategory where
  arbitrary = genTransferCategory
