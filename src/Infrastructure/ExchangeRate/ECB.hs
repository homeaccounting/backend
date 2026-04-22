{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.ECB
-- Description : ECB (European Central Bank) exchange rate provider
--
-- Fetches daily exchange rates from the ECB XML feed.
-- All ECB rates are EUR-based; cross-rates are derived for all supported pairs.
module Infrastructure.ExchangeRate.ECB
  ( ecbProvider,
    -- exported for integration tests only
    fetchEcbRates,
  )
where

import Domain.Core.Types (Currency (..), parseCurrency)
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), deriveCrossRates)
import Network.HTTP.Client (httpLbs, newManager, parseRequest, responseBody)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Text.XML (Document, def, parseLBS)
import Text.XML.Cursor (attribute, element, fromDocument, ($//))

-- | ECB exchange rate provider.
ecbProvider :: RateProvider
ecbProvider =
  RateProvider
    { providerName = "ecb",
      fetchRates = fetchEcbRates
    }

-- | Fetch daily rates from ECB XML feed.
fetchEcbRates :: IO (Either Text ExchangeRateMap)
fetchEcbRates = do
  result <- tryAny $ do
    manager <- newManager tlsManagerSettings
    request <- parseRequest ecbUrl
    responseBody <$> httpLbs request manager
  case result of
    Left ex -> pure $ Left $ "ECB: fetch failed: " <> T.pack (show ex)
    Right body ->
      case parseLBS def body of
        Left ex -> pure $ Left $ "ECB: XML parse failed: " <> T.pack (show ex)
        Right doc -> pure $ parseEcbDoc doc
  where
    ecbUrl = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"

-- | Parse ECB XML document into rate map.
parseEcbDoc :: Document -> Either Text ExchangeRateMap
parseEcbDoc doc =
  let cursor = fromDocument doc
      cubes = cursor $// element "{http://www.ecb.int/vocabulary/2002-08-01/eurofxref}Cube"
      eurRates = mapMaybe parseCube cubes
   in if null eurRates
        then Left "ECB: no rates found in response"
        else Right $ deriveCrossRates EUR (Map.fromList eurRates)
  where
    parseCube c = do
      curText <- listToMaybe $ attribute "currency" c
      rateText <- listToMaybe $ attribute "rate" c
      cur <- either (const Nothing) Just $ parseCurrency curText
      (rate :: Double) <- readMaybe (T.unpack rateText)
      guard (rate > 0)
      pure (cur, toRational rate)
