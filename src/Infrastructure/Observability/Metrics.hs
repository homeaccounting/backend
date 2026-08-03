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
  )
where

import Prometheus
  ( Counter,
    Info (..),
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
