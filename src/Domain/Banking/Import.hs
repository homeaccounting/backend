{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Banking.Import
-- Description : Import provenance for the banking subdomain
--
-- Shared value types carrying the provenance of an imported transaction: the
-- external-system identifier ('ExternalTransactionId') and the import envelope
-- ('ImportInfo', which bundles the external ids with the optional provider
-- category/contact signals from "Domain.Banking.Signal").
--
-- There is __no Banking aggregate__: banking has no lifecycle of its own.
-- Import provenance rides on 'Domain.Transaction' events (threaded as
-- @Maybe ImportInfo@), and the category/contact maps these signals key are
-- 'Domain.Configuration' events. These are shared value types used across
-- aggregates, so they live in a dedicated value-type namespace (the same shape
-- as "Domain.Core.Types") rather than in an aggregate module.
module Domain.Banking.Import
  ( -- * External Transaction Identifier
    ExternalTransactionId,
    mkExternalTransactionId,
    unsafeExternalTransactionId,
    unExternalTransactionId,

    -- * Import provenance
    ImportInfo (..),
    importInfoExternalTransactionIds,
    importInfoCategory,
    importInfoContact,

    -- * Import attribution
    importAttributionCapacity,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as T
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact)
import Domain.Core.Types (TransactionType (..))
import GHC.Generics (Generic)
import RIO (Display (..))

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
-- Import provenance
-- -----------------------------------------------------------------------------

-- | Provenance for an imported transaction, threaded through
-- 'Domain.Transaction.Commands.InitiateTransactionPosting' and
-- 'Domain.Transaction.Events.TransactionPostingInitiated' as
-- @Maybe ImportInfo@: 'Nothing' is a manual entry, 'Just' is an import.
--
-- 'externalTransactionIds' carries one or more external ids: a normal import
-- carries one, a detected internal transfer carries both legs' ids (so both can
-- be deduplicated). It is required (every import has at least one; it drives the
-- overdraft-bypass guard and import dedup), while 'category' and 'contact' are
-- optional because only some providers supply a provider category (monobank
-- supplies an MCC; PrivatBank supplies a text label) or a counterparty signal.
-- Grouping the import-only fields keeps future provider metadata in one place.
-- Mirrors 'RelationSpec' in shape and role.
data ImportInfo = ImportInfo
  { externalTransactionIds :: NonEmpty ExternalTransactionId,
    category :: Maybe BankProviderCategory,
    contact :: Maybe BankProviderContact
  }
  deriving (Show, Eq, Generic)

instance ToJSON ImportInfo

instance FromJSON ImportInfo

-- | The external identifiers carried by an import (one or more). Accessor
-- function provided for API consistency with 'importInfoCategory', whose shared
-- @category@ field name is ambiguous under @DuplicateRecordFields@ at call sites
-- that also see other records with that field name.
importInfoExternalTransactionIds :: ImportInfo -> NonEmpty ExternalTransactionId
importInfoExternalTransactionIds ImportInfo {externalTransactionIds = e} = e

-- | The provider category carried by an import, if the provider supplied one.
importInfoCategory :: ImportInfo -> Maybe BankProviderCategory
importInfoCategory ImportInfo {category = c} = c

-- | The provider contact signal carried by an import, if the provider supplied one.
importInfoContact :: ImportInfo -> Maybe BankProviderContact
importInfoContact ImportInfo {contact = c} = c

-- -----------------------------------------------------------------------------
-- Import attribution
-- -----------------------------------------------------------------------------

-- | How many external transaction ids import reconciliation may attribute to a
-- transaction of this type. A 'Transfer' spans two accounts, so it absorbs one
-- leg per side; every other type is a single movement carrying one id.
--
-- This is the single home for the limit: the transaction aggregate's reconcile
-- guard and the bank-import candidate filter both read it, so the write model
-- and the import path cannot drift apart on how many legs may attach.
--
-- Enumerated constructor by constructor (like 'kindOf') rather than via a
-- catch-all, so that adding a 'TransactionType' is a compile error here instead
-- of silently inheriting a capacity of one.
importAttributionCapacity :: TransactionType -> Int
importAttributionCapacity Transfer = 2
importAttributionCapacity (Income _) = 1
importAttributionCapacity (Expense _) = 1
importAttributionCapacity Adjustment = 1
