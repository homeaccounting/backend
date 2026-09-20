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
--     'rebuildEnvVar'. A rebuild is announced on the log around the replay
--     (grep @read-model rebuild@), because it is an operator-requested one-off
--     whose only other evidence is the corrected data it produces.
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
import Application.ReadModels.Configuration (configurationProjectionName, configurationReadModel)
import Application.ReadModels.DataVersion (dataVersionProjectionName, dataVersionReadModel)
import Application.ReadModels.ExchangeRate (exchangeRateProjectionName, exchangeRateReadModel)
import Application.ReadModels.Transaction (transactionProjectionName, transactionReadModel)
import Application.ReadModels.User (userProjectionName, userReadModel)
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
    (unCheckpointName transactionProjectionName, transactionReadModel),
    -- Must run AFTER account + transaction so account_access and the
    -- transaction rows reflect the just-applied event when it resolves the
    -- users to signal (matters for grant/revoke and transactionId-only edits).
    (unCheckpointName dataVersionProjectionName, dataVersionReadModel),
    (unCheckpointName userProjectionName, userReadModel),
    (unCheckpointName exchangeRateProjectionName, exchangeRateReadModel),
    (unCheckpointName configurationProjectionName, configurationReadModel)
  ]
  where
    unCheckpointName (CheckpointName t) = t

-- | Bring every persistent read model up to date at startup: catch up from each
-- model's checkpoint, or fully rebuild the ones named in 'rebuildEnvVar'.
--
-- Each rebuild is logged by name, before and after its replay, so that the
-- operator who set 'rebuildEnvVar' for a one-off correction can confirm it
-- actually ran (and see it start, since replaying the whole log is not quick).
-- A catch-up is the normal startup path and stays silent.
initializePersistentReadModels ::
  (MonadIO m, MonadReader env m, HasLogFunc env) =>
  ConnectionPool ->
  AccountingGlobalEventStoreReader SqlIO ->
  m ()
initializePersistentReadModels pool gr = do
  rebuildTargets <- liftIO readRebuildTargets
  warnUnknownRebuildTargets rebuildTargets
  forM_ persistentReadModels $ \(name, rm) ->
    if shouldRebuild rebuildTargets name
      then do
        logInfo $ "Starting read-model rebuild (reset + full replay): " <> display name
        liftIO $ runDbDirect pool (rebuildReadModel gr rm)
        logInfo $ "Finished read-model rebuild: " <> display name
      else liftIO $ runDbDirect pool (catchUpReadModel gr rm)

-- | Warn about 'rebuildEnvVar' entries that name no registered projection.
-- Such an entry is a no-op, so a typo would otherwise leave the operator
-- concluding from a clean startup that the rebuild they asked for happened.
warnUnknownRebuildTargets ::
  (MonadIO m, MonadReader env m, HasLogFunc env) =>
  [Text] ->
  m ()
warnUnknownRebuildTargets targets =
  case filter (\t -> t /= "all" && t `notElem` known) targets of
    [] -> pure ()
    unknown ->
      logWarn
        $ display (T.pack rebuildEnvVar)
        <> " names no such projection: "
        <> display (T.intercalate ", " unknown)
        <> " — nothing was rebuilt for it. Known projections: "
        <> display (T.intercalate ", " known)
  where
    known = map fst persistentReadModels

-- | Parse 'rebuildEnvVar' into a list of requested targets (trimmed,
-- comma-separated). Empty when unset.
readRebuildTargets :: IO [Text]
readRebuildTargets =
  maybe [] (filter (not . T.null) . map T.strip . T.split (== ',') . T.pack)
    <$> lookupEnv rebuildEnvVar

-- | Whether a model should be fully rebuilt: named explicitly, or @all@.
shouldRebuild :: [Text] -> Text -> Bool
shouldRebuild targets name = "all" `elem` targets || name `elem` targets
