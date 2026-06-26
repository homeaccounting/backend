{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.Persist
-- Description : Startup migration + catch-up/rebuild for persistent read models
--
-- Single place that brings every persistent (SQL) read model up to date at
-- startup. Called from the composition root (@app/Main.hs@) so that
-- Infrastructure need not depend on Application.
--
-- For each persistent read model it:
--   1. migrates the model's table(s), then
--   2. catches it up from its checkpoint — or fully rebuilds it when requested
--      via the 'rebuildEnvVar' environment variable.
--
-- Their live updates already commit in the event-append transaction; this is the
-- one-time backfill (newly-added tables) / bounded boot catch-up / on-demand
-- rebuild path. Idempotent applies make re-application safe.
module Application.ReadModels.Persist
  ( initializePersistentReadModels,
    rebuildEnvVar,
  )
where

import Application.ReadModels.BankImportReadModel
  ( bankImportProjectionName,
    handleBankImportEvents,
    migrateBankImport,
    resetBankImport,
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import Infrastructure.Database (ConnectionPool, SqlIO, runDbDirect, runMigration)
import Infrastructure.Eventium (AccountingGlobalEventStoreReader)
import Infrastructure.Eventium.Backfill (backfillReadModel, rebuildReadModelTables)
import RIO
import qualified RIO.Text as T
import System.Environment (lookupEnv)

-- | Environment variable naming which read models to fully rebuild at startup
-- (comma-separated projection names, or @all@). Centralized here rather than
-- read inline in the composition root.
rebuildEnvVar :: String
rebuildEnvVar = "REBUILD_READ_MODELS"

-- | Events replayed per backfill batch / DB transaction.
defaultBatchSize :: Int
defaultBatchSize = 1000

-- | Migrate and bring every persistent read model up to date. Returns
-- @(projectionName, eventsApplied)@ pairs for the caller to log.
initializePersistentReadModels ::
  ConnectionPool ->
  AccountingGlobalEventStoreReader SqlIO ->
  IO [(Text, Int)]
initializePersistentReadModels pool gr = do
  rebuildTargets <- readRebuildTargets
  let bringUpToDate name reset checkpoint handler = do
        let cp = postgresqlCheckpointStore checkpoint
        applied <-
          if shouldRebuild rebuildTargets name
            then rebuildReadModelTables pool reset gr cp handler defaultBatchSize
            else backfillReadModel pool gr cp handler defaultBatchSize
        pure (name, applied)

  -- BankImport
  runDbDirect pool (runMigration migrateBankImport)
  bankImport <-
    bringUpToDate
      (projectionText bankImportProjectionName)
      resetBankImport
      bankImportProjectionName
      handleBankImportEvents

  pure [bankImport]
  where
    projectionText (CheckpointName t) = t

-- | Parse 'rebuildEnvVar' into a list of requested targets (trimmed,
-- comma-separated). Empty when unset.
readRebuildTargets :: IO [Text]
readRebuildTargets =
  maybe [] (filter (not . T.null) . map T.strip . T.split (== ',') . T.pack)
    <$> lookupEnv rebuildEnvVar

-- | Whether a model should be fully rebuilt: named explicitly, or @all@.
shouldRebuild :: [Text] -> Text -> Bool
shouldRebuild targets name = "all" `elem` targets || name `elem` targets
