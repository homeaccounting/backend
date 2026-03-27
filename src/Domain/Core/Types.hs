{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Domain.Core.Types
-- Description : Core domain types for the accounting system
--
-- This module defines the fundamental value types used throughout the accounting domain.
-- All types include smart constructors with validation to maintain domain invariants.
module Domain.Core.Types
  ( -- * Currency Type
    Currency (..),
    parseCurrency,

    -- * Money Type
    Money,
    mkMoney,
    mkDefaultMoney,
    unsafeMoney,
    unMoney,
    moneyCurrency,
    addMoney,
    subtractMoney,

    -- * Exchange Rate Type
    ExchangeRate,
    mkExchangeRate,
    unsafeExchangeRate,
    exchangeRateSource,
    exchangeRateTarget,
    exchangeRateValue,
    convert,

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

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
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
-- Currency Type
-- -----------------------------------------------------------------------------

-- | Supported currencies in the accounting system.
data Currency = UAH | USD | EUR | GBP
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

instance ToJSON Currency where
  toJSON UAH = toJSON ("UAH" :: Text)
  toJSON USD = toJSON ("USD" :: Text)
  toJSON EUR = toJSON ("EUR" :: Text)
  toJSON GBP = toJSON ("GBP" :: Text)

instance FromJSON Currency where
  parseJSON = withText "Currency" $ \t ->
    case parseCurrency t of
      Right c -> pure c
      Left err -> fail (T.unpack err)

-- | Parse a currency code from text.
--
-- >>> parseCurrency "UAH"
-- Right UAH
--
-- >>> parseCurrency "xyz"
-- Left "Unknown currency: xyz"
parseCurrency :: Text -> Either Text Currency
parseCurrency t = case T.toUpper t of
  "UAH" -> Right UAH
  "USD" -> Right USD
  "EUR" -> Right EUR
  "GBP" -> Right GBP
  _ -> Left $ "Unknown currency: " <> t

-- -----------------------------------------------------------------------------
-- Money Type
-- -----------------------------------------------------------------------------

-- | Represents a monetary amount with currency using exact rational arithmetic.
--
-- Uses Rational instead of Double to avoid floating-point precision issues.
-- This ensures exact calculations for financial operations.
--
-- Money values can be negative (overdraft enforcement is at account level).
-- Use smart constructor 'mkMoney' to create instances.
--
-- Mathematical Properties:
--  - Additive identity: addMoney m (mkMoney c 0) = m (when currencies match)
--  - Commutative: addMoney m1 m2 = addMoney m2 m1 (when currencies match)
--  - Associative: addMoney (addMoney m1 m2) m3 = addMoney m1 (addMoney m2 m3) (when currencies match)
--  - Exact arithmetic: No rounding errors in basic operations
data Money = Money
  { amount :: Rational,
    currency :: Currency
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the rational value from a Money.
unMoney :: Money -> Rational
unMoney (Money r _) = r

-- | Extract the currency from a Money.
moneyCurrency :: Money -> Currency
moneyCurrency (Money _ c) = c

-- | JSON serialization for Money.
-- Serializes as an object with amount and currency fields.
instance ToJSON Money where
  toJSON (Money rat cur) =
    object
      [ "amount" .= (fromRational rat :: Double),
        "currency" .= cur
      ]

-- | JSON deserialization for Money.
-- Accepts an object with amount and currency fields.
instance FromJSON Money where
  parseJSON = withObject "Money" $ \o -> do
    (d :: Double) <- o .: "amount"
    cur <- o .: "currency"
    case mkMoney cur (toRational d) of
      Right money -> pure money
      Left err -> fail (T.unpack err)

-- | Smart constructor for Money from Currency and Rational.
--
-- Creates a Money value for any amount (negative values are allowed).
--
-- >>> mkMoney UAH 100
-- Right (Money {amount = 100 % 1, currency = UAH})
--
-- >>> mkMoney UAH (-10)
-- Right (Money {amount = (-10) % 1, currency = UAH})
mkMoney :: Currency -> Rational -> Either Text Money
mkMoney cur amt = Right (Money amt cur)

-- | Smart constructor for Money using the default currency (USD).
--
-- >>> mkDefaultMoney 100
-- Right (Money {amount = 100 % 1, currency = USD})
mkDefaultMoney :: Rational -> Either Text Money
mkDefaultMoney = mkMoney USD

-- | Unsafe constructor for Money.
--
-- WARNING: Only use in tests where you need to bypass validation.
-- This function does not perform any validation and will accept any amount,
-- including negative values.
--
-- >>> unsafeMoney UAH 100
-- Money {amount = 100 % 1, currency = UAH}
unsafeMoney :: Currency -> Rational -> Money
unsafeMoney cur amt = Money amt cur

-- | Add two Money values.
--
-- Returns an error if the currencies do not match.
addMoney :: Money -> Money -> Either Text Money
addMoney (Money a ca) (Money b cb)
  | ca /= cb = Left $ "Currency mismatch: cannot add " <> T.pack (show ca) <> " and " <> T.pack (show cb)
  | otherwise = Right (Money (a + b) ca)

-- | Subtract two Money values.
--
-- Returns an error only if the currencies do not match.
-- Negative results are allowed (overdraft enforcement is at account level).
subtractMoney :: Money -> Money -> Either Text Money
subtractMoney (Money a ca) (Money b cb)
  | ca /= cb = Left $ "Currency mismatch: cannot subtract " <> T.pack (show cb) <> " from " <> T.pack (show ca)
  | otherwise = Right (Money (a - b) ca)

-- -----------------------------------------------------------------------------
-- Exchange Rate Type
-- -----------------------------------------------------------------------------

-- | Represents an exchange rate between two currencies.
--
-- The rate converts from source to target currency:
-- amount_in_target = amount_in_source * rate
--
-- Uses Rational for exact arithmetic (no floating-point precision loss).
data ExchangeRate = ExchangeRate
  { source :: Currency,
    target :: Currency,
    rate :: Rational
  }
  deriving (Show, Eq, Generic)

instance ToJSON ExchangeRate where
  toJSON (ExchangeRate s t r) =
    object ["source" .= s, "target" .= t, "rate" .= (fromRational r :: Double)]

instance FromJSON ExchangeRate where
  parseJSON = withObject "ExchangeRate" $ \o -> do
    s <- o .: "source"
    t <- o .: "target"
    (d :: Double) <- o .: "rate"
    case mkExchangeRate s t (toRational d) of
      Right er -> pure er
      Left err -> fail (T.unpack err)

-- | Smart constructor. Rejects non-positive rates and same-currency pairs.
--
-- >>> mkExchangeRate UAH USD 0.025
-- Right (ExchangeRate {source = UAH, target = USD, rate = ...})
--
-- >>> mkExchangeRate USD USD 1.0
-- Left "Source and target currencies must differ"
--
-- >>> mkExchangeRate UAH USD 0
-- Left "Exchange rate must be positive"
mkExchangeRate :: Currency -> Currency -> Rational -> Either Text ExchangeRate
mkExchangeRate src tgt r
  | src == tgt = Left "Source and target currencies must differ"
  | r <= 0 = Left "Exchange rate must be positive"
  | otherwise = Right (ExchangeRate src tgt r)

-- | Unsafe constructor for tests. Bypasses validation.
unsafeExchangeRate :: Currency -> Currency -> Rational -> ExchangeRate
unsafeExchangeRate = ExchangeRate

-- | Extract the source currency from an ExchangeRate.
exchangeRateSource :: ExchangeRate -> Currency
exchangeRateSource (ExchangeRate s _ _) = s

-- | Extract the target currency from an ExchangeRate.
exchangeRateTarget :: ExchangeRate -> Currency
exchangeRateTarget (ExchangeRate _ t _) = t

-- | Extract the rate value from an ExchangeRate.
exchangeRateValue :: ExchangeRate -> Rational
exchangeRateValue (ExchangeRate _ _ r) = r

-- | Convert money using an exchange rate.
--
-- Output is in the rate's target currency.
-- Uses direct pattern match on Money since both types are in this module.
--
-- >>> convert (unsafeExchangeRate UAH USD 0.025) (unsafeMoney UAH 1000)
-- Money {amount = 25 % 1, currency = USD}
convert :: ExchangeRate -> Money -> Money
convert (ExchangeRate _ tgt r) (Money amt _) = Money (amt * r) tgt

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
