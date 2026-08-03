{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Observability.LoggingSpec (spec) where

import Control.Monad.Logger (LoggingT, logDebugN, logInfoN, runLoggingT)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text.Encoding as TE
import qualified Data.UUID as UUID
import Domain.Core.Types (unsafeUserId)
import Infrastructure.Config (LogFormat (..))
import Infrastructure.Observability.Logging
import Infrastructure.Observability.Context (RequestContext (..), nilRequestContext, renderUserId)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T
import RIO.Time (UTCTime)
import qualified System.Log.FastLogger as FastLogger
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Observability.Logging" $ do
  it "shouldLog gates by threshold" $ do
    shouldLog LevelInfo LevelDebug `shouldBe` False
    shouldLog LevelInfo LevelWarn `shouldBe` True
  it "renderJsonLogLine emits one JSON line with context fields" $ do
    let t0 = read "2026-08-01 00:00:00 UTC" :: UTCTime
        cid = UUID.nil
        uid = unsafeUserId UUID.nil
        line = renderJsonLogLine t0 LevelInfo (RequestContext cid (Just uid)) (Just "Foo.hs:1") ("hi" :: Utf8Builder)
    -- one line, no interior newline (the trailing \n is stripped before checking)
    BL.elem 0x0a (BL.take (BL.length line - 1) line) `shouldBe` False
    case A.decode line :: Maybe A.Value of
      Just (A.Object o) -> do
        KM.lookup "level" o `shouldBe` Just (A.String "info")
        KM.lookup "msg" o `shouldBe` Just (A.String "hi")
        KM.lookup "correlationId" o `shouldBe` Just (A.String (UUID.toText cid))
        KM.lookup "userId" o `shouldBe` Just (A.String (renderUserId uid))
      _ -> expectationFailure "expected a JSON object line"
  it "renderJsonLogLine omits userId when absent" $ do
    let t0 = read "2026-08-01 00:00:00 UTC" :: UTCTime
        line = renderJsonLogLine t0 LevelInfo (RequestContext UUID.nil Nothing) Nothing ("hi" :: Utf8Builder)
    case A.decode line :: Maybe A.Value of
      Just (A.Object o) -> KM.member "userId" o `shouldBe` False
      _ -> expectationFailure "expected a JSON object line"
  it "mkContextLogFunc gates below-threshold lines out of the sink" $ do
    contents <- captureLog LogJson LevelInfo (logDebug "DEBUG_DROP" >> logInfo "INFO_KEEP")
    ("INFO_KEEP" `T.isInfixOf` contents) `shouldBe` True
    ("DEBUG_DROP" `T.isInfixOf` contents) `shouldBe` False
  it "mkContextLogFunc renders LogText without a JSON envelope" $ do
    contents <- captureLog LogText LevelInfo (logInfo "TEXT_LINE")
    ("TEXT_LINE" `T.isInfixOf` contents) `shouldBe` True
    ("info" `T.isInfixOf` contents) `shouldBe` True
    ("cid=" `T.isInfixOf` contents) `shouldBe` True
    ("{" `T.isInfixOf` contents) `shouldBe` False
  it "renderSqlJsonLine emits one JSON line tagged source:sql, with correlationId" $ do
    let t0 = read "2026-08-01 00:00:00 UTC" :: UTCTime
        line = renderSqlJsonLine t0 LevelDebug (Just "cid-123") "SELECT 1 FROM foo"
    BL.elem 0x0a (BL.take (BL.length line - 1) line) `shouldBe` False
    case A.decode line :: Maybe A.Value of
      Just (A.Object o) -> do
        KM.lookup "level" o `shouldBe` Just (A.String "debug")
        KM.lookup "msg" o `shouldBe` Just (A.String "SELECT 1 FROM foo")
        KM.lookup "source" o `shouldBe` Just (A.String "sql")
        KM.lookup "correlationId" o `shouldBe` Just (A.String "cid-123")
      _ -> expectationFailure "expected a JSON object line"
  it "renderSqlJsonLine omits correlationId when absent" $ do
    let t0 = read "2026-08-01 00:00:00 UTC" :: UTCTime
        line = renderSqlJsonLine t0 LevelDebug Nothing "SELECT 1"
    case A.decode line :: Maybe A.Value of
      Just (A.Object o) -> KM.member "correlationId" o `shouldBe` False
      _ -> expectationFailure "expected a JSON object line"
  it "sqlJsonLogSink renders a debug SQL line as JSON at debug threshold" $ do
    contents <- captureSqlLog LevelDebug (Just "cid-abc") (logDebugN "SELECT * FROM accounts")
    case A.decode (BL.fromStrict (TE.encodeUtf8 contents)) :: Maybe A.Value of
      Just (A.Object o) -> do
        KM.lookup "source" o `shouldBe` Just (A.String "sql")
        KM.lookup "msg" o `shouldBe` Just (A.String "SELECT * FROM accounts")
        KM.lookup "correlationId" o `shouldBe` Just (A.String "cid-abc")
      _ -> expectationFailure "expected a JSON object line"
  it "sqlJsonLogSink suppresses debug SQL lines at an info threshold" $ do
    contents <- captureSqlLog LevelInfo Nothing (logDebugN "SELECT * FROM accounts" >> logInfoN "kept")
    ("SELECT" `T.isInfixOf` contents) `shouldBe` False
    ("kept" `T.isInfixOf` contents) `shouldBe` True

-- | Run an action against a 'mkContextLogFunc'-built 'LogFunc' whose sink is a
-- temporary file, then return the file's contents. Exercises the production
-- emit path (fast-logger 'LoggerSet') unchanged.
captureLog :: LogFormat -> LogLevel -> RIO LogFunc () -> IO Text
captureLog fmt threshold action =
  withSystemTempFile "logspec.log" $ \path h -> do
    hClose h
    loggerSet <- FastLogger.newFileLoggerSet FastLogger.defaultBufSize path
    let lf = mkContextLogFunc fmt threshold nilRequestContext loggerSet
    runRIO lf action
    FastLogger.flushLogStr loggerSet
    FastLogger.rmLoggerSet loggerSet
    readFileUtf8 path

-- | Run a @monad-logger@ action against a 'sqlJsonLogSink'-built sink whose
-- target is a temporary file, then return the file's contents. Exercises the
-- production emit path (fast-logger 'LoggerSet') exactly as 'runDb' does.
captureSqlLog :: LogLevel -> Maybe Text -> LoggingT IO () -> IO Text
captureSqlLog threshold cid action =
  withSystemTempFile "logspec-sql.log" $ \path h -> do
    hClose h
    loggerSet <- FastLogger.newFileLoggerSet FastLogger.defaultBufSize path
    runLoggingT action (sqlJsonLogSink threshold cid loggerSet)
    FastLogger.flushLogStr loggerSet
    FastLogger.rmLoggerSet loggerSet
    readFileUtf8 path
