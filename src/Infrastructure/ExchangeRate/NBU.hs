{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.NBU
-- Description : NBU (National Bank of Ukraine) exchange rate provider
--
-- Fetches daily exchange rates from the NBU JSON API.
-- All NBU rates are UAH-based; cross-rates are derived for all supported pairs.
module Infrastructure.ExchangeRate.NBU
  ( nbuProvider,
    -- exported for unit tests
    parseNbuResponse,
  )
where

import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Domain.Core.Types (Currency (..), parseCurrency)
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), deriveCrossRates)
import Network.HTTP.Client (httpLbs, newManager, parseRequest, responseBody)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T

-- | NBU exchange rate provider.
nbuProvider :: RateProvider
nbuProvider =
  RateProvider
    { providerName = "nbu",
      fetchRates = fetchNbuRates
    }

-- | Raw NBU rate entry from JSON response.
data NbuRateEntry = NbuRateEntry
  { cc :: !Text,
    rate :: !Double
  }

instance FromJSON NbuRateEntry where
  parseJSON = withObject "NbuRateEntry" $ \v ->
    NbuRateEntry
      <$> v
      .: "cc"
      <*> v
      .: "rate"

-- | Fetch daily rates from NBU JSON API.
fetchNbuRates :: IO (Either Text ExchangeRateMap)
fetchNbuRates = do
  result <- tryAny $ do
    manager <- newManager tlsManagerSettings
    request <- parseRequest nbuUrl
    responseBody <$> httpLbs request manager
  case result of
    Left ex -> pure $ Left $ "NBU: fetch failed: " <> T.pack (show ex)
    Right body -> pure $ parseNbuResponse body
  where
    nbuUrl = "https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json"

-- | Parse NBU JSON response into rate map.
--
-- Exposed for unit testing with sample payloads.
parseNbuResponse :: LByteString -> Either Text ExchangeRateMap
parseNbuResponse body =
  case eitherDecode body :: Either String [NbuRateEntry] of
    Left err -> Left $ "NBU: JSON parse failed: " <> T.pack err
    Right entries ->
      let uahRates = mapMaybe toRatePair entries
       in if null uahRates
            then Left "NBU: no supported rates found in response"
            else Right $ deriveCrossRates UAH (Map.fromList uahRates)
  where
    toRatePair :: NbuRateEntry -> Maybe (Currency, Rational)
    toRatePair entry = do
      cur <- either (const Nothing) Just $ parseCurrency entry.cc
      guard (entry.rate > 0)
      guard (cur /= UAH) -- NBU rates are relative to UAH, skip UAH itself
      pure (cur, toRational entry.rate)
