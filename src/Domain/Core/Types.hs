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
    currencyNumericCode,
    currencyFromNumericCode,

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
    ConfigurationId,
    mkConfigurationId,
    mkConfigurationIdSafe,
    unsafeConfigurationId,
    unConfigurationId,
    defaultConfigurationId,
    DictionaryEntryId,
    mkDictionaryEntryId,
    unsafeDictionaryEntryId,
    unDictionaryEntryId,
    LabelId,
    CategoryId,
    MCC,
    DictionaryId (..),
    unDictionaryId,
    EntryName,
    mkEntryName,
    unsafeEntryName,
    unEntryName,
    CreatedBy (..),
    DictionaryEntry (..),
    Dictionary (..),
    TelegramId (..),

    -- * Account Types
    CardNetwork (..),
    AssetType (..),
    CashProperties (..),
    BankAccountProperties (..),
    EWalletProperties (..),
    AssetProperties (..),
    LoanProperties (..),
    defaultCashProperties,
    defaultBankAccountProperties,
    defaultEWalletProperties,
    defaultAssetProperties,
    defaultLoanProperties,
    AccountSubtype (..),
    defaultCash,
    defaultBankAccount,
    defaultEWallet,
    defaultAsset,
    defaultLoan,
    AccountType (..),
    AccountRole (..),
    AccountAccess (..),

    -- * Transfer Types
    TransferType (..),

    -- * OAuth Types
    OAuthProvider (..),
    OAuthIdentity (..),

    -- * Telegram Types
    TelegramIdentity (..),

    -- * External Transaction Identifier
    ExternalTransactionId,
    mkExternalTransactionId,
    unsafeExternalTransactionId,
    unExternalTransactionId,

    -- * Password Types
    PasswordHash (..),
    unPasswordHash,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.:), (.=))
import qualified Data.Aeson as Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time.Calendar (Day)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import GHC.Generics (Generic)
import RIO (Display (..))

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

-- | Convert a Currency to its ISO 4217 numeric code.
currencyNumericCode :: Currency -> Int
currencyNumericCode UAH = 980
currencyNumericCode USD = 840
currencyNumericCode EUR = 978
currencyNumericCode GBP = 826

-- | Parse a Currency from its ISO 4217 numeric code.
currencyFromNumericCode :: Int -> Either Text Currency
currencyFromNumericCode 980 = Right UAH
currencyFromNumericCode 840 = Right USD
currencyFromNumericCode 978 = Right EUR
currencyFromNumericCode 826 = Right GBP
currencyFromNumericCode code = Left $ "Unsupported currency code: " <> T.pack (show code)

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
-- Configuration Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for a configuration aggregate.
newtype ConfigurationId = ConfigurationId
  { unConfigurationId :: UUID
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the UUID from a ConfigurationId.
unConfigurationId :: ConfigurationId -> UUID
unConfigurationId (ConfigurationId uuid) = uuid

instance ToJSON ConfigurationId where
  toJSON = toJSON . unConfigurationId

instance FromJSON ConfigurationId where
  parseJSON v = ConfigurationId <$> parseJSON v

mkConfigurationId :: UUID -> Either Text ConfigurationId
mkConfigurationId uuid
  | uuid == UUID.nil = Left "ConfigurationId cannot be nil UUID"
  | otherwise = Right (ConfigurationId uuid)

mkConfigurationIdSafe :: UUID -> Maybe ConfigurationId
mkConfigurationIdSafe uuid
  | uuid == UUID.nil = Nothing
  | otherwise = Just (ConfigurationId uuid)

unsafeConfigurationId :: UUID -> ConfigurationId
unsafeConfigurationId = ConfigurationId

-- | Well-known ID for the system default configuration.
defaultConfigurationId :: ConfigurationId
defaultConfigurationId = ConfigurationId (fromJust (UUID.fromString "00000000-0000-0000-0000-000000000001"))

-- -----------------------------------------------------------------------------
-- Dictionary Entry Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for a dictionary entry.
newtype DictionaryEntryId = DictionaryEntryId
  { unDictionaryEntryId :: UUID
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the UUID from a DictionaryEntryId.
unDictionaryEntryId :: DictionaryEntryId -> UUID
unDictionaryEntryId (DictionaryEntryId uuid) = uuid

instance ToJSON DictionaryEntryId where
  toJSON = toJSON . unDictionaryEntryId

instance FromJSON DictionaryEntryId where
  parseJSON v = DictionaryEntryId <$> parseJSON v

mkDictionaryEntryId :: UUID -> Either Text DictionaryEntryId
mkDictionaryEntryId uuid
  | uuid == UUID.nil = Left "DictionaryEntryId cannot be nil UUID"
  | otherwise = Right (DictionaryEntryId uuid)

unsafeDictionaryEntryId :: UUID -> DictionaryEntryId
unsafeDictionaryEntryId = DictionaryEntryId

-- | Alias for a label identifier. Labels reuse the same storage as
-- dictionary entries; treating them as aliases avoids a parallel type
-- hierarchy while keeping spec language ("labels") intact at call sites.
type LabelId = DictionaryEntryId

-- | Alias for a category identifier. Categories reuse the same storage as
-- dictionary entries; treating them as aliases avoids a parallel type
-- hierarchy while keeping spec language ("categories") intact at call sites.
type CategoryId = DictionaryEntryId

-- | ISO 18245 Merchant Category Code, rendered as text.
--
-- Monobank-produced MCCs are 4-digit numeric codes but they are
-- consistently transported and stored as strings (API payloads, JSON
-- map keys, log lines). Modeling as 'Text' also keeps the door open
-- for future providers that emit non-numeric category keys through
-- the same field.
type MCC = Text

-- -----------------------------------------------------------------------------
-- Dictionary Id
-- -----------------------------------------------------------------------------

-- | Opaque dictionary key — no domain semantics in Configuration context.
newtype DictionaryId = DictionaryId
  { unDictionaryId :: Text
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the Text from a DictionaryId.
unDictionaryId :: DictionaryId -> Text
unDictionaryId (DictionaryId t) = t

instance ToJSON DictionaryId where
  toJSON = toJSON . unDictionaryId

instance FromJSON DictionaryId where
  parseJSON v = DictionaryId <$> parseJSON v

-- -----------------------------------------------------------------------------
-- Entry Name
-- -----------------------------------------------------------------------------

-- | Display name for a dictionary entry (non-empty, trimmed, max 50 chars).
newtype EntryName = EntryName
  { unEntryName :: Text
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the Text from an EntryName.
unEntryName :: EntryName -> Text
unEntryName (EntryName t) = t

instance ToJSON EntryName where
  toJSON = toJSON . unEntryName

instance FromJSON EntryName where
  parseJSON v = EntryName <$> parseJSON v

mkEntryName :: Text -> Either Text EntryName
mkEntryName raw
  | T.null trimmed = Left "EntryName cannot be empty"
  | T.length trimmed > 50 = Left "EntryName cannot exceed 50 characters"
  | otherwise = Right (EntryName trimmed)
  where
    trimmed = T.strip raw

unsafeEntryName :: Text -> EntryName
unsafeEntryName = EntryName

-- -----------------------------------------------------------------------------
-- Configuration Types
-- -----------------------------------------------------------------------------

-- | Who created a configuration.
data CreatedBy
  = System
  | ClonedBy UserId ConfigurationId
  deriving (Show, Eq, Generic)

instance ToJSON CreatedBy

instance FromJSON CreatedBy

-- | A single dictionary entry.
data DictionaryEntry = DictionaryEntry
  { entryId :: DictionaryEntryId,
    name :: EntryName
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryEntry

instance FromJSON DictionaryEntry

-- | A collection of entries.
data Dictionary = Dictionary
  { entries :: [DictionaryEntry]
  }
  deriving (Show, Eq, Generic)

instance ToJSON Dictionary

instance FromJSON Dictionary

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

-- | Network of a bank card.
data CardNetwork
  = Visa
  | Mastercard
  | Amex
  | OtherCardNetwork Text
  deriving (Show, Eq, Generic)

instance ToJSON CardNetwork

instance FromJSON CardNetwork

-- | Type of asset held.
data AssetType
  = Property
  | Vehicle
  | Stocks
  | RetirementFund
  | OtherAsset Text
  deriving (Show, Eq, Generic)

instance ToJSON AssetType

instance FromJSON AssetType

-- | Properties specific to cash accounts.
data CashProperties = CashProperties
  { storageLocation :: Maybe Text,
    metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON CashProperties

instance FromJSON CashProperties

-- | Properties specific to bank accounts (checking, savings, debit/credit cards).
data BankAccountProperties = BankAccountProperties
  { bankName :: Maybe Text,
    accountNumber :: Maybe Text,
    cardNetwork :: Maybe CardNetwork,
    metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON BankAccountProperties

instance FromJSON BankAccountProperties

-- | Properties specific to electronic wallet accounts.
data EWalletProperties = EWalletProperties
  { provider :: Maybe Text,
    accountIdentifier :: Maybe Text,
    metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON EWalletProperties

instance FromJSON EWalletProperties

-- | Properties specific to asset accounts (property, vehicles, stocks, etc.).
data AssetProperties = AssetProperties
  { assetType :: Maybe AssetType,
    description :: Maybe Text,
    metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AssetProperties

instance FromJSON AssetProperties

-- | Properties specific to loan/liability accounts.
data LoanProperties = LoanProperties
  { lender :: Maybe Text,
    interestRate :: Maybe Rational,
    dueDate :: Maybe Day,
    metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON LoanProperties

instance FromJSON LoanProperties

-- | Default property constructors with all fields empty.
defaultCashProperties :: CashProperties
defaultCashProperties = CashProperties Nothing mempty

defaultBankAccountProperties :: BankAccountProperties
defaultBankAccountProperties = BankAccountProperties Nothing Nothing Nothing mempty

defaultEWalletProperties :: EWalletProperties
defaultEWalletProperties = EWalletProperties Nothing Nothing mempty

defaultAssetProperties :: AssetProperties
defaultAssetProperties = AssetProperties Nothing Nothing mempty

defaultLoanProperties :: LoanProperties
defaultLoanProperties = LoanProperties Nothing Nothing Nothing mempty

-- | User-facing account classification with per-type properties.
data AccountSubtype
  = Cash CashProperties
  | BankAccount BankAccountProperties
  | EWallet EWalletProperties
  | Asset AssetProperties
  | Loan LoanProperties
  deriving (Show, Eq, Generic)

instance ToJSON AccountSubtype

instance FromJSON AccountSubtype

-- | Convenience constructors with default empty properties.
defaultCash :: AccountSubtype
defaultCash = Cash defaultCashProperties

defaultBankAccount :: AccountSubtype
defaultBankAccount = BankAccount defaultBankAccountProperties

defaultEWallet :: AccountSubtype
defaultEWallet = EWallet defaultEWalletProperties

defaultAsset :: AccountSubtype
defaultAsset = Asset defaultAssetProperties

defaultLoan :: AccountSubtype
defaultLoan = Loan defaultLoanProperties

-- | Business behavior classification for accounts.
--
-- Regular accounts are user-created and carry an AccountSubtype for UI categorization.
-- External accounts are system-created for tracking income/expenses.
data AccountType
  = Regular AccountSubtype
  | External
  deriving (Show, Eq, Generic)

instance ToJSON AccountType where
  toJSON External = toJSON ("External" :: Text)
  toJSON (Regular st) = object ["tag" .= ("Regular" :: Text), "subtype" .= st]

instance FromJSON AccountType where
  parseJSON (Aeson.String "External") = pure External
  parseJSON v = flip (withObject "AccountType") v $ \o -> do
    tag <- o .: "tag"
    case (tag :: Text) of
      "Regular" -> Regular <$> o .: "subtype"
      _ -> fail $ "Unknown AccountType tag: " <> show tag

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
--
-- Income and Expense carry a CategoryId referencing the user's
-- configured category. Transfer (internal) has no category.
data TransferType
  = Income CategoryId
  | Expense CategoryId
  | Transfer
  deriving (Show, Eq, Generic)

instance ToJSON TransferType

instance FromJSON TransferType

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
-- External Transaction Identifier
-- -----------------------------------------------------------------------------

-- | Identifier for a transaction in an external system (e.g., Monobank).
--   Must be non-empty.
newtype ExternalTransactionId = ExternalTransactionId Text
  deriving (Show, Eq, Ord, Generic)

unExternalTransactionId :: ExternalTransactionId -> Text
unExternalTransactionId (ExternalTransactionId t) = t

mkExternalTransactionId :: Text -> Either Text ExternalTransactionId
mkExternalTransactionId t
  | T.null t = Left "ExternalTransactionId must not be empty"
  | otherwise = Right (ExternalTransactionId t)

unsafeExternalTransactionId :: Text -> ExternalTransactionId
unsafeExternalTransactionId = ExternalTransactionId

instance Display ExternalTransactionId where
  display (ExternalTransactionId t) = display t

instance ToJSON ExternalTransactionId where
  toJSON (ExternalTransactionId t) = toJSON t

instance FromJSON ExternalTransactionId where
  parseJSON = withText "ExternalTransactionId" $ \t ->
    case mkExternalTransactionId t of
      Right eid -> pure eid
      Left err -> fail (T.unpack err)

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
