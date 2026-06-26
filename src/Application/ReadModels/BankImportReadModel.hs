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
--   - 'handleBankImportEvents': idempotent projection apply, run in the
--     event-append transaction (strong consistency)
--   - 'migrateBankImport' / 'resetBankImport': schema + rebuild support
--
-- Design rationale:
--   - A unique constraint on the external transaction id lets the database
--     enforce dedup uniqueness, and the apply is naturally idempotent
--     ('insertUnique' re-inserting the same id is a no-op). This is what makes
--     boot catch-up (which re-applies events past the checkpoint) safe here.
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
    handleBankImportEvents,
    isImported,
  )
where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (isJust)
import Database.Persist (Filter, deleteWhere, getBy, insertUnique)
import Database.Persist.Sql (SqlPersistT)
import Database.Persist.TH
  ( mkMigrate,
    mkPersist,
    persistLowerCase,
    share,
    sqlSettings,
  )
import Domain.Core.Types (ExternalTransactionId, TransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionPostingInitiated (..))
import Eventium (EventHandler (..), GlobalStreamEvent)
import Eventium.ProjectionCache.Postgresql (CheckpointName (..))
import Infrastructure.Database.Orphans ()
import Infrastructure.Eventium (AccountingReadModelHandler)
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
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Idempotent projection apply: records the external-id -> internal-tx-id
-- mapping for every 'TransactionPostingInitiated' carrying an external id.
--
-- Runs in 'SqlPersistT' so it commits in the same transaction as the event
-- append. 'insertUnique' (keyed by the external id) makes re-application a no-op,
-- which is required for safe boot catch-up.
handleBankImportEvents :: (MonadIO m) => AccountingReadModelHandler (SqlPersistT m)
handleBankImportEvents = EventHandler $ \events -> mapM_ applyOne events
  where
    applyOne :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
    applyOne globalEvent =
      let (streamUuid, payload) = unpackGlobalEvent globalEvent
       in case payload of
            TransactionPostingInitiatedEvent evt ->
              case (evt.externalTransactionId, mkTransactionIdSafe streamUuid) of
                (Just extId, Just txId) ->
                  -- insertUnique is a no-op (returns Nothing) when the external
                  -- id already exists, so re-applying an event is idempotent.
                  void $ insertUnique (ImportedTransactionEntity extId txId)
                _ -> pure ()
            _ -> pure ()
