{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Observability.InterpreterSpec (spec) where

import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import qualified Data.List as List
import qualified Data.UUID as UUID
import Domain.Core.Types (UserId, unsafeUserId)
import Eventium
  ( ConflictInfo (..),
    EventMetadata,
    EventVersion (..),
    ExpectedPosition (..),
    Signal (..),
    emptyMetadata,
    insertCustomMetadata,
  )
import Infrastructure.Observability.Context (renderUserId, setCorrelationId)
import Infrastructure.Observability.Interpreter (interpretSignal)
import Infrastructure.Observability.Metrics
  ( Metrics (..),
    registerMetrics,
  )
import Prometheus (getCounter, getVectorWith)
import RIO
import qualified RIO.ByteString.Lazy as BL
import System.Log.FastLogger (LogStr, fromLogStr)
import Test.Hspec

spec :: Spec
spec = describe "Observability.Interpreter" $ do
  metrics <- runIO registerMetrics
  it "on EventsPersisted at Debug threshold: bumps the per-event-type counter and emits a debug JSON line with correlationId + userId" $ do
    ref <- newIORef []
    let cid = UUID.nil
        uid = unsafeUserId UUID.nil
        md = mkMetadata cid uid "AccountOpened"

    before <- readEventsPersisted metrics "AccountOpened"
    interpretSignal LevelDebug (captureSink ref) metrics (EventsPersisted UUID.nil [md, md] [])
    after <- readEventsPersisted metrics "AccountOpened"
    (after - before) `shouldBe` 2

    captured <- readIORef ref
    case mapMaybe (A.decode . BL.fromStrict) captured :: [A.Value] of
      (A.Object o : _) -> do
        KM.lookup "correlationId" o `shouldBe` Just (A.String (UUID.toText cid))
        KM.lookup "userId" o `shouldBe` Just (A.String (renderUserId uid))
      _ -> expectationFailure "expected at least one decodable JSON line"

  it "on EventsPersisted at Info threshold: suppresses the debug persist line but still bumps the metric" $ do
    ref <- newIORef []
    let cid = UUID.nil
        uid = unsafeUserId UUID.nil
        md = mkMetadata cid uid "AccountOpened"

    before <- readEventsPersisted metrics "AccountOpened"
    interpretSignal LevelInfo (captureSink ref) metrics (EventsPersisted UUID.nil [md, md] [])
    after <- readEventsPersisted metrics "AccountOpened"
    (after - before) `shouldBe` 2

    captured <- readIORef ref
    captured `shouldBe` []

  it "on WriteConflict at Info threshold: bumps the conflicts counter and emits a warn line" $ do
    ref <- newIORef []
    before <- getCounter metrics.eventWriteConflicts

    interpretSignal
      LevelInfo
      (captureSink ref)
      metrics
      (WriteConflict UUID.nil (ConflictInfo (ExactPosition (EventVersion 3)) (EventVersion 7)))

    after <- getCounter metrics.eventWriteConflicts
    (after - before) `shouldBe` 1

    captured <- readIORef ref
    case mapMaybe (A.decode . BL.fromStrict) captured :: [A.Value] of
      (A.Object o : _) -> KM.lookup "level" o `shouldBe` Just (A.String "warn")
      _ -> expectationFailure "expected at least one decodable JSON line"

-- | Build metadata with a correlation id and a stamped @userId@ custom field,
-- mirroring how 'Infrastructure.Observability.Context.enricherFromContext'
-- stamps outgoing event metadata.
mkMetadata :: UUID.UUID -> UserId -> Text -> EventMetadata
mkMetadata cid uid tag =
  insertCustomMetadata "userId" (renderUserId uid) (setCorrelationId cid (emptyMetadata tag))

-- | Append each captured log line (as a strict 'ByteString') to an 'IORef'.
captureSink :: IORef [ByteString] -> LogStr -> IO ()
captureSink ref ls = modifyIORef' ref (<> [fromLogStr ls])

-- | Current value of the @event_type@-labeled persisted-events counter for a
-- given label, defaulting to 0 when the label hasn't been observed yet.
readEventsPersisted :: Metrics -> Text -> IO Double
readEventsPersisted m label =
  fromMaybe 0 . List.lookup label <$> getVectorWith m.eventsPersisted getCounter
