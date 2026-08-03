{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ExchangeRatePublisher
-- Description : Publishes exchange rates as domain events on a per-provider stream.
--
-- Writes 'ExchangeRatesPublishedEvent' to the event store so that
-- historical rates survive restarts. Idempotent within a single UTC day
-- per provider: the second call on the same day is a no-op, detected by
-- the @exchange_rates@ read-model table which is updated synchronously in
-- the event-append transaction after the first successful write.
--
-- The business date is carried in the payload as 'ExchangeRatesPublished.at',
-- set to today's UTC day at publish time.
module Application.Services.ExchangeRatePublisher
  ( publishRates,
    spawnRatePublisher,
    providerStreamId,
  )
where

import Application.ReadModels.ExchangeRate (ratesPublishedOn)
import qualified Data.ByteString as BS
import Data.Time
  ( UTCTime (..),
    addDays,
    diffUTCTime,
    getCurrentTime,
    secondsToDiffTime,
    utctDay,
  )
import Data.UUID (UUID)
import qualified Data.UUID.V5 as UUID5
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..), Provider, unProvider)
import Domain.Models (AccountingEvent (..))
import Eventium (EventStoreWriter (..), ExpectedPosition (..), metadataEnrichingEventStoreWriterWithTag)
import Infrastructure.Database (ConnectionPool, runDbDirect)
import Infrastructure.Eventium
  ( AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
    accountingEventTag,
  )
import Infrastructure.Eventium.Schema (accountingEventCodec)
import Infrastructure.ExchangeRate.Provider (RateProvider (..))
import RIO

-- -----------------------------------------------------------------------------
-- Deterministic per-provider Stream UUID
-- -----------------------------------------------------------------------------

-- | Namespace UUID for deterministic exchange-rate stream ID generation.
-- Uses UUID v5 (SHA-1 based) so that each provider name maps to a stable stream.
exchangeRateNamespace :: UUID
exchangeRateNamespace =
  UUID5.generateNamed
    UUID5.namespaceURL
    (BS.unpack $ encodeUtf8 "homeaccounting/exchange-rate")

-- | Deterministic stream UUID for a given provider name.
--
-- The same provider always resolves to the same stream UUID so that
-- replays pick up the full history. Distinct providers resolve to
-- distinct streams, isolating their event histories.
providerStreamId :: Provider -> UUID
providerStreamId prov =
  UUID5.generateNamed exchangeRateNamespace (BS.unpack . encodeUtf8 $ unProvider prov)

-- -----------------------------------------------------------------------------
-- Single-shot Publish
-- -----------------------------------------------------------------------------

-- | Publish today's rates for a provider as an 'ExchangeRatesPublishedEvent'.
--
-- Behaviour:
--   * If the read model already contains rates for today under this
--     provider, returns @Left "Rates already published for today"@
--     without contacting the provider or the event store.
--   * Otherwise, fetches rates from the provider. On provider failure,
--     returns @Left err@ without writing anything.
--   * On success, appends a single 'ExchangeRatesPublishedEvent' to the
--     per-provider stream ('providerStreamId') with @at = today@ in the
--     payload.
--
-- Idempotence relies on the tagged writer being composed with the
-- synchronous read-model publisher that projects the @exchange_rates@ table
-- in the event-append transaction before this function returns — the same
-- wiring used in production ('Application.ReadModels.Persist' driven by the
-- event-store writer in @app/Main.hs@).
publishRates ::
  (MonadIO m) =>
  RateProvider ->
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  ConnectionPool ->
  m (Either Text ())
publishRates prov writer _reader pool = liftIO $ do
  today <- utctDay <$> getCurrentTime
  alreadyPublished <- runDbDirect pool (ratesPublishedOn prov.providerName today)
  if alreadyPublished
    then pure (Left "Rates already published for today")
    else do
      result <- prov.fetchRates
      case result of
        Left err -> pure (Left err)
        Right rates -> do
          let streamId = providerStreamId prov.providerName
              payload =
                ExchangeRatesPublishedEvent
                  ExchangeRatesPublished
                    { provider = prov.providerName,
                      rates = rates,
                      at = today
                    }
              -- 'metadataEnrichingEventStoreWriterWithTag' with 'accountingEventTag'
              -- (not the plain 'metadataEnrichingEventStoreWriter', which would
              -- derive the tag from 'Typeable' and stamp every event
              -- @"AccountingEvent"@ — see 'Infrastructure.Eventium.accountingEventTag').
              enrichedWriter =
                metadataEnrichingEventStoreWriterWithTag accountingEventTag id accountingEventCodec writer
          writeResult <-
            enrichedWriter.storeEvents streamId AnyPosition [payload]
          case writeResult of
            Right _ -> pure (Right ())
            Left e -> pure (Left (tshow e))

-- -----------------------------------------------------------------------------
-- Background Scheduler
-- -----------------------------------------------------------------------------

-- | Spawn a daily background publisher.
--
-- Runs one immediate 'publishRates' call, then sleeps until 00:05 UTC
-- of the next day, then repeats. Uses 'async' + 'threadDelay' from RIO
-- — no new scheduling dependency.
--
-- Errors from 'publishRates' are caught and logged; the loop never
-- terminates on its own. The returned 'Async' handle is returned for
-- completeness — callers may retain it to 'cancel' the publisher on
-- shutdown, but it is safe to discard (e.g. with 'void') when the
-- publisher should simply live for the lifetime of the process.
spawnRatePublisher ::
  RateProvider ->
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  ConnectionPool ->
  LogFunc ->
  IO (Async ())
spawnRatePublisher prov writer reader pool logFunc =
  async
    $ runRIO logFunc
    $ forever
    $ do
      outcome <- liftIO $ tryAny (publishRates prov writer reader pool)
      case outcome of
        Left e ->
          logError $ "rate publish failed: " <> displayShow e
        Right (Left msg) ->
          logInfo $ "rate publish skipped: " <> display msg
        Right (Right ()) ->
          logInfo $ "rates published from " <> display prov.providerName
      delayMicros <- liftIO microsUntilNextTick
      liftIO $ threadDelay delayMicros

-- | Microseconds from now until 00:05 UTC of tomorrow, clamped to at
-- least 1 µs so 'threadDelay' never sees a non-positive argument if the
-- clock is adjusted mid-loop.
microsUntilNextTick :: IO Int
microsUntilNextTick = do
  now <- getCurrentTime
  let tomorrow = addDays 1 (utctDay now)
      target = UTCTime tomorrow (secondsToDiffTime (5 * 60))
      diffSec = realToFrac (diffUTCTime target now) :: Double
  pure $ max 1 (ceiling (diffSec * 1_000_000))
