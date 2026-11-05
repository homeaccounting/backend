{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.AccountCatalog
-- Description : Localized display names for account subtype kinds and asset
--               types (an area on the localization foundation).
--
-- The labels the account naming scheme ('Domain.Account.Naming', ADR 009) puts
-- in a full name, keyed by a stable slug (@cash@, @bankAccount@, @property@, …)
-- matching web's @accounts:subtype.*@ and @accounts:assetType.*@ keys. Pure;
-- open key->text shape resolved via 'Domain.Localization.Catalog.resolve'.
--
-- Per-locale names live in JSON under @locales\/accounts\/<locale>\/default.json@
-- (slug -> localized name), embedded at compile time via "Data.Embed", as in
-- 'Domain.Localization.CategoryCatalog'. The English catalog is the fallback for
-- any slug a non-English file omits; an unknown slug returns the slug itself.
-- Completeness is guarded by the naming spec, not the compiler.
module Domain.Localization.AccountCatalog
  ( localizedAccountLabel,
  )
where

import Data.Aeson (eitherDecodeStrict)
import Data.Embed (embedFileBytes)
import qualified Data.Map.Strict as Map
import Domain.Localization.Catalog (resolve)
import Domain.Localization.Language (Language (..))
import RIO

-- | Localized display name for an account subtype kind or asset type, keyed by
-- its slug. Falls back to English, then to the slug.
localizedAccountLabel :: Language -> Text -> Text
localizedAccountLabel = resolve overrides englishBase
  where
    overrides :: Language -> Text -> Maybe Text
    overrides En s = Map.lookup s enNames
    overrides Uk s = Map.lookup s ukNames

    englishBase :: Text -> Text
    englishBase s = fromMaybe s (Map.lookup s enNames)

-- | Labels per locale (slug -> localized name), loaded from
-- @locales\/accounts\/<locale>\/default.json@ at compile time. uk wording matches
-- the web catalog. A decode failure yields an empty map (the spec catches it).
enNames, ukNames :: Map Text Text
enNames = fromRight Map.empty (eitherDecodeStrict $(embedFileBytes "locales/accounts/en/default.json"))
ukNames = fromRight Map.empty (eitherDecodeStrict $(embedFileBytes "locales/accounts/uk/default.json"))
