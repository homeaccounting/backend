{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Preset
-- Description : Country -> regional defaults (US / EU / UA profiles).
--
-- Pure country->defaults table. Three launch profiles; 'EU' is a profile the
-- euro-area codes all map to (each user's stored country stays their real ISO
-- code). 'presetFor' is total; the fallback (En, no currency) is only reachable
-- if the supported set is later widened ahead of this table.
module Domain.Localization.Preset
  ( CountryPreset (..),
    presetFor,
  )
where

import qualified Data.Set as Set
import Domain.Core.Types (Currency (..))
import Domain.Localization.Country (Country, euroAreaCountries, unCountry)
import Domain.Localization.Language (Language (..))
import RIO

-- | Regional defaults applied on country selection. Currencies are 'Maybe' so
-- an uncovered country can leave them untouched.
data CountryPreset = CountryPreset
  { language :: Language,
    baseCurrency :: Maybe Currency,
    defaultCurrency :: Maybe Currency
  }
  deriving (Show, Eq, Generic)

-- | Resolve the preset for a country.
presetFor :: Country -> CountryPreset
presetFor c = case unCountry c of
  "US" -> CountryPreset En (Just USD) (Just USD)
  "UA" -> CountryPreset Uk (Just UAH) (Just UAH)
  code
    | code `Set.member` euroAreaCountries -> CountryPreset En (Just EUR) (Just EUR)
    | otherwise -> CountryPreset En Nothing Nothing
