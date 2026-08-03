{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Observability.Interpreter
-- Description : Telemetry interpreter turning eventium 'Signal's into metrics + JSON logs
--
-- A pure factory: 'mkTelemetry' takes its dependencies explicitly (a log
-- threshold, a sink, and a registered 'Metrics' handle) and returns a
-- 'Telemetry' interpreter to hand to the eventium event store writer. It does
-- not read from 'Infrastructure.App.AppEnv' — wiring it into the app is a
-- later task.
--
-- Per "Eventium.Telemetry", interpreters must never throw: a write-path emit
-- may run inside the write transaction, so this module only ever bumps
-- Prometheus counters and pushes a pre-rendered log line, both of which are
-- best-effort and non-throwing.
--
-- Metrics are bumped unconditionally for every 'Signal' — only the
-- accompanying log line is gated by the configured 'LogLevel' threshold, via
-- "Infrastructure.Observability.Logging".'shouldLog'.
module Infrastructure.Observability.Interpreter
  ( interpretSignal,
    mkTelemetry,
  )
where

import Database.Persist.Sql (SqlPersistT)
import Eventium
  ( EventMetadata (..),
    Signal (..),
    Telemetry (..),
    uuidToText,
  )
import Infrastructure.Observability.Logging (renderJsonLogLineFields, shouldLog)
import Infrastructure.Observability.Metrics (Metrics, incEventPersisted, incWriteConflict)
import RIO
import qualified RIO.Map as Map
import RIO.Time (getCurrentTime)
import System.Log.FastLogger (LogStr, toLogStr)

-- | Turn one eventium 'Signal' into metric bumps and (level-gated) a single
-- JSON log line pushed to 'sink'. Best-effort and non-throwing: metrics use
-- 'Prometheus' counters (which don't throw) and the sink is caller-supplied.
interpretSignal :: LogLevel -> (LogStr -> IO ()) -> Metrics -> Signal -> IO ()
interpretSignal threshold sink metrics sig = do
  now <- getCurrentTime
  case sig of
    EventsPersisted _ metas _ -> do
      for_ metas $ \m -> incEventPersisted metrics m.eventType
      when (shouldLog threshold LevelDebug)
        $ sink
          ( toLogStr
              ( renderJsonLogLineFields
                  now
                  LevelDebug
                  (correlationIdOf metas)
                  (userIdOf metas)
                  Nothing
                  (msgFor metas)
              )
          )
    WriteConflict uuid _ -> do
      incWriteConflict metrics
      when (shouldLog threshold LevelWarn)
        $ sink
          ( toLogStr
              ( renderJsonLogLineFields
                  now
                  LevelWarn
                  Nothing
                  Nothing
                  Nothing
                  ("write conflict on stream " <> display (uuidToText uuid))
              )
          )
  where
    correlationIdOf :: [EventMetadata] -> Maybe Text
    correlationIdOf metas = do
      m <- listToMaybe metas
      uuidToText <$> m.correlationId

    userIdOf :: [EventMetadata] -> Maybe Text
    userIdOf metas = do
      m <- listToMaybe metas
      Map.lookup "userId" m.custom

    msgFor :: [EventMetadata] -> Utf8Builder
    msgFor metas = "persisted " <> display (length metas) <> " event(s)"

-- | Build a 'Telemetry' interpreter over 'SqlPersistT IO' — the monad the
-- eventium write path runs its store operations in — from explicit
-- dependencies. Pure factory: no 'AppEnv' reads.
mkTelemetry :: LogLevel -> (LogStr -> IO ()) -> Metrics -> Telemetry (SqlPersistT IO)
mkTelemetry threshold sink metrics =
  Telemetry $ \sig -> lift (interpretSignal threshold sink metrics sig)
