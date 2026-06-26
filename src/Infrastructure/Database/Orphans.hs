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

import Data.UUID (UUID)
import Database.Persist (PersistField (..))
import Database.Persist.Sql (PersistFieldSql (..), SqlType (SqlString))
import Domain.Core.Types
  ( ExternalTransactionId,
    TransactionId,
    mkExternalTransactionId,
    mkTransactionIdSafe,
    unExternalTransactionId,
    unTransactionId,
  )
import Eventium.Store.Sql.Orphans ()
import RIO

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
