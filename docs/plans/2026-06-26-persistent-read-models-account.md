# Persistent Read Models — Phase 2: eventium dual-mode adoption + Account

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development for each task. Steps use `- [ ]` checkboxes.

**Goal:** Adopt eventium 0.4.0's dual-mode `ReadModel` (synchronous in-transaction projection with real global positions) as the backend's persistent-read-model foundation, then migrate the **Account** read model to indexed Postgres tables — eliminating the `getAccessibleAccounts`/`getUserRegularAccounts`/`listTransactions`-style scans for accounts.

**Architecture:** Persistent read models become eventium `ReadModel`s driven by `readModelPublisher` wired into a global-publishing event-store writer, so each projection applies + advances its checkpoint in the event-append transaction (strong consistency). The bespoke `Infrastructure.Eventium.Backfill` is retired in favour of eventium's `catchUpReadModel`/`rebuildReadModel`. Account stores its data in `accounts` + `account_access`; the per-row `version` is recorded from the event's real per-stream version (no `version + 1`); `balance` deltas apply once (no re-application, so no guard).

**Spec:** `docs/specs/2026-06-25-persistent-read-models-design.md` (see the "Resolution (decided): synchronous, in-transaction projection" section).

**Depends on:** eventium `feat/global-sequence-write-result` (PR #9), used via local branch (backend bounds already `>= 0.4.0 && < 0.5.0`).

---

## Part A — Adopt eventium dual-mode ReadModel (foundation)

### A1. eventium: add `catchUpReadModel` (one-shot catch-up, no reset)

`rebuildReadModel` resets then replays — wrong for startup (would wipe durable tables every boot). Extract the catch-up loop into a reset-less one-shot.

**Files:** `eventium-core/src/Eventium/ReadModel.hs` (+ export), `eventium-memory/tests/Eventium/ReadModelSpec.hs`.

- [ ] Add `catchUpReadModel :: Monad m => GlobalEventStoreReader m event -> ReadModel m event -> m ()` = `initialize` then replay `checkpoint+1 → latest` (the existing `replayAll` loop, no `reset`). Refactor `rebuildReadModel` to `reset >> catchUpReadModel`.
- [ ] Test (memory): after some writes, `catchUpReadModel` brings a fresh model current without wiping; running it again is a no-op.
- [ ] `cabal test eventium-core eventium-memory -fci` green; bump nothing (still 0.4.0, additive); CHANGELOG note under 0.4.0.

### A2. Backend: global-publishing writer + ReadModel registry

Drive persistent read models synchronously with real positions; keep in-memory models (not yet migrated) + process managers + logger working via `globalToVersionedHandler`.

**Files:** `src/Infrastructure/Eventium.hs`, `src/Application/ReadModels/Persist.hs`, `app/Main.hs`.

- [ ] Add a persistent-read-model **registry** entry shape: `data PersistentReadModel = PersistentReadModel { name :: Text, readModel :: ReadModel (SqlPersistT IO) AccountingEvent }` (or reuse eventium `ReadModel` + a name). Each entry's `ReadModel` has `initialize = runMigration`, `eventHandler` (SQL apply), `checkpointStore = postgresqlCheckpointStore (CheckpointName name)`, `reset = truncate`.
- [ ] In `accountingEventStoreWriter`/`…WithRaw`, build the publisher as a `GlobalEventPublisher`:
  `mconcat (map readModelPublisher persistentReadModels) <> synchronousGlobalPublisher (globalToVersionedHandler (eventLoggerHandler <> mconcat inMemoryHandlers <> pmFactory …))`, wired via `publishingGlobalTaggedCodecEventStoreWriter`. Confirm the lazy-binding for PMs still holds.
- [ ] `Application.ReadModels.Persist.initializePersistentReadModels`: per registered `ReadModel`, run `catchUpReadModel` (or `rebuildReadModel` when `REBUILD_READ_MODELS` names it). Drop the bespoke backfill calls.
- [ ] Delete `src/Infrastructure/Eventium/Backfill.hs`; remove its references/exports.

### A3. Retrofit BankImport onto the eventium `ReadModel`

**Files:** `src/Application/ReadModels/BankImportReadModel.hs`, `Persist.hs`, `Main.hs`, `test/Testkit/InMemoryEventStore.hs`.

- [ ] Express BankImport as a `ReadModel (SqlPersistT IO) AccountingEvent`: `eventHandler` = the existing `handleBankImportEvents` adapted to a single `GlobalStreamEvent`; `initialize = runMigration migrateBankImport`; `checkpointStore = postgresqlCheckpointStore bankImportProjectionName`; `reset = resetBankImport`.
- [ ] Register it; remove its bespoke wiring in `Main`/Persist and the `createReadModelHandlersFrom handleBankImportEvents` hookup.
- [ ] Test harness: the SQLite writer must also use the global publisher path so the sync driver runs in tests (mirror production wiring with `publishingGlobalTaggedCodecEventStoreWriter` + `readModelPublisher`).
- [ ] `just build`; `cabal build -fci` (lib+exe); full `just test` green (BankImport specs + backfill/rebuild specs adapted to eventium `catchUpReadModel`/`rebuildReadModel`).
- [ ] Commit Part A.

---

## Part B — Migrate the Account read model

### B1. `PersistField` instances for Account column types

**Files:** `src/Infrastructure/Database/Orphans.hs` (+ round-trip spec).

- [ ] Add `PersistField`/`PersistFieldSql` for `AccountRole`, `AccountStatus`, and `Money` (scalar columns for filtering); `AccountType`/`AccountSubtype` may be JSONB (not filtered on) — decide per query needs. `Currency` if needed for balance.
- [ ] Round-trip property tests for each (in `Infrastructure.Database.OrphansSpec`).

### B2. `accounts` + `account_access` schema + apply

**Files:** `src/Application/ReadModels/Account.hs`.

- [ ] Entities: `AccountEntity sql=accounts (id, name, balance, createdBy, accountType, overdraftLimit, hasTransactions, status, version)` + `AccountAccessEntity sql=account_access (accountId, userId, role)` with unique `(accountId, userId)` and an index on `userId`. `migrateAccount`.
- [ ] Idempotent `SqlPersistT` apply over `GlobalStreamEvent`:
  - `AccountCreated` → upsert account row; insert owner `account_access` row; `version = event's per-stream version`.
  - access granted/revoked → upsert/delete `account_access`; `version` from event.
  - debit/credit/reversal → `balance ± amount`, `hasTransactions = True`, `version` from event. (Safe: sync driver ⇒ applied once.)
  - rename/close/reopen/overdraft/subtype → set field; `version` from event.
  - **Record `version` from `globalEvent.payload.position`** — not `account.version + 1`.
- [ ] `reset = deleteWhere [] accounts + account_access`.
- [ ] Decide the `(streamKey, version, payload)` accessor (extend `unpackGlobalEvent` vs upstream to eventium) — implement the chosen one.

### B3. Indexed queries replacing the scans

**Files:** `src/Application/ReadModels/Account.hs`.

- [ ] `getAccessibleAccounts userId` → `SELECT a.*, x.role FROM accounts a JOIN account_access x ON x.account_id = a.id WHERE x.user_id = ?` (index on `user_id`).
- [ ] `getAccessibleAccountIds`, `getUserRegularAccounts` (filter `created_by = ?` + regular type), `getAccount`, `getAccountForUser` (join role), `accountExists`, `getAllAccounts` (reporting), all as indexed `SqlPersistT` queries.
- [ ] `balanceAsOf`/`foldBalanceAsOf` stay (event-store replay); unaffected.

### B4. Wire Account as a persistent `ReadModel`; migrate consumers

**Files:** `Persist.hs`, `Main.hs`, `App.hs`, `EventDispatch.hs`, and the ~25 consumer call sites (`AccountService`, `TransactionHistoryService`, `ReportingService`, `BankImportService`, `ConfigurationService`, `Web/API/*`, `Telegram/Commands.hs`).

- [ ] Register Account's `ReadModel`; add `migrateAccount` to migrations.
- [ ] Replace every `view accountReadModelL` + `ReadModel.getX tvar …` with `runDb (ReadModel.getX …)`.
- [ ] Remove `accountReadModel` from `AppEnv`/`ReadModels`/`HasReadModel`; drop the in-memory `AccountReadModel`/`handleAccountEvents`/`createAccountReadModel`.
- [ ] Update the test harness construction accordingly.

### B5. Tests + verification

- [ ] Integration: tenant isolation (A never sees B's accounts), shared-account visibility (grantee sees a shared account via `account_access`), rebuild correctness, **version recorded from event** (apply an event twice ⇒ same version + balance, proving idempotency under the sync driver).
- [ ] Port existing Account read-model unit specs to DB-backed (SQLite harness).
- [ ] `just build`, `cabal build -fci` (lib+exe), `just test`, `just check` all green.
- [ ] Commit Part B.

---

## Out of scope (later phases)
- Transaction, User, Configuration, ExchangeRate migrations (same pattern; `version + 1` removed there too).
- Upstreaming the global-event accessors to eventium (unless chosen in B2).

## Done criteria
- Account served from `accounts`/`account_access`; `getAccessibleAccounts` is an indexed join, no scans.
- Persistent read models run as eventium `ReadModel`s via `readModelPublisher`; bespoke `Backfill` gone.
- `version + 1` derivation removed from migrated models (recorded from events).
- All gates green; backend on eventium 0.4.0 (local branch).
