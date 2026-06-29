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

import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import Data.Bifunctor (first)
import Data.UUID (UUID)
import Database.Persist (PersistField (..), PersistValue (..))
import Database.Persist.Sql (PersistFieldSql (..), SqlType (SqlString))
import Domain.Core.Types
  ( AccountId,
    AccountRole,
    AccountStatus,
    AccountType,
    Currency,
    ExternalTransactionId,
    Money,
    TransactionId,
    UserId,
    mkAccountIdSafe,
    mkExternalTransactionId,
    mkMoney,
    mkTransactionIdSafe,
    mkUserIdSafe,
    moneyCurrency,
    unAccountId,
    unExternalTransactionId,
    unMoney,
    unTransactionId,
    unUserId,
  )
import Eventium.Store.Sql.Orphans ()
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
