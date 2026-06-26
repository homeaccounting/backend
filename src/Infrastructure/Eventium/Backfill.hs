{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Infrastructure.Eventium.Backfill
-- Description : Batched, idempotent catch-up + rebuild for persistent read models
--
-- Reusable foundation for persistent read models. Both functions read the
-- global event stream via the SQL reader (so they see /real/ 'SequenceNumber's,
-- unlike the live publish path) and drive a read model's apply handler, advancing
-- an eventium 'CheckpointStore' as they go.
--
--   - 'backfillReadModel' replays @checkpoint+1 .. latest@ in batches, one DB
--     transaction per batch (resumable). Because the live path does not advance
--     the checkpoint, this re-applies events written since the last checkpoint
--     advance — bounded by the previous run's write volume, not full history —
--     which is safe only because read-model applies are idempotent.
--   - 'rebuildReadModelTables' truncates the model's tables and resets the
--     checkpoint, then backfills from sequence 0. The schema-evolution path.
--
-- The replay/checkpoint mechanics here are generic over the event type and are a
-- candidate to upstream into the eventium library (it already ships
-- 'Eventium.ReadModel.rebuildReadModel'); kept in-app for now to avoid library
-- churn mid-migration.
module Infrastructure.Eventium.Backfill
  ( backfillReadModel,
    rebuildReadModelTables,
  )
where

import qualified Data.List.NonEmpty as NE
import Eventium
  ( CheckpointStore (..),
    EventHandler (..),
    EventStoreReader (..),
    SequenceNumber,
    StreamEvent (..),
    eventsStartingAtTakeLimit,
  )
import Infrastructure.Database (ConnectionPool, SqlIO, runDbDirect)
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingReadModelHandler,
  )

-- | Replay @checkpoint+1 .. latest@ into a read model in batches, advancing the
-- checkpoint per batch. Returns the total number of events applied.
backfillReadModel ::
  ConnectionPool ->
  AccountingGlobalEventStoreReader SqlIO ->
  CheckpointStore SqlIO SequenceNumber ->
  AccountingReadModelHandler SqlIO ->
  -- | batch size
  Int ->
  IO Int
backfillReadModel pool (EventStoreReader getEvs) (CheckpointStore getCp saveCp) (EventHandler apply) batchN = go 0
  where
    go acc = do
      applied <- runDbDirect pool $ do
        from <- getCp
        evs <- getEvs (eventsStartingAtTakeLimit () (from + 1) batchN)
        case NE.nonEmpty evs of
          Nothing -> pure 0
          Just ne -> do
            apply evs
            saveCp (NE.last ne).position
            pure (length evs)
      if applied == 0 then pure acc else go (acc + applied)

-- | Reset a read model (truncate its tables + checkpoint), then backfill it from
-- the start of the log.
rebuildReadModelTables ::
  ConnectionPool ->
  -- | reset action: truncate this model's tables
  SqlIO () ->
  AccountingGlobalEventStoreReader SqlIO ->
  CheckpointStore SqlIO SequenceNumber ->
  AccountingReadModelHandler SqlIO ->
  Int ->
  IO Int
rebuildReadModelTables pool reset gr cp@(CheckpointStore _ saveCp) handler batchN = do
  runDbDirect pool $ do
    reset
    saveCp 0
  backfillReadModel pool gr cp handler batchN
