{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Observability.MetricsSpec (spec) where

import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.List as List
import Infrastructure.Observability.Metrics
import Prometheus
  ( Info (..),
    Sample (..),
    SampleGroup (..),
    exportMetricsAsText,
    getCounter,
    getVectorWith,
  )
import RIO
import Test.Hspec

-- | 'prometheus-client' keeps a process-global registry, so registering the
-- same metric names twice across examples is not something we want to do
-- repeatedly. Register once, at spec-tree construction time via 'runIO', and
-- share the handle across all examples. Counter assertions use before/after
-- deltas rather than absolute values, since the global registry accumulates
-- across the whole test suite run.
--
-- Note: 'withLabel'\'s signature is @(metric -> IO ()) -> m ()@ — it cannot
-- be used to read a value out, only to act on one — so reading a
-- per-label counter goes through 'getVectorWith' instead.
spec :: Spec
spec = describe "Observability.Metrics" $ do
  m <- runIO registerMetrics
  it "incEventPersisted increments the event_type-labeled counter" $ do
    before <- readEventsPersisted m "AccountOpened"
    incEventPersisted m "AccountOpened"
    after <- readEventsPersisted m "AccountOpened"
    (after - before) `shouldBe` 1
  it "incWriteConflict increments the conflicts counter" $ do
    before <- getCounter m.eventWriteConflicts
    incWriteConflict m
    after <- getCounter m.eventWriteConflicts
    (after - before) `shouldBe` 1
  it "registered metrics appear in the export" $ do
    txt <- exportMetricsAsText
    BLC.unpack txt `shouldContain` "events_persisted_total"
    BLC.unpack txt `shouldContain` "events_write_conflicts_total"
  it "labels events_persisted_total by event_type in the export" $ do
    incEventPersisted m "AccountOpened"
    txt <- exportMetricsAsText
    BLC.unpack txt `shouldContain` "event_type=\"AccountOpened\""
  describe "scrape-time gauge collector" $ do
    it "renders each gauge sample as a gauge-typed sample group" $ do
      let groups = toSampleGroups [gaugeSample "users" "Registered users" 3]
      case groups of
        [SampleGroup (Info n h) ty [Sample sn _ v]] -> do
          n `shouldBe` "users"
          h `shouldBe` "Registered users"
          show ty `shouldBe` "gauge" -- SampleType has no Eq instance; its Show renders lowercase
          sn `shouldBe` "users"
          v `shouldBe` "3" -- decimal-encoded value bytes
        other -> expectationFailure ("unexpected shape: " <> show other)

    it "preserves order and encodes each Int64 value as decimal bytes" $ do
      let groups =
            toSampleGroups
              [ gaugeSample "users" "u" 0,
                gaugeSample "accounts" "a" 42
              ]
      [n | SampleGroup (Info n _) _ _ <- groups] `shouldBe` ["users", "accounts"]
      [v | SampleGroup _ _ [Sample _ _ v] <- groups] `shouldBe` ["0", "42"]

readEventsPersisted :: Metrics -> Text -> IO Double
readEventsPersisted m label =
  fromMaybe 0 . List.lookup label <$> getVectorWith m.eventsPersisted getCounter
