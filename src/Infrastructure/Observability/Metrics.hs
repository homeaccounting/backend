{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Observability.Metrics
-- Description : Registered Prometheus metric handles for event-store telemetry
--
-- This module defines the 'Metrics' record of registered Prometheus metric
-- handles, the 'registerMetrics' action that registers them (once, into the
-- process-global 'Prometheus' registry), and small helpers to bump them.
--
-- Labels are intentionally minimal: a single @event_type@ label on the
-- persisted-events counter, and no labels at all on the write-conflicts
-- counter.
--
-- This module is intentionally isolated: it depends only on @prometheus-client@
-- / @prometheus-metrics-ghc@ and RIO. It defines the 'HasMetrics' capability
-- class but does NOT provide an 'AppEnv' instance — that wiring is added by a
-- later task once metrics are threaded through the app.
module Infrastructure.Observability.Metrics
  ( Metrics (..),
    registerMetrics,
    HasMetrics (..),
    incEventPersisted,
    incWriteConflict,
    GaugeSample,
    gaugeSample,
    toSampleGroups,
    registerGaugeCollector,
  )
where

import qualified Data.ByteString.Char8 as BS8
import Prometheus
  ( Counter,
    Info (..),
    Metric (..),
    Sample (..),
    SampleGroup (..),
    SampleType (..),
    Vector,
    counter,
    incCounter,
    register,
    vector,
    withLabel,
  )
import Prometheus.Metric.GHC (ghcMetrics)
import RIO hiding (Vector)

-- | Registered Prometheus metric handles used by the event-store telemetry.
data Metrics = Metrics
  { eventsPersisted :: !(Vector Text Counter),
    eventWriteConflicts :: !Counter
  }

-- | Register the metrics with the process-global Prometheus registry,
-- including the standard GHC runtime-statistics collector. Should be called
-- once per process (multiple calls each register a fresh, independent set of
-- handles into the registry — they are not deduplicated by name).
registerMetrics :: IO Metrics
registerMetrics = do
  eventsPersistedCounter <-
    register
      $ vector
        "event_type"
        (counter (Info "events_persisted_total" "Events durably persisted, by event type"))
  eventWriteConflictsCounter <-
    register
      $ counter (Info "events_write_conflicts_total" "Optimistic-concurrency write conflicts")
  void $ register ghcMetrics
  pure
    Metrics
      { eventsPersisted = eventsPersistedCounter,
        eventWriteConflicts = eventWriteConflictsCounter
      }

-- | Capability for environments that carry a 'Metrics' handle. The 'AppEnv'
-- instance is added by a later task.
class HasMetrics env where
  metricsL :: Lens' env Metrics

-- | Increment the @events_persisted_total@ counter for the given event type.
incEventPersisted :: Metrics -> Text -> IO ()
incEventPersisted m eventType = withLabel m.eventsPersisted eventType incCounter

-- | Increment the @events_write_conflicts_total@ counter.
incWriteConflict :: Metrics -> IO ()
incWriteConflict m = incCounter m.eventWriteConflicts

-- -----------------------------------------------------------------------------
-- Scrape-time gauge collector
--
-- A generic, computed-at-scrape gauge (as opposed to the imperatively-bumped
-- counter handles in 'Metrics' above): the value is produced by a fetch action
-- each time Prometheus scrapes. Gauge, not counter, because the value is a
-- recomputed snapshot of current state (e.g. @COUNT(*)@ over a read-model table),
-- not an accumulated total — a read-model rebuild under changed projection rules
-- can legitimately settle it at a lower number, and a Prometheus counter would
-- misread any such decrease as a reset. The concrete series and their meaning
-- (e.g. the business @users@ / @accounts@ / @transactions@ totals) are decided by
-- the caller in the composition root; this module stays metric-generic and
-- Application-agnostic (the fetch is injected, so no 'Application.*' import).
-- -----------------------------------------------------------------------------

-- | One scrape-time gauge to expose: a Prometheus name, help text, and current
-- value. Abstract — construct via 'gaugeSample'.
data GaugeSample = GaugeSample
  { name :: !Text,
    help :: !Text,
    value :: !Int64
  }

-- | Build a 'GaugeSample'. @name@ is the full Prometheus series name
-- (e.g. @"users"@). Do not use a @_total@ suffix — that convention is reserved
-- for counters.
gaugeSample :: Text -> Text -> Int64 -> GaugeSample
gaugeSample = GaugeSample

-- | Render gauge samples as gauge-typed Prometheus sample groups. Pure and
-- order-preserving; this is the unit-tested surface.
toSampleGroups :: [GaugeSample] -> [SampleGroup]
toSampleGroups = map render
  where
    render m =
      SampleGroup
        (Info m.name m.help)
        GaugeType
        [Sample m.name [] (BS8.pack (show m.value))]

-- | Register a scrape-time collector that runs @fetch@ on every scrape and emits
-- the resulting gauges. Registers once into the process-global registry
-- (mirrors 'registerMetrics'); call exactly once at startup.
registerGaugeCollector :: IO [GaugeSample] -> IO ()
registerGaugeCollector fetch =
  void $ register $ Metric $ pure ((), toSampleGroups <$> fetch)
