{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Application.ReadModels.Transaction
-- Description : Persistent, indexed read model for transaction queries
--
-- Transactions are projected into two Postgres tables:
--
--   * @transactions@ — one row per transaction (legs, amounts, exchange rate,
--     description, status, type, business date, amendment count, version), and
--   * @transaction_labels@ — the many-to-many label set, indexed by label so the
--     in-use deletion guard and label filters are indexed lookups.
--
-- The projection is an eventium 'ReadModel' ('transactionReadModel') driven
-- synchronously in the event-append transaction. Per-row @version@ is recorded
-- from the event's real per-stream 'EventVersion' (not derived by incrementing).
-- Queries are scoped to the caller's visible accounts via indexed SQL, replacing
-- the former full-map scans (@listTransactions@, reporting).
module Application.ReadModels.Transaction
  ( -- * Query result type
    TransactionData (..),

    -- * Query filter
    TransactionFilter (..),
    mkTransactionFilter,
    emptyTransactionFilter,

    -- * Read model
    transactionReadModel,
    transactionProjectionName,
    migrateTransaction,
    resetTransaction,
    applyTransactionEvent,
    TransactionEntity (..),
    TransactionLabelEntity (..),
    TransactionRelationEntity (..),

    -- * Queries (run via 'runDb')
    getTransaction,
    listTransactions,
    transactionDatesForAccount,
    findReferencingTransactions,
    reportableTransactions,
    countTransactions,
    relationsFrom,
    relationsFromMany,
    reverseRelations,
    relationsTo,

    -- * Helpers
    touchesVisible,
  )
where

import Control.Monad (forM_, void)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.Persist
  ( Entity (..),
    Filter (..),
    SelectOpt (Asc, Desc, LimitTo, OffsetBy),
    count,
    deleteWhere,
    getBy,
    insertUnique,
    replace,
    selectList,
    (!=.),
    (<-.),
    (<=.),
    (==.),
    (>=.),
  )
import Database.Persist.Sql (SqlPersistT, rawExecute, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Core.Page (Page (..))
import Domain.Core.Range (Range (..))
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    ContactId,
    DictionaryEntryId,
    ExchangeRate,
    LabelId,
    MCC,
    Money,
    RelationKind (..),
    TransactionId,
    TransactionType,
    allAllocations,
    allocationsOf,
    importInfoMcc,
    mkTransactionIdSafe,
    replaceAllocations,
  )
-- Event record types imported with @(..)@ so their field labels are in scope —
-- 'OverloadedRecordDot' (@evt.sourceAccountId@ etc.) needs the label visible
-- under @DuplicateRecordFields@, since 'TransactionData' shares some names.
import Domain.Models
  ( AccountingEvent (..),
    TransactionAllocationsChanged (..),
    TransactionAmendmentCompleted (..),
    TransactionContactSet (..),
    TransactionDateChanged (..),
    TransactionDescriptionChanged (..),
    TransactionLabelsSet (..),
    TransactionPostingFailed (..),
    TransactionPostingInitiated (..),
    TransactionRelationAdded (..),
    TransactionRelationRemoved (..),
  )
import Domain.Transaction.Projection (StatusKind (..), TransactionStatus (..), statusFromKind)
import Eventium
  ( EventHandler (..),
    EventVersion (..),
    GlobalStreamEvent,
    ReadModel (..),
    StreamEvent (..),
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import GHC.Generics (Generic)
import Infrastructure.Database.Orphans ()

-- -----------------------------------------------------------------------------
-- Query result type
-- -----------------------------------------------------------------------------

-- | Denormalized transaction information returned by queries. @labels@ is
-- assembled from the @transaction_labels@ rows; @status@ is reconstructed from
-- the stored 'StatusKind' plus the optional failure reason.
data TransactionData = TransactionData
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    status :: TransactionStatus,
    transactionType :: TransactionType,
    date :: UTCTime,
    -- | Original provider MCC for imported transactions; 'Nothing' for manual
    -- entries and providers that supply no MCC.
    mcc :: Maybe MCC,
    labels :: Set LabelId,
    -- | Optional contact (payee/payer) associated with this transaction.
    -- 'Nothing' when no contact is set.
    contactId :: Maybe ContactId,
    -- | Outbound typed relationship edges declared by this transaction as
    -- @(relatedTransactionId, kind)@ — e.g. a 'Refund' edge to the expense it
    -- refunds. Assembled from the @transaction_relations@ rows (batch-loaded on
    -- every query path, mirroring 'labels'). Empty when none are declared.
    relations :: [(TransactionId, RelationKind)],
    -- | Count of 'TransactionAmendmentCompleted' events folded on this
    -- transaction. @0@ when never amended.
    amendmentCount :: Word
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionData

instance FromJSON TransactionData

-- -----------------------------------------------------------------------------
-- Query filter
-- -----------------------------------------------------------------------------

-- | Standardized transaction query filter. Each field is an optional
-- constraint; 'Nothing' means "no constraint on this field". Build values via
-- 'mkTransactionFilter' or 'emptyTransactionFilter'; read fields via dot access.
data TransactionFilter = TransactionFilter
  { accountId :: Maybe AccountId,
    -- | Inclusive business-date range. Named 'dateRange' (not 'date') to
    -- avoid a 'DuplicateRecordFields' collision with 'TransactionData.date'.
    dateRange :: Maybe (Range UTCTime),
    -- | Status set (IN). Named 'statuses' (not 'status') to avoid a collision
    -- with 'TransactionData.status'.
    statuses :: Maybe (NE.NonEmpty StatusKind),
    label :: Maybe (NE.NonEmpty LabelId)
  }
  deriving (Show, Eq)

-- | Assemble a filter. Cross-field validation (date @from <= to@) is the
-- caller's responsibility via 'Domain.Core.Range.mkRange' at the boundary.
mkTransactionFilter ::
  Maybe AccountId ->
  Maybe (Range UTCTime) ->
  Maybe (NE.NonEmpty StatusKind) ->
  Maybe (NE.NonEmpty LabelId) ->
  TransactionFilter
mkTransactionFilter a d s l =
  TransactionFilter {accountId = a, dateRange = d, statuses = s, label = l}

-- | A filter with no constraints (every visible transaction matches).
emptyTransactionFilter :: TransactionFilter
emptyTransactionFilter = TransactionFilter Nothing Nothing Nothing Nothing

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateTransaction"]
  [persistLowerCase|
TransactionEntity sql=transactions
    transactionId TransactionId
    sourceAccountId AccountId
    targetAccountId AccountId
    sourceAmount Money
    targetAmount Money
    exchangeRate ExchangeRate Maybe
    description Text
    statusKind StatusKind
    failureReason Text Maybe
    transactionType TransactionType
    date UTCTime
    mcc Text Maybe
    contactId DictionaryEntryId Maybe
    amendmentCount Int
    version EventVersion
    UniqueTransactionId transactionId
    deriving Show Eq
TransactionLabelEntity sql=transaction_labels
    transactionId TransactionId
    labelId LabelId
    UniqueTransactionLabel transactionId labelId
    deriving Show Eq
TransactionRelationEntity sql=transaction_relations
    transactionId TransactionId
    relatedTransactionId TransactionId
    relationKind RelationKind
    UniqueTransactionRelation transactionId relatedTransactionId relationKind
    deriving Show Eq
|]

-- | Projection/checkpoint name for this read model.
transactionProjectionName :: CheckpointName
transactionProjectionName = CheckpointName "transaction"

-- | Clear both transaction tables. The checkpoint is reset by 'rebuildReadModel'.
resetTransaction :: (MonadIO m) => SqlPersistT m ()
resetTransaction = do
  deleteWhere ([] :: [Filter TransactionRelationEntity])
  deleteWhere ([] :: [Filter TransactionLabelEntity])
  deleteWhere ([] :: [Filter TransactionEntity])

-- | Secondary indexes the query layer relies on. Persistent's quasi-quoter only
-- emits the unique constraints, so the lookup/filter columns get explicit
-- @CREATE INDEX IF NOT EXISTS@ (valid on both PostgreSQL and SQLite) at startup.
createTransactionIndexes :: (MonadIO m) => SqlPersistT m ()
createTransactionIndexes =
  forM_ stmts $ \s -> rawExecute s []
  where
    stmts =
      [ "CREATE INDEX IF NOT EXISTS idx_transactions_source ON transactions (source_account_id)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_target ON transactions (target_account_id)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_date ON transactions (date)",
        "CREATE INDEX IF NOT EXISTS idx_transaction_labels_label ON transaction_labels (label_id)",
        "CREATE INDEX IF NOT EXISTS idx_transaction_relations_from ON transaction_relations (transaction_id)",
        "CREATE INDEX IF NOT EXISTS idx_transaction_relations_to_kind ON transaction_relations (related_transaction_id, relation_kind)"
      ]

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

transactionReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
transactionReadModel =
  ReadModel
    { initialize = do
        void (runMigrationSilent migrateTransaction)
        createTransactionIndexes,
      eventHandler = EventHandler applyTransactionEvent,
      checkpointStore = postgresqlCheckpointStore transactionProjectionName,
      reset = resetTransaction
    }

-- | Apply a single global event to the transaction tables. The per-stream
-- version (@globalEvent.payload.position@) is recorded as the row @version@.
-- Total and idempotent: row inserts are keyed by 'UniqueTransactionId', the
-- label set is fully replaced, and amendment count is the only accumulator
-- (incremented once per completed amendment under the synchronous driver).
applyTransactionEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyTransactionEvent globalEvent =
  let inner = globalEvent.payload
      ver = inner.position
   in case mkTransactionIdSafe inner.key of
        Nothing -> pure ()
        Just txId -> case inner.payload of
          TransactionPostingInitiatedEvent evt -> do
            -- insertUnique (not repsert) so a terminal event already applied
            -- out of order is never clobbered back to Pending.
            inserted <-
              insertUnique
                TransactionEntity
                  { transactionEntityTransactionId = txId,
                    transactionEntitySourceAccountId = evt.sourceAccountId,
                    transactionEntityTargetAccountId = evt.targetAccountId,
                    transactionEntitySourceAmount = evt.sourceAmount,
                    transactionEntityTargetAmount = evt.targetAmount,
                    transactionEntityExchangeRate = evt.exchangeRate,
                    transactionEntityDescription = evt.description,
                    transactionEntityStatusKind = PendingKind,
                    transactionEntityFailureReason = Nothing,
                    transactionEntityTransactionType = evt.transactionType,
                    transactionEntityDate = evt.at,
                    transactionEntityMcc = evt.importInfo >>= importInfoMcc,
                    transactionEntityContactId = evt.contactId,
                    transactionEntityAmendmentCount = 0,
                    transactionEntityVersion = ver
                  }
            case inserted of
              Nothing -> pure ()
              Just _ -> setLabels txId (Set.toList evt.labels)
          TransactionPostingCompletedEvent _ ->
            modifyTx txId (\e -> e {transactionEntityStatusKind = CompletedKind, transactionEntityVersion = ver})
          TransactionPostingFailedEvent evt ->
            modifyTx txId (\e -> e {transactionEntityStatusKind = FailedKind, transactionEntityFailureReason = Just evt.reason, transactionEntityVersion = ver})
          TransactionLabelsSetEvent evt -> do
            setLabels txId (Set.toList evt.labels)
            modifyTx txId (\e -> e {transactionEntityVersion = ver})
          TransactionContactSetEvent evt ->
            modifyTx txId (\e -> e {transactionEntityContactId = evt.contactId, transactionEntityVersion = ver})
          TransactionAllocationsChangedEvent evt ->
            modifyTx txId (\e -> e {transactionEntityTransactionType = replaceAllocations evt.newAllocations e.transactionEntityTransactionType, transactionEntityVersion = ver})
          TransactionDescriptionChangedEvent evt ->
            modifyTx txId (\e -> e {transactionEntityDescription = evt.newDescription, transactionEntityVersion = ver})
          TransactionDateChangedEvent evt ->
            modifyTx txId (\e -> e {transactionEntityDate = evt.newAt, transactionEntityVersion = ver})
          TransactionAmendmentCompletedEvent evt ->
            modifyTx
              txId
              ( \e ->
                  e
                    { transactionEntitySourceAccountId = evt.newSourceAccountId,
                      transactionEntityTargetAccountId = evt.newTargetAccountId,
                      transactionEntitySourceAmount = evt.newSourceAmount,
                      transactionEntityTargetAmount = evt.newTargetAmount,
                      transactionEntityExchangeRate = evt.newExchangeRate,
                      transactionEntityTransactionType = evt.newTransactionType,
                      transactionEntityContactId = evt.contactId,
                      transactionEntityAmendmentCount = e.transactionEntityAmendmentCount + 1,
                      transactionEntityVersion = ver
                    }
              )
          TransactionCancellationCompletedEvent _ ->
            modifyTx txId (\e -> e {transactionEntityStatusKind = CancelledKind, transactionEntityVersion = ver})
          -- saga-internal markers / informational: no canonical change
          TransactionAmendmentInitiatedEvent _ -> pure ()
          TransactionAmendmentFailedEvent _ -> pure ()
          TransactionCancellationInitiatedEvent _ -> pure ()
          TransactionRelationAddedEvent evt ->
            void (insertUnique (TransactionRelationEntity txId evt.relatedTransactionId evt.relationKind))
          TransactionRelationRemovedEvent evt ->
            deleteWhere
              [ TransactionRelationEntityTransactionId ==. txId,
                TransactionRelationEntityRelatedTransactionId ==. evt.relatedTransactionId,
                TransactionRelationEntityRelationKind ==. evt.relationKind
              ]
          _ -> pure ()

-- | Read-modify-write a transaction row (no-op if absent).
modifyTx :: (MonadIO m) => TransactionId -> (TransactionEntity -> TransactionEntity) -> SqlPersistT m ()
modifyTx txId f = do
  mEnt <- getBy (UniqueTransactionId txId)
  case mEnt of
    Nothing -> pure ()
    Just (Entity k e) -> replace k (f e)

-- | Replace the full label set for a transaction (delete then insert).
setLabels :: (MonadIO m) => TransactionId -> [LabelId] -> SqlPersistT m ()
setLabels txId ls = do
  deleteWhere [TransactionLabelEntityTransactionId ==. txId]
  forM_ ls $ \l -> void (insertUnique (TransactionLabelEntity txId l))

-- -----------------------------------------------------------------------------
-- Reconstruction
-- -----------------------------------------------------------------------------

entToData :: TransactionEntity -> [LabelId] -> [(TransactionId, RelationKind)] -> TransactionData
entToData e ls rels =
  TransactionData
    { sourceAccountId = e.transactionEntitySourceAccountId,
      targetAccountId = e.transactionEntityTargetAccountId,
      sourceAmount = e.transactionEntitySourceAmount,
      targetAmount = e.transactionEntityTargetAmount,
      exchangeRate = e.transactionEntityExchangeRate,
      description = e.transactionEntityDescription,
      status = statusFromKind e.transactionEntityStatusKind e.transactionEntityFailureReason,
      transactionType = e.transactionEntityTransactionType,
      date = e.transactionEntityDate,
      mcc = e.transactionEntityMcc,
      labels = Set.fromList ls,
      contactId = e.transactionEntityContactId,
      relations = rels,
      amendmentCount = fromIntegral (max 0 e.transactionEntityAmendmentCount)
    }

-- | Labels for one transaction.
loadLabels :: (MonadIO m) => TransactionId -> SqlPersistT m [LabelId]
loadLabels txId = do
  rows <- selectList [TransactionLabelEntityTransactionId ==. txId] []
  pure [r.transactionLabelEntityLabelId | Entity _ r <- rows]

-- | Labels for many transactions in a single indexed query, grouped by
-- transaction (avoids the N+1 of 'loadLabels' per row).
loadLabelsMany :: (MonadIO m) => [TransactionId] -> SqlPersistT m (Map TransactionId [LabelId])
loadLabelsMany [] = pure Map.empty
loadLabelsMany txIds = do
  rows <- selectList [TransactionLabelEntityTransactionId <-. txIds] []
  pure $
    Map.fromListWith
      (<>)
      [(r.transactionLabelEntityTransactionId, [r.transactionLabelEntityLabelId]) | Entity _ r <- rows]

-- | Materialize a page of entity rows into '(id, TransactionData)' pairs,
-- batch-loading their labels and outbound relations (each a single indexed
-- query — no N+1).
withLabels :: (MonadIO m) => [Entity TransactionEntity] -> SqlPersistT m [(TransactionId, TransactionData)]
withLabels rows = do
  let ids = [e.transactionEntityTransactionId | Entity _ e <- rows]
  labelMap <- loadLabelsMany ids
  relMap <- relationsFromMany ids
  pure
    [ ( tid,
        entToData
          e
          (Map.findWithDefault [] tid labelMap)
          (Map.findWithDefault [] tid relMap)
      )
    | Entity _ e <- rows,
      let tid = e.transactionEntityTransactionId
    ]

-- -----------------------------------------------------------------------------
-- Queries
-- -----------------------------------------------------------------------------

-- | Total number of transactions in the read model (an unfiltered @COUNT(*)@).
-- Not a per-tenant data scan; useful for ops/health checks and tests.
countTransactions :: (MonadIO m) => SqlPersistT m Int
countTransactions = count ([] :: [Filter TransactionEntity])

-- | Transaction by id, with its labels and outbound relations, or 'Nothing'.
getTransaction :: (MonadIO m) => TransactionId -> SqlPersistT m (Maybe TransactionData)
getTransaction txId = do
  mEnt <- getBy (UniqueTransactionId txId)
  case mEnt of
    Nothing -> pure Nothing
    Just (Entity _ e) -> do
      ls <- loadLabels txId
      rels <- relationsFrom txId
      pure (Just (entToData e ls rels))

-- | List transactions visible to the caller (touching at least one account in
-- @visible@ on either leg), filtered by 'TransactionFilter' and paginated by
-- 'Page'. Returns @(totalMatches, pageSlice)@; @totalMatches@ counts all matches
-- before slicing. All predicates run as indexed SQL — never a full scan over
-- other tenants' transactions. Ordered by date descending, ties by id.
listTransactions ::
  (MonadIO m) =>
  Set AccountId ->
  TransactionFilter ->
  Page ->
  SqlPersistT m (Int, [(TransactionId, TransactionData)])
listTransactions visible filt page
  | Set.null visible = pure (0, [])
  | otherwise = do
      mLabelTxIds <- resolveLabelFilter filt.label
      case mLabelTxIds of
        Just [] -> pure (0, []) -- label filter present, nothing matches
        _ -> do
          let filters = baseVisible visible ++ accountFilter filt.accountId ++ dateFilters filt.dateRange ++ statusFilters filt.statuses ++ labelFilters mLabelTxIds
          total <- count filters
          rows <-
            selectList
              filters
              [Desc TransactionEntityDate, Asc TransactionEntityTransactionId, OffsetBy page.offset, LimitTo page.limit]
          slice <- withLabels rows
          pure (total, slice)

-- | The set of transaction ids carrying a given label, or 'Nothing' when no
-- label filter is requested.
resolveLabelFilter :: (MonadIO m) => Maybe (NE.NonEmpty LabelId) -> SqlPersistT m (Maybe [TransactionId])
resolveLabelFilter Nothing = pure Nothing
resolveLabelFilter (Just ls) = do
  rows <- selectList [TransactionLabelEntityLabelId <-. NE.toList ls] []
  pure (Just (Set.toList (Set.fromList [r.transactionLabelEntityTransactionId | Entity _ r <- rows])))

-- | The visibility precondition as a single OR-group: source OR target leg in
-- the visible set.
baseVisible :: Set AccountId -> [Filter TransactionEntity]
baseVisible visible =
  let vis = Set.toList visible
   in [FilterOr [TransactionEntitySourceAccountId <-. vis, TransactionEntityTargetAccountId <-. vis]]

accountFilter :: Maybe AccountId -> [Filter TransactionEntity]
accountFilter Nothing = []
accountFilter (Just a) = [FilterOr [TransactionEntitySourceAccountId ==. a, TransactionEntityTargetAccountId ==. a]]

dateFilters :: Maybe (Range UTCTime) -> [Filter TransactionEntity]
dateFilters Nothing = []
dateFilters (Just r) =
  maybe [] (\f -> [TransactionEntityDate >=. f]) r.from
    ++ maybe [] (\t -> [TransactionEntityDate <=. t]) r.to

statusFilters :: Maybe (NE.NonEmpty StatusKind) -> [Filter TransactionEntity]
statusFilters Nothing = []
statusFilters (Just ks) = [TransactionEntityStatusKind <-. NE.toList ks]

labelFilters :: Maybe [TransactionId] -> [Filter TransactionEntity]
labelFilters (Just txIds) = [TransactionEntityTransactionId <-. txIds]
labelFilters Nothing = []

-- | Map of @transactionId -> business date@ for every transaction touching the
-- given account on either leg, regardless of status. Powers the balance-as-of
-- fold (which needs the effective date of each leg's transaction) without
-- scanning every tenant's transactions.
transactionDatesForAccount :: (MonadIO m) => AccountId -> SqlPersistT m (Map TransactionId UTCTime)
transactionDatesForAccount accId = do
  rows <- selectList [FilterOr [TransactionEntitySourceAccountId ==. accId, TransactionEntityTargetAccountId ==. accId]] []
  pure $ Map.fromList [(e.transactionEntityTransactionId, e.transactionEntityDate) | Entity _ e <- rows]

-- | Count transactions that reference the given dictionary entry id — as a label
-- (indexed @transaction_labels@ lookup), as an allocation category, or as the
-- transaction's contact (the @transactions.contact_id@ scalar column) — and
-- are not 'Failed'. Powers the in-use check that blocks deleting a
-- dictionary entry.
--
-- 'Cancelled' transactions DO count: they remain retrievable via the API, so a
-- dictionary entry they still reference must stay resolvable — deleting it
-- would break that lookup. 'Failed' transactions never posted, so their
-- references never blocked anything and don't count here either.
--
-- This is intentionally account-agnostic: the guard must catch a reference from
-- /any/ transaction, and a transaction's accounts are unrelated to which
-- configuration owns the entry (the entry id is a globally-unique UUID, so only
-- the genuinely-referencing transactions match). The label path is the indexed
-- @transaction_labels.label_id@ lookup; the allocation path deserializes the
-- eligible rows' @transactionType@ — a bounded scan acceptable for this
-- rare deletion-time guard. A fully-indexed allocation path would require a
-- normalized @transaction_categories@ table (spec out-of-scope follow-up).
findReferencingTransactions :: (MonadIO m) => DictionaryEntryId -> SqlPersistT m Int
findReferencingTransactions entryId = do
  eligible <- selectList [TransactionEntityStatusKind !=. FailedKind] []
  let eligibleIds = Set.fromList [e.transactionEntityTransactionId | Entity _ e <- eligible]
      allocRefs =
        Set.fromList
          [ e.transactionEntityTransactionId
          | Entity _ e <- eligible,
            referencesEntry entryId e.transactionEntityTransactionType
          ]
      contactRefs =
        Set.fromList
          [ e.transactionEntityTransactionId
          | Entity _ e <- eligible,
            e.transactionEntityContactId == Just entryId
          ]
  labelRows <- selectList [TransactionLabelEntityLabelId ==. entryId] []
  let labelRefs =
        Set.intersection eligibleIds $
          Set.fromList [r.transactionLabelEntityTransactionId | Entity _ r <- labelRows]
  pure (Set.size (Set.unions [allocRefs, labelRefs, contactRefs]))
  where
    referencesEntry eid tt = case allocationsOf tt of
      Nothing -> False
      Just allocs -> any (\(Allocation cid _ _) -> cid == eid) (allAllocations allocs)

-- | Transactions eligible for reporting: 'Completed', touching a visible
-- account, within the optional inclusive business-date window. Returned as
-- 'TransactionData' (with labels) for the pure base-currency aggregations in
-- 'Application.Services.ReportingService'. Replaces the former full-map scan.
reportableTransactions ::
  (MonadIO m) =>
  Set AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  SqlPersistT m [TransactionData]
reportableTransactions visible mFrom mTo
  | Set.null visible = pure []
  | otherwise = do
      let filters =
            baseVisible visible
              ++ [TransactionEntityStatusKind ==. CompletedKind]
              ++ maybe [] (\f -> [TransactionEntityDate >=. f]) mFrom
              ++ maybe [] (\t -> [TransactionEntityDate <=. t]) mTo
      rows <- selectList filters []
      map snd <$> withLabels rows

-- -----------------------------------------------------------------------------
-- Relation queries
-- -----------------------------------------------------------------------------

-- | Outbound edges declared by a transaction: (relatedTransactionId, kind).
relationsFrom :: (MonadIO m) => TransactionId -> SqlPersistT m [(TransactionId, RelationKind)]
relationsFrom txId = do
  rows <- selectList [TransactionRelationEntityTransactionId ==. txId] []
  pure [(r.transactionRelationEntityRelatedTransactionId, r.transactionRelationEntityRelationKind) | Entity _ r <- rows]

-- | Outbound edges for many transactions in one query (avoids N+1 on list responses).
relationsFromMany :: (MonadIO m) => [TransactionId] -> SqlPersistT m (Map TransactionId [(TransactionId, RelationKind)])
relationsFromMany [] = pure Map.empty
relationsFromMany txIds = do
  rows <- selectList [TransactionRelationEntityTransactionId <-. txIds] []
  pure $
    Map.fromListWith
      (<>)
      [ ( r.transactionRelationEntityTransactionId,
          [(r.transactionRelationEntityRelatedTransactionId, r.transactionRelationEntityRelationKind)]
        )
      | Entity _ r <- rows
      ]

-- | Inbound edges of a given kind pointing at a transaction. For 'Refund' the
-- cancelled-"from" edges are skipped (auto-orphan, decision 3); for 'Merge'/'Split'
-- the "from" is deliberately cancelled (lineage) and is kept.
-- e.g. refundsOf = reverseRelations _ Refund.
reverseRelations :: (MonadIO m) => TransactionId -> RelationKind -> SqlPersistT m [TransactionId]
reverseRelations txId kind = do
  rows <- selectList [TransactionRelationEntityRelatedTransactionId ==. txId, TransactionRelationEntityRelationKind ==. kind] []
  let froms = [r.transactionRelationEntityTransactionId | Entity _ r <- rows]
  if kind == Refund then nonCancelledTransactions froms else pure froms

-- | All inbound edges (any kind) pointing at a transaction. Refund edges from a
-- Cancelled source are skipped; Merge/Split lineage is kept even when cancelled.
relationsTo :: (MonadIO m) => TransactionId -> SqlPersistT m [(TransactionId, RelationKind)]
relationsTo txId = do
  rows <- selectList [TransactionRelationEntityRelatedTransactionId ==. txId] []
  let pairs = [(r.transactionRelationEntityTransactionId, r.transactionRelationEntityRelationKind) | Entity _ r <- rows]
      refundFroms = [f | (f, Refund) <- pairs]
  liveRefund <- Set.fromList <$> nonCancelledTransactions refundFroms
  pure [p | p@(f, k) <- pairs, k /= Refund || Set.member f liveRefund]

-- | Filter a list of "from" transaction ids down to those NOT Cancelled.
nonCancelledTransactions :: (MonadIO m) => [TransactionId] -> SqlPersistT m [TransactionId]
nonCancelledTransactions [] = pure []
nonCancelledTransactions ids = do
  rows <- selectList [TransactionEntityTransactionId <-. ids, TransactionEntityStatusKind !=. CancelledKind] []
  pure [e.transactionEntityTransactionId | Entity _ e <- rows]

-- -----------------------------------------------------------------------------
-- Pure helpers
-- -----------------------------------------------------------------------------

-- | Whether a transaction touches at least one account in the visible set, on
-- either its source or target leg. Retained for the pure reporting filter
-- ('Application.Services.ReportingService.reportableTxns') and its unit tests.
touchesVisible :: Set AccountId -> TransactionData -> Bool
touchesVisible visible td =
  Set.member td.sourceAccountId visible
    || Set.member td.targetAccountId visible
