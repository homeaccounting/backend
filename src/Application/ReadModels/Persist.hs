{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.Persist
-- Description : Registry + startup catch-up/rebuild for persistent read models
--
-- The single registry of persistent (SQL) read models, expressed as eventium
-- 'ReadModel's. Two consumers use it:
--
--   * the event-store writer wiring (@app/Main.hs@) drives each model
--     synchronously in the event-append transaction via @readModelPublisher@
--     (real global positions; checkpoint advanced in-line), and
--   * 'initializePersistentReadModels' brings each model up to date at startup
--     with 'catchUpReadModel' (initialize + replay from its checkpoint, no
--     reset) — or 'rebuildReadModel' (reset + replay) when named in
--     'rebuildEnvVar'.
--
-- Lives in Application (it references concrete read models) and is called from
-- the composition root, so Infrastructure need not depend on Application.
module Application.ReadModels.Persist
  ( persistentReadModels,
    initializePersistentReadModels,
    rebuildEnvVar,
  )
where

import Application.ReadModels.Account (accountProjectionName, accountReadModel)
import Application.ReadModels.BankImportReadModel (bankImportProjectionName, bankImportReadModel)
import Application.ReadModels.Transaction (transactionProjectionName, transactionReadModel)
import Domain.Models (AccountingEvent)
import Eventium (ReadModel, catchUpReadModel, rebuildReadModel)
import Eventium.ProjectionCache.Postgresql (CheckpointName (..))
import Infrastructure.Database (ConnectionPool, SqlIO, runDbDirect)
import Infrastructure.Eventium (AccountingGlobalEventStoreReader)
import RIO
import qualified RIO.Text as T
import System.Environment (lookupEnv)

-- | Environment variable naming which read models to fully rebuild at startup
-- (comma-separated projection names, or @all@).
rebuildEnvVar :: String
rebuildEnvVar = "REBUILD_READ_MODELS"

-- | Every persistent read model, keyed by its projection name (used both to
-- drive it in the writer and to match 'rebuildEnvVar' targets).
persistentReadModels :: [(Text, ReadModel SqlIO AccountingEvent)]
persistentReadModels =
  [ (unCheckpointName bankImportProjectionName, bankImportReadModel),
    (unCheckpointName accountProjectionName, accountReadModel),
    (unCheckpointName transactionProjectionName, transactionReadModel)
  ]
  where
    unCheckpointName (CheckpointName t) = t

-- | Bring every persistent read model up to date at startup: catch up from each
-- model's checkpoint, or fully rebuild the ones named in 'rebuildEnvVar'.
initializePersistentReadModels ::
  ConnectionPool ->
  AccountingGlobalEventStoreReader SqlIO ->
  IO ()
initializePersistentReadModels pool gr = do
  rebuildTargets <- readRebuildTargets
  forM_ persistentReadModels $ \(name, rm) ->
    runDbDirect pool
      $ if shouldRebuild rebuildTargets name
        then rebuildReadModel gr rm
        else catchUpReadModel gr rm

-- | Parse 'rebuildEnvVar' into a list of requested targets (trimmed,
-- comma-separated). Empty when unset.
readRebuildTargets :: IO [Text]
readRebuildTargets =
  maybe [] (filter (not . T.null) . map T.strip . T.split (== ',') . T.pack)
    <$> lookupEnv rebuildEnvVar

-- | Whether a model should be fully rebuilt: named explicitly, or @all@.
shouldRebuild :: [Text] -> Text -> Bool
shouldRebuild targets name = "all" `elem` targets || name `elem` targets
