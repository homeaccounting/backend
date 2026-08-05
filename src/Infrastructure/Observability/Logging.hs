{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Observability.Logging
-- Description : JSON structured-logging 'LogFunc' over a shared 'fast-logger' 'LoggerSet'
--
-- RIO's 'LogFunc' is opaque and message-only: it is built solely via
-- 'mkLogFunc' and its callback carries only a 'Utf8Builder' message (no
-- key/value field slot). So per-request context (correlation id, user id)
-- cannot be "wrapped onto" an existing 'LogFunc' — it must be baked into the
-- formatter at construction time.
--
-- This module builds a 'LogFunc' that renders either a single JSON line
-- (Promtail/Grafana friendly) or a human-readable text line, gated by a
-- configured minimum 'LogLevel' (RIO does not filter for us on a
-- 'mkLogFunc'-built 'LogFunc'), and emits it through a shared, thread-safe,
-- buffered 'LoggerSet'.
module Infrastructure.Observability.Logging
  ( shouldLog,
    renderJsonLogLine,
    renderJsonLogLineFields,
    renderTextLogLineFields,
    renderSqlJsonLine,
    sqlJsonLogSink,
    mlToRioLevel,
    mkContextLogFunc,
    newStdoutLoggerSet,
    rioLevel,
  )
where

import Control.Monad.Logger (Loc, LogStr, fromLogStr)
import qualified Control.Monad.Logger as ML
import qualified Data.Aeson as A
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.UUID as UUID
import GHC.Stack (SrcLoc (..), getCallStack)
import qualified Infrastructure.Config as Config
import Infrastructure.Observability.Context (RequestContext (..), renderUserId)
import RIO
import qualified RIO.ByteString.Lazy as BL
import RIO.Time (UTCTime, getCurrentTime)
import qualified System.Log.FastLogger as FastLogger

-- | Should a log line at the given event level be emitted, given the
-- configured minimum threshold? Both are RIO 'LogLevel's ordered by
-- verbosity, so this is a simple threshold comparison.
shouldLog :: LogLevel -> LogLevel -> Bool
shouldLog threshold ev = ev >= threshold

-- | Render one JSON log line (with a trailing newline, no interior
-- newlines) carrying the standard fields: @ts@, @level@, @msg@, @caller@
-- (when present), @correlationId@, and @userId@ (when present).
--
-- Pure and deterministic: the timestamp is a parameter rather than sourced
-- from 'getCurrentTime', so tests don't need to mock the clock.
--
-- Thin wrapper over 'renderJsonLogLineFields' that projects the
-- 'RequestContext' down to already-rendered text fields — the correlation id
-- is always present (via 'Just'), the user id only when the context carries
-- one.
renderJsonLogLine ::
  UTCTime ->
  LogLevel ->
  RequestContext ->
  Maybe Text ->
  Utf8Builder ->
  BL.ByteString
renderJsonLogLine now lvl ctx =
  renderJsonLogLineFields
    now
    lvl
    (Just (UUID.toText ctx.correlationId))
    (fmap renderUserId ctx.userId)

-- | Core JSON log line renderer, taking the log fields directly rather than
-- a 'RequestContext'. Shared by 'renderJsonLogLine' (the request-path
-- 'LogFunc') and "Infrastructure.Observability.Interpreter" (the
-- eventium-'Signal' telemetry path), so both emit through the exact same
-- JSON schema instead of each reconstructing it.
--
-- @correlationId@ and @userId@ are already-rendered 'Text' and are omitted
-- from the JSON object when 'Nothing'.
renderJsonLogLineFields ::
  UTCTime ->
  LogLevel ->
  -- | correlationId, already rendered as text; omitted from the JSON when 'Nothing'
  Maybe Text ->
  -- | userId, already rendered as text; omitted from the JSON when 'Nothing'
  Maybe Text ->
  Maybe Text ->
  Utf8Builder ->
  BL.ByteString
renderJsonLogLineFields now lvl correlationId userId caller msg =
  A.encode
    ( A.object
        $ [ "ts" A..= iso8601 now,
            "level" A..= levelText lvl,
            "msg" A..= utf8BuilderToText msg
          ]
        <> maybe [] (\c -> ["correlationId" A..= c]) correlationId
        <> maybe [] (\c -> ["caller" A..= c]) caller
        <> maybe [] (\uid -> ["userId" A..= uid]) userId
    )
    <> "\n"

-- | ISO-8601 rendering matching the repo's existing convention (see
-- "Web.ErrorMapping".iso8601).
iso8601 :: UTCTime -> Text
iso8601 = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

-- | Lowercase level tag used in log lines. 'LevelOther' passes its own tag
-- through unchanged.
levelText :: LogLevel -> Text
levelText LevelDebug = "debug"
levelText LevelInfo = "info"
levelText LevelWarn = "warn"
levelText LevelError = "error"
levelText (LevelOther t) = t

-- | Render one SQL-log JSON line, reusing 'iso8601' and 'levelText' so its
-- @ts@/@level@/@msg@ keys stay byte-for-byte identical to
-- 'renderJsonLogLineFields'. @source:"sql"@ is the discriminator that lets
-- Promtail/Grafana tell persistent's query logging apart from the rest of
-- the app's structured logs; @correlationId@ is included only when the SQL
-- ran on a known request path (omitted otherwise).
--
-- This is the bridge target for 'sqlJsonLogSink': persistent's
-- @monad-logger@ SQL debug lines land here instead of
-- @Control.Monad.Logger.runStdoutLoggingT@'s plaintext output, keeping the
-- "one stdout line is one JSON object" invariant intact.
renderSqlJsonLine ::
  UTCTime ->
  LogLevel ->
  -- | correlationId, already rendered as text; omitted from the JSON when 'Nothing'
  Maybe Text ->
  -- | the raw SQL log message
  Text ->
  BL.ByteString
renderSqlJsonLine now lvl correlationId msg =
  A.encode
    ( A.object
        $ [ "ts" A..= iso8601 now,
            "level" A..= levelText lvl,
            "msg" A..= msg,
            "source" A..= ("sql" :: Text)
          ]
        <> maybe [] (\c -> ["correlationId" A..= c]) correlationId
    )
    <> "\n"

-- | A @monad-logger@ sink — the callback shape 'Control.Monad.Logger.runLoggingT'
-- expects — that renders through 'renderSqlJsonLine' and pushes onto the
-- shared 'FastLogger.LoggerSet'. This is how @persistent@'s SQL debug
-- logging (normally run via @runStdoutLoggingT@, emitting raw plaintext) is
-- bridged onto the same JSON stdout stream as the rest of the app's
-- structured logging, in JSON log mode.
--
-- Gates on 'threshold' itself: unlike 'mkContextLogFunc' (which is always
-- wrapped in a level check by its caller), there is no guarantee a
-- @filterLogger@ sits between @persistent@ and this sink, so the check
-- lives here.
-- The callback's level comes from @monad-logger@ ('ML.LogLevel'), whereas the
-- 'threshold' and everything downstream ('shouldLog', 'renderSqlJsonLine',
-- 'levelText') speak RIO's 'LogLevel' — so the incoming level is mapped over
-- via 'mlToRioLevel' before it is gated and rendered.
sqlJsonLogSink ::
  -- | minimum level to emit (mirrors the app's configured log level)
  LogLevel ->
  -- | correlationId, when the SQL ran on a known request path
  Maybe Text ->
  FastLogger.LoggerSet ->
  (Loc -> ML.LogSource -> ML.LogLevel -> LogStr -> IO ())
sqlJsonLogSink threshold correlationId loggerSet _loc _src mlLvl msg =
  let lvl = mlToRioLevel mlLvl
   in when (shouldLog threshold lvl) $ do
        now <- getCurrentTime
        let msgText = decodeUtf8Lenient (fromLogStr msg)
        FastLogger.pushLogStr loggerSet (FastLogger.toLogStr (renderSqlJsonLine now lvl correlationId msgText))

-- | Map @monad-logger@'s 'ML.LogLevel' onto RIO's 'LogLevel'. They are
-- structurally identical sum types living in different packages; persistent
-- logs through the former, the rest of the app speaks the latter.
mlToRioLevel :: ML.LogLevel -> LogLevel
mlToRioLevel ML.LevelDebug = LevelDebug
mlToRioLevel ML.LevelInfo = LevelInfo
mlToRioLevel ML.LevelWarn = LevelWarn
mlToRioLevel ML.LevelError = LevelError
mlToRioLevel (ML.LevelOther t) = LevelOther t

-- | Plain human-readable line used in 'Config.LogText' mode: mirrors the
-- JSON line's fields without the JSON envelope.
--
-- Thin wrapper over 'renderTextLogLineFields' that projects the
-- 'RequestContext' down to already-rendered text fields — mirroring how
-- 'renderJsonLogLine' wraps 'renderJsonLogLineFields'.
renderTextLogLine ::
  UTCTime ->
  LogLevel ->
  RequestContext ->
  Maybe Text ->
  Utf8Builder ->
  BL.ByteString
renderTextLogLine now lvl ctx =
  renderTextLogLineFields
    now
    lvl
    (Just (UUID.toText ctx.correlationId))
    (fmap renderUserId ctx.userId)

-- | Core plain-text log line renderer, taking the log fields directly rather
-- than a 'RequestContext' — the text-mode counterpart of
-- 'renderJsonLogLineFields'. Shared by 'renderTextLogLine' (the request-path
-- 'LogFunc') and "Infrastructure.Observability.Interpreter" (the
-- eventium-'Signal' telemetry path), so both honour 'Config.LogText' through
-- the exact same layout instead of the telemetry path always emitting JSON.
--
-- @correlationId@ and @userId@ are already-rendered 'Text' and are omitted
-- from the line when 'Nothing'.
renderTextLogLineFields ::
  UTCTime ->
  LogLevel ->
  -- | correlationId, already rendered as text; omitted when 'Nothing'
  Maybe Text ->
  -- | userId, already rendered as text; omitted when 'Nothing'
  Maybe Text ->
  Maybe Text ->
  Utf8Builder ->
  BL.ByteString
renderTextLogLineFields now lvl correlationId userId caller msg =
  BL.fromStrict (encodeUtf8 line) <> "\n"
  where
    line =
      T.unwords
        $ [ iso8601 now,
            "[" <> levelText lvl <> "]"
          ]
        <> maybe [] (\c -> ["cid=" <> c]) correlationId
        <> maybe [] (\uid -> ["user=" <> uid]) userId
        <> maybe [] (\c -> ["caller=" <> c]) caller
        <> [utf8BuilderToText msg]

-- | Build a context-aware 'LogFunc' that renders through the configured
-- format, drops lines below the configured threshold, and emits through the
-- shared 'FastLogger.LoggerSet'.
mkContextLogFunc :: Config.LogFormat -> LogLevel -> RequestContext -> FastLogger.LoggerSet -> LogFunc
mkContextLogFunc fmt threshold ctx loggerSet =
  mkLogFunc $ \cs _src lvl msg ->
    when (shouldLog threshold lvl) $ do
      now <- getCurrentTime
      let caller = callerFromCS cs
          render = case fmt of
            Config.LogJson -> renderJsonLogLine now lvl ctx caller msg
            Config.LogText -> renderTextLogLine now lvl ctx caller msg
      FastLogger.pushLogStr loggerSet (FastLogger.toLogStr render)

-- | The @file:line@ of the last (innermost) call-site frame, or 'Nothing'
-- when the call stack is empty.
callerFromCS :: CallStack -> Maybe Text
callerFromCS cs = case reverse (getCallStack cs) of
  (_, loc) : _ -> Just (T.pack loc.srcLocFile <> ":" <> tshow loc.srcLocStartLine)
  [] -> Nothing

-- | A stdout 'FastLogger.LoggerSet' with the library's default buffer size.
newStdoutLoggerSet :: IO FastLogger.LoggerSet
newStdoutLoggerSet = FastLogger.newStdoutLoggerSet FastLogger.defaultBufSize

-- | Convert the app's configured 'Config.LogLevel' to RIO's 'LogLevel'.
--
-- Currently duplicated inline as @convertLogLevel@ in
-- "Main".@createLogOptions@; exposed here for reuse (that call site is left
-- untouched by this task).
rioLevel :: Config.LogLevel -> LogLevel
rioLevel Config.LogDebug = LevelDebug
rioLevel Config.LogInfo = LevelInfo
rioLevel Config.LogWarn = LevelWarn
rioLevel Config.LogError = LevelError
