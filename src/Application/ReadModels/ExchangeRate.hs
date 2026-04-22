{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.ExchangeRate
-- Description : In-memory projection of persisted exchange-rate events.
--
-- Consumes 'ExchangeRatesPublishedEvent' payloads delivered on the
-- global event stream and builds a per-provider, per-day history of
-- published rates. Lookups fall back to the nearest available date
-- (see 'lookupNearestDate' below).
--
-- The business date for a published rate set is carried on the inner
-- 'Eventium.EventMetadata.occurredAt' of the 'VersionedStreamEvent',
-- not on the outer 'GlobalStreamEvent' metadata — destructuring
-- reaches through both layers.
module Application.ReadModels.ExchangeRate
  ( -- * Read Model Types
    ExchangeRateReadModel (..),

    -- * Read Model Creation
    createExchangeRateReadModel,

    -- * Event Handler
    handleExchangeRateEvents,

    -- * Query Functions
    lookupHistoricalRate,

    -- * Internal Helpers (re-exported for property tests)
    lookupNearestDate,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Time (Day, diffDays, utctDay)
import Domain.Core.Types (Currency, ExchangeRate)
import Domain.ExchangeRate.Events (ExchangeRateMap, ExchangeRatesPublished (..), Provider)
import Domain.Models (AccountingEvent (..))
import Eventium (EventMetadata (..), GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import Infrastructure.ExchangeRate.Provider (getRate)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Per-provider, day-indexed history of published exchange rates.
--
-- Outer key is the provider name (matches
-- 'Infrastructure.ExchangeRate.Provider.RateProvider.providerName').
-- Inner key is the business date (from
-- 'EventMetadata.occurredAt'). The value is the full
-- 'ExchangeRateMap' published for that day so subsequent lookups can
-- resolve any currency pair without replaying events.
data ExchangeRateReadModel = ExchangeRateReadModel
  { latestSequence :: SequenceNumber,
    historyByProvider :: !(Map Provider (Map Day ExchangeRateMap))
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty exchange-rate read model.
--
-- Initializes the read model with:
--   - Sequence number -1 (before any events)
--   - Empty per-provider history
createExchangeRateReadModel :: (MonadIO m) => m (TVar ExchangeRateReadModel)
createExchangeRateReadModel =
  liftIO $
    newTVarIO $
      ExchangeRateReadModel
        { latestSequence = -1,
          historyByProvider = Map.empty
        }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Fold 'ExchangeRatesPublishedEvent' events into the read model.
--
-- Behaviour:
--   * Non-matching 'AccountingEvent' variants are silently skipped.
--   * Events without 'occurredAt' on the inner metadata are silently
--     skipped (defensive — writes should always set it).
--   * The highest 'SequenceNumber' seen is tracked.
--   * Update is atomic via the TVar.
handleExchangeRateEvents ::
  (MonadIO m) =>
  TVar ExchangeRateReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleExchangeRateEvents rmTVar events = do
  currentModel <- liftIO $ readTVarIO rmTVar
  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updated = foldl processEvent currentModel.historyByProvider events
  liftIO . atomically . writeTVar rmTVar $
    currentModel
      { latestSequence = newSeq,
        historyByProvider = updated
      }

-- | Project a single global event into the per-provider history.
--
-- 'GlobalStreamEvent' is
-- @StreamEvent () SequenceNumber (VersionedStreamEvent event)@, where
-- @VersionedStreamEvent event = StreamEvent UUID EventVersion event@.
-- The business date lives on the INNER metadata's 'occurredAt'.
processEvent ::
  Map Provider (Map Day ExchangeRateMap) ->
  GlobalStreamEvent AccountingEvent ->
  Map Provider (Map Day ExchangeRateMap)
processEvent acc globalEvent =
  let inner = globalEvent.payload
      innerMeta = inner.metadata
      payload = inner.payload
   in case (payload, innerMeta.occurredAt) of
        (ExchangeRatesPublishedEvent published, Just occurred) ->
          let day = utctDay occurred
              providerKey = published.provider
              providerHistory =
                fromMaybe Map.empty (Map.lookup providerKey acc)
              providerHistory' = Map.insert day published.rates providerHistory
           in Map.insert providerKey providerHistory' acc
        _ -> acc

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Look up a historical rate for a @(source, target)@ currency pair
-- published by @providerName@ on or near @day@.
--
-- When @day@ has no exact match in the provider's history, the query
-- falls back to the nearest known date per 'lookupNearestDate'.
lookupHistoricalRate ::
  (MonadIO m) =>
  TVar ExchangeRateReadModel ->
  Provider ->
  Day ->
  Currency ->
  Currency ->
  m (Maybe ExchangeRate)
lookupHistoricalRate rmTVar providerName day src tgt = do
  model <- liftIO $ readTVarIO rmTVar
  return $ do
    providerHistory <- Map.lookup providerName model.historyByProvider
    (_, rateMap) <- lookupNearestDate providerHistory day
    getRate rateMap src tgt

-- | Find the nearest date in a map. Prefers earlier dates when the two
-- candidates are equidistant.
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
