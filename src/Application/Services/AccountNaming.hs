{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AccountNaming
-- Description : The universal account naming scheme (ADR 009).
--
-- Full name: @{Kind} › {Qualifier} › {Name} · {Currency}@. Short forms drop the
-- segments the surrounding text already shows. Search matches when every query
-- token is a case- and accent-insensitive substring of the full name.
--
-- Application rather than Domain: a name is a localized display string, not an
-- identity or invariant (no uniqueness, never a key), used by the prompt
-- resolver and Telegram. Kind and asset-type labels live in
-- @locales\/accounts\/<locale>\/labels.json@, mirroring web's
-- @accounts:subtype.*@ and @accounts:assetType.*@, embedded at compile time.
--
-- Clients implement the same ADR (web @src\/features\/accounts\/accountName.ts@);
-- keep the rules in step with it. Change the ADR first.
module Application.Services.AccountNaming
  ( AccountNameParts (..),
    ShownByContext (..),
    accountNameParts,
    fullAccountName,
    shortAccountName,
    accountMatches,
    foldForSearch,
  )
where

import Data.Aeson (eitherDecodeStrict)
import qualified Data.Char as Char
import Data.Embed (embedFileBytes)
import qualified Data.Map.Strict as Map
import qualified Data.Text.Normalize as Normalize
import Domain.Core.Types
  ( AccountSubtype (..),
    AssetProperties (..),
    AssetType (..),
    BankAccountProperties (..),
    CashProperties (..),
    Currency,
    EWalletProperties (..),
    LoanProperties (..),
  )
import Domain.Localization.Catalog (resolve)
import Domain.Localization.Language (Language (..))
import RIO
import qualified RIO.Text as T

data AccountNameParts = AccountNameParts
  { kind :: !Text,
    qualifier :: !(Maybe Text),
    name :: !Text,
    currency :: !Text
  }
  deriving (Show, Eq)

-- | Segments the surrounding text already shows: a bank heading shows the
-- qualifier, an amount next to the name shows the currency.
data ShownByContext = ShownByContext
  { qualifierShown :: !Bool,
    currencyShown :: !Bool
  }
  deriving (Show, Eq)

accountNameParts :: Language -> Text -> Currency -> AccountSubtype -> AccountNameParts
accountNameParts lang nm cur st =
  AccountNameParts
    { kind = kindLabel lang st,
      qualifier = qualifierOf lang st,
      name = nm,
      currency = tshow cur
    }

fullAccountName :: AccountNameParts -> Text
fullAccountName p =
  T.intercalate " \x203A " (catMaybes [Just p.kind, p.qualifier, Just p.name])
    <> " \xB7 "
    <> p.currency

shortAccountName :: ShownByContext -> AccountNameParts -> Text
shortAccountName shown p =
  T.intercalate " \xB7 " $
    [p.name]
      <> [q | not shown.qualifierShown, Just q <- [p.qualifier]]
      <> [p.currency | not shown.currencyShown]

-- | Whether every whitespace-separated token of the query appears in the full
-- name, so "privat usd" finds the PrivatBank USD card. A blank query matches.
accountMatches :: Text -> AccountNameParts -> Bool
accountMatches query p = all (`T.isInfixOf` haystack) (T.words (foldForSearch query))
  where
    haystack = foldForSearch (fullAccountName p)

-- | Case- and accent-insensitive form for comparison: decompose, drop the
-- combining marks, casefold.
foldForSearch :: Text -> Text
foldForSearch = T.toCaseFold . T.filter (not . isMark) . Normalize.normalize Normalize.NFD
  where
    isMark c = case Char.generalCategory c of
      Char.NonSpacingMark -> True
      Char.SpacingCombiningMark -> True
      Char.EnclosingMark -> True
      _ -> False

-- | The field that tells the user which account a name refers to; blank means
-- none. An asset shows its type's label.
qualifierOf :: Language -> AccountSubtype -> Maybe Text
qualifierOf lang = \case
  Cash p -> nonBlank p.storageLocation
  BankAccount p -> nonBlank p.bankName
  EWallet p -> nonBlank p.provider
  Asset p -> p.assetType >>= nonBlank . Just . assetTypeLabel lang
  Loan p -> nonBlank p.lender
  where
    nonBlank = mfilter (not . T.null) . fmap T.strip

kindLabel :: Language -> AccountSubtype -> Text
kindLabel lang =
  label lang "subtype" . \case
    Cash _ -> "cash"
    BankAccount _ -> "bankAccount"
    EWallet _ -> "eWallet"
    Asset _ -> "asset"
    Loan _ -> "loan"

-- | A freeform asset type has no label and shows as typed.
assetTypeLabel :: Language -> AssetType -> Text
assetTypeLabel lang = \case
  Property -> known "property"
  Vehicle -> known "vehicle"
  Stocks -> known "stocks"
  RetirementFund -> known "retirementFund"
  Electronics -> known "electronics"
  Equipment -> known "equipment"
  Furniture -> known "furniture"
  OtherAsset t -> t
  where
    known = label lang "assetType"

-- | A label from the locale's catalog, falling back to English, then the key.
label :: Language -> Text -> Text -> Text
label lang section = resolve overrides base lang
  where
    lookupIn labels k = Map.lookup section labels >>= Map.lookup k
    overrides En = lookupIn enLabels
    overrides Uk = lookupIn ukLabels
    base k = fromMaybe k (lookupIn enLabels k)

-- | Section ("subtype", "assetType") -> key -> label. A decode failure yields an
-- empty catalog, which the spec catches.
enLabels, ukLabels :: Map Text (Map Text Text)
enLabels = fromRight Map.empty (eitherDecodeStrict $(embedFileBytes "locales/accounts/en/labels.json"))
ukLabels = fromRight Map.empty (eitherDecodeStrict $(embedFileBytes "locales/accounts/uk/labels.json"))
