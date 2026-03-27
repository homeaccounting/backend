{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.Provider
-- Description : Exchange rate provider abstraction and cache
--
-- Defines the RateProvider record-of-functions and the provider-agnostic
-- ExchangeRateCache. Providers (ECB, NBU) plug into the cache via RateProvider.
-- Cache refreshes daily on first request after UTC midnight.
module Infrastructure.ExchangeRate.Provider
  ( -- * Provider Abstraction
    RateProvider (..),

    -- * Rate Map
    ExchangeRateMap,
    getRate,

    -- * Cross-Rate Derivation
    deriveCrossRates,

    -- * Cache
    ExchangeRateCache,
    newExchangeRateCache,
    getCachedRate,
    refreshCache,
  )
where

import Data.Time (UTCTime, getCurrentTime, utctDay)
import Domain.Core.Types (Currency, ExchangeRate, mkExchangeRate)
import RIO
import qualified RIO.Map as Map

-- | Exchange rate provider interface.
--
-- Each provider (ECB, NBU, etc.) exports a value of this type.
-- The cache delegates rate fetching to whichever provider is configured.
data RateProvider = RateProvider
  { -- | Human-readable provider name (for error messages)
    providerName :: !Text,
    -- | Fetch current rates from the provider. Uses bare IO because
    -- providers perform real network I/O and the cache operates in IO.
    fetchRates :: IO (Either Text ExchangeRateMap)
  }

-- | Map of (source, target) -> ExchangeRate
type ExchangeRateMap = Map (Currency, Currency) ExchangeRate

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

-- | Exchange rate cache with daily refresh.
--
-- Opaque type — use 'newExchangeRateCache', 'getCachedRate', 'refreshCache'.
data ExchangeRateCache = ExchangeRateCache
  { provider :: !RateProvider,
    cacheRef :: !(IORef (Maybe (UTCTime, ExchangeRateMap)))
  }

-- | Create a new empty cache backed by the given provider.
newExchangeRateCache :: RateProvider -> IO ExchangeRateCache
newExchangeRateCache prov = ExchangeRateCache prov <$> newIORef Nothing

-- | Refresh the cache by fetching from the configured provider.
refreshCache :: ExchangeRateCache -> IO (Either Text ())
refreshCache cache = do
  result <- cache.provider.fetchRates
  case result of
    Left err -> pure (Left err)
    Right rates -> do
      now <- getCurrentTime
      writeIORef cache.cacheRef (Just (now, rates))
      pure (Right ())

-- | Get a cached rate. Refreshes if cache is from a previous day (UTC).
getCachedRate :: ExchangeRateCache -> Currency -> Currency -> IO (Either Text ExchangeRate)
getCachedRate cache src tgt
  | src == tgt = pure $ Left "Same currency, no conversion needed"
  | otherwise = do
      cached <- readIORef cache.cacheRef
      now <- getCurrentTime
      let needsRefresh = case cached of
            Nothing -> True
            Just (fetchTime, _) -> utctDay fetchTime /= utctDay now
      when needsRefresh $ void $ refreshCache cache
      cached' <- readIORef cache.cacheRef
      case cached' of
        Nothing -> pure $ Left $ cache.provider.providerName <> ": exchange rates unavailable"
        Just (_, rates) ->
          case getRate rates src tgt of
            Just er -> pure (Right er)
            Nothing ->
              pure
                $ Left
                $ cache.provider.providerName
                <> ": no rate for "
                <> tshow src
                <> " -> "
                <> tshow tgt
