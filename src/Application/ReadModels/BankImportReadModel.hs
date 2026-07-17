{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ReadModels.BankImportReadModel
-- Description : Persistent read model for bank import deduplication
--
-- Indexes external transaction IDs from 'TransactionPostingInitiated' events into
-- the @imported_transactions@ table, so the bank import service can detect and
-- skip duplicate imports.
--
-- Key components:
--   - 'ImportedTransactionEntity': @imported_transactions@ row (external id -> internal tx id)
--   - 'isImported': SQL membership check used during bank statement import
--   - 'bankImportReadModel': the eventium 'ReadModel' (apply, checkpoint,
--     migrate, reset), driven synchronously in the event-append transaction
--   - 'migrateBankImport' / 'resetBankImport': schema + rebuild support
--
-- Design rationale:
--   - A unique constraint on the external transaction id lets the database
--     enforce dedup uniqueness, and the apply is naturally idempotent
--     ('insertUnique' re-inserting the same id is a no-op).
--   - Deduplication is /permanent/: a mapping recorded on
--     'TransactionPostingInitiated' is never removed, even if the posting later
--     fails. A re-sync therefore never re-imports a transaction it has already
--     attempted, preventing the unbounded duplicate accumulation that the
--     previous (evict-on-failure) behaviour caused.
module Application.ReadModels.BankImportReadModel
  ( ImportedTransactionEntity (..),
    ImportedTransactionEntityId,
    bankImportProjectionName,
    migrateBankImport,
    resetBankImport,
    bankImportReadModel,
    isImported,
  )
where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (isJust)
import Database.Persist (Filter, deleteWhere, getBy, insertUnique)
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.TH
  ( mkMigrate,
    mkPersist,
    persistLowerCase,
    share,
    sqlSettings,
  )
import Domain.Core.Types (ExternalTransactionId, TransactionId, importInfoExternalTransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionPostingInitiated (..))
import Eventium (EventHandler (..), GlobalStreamEvent, ReadModel (..))
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import Infrastructure.Database.Orphans ()
import Infrastructure.Eventium.GlobalEvent (unpackGlobalEvent)

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateBankImport"]
  [persistLowerCase|
ImportedTransactionEntity sql=imported_transactions
    externalTransactionId ExternalTransactionId
    transactionId TransactionId
    UniqueExternalTransactionId externalTransactionId
    deriving Show Eq
|]

-- | Projection/checkpoint name for this read model. The single source of truth
-- for the @projection_snapshots@ key, shared by the catch-up/rebuild wiring.
bankImportProjectionName :: CheckpointName
bankImportProjectionName = CheckpointName "bankimport"

-- -----------------------------------------------------------------------------
-- Rebuild support
-- -----------------------------------------------------------------------------

-- | Clear the dedup table. Used by the rebuild path before replaying the log.
--
-- Uses @DELETE@ (via 'deleteWhere') rather than SQL @TRUNCATE@: persistent has no
-- portable truncate, raw @TRUNCATE@ is Postgres-only and would break the SQLite
-- test backend, and SQLite already optimizes an unqualified @DELETE@ into a fast
-- table clear. Rebuild is a rare admin/migration operation, so the difference is
-- immaterial.
resetBankImport :: (MonadIO m) => SqlPersistT m ()
resetBankImport = deleteWhere ([] :: [Filter ImportedTransactionEntity])

-- -----------------------------------------------------------------------------
-- Query
-- -----------------------------------------------------------------------------

-- | Whether an external transaction id has already been imported.
isImported :: (MonadIO m) => ExternalTransactionId -> SqlPersistT m Bool
isImported extId = isJust <$> getBy (UniqueExternalTransactionId extId)

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

-- | Idempotent projection apply for a single global event: records the
-- external-id -> internal-tx-id mapping for every 'TransactionPostingInitiated'
-- carrying an external id. 'insertUnique' (keyed by the external id) makes
-- re-application a no-op.
applyBankImportEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyBankImportEvent globalEvent =
  let (streamUuid, payload) = unpackGlobalEvent globalEvent
   in case payload of
        TransactionPostingInitiatedEvent evt ->
          case (importInfoExternalTransactionId <$> evt.importInfo, mkTransactionIdSafe streamUuid) of
            (Just extId, Just txId) ->
              void $ insertUnique (ImportedTransactionEntity extId txId)
            _ -> pure ()
        _ -> pure ()

-- | The bank-import dedup as an eventium 'ReadModel'. Driven synchronously in the
-- event-append transaction via 'readModelPublisher' (real global positions,
-- checkpoint advanced in-line), and brought up to date / rebuilt at startup via
-- 'catchUpReadModel' / 'rebuildReadModel'.
bankImportReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
bankImportReadModel =
  ReadModel
    { initialize = void (runMigrationSilent migrateBankImport),
      eventHandler = EventHandler applyBankImportEvent,
      checkpointStore = postgresqlCheckpointStore bankImportProjectionName,
      -- Only drop view data; rebuildReadModel resets the checkpoint itself.
      reset = resetBankImport
    }
