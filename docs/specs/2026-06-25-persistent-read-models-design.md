---
status: draft
---

# Persistent, Indexed Read Models

## Summary

Migrate the six in-memory `TVar`-backed read models (Account, Transaction, User,
Configuration, BankImport, ExchangeRate) to **persistent, indexed PostgreSQL
tables**, projected from the event log via eventium's `ReadModel` abstraction
with per-model `CheckpointStore`s.

Read-model handlers continue to run **synchronously inside the event-append
transaction** (strong consistency, atomic with the command + saga cascade); the
checkpoint advances in that same transaction. Queries become indexed SQL instead
of in-process map scans.

This is the implementation of #51, deliberately scoped to **queryable indexed
tables** (not serialized blobs). Doing so resolves the two scaling problems
tracked in #110 — cross-tenant full-map scans and unbounded in-process memory
growth — as a side effect of moving derived state into an indexed store, so
**#110 is superseded by this work** (no per-tenant in-memory partitioning, TTL,
or eviction machinery is built).

## Motivation

Today (`src/Infrastructure/Eventium.hs`, `src/Application/ReadModels/*`):

- Each read model is a single global `TVar` wrapping a flat `Map`, shared across
  all users.
- On every startup, `replayWith globalReader handlers` re-reads the **entire**
  global event stream from sequence 0 into memory. Replay cost and memory both
  grow monotonically with the whole event log / user base; nothing is ever
  evicted, and read models are lost on restart.
- Access control is enforced at **query time** by scanning global maps:
  `getAccessibleAccounts` (`Application/ReadModels/Account.hs`) walks **every**
  account filtering by `accessList`; `listTransactions`
  (`Application/ReadModels/Transaction.hs`) walks **every** transaction. Lookup
  cost is O(all users), not O(requesting user).

Moving derived state into indexed Postgres tables fixes all of this with
standard database mechanics:

- Per-user lookups become indexed joins — O(that user's data).
- Process memory is bounded by the connection pool / query working set, not the
  event log.
- Read models survive restarts and are shared across horizontally-scaled
  instances.
- Read-model schemas become freely evolvable: change shape → reset + rebuild
  from the event log (the source of truth), consistent with the project's
  "no backward-compatibility phase" constraint.

## Goals

- Replace all six in-memory read models with persistent, indexed Postgres tables.
- Eliminate every full-map scan; replace with indexed queries scoped to the
  requesting user.
- Project synchronously in the event-append transaction (strong consistency,
  read-after-write preserved), advancing an eventium `CheckpointStore` in the
  same transaction.
- Provide per-model startup catch-up (replay only events past the checkpoint)
  and an on-demand full-rebuild path.
- Cover tenant isolation, shared-account visibility, and rebuild correctness
  with tests.

## Non-Goals

- Per-tenant in-memory partitioning / TTL / eviction (#110's original approach —
  superseded here).
- Tenancy in the **event store** (no `tenant_id` column, no per-tenant
  ordering). Global ordering is preserved — it is load-bearing for
  subscriptions, checkpoints, and the cross-aggregate process managers
  (`transferProcessManager`, `transferAmendmentProcessManager`,
  `transactionCancellationProcessManager`, wired in `app/Main.hs`).
- Eventual-consistency / async projections. The machinery (checkpoints, reset,
  replay) is adopted, but live updates remain synchronous. Individual models can
  be peeled off to async later without rework.
- A household / multi-configuration tenancy model. The product is a personal
  finance tracker; every user shares the singleton `defaultConfigurationId`. The
  effective isolation unit is `UserId`, and shared accounts are modeled as a
  many-to-many relation (see below).
- Write-throughput scaling (the events-table exclusive-lock critical section).
  Tracked separately if it becomes the bottleneck.

## Consistency & Recovery Model

**Single transaction, strong consistency.** The event store and read models live
in the same PostgreSQL database. The synchronous publisher
(`accountingEventStoreWriter` in `Infrastructure/Eventium.hs`) already runs
read-model handlers and process managers inside the writer's `SqlPersistT`
transaction, executed via one `runSqlPool` (`runDbDirect`). For a single command,
the entire cascade — command events, projection writes, process-manager
reactions, saga-emitted events, and *their* projection writes — commits or rolls
back atomically.

Consequences:

- The classic dual-write problem does not arise: "event stored but projection
  not" is impossible on the happy path (one ACID commit).
- Read-after-write holds, including across saga-generated events. Services that
  append an event and then immediately read the result back from a read model
  (e.g. `AccountService.createAccount`) keep working unchanged — the writer's
  transaction commits before the service's follow-up `runDb` read begins.
- Process managers read aggregate state from the **event store**
  (`versionedReader`/`globalReader`), never from read models, so the projection
  consistency model does not affect saga correctness.

**Discipline to keep this safe.** Because a projection write that throws would
roll back the legitimate domain/saga events, projection applies MUST be:

- **Total** — pure upserts keyed by entity id; no failable constraints on valid
  data. A throw indicates a deploy-time bug (caught by tests), not a runtime data
  condition.
- **Idempotent** — applying an event twice equals applying it once. This makes
  replay, startup catch-up, and rebuild always safe, and tolerates any redundant
  re-application from catch-up.

**Live writes are durable and in-transaction**, including writes from other
horizontally-scaled instances (the projection tables are shared state in
Postgres). This rests on one invariant: **every event write goes through the
synchronous publisher** (true today via `accountingEventStoreWriter`), so no
committed event skips its in-transaction projection write. Backfill/rebuild are
the only deliberate exceptions.

**Checkpoint is advanced only by the replay path, not the live path.** A subtlety
in the current wiring forces this: on the live path, `createReadModelHandlersFrom`
(`Infrastructure/Eventium.hs`) wraps each event as `StreamEvent () 0 …` —
position `0`, fabricated. The real global `SequenceNumber` exists only on the
**replay path** (the global reader). So the live in-transaction handler cannot
know its own global sequence and does not touch the checkpoint. The checkpoint —
an eventium `CheckpointStore` (`postgresqlCheckpointStore (CheckpointName
"<model>")`, persisted in `projection_snapshots`) — is written only by
backfill/rebuild, which read the global reader and have real positions.

**Startup = bounded, idempotent catch-up (replaces full replay).** Per model, run
backfill from `checkpoint + 1` in batches, applying events and advancing the
checkpoint per batch to the latest position. Because the live path does not
advance the checkpoint, this **re-applies the events written since the last
checkpoint advance** — bounded by the previous run's write volume, not by total
history, and into a durable table rather than rebuilt-from-zero memory. It
replaces today's unconditional `replayWith globalReader handlers` from sequence 0
into in-memory `TVar`s on every boot.

**Idempotency discipline (the load-bearing requirement).** Because boot catch-up
re-applies events the live path already applied, projection applies MUST be
idempotent:
- **Pure-insert projections** (BankImport dedup, identity indexes) are naturally
  idempotent — re-inserting the same key is a no-op (`repsert`/`INSERT … ON
  CONFLICT DO NOTHING`).
- **Accumulating projections** (e.g. `accounts.balance`, which folds
  `AccountDebited`/`AccountCredited` deltas) are NOT idempotent under naive
  re-application. They must guard by **per-aggregate stream version**: store the
  last-applied `EventVersion` per row and apply an event only when its version
  exceeds the stored one.

The BankImport pilot needs only natural upsert idempotency. The exact mechanism
for accumulating models — a per-aggregate version guard, vs. a future eventium
change that threads the real global `SequenceNumber` to live handlers (which would
let live writes advance the checkpoint and eliminate boot catch-up entirely) — is
decided in the **Account** phase, not here.

**On-demand rebuild** (also the schema-evolution path): reset one model's tables
+ checkpoint, replay from the log, via eventium's `reset` / `rebuildReadModel`.
Per-model, so one projection can be rebuilt without touching the others.
Triggered by a CLI/env flag — no new admin API surface.

## Architecture

### Tenant isolation via indexes, not partitions

The effective tenant is `UserId`. Isolation is delivered by indexed SQL, not by
partitioning the store. The shared-account relation (`accessList`, a single
account visible to several users) — awkward to model in memory — becomes a
normalized many-to-many table:

```
account_access(user_id, account_id, role)     -- index on user_id
```

- `getAccessibleAccounts userId`:
  `SELECT a.* FROM accounts a JOIN account_access x ON x.account_id = a.id
   WHERE x.user_id = ?` — O(that user's accounts). A shared account simply has
  multiple `account_access` rows; no duplication, no resident visibility index.
- `listTransactions visible filter page`:
  ```sql
  SELECT * FROM transactions
  WHERE (source_account_id IN (visible) OR target_account_id IN (visible))
    AND date BETWEEN ? AND ? AND status = ? AND <label filter>
  ORDER BY date DESC LIMIT ? OFFSET ?
  ```
  where `visible` derives from `account_access`. Indexed and paginated in the DB.

### Per-read-model schema

Fields used for filtering/lookup become real (indexed) columns; genuinely opaque
payload fields may be JSONB.

| Read model | Tables (sketch) | Key indexes |
|---|---|---|
| **Account** | `accounts(id, name, balance, created_by, account_type, overdraft_limit, has_transactions, status, version)`; `account_access(account_id, user_id, role)` | `account_access(user_id)`; `accounts(created_by)` |
| **Transaction** | `transactions(id, source_account_id, target_account_id, source_amount, target_amount, exchange_rate?, description, status, transaction_type, date, amendment_count)`; `transaction_labels(transaction_id, label_id)` | `transactions(source_account_id)`, `(target_account_id)`, `(date)`; `transaction_labels(label_id)` |
| **User** | `users(id, email?, has_password, external_account_id, configuration_id, version)`; `user_oauth(user_id, provider, subject)`; `user_telegram(user_id, telegram_id)` | unique `users(email)`, unique `user_oauth(provider, subject)`, unique `user_telegram(telegram_id)` |
| **Configuration** | `configurations(id, base_currency, default_currency, default_income_category?, default_expense_category?, books_closed_through?, created_by, version)`; `dictionary_entries(config_id, dictionary_id, entry_id, name)`; bank-connection tables | `dictionary_entries(config_id)` |
| **BankImport** | `imported_transactions(external_transaction_id PK, transaction_id)` | unique `external_transaction_id` |
| **ExchangeRate** | `exchange_rates(provider, day, base, quote, rate)` | `(provider, day)` |

Domain value types (`Money`, `AccountRole`, currencies, status enums) get
`PersistField` instances — scalar columns where we filter, JSONB only for opaque
blobs.

The account **owner** is the single column `accounts.created_by` (decided). The
`account_access` table records granted access (including the owner's own
`Owner` row for uniform access queries), but `accounts.created_by` is the
authoritative owner field.

### Module organization & layering

- **Entity definitions** are co-located with each read model in
  `Application/ReadModels/*`, using persistent's quasi-quoter, importing
  persistent via `Infrastructure.Database` re-exports. (Legal under the layering
  rules: Application may import Infrastructure. Read models are an Application
  concern and stay self-contained.)
- Each `Application/ReadModels/X.hs` exposes:
  - the persistent entity/entities + `migrateX`,
  - the event→row **apply** handler (`SqlPersistT m`, total + idempotent upserts),
  - **query** functions returning `SqlPersistT m a`.
- **Domain stays pure** — no persistent imports in `Domain.*`.

### Wiring changes

- `AppEnv` (`Infrastructure/App.hs`): remove the read-model `TVar` fields and
  their capability classes. Note the fields are split across classes today:
  account/transaction/user/configuration live under `HasReadModel`, while
  ExchangeRate and BankImport have their own classes
  (`HasExchangeRateReadModel`, `HasBankImportReadModel` via `BankingEnv`) — all
  are removed as their models migrate. Read models are no longer in-process
  state.
- Services: replace `view <model>ReadModelL` + `ReadModel.getX tvar …` with
  `runDb (ReadModel.getX …)`. Mechanical but broad — `AccountService`,
  `TransactionService`, `UserService`, `ConfigurationService`, banking services,
  bot handlers.
- `runMigrations` (`Infrastructure/Database.hs`): add each `migrateX` (the hook
  and TODO already exist there).
- Startup (`app/Main.hs`): replace `replayWith globalReader handlers` with
  per-model **batched, idempotent catch-up from the checkpoint** (read
  checkpoint, replay `checkpoint+1 →` latest in batches via the global reader,
  advancing the checkpoint per batch); wire each read model's `CheckpointStore`.
- Config (`Infrastructure/Config.hs`): optional `readModels:` section only if
  knobs are needed (e.g. rebuild-on-startup flag). Minimal initially.

## Testing

- **Integration**: tenant isolation (user A's queries never return user B's
  accounts/transactions); shared-account visibility (a grantee sees a shared
  account through `account_access`); rebuild correctness (reset + replay
  reproduces identical query results).
- **Property**: apply-idempotency (apply-twice == apply-once); catch-up
  equivalence (replay from checkpoint N == full replay) for each handler.
- **Migrated unit specs**: existing read-model unit tests ported from TVar
  assertions to DB-backed assertions, using the test database harness.

## Rollout (incremental — each step independently shippable)

1. **Foundation + pilot** — migration plumbing, checkpoint-in-transaction
   pattern, startup catch-up, rebuild op; proven on **BankImport** (tiny, no
   read-after-write criticality).
2. **Account** — the headline #110 win (`account_access` join table; removes the
   `getAccessibleAccounts` scan).
3. **Transaction** — removes the `listTransactions` scan.
4. **User**, **Configuration**, **ExchangeRate** — fast-follow.

The spec describes the full target architecture; the implementation plan executes
it phase by phase. Phases 1–3 are the committed scope of this effort; 4 is
fast-follow.

## Risks & Mitigations

- **Projection write aborts a command/saga.** Mitigated by total + idempotent
  applies (upsert-by-id, no failable constraints); a throw is a deploy-time bug
  surfaced by tests, recoverable by rebuild.
- **Longer events-table lock critical section** (projection writes extend the
  write critical path). Accepted for now (low write volume, personal finance);
  escape hatch is moving a model to async, machinery already present.
- **Read-after-write regressions** during the service migration. Mitigated by the
  single-transaction model (writer commits before follow-up read) and by
  integration tests on the create→read-back flows.
- **`PersistField` correctness for domain types.** Covered by round-trip property
  tests on the new instances.

## References

- Supersedes the in-memory approach in #110 (per-tenant partitioning + TTL).
- Implements #51 (eventium `ReadModel` adoption), scoped to indexed tables.
- eventium: `Eventium.ReadModel` (`ReadModel`, `rebuildReadModel`, `reset`),
  `Eventium.EventSubscription` (`CheckpointStore`),
  `Eventium.ProjectionCache.Sql` (`postgresqlCheckpointStore`,
  `migrateProjectionSnapshot`), example
  `examples/bank/src/Bank/ReadModels/Transfers.hs`.
