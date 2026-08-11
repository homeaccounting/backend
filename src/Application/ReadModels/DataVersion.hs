{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.DataVersion
-- Description : Pure event -> scope classifier + storage for the data-version signal
--
-- Part of the "data changed" signal (tracker#45): a future persistent read
-- model will, on every committed Account/Transaction event, bump a per-user
-- counter for everyone who can see the affected account. This module holds:
--
--   * the PURE core of that read model: 'classifyEvent' maps one decoded
--     'AccountingEvent' (plus its aggregate stream-key 'UUID') to the
--     accounts, transaction (for accounts to be resolved later via the
--     transaction read model), and extra users it affects; and
--   * the persistent storage layer: the @sync_data_version@ table
--     ('DataVersionEntity'), 'getDataVersion' (a non-mutating read), and
--     'bumpVersions' (an atomic, per-user @+1@, meant to run inside the same
--     DB transaction as the triggering event append so the counter and the
--     event data commit atomically). The counter is an ALWAYS-INCREMENTING
--     per-user value, never a max/'GREATEST' of a global sequence number: a
--     @GREATEST(seqNo)@ would let a late-committing lower-seqNo concurrent
--     transaction clamp to a no-op and silently drop an invalidation. The
--     per-user row lock ('upsert' on the single 'UniqueDataVersionUser' key)
--     serializes concurrent same-user increments so neither clamps the other.
--
-- The effectful handler that wires 'classifyEvent' + 'bumpVersions' into the
-- event-append pipeline, and the eventium 'ReadModel' value, are a later task;
-- this module is not yet registered in 'Application.ReadModels.Persist.persistentReadModels'.
--
-- == Exhaustiveness by construction
--
-- 'classifyEvent' deliberately does NOT pattern-match the flat 'AccountingEvent'
-- with a catch-all. A wildcard there would make the match exhaustive and
-- defeat @-Wincomplete-patterns@, so a future event type would silently map to
-- "no signal" with no compiler warning. Instead, 'AccountingEvent' is
-- projected into 'Maybe' 'AccountEvent' and 'Maybe' 'TransactionEvent' via the
-- 'accountEventEmbedding' / 'transactionEventEmbedding' 'TypeEmbedding's, and
-- 'classifyAccount' / 'classifyTransaction' match those smaller sum types
-- exhaustively with no catch-all. Adding a new Account or Transaction event
-- constructor therefore makes @-Wincomplete-patterns@ (a @-Werror@ warning
-- under the @ci@ Cabal flag) fail the build here until it is classified.
-- Only the genuinely-other aggregates (User/Configuration/ExchangeRate) fall
-- through to 'emptyScope' via a final wildcard in 'classifyEvent' itself.
module Application.ReadModels.DataVersion
  ( EventScope (..),
    emptyScope,
    classifyEvent,
    classifyAccount,
    classifyTransaction,

    -- * Persistent storage
    DataVersionEntity (..),
    migrateDataVersion,
    dataVersionProjectionName,
    getDataVersion,
    bumpVersions,

    -- * Effectful handler + read model
    applyDataVersionEvent,
    dataVersionReadModel,
  )
where

import Application.ReadModels.Account (loadAccessLists)
import Application.ReadModels.Transaction (transactionAccounts)
import Data.UUID (UUID)
import Database.Persist (Entity (..), Filter, deleteWhere, getBy, upsert, (+=.))
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Account.Events (AccountAccessRevoked (..))
import Domain.Account.Projection (AccountEvent (..))
import Domain.Core.Types
  ( AccountAccess (..),
    AccountId,
    TransactionId,
    UserId,
    mkAccountIdSafe,
    mkTransactionIdSafe,
  )
import Domain.Models (AccountingEvent, accountEventEmbedding, transactionEventEmbedding)
import Domain.Transaction.Events
  ( TransactionAllocationsChanged (..),
    TransactionAmendmentCompleted (..),
    TransactionAmendmentInitiated (..),
    TransactionCancellationCompleted (..),
    TransactionCancellationInitiated (..),
    TransactionContactSet (..),
    TransactionDateChanged (..),
    TransactionDescriptionChanged (..),
    TransactionImportReconciled (..),
    TransactionLabelsSet (..),
    TransactionMergeInitiated (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Projection (TransactionEvent (..))
import Eventium
  ( EventHandler (..),
    GlobalStreamEvent,
    ReadModel (..),
    StreamEvent (..),
    TypeEmbedding (..),
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import Infrastructure.Database.Orphans ()
import RIO
import RIO.List (nub)
import qualified RIO.Map as Map

-- | Which accounts/users a single event affects, from the perspective of the
-- data-version signal.
--
-- * 'directAccounts' -- accounts known straight from the event (either the
--   aggregate's own stream key, or account ids carried in the payload).
-- * 'viaTransaction' -- the event only carries a 'TransactionId'; the
--   affected accounts must be resolved from the transaction read model (a
--   later task).
-- * 'extraUsers' -- users affected independently of any account visibility,
--   e.g. a revoked user who is about to lose access and so would otherwise
--   never see their own counter bump again.
data EventScope = EventScope
  { directAccounts :: [AccountId],
    viaTransaction :: Maybe TransactionId,
    extraUsers :: [UserId]
  }
  deriving (Show, Eq)

-- | The scope of an event that affects nothing (a pure system/saga signal, or
-- an event from an aggregate outside Account/Transaction).
emptyScope :: EventScope
emptyScope = EventScope [] Nothing []

-- | Classify a decoded 'AccountingEvent' (plus its aggregate stream-key
-- 'UUID') into the accounts/users it affects.
--
-- Projects into the per-aggregate 'AccountEvent' / 'TransactionEvent' sum
-- types first so the real classification logic can match those smaller types
-- exhaustively (see the module haddock). Only User/Configuration/ExchangeRate
-- events -- genuinely unrelated to this signal -- fall through the final
-- wildcard to 'emptyScope'.
classifyEvent :: UUID -> AccountingEvent -> EventScope
classifyEvent streamKey event
  | Just accountEvent <- accountEventEmbedding.extract event =
      classifyAccount streamKey accountEvent
  | Just transactionEvent <- transactionEventEmbedding.extract event =
      classifyTransaction streamKey transactionEvent
  | otherwise = emptyScope

-- | Classify an 'AccountEvent'. Every Account event affects its own stream-key
-- account; 'AccountAccessRevokedAccountEvent' additionally surfaces the
-- revoked user (they are about to lose access, so they must be signalled
-- directly rather than via the account's access list).
--
-- Matched with no catch-all: adding a new 'AccountEvent' constructor is a
-- compile error here until classified.
classifyAccount :: UUID -> AccountEvent -> EventScope
classifyAccount streamKey accountEvent = case accountEvent of
  AccountCreatedAccountEvent _ -> withStreamKeyAccount
  AccountAccessGrantedAccountEvent _ -> withStreamKeyAccount
  AccountAccessRevokedAccountEvent evt ->
    withStreamKeyAccount {extraUsers = [evt.userId]}
  AccountDebitedAccountEvent _ -> withStreamKeyAccount
  AccountCreditedAccountEvent _ -> withStreamKeyAccount
  OverdraftLimitSetAccountEvent _ -> withStreamKeyAccount
  AccountSubtypeSetAccountEvent _ -> withStreamKeyAccount
  AccountCurrencyChangedAccountEvent _ -> withStreamKeyAccount
  AccountRenamedAccountEvent _ -> withStreamKeyAccount
  AccountDebitReversedAccountEvent _ -> withStreamKeyAccount
  AccountCreditReversedAccountEvent _ -> withStreamKeyAccount
  AccountClosedAccountEvent _ -> withStreamKeyAccount
  AccountReopenedAccountEvent _ -> withStreamKeyAccount
  where
    -- The account id is the aggregate's stream key, never a payload field. A
    -- failed parse should never happen in practice (the stream key is always
    -- a valid AccountId once written); treat it as "no signal" rather than
    -- crashing.
    withStreamKeyAccount = case mkAccountIdSafe streamKey of
      Just accountId -> emptyScope {directAccounts = [accountId]}
      Nothing -> emptyScope

-- | Classify a 'TransactionEvent'.
--
-- Matched with no catch-all: adding a new 'TransactionEvent' constructor is a
-- compile error here until classified.
classifyTransaction :: UUID -> TransactionEvent -> EventScope
classifyTransaction streamKey transactionEvent = case transactionEvent of
  TransactionPostingInitiatedTransactionEvent evt ->
    emptyScope {directAccounts = [evt.sourceAccountId, evt.targetAccountId]}
  -- Pure system/saga signals: no standalone user-visible data change.
  TransactionPostingCompletedTransactionEvent _ -> emptyScope
  TransactionPostingFailedTransactionEvent _ -> emptyScope
  TransactionLabelsSetTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionContactSetTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionAllocationsChangedTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionDescriptionChangedTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionDateChangedTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionAmendmentInitiatedTransactionEvent evt ->
    emptyScope {directAccounts = [evt.newSourceAccountId, evt.newTargetAccountId]}
  TransactionAmendmentCompletedTransactionEvent evt ->
    emptyScope {directAccounts = [evt.newSourceAccountId, evt.newTargetAccountId]}
  -- Saga failure: no leg events were written, the prior transfer is intact.
  TransactionAmendmentFailedTransactionEvent _ -> emptyScope
  TransactionCancellationInitiatedTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionCancellationCompletedTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}
  TransactionMergeInitiatedTransactionEvent evt ->
    emptyScope {directAccounts = [evt.newSourceAccountId, evt.newTargetAccountId]}
  -- Saga completion: the target amend (already classified via
  -- TransactionAmendmentInitiated/Completed) and the per-source Account
  -- Debited/Credited events already carried the balance-visible change.
  TransactionMergeCompletedTransactionEvent _ -> emptyScope
  -- Saga failure: the cascade runs in one transaction and nothing landed.
  TransactionMergeFailedTransactionEvent _ -> emptyScope
  -- The "from" endpoint is the stream key, never a payload field (mirrors
  -- TransactionPostingInitiated's own missing self-id). Known, accepted
  -- asymmetry: only the "from" side is signalled, not the referenced "to".
  TransactionRelationAddedTransactionEvent _ ->
    emptyScope {viaTransaction = mkTransactionIdSafe streamKey}
  TransactionRelationRemovedTransactionEvent _ ->
    emptyScope {viaTransaction = mkTransactionIdSafe streamKey}
  TransactionImportReconciledTransactionEvent evt ->
    emptyScope {viaTransaction = Just evt.transactionId}

-- -----------------------------------------------------------------------------
-- Persistent storage
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateDataVersion"]
  [persistLowerCase|
DataVersionEntity sql=sync_data_version
    userId UserId
    version Int
    UniqueDataVersionUser userId
    deriving Show Eq
|]

-- | Projection/checkpoint name for the (not-yet-wired) data-version read
-- model.
dataVersionProjectionName :: CheckpointName
dataVersionProjectionName = CheckpointName "data_version"

-- | Non-mutating read: a user with no row reads as 0.
getDataVersion :: (MonadIO m) => UserId -> SqlPersistT m Word64
getDataVersion uid = do
  mEnt <- getBy (UniqueDataVersionUser uid)
  pure $ case mEnt of
    Nothing -> 0
    Just (Entity _ e) -> fromIntegral (max 0 e.dataVersionEntityVersion)

-- | +1 per user; idempotent upsert, atomic with the surrounding write txn.
-- The per-user row lock serializes concurrent same-user increments so
-- neither clamps the other (see the module haddock for why this must be an
-- always-incrementing counter, not a max of the global sequence number).
bumpVersions :: (MonadIO m) => [UserId] -> SqlPersistT m ()
bumpVersions users =
  forM_ (nub users) $ \uid ->
    void $ upsert (DataVersionEntity uid 1) [DataVersionEntityVersion +=. 1]

-- -----------------------------------------------------------------------------
-- Effectful handler + read model
-- -----------------------------------------------------------------------------

-- | Apply a single committed event: classify it into an 'EventScope', resolve
-- that scope to the concrete users who must see their counter bump, and bump
-- them.
--
-- Account resolution: 'directAccounts' plus (when 'viaTransaction' is set)
-- the accounts of that transaction, via 'transactionAccounts'.
--
-- User resolution: the union, over every resolved account, of everyone with
-- an @account_access@ row on it (owner + editors + viewers), via the existing
-- batched 'loadAccessLists' -- never a per-account N+1. This is also the
-- External-sentinel guard: income/expense 'TransactionPostingInitiated'
-- events carry the user's own External bookkeeping account on the opposite
-- leg (see 'Application.Services.TransactionService'), and External accounts
-- can never be shared (see 'Application.Services.AccountService'), so their
-- only @account_access@ row is ever the owner's own -- resolving accessors
-- over that leg can never leak the signal to another user.
--
-- 'extraUsers' (currently just the revoked user on 'AccountAccessRevoked')
-- are added on top, since they must be signalled directly rather than via an
-- access list they have just been removed from.
applyDataVersionEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyDataVersionEvent ge = do
  let inner = ge.payload
      scope = classifyEvent inner.key inner.payload
  viaAccs <- maybe (pure []) transactionAccounts scope.viaTransaction
  let accIds = nub (scope.directAccounts <> viaAccs)
  accessMap <- loadAccessLists accIds
  let accessors = [a.userId | accs <- Map.elems accessMap, a <- accs]
  bumpVersions (accessors <> scope.extraUsers)

-- | The eventium 'ReadModel' value tying 'classifyEvent' + 'bumpVersions'
-- together. Not yet registered in 'Application.ReadModels.Persist.persistentReadModels'
-- (a later task).
dataVersionReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
dataVersionReadModel =
  ReadModel
    { initialize = void (runMigrationSilent migrateDataVersion),
      eventHandler = EventHandler applyDataVersionEvent,
      checkpointStore = postgresqlCheckpointStore dataVersionProjectionName,
      reset = deleteWhere ([] :: [Filter DataVersionEntity])
    }
