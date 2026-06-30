---
status: completed
---

# Persistent Read Models — Phase 3: Transaction

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development for each task. Steps use `- [ ]` checkboxes.

**Goal:** Migrate the **Transaction** read model from a single in-memory `TVar (Map TransactionId TransactionData)` to persistent, indexed Postgres tables (`transactions` + `transaction_labels`), driven by the eventium dual-mode `ReadModel` already wired in Phase 2 — eliminating the `listTransactions` and reporting full-map scans.

**Architecture:** Follows the Phase 2 Account template exactly (`docs/plans/2026-06-26-persistent-read-models-account.md`, merged in #112). Transaction becomes an eventium `ReadModel (SqlPersistT IO) AccountingEvent` registered in `Application.ReadModels.Persist.persistentReadModels`, projected synchronously in the event-append transaction. Per-row `version` is recorded from the event's real per-stream `EventVersion`. Queries become indexed `SqlPersistT` lookups scoped to the caller's visible accounts; the in-memory `transactionReadModel` field is removed from `AppEnv`/`HasReadModel`/`EventDispatch`.

**Spec:** `docs/specs/2026-06-25-persistent-read-models-design.md` (rollout step 3; Transaction table sketch in the per-read-model schema table).

**Tech Stack:** Haskell (GHC 9.10), persistent (quasi-quoter schema), eventium 0.4.0 `ReadModel`/`catchUpReadModel`/`rebuildReadModel`, Hspec, SQLite test harness.

---

## Design decisions (locked)

- **Schema.** Two tables, mirroring the spec sketch:
  - `transactions` — one row per transaction. Columns: `transactionId` (unique), `sourceAccountId`, `targetAccountId` (both indexed), `sourceAmount`, `targetAmount` (`Money`), `exchangeRate` (`ExchangeRate Maybe`), `description` (`Text`), `statusKind` (`StatusKind`), `failureReason` (`Text Maybe`), `transactionType` (`TransactionType`, JSON column — carries the two-bucket allocations), `date` (`UTCTime`, indexed), `amendmentCount` (`Int`), `version` (`EventVersion`).
  - `transaction_labels` — `(transactionId, labelId)` with unique `(transactionId, labelId)` and an index on `labelId`.
- **Status split.** `TransactionStatus` (`Pending | Completed | Failed Text | Cancelled`) is stored as a queryable `statusKind` enum column **plus** a nullable `failureReason`. This keeps the `listTransactions` status filter (`IN (StatusKind…)`) a clean indexed predicate while round-tripping the `Failed` reason. `TransactionData.status` is reconstructed from `(statusKind, failureReason)`. `StatusKind` has **no** `ToJSON`/`FromJSON` instances; it is stored as a text token via the existing `renderStatusKind`/`parseStatusKind` (it already derives `Enum`/`Bounded`), which is also the natural form for the `IN` filter.
- **`transactionType` as JSON.** Reporting (`ReportingService.aggregate*`) and `findReferencingTransactions` need the full nested allocations, which are opaque to SQL filtering. Stored as a JSON column (like `AccountType`). Reporting reconstructs `TransactionData` and aggregates in Haskell, but over a **visible-account, date-windowed, Completed** result set (indexed) rather than the whole table.
- **`amendmentCount`** is domain `Word`; stored as `Int` and converted at the boundary (`fromIntegral`; clamp negatives to 0 on read — defensive, never expected).
- **`findReferencingTransactions`** keeps its current contract (count of non-`Cancelled` transactions referencing a `DictionaryEntryId` as a label or as an allocation category). The **label** path becomes an indexed `transaction_labels` join; the **allocation** path remains a bounded scan over non-cancelled rows deserializing `transactionType` (documented — this is a rare dictionary-entry deletion guard, not a hot path). No `transaction_categories` table (out of scope; the spec sketch does not include one).
- **No in-memory fallback.** Consistent with the project's no-backward-compat constraint, the in-memory `TransactionReadModel`/`createTransactionReadModel`/`handleTransactionEvents` are deleted, not kept behind a flag.

---

## Part A — `PersistField` instances for Transaction column types

### A1. Add instances + round-trip tests

**Files:** `src/Infrastructure/Database/Orphans.hs`; `test/Infrastructure/Database/OrphansSpec.hs`.

New instances:
- `DictionaryEntryId` — UUID-backed (`unDictionaryEntryId`/`mkDictionaryEntryId`), mirroring the `TransactionId`/`AccountId` instances (this is `LabelId`/`CategoryId`).
- `ExchangeRate` — JSON via `jsonToPersist`/`jsonFromPersist` (`ToJSON`/`FromJSON` already exist on the domain type).
- `TransactionType` — JSON (`ToJSON`/`FromJSON` exist).
- `StatusKind` — **text token** via `renderStatusKind`/`parseStatusKind` (no JSON instances exist; `parseStatusKind :: Text -> Maybe StatusKind` → `Left` on failure in `fromPersistValue`). `PersistFieldSql … = SqlString`.

(`Money`, `TransactionId`, `AccountId`, `UserId` already exist; `EventVersion`, `UTCTime`, `Int`, `Text` are provided by eventium/persistent.)

- [ ] **Step 1: Write failing round-trip property tests.** In `OrphansSpec`, add `prop_roundtrip` cases for `DictionaryEntryId`, `ExchangeRate`, `TransactionType`, `StatusKind`: `fromPersistValue (toPersistValue x) == Right x`. Reuse/extend existing generators in `test/Testkit/Generators.hs` (there are already generators for these domain types used by other specs — import them; add a `StatusKind` generator if missing).
- [ ] **Step 2: Run, verify they fail to compile** (no instance): `cabal test backend-test --test-option=--match --test-option="/Orphans/" -fci`. Expected: build error "No instance for PersistField …".
- [ ] **Step 3: Add the four instances** in `Orphans.hs` (and their `PersistFieldSql … = SqlString`), importing the needed names from `Domain.Core.Types`/`Domain.Transaction.Projection`.
- [ ] **Step 4: Run, verify pass.** Expected: PASS.
- [ ] **Step 5: Commit.** `feat(read-models): PersistField instances for Transaction column types`.

---

## Part B — Persistent Transaction read model (schema + apply + queries)

This rewrites `src/Application/ReadModels/Transaction.hs`. Keep the public query *names* and `TransactionData`/`TransactionFilter`/`touchesVisible`/`emptyTransactionFilter`/`mkTransactionFilter` exports (consumers depend on them); change query *signatures* from `TVar … -> … -> m a` to `… -> SqlPersistT m a`, dropping the `TVar` parameter. Remove `TransactionReadModel`, `createTransactionReadModel`, `handleTransactionEvents`, `getAllTransactions`, `transactionToMap`, `transactionExists`, `processEvent`.

> **LiquidHaskell:** no obligation here. The CLAUDE.md LH requirement applies to `Domain.*` types; the merged Account read model carries no refinements, and this is an Application-layer projection of existing domain types. No `{-@ @-}` annotations needed.

### B1. Schema + `migrateTransaction` + `resetTransaction`

**Files:** `src/Application/ReadModels/Transaction.hs`.

- [ ] **Step 1:** Add the `share [mkPersist sqlSettings, mkMigrate "migrateTransaction"] [persistLowerCase| … |]` block defining `TransactionEntity sql=transactions` and `TransactionLabelEntity sql=transaction_labels` per the locked schema, plus `transactionProjectionName = CheckpointName "transaction"` and `resetTransaction` (deleteWhere both tables). Add the LANGUAGE pragmas used by Account (`QuasiQuotes`, `TemplateHaskell`, `TypeFamilies`, `DerivingStrategies`, `GADTs`, `StandaloneDeriving`, `DeriveGeneric`, `FlexibleContexts`, `GeneralizedNewtypeDeriving`, `OverloadedRecordDot`, `OverloadedStrings`). Import `Infrastructure.Database.Orphans ()`.
- [ ] **Step 2:** `cabal build backend -fci`. Expected: compiles (entities generate).
- [ ] **Step 3: Commit.** `feat(read-models): transactions + transaction_labels schema`.

### B2. Event apply (`applyTransactionEvent`) + `transactionReadModel`

**Files:** `src/Application/ReadModels/Transaction.hs`; new spec `test/Application/ReadModels/PersistentTransactionReadModelSpec.hs`.

Port `processEvent` to a total, idempotent `applyTransactionEvent :: MonadIO m => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()` (pattern from `applyAccountEvent`):
- `TransactionPostingInitiated` → `insertUnique` the `transactions` row (status `Pending`); `insertUnique` a `transaction_labels` row per label. Use `insertUnique` (no overwrite) to preserve the "terminal state may arrive before initiated" depth-first ordering guarantee the old `Map.insertWith (\_ existing -> existing)` provided.
- `TransactionPostingCompleted` → set `statusKind = CompletedKind`.
- `TransactionPostingFailed` → set `statusKind = FailedKind`, `failureReason = Just evt.reason`.
- `TransactionLabelsSet` → replace label rows (`deleteWhere [labelEntityTransactionId ==. tid]` then `insertUnique` each).
- `TransactionAllocationsChanged` → `transactionType = replaceAllocations evt.newAllocations …`.
- `TransactionDescriptionChanged` → `description = evt.newDescription`.
- `TransactionDateChanged` → `date = evt.newAt`.
- `TransactionAmendmentCompleted` → set source/target account+amount, exchangeRate, transactionType; `amendmentCount += 1`.
- `TransactionCancellationCompleted` → `statusKind = CancelledKind`.
- `TransactionAmendmentInitiated`/`…Failed`/`TransactionCancellationInitiated` → no-op (saga-internal).
- All non-transaction events → no-op.
- Every mutating branch records `version = inner.position` (from `globalEvent.payload.position`), mirroring Account.

Then `transactionReadModel :: ReadModel (SqlPersistT IO) AccountingEvent` = `{ initialize = void (runMigrationSilent migrateTransaction), eventHandler = EventHandler applyTransactionEvent, checkpointStore = postgresqlCheckpointStore transactionProjectionName, reset = resetTransaction }`.

- [ ] **Step 1: Write failing spec** `PersistentTransactionReadModelSpec` (SQLite harness, mirroring `PersistentAccountReadModelSpec`): apply an initiated→completed sequence, assert `getTransaction` reflects it; apply-twice == apply-once (idempotency); `version` tracks the real per-stream `EventVersion` (0,1,2…); label rows created/replaced.
- [ ] **Step 2: Run, verify fail** (`applyTransactionEvent`/`transactionReadModel` undefined).
- [ ] **Step 3: Implement** apply + read model.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `feat(read-models): Transaction event apply as eventium ReadModel`.

### B3. Indexed queries

**Files:** `src/Application/ReadModels/Transaction.hs`.

Reconstruction helper `entToData :: TransactionEntity -> [LabelId] -> TransactionData` rebuilding `status` from `(statusKind, failureReason)`, `labels` from the joined rows, and `amendmentCount` from the stored `Int` clamped to `>= 0` (`fromIntegral . max 0`). Queries:
- `getTransaction :: MonadIO m => TransactionId -> SqlPersistT m (Maybe TransactionData)` — `getBy UniqueTransactionId` + load labels.
- `listTransactions :: MonadIO m => Set AccountId -> TransactionFilter -> Page -> SqlPersistT m (Int, [(TransactionId, TransactionData)])` — assemble the predicate with explicit `FilterOr`/`FilterAnd` nesting (NOT just list concatenation): `FilterAnd [ FilterOr [src <-. vis, tgt <-. vis], <optional accountId as FilterOr [src ==. a, tgt ==. a]>, <date >=./<=.>, <statusKind <-. kinds>, <label-derived TransactionId <-. ids> ]`. For a `label` filter, first resolve `transaction_labels` rows with `labelId <-. labels` to the matching `transactionId`s. **Empty-visible-set edge:** when `vis` is empty, short-circuit to `(0, [])` rather than emit `IN ()` (verify SQLite behaviour in the harness regardless). Compute `total` via `count filters`, then `selectList filters [Desc …Date, Asc …TransactionId, OffsetBy page.offset, LimitTo page.limit]`; batch-load labels for the page (single `labelId`-grouped query like Account's `loadAccessLists`).
- `transactionDatesForAccount :: MonadIO m => AccountId -> SqlPersistT m (Map TransactionId UTCTime)` — `(src ==. a) OR (tgt ==. a)`, returns `(transactionId, date)`. Replaces the `AccountService` use of `getAllTransactions` that builds the `txId → business-date` lookup for the `balanceAsOf` fold (any status; scoped to the one account being adjusted).
- `findReferencingTransactions :: MonadIO m => DictionaryEntryId -> SqlPersistT m Int` — union of: (a) non-cancelled transactions with a `transaction_labels` row for `entryId` (indexed), and (b) non-cancelled transactions whose `transactionType` allocations reference `entryId` (deserialize + scan over non-cancelled rows; documented bounded cost — rare deletion guard). Count distinct transaction ids.
- `reportableTransactions :: MonadIO m => Set AccountId -> Maybe UTCTime -> Maybe UTCTime -> SqlPersistT m [TransactionData]` — `statusKind ==. CompletedKind` AND visible-account `FilterOr` AND date window; returns `TransactionData` for in-memory categorised aggregation. Replaces `getAllTransactions` in `ReportingService` (which only kept `Completed` + visible rows anyway, via `reportableTxns`).

Drop `transactionExists` — it has no consumers outside the module (grep-confirmed); do not port it.

- [ ] **Step 1: Write failing query spec** extending `PersistentTransactionReadModelSpec`: tenant isolation (a transaction touching only user B's accounts never appears in user A's `listTransactions`/`reportableTransactions`); shared visibility (a transaction on a shared account appears for the grantee); filter correctness (date/status/label/account); pagination + `total`; empty-visible-set → `(0, [])`; `findReferencingTransactions` counts both label and allocation references and excludes `Cancelled`; `transactionDatesForAccount` returns dates for both legs and any status; `amendmentCount` clamp on read.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** queries.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `feat(read-models): indexed Transaction queries`.

### B4. Port existing unit/property specs to DB-backed

**Files:** `test/Application/ReadModels/TransactionListSpec.hs`, `TransactionFilterSpec.hs`, `TransactionListPropertySpec.hs`.

- [ ] **Step 1:** Adapt these specs from `TVar`/`Map` assertions to the SQLite harness (`runDb`-equivalent against a fresh pool), mirroring how `TransactionAmendmentSpec`/`AmendmentBalanceSpec` were migrated for Account. `TransactionFilterSpec` (pure filter construction) likely needs no change.
- [ ] **Step 2: Run, verify pass.** `cabal test backend-test --test-option=--match --test-option="/Transaction/" -fci`.
- [ ] **Step 3: Commit.** `test(read-models): port Transaction read-model specs to DB-backed`.

---

## Part C — Wiring + consumer migration

### C1. Register the read model; drop in-memory wiring

**Files:** `src/Application/ReadModels/Persist.hs`, `src/Infrastructure/Database.hs` (`runMigrations`), `src/Application/EventDispatch.hs`, `src/Infrastructure/App.hs`, `app/Main.hs`, `test/Testkit/InMemoryEventStore.hs`.

- [ ] Add `(unCheckpointName transactionProjectionName, transactionReadModel)` to `persistentReadModels`.
- [ ] Add `migrateTransaction` to `runMigrations` in `Infrastructure/Database.hs`.
- [ ] `EventDispatch.hs`: remove `transaction` from `ReadModels`, `createReadModels`, `fromReadModels`, and drop `handleTransactionEvents` from the handler list + the `Application.ReadModels.Transaction` import of removed names.
- [ ] `App.hs`: remove the `transactionReadModel` field from `AppEnv` (`:206-207`), the **positional** parameter in `initializeAppEnv` (`:301,314` — one `TVar` among ~20 positional args; every caller's argument order shifts, get it right), and `transactionReadModelL` from `HasReadModel` (`:475-483`). The `HasReadModel` class **survives** — it still carries `userReadModelL` and `configurationReadModelL` (not yet migrated).
- [ ] `Main.hs`: drop the `transactionReadModel` construction and its positional argument to `initializeAppEnv` (`:280-281,408`).
- [ ] `InMemoryEventStore.hs`: drop `readModels.transaction` from the `AppEnv` build (`:261`) and the matching `initializeAppEnv` positional argument. The persistent model is already driven via `persistentReadModels`/`readModelPublisher` (`:235`) and `initialize`d in the harness setup loop (`:210`), so no further harness wiring is needed.
- [ ] `cabal build all -fci` — expect type errors only at the consumer call sites handled in C2.

### C2. Migrate consumers to `runDb (ReadModel.…)`

**Files (call sites):** `src/Application/Services/TransactionService.hs`, `ReportingService.hs`, `TransactionHistoryService.hs`, `AccountService.hs`, `ConfigurationService.hs`, `src/Web/API/TransactionAPI.hs`, `src/Web/Types.hs`, `src/Telegram/Commands.hs`, `src/Telegram/Formatting.hs`.

Transformation rule (mechanical, mirrors Account #112): replace `view transactionReadModelL` + `ReadModel.getX tvar args` with `runDb (ReadModel.getX args)`; in `ExceptT`/`runExceptT` contexts, `lift (runDb …)`. Specific swaps:
- `TransactionService`, `TransactionHistoryService`, `Web/API/TransactionAPI`, `Web/Types`, `Telegram/Commands`, `Telegram/Formatting`: `getTransaction`/`listTransactions` — drop the `TVar` arg, wrap in `runDb`.
- `ReportingService` (`:49,191,203`): replace the `view transactionReadModelL` + `getAllTransactions` + `reportableTxns visible …` pipeline with `runDb (reportableTransactions visible mFrom mTo)`; keep the pure `aggregate*` helpers operating on the returned list. Drop the `reportableTxns`/`getAllTransactions` imports.
- `AccountService` (`:443-445`): replace `view transactionReadModelL` + `getAllTransactions` (building the `txId → date` map) with `runDb (transactionDatesForAccount accountId)`. The `lookupTxAt` closure then reads that scoped map.
- `ConfigurationService` in-use check: `runDb (findReferencingTransactions entryId)`.

- [ ] **Step 1:** Apply the swaps file-by-file until `cabal build all -fci` is clean.
- [ ] **Step 2: Migrate the test specs** that reference the old `TVar` model or call now-`runDb` services and read the model back. At minimum, audit and fix: `test/Testkit/{InMemoryEventStore,Helpers,Generators}.hs`; `test/Application/Services/{TransactionService,TransactionServiceSpec,TransactionServiceLabelsSpec,TransactionMetadataEditSpec,TransactionAllocationsIntegration,ContraExpenseIntegration,CrossKindAmendment,TransactionAmendment,ReportingService,ReportingServiceProperty,ConfigurationServiceInUse,BankImportService}Spec.hs`; `test/Integration/{TransferWorkflow,ReportingWorkflowIntegration,TransactionCancellationIntegration,TransactionLabelsIntegration,TransactionMetadataEditIntegration,TransactionCategoryIntegration,TransactionAmendmentIntegration,BankImportWorkflow}Spec.hs`; `test/Telegram/FormattingSpec.hs`. (Re-grep the symbol list before declaring done — the set is large; treat the grep, not this list, as authoritative.)
- [ ] **Step 3:** `just test` (full suite) green.
- [ ] **Step 4: Commit.** `refactor(read-models): migrate Transaction consumers to runDb`.

---

## Part D — Verification

- [ ] `just rebuild` (clean `-fci` build, lib+exe+test) — definitive `-Werror` check.
- [ ] `just test` — full suite green.
- [ ] `just check` (ormolu + hlint) clean.
- [ ] Grep confirms no remaining `transactionReadModel`/`TransactionReadModel`/`handleTransactionEvents`/`getAllTransactions` references outside history.
- [ ] Update `docs/specs/2026-06-25-persistent-read-models-design.md` rollout (mark Transaction done) and set this plan's frontmatter `status: completed`.
- [ ] Open PR `refactor(read-models): persistent indexed Transaction read model` against `master`, referencing #51 (and noting it advances #110's goals).

---

## Done criteria

- Transaction served from `transactions`/`transaction_labels`; `listTransactions` and reporting are indexed visible-account queries, no full-table scans (except the documented bounded allocation path in `findReferencingTransactions`).
- Lookup latency independent of other tenants' transaction volume (acceptance criterion from #110).
- `transactionReadModel` removed from `AppEnv`/`HasReadModel`/`EventDispatch`; the model runs as a registered eventium `ReadModel` via `readModelPublisher` with checkpoint-in-transaction.
- Per-row `version` recorded from the event (no `+1`).
- Property/integration tests cover tenant isolation and rebuild-after-eviction (catch-up) correctness.
- All gates green.

## Out of scope (later phases)
- User, Configuration, ExchangeRate migrations (same pattern; rollout step 4).
- A normalized `transaction_categories` reverse index (only if `findReferencingTransactions` allocation scan becomes a measured bottleneck).
