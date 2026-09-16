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
-- Indexes external transaction IDs from 'TransactionPostingInitiated' and
-- 'TransactionImportReconciled' events into the @imported_transactions@ table, so
-- the bank import service can detect and skip duplicate imports.
--
-- Key components:
--   - 'ImportedTransactionEntity': @imported_transactions@ row (external id -> internal tx id)
--   - 'isImported': SQL membership check used during bank statement import
--   - 'importAttributionCount': reverse lookup (by internal tx id) — how many
--     external ids are attributed to a transaction, which reconciliation weighs
--     against the transaction's capacity to decide whether another may attach
--   - 'isReconciled': the same lookup as a boolean; test-facing only
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
--   - External ids are normalized on apply ('normalizePrivatBankRetailId'), so a
--     provider-synthesized id stored under a superseded derivation still matches
--     the current one. Deploying such a change therefore needs one
--     @REBUILD_READ_MODELS=bankimport@ startup and no event rewriting. A statement
--     line imported both before and after the derivation change will have both its
--     events normalize to the same key, so 'insertUnique' keeps the lower-sequence
--     row and the later duplicate gains zero attribution (becoming a reconciliation
--     candidate) — the intended outcome.
module Application.ReadModels.BankImportReadModel
  ( ImportedTransactionEntity (..),
    ImportedTransactionEntityId,
    bankImportProjectionName,
    migrateBankImport,
    resetBankImport,
    bankImportReadModel,
    isImported,
    isReconciled,
    applyBankImportEvent,
    importAttributionCount,
  )
where

import Control.Monad (forM_, void)
import Control.Monad.IO.Class (MonadIO)
import Data.Maybe (isJust)
import Database.Persist (Filter, count, deleteWhere, getBy, insertUnique, (==.))
import Database.Persist.Sql (SqlPersistT, rawExecute, runMigrationSilent)
import Database.Persist.TH
  ( mkMigrate,
    mkPersist,
    persistLowerCase,
    share,
    sqlSettings,
  )
import Domain.Banking.Import (ExternalTransactionId, importInfoExternalTransactionIds)
import Domain.Core.Types (TransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionImportReconciled (..), TransactionPostingInitiated (..))
import Eventium (EventHandler (..), GlobalStreamEvent, ReadModel (..))
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import Infrastructure.Banking.ExternalId (normalizePrivatBankRetailId)
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

-- | Whether an external transaction id has already been imported. The argument
-- is assumed to be in canonical form as produced by the current parser;
-- comparing against a stored or user-supplied id is a silent-miss failure mode.
isImported :: (MonadIO m) => ExternalTransactionId -> SqlPersistT m Bool
isImported extId = isJust <$> getBy (UniqueExternalTransactionId extId)

-- | How many external ids are attributed to a transaction. Reconciliation
-- compares this against the transaction's capacity: an income/expense holds one
-- attribution, a transfer holds two (one per leg), so a transfer that already
-- absorbed one leg can still absorb the other.
importAttributionCount :: (MonadIO m) => TransactionId -> SqlPersistT m Int
importAttributionCount txId =
  count [ImportedTransactionEntityTransactionId ==. txId]

-- | Whether a transaction carries any import attribution at all. Has no
-- production caller: reconciliation weighs 'importAttributionCount' against
-- 'Domain.Core.Types.importAttributionCapacity' rather than gating on a boolean,
-- which is what lets a transfer take one attribution per leg. Retained as the
-- existence predicate the specs assert with.
isReconciled :: (MonadIO m) => TransactionId -> SqlPersistT m Bool
isReconciled txId = (> 0) <$> importAttributionCount txId

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

-- | Idempotent projection apply for a single global event: for every
-- 'TransactionPostingInitiated' carrying import info, records one
-- external-id -> internal-tx-id row per external id (a normal import has one; a
-- detected internal transfer has both legs' ids, all mapping to the same
-- transaction). 'TransactionImportReconciled' is projected the same way, so a
-- manual transaction later reconciled against a bank import gains its external
-- id(s) in the dedup table (a subsequent re-sync then skips via 'isImported').
-- 'insertUnique' (keyed by the external id) makes re-application a no-op.
applyBankImportEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyBankImportEvent globalEvent =
  let (streamUuid, payload) = unpackGlobalEvent globalEvent
   in case payload of
        TransactionPostingInitiatedEvent evt ->
          case (importInfoExternalTransactionIds <$> evt.importInfo, mkTransactionIdSafe streamUuid) of
            (Just extIds, Just txId) -> record txId extIds
            _ -> pure ()
        TransactionImportReconciledEvent evt ->
          case mkTransactionIdSafe streamUuid of
            Just txId -> record txId evt.externalTransactionIds
            Nothing -> pure ()
        _ -> pure ()
  where
    -- Ids are normalized on the way IN to the view, not by rewriting the log:
    -- a PrivatBank retail id written before commit 38968e9 lands on today's
    -- derivation, so 'isImported' matches what the parser now produces
    -- (backend#3 / ADR 004). Doing it here rather than as a one-off table
    -- migration keeps a rebuild correct, and it is idempotent.
    record txId extIds =
      forM_ extIds $ \extId ->
        void $ insertUnique (ImportedTransactionEntity (normalizePrivatBankRetailId extId) txId)

-- | Secondary indexes the query layer relies on. Persistent's quasi-quoter only
-- emits the unique constraint on the external id, so the @transaction_id@ column
-- backing the 'importAttributionCount' reverse lookup gets an explicit
-- @CREATE INDEX IF NOT EXISTS@ (valid on both PostgreSQL and SQLite) at startup.
createBankImportIndexes :: (MonadIO m) => SqlPersistT m ()
createBankImportIndexes =
  forM_ stmts $ \s -> rawExecute s []
  where
    stmts =
      [ "CREATE INDEX IF NOT EXISTS idx_imported_transactions_tx ON imported_transactions (transaction_id)"
      ]

-- | The bank-import dedup as an eventium 'ReadModel'. Driven synchronously in the
-- event-append transaction via 'readModelPublisher' (real global positions,
-- checkpoint advanced in-line), and brought up to date / rebuilt at startup via
-- 'catchUpReadModel' / 'rebuildReadModel'.
bankImportReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
bankImportReadModel =
  ReadModel
    { initialize = do
        void (runMigrationSilent migrateBankImport)
        createBankImportIndexes,
      eventHandler = EventHandler applyBankImportEvent,
      checkpointStore = postgresqlCheckpointStore bankImportProjectionName,
      -- Only drop view data; rebuildReadModel resets the checkpoint itself.
      reset = resetBankImport
    }
