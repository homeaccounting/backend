{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Domain.Core.Types
-- Description : Core domain types for the accounting system
--
-- This module defines the fundamental value types used throughout the accounting domain.
-- All types include smart constructors with validation to maintain domain invariants.
module Domain.Core.Types
  ( -- * Money Type
    Money,
    mkMoney,
    unsafeMoney,
    unMoney,
    addMoney,
    subtractMoney,
    subtractMoneyAllowNegative,

    -- * Identifiers
    AccountId,
    mkAccountId,
    mkAccountIdSafe,
    unsafeAccountId,
    unAccountId,
    TransactionId,
    mkTransactionId,
    mkTransactionIdSafe,
    unsafeTransactionId,
    unTransactionId,
    UserId,
    mkUserId,
    mkUserIdSafe,
    unsafeUserId,
    unUserId,
    TelegramId (..),

    -- * Account Types
    AccountType (..),
    AccountRole (..),
    AccountAccess (..),

    -- * Transfer Types
    TransferType (..),
    IncomeCategory (..),
    ExpenseCategory (..),
    InternalCategory (..),
    TransferCategory (..),
    validateTransferCategory,

    -- * OAuth Types
    OAuthProvider (..),
    OAuthIdentity (..),

    -- * Telegram Types
    TelegramIdentity (..),

    -- * Password Types
    PasswordHash (..),
    unPasswordHash,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Money Type
-- -----------------------------------------------------------------------------

-- | Represents a monetary amount using exact rational arithmetic.
--
-- Uses Rational instead of Double to avoid floating-point precision issues.
-- This ensures exact calculations for financial operations.
--
-- Invariant: Money values must be non-negative.
-- Use smart constructor 'mkMoney' to create validated instances.
--
-- Mathematical Properties:
--  - Non-negative: forall m. unMoney m >= 0
--  - Additive identity: addMoney m (Money 0) = m
--  - Commutative: addMoney m1 m2 = addMoney m2 m1
--  - Associative: addMoney (addMoney m1 m2) m3 = addMoney m1 (addMoney m2 m3)
--  - Exact arithmetic: No rounding errors in basic operations
newtype Money = Money
  { unMoney :: Rational
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the rational value from a Money.
unMoney :: Money -> Rational
unMoney (Money r) = r

-- | JSON serialization for Money.
-- Serializes as a decimal number with appropriate precision.
instance ToJSON Money where
  toJSON (Money rat) = toJSON (fromRational rat :: Double)

-- | JSON deserialization for Money.
-- Accepts both integer and decimal numbers.
instance FromJSON Money where
  parseJSON v = do
    (d :: Double) <- parseJSON v
    case mkMoney (toRational d) of
      Right money -> pure money
      Left err -> fail (T.unpack err)

-- | Smart constructor for Money from Rational.
--
-- Creates a Money value if the amount is non-negative.
--
-- >>> mkMoney 100
-- Right (Money (100 % 1))
--
-- >>> mkMoney (-10)
-- Left "Money amount must be non-negative: (-10) % 1"
mkMoney :: Rational -> Either Text Money
mkMoney amount
  | amount < 0 = Left $ T.pack $ "Money amount must be non-negative: " <> show amount
  | otherwise = Right (Money amount)

-- | Unsafe constructor for Money.
--
-- WARNING: Only use in tests where you need to bypass validation.
-- This function does not perform any validation and will accept any amount,
-- including negative values.
--
-- >>> unsafeMoney 100
-- Money (100 % 1)
--
-- >>> unsafeMoney (-10)  -- Should not do this!
-- Money ((-10) % 1)
unsafeMoney :: Rational -> Money
unsafeMoney = Money

-- | Add two Money values.
--
-- >>> let m1 = Money 100
-- >>> let m2 = Money 50
-- >>> addMoney m1 m2
-- Money (150 % 1)
addMoney :: Money -> Money -> Money
addMoney (Money a) (Money b) = Money (a + b)

-- | Subtract two Money values.
--
-- Returns an error if the result would be negative.
--
-- >>> let m1 = Money 100
-- >>> let m2 = Money 50
-- >>> subtractMoney m1 m2
-- Right (Money (50 % 1))
--
-- >>> subtractMoney m2 m1
-- Left "Insufficient funds: cannot subtract 100 % 1 from 50 % 1"
subtractMoney :: Money -> Money -> Either Text Money
subtractMoney (Money a) (Money b)
  | a < b = Left $ T.pack $ "Insufficient funds: cannot subtract " <> show b <> " from " <> show a
  | otherwise = Right (Money (a - b))

-- | Subtract two Money values, allowing negative results.
--
-- This is used for External accounts that can go negative
-- (representing money owed to the "outside world").
--
-- >>> let m1 = Money 50
-- >>> let m2 = Money 100
-- >>> subtractMoneyAllowNegative m1 m2
-- Money ((-50) % 1)
subtractMoneyAllowNegative :: Money -> Money -> Money
subtractMoneyAllowNegative (Money a) (Money b) = Money (a - b)

-- -----------------------------------------------------------------------------
-- Account Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for an account.
--
-- Uses UUID internally to guarantee uniqueness across the system.
newtype AccountId = AccountId
  { unAccountId :: UUID
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the UUID from an AccountId.
unAccountId :: AccountId -> UUID
unAccountId (AccountId uuid) = uuid

instance ToJSON AccountId where
  toJSON = toJSON . unAccountId

instance FromJSON AccountId where
  parseJSON v = AccountId <$> parseJSON v

-- | Smart constructor for AccountId.
--
-- Creates an AccountId from a UUID.
--
-- >>> import Data.UUID (nil)
-- >>> mkAccountId nil
-- Left "Account ID cannot be nil UUID"
mkAccountId :: UUID -> Either Text AccountId
mkAccountId uuid
  | uuid == UUID.nil = Left $ T.pack "Account ID cannot be nil UUID"
  | otherwise = Right (AccountId uuid)

-- | Safe constructor for AccountId from UUID.
--
-- Returns Nothing for invalid UUIDs (nil UUID).
-- Useful in read models and projections where UUIDs come from valid events.
--
-- >>> import Data.UUID (nil)
-- >>> mkAccountIdSafe nil
-- Nothing
mkAccountIdSafe :: UUID -> Maybe AccountId
mkAccountIdSafe uuid =
  case mkAccountId uuid of
    Right accountId -> Just accountId
    Left _err -> Nothing

-- | Unsafe constructor for AccountId from UUID.
--
-- WARNING: Only use in tests where you need to bypass validation.
-- This function does not perform any validation and will accept any UUID,
-- including nil UUIDs.
--
-- >>> import Data.UUID (nil)
-- >>> unsafeAccountId nil
-- AccountId 00000000-0000-0000-0000-000000000000
unsafeAccountId :: UUID -> AccountId
unsafeAccountId = AccountId

-- -----------------------------------------------------------------------------
-- Transaction Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for a transaction.
--
-- Uses UUID internally to guarantee uniqueness across the system.
newtype TransactionId = TransactionId
  { unTransactionId :: UUID
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the UUID from a TransactionId.
unTransactionId :: TransactionId -> UUID
unTransactionId (TransactionId uuid) = uuid

instance ToJSON TransactionId where
  toJSON = toJSON . unTransactionId

instance FromJSON TransactionId where
  parseJSON v = TransactionId <$> parseJSON v

-- | Smart constructor for TransactionId.
--
-- Creates a TransactionId from a UUID.
--
-- >>> import Data.UUID (nil)
-- >>> mkTransactionId nil
-- Left "Transaction ID cannot be nil UUID"
mkTransactionId :: UUID -> Either Text TransactionId
mkTransactionId uuid
  | uuid == UUID.nil = Left $ T.pack "Transaction ID cannot be nil UUID"
  | otherwise = Right (TransactionId uuid)

-- | Safe constructor for TransactionId from UUID.
--
-- Returns Nothing for invalid UUIDs (nil UUID).
-- Useful in process managers and projections where UUIDs come from valid events.
--
-- >>> import Data.UUID (nil)
-- >>> mkTransactionIdSafe nil
-- Nothing
mkTransactionIdSafe :: UUID -> Maybe TransactionId
mkTransactionIdSafe uuid =
  case mkTransactionId uuid of
    Right txId -> Just txId
    Left _err -> Nothing

-- | Unsafe constructor for TransactionId from UUID.
--
-- WARNING: Only use in tests where you need to bypass validation.
-- This function does not perform any validation and will accept any UUID,
-- including nil UUIDs.
--
-- >>> import Data.UUID (nil)
-- >>> unsafeTransactionId nil
-- TransactionId 00000000-0000-0000-0000-000000000000
unsafeTransactionId :: UUID -> TransactionId
unsafeTransactionId = TransactionId

-- -----------------------------------------------------------------------------
-- User Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for a user.
--
-- Uses UUID internally to guarantee uniqueness across the system.
newtype UserId = UserId
  { unUserId :: UUID
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the UUID from a UserId.
unUserId :: UserId -> UUID
unUserId (UserId uuid) = uuid

instance ToJSON UserId where
  toJSON = toJSON . unUserId

instance FromJSON UserId where
  parseJSON v = UserId <$> parseJSON v

-- | Smart constructor for UserId.
--
-- Creates a UserId from a UUID.
--
-- >>> import Data.UUID (nil)
-- >>> mkUserId nil
-- Left "User ID cannot be nil UUID"
mkUserId :: UUID -> Either Text UserId
mkUserId uuid
  | uuid == UUID.nil = Left $ T.pack "User ID cannot be nil UUID"
  | otherwise = Right (UserId uuid)

-- | Safe constructor for UserId from UUID.
--
-- Returns Nothing for invalid UUIDs (nil UUID).
-- Useful in read models and projections where UUIDs come from valid events.
mkUserIdSafe :: UUID -> Maybe UserId
mkUserIdSafe uuid =
  case mkUserId uuid of
    Right userId -> Just userId
    Left _err -> Nothing

-- | Unsafe constructor for UserId from UUID.
--
-- WARNING: Only use in tests where you need to bypass validation.
unsafeUserId :: UUID -> UserId
unsafeUserId = UserId

-- -----------------------------------------------------------------------------
-- Telegram Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for a Telegram user.
--
-- Telegram user IDs are 64-bit integers assigned by Telegram.
newtype TelegramId = TelegramId
  { unTelegramId :: Int64
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the Int64 from a TelegramId.
unTelegramId :: TelegramId -> Int64
unTelegramId (TelegramId i) = i

instance ToJSON TelegramId where
  toJSON = toJSON . unTelegramId

instance FromJSON TelegramId where
  parseJSON v = TelegramId <$> parseJSON v

-- -----------------------------------------------------------------------------
-- Account Types
-- -----------------------------------------------------------------------------

-- | Type of account for transfer-only model.
--
-- - RegularAccount: User-created accounts (Checking, Savings, Cash, etc.)
-- - ExternalAccount: System-created account for each user to track income/expenses
data AccountType
  = -- | User-created account for holding money
    RegularAccount
  | -- | System-created account representing "outside world" for income/expenses
    ExternalAccount
  deriving (Show, Eq, Generic)

instance ToJSON AccountType

instance FromJSON AccountType

-- | Role-Based Access Control role for account access.
--
-- Roles determine what operations a user can perform on an account:
-- - Owner: Full control (view, transfer, share, delete)
-- - Editor: Can view and transfer
-- - Viewer: Read-only access
data AccountRole
  = Owner
  | Editor
  | Viewer
  deriving (Show, Eq, Ord, Generic)

instance ToJSON AccountRole

instance FromJSON AccountRole

-- | Access record linking a user to an account with a specific role.
data AccountAccess = AccountAccess
  { userId :: UserId,
    role :: AccountRole
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountAccess

instance FromJSON AccountAccess

-- -----------------------------------------------------------------------------
-- Transfer Types
-- -----------------------------------------------------------------------------

-- | Type of transfer operation.
data TransferType
  = Income
  | Expense
  | InternalTransfer
  deriving (Show, Eq, Generic)

instance ToJSON TransferType

instance FromJSON TransferType

-- | Category for income transfers.
data IncomeCategory
  = Salary
  | Freelance
  | Investment
  | IncomeGift
  | IncomeOther
  deriving (Show, Eq, Generic)

instance ToJSON IncomeCategory

instance FromJSON IncomeCategory

-- | Category for expense transfers.
data ExpenseCategory
  = Food
  | Transport
  | Utilities
  | Rent
  | Entertainment
  | ExpenseOther
  deriving (Show, Eq, Generic)

instance ToJSON ExpenseCategory

instance FromJSON ExpenseCategory

-- | Category for internal (account-to-account) transfers.
data InternalCategory
  = Rebalance
  | Savings
  | InternalOther
  deriving (Show, Eq, Generic)

instance ToJSON InternalCategory

instance FromJSON InternalCategory

-- | Transfer category, scoped by transfer type.
data TransferCategory
  = IncomeCat IncomeCategory
  | ExpenseCat ExpenseCategory
  | InternalCat InternalCategory
  deriving (Show, Eq, Generic)

instance ToJSON TransferCategory

instance FromJSON TransferCategory

-- | Validate that a TransferCategory is consistent with its TransferType.
validateTransferCategory :: TransferType -> TransferCategory -> Either Text ()
validateTransferCategory Income (IncomeCat _) = Right ()
validateTransferCategory Expense (ExpenseCat _) = Right ()
validateTransferCategory InternalTransfer (InternalCat _) = Right ()
validateTransferCategory transferType category =
  Left $ T.pack $ "Category " <> show category <> " is not valid for transfer type " <> show transferType

-- -----------------------------------------------------------------------------
-- OAuth Types
-- -----------------------------------------------------------------------------

-- | Supported OAuth providers.
data OAuthProvider
  = Google
  | GitHub
  | Microsoft
  deriving (Show, Eq, Ord, Generic)

instance ToJSON OAuthProvider

instance FromJSON OAuthProvider

-- | OAuth identity linking a user to an OAuth provider.
data OAuthIdentity = OAuthIdentity
  { -- | The OAuth provider
    provider :: OAuthProvider,
    -- | The unique subject identifier from the provider
    subject :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON OAuthIdentity

instance FromJSON OAuthIdentity

-- -----------------------------------------------------------------------------
-- Telegram Identity
-- -----------------------------------------------------------------------------

-- | Telegram identity for a user.
data TelegramIdentity = TelegramIdentity
  { -- | Telegram user ID
    id :: TelegramId,
    -- | Optional Telegram username (without @)
    username :: Maybe Text,
    -- | User's first name from Telegram
    firstName :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramIdentity

instance FromJSON TelegramIdentity

-- -----------------------------------------------------------------------------
-- Password Types
-- -----------------------------------------------------------------------------

-- | Hashed password stored using Argon2.
--
-- This newtype wraps a ByteString containing the password hash.
-- The hash is never decoded back to plaintext.
newtype PasswordHash = PasswordHash
  { unPasswordHash :: ByteString
  }
  deriving (Show, Eq, Generic)

-- | Extract the ByteString from a PasswordHash.
unPasswordHash :: PasswordHash -> ByteString
unPasswordHash (PasswordHash bs) = bs

-- | JSON serialization for PasswordHash (base64 encoded).
instance ToJSON PasswordHash where
  toJSON (PasswordHash bs) = toJSON $ decodeUtf8 $ B64.encode bs

instance FromJSON PasswordHash where
  parseJSON = withText "PasswordHash" $ \t ->
    case B64.decode $ encodeUtf8 t of
      Right bs -> pure $ PasswordHash bs
      Left err -> fail $ "Invalid base64 password hash: " <> err
