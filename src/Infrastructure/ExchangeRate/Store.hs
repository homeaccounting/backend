{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.Store
-- Description : Event-sourced exchange rate store with nearest-date lookup
--
-- Provides historical exchange rate storage backed by events. Rates are
-- indexed by day, and lookups fall back to the nearest available date
-- when no exact match exists. The store is populated by replaying
-- 'ExchangeRateEvent' values and by publishing fresh rates from the
-- configured 'RateProvider'.
module Infrastructure.ExchangeRate.Store
  ( -- * Events
    ExchangeRateEvent (..),

    -- * History
    ExchangeRateHistory,

    -- * Store
    ExchangeRateStore (..),
    newExchangeRateStore,

    -- * Queries
    lookupHistoricalRate,
    lookupNearestDate,

    -- * Commands
    publishRates,
    replayRateEvents,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (Day, diffDays, getCurrentTime, utctDay)
import Domain.Core.Types (Currency, ExchangeRate)
import GHC.Generics (Generic)
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), getRate)
import RIO
import qualified RIO.Map as Map

-- | Exchange rate events for event sourcing.
data ExchangeRateEvent
  = ExchangeRatesPublished
  { date :: !Day,
    provider :: !Text,
    rates :: !ExchangeRateMap
  }
  deriving (Show, Eq, Generic)

instance ToJSON ExchangeRateEvent

instance FromJSON ExchangeRateEvent

-- | Historical exchange rates indexed by day.
type ExchangeRateHistory = Map Day ExchangeRateMap

-- | Event-sourced exchange rate store.
data ExchangeRateStore = ExchangeRateStore
  { historyRef :: !(IORef ExchangeRateHistory),
    rateProvider :: !RateProvider
  }

-- | Create a new empty store backed by the given provider.
newExchangeRateStore :: RateProvider -> IO ExchangeRateStore
newExchangeRateStore prov =
  ExchangeRateStore <$> newIORef Map.empty <*> pure prov

-- | Replay events to populate the store.
replayRateEvents :: ExchangeRateStore -> [ExchangeRateEvent] -> IO ()
replayRateEvents store events =
  modifyIORef' store.historyRef $ \history ->
    foldl' applyEvent history events
  where
    applyEvent h (ExchangeRatesPublished d _ r) = Map.insert d r h

-- | Look up a rate for a given date, using nearest-date fallback.
lookupHistoricalRate ::
  ExchangeRateStore ->
  Day ->
  Currency ->
  Currency ->
  IO (Maybe ExchangeRate)
lookupHistoricalRate store day src tgt = do
  history <- readIORef store.historyRef
  pure $ do
    (_, rateMap) <- lookupNearestDate history day
    getRate rateMap src tgt

-- | Find the nearest date in a map. Prefers earlier dates when equidistant.
lookupNearestDate :: Map Day v -> Day -> Maybe (Day, v)
lookupNearestDate m target
  | Map.null m = Nothing
  | otherwise =
      let before = Map.lookupLE target m
          after = Map.lookupGE target m
       in case (before, after) of
            (Just (bDay, bVal), Just (aDay, aVal))
              | diffDays target bDay <= diffDays aDay target -> Just (bDay, bVal)
              | otherwise -> Just (aDay, aVal)
            (Just bv, Nothing) -> Just bv
            (Nothing, Just av) -> Just av
            (Nothing, Nothing) -> Nothing

-- | Publish today's rates if not already present.
-- TODO: persist the returned ExchangeRatesPublished event to the event store
-- so historical rates can be replayed on startup via replayRateEvents
publishRates :: ExchangeRateStore -> IO (Either Text ExchangeRateEvent)
publishRates store = do
  today <- utctDay <$> getCurrentTime
  history <- readIORef store.historyRef
  case Map.lookup today history of
    Just _ -> pure $ Left "Rates already published for today"
    Nothing -> do
      result <- store.rateProvider.fetchRates
      case result of
        Left err -> pure $ Left err
        Right rates -> do
          let event =
                ExchangeRatesPublished
                  today
                  store.rateProvider.providerName
                  rates
          modifyIORef' store.historyRef (Map.insert today rates)
          pure $ Right event
