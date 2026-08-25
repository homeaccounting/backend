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
    Money (..),
    mkMoney,
    mkDefaultMoney,
    unsafeMoney,
    unMoney,
    moneyCurrency,
    addMoney,
    subtractMoney,
    moneyIsZero,
    moneyIsPositive,
    negateMoney,

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
    ContactId,
    EntryName,
    mkEntryName,
    unsafeEntryName,
    unEntryName,
    CreatedBy (..),
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
    AccountSubtypeKind (..),
    accountSubtypeKind,
    DefaultSubtypeAccounts (..),
    unDefaultSubtypeAccounts,
    defaultCash,
    defaultBankAccount,
    defaultEWallet,
    defaultAsset,
    defaultLoan,
    AccountType (..),
    isRegular,
    isExternal,
    accountTypeSubtypeKind,
    AccountRole (..),
    roleToText,
    AccountAccess (..),
    AccountStatus (..),

    -- * Transfer Types
    TransactionType (..),
    TransactionKind (..),
    kindOf,
    deriveTransactionKind,
    mkIncome,
    mkExpense,
    allocationsOf,
    isCategorised,
    validateAllocations,
    replaceAllocations,
    Allocation (..),
    mkAllocation,
    Allocations (..),
    mkAllocations,
    mkIncomeAllocations,
    mkExpenseAllocations,
    mkMixedAllocations,
    allAllocations,

    -- * Transaction Relationships
    RelationKind (..),
    renderRelationKind,
    parseRelationKind,
    RelationSpec (..),

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

import Data.Aeson (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..), defaultJSONKeyOptions, genericFromJSONKey, genericToJSONKey, object, withObject, withText, (.:), (.=))
import qualified Data.Aeson as Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64 as B64
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..), toList)
import Data.Map.Strict (Map)
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time.Calendar (Day)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import GHC.Generics (Generic)
import Text.Read (readMaybe)

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
--
-- Serializes as an object with amount and currency fields. The amount is
-- encoded as the exact 'Rational' rendered via 'show' (e.g. @"91899 % 100"@),
-- /not/ as a lossy 'Double'. This is what makes the persisted event-store
-- shape honour the type's exact-arithmetic invariant: an amount round-trips
-- through JSON with no floating-point precision loss, for any precision.
instance ToJSON Money where
  toJSON (Money rat cur) =
    object
      [ "amount" .= show rat,
        "currency" .= cur
      ]

-- | JSON deserialization for Money.
-- Accepts an object with amount and currency fields, where the amount is the
-- exact 'Rational' rendered by 'show' (see 'ToJSON').
instance FromJSON Money where
  parseJSON = withObject "Money" $ \o -> do
    amt <- o .: "amount"
    rat <- maybe (fail "Invalid Money amount") pure (readMaybe amt)
    cur <- o .: "currency"
    case mkMoney cur rat of
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

-- | True when the 'Money' amount is exactly zero (currency-agnostic).
moneyIsZero :: Money -> Bool
moneyIsZero (Money a _) = a == 0

-- | True when the 'Money' amount is strictly positive.
moneyIsPositive :: Money -> Bool
moneyIsPositive (Money a _) = a > 0

-- | Negate a 'Money' amount, preserving its currency.
negateMoney :: Money -> Money
negateMoney (Money a c) = Money (negate a) c

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

-- | The rate is encoded as the exact 'Rational' rendered via 'show' (e.g.
-- @"4105128 % 91899"@), /not/ as a lossy 'Double'. A derived cross-currency
-- rate is frequently a non-terminating decimal, so only the rational form
-- round-trips it without precision loss.
instance ToJSON ExchangeRate where
  toJSON (ExchangeRate s t r) =
    object ["source" .= s, "target" .= t, "rate" .= show r]

instance FromJSON ExchangeRate where
  parseJSON = withObject "ExchangeRate" $ \o -> do
    s <- o .: "source"
    t <- o .: "target"
    rs <- o .: "rate"
    r <- maybe (fail "Invalid ExchangeRate rate") pure (readMaybe rs)
    case mkExchangeRate s t r of
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

instance ToJSONKey TransactionId

instance FromJSONKey TransactionId

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

-- | A contact (counterparty) reference: the source of an income or the
-- beneficiary of an expense. An entry in the shared @contact@ dictionary.
type ContactId = DictionaryEntryId

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
  | Electronics
  | Equipment
  | Furniture
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

-- | Payload-free discriminator over 'AccountSubtype' constructors, for use as a
-- map key and wire tag (mirrors the query-side 'StatusKind' pattern).
data AccountSubtypeKind
  = CashKind
  | BankAccountKind
  | EWalletKind
  | AssetKind
  | LoanKind
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance ToJSON AccountSubtypeKind

instance FromJSON AccountSubtypeKind

-- | Object-keyed JSON so a @Map AccountSubtypeKind _@ serialises as a JSON
-- object keyed by the constructor name (e.g. @"CashKind"@).
instance ToJSONKey AccountSubtypeKind where
  toJSONKey = genericToJSONKey defaultJSONKeyOptions

instance FromJSONKey AccountSubtypeKind where
  fromJSONKey = genericFromJSONKey defaultJSONKeyOptions

-- | Payload-free projection of an 'AccountSubtype'.
accountSubtypeKind :: AccountSubtype -> AccountSubtypeKind
accountSubtypeKind (Cash _) = CashKind
accountSubtypeKind (BankAccount _) = BankAccountKind
accountSubtypeKind (EWallet _) = EWalletKind
accountSubtypeKind (Asset _) = AssetKind
accountSubtypeKind (Loan _) = LoanKind

-- | Newtype wrapper so the per-subtype default-account map can carry a
-- 'Database.Persist.PersistField' instance (stored as one JSON column) without
-- an orphan instance on 'Map'.
newtype DefaultSubtypeAccounts = DefaultSubtypeAccounts
  { unDefaultSubtypeAccounts :: Map AccountSubtypeKind AccountId
  }
  deriving (Show, Eq, Generic)

-- | Extract the underlying map from a 'DefaultSubtypeAccounts'.
unDefaultSubtypeAccounts :: DefaultSubtypeAccounts -> Map AccountSubtypeKind AccountId
unDefaultSubtypeAccounts (DefaultSubtypeAccounts m) = m

instance ToJSON DefaultSubtypeAccounts

instance FromJSON DefaultSubtypeAccounts

-- | Business behavior classification for accounts.
--
-- Regular accounts are user-created and carry an AccountSubtype for UI categorization.
-- External accounts are system-created for tracking income/expenses.
data AccountType
  = Regular AccountSubtype
  | External
  deriving (Show, Eq, Generic)

-- | True for user-created 'Regular' accounts (those that carry an
-- 'AccountSubtype'); False for the system-managed 'External' account.
isRegular :: AccountType -> Bool
isRegular (Regular _) = True
isRegular External = False

-- | True for the system-managed 'External' account; the complement of
-- 'isRegular'.
isExternal :: AccountType -> Bool
isExternal = not . isRegular

-- | The payload-free subtype discriminator of a 'Regular' account, or 'Nothing'
-- for the system-managed 'External' account.
accountTypeSubtypeKind :: AccountType -> Maybe AccountSubtypeKind
accountTypeSubtypeKind (Regular st) = Just (accountSubtypeKind st)
accountTypeSubtypeKind External = Nothing

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

-- | Render an 'AccountRole' as the lowercase wire token used by the HTTP API
-- ("owner"/"editor"/"viewer"). Inverse of 'Application.Services.AccountService.parseRole'.
roleToText :: AccountRole -> Text
roleToText Owner = "owner"
roleToText Editor = "editor"
roleToText Viewer = "viewer"

-- | Access record linking a user to an account with a specific role.
data AccountAccess = AccountAccess
  { userId :: UserId,
    role :: AccountRole
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountAccess

instance FromJSON AccountAccess

-- | Lifecycle status of an account.
--
-- Accounts are 'Opened' on creation. An owner may close (deactivate) an
-- account to hide it from the default UI; reopening restores it to 'Opened'.
-- Closing is a pure visibility label and imposes no behavioural restrictions
-- (see the account-close design spec).
data AccountStatus
  = Opened
  | Closed
  deriving (Show, Eq, Generic)

instance ToJSON AccountStatus

instance FromJSON AccountStatus

-- -----------------------------------------------------------------------------
-- Transfer Types
-- -----------------------------------------------------------------------------

-- | A single category slice of a transaction's categorised amount.
--
-- An 'Allocation' associates a portion of a transaction's total amount
-- with a category. Allocations are the building blocks of multi-category
-- splits: a 1000 UAH grocery purchase that is 200 UAH food and 800 UAH
-- housekeeping has two Allocations summing to 1000 UAH.
--
-- Invariants (enforced by the smart constructors of 'TransactionType' that
-- wrap allocation lists):
--
--   * amount > 0 (strict positivity)
--   * all allocations on one transaction share a 'Currency'
--   * sum of amounts equals the categorised total of the transaction

{-@
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: {m : Money | (amount m) > 0}
  , comment    :: Maybe Text
  }
@-}
data Allocation = Allocation
  { categoryId :: CategoryId,
    amount :: Money,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON Allocation

instance FromJSON Allocation

-- | Smart constructor for an 'Allocation'. Enforces @amount > 0@; the
-- optional comment is trimmed and blank text normalizes to 'Nothing'.
--
-- >>> import Data.UUID (fromWords)
-- >>> let c = unsafeDictionaryEntryId (fromWords 1 0 0 0)
-- >>> let Right m = mkDefaultMoney 10
-- >>> fmap (.amount) (mkAllocation c m Nothing)
-- Right (Money {amount = 10 % 1, currency = USD})
mkAllocation :: CategoryId -> Money -> Maybe Text -> Either DomainError Allocation
mkAllocation cid m mcomment
  | unMoney m > 0 = Right (Allocation cid m (normalizeComment mcomment))
  | otherwise =
      Left . ValidationErr $
        mkValidationError
          "amount"
          "Allocation amount must be positive"
          (T.pack (show (unMoney m)))

-- | Trim a comment; blank / whitespace-only becomes 'Nothing'.
normalizeComment :: Maybe Text -> Maybe Text
normalizeComment mt = do
  t <- mt
  let s = T.strip t
  if T.null s then Nothing else Just s

-- | The categorised side of a transaction, split into two buckets by the
-- dictionary the categories come from. The contra effect (a reimbursement
-- reducing an expense category) is derived from bucket + flow direction —
-- never a negative amount. Build via 'mkIncomeAllocations' /
-- 'mkExpenseAllocations' (single-bucket totals), 'mkMixedAllocations'
-- (both buckets), or 'mkAllocations' (dynamic, from possibly-empty lists).
data Allocations = Allocations
  { incomes :: [Allocation], -- categories from the income-category dict
    expenses :: [Allocation] -- categories from the expense-category dict
  }
  deriving (Show, Eq, Generic)

instance ToJSON Allocations

instance FromJSON Allocations

-- | All allocations regardless of bucket — the categorised lines as a flat list.
allAllocations :: Allocations -> [Allocation]
allAllocations a = a.incomes <> a.expenses

-- | Smart constructor. Enforces only the cross-bucket structural invariant
-- (not both empty); per-allocation positivity, currency, and sum-vs-total
-- are checked against an anchor amount by 'validateAllocations' /
-- 'mkIncome' / 'mkExpense'. Kind-agnostic by design — directional rules
-- (no contra-income) live in the constructors/handler.
mkAllocations :: [Allocation] -> [Allocation] -> Either DomainError Allocations
mkAllocations incs exps
  | null incs && null exps = Left AllocationsEmpty
  | otherwise = Right (Allocations incs exps)

-- | Allocations entirely in the income bucket (expense bucket empty).
-- Total: 'NonEmpty' guarantees the not-both-empty invariant, so — unlike
-- the fallible 'mkAllocations' — this returns 'Allocations' directly.
mkIncomeAllocations :: NonEmpty Allocation -> Allocations
mkIncomeAllocations xs = Allocations (toList xs) []

-- | Allocations entirely in the expense bucket (income bucket empty). Total.
mkExpenseAllocations :: NonEmpty Allocation -> Allocations
mkExpenseAllocations xs = Allocations [] (toList xs)

-- | Allocations spanning both buckets (income earnings + expense
-- reimbursements), e.g. a salary transfer bundling a rent reimbursement. Total.
mkMixedAllocations :: NonEmpty Allocation -> NonEmpty Allocation -> Allocations
mkMixedAllocations incs exps = Allocations (toList incs) (toList exps)

-- | Type of transfer operation.
--
-- 'Income' and 'Expense' carry one or more 'Allocation's whose amounts
-- sum to the transaction's categorised total. Construct via 'mkIncome'
-- / 'mkExpense' smart constructors to ensure the invariants hold.
--
-- 'Transfer' (internal account-to-account) and 'Adjustment' (balance
-- reconciliation) have no category side.
data TransactionType
  = Income Allocations
  | Expense Allocations
  | Transfer
  | Adjustment
  deriving (Show, Eq, Generic)

instance ToJSON TransactionType

instance FromJSON TransactionType

-- | The kind of a 'TransactionType', ignoring its payload. Used by command
-- handlers to enforce kind-preservation across edits.
data TransactionKind = IncomeKind | ExpenseKind | TransferKind | AdjustmentKind
  deriving (Show, Eq, Generic)

instance ToJSON TransactionKind

instance FromJSON TransactionKind

-- | Project a 'TransactionType' onto its 'TransactionKind' (constructor tag).
kindOf :: TransactionType -> TransactionKind
kindOf (Income _) = IncomeKind
kindOf (Expense _) = ExpenseKind
kindOf Transfer = TransferKind
kindOf Adjustment = AdjustmentKind

-- | Derive the 'TransactionKind' from the account types of the two endpoints.
--
-- The mapping reflects the financial semantics of money flowing between
-- account kinds:
--
-- * @Regular → External@: money leaves the user's assets → 'ExpenseKind'
-- * @External → Regular@: money enters the user's assets → 'IncomeKind'
-- * @Regular → Regular@: money moves between user's own accounts → 'TransferKind'
-- * @External → External@: structurally unreachable for valid inputs (the
--   service layer rejects @source == target@, and every user has exactly one
--   External account). The branch is kept exhaustive to satisfy the
--   no-partial-functions rule; the result is irrelevant.
deriveTransactionKind :: AccountType -> AccountType -> TransactionKind
deriveTransactionKind (Regular _) External = ExpenseKind
deriveTransactionKind External (Regular _) = IncomeKind
deriveTransactionKind (Regular _) (Regular _) = TransferKind
deriveTransactionKind External External = TransferKind -- DEAD: unreachable; value irrelevant

-- | The allocations on a categorised 'TransactionType', 'Nothing' otherwise.
allocationsOf :: TransactionType -> Maybe Allocations
allocationsOf (Income xs) = Just xs
allocationsOf (Expense xs) = Just xs
allocationsOf Transfer = Nothing
allocationsOf Adjustment = Nothing

-- | True for Income / Expense; False for Transfer / Adjustment.
isCategorised :: TransactionType -> Bool
isCategorised = isJust . allocationsOf

-- | Validate an allocation list against an expected categorised total.
--
-- Returns @Right ()@ when:
--
--   * every allocation amount is strictly positive
--   * every allocation shares 'expectedTotal''s currency
--   * the sum of allocation amounts equals 'expectedTotal'
validateAllocations ::
  Money ->
  Allocations ->
  Either DomainError ()
validateAllocations expectedTotal a =
  checkNotEmpty *> checkPositive *> checkCurrency *> checkSum
  where
    xs = allAllocations a
    expectedCurrency = expectedTotal.currency

    checkNotEmpty
      | null xs = Left AllocationsEmpty
      | otherwise = Right ()

    checkPositive = case filter (\x -> x.amount.amount <= 0) xs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError "amount" "Allocation amount must be positive" (T.pack (show bad.amount.amount))

    checkCurrency = case filter (\x -> x.amount.currency /= expectedCurrency) xs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError "currency" "All allocations must share the categorised currency" (T.pack (show bad.amount.currency))

    checkSum =
      let s = Money (sum (fmap (\x -> x.amount.amount) xs)) expectedCurrency
       in if s == expectedTotal
            then Right ()
            else
              Left . ValidationErr $
                mkValidationError "allocations" "Sum of allocations must equal categorised amount" (T.pack (show s.amount))

-- | Replace the allocations payload of a categorised 'TransactionType'.
--
-- No-op on 'Transfer' / 'Adjustment' (their structure has no allocations).
-- The new allocations must already satisfy the smart-constructor
-- invariants for the surrounding kind (sum-equals-total, currency
-- consistency, amount > 0); this helper does not re-validate.
replaceAllocations :: Allocations -> TransactionType -> TransactionType
replaceAllocations new tt = case tt of
  Income _ -> Income new
  Expense _ -> Expense new
  Transfer -> Transfer
  Adjustment -> Adjustment

-- | Construct an Income 'TransactionType'.
--
-- The categorised amount is the transaction's target-side amount
-- (the side credited by the income). The allocations must:
--
--   * carry at least one slice across both buckets ('AllocationsEmpty')
--   * each have @amount > 0@
--   * all share the same 'Currency' as the categorised total
--   * sum to the categorised total
--
-- Both buckets may be populated: a non-empty @expenses@ bucket is a
-- reimbursement (contra-expense), which is allowed on income.
mkIncome :: Money -> Allocations -> Either DomainError TransactionType
mkIncome categorisedTotal a = do
  validateAllocations categorisedTotal a
  pure (Income a)

-- | Construct an Expense 'TransactionType'.
--
-- The categorised amount is the transaction's source-side amount
-- (the side debited by the expense). Same invariants as 'mkIncome',
-- plus the directional contra rule: the @incomes@ bucket must be empty
-- (a contra-income expense is unsupported → 'ContraIncomeNotSupported').
mkExpense :: Money -> Allocations -> Either DomainError TransactionType
mkExpense categorisedTotal a = do
  validateAllocations categorisedTotal a
  if null a.incomes
    then pure (Expense a)
    else Left ContraIncomeNotSupported

-- -----------------------------------------------------------------------------
-- Transaction Relationships
-- -----------------------------------------------------------------------------

-- | The kind of a typed relationship between two transactions. See
-- docs/specs/2026-07-05-transaction-relationships-design.md.
--
--   * 'Refund'     — an Income transaction partially/fully refunds an Expense.
--   * 'Merge'      — a cancelled source transaction was merged into a target.
--   * 'Split'      — a newly-created result was split from an origin.
--   * 'Associated' — a generic user-declared link between two related
--     transactions of any kind (e.g. a delivery expense tied to the goods
--     purchase, or two incomes that are parts of one payment). Endpoint kinds
--     are unrestricted.
--
-- Direction is a documented convention (the owning/self transaction is the
-- "from" endpoint; the referenced one is 'relatedTransactionId'), not encoded
-- in the constructor names.
data RelationKind = Refund | Merge | Split | Associated
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance ToJSON RelationKind

instance FromJSON RelationKind

-- | An at-creation relationship request threaded through 'InitiateTransactionPosting':
-- the referenced (pre-existing) transaction and the kind of edge to record. The
-- owning ("from") transaction is the one being created, so it is not named here.
data RelationSpec = RelationSpec
  { relatedTransactionId :: TransactionId,
    relationKind :: RelationKind
  }
  deriving (Show, Eq, Generic)

instance ToJSON RelationSpec

instance FromJSON RelationSpec

-- | Render a 'RelationKind' to its lowercase wire/DB token.
renderRelationKind :: RelationKind -> Text
renderRelationKind Refund = "refund"
renderRelationKind Merge = "merge"
renderRelationKind Split = "split"
renderRelationKind Associated = "associated"

-- | Parse a wire/DB token (trimmed, case-insensitive) to a 'RelationKind'.
parseRelationKind :: Text -> Maybe RelationKind
parseRelationKind raw = case T.toLower (T.strip raw) of
  "refund" -> Just Refund
  "merge" -> Just Merge
  "split" -> Just Split
  "associated" -> Just Associated
  _ -> Nothing

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
