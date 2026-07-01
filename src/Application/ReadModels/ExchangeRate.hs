{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Application.ReadModels.ExchangeRate
-- Description : Persistent, indexed projection of published exchange rates.
--
-- Published rates are projected into a single Postgres table, one row per
-- @(provider, day, source, target)@ currency pair:
--
--   * @exchange_rates@ — the exact rate for a pair on a given business day,
--     partitioned by provider.
--
-- The @(provider, day, source, target)@ unique index backs both the
-- historical lookup and the publisher's per-day idempotency check, replacing
-- the in-memory @Map Provider (Map Day ExchangeRateMap)@. The projection is an
-- eventium 'ReadModel' ('exchangeRateReadModel') driven synchronously in the
-- event-append transaction.
--
-- The business date for a published rate set is the payload field
-- 'ExchangeRatesPublished.at'. Lookups fall back to the nearest available date
-- (see 'lookupNearestDate').
module Application.ReadModels.ExchangeRate
  ( -- * Read model
    exchangeRateReadModel,
    exchangeRateProjectionName,
    migrateExchangeRate,
    resetExchangeRate,
    applyExchangeRateEvent,
    ExchangeRateEntity (..),

    -- * Query Functions (run via 'runDb')
    lookupHistoricalRate,
    ratesPublishedOn,

    -- * Internal Helpers (re-exported for property tests)
    lookupNearestDate,
  )
where

import Control.Monad (forM_, void)
import Control.Monad.IO.Class (MonadIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Time (Day, diffDays)
import Database.Persist
  ( Entity (..),
    Filter,
    deleteWhere,
    insert_,
    selectFirst,
    selectList,
    (==.),
  )
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Core.Types (Currency, ExchangeRate)
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..), Provider)
import Domain.Models (AccountingEvent (..))
import Eventium
  ( EventHandler (..),
    GlobalStreamEvent,
    ReadModel (..),
    StreamEvent (..),
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import Infrastructure.Database.Orphans ()

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateExchangeRate"]
  [persistLowerCase|
ExchangeRateEntity sql=exchange_rates
    provider Provider
    day Day
    source Currency
    target Currency
    rate ExchangeRate
    -- One row per currency pair published by a provider on a business day.
    -- The unique key backs the historical lookup and per-day idempotency.
    UniqueExchangeRatePair provider day source target
    deriving Show Eq
|]

-- | Projection/checkpoint name for this read model.
exchangeRateProjectionName :: CheckpointName
exchangeRateProjectionName = CheckpointName "exchange_rate"

-- | Clear the exchange-rate table. The checkpoint is reset by 'rebuildReadModel'.
resetExchangeRate :: (MonadIO m) => SqlPersistT m ()
resetExchangeRate = deleteWhere ([] :: [Filter ExchangeRateEntity])

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

exchangeRateReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
exchangeRateReadModel =
  ReadModel
    { initialize = void (runMigrationSilent migrateExchangeRate),
      eventHandler = EventHandler applyExchangeRateEvent,
      checkpointStore = postgresqlCheckpointStore exchangeRateProjectionName,
      reset = resetExchangeRate
    }

-- | Apply a single global event to the @exchange_rates@ table.
--
-- On 'ExchangeRatesPublishedEvent', the day's rows for that provider are
-- replaced by the freshly published pairs — mirroring the in-memory
-- @Map.insert published.at published.rates@ (full-day replace) and making
-- replay idempotent.
applyExchangeRateEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyExchangeRateEvent globalEvent =
  case globalEvent.payload.payload of
    ExchangeRatesPublishedEvent published -> do
      deleteWhere
        [ ExchangeRateEntityProvider ==. published.provider,
          ExchangeRateEntityDay ==. published.at
        ]
      forM_ (Map.toList published.rates) $ \((src, tgt), er) ->
        insert_ (ExchangeRateEntity published.provider published.at src tgt er)
    _ -> pure ()

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Look up a historical rate for a @(source, target)@ currency pair published
-- by @provider@ on or near @day@.
--
-- When @day@ has no exact match in the provider's history, the query falls back
-- to the nearest known business day per 'lookupNearestDate' — the same day the
-- provider published /any/ rates, then the pair is resolved on that day.
-- Returns 'Nothing' when @source == target@ (matching the pure @getRate@).
lookupHistoricalRate ::
  (MonadIO m) =>
  Provider ->
  Day ->
  Currency ->
  Currency ->
  SqlPersistT m (Maybe ExchangeRate)
lookupHistoricalRate provider day src tgt
  | src == tgt = pure Nothing
  | otherwise = do
      daysMap <- providerDays provider
      case lookupNearestDate daysMap day of
        Nothing -> pure Nothing
        Just (nearest, ()) -> do
          mRow <-
            selectFirst
              [ ExchangeRateEntityProvider ==. provider,
                ExchangeRateEntityDay ==. nearest,
                ExchangeRateEntitySource ==. src,
                ExchangeRateEntityTarget ==. tgt
              ]
              []
          pure ((.exchangeRateEntityRate) . entityVal <$> mRow)

-- | Whether @provider@ has published any rates on the exact business day
-- @day@. Backs the daily-publish idempotency guard.
ratesPublishedOn :: (MonadIO m) => Provider -> Day -> SqlPersistT m Bool
ratesPublishedOn provider day =
  isJust
    <$> selectFirst
      [ExchangeRateEntityProvider ==. provider, ExchangeRateEntityDay ==. day]
      []

-- | The set of business days on which @provider@ has published rates, as a map
-- suitable for 'lookupNearestDate'.
providerDays :: (MonadIO m) => Provider -> SqlPersistT m (Map Day ())
providerDays provider = do
  rows <- selectList [ExchangeRateEntityProvider ==. provider] []
  pure $ Map.fromList [(e.exchangeRateEntityDay, ()) | Entity _ e <- rows]

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
