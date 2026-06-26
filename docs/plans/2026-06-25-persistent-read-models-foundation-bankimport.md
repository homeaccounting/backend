# Persistent Read Models — Phase 1: Foundation + BankImport Pilot

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> Use @superpowers:test-driven-development for every task: write the failing test, watch it fail, implement, watch it pass, commit.

**Goal:** Establish the reusable machinery for persistent, indexed, Postgres-backed read models (migration registration, synchronous in-transaction projection writes, checkpointed boot catch-up, on-demand rebuild) and prove it end-to-end by migrating the **BankImport** dedup read model off its in-memory `TVar`.

**Architecture:** Each persistent read model is a set of `persistent` tables co-located with its module in `Application/ReadModels/*`. The event→row *apply* handler runs in `SqlPersistT IO` and is wired into the event-store writer's synchronous publisher, so projection writes commit in the **same transaction** as the event append (strong consistency, read-after-write). A per-model eventium `CheckpointStore` (in `projection_snapshots`) is advanced only by the replay path. On boot, a reusable `backfillReadModel` replays `checkpoint+1 → latest` in idempotent batches. Reads become SQL queries via `runDb`.

**Tech Stack:** Haskell (GHC 9.10.3, RIO prelude), `persistent` + `persistent-postgresql`, eventium (`eventium-core`, `eventium-sql-common`, `eventium-postgresql`), Hspec, `just`.

**Spec:** `docs/specs/2026-06-25-persistent-read-models-design.md`

---

## Background the implementer needs

- **Layering** (see `CLAUDE.md`): `Domain.*` is pure; `Application.*` may import `Infrastructure.*`. Read models live in `Application/ReadModels/*` and may use `persistent` via `Infrastructure.Database` re-exports. Do **not** add `persistent` imports to `Domain.*`.
- **Build/verify**: `just build` (hpack + cabal build), `just test`, `just check` (format + lint). CI gate `cabal build -fci` must stay clean for lib+exe; the test suite has known `-Werror` debt gated by `just test` (do not rely on `-fci` for tests).
- **Format/lint are mandatory**: run `just format` and `just lint` before every commit. No `hlint` suppressions.
- **No partial functions**, no `error`/`undefined`. Smart constructors return `Either`/`Maybe`.
- **DB plumbing** (already present):
  - `Infrastructure.Database.runMigrations :: SqlPersistT m ()` — the hook to register new table migrations (currently runs `migrateSqlEvent` only; has a TODO pointing exactly here).
  - `runDbDirect :: ConnectionPool -> SqlPersistT IO a -> IO a` (= `flip runSqlPool`, one transaction).
  - `Infrastructure.App.runDb :: (MonadReader env m, HasDbPool env, MonadUnliftIO m) => ReaderT SqlBackend (LoggingT IO) a -> m a` — runtime query runner used by services.
- **Writer wiring** (`Infrastructure/Eventium.hs:237-260`): `accountingEventStoreWriter config pmFactory extraHandlers` builds the synchronous publisher. `extraHandlers :: [AccountingEventHandler (SqlPersistT m)]` run **inside the writer transaction**. Today read-model handlers reach this list as IO handlers via `map liftIOEventHandler (createReadModelHandlersFrom handlers)` in `app/Main.hs:281,297`. A **persistent** handler must instead be supplied directly as an `AccountingEventHandler (SqlPersistT IO)` (NOT `liftIOEventHandler`-wrapped) so its DB writes join the transaction.
- **Handler types** (`Infrastructure/Eventium.hs`):
  - `AccountingEventHandler m = EventHandler m (VersionedStreamEvent AccountingEvent)` (single event, per-stream).
  - `AccountingReadModelHandler m = EventHandler m [GlobalStreamEvent AccountingEvent]` (batch).
  - `createReadModelHandlersFrom :: AccountingReadModelHandler m -> [AccountingEventHandler m]` — wraps each live event as `StreamEvent () 0 …` (**position 0 fabricated**; fine for BankImport, which ignores position).
- **Global reader for backfill**: `accountingGlobalEventStoreReader config :: AccountingGlobalEventStoreReader (SqlPersistT m)`; read a batch with **real** `SequenceNumber`s via the exported record field `gr.getEvents (eventsStartingAtTakeLimit () start n)`. (Note: `Infrastructure.Eventium.readEvents` is **not exported** — use the `EventStoreReader` newtype's `getEvents` field directly, the idiom eventium itself uses.)
- **Checkpoint store**: `Eventium.ProjectionCache.Sql.postgresqlCheckpointStore (CheckpointName "<name>") :: CheckpointStore (SqlPersistT m) SequenceNumber`; backed by `projection_snapshots` (migration `migrateProjectionSnapshot`, re-exported from `eventium-postgresql`). `getCheckpoint` returns `0` when absent.
- **BankImport today** (`Application/ReadModels/BankImportReadModel.hs`): `importedTransactions :: Map ExternalTransactionId TransactionId`. `processEvent` records the mapping on `TransactionPostingInitiatedEvent` when `externalTransactionId` is `Just`. The mapping is permanent (never evicted). The only caller is `Application/Services/BankImportService.hs:301-302` (`view bankImportReadModelL` then `isImported`), under a per-user lock.
- **Id types** (`Domain/Core/Types.hs`): `ExternalTransactionId` wraps `Text` (`unExternalTransactionId`, `mkExternalTransactionId`); `TransactionId` wraps `UUID` (`unTransactionId`, `mkTransactionIdSafe`).

---

## File Structure

- **Create** `src/Infrastructure/ReadModels/Backfill.hs` — reusable foundation: `backfillReadModel` (batched idempotent catch-up) and `rebuildReadModelTables` (reset + backfill). Pure infrastructure; no BankImport specifics.
- **Modify** `src/Application/ReadModels/BankImportReadModel.hs` — add the `persistent` entity + `migrateBankImport`, the `SqlPersistT` apply handler, and the `SqlPersistT` `isImported` query. Remove the `TVar` model (or keep temporarily — see Task 8).
- **Modify** `src/Infrastructure/Database.hs` — register `migrateBankImport` and `migrateProjectionSnapshot` in `runMigrations`.
- **Modify** `src/Application/EventDispatch.hs` — stop bundling BankImport into the in-memory `ReadModels`/`fromReadModels`; expose the persistent handler separately.
- **Modify** `src/Infrastructure/Eventium.hs` — if needed, a small helper to inject a `SqlPersistT IO` read-model handler into `extraHandlers`.
- **Modify** `app/Main.hs` — wire the persistent BankImport handler into `accountingEventStoreWriter`; run BankImport boot catch-up; drop BankImport from the in-memory replay; remove it from `BankingEnv` construction.
- **Modify** `src/Infrastructure/App.hs` — remove `bankImportReadModel` field from `BankingEnv` and the `HasBankImportReadModel` class/instances.
- **Modify** `src/Application/Services/BankImportService.hs` — `isImported` now runs via `runDb`; drop `bankImportReadModelL`.
- **Create** `test/Application/ReadModels/BankImportReadModelIntegrationSpec.hs` — dedup persistence, backfill, rebuild, idempotency.
- **Modify** `package.yaml` only if a new dependency is needed (none expected; `persistent`, eventium already deps). Run `hpack` (via `just build`) after.

---

## Task 1: `PersistField` instances for the id types used as columns

**Files:**
- Modify: `src/Application/ReadModels/BankImportReadModel.hs` (instances co-located with first use), or a small `src/Infrastructure/Persist/Orphans.hs` if you prefer to centralize. Default: co-locate in the read-model module.
- Test: `test/Application/ReadModels/BankImportReadModelIntegrationSpec.hs` (round-trip property added in Task 11; a focused unit round-trip here is enough to start).

- [ ] **Step 1: Write a failing round-trip test** for `PersistField ExternalTransactionId` and `PersistField TransactionId` (`fromPersistValue . toPersistValue == Right x`).

```haskell
-- ExternalTransactionId <-> PersistText ; TransactionId <-> PersistText (UUID rendered)
prop "ExternalTransactionId round-trips through PersistValue" $ \t ->
  let extId = unsafeExternalTransactionId t
   in fromPersistValue (toPersistValue extId) === Right extId
```

- [ ] **Step 2: Run it, watch it fail** (no instance). `cabal test all --test-option='--match' --test-option="/BankImport/"`.

- [ ] **Step 3: Implement the instances.**

```haskell
instance PersistField ExternalTransactionId where
  toPersistValue = toPersistValue . unExternalTransactionId
  fromPersistValue v = do
    t <- fromPersistValue v
    first T.pack (mkExternalTransactionId t)

instance PersistFieldSql ExternalTransactionId where
  sqlType _ = SqlString

instance PersistField TransactionId where
  toPersistValue = toPersistValue . unTransactionId          -- store the UUID
  fromPersistValue v = mkTransactionIdSafe <$> fromPersistValue v >>= maybe (Left "invalid TransactionId") Right
```

(Use `UUID` ↔ `PersistValue` via persistent's existing `UUID` instance, already used by the events table. Adjust the exact combinators to compile; keep it total.)

- [ ] **Step 4: Run the test, watch it pass.**
- [ ] **Step 5: `just format && just lint`, then commit.** `git commit -m "feat(read-models): PersistField instances for external/transaction ids"`

---

## Task 2: Persistent entity + migration for BankImport

**Files:**
- Modify: `src/Application/ReadModels/BankImportReadModel.hs`

- [ ] **Step 1: Write a failing test** that runs `migrateBankImport` against a test DB connection and inserts/reads a row.
- [ ] **Step 2: Run, watch fail** (no entity/migration).
- [ ] **Step 3: Define the entity** (quasi-quoter, co-located). External id is the primary key (enforces dedup uniqueness in the DB):

```haskell
share [mkPersist sqlSettings, mkMigrate "migrateBankImport"]
  [persistLowerCase|
ImportedTransactionEntity sql=imported_transactions
    externalTransactionId ExternalTransactionId
    transactionId TransactionId
    Primary externalTransactionId
    deriving Show
|]
```

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): imported_transactions table + migrateBankImport`

---

## Task 3: Idempotent `SqlPersistT` apply handler

**Files:**
- Modify: `src/Application/ReadModels/BankImportReadModel.hs`

- [ ] **Step 1: Write a failing test:** applying a batch containing a `TransactionPostingInitiatedEvent` with an `externalTransactionId` inserts the mapping; applying the **same** batch twice leaves exactly one row (idempotent); events without an external id insert nothing.
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement** the handler in `SqlPersistT`. Use `repsert` (insert-or-replace by primary key) so re-application is a no-op — this is the natural idempotency BankImport relies on.

```haskell
handleBankImportEventsSql :: (MonadIO m) => AccountingReadModelHandler (SqlPersistT m)
handleBankImportEventsSql = EventHandler $ \events -> mapM_ applyOne events
  where
    applyOne globalEvent =
      let (streamUuid, payload) = unpackGlobalEvent globalEvent
       in case payload of
            TransactionPostingInitiatedEvent evt ->
              case (evt.externalTransactionId, mkTransactionIdSafe streamUuid) of
                (Just extId, Just txId) ->
                  repsert (ImportedTransactionEntityKey extId)
                          (ImportedTransactionEntity extId txId)
                _ -> pure ()
            _ -> pure ()
```

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): idempotent SQL apply for bank-import dedup`

---

## Task 4: `SqlPersistT` `isImported` query

**Files:**
- Modify: `src/Application/ReadModels/BankImportReadModel.hs`

- [ ] **Step 1: Failing test:** after applying an event for `extId`, `isImported extId` returns `True`; for an unknown id, `False`.
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement** (replace the `TVar` `isImported`):

```haskell
isImported :: (MonadIO m) => ExternalTransactionId -> SqlPersistT m Bool
isImported extId = isJust <$> get (ImportedTransactionEntityKey extId)
```

Update the module export list: drop `BankImportReadModel(..)`, `createBankImportReadModel`, `handleBankImportEvents`; add `ImportedTransactionEntity(..)`, `migrateBankImport`, `handleBankImportEventsSql`, the new `isImported`.

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): SQL isImported query`

---

## Task 5: Register migrations

**Files:**
- Modify: `src/Infrastructure/Database.hs:351-354` (`runMigrations`)

- [ ] **Step 1: Failing test** (integration): calling `runMigrations` then querying `imported_transactions` succeeds (table exists), and `projection_snapshots` exists.
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement** — add to `runMigrations`:

```haskell
void $ runMigration migrateProjectionSnapshot   -- from Eventium.ProjectionCache.Sql / eventium-postgresql
void $ runMigration migrateBankImport
```

Add imports for `migrateProjectionSnapshot` and `migrateBankImport`.

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): register bank-import + projection-snapshot migrations`

---

## Task 6: Reusable backfill + rebuild foundation

**Files:**
- Create: `src/Infrastructure/ReadModels/Backfill.hs`
- Test: `test/Infrastructure/ReadModels/BackfillSpec.hs`

- [ ] **Step 1: Failing tests** using the in-memory/test event store harness (`test/Testkit/InMemoryEventStore.hs`) or a test Postgres:
  - `backfillReadModel` over a stream of N events applies all of them and sets the checkpoint to the last position.
  - Running `backfillReadModel` **again** from the saved checkpoint applies only the tail and leaves projection state unchanged (idempotency + resumability).
  - `rebuildReadModelTables` (reset then backfill) reproduces identical projection rows.
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement.** Batched loop; each batch is one transaction (read events, apply, advance checkpoint):

```haskell
backfillReadModel ::
  ConnectionPool ->
  AccountingGlobalEventStoreReader (SqlPersistT IO) ->
  CheckpointStore (SqlPersistT IO) SequenceNumber ->
  AccountingReadModelHandler (SqlPersistT IO) ->
  Int ->                              -- batch size
  IO Int                              -- total events applied
backfillReadModel pool gr cp (EventHandler apply) batchN = go 0
  where
    go !acc = do
      n <- runDbDirect pool $ do
        from <- cp.getCheckpoint
        evs  <- gr.getEvents (eventsStartingAtTakeLimit () (from + 1) batchN)  -- exported field; readEvents is private
        case nonEmpty evs of
          Nothing -> pure 0
          Just ne -> do
            apply evs
            cp.saveCheckpoint (NE.last ne).position
            pure (length evs)
      if n == 0 then pure acc else go (acc + n)

rebuildReadModelTables ::
  ConnectionPool ->
  SqlPersistT IO () ->                -- reset action (truncate tables)
  CheckpointStore (SqlPersistT IO) SequenceNumber ->
  ... -> IO Int
-- reset tables + saveCheckpoint 0 in one tx, then backfillReadModel
```

(Confirm exact `eventsStartingAtTakeLimit`/`SequenceNumber` arithmetic against `Eventium.Store.Queries`. Keep batches modest, e.g. 1000.)

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): reusable batched backfill + rebuild`

---

## Task 7: Wire the persistent handler into the writer; split BankImport out of the in-memory bundle

**Files:**
- Modify: `src/Application/EventDispatch.hs` (remove `bankImport` from `ReadModels`/`createReadModels`/`fromReadModels`; export the persistent handler reference)
- Modify: `app/Main.hs:284-310` (writer construction + replay)
- Modify: `src/Infrastructure/Eventium.hs` only if a helper is needed

- [ ] **Step 1: Failing integration test** (end-to-end through the real writer, test DB): execute a command that emits `TransactionPostingInitiated` with an external id (or publish a synthetic event through the writer), then in a **separate** `runDb` transaction assert `isImported extId == True` — proving the projection committed in the writer's transaction (read-after-write).
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement.**
  - In `EventDispatch.hs`: remove the `bankImport` field and its create/handler lines; `ReadModels` and `fromReadModels` now cover the five still-in-memory models.
  - In `app/Main.hs`: pass the persistent handler to the writer's `extraHandlers` directly as a `SqlPersistT IO` handler (it does real DB writes in-transaction), alongside the existing IO-lifted in-memory handlers:

```haskell
        accountingEventStoreWriter
          eventStoreConfig
          (wireProcessManagers [...])
          ( handleBankImportEventsSql                       -- SqlPersistT IO, in-transaction
              : map liftIOEventHandler (createReadModelHandlersFrom handlers)  -- remaining TVar models
          )
```

  Note: `handleBankImportEventsSql :: AccountingReadModelHandler (SqlPersistT IO)` is a *batch* handler; the `extraHandlers` slot is `AccountingEventHandler (SqlPersistT IO)` (single versioned event). Reuse `createReadModelHandlersFrom` to adapt it (it wraps a single event into a singleton global batch with position 0 — fine for BankImport). So pass `createReadModelHandlersFrom handleBankImportEventsSql ++ map liftIOEventHandler (createReadModelHandlersFrom handlers)`. Confirm the monad: `createReadModelHandlersFrom` is monad-polymorphic, so it yields `[AccountingEventHandler (SqlPersistT IO)]` directly — no `liftIOEventHandler` for the persistent one.
  - Remove `bankImport` from the in-memory `replayWith` path (it's no longer in `handlers`).

- [ ] **Step 4: Run, watch pass** (and `just build`, `cabal build -fci` clean for lib+exe).
- [ ] **Step 5: format/lint, commit.** `feat(read-models): project bank-import dedup in the event-store transaction`

---

## Task 8: Boot catch-up wiring for BankImport

**Files:**
- Modify: `app/Main.hs` (after migrations/writer setup, before server start)

- [ ] **Step 1: Failing test:** with events already in the store but `imported_transactions` empty (simulating a freshly-added table), boot catch-up populates the dedup rows and sets the checkpoint.
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement** — replace BankImport's slice of the old full replay with a catch-up call:

```haskell
let bankImportCp = postgresqlCheckpointStore (CheckpointName "bankimport")
    sqlGlobalReader = accountingGlobalEventStoreReader eventStoreConfig
_ <- liftIO $ backfillReadModel pool sqlGlobalReader bankImportCp handleBankImportEventsSql 1000
```

Keep the existing `replayWith globalReader handlers` for the five still-in-memory models (BankImport removed from `handlers`).

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): boot catch-up for bank-import projection`

---

## Task 9: On-demand rebuild trigger (CLI/env flag)

**Files:**
- Modify: `app/Main.hs` (read an env var, e.g. `REBUILD_READ_MODELS=bankimport`)

- [ ] **Step 1: Failing test** (or a documented manual check): with the flag set, startup resets `imported_transactions` + checkpoint and rebuilds from the log; without it, startup does ordinary catch-up.
- [ ] **Step 2: Run, watch fail.**
- [ ] **Step 3: Implement** — parse the env var; if it names `bankimport`, call `rebuildReadModelTables` (reset = `deleteWhere ([] :: [Filter ImportedTransactionEntity])` + `saveCheckpoint 0`) instead of plain catch-up. No new HTTP/admin surface.
- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `feat(read-models): env-flag rebuild for bank-import projection`

---

## Task 10: Swap the service caller to SQL

**Files:**
- Modify: `src/Application/Services/BankImportService.hs:300-302` (and imports line 39, 71)

- [ ] **Step 1: Failing test** — existing BankImportService tests should still pass once the call is swapped; add/adjust a test that the dedup skip path triggers using the SQL-backed `isImported`.
- [ ] **Step 2: Run, watch fail/compile-error** (old `bankImportReadModelL` removed).
- [ ] **Step 3: Implement:**

```haskell
-- was: bankImportRM <- view bankImportReadModelL
--      alreadyImported <- isImported bankImportRM tx.externalId
alreadyImported <- runDb $ isImported tx.externalId
```

Keep the surrounding per-user lock unchanged. Update imports (drop `HasBankImportReadModel`, `bankImportReadModelL`).

- [ ] **Step 4: Run, watch pass.**
- [ ] **Step 5: format/lint, commit.** `refactor(bank-import): query dedup via SQL read model`

---

## Task 11: Remove the in-memory BankImport remnants + full verification

**Files:**
- Modify: `src/Application/ReadModels/BankImportReadModel.hs` (delete `BankImportReadModel` type, `createBankImportReadModel`, `handleBankImportEvents`, `processEvent`, `TVar` imports — all now unused)
- Modify: `src/Infrastructure/App.hs:252,558-565` (remove `bankImportReadModel` field from `BankingEnv`; remove `HasBankImportReadModel` class + both instances; fix `App.hs:94` export)
- Modify: `app/Main.hs:372` (drop `bankImportReadModel = …` from `BankingEnv` construction)
- Test: `test/Application/ReadModels/BankImportReadModelIntegrationSpec.hs`

- [ ] **Step 1: Add the integration spec** (`*IntegrationSpec.hs`) covering the spec's acceptance criteria for this model:
  - **Dedup persists across a simulated restart**: apply an import event via the writer; build a fresh query path (new `runDb`) and assert `isImported == True`.
  - **Backfill correctness**: seed N events, empty table, run `backfillReadModel`, assert all dedup rows present and checkpoint advanced.
  - **Rebuild correctness**: after live writes, `rebuildReadModelTables` reproduces identical rows.
  - **Idempotency property** (QuickCheck): applying any event batch twice == once (row set identical).
- [ ] **Step 2: Run the new spec, watch the relevant assertions fail** before cleanup if applicable; then remove the remnants.
- [ ] **Step 3: Implement the deletions.** Compiler will flag every remaining reference — resolve until clean.
- [ ] **Step 4: Full verification:**
  - `just build` — clean.
  - `cabal build -fci` — clean for lib+exe.
  - `just test` — all green (BankImport specs included).
  - `just check` (format + lint) — clean.
  - Manual smoke (optional): run the app (`just run`) against a DB with existing events; confirm logs show bank-import catch-up populating rows and the app serves.
- [ ] **Step 5: commit.** `refactor(read-models): remove in-memory bank-import read model`

---

## Done criteria for Phase 1

- BankImport dedup is served entirely from `imported_transactions`; no `TVar` remains for it.
- Projection writes commit in the event-append transaction (verified by a read-after-write integration test).
- Boot catch-up + env-flag rebuild work and are covered by tests.
- The reusable `backfillReadModel`/`rebuildReadModelTables` foundation exists for Account/Transaction phases.
- `just build`, `cabal build -fci` (lib+exe), `just test`, `just check` all clean.

## Explicitly deferred to later phases (do NOT do here)

- Account migration (`accounts` + `account_access`, killing `getAccessibleAccounts` scan) and the **accumulating-projection idempotency decision** (per-aggregate version guard vs. an eventium change threading real global positions to live handlers) — that decision is made in the Account plan.
- Transaction, User, Configuration, ExchangeRate migrations.
- Any change to the event store schema or global ordering.
