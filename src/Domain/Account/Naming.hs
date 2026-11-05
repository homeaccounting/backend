{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Account.Naming
-- Description : The universal account naming scheme (ADR 009).
--
-- Full name: @{Kind} › {Qualifier} › {Name} · {Currency}@. Short forms drop the
-- segments the surrounding text already shows. Search matches when every query
-- token is a case- and accent-insensitive substring of the full name.
--
-- Clients implement the same ADR (web @src\/features\/accounts\/accountName.ts@);
-- keep the labels and rules in step with it. Change the ADR first.
module Domain.Account.Naming
  ( AccountNameParts (..),
    ShownByContext (..),
    accountNameParts,
    fullAccountName,
    shortAccountName,
    accountMatches,
    foldForSearch,
  )
where

import qualified Data.Char as Char
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

-- Labels match the web catalog (accounts:subtype.*, accounts:assetType.*).

kindLabel :: Language -> AccountSubtype -> Text
kindLabel = \case
  En -> \case
    Cash _ -> "Cash"
    BankAccount _ -> "Bank account"
    EWallet _ -> "E-wallet"
    Asset _ -> "Asset"
    Loan _ -> "Loan"
  Uk -> \case
    Cash _ -> "Готівка"
    BankAccount _ -> "Банківський рахунок"
    EWallet _ -> "Електронний гаманець"
    Asset _ -> "Актив"
    Loan _ -> "Кредит"

assetTypeLabel :: Language -> AssetType -> Text
assetTypeLabel = \case
  En -> \case
    Property -> "Property"
    Vehicle -> "Vehicle"
    Stocks -> "Stocks"
    RetirementFund -> "Retirement fund"
    Electronics -> "Electronics"
    Equipment -> "Equipment"
    Furniture -> "Furniture"
    OtherAsset t -> t
  Uk -> \case
    Property -> "Нерухомість"
    Vehicle -> "Транспорт"
    Stocks -> "Акції"
    RetirementFund -> "Пенсійний фонд"
    Electronics -> "Електроніка"
    Equipment -> "Обладнання"
    Furniture -> "Меблі"
    OtherAsset t -> t
