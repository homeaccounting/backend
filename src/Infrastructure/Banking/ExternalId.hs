{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.ExternalId
-- Description : The synthesized bank-import external-id format
--
-- Most providers hand us a bank-issued transaction identifier (Monobank's API
-- @id@, the PrivatBank business export's @Референс@). The PrivatBank __retail__
-- export has no reference column, so its id is /synthesized/ from row data.
--
-- That synthesized id is an __idempotency key__: bank-import dedup keys on it
-- (@imported_transactions@), so its derivation is a stored-data contract, not
-- an implementation detail of the parser. This module is its single owner —
-- construction and legacy repair live side by side so they cannot drift — and
-- 'Infrastructure.Banking.ExternalIdSpec' pins the exact output. See
-- @docs/decisions/004-synthesized-external-ids-are-pinned-idempotency-keys.md@.
--
-- It lives here rather than inside the PrivatBank provider because the dedup
-- projection must interpret historical PrivatBank ids regardless of whether
-- that provider is enabled in @banking.providers@ — a disabled provider stops
-- new imports, it does not erase the ids already in the log.
module Infrastructure.Banking.ExternalId
  ( privatBankRetailPrefix,
    privatBankRetailExternalId,
    normalizePrivatBankRetailId,
  )
where

import qualified Data.Text as T
import Domain.Banking.Import
  ( ExternalTransactionId,
    unExternalTransactionId,
    unsafeExternalTransactionId,
  )
import Infrastructure.Banking.Statement (canonicalDecimal)
import RIO

-- | Tag identifying a PrivatBank retail synthesized id. Also the marker
-- 'normalizePrivatBankRetailId' matches on, so that other providers' ids are
-- never rewritten.
privatBankRetailPrefix :: Text
privatBankRetailPrefix = "privatbank:"

-- | The PrivatBank retail key: the row's date verbatim, plus its card-currency
-- amount and running balance in canonical decimal form. The running balance
-- makes each row unique when date+amount repeat (two identical top-ups);
-- canonicalising by exact value rather than textual spelling makes the id
-- format-independent, so a statement imported as CSV (@"510"@) or XLSX
-- (@"510.0"@) yields one id and dedups identically.
--
-- Arguments are raw statement text, in column order: date, amount, balance.
privatBankRetailExternalId :: Text -> Text -> Text -> Text
privatBankRetailExternalId date amount balance =
  privatBankRetailPrefix
    <> date
    <> ":"
    <> canonicalDecimal amount
    <> ":"
    <> canonicalDecimal balance

-- | Normalize a stored PrivatBank retail id to the current derivation, for ids
-- written before the amount/balance fields were canonicalised (commit
-- @38968e9@, 2026-08-17). Re-canonicalises the trailing two colon-fields after
-- stripping whitespace from the numeric fields.
--
-- Total, and safe to apply to anything: the identity for ids without the retail
-- prefix (Monobank ids, business references) and for a prefixed id whose shape
-- does not parse. Idempotent for any stored legacy key, including ones with
-- whitespace-padded fields (which can occur when the parser interpolated raw
-- statement data without stripping), because the repair strips and then
-- canonicalises.
--
-- 'unsafeExternalTransactionId' is justified here: the output always carries at
-- least the non-empty prefix, so it can never be the empty string that
-- 'mkExternalTransactionId' rejects.
normalizePrivatBankRetailId :: ExternalTransactionId -> ExternalTransactionId
normalizePrivatBankRetailId extId =
  case T.stripPrefix privatBankRetailPrefix (unExternalTransactionId extId) of
    Nothing -> extId
    Just rest -> case splitTrailingTwo rest of
      Nothing -> extId
      Just (date, amount, balance) ->
        unsafeExternalTransactionId (privatBankRetailExternalId date (T.strip amount) (T.strip balance))

-- | Split @\"\<date\>:\<amount\>:\<balance\>\"@ into its three parts, taking the
-- last two colon-separated fields from the right so that the colons inside the
-- date (@\"06.08.2026 11:09:20\"@) stay in the date. 'Nothing' when there are
-- fewer than two colons to split on.
splitTrailingTwo :: Text -> Maybe (Text, Text, Text)
splitTrailingTwo t = do
  (beforeBalance, balance) <- breakOnLastColon t
  (date, amount) <- breakOnLastColon beforeBalance
  pure (date, amount, balance)

-- | Split on the LAST colon: @\"a:b:c\"@ becomes @Just (\"a:b\", \"c\")@.
-- 'Nothing' when the text has no colon.
breakOnLastColon :: Text -> Maybe (Text, Text)
breakOnLastColon t =
  case T.breakOnEnd ":" t of
    (before, after)
      | T.null before -> Nothing
      | otherwise -> Just (T.dropEnd 1 before, after)
