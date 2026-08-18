{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- |
-- Module      : Infrastructure.Database.Orphans
-- Description : @PersistField@ instances for domain id types used as read-model columns
--
-- Persistent read models store domain identifiers in real (indexed) columns.
-- This module provides the @persistent@ serialization for those id types,
-- reusing eventium's existing @PersistField UUID@ instance
-- ('Eventium.Store.Sql.Orphans') so UUID-backed ids share one wire format.
--
-- These are orphan instances (the types live in @Domain.Core.Types@, the class
-- in @persistent@); they are centralized here so that multiple read models can
-- depend on them without redefining — and risking conflicting — instances.
module Infrastructure.Database.Orphans () where

import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeStrict', encode, object, parseJSON, toJSON, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.UUID (UUID)
import Database.Persist (PersistField (..), PersistValue (..))
import Database.Persist.Sql (PersistFieldSql (..), SqlType (SqlString))
import Domain.Banking.Import (ExternalTransactionId, mkExternalTransactionId, unExternalTransactionId)
import Domain.Banking.Types (BankConnectionId, BankProviderId)
import Domain.Configuration.Dictionary (DictionaryKind, EntryRole (..), dictionaryKindSlug, parseDictionaryKind)
import Domain.Core.Types (AccountId, AccountRole, AccountStatus, AccountSubtypeKind, AccountType, Allocation (..), Allocations (..), ConfigurationId, CreatedBy, Currency, DefaultSubtypeAccounts, DictionaryEntryId, EntryName, ExchangeRate, Money, OAuthProvider, RelationKind, TelegramId (..), TransactionId, TransactionType (..), UserId, exchangeRateSource, exchangeRateTarget, exchangeRateValue, mkAccountIdSafe, mkConfigurationIdSafe, mkDictionaryEntryId, mkExchangeRate, mkMoney, mkTransactionIdSafe, mkUserIdSafe, moneyCurrency, parseRelationKind, renderRelationKind, unAccountId, unConfigurationId, unDictionaryEntryId, unMoney, unTransactionId, unUserId)
import Domain.ExchangeRate.Events (Provider (..), unProvider)
import Domain.Localization.Country (Country, unCountry, unsafeCountry)
import Domain.Localization.Language (Language, languageCode, parseLanguage)
import Domain.Transaction.Projection (StatusKind, parseStatusKind, renderStatusKind)
import Eventium.Store.Sql.Orphans ()
import Infrastructure.Crypto.SecretBox (EncryptedSecret)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

-- | Store a JSON-serializable value as a text column.
jsonToPersist :: (ToJSON a) => a -> PersistValue
jsonToPersist = PersistText . decodeUtf8Lenient . BL.toStrict . encode

-- | Parse a JSON value back from a text (or bytestring) column.
jsonFromPersist :: (FromJSON a) => PersistValue -> Either Text a
jsonFromPersist v = do
  bs <- case v of
    PersistText t -> Right (encodeUtf8 t)
    PersistByteString b -> Right b
    _ -> Left "jsonFromPersist: expected a text/bytestring JSON column"
  first T.pack (eitherDecodeStrict' bs)

-- | 'ExternalTransactionId' wraps non-empty 'Text'; stored as a text column.
instance PersistField ExternalTransactionId where
  toPersistValue = toPersistValue . unExternalTransactionId
  fromPersistValue v = fromPersistValue v >>= mkExternalTransactionId

instance PersistFieldSql ExternalTransactionId where
  sqlType _ = SqlString

-- | 'TransactionId' wraps a 'UUID'; reuses eventium's @PersistField UUID@.
instance PersistField TransactionId where
  toPersistValue = toPersistValue . unTransactionId
  fromPersistValue v = do
    uuid <- fromPersistValue v
    maybe (Left "Invalid TransactionId UUID") Right (mkTransactionIdSafe uuid)

instance PersistFieldSql TransactionId where
  sqlType _ = sqlType (Proxy :: Proxy UUID)

-- | 'AccountId' wraps a 'UUID'.
instance PersistField AccountId where
  toPersistValue = toPersistValue . unAccountId
  fromPersistValue v = do
    uuid <- fromPersistValue v
    maybe (Left "Invalid AccountId UUID") Right (mkAccountIdSafe uuid)

instance PersistFieldSql AccountId where
  sqlType _ = sqlType (Proxy :: Proxy UUID)

-- | 'UserId' wraps a 'UUID'.
instance PersistField UserId where
  toPersistValue = toPersistValue . unUserId
  fromPersistValue v = do
    uuid <- fromPersistValue v
    maybe (Left "Invalid UserId UUID") Right (mkUserIdSafe uuid)

instance PersistFieldSql UserId where
  sqlType _ = sqlType (Proxy :: Proxy UUID)

-- | 'ConfigurationId' wraps a 'UUID'.
instance PersistField ConfigurationId where
  toPersistValue = toPersistValue . unConfigurationId
  fromPersistValue v = do
    uuid <- fromPersistValue v
    maybe (Left "Invalid ConfigurationId UUID") Right (mkConfigurationIdSafe uuid)

instance PersistFieldSql ConfigurationId where
  sqlType _ = sqlType (Proxy :: Proxy UUID)

-- | 'TelegramId' wraps an 'Int64'; stored as an integer column.
instance PersistField TelegramId where
  toPersistValue (TelegramId i) = toPersistValue i
  fromPersistValue v = TelegramId <$> fromPersistValue v

instance PersistFieldSql TelegramId where
  sqlType _ = sqlType (Proxy :: Proxy Int64)

-- | 'OAuthProvider' is a small closed enum; stored as its JSON token (a valid
-- equality filter for the @getUserByOAuthIdentity@ lookup and the unique key).
instance PersistField OAuthProvider where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql OAuthProvider where
  sqlType _ = SqlString

-- | 'Money' stored exactly as JSON @[amountString, currency]@. The domain's own
-- JSON encodes the amount as a lossy 'Double'; a balance column must round-trip
-- exactly, so we serialize the 'Rational' via 'show'/'readMaybe' instead.
instance PersistField Money where
  toPersistValue m = jsonToPersist (show (unMoney m), moneyCurrency m)
  fromPersistValue v = do
    (s, cur) <- jsonFromPersist v :: Either Text (String, Currency)
    rat <- maybe (Left "Invalid Money amount") Right (readMaybe s)
    mkMoney cur rat

instance PersistFieldSql Money where
  sqlType _ = SqlString

instance PersistField AccountType where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql AccountType where
  sqlType _ = SqlString

instance PersistField AccountSubtypeKind where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql AccountSubtypeKind where
  sqlType _ = SqlString

instance PersistField DefaultSubtypeAccounts where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql DefaultSubtypeAccounts where
  sqlType _ = SqlString

instance PersistField AccountRole where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql AccountRole where
  sqlType _ = SqlString

instance PersistField AccountStatus where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql AccountStatus where
  sqlType _ = SqlString

-- | 'DictionaryEntryId' (also 'LabelId'/'CategoryId') wraps a 'UUID'.
instance PersistField DictionaryEntryId where
  toPersistValue = toPersistValue . unDictionaryEntryId
  fromPersistValue v = do
    uuid <- fromPersistValue v
    mkDictionaryEntryId uuid

instance PersistFieldSql DictionaryEntryId where
  sqlType _ = sqlType (Proxy :: Proxy UUID)

-- | Exact JSON for a 'Money' amount: the 'Rational' is serialized via
-- 'show'/'readMaybe' as a compact @[amountString, currency]@ pair, so amounts
-- stored inside 'ExchangeRate'/'TransactionType' columns round-trip exactly.
-- The domain 'Money' JSON instance is likewise exact (it renders the same
-- 'Rational' via 'show'); this read-model encoding keeps its own compact array
-- shape independent of the domain object shape.
moneyToValue :: Money -> Value
moneyToValue m = toJSON (show (unMoney m), moneyCurrency m)

moneyParser :: Value -> Parser Money
moneyParser v = do
  (s, cur) <- parseJSON v :: Parser (String, Currency)
  r <- maybe (fail "Invalid Money amount") pure (readMaybe s)
  either (fail . T.unpack) pure (mkMoney cur r)

allocToValue :: Allocation -> Value
allocToValue (Allocation cid amt cmt) =
  object ["categoryId" .= cid, "amount" .= moneyToValue amt, "comment" .= cmt]

allocParser :: Value -> Parser Allocation
allocParser = withObject "Allocation" $ \o -> do
  cid <- o .: "categoryId"
  amt <- (o .: "amount") >>= moneyParser
  cmt <- o .:? "comment"
  pure (Allocation cid amt cmt)

allocsToValue :: Allocations -> Value
allocsToValue (Allocations incs exps) =
  object ["incomes" .= map allocToValue incs, "expenses" .= map allocToValue exps]

allocsParser :: Value -> Parser Allocations
allocsParser = withObject "Allocations" $ \o -> do
  incs <- (o .: "incomes") >>= traverse allocParser
  exps <- (o .: "expenses") >>= traverse allocParser
  pure (Allocations incs exps)

transactionTypeToValue :: TransactionType -> Value
transactionTypeToValue Transfer = object ["kind" .= ("transfer" :: Text)]
transactionTypeToValue Adjustment = object ["kind" .= ("adjustment" :: Text)]
transactionTypeToValue (Income a) = object ["kind" .= ("income" :: Text), "allocations" .= allocsToValue a]
transactionTypeToValue (Expense a) = object ["kind" .= ("expense" :: Text), "allocations" .= allocsToValue a]

transactionTypeParser :: Value -> Parser TransactionType
transactionTypeParser = withObject "TransactionType" $ \o -> do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "transfer" -> pure Transfer
    "adjustment" -> pure Adjustment
    "income" -> Income <$> ((o .: "allocations") >>= allocsParser)
    "expense" -> Expense <$> ((o .: "allocations") >>= allocsParser)
    other -> fail ("Unknown TransactionType kind: " <> T.unpack other)

-- | 'ExchangeRate' stored as JSON @[source, target, rateString]@ with the
-- 'Rational' rate shown exactly. The domain JSON instance is likewise exact;
-- this read-model encoding keeps its own compact array shape.
instance PersistField ExchangeRate where
  toPersistValue er = jsonToPersist (exchangeRateSource er, exchangeRateTarget er, show (exchangeRateValue er))
  fromPersistValue v = do
    (s, t, rs) <- jsonFromPersist v :: Either Text (Currency, Currency, String)
    r <- maybe (Left "Invalid ExchangeRate rate") Right (readMaybe rs)
    mkExchangeRate s t r

instance PersistFieldSql ExchangeRate where
  sqlType _ = SqlString

-- | 'TransactionType' stored as JSON — it carries the nested two-bucket
-- allocations, reconstructed for reporting and the in-use deletion guard.
-- Allocation amounts use the exact 'Money' encoding above.
instance PersistField TransactionType where
  toPersistValue = jsonToPersist . transactionTypeToValue
  fromPersistValue v = do
    val <- jsonFromPersist v :: Either Text Value
    first T.pack (parseEither transactionTypeParser val)

instance PersistFieldSql TransactionType where
  sqlType _ = SqlString

-- | 'StatusKind' stored as its lowercase wire token (a queryable enum column for
-- the 'listTransactions' status filter). The 'Failed' reason is stored
-- separately, so only the payload-free 'StatusKind' lands in the column.
instance PersistField StatusKind where
  toPersistValue = PersistText . renderStatusKind
  fromPersistValue v = do
    t <- fromPersistValue v
    maybe (Left ("Invalid StatusKind token: " <> t)) Right (parseStatusKind t)

instance PersistFieldSql StatusKind where
  sqlType _ = SqlString

-- | 'RelationKind' stored as its lowercase wire token (a queryable enum column
-- for the transaction_relations reverse index).
instance PersistField RelationKind where
  toPersistValue = PersistText . renderRelationKind
  fromPersistValue v = do
    t <- fromPersistValue v
    maybe (Left ("Invalid RelationKind token: " <> t)) Right (parseRelationKind t)

instance PersistFieldSql RelationKind where
  sqlType _ = SqlString

-- | 'Currency' is a small closed enum; stored as its JSON token so the
-- @exchange_rates@ read model can filter on the @source@ / @target@ columns.
instance PersistField Currency where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql Currency where
  sqlType _ = SqlString

-- | 'Provider' wraps 'Text' (an exchange-rate provider name); stored as a text
-- column, the @exchange_rates@ read model's per-provider partition key.
instance PersistField Provider where
  toPersistValue = toPersistValue . unProvider
  fromPersistValue v = Provider <$> fromPersistValue v

instance PersistFieldSql Provider where
  sqlType _ = SqlString

-- | 'Country' wraps an alpha-2 'Text' code; stored as the bare code (mirrors
-- 'Provider'). Reads use 'unsafeCountry' — stored values were validated on
-- write, so re-validating against the (possibly-narrowing) supported set on read
-- would be wrong.
instance PersistField Country where
  toPersistValue = toPersistValue . unCountry
  fromPersistValue v = unsafeCountry <$> fromPersistValue v

instance PersistFieldSql Country where
  sqlType _ = SqlString

-- | 'Language' stored as its lowercase code token (mirrors 'StatusKind'), the
-- @configurations.language@ column.
instance PersistField Language where
  toPersistValue = PersistText . languageCode
  fromPersistValue v = fromPersistValue v >>= parseLanguage

instance PersistFieldSql Language where
  sqlType _ = SqlString

-- Configuration read-model column types. The configuration projection is only
-- ever fetched whole by id, so these columns are never filtered on — each is
-- stored as its JSON token for a uniform, lossless round-trip.

-- | 'DictionaryKind' persists as its stable slug text.
instance PersistField DictionaryKind where
  toPersistValue = toPersistValue . dictionaryKindSlug
  fromPersistValue v = do
    t <- fromPersistValue v
    maybe (Left ("Invalid DictionaryKind: " <> t)) Right (parseDictionaryKind t)

instance PersistFieldSql DictionaryKind where
  sqlType _ = SqlString

-- | 'EntryRole' persists as its lowercased role name text.
instance PersistField EntryRole where
  toPersistValue GroupRole = toPersistValue ("group" :: Text)
  toPersistValue ItemRole = toPersistValue ("item" :: Text)
  fromPersistValue v = do
    t <- fromPersistValue v
    case (t :: Text) of
      "group" -> Right GroupRole
      "item" -> Right ItemRole
      other -> Left ("Invalid EntryRole: " <> other)

instance PersistFieldSql EntryRole where
  sqlType _ = SqlString

-- | 'EntryName' wraps 'Text' (a dictionary entry's display name).
instance PersistField EntryName where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql EntryName where
  sqlType _ = SqlString

-- | 'CreatedBy' identifies the configuration's creator.
instance PersistField CreatedBy where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql CreatedBy where
  sqlType _ = SqlString

-- | 'BankConnectionId' wraps a 'UUID'.
instance PersistField BankConnectionId where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql BankConnectionId where
  sqlType _ = SqlString

-- | 'BankProviderId' wraps 'Text' (a provider slug); stored via its bare-string
-- JSON so the column round-trips cleanly.
instance PersistField BankProviderId where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql BankProviderId where
  sqlType _ = SqlString

-- | 'EncryptedSecret' round-trips through its own (base64) JSON encoding.
instance PersistField EncryptedSecret where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql EncryptedSecret where
  sqlType _ = SqlString
