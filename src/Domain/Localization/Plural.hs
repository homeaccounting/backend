{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Plural
-- Description : CLDR plural-category selection for pluralized catalog strings.
--
-- A pure, dependency-free plural helper for the localization foundation. Grammar
-- for count-bearing messages differs by locale — English has two forms
-- (@one@/@other@), Ukrainian has three for integers (@one@/@few@/@many@) — so a
-- flat @{count}@ substitution is grammatically wrong for @uk@ once a noun follows
-- the count. This picks the CLDR plural /category/ for a count, and resolves the
-- matching template from a catalog map using the same @<key>_<category>@ suffix
-- convention the web's i18next uses (so the JSON files mirror the web).
--
-- Usage: author @foo_one@ / @foo_few@ / @foo_many@ / @foo_other@ keys in the
-- locale JSON, then @selectPluralTemplate lang n nsMap "foo"@ returns the right
-- template to interpolate. Falls back to @foo_other@, then the bare @foo@.
module Domain.Localization.Plural
  ( PluralCategory (..),
    pluralCategory,
    pluralSuffix,
    selectPluralTemplate,
  )
where

import Domain.Localization.Language (Language (..))
import RIO
import qualified RIO.Map as Map

-- | The CLDR plural categories reachable for the supported locales' integer
-- counts. English uses 'One'/'Other'; Ukrainian uses 'One'/'Few'/'Many'.
-- ('Other' is CLDR's fractional category — unreachable for the 'Int' counts we
-- pluralize on, but kept so it can be the explicit fallback key.)
data PluralCategory = One | Few | Many | Other
  deriving (Show, Eq, Enum, Bounded)

-- | The CLDR plural category for an integer count in @lang@.
--
-- English: @one@ iff the count is 1. Ukrainian (CLDR integer rules):
--
--   * @one@  — count mod 10 == 1 and count mod 100 /= 11
--   * @few@  — count mod 10 in 2..4 and count mod 100 not in 12..14
--   * @many@ — otherwise (mod 10 in {0,5..9} or mod 100 in 11..14)
pluralCategory :: Language -> Int -> PluralCategory
pluralCategory En n = if n == 1 then One else Other
pluralCategory Uk n
  | m10 == 1 && m100 /= 11 = One
  | m10 >= 2 && m10 <= 4 && not (m100 >= 12 && m100 <= 14) = Few
  | otherwise = Many
  where
    a = abs n
    m10 = a `mod` 10
    m100 = a `mod` 100

-- | The i18next-style key suffix for a category (@one@/@few@/@many@/@other@).
pluralSuffix :: PluralCategory -> Text
pluralSuffix One = "one"
pluralSuffix Few = "few"
pluralSuffix Many = "many"
pluralSuffix Other = "other"

-- | Resolve the plural template for @count@ from a catalog namespace map, using
-- @\<key\>_\<category\>@ keys. Falls back to @\<key\>_other@, then the bare
-- @\<key\>@ (so a not-yet-pluralized string still resolves). 'Nothing' if none
-- of those keys exist.
selectPluralTemplate :: Language -> Int -> Map Text Text -> Text -> Maybe Text
selectPluralTemplate lang count m key =
  keyed (pluralSuffix (pluralCategory lang count))
    <|> keyed "other"
    <|> Map.lookup key m
  where
    keyed suffix = Map.lookup (key <> "_" <> suffix) m
