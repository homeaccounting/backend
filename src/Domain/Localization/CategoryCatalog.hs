{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.CategoryCatalog
-- Description : Localized display names for the default category tree (an area
--               on the localization foundation).
--
-- App-authored reference data: the 'Domain.Configuration.Defaults' default
-- categories, translated per locale. Keyed by each default's stable @slug@ (not
-- its English display name, and never its id), so this never touches ids. Pure;
-- open key->text shape resolved via 'Domain.Localization.Catalog.resolve'.
--
-- Per-locale names live in JSON under @locales\/categories\/<locale>\/default.json@ (slug
-- -> localized name), one file per locale — including @en.json@, so every locale
-- uses the same machinery — mirroring the web app's @src\/locales@ layout, and
-- embedded at compile time via "Data.Embed" so the catalog stays pure (no runtime
-- file access) while remaining translator-friendly. The English catalog (@en.json@)
-- is the fallback for any slug a non-English file omits; an unknown slug returns
-- the slug itself as the last resort. Completeness — every default category having
-- a name in each locale — is guarded by the catalog's spec, not the compiler.
module Domain.Localization.CategoryCatalog
  ( localizedCategoryName,
  )
where

import Data.Aeson (eitherDecodeStrict)
import Data.Embed (embedFileBytes)
import qualified Data.Map.Strict as Map
import Domain.Localization.Catalog (resolve)
import Domain.Localization.Language (Language (..))
import RIO

-- | Localized display name for a default category, keyed by its stable slug.
-- Reads the per-locale JSON catalog; falls back to the English catalog for any
-- slug a non-English locale omits, and to the slug itself for any slug missing
-- everywhere.
localizedCategoryName :: Language -> Text -> Text
localizedCategoryName = resolve overrides englishBase
  where
    overrides :: Language -> Text -> Maybe Text
    overrides En s = Map.lookup s enNames
    overrides Uk s = Map.lookup s ukNames
    englishBase :: Text -> Text
    englishBase s = fromMaybe s (Map.lookup s enNames)

-- | Default category names per locale (slug -> localized name), loaded from
-- @locales\/categories\/<locale>\/default.json@ at compile time. Each file must cover every
-- slug in 'defaultIncomeCategories'/'defaultExpenseCategories' (guarded by
-- 'Domain.Localization.CategoryCatalogSpec'). uk wording is best-effort pending
-- native review. A decode failure yields an empty map (the spec catches it).
enNames, ukNames :: Map Text Text
enNames = fromRight Map.empty (eitherDecodeStrict $(embedFileBytes "locales/categories/en/default.json"))
ukNames = fromRight Map.empty (eitherDecodeStrict $(embedFileBytes "locales/categories/uk/default.json"))
