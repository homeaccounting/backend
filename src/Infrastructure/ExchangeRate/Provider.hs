{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.Provider
-- Description : Exchange rate provider abstraction
--
-- Defines the RateProvider record-of-functions and the provider-agnostic
-- rate map utilities. Providers (ECB, NBU) are consumed by
-- 'Application.Services.ExchangeRatePublisher'.
module Infrastructure.ExchangeRate.Provider
  ( -- * Provider Abstraction
    RateProvider (..),

    -- * Rate Map
    ExchangeRateMap,
    getRate,

    -- * Cross-Rate Derivation
    deriveCrossRates,
  )
where

import Domain.Core.Types (Currency, ExchangeRate, mkExchangeRate)
import Domain.ExchangeRate.Events (ExchangeRateMap, Provider)
import RIO
import qualified RIO.Map as Map

-- | Exchange rate provider interface.
--
-- Each provider (ECB, NBU, etc.) exports a value of this type.
-- The cache delegates rate fetching to whichever provider is configured.
data RateProvider = RateProvider
  { -- | Provider identifier (e.g. @"ecb"@, @"nbu"@). Used both for
    -- logging and as the persistence key: the same identifier must
    -- appear in 'Infrastructure.Config.ExchangeRateConfig' so that the
    -- same stream is written and read.
    providerName :: !Provider,
    -- | Fetch current rates from the provider. Uses bare IO because
    -- providers perform real network I/O and the cache operates in IO.
    fetchRates :: IO (Either Text ExchangeRateMap)
  }

-- | Look up a rate for a given currency pair.
getRate :: ExchangeRateMap -> Currency -> Currency -> Maybe ExchangeRate
getRate rates src tgt
  | src == tgt = Nothing
  | otherwise = Map.lookup (src, tgt) rates

-- | Derive full cross-rate matrix from base currency rates.
--
-- Given a base currency and rates relative to it, produces all currency pairs
-- for currencies present in the input map plus the base currency.
-- Does NOT hardcode supported currencies — output is determined by input keys.
deriveCrossRates :: Currency -> Map Currency Rational -> ExchangeRateMap
deriveCrossRates base baseRates =
  let allCurrencies = base : Map.keys baseRates
      pairs = do
        src <- allCurrencies
        tgt <- allCurrencies
        guard (src /= tgt)
        let srcToBase =
              if src == base
                then 1
                else fromMaybe 0 (Map.lookup src baseRates)
        let baseToTgt =
              if tgt == base
                then 1
                else case Map.lookup tgt baseRates of
                  Just r -> 1 / r
                  Nothing -> 0
        let crossRate = srcToBase * baseToTgt
        guard (crossRate > 0)
        case mkExchangeRate src tgt crossRate of
          Right er -> [((src, tgt), er)]
          Left _ -> []
   in Map.fromList pairs
