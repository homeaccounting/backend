{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Catalog
-- Description : Pure, area-agnostic localization primitive.
--
-- The single reusable rule every open (key->text) localization area shares:
-- resolve a key in the target language, falling back to a total English base
-- that can never fail. Closed record-per-language catalogs (e.g. 'Telegram.I18n')
-- do not need this — the record is total per locale — but this keeps the
-- fallback logic in one place for data-driven areas (e.g.
-- 'Domain.Localization.CategoryCatalog'). Pure: no IO, no resource loading.
module Domain.Localization.Catalog
  ( resolve,
  )
where

import Domain.Localization.Language (Language)
import RIO

-- | Resolve a key with English fallback.
--
-- @resolve overrides base lang k@ tries the per-locale @overrides@ table; on a
-- miss it uses the total English @base@. English needs no override entry — the
-- base is the English text by construction.
resolve ::
  (Language -> k -> Maybe Text) ->
  (k -> Text) ->
  Language ->
  k ->
  Text
resolve overrides base lang k = fromMaybe (base k) (overrides lang k)
