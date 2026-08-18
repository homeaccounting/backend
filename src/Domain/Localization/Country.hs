{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Country
-- Description : User country signal (ISO 3166-1 alpha-2, launch-scoped set).
--
-- A shared 'Domain.Localization' value type. Validated over ISO 3166-1 alpha-2,
-- but the /supported set/ for launch is exactly the countries the 3 presets
-- cover (US, UA, euro-area) — we do not build the full ~249-entry ISO table yet.
-- No LiquidHaskell refinement, matching the 'Currency'/'EntryName' precedent;
-- validation is in the smart constructor + tests.
module Domain.Localization.Country
  ( Country,
    unCountry,
    mkCountry,
    unsafeCountry,
    supportedCountries,
    euroAreaCountries,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Char (isAsciiUpper)
import qualified Data.Set as Set
import qualified Data.Text as T
import RIO

-- | An ISO 3166-1 alpha-2 country code from the supported set. Constructor is
-- not exported; use 'mkCountry' (validating) or 'unsafeCountry' (trusted).
newtype Country = Country {unCountry :: Text}
  deriving (Show, Eq, Ord, Generic)

-- | Extract the alpha-2 code. (Standalone accessor; the field selector is
-- suppressed by the project-wide @NoFieldSelectors@, mirroring 'EntryName'.)
unCountry :: Country -> Text
unCountry (Country t) = t

-- | Euro-area member states (currency preset EUR). Extended as coverage grows.
euroAreaCountries :: Set Text
euroAreaCountries =
  Set.fromList
    ["AT", "BE", "HR", "CY", "EE", "FI", "FR", "DE", "GR", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PT", "SK", "SI", "ES"]

-- | The launch supported/selectable set: US + UA + euro-area. This is also the
-- set the picker renders and 'localization-options' returns.
supportedCountries :: Set Text
supportedCountries = Set.insert "US" (Set.insert "UA" euroAreaCountries)

-- | Smart constructor: well-formed alpha-2 AND in the supported set. Returns
-- 'Either Text' to match 'parseCurrency' and plug into 'validateFieldCtx'.
mkCountry :: Text -> Either Text Country
mkCountry raw
  | not wellFormed = Left ("Malformed country code: " <> raw)
  | not (code `Set.member` supportedCountries) = Left ("Unsupported country: " <> code)
  | otherwise = Right (Country code)
  where
    code = T.toUpper (T.strip raw)
    wellFormed = T.length code == 2 && T.all isAsciiUpper code

-- | Reconstruct without validation. For trusted sources only (DB reads):
-- values were validated on write. Mirrors 'unsafeEntryName'.
unsafeCountry :: Text -> Country
unsafeCountry = Country

instance ToJSON Country where
  toJSON = toJSON . unCountry

-- | Lenient decode (trusted stored form), mirroring 'EntryName' — API input is
-- validated via 'mkCountry' at the boundary, not here.
instance FromJSON Country where
  parseJSON v = Country <$> parseJSON v
