---
status: completed
---

# Persistable Exchange Rate History Design

**Date:** 2026-04-20
**Issue:** homeaccounting/backend#43

## Problem

Exchange rates published by the configured provider (ECB or NBU) are currently held only in an in-memory `IORef` inside `Infrastructure.ExchangeRate.Store`. Nothing survives a restart. With bank transaction imports and backdated-transaction entry now landing, we need the rate history to persist so that:

- A backdated transaction entered on day N can be valued with the rate that was in effect on its actual occurrence date, not whatever is cached today.
- Bank imports that pull multi-day statements can pick the correct day's rate for each transaction.
- Restarts, deploys, and migrations do not erase accumulated rate history.

Two TODO comments already acknowledge the gap — `Infrastructure/ExchangeRate/Store.hs:107` and `app/Main.hs:327`. Issue #43's suggested direction is "push app-level events on the global event-stream when exchange rate is published for a specific date," reusing the existing Eventium event store.

## Design

### Summary

Exchange-rate publications become a new variant of the unified `AccountingEvent` sum type, persisted through the existing PostgreSQL-backed event store. One event stream per provider keeps histories isolated so that a provider switch does not overwrite or interleave histories. A dedicated read model owns the in-memory `Day → ExchangeRateMap` projection and is populated via the same replay plumbing that already rebuilds the other read models on startup. A background scheduler publishes rates once per 24 hours.

The existing `Infrastructure.ExchangeRate.Store` module is **removed**. Its responsibilities split cleanly:

- Projection state and lookup → `Application.ReadModels.ExchangeRate`
- Publishing (fetch + event emit + scheduling) → `Application.Services.ExchangeRatePublisher`

### Event Modeling

`ExchangeRateEvent` moves from `Infrastructure.ExchangeRate.Store` to a new Domain module:

```
src/Domain/ExchangeRate/Events.hs
```

Contents:

```haskell
data ExchangeRateEvent
  = ExchangeRatesPublished
      { provider :: !Text,
        rates :: !ExchangeRateMap
      }
  deriving (Show, Eq, Generic)

type ExchangeRateMap = Map (Currency, Currency) ExchangeRate
```

The event date (what day these rates are for) is carried in the Eventium
`EventMetadata.occurredAt` field rather than the payload, mirroring the pattern
already used by `TransferInitiated` and the rest of the codebase since the
backdated-transactions work (see
`docs/specs/2026-04-10-backdated-transactions-design.md`). `occurredAt` is the
project's canonical "when this happened in the real world" timestamp, distinct
from `createdAt`. Using it here means a future historical-backfill feature can
stamp past rates with past `occurredAt` values without changing the payload
schema.

Rationale for a Domain placement:

- Rate-publication facts are business-relevant (they determine which rate applies to a backdated or imported transaction).
- `Currency` and `ExchangeRate` — which this type references — already live in Domain (`Domain.Core.Types`).
- Domain may not import Infrastructure, so `AccountingEvent` (defined in `Domain.Models`) cannot include an Infrastructure-defined event directly.

`ExchangeRateMap` moves here rather than remaining in `Infrastructure.ExchangeRate.Provider` because the event type contains it. `Provider.hs` re-exports it so consumers that already import from there continue to compile.

The module exports a TH-list `exchangeRateEvents :: [Name]` consumed by `constructSumType` in `Domain.Models` — the same mechanism already used for account/transaction/user/configuration event lists.

### Unified Event Type

`Domain.Models` appends `exchangeRateEvents` to the list passed to `constructSumType "AccountingEvent"`. The resulting sum gains one new variant named `ExchangeRatesPublishedEvent` (the `Event` suffix is added automatically by the existing tag-options pipeline).

A `TypeEmbedding` is generated for completeness so the event can be projected across the unified type if future code needs it:

```haskell
mkSumTypeEmbedding "exchangeRateEventEmbedding" ''ExchangeRateEvent ''AccountingEvent
```

No `CommandEmbedding` is added. Rate events are not command-sourced — they are externally observed facts fetched from a provider and appended directly. This mirrors how external-fact events are already handled elsewhere (e.g., `BankAccountsLinked` in the bank-integration design).

### Event Stream Identity

Each provider writes to its own stream, keyed by a deterministic UUID derived from the provider name:

```haskell
-- Application/Services/ExchangeRatePublisher.hs
providerStreamId :: Text -> UUID
providerStreamId name = uuidV5 exchangeRateNamespace (encodeUtf8 name)
  where
    exchangeRateNamespace = UUID.fromWords 0xEA... -- fixed namespace constant
```

(Exact namespace UUID picked once, constant, checked into source.)

Properties:

- `providerStreamId "ecb"` and `providerStreamId "nbu"` produce stable, distinct UUIDs across restarts.
- Switching providers leaves prior history intact on the old stream. A future merge/fallback provider (mentioned in the existing pluggable-providers spec) can read both streams.
- Optimistic concurrency via `(uuid, version)` naturally prevents a race between two publish attempts for the same provider stream.

### Read Model

New module `src/Application/ReadModels/ExchangeRate.hs`, following the exact shape of the existing read models (`Account`, `Transaction`, `User`, `Configuration`, `BankImport`):

```haskell
data ExchangeRateReadModel = ExchangeRateReadModel
  { historyByProvider :: !(Map Text (Map Day ExchangeRateMap))
  }

createExchangeRateReadModel :: (MonadIO m) => m (TVar ExchangeRateReadModel)

handleExchangeRateEvents ::
  (MonadIO m) =>
  TVar ExchangeRateReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
```

- Projection keyed by provider so histories are addressable per-source. For a lookup, the caller knows which provider is currently active (via config); the read model is queried for that provider. A future multi-provider query can read across keys.
- `handleExchangeRateEvents` filters for `AccountingExchangeRatesPublishedEvent` variants and folds them into the TVar. Non-matching events are silently skipped — the standard read model pattern. For each matching event, the day key is `utctDay <$> metadata.occurredAt`; events with `occurredAt = Nothing` are logged at warn level and skipped (defensive — writes produced by the publisher always set it).

Query functions live alongside the read model:

```haskell
lookupHistoricalRate ::
  TVar ExchangeRateReadModel ->
  Text ->       -- provider name (from config)
  Day ->
  Currency ->
  Currency ->
  IO (Maybe ExchangeRate)

lookupNearestDate :: Map Day v -> Day -> Maybe (Day, v)
```

The nearest-date fallback (current `Store.lookupNearestDate`) moves verbatim — it is already pure and provider-agnostic.

### Read Model Registration

`Infrastructure.Eventium.ReadModels` gains one more field:

```haskell
data ReadModels = ReadModels
  { account :: TVar AccountReadModel,
    transaction :: TVar TransactionReadModel,
    user :: TVar UserReadModel,
    configuration :: TVar ConfigurationReadModel,
    bankImport :: TVar BankImportReadModel,
    exchangeRate :: TVar ExchangeRateReadModel    -- new
  }
```

`createReadModelHandlers` creates it and appends its handler. `replayReadModels` appends a `handleExchangeRateEvents readModels.exchangeRate events` call. That single addition gives:

- Live updates: whenever `ExchangeRatesPublished` is persisted, the event bus delivers it to the handler and the TVar updates.
- Startup replay: `replayReadModels` rebuilds historical state from disk, same path as all other read models.

No bespoke replay function, no manual `IORef` updates after publish. The projection stays in sync with the event log by the same mechanism as the rest of the system.

### Publisher Service

New module `src/Application/Services/ExchangeRatePublisher.hs`:

```haskell
publishRates ::
  (MonadIO m) =>
  RateProvider ->
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  TVar ExchangeRateReadModel ->
  m (Either Text ExchangeRateEvent)
```

Behavior:

1. Compute `nowUtc <- getCurrentTime`; `today = utctDay nowUtc`.
2. Check the read model TVar for `(providerName, today)` — idempotence. If present, return `Left "already published for today"`.
3. Call `provider.fetchRates`. On `Left`, propagate.
4. Determine the next version by reading the length (or tail) of the provider's stream via the versioned reader. Publishes are rare (≤1/day), so the extra read is negligible.
5. Wrap the payload: `AccountingExchangeRatesPublishedEvent (ExchangeRatesPublished provider.providerName rates)`.
6. Write via the tagged writer, keyed by `providerStreamId provider.providerName` at the computed next version. Pass a `MetadataEnricher` that sets `occurredAt = Just nowUtc` (mirrors `TransferManager.mkEnricher`). For a future backfill call, `occurredAt` would be the historical date instead.
7. Return the event. The event bus (via `accountingEventStoreWriter`'s publishing layer) delivers it to the read model handler — no manual TVar update.

On optimistic concurrency failure (another publish for the same day won the race), log a warning and return `Left`. No retry — the other write already persisted the rates.

```haskell
spawnRatePublisher ::
  RateProvider ->
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  TVar ExchangeRateReadModel ->
  LogFunc ->
  IO (Async ())
```

Behavior:

1. Immediately call `publishRates` (replaces the current startup-only one-shot).
2. Loop forever:
   - Compute delay to next UTC midnight + 5-minute jitter.
   - `threadDelay delay`.
   - `publishRates` (log outcome at info/warn).
   - Catch any synchronous exception, log at error level, continue the loop (do not die).
3. Return the `Async` handle so `Main.hs` can optionally `link` it.

The 5-minute offset past midnight is a small margin to avoid racing ECB/NBU's own publication timing; the existing behavior already picks up "today" on a best-effort basis, so an exact instant is not required.

**Scheduling primitives.** No scheduling library is introduced. The loop uses `threadDelay` (from `base`, re-exported by `rio`) and `async` (from `unliftio`, via `rio`) — the same pattern as the existing Telegram polling loop in `src/Telegram/Bot.hs:84,96`. A cron or scheduler package would be overkill for a single once-daily task, and `backend.cabal` currently contains none. Time computations use `Data.Time` helpers (`getCurrentTime`, `addDays`, `diffUTCTime`) already used across the codebase.

### Infrastructure Changes

`src/Infrastructure/ExchangeRate/Store.hs` is **deleted**. Its replaced responsibilities:

| Responsibility in old `Store.hs` | New home |
| --- | --- |
| `ExchangeRateEvent` type | `Domain.ExchangeRate.Events` |
| `ExchangeRateHistory` + `historyRef :: IORef` | Read-model TVar in `Application.ReadModels.ExchangeRate` |
| `replayRateEvents` | `replayReadModels` (via `handleExchangeRateEvents`) |
| `lookupHistoricalRate`, `lookupNearestDate` | `Application.ReadModels.ExchangeRate` |
| `publishRates` | `Application.Services.ExchangeRatePublisher` |
| `newExchangeRateStore` | (gone — read model + publisher are constructed directly) |

Remaining `Infrastructure/ExchangeRate/`:

- `Provider.hs` — `RateProvider`, `getRate`, `deriveCrossRates`. Re-exports `ExchangeRateMap` from `Domain.ExchangeRate.Events` for backwards compatibility of importers.
- `ECB.hs`, `NBU.hs` — HTTP fetchers, unchanged (they produce `ExchangeRateMap` values, which is now a Domain type but the import path via `Provider` remains valid).

### App Environment

`Infrastructure.App`:

- `HasExchangeRateStore` / `exchangeRateStoreL` → `HasExchangeRateReadModel` / `exchangeRateReadModelL`.
- The field in `AppEnv` holds `TVar ExchangeRateReadModel` instead of `ExchangeRateStore`.
- `initializeAppEnv`'s argument for exchange rates changes type accordingly.

Consumers that look up rates (primarily `Application.Services.TransactionService`) change import from `Infrastructure.ExchangeRate.Store` → `Application.ReadModels.ExchangeRate`. The query signature gains a `providerName :: Text` argument; call sites read the name from `config.exchangeRate.provider` (already in context via `HasAppConfig`).

### Main.hs Wiring

In `initializeEnvironment`:

1. Read models are created (existing call to `createReadModelHandlers`) — now produces the new exchange-rate TVar too.
2. Event store writer/reader are created (existing).
3. `replayReadModels` runs — now also replays exchange-rate events automatically.
4. Replace the existing three-line block (`newExchangeRateStore` / `publishRates`) with:

   ```haskell
   rateProvider <- case config.exchangeRate.provider of
     "nbu" -> pure nbuProvider
     "ecb" -> pure ecbProvider
     unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
   _publisherAsync <-
     liftIO $ spawnRatePublisher rateProvider writer reader readModels.exchangeRate logFunc
   ```

5. Pass `readModels.exchangeRate` (not a store) to `initializeAppEnv`.

The two `TODO: persist …` comments in `Main.hs` and `Store.hs` are deleted.

### Error Handling

- Empty / failed provider fetch at publish time → log warn, scheduler retries next cycle. No crash.
- Event store write conflict (concurrent publisher on a different node) → log warn, treat as benign success.
- Replay failure on startup → fatal, same as current read model replay (fail-fast is project policy).
- Scheduler thread death from an unexpected exception → caught, logged at error, loop continues. The `Async` handle allows `link` from `Main.hs` for diagnostic purposes; production preference is "keep going and alert" rather than "crash the process."

No new `DomainError` variants. Publish failures are logged; they do not surface to domain callers.

### Testing

**Unit / property — read model (new `test/Application/ReadModels/ExchangeRateSpec.hs`):**
- Empty read model returns `Nothing` for any lookup.
- After folding in a single `ExchangeRatesPublished`, exact-date lookup returns the expected rate.
- Nearest-date fallback: property — for an arbitrary sparse history, the looked-up day is the closest by absolute day diff, preferring earlier on tie (matches existing `lookupNearestDate` semantics).
- Provider isolation: events from provider A do not appear when querying provider B.

**Unit — publisher (new `test/Application/Services/ExchangeRatePublisherSpec.hs`):**
- Publishes a single event to the correct stream with version 0 when the stream is empty; written event carries `occurredAt = Just today`.
- Idempotence: second call on the same day returns `Left` and writes no event.
- Version advance: after two publishes on different days, the second is at version 1.
- On provider error, no event is written; result is `Left`.

**Integration (new `test/Integration/ExchangeRatePersistenceSpec.hs`):**
- Publish via the publisher → create a fresh read model from the same event store → replay → `lookupHistoricalRate` returns the persisted rate.
- Uses the existing `Testkit/InMemoryEventStore.hs` infrastructure. Verifies end-to-end that the new read-model path closes the persistence loop.

**Existing tests — adjusted for new signatures, not new logic:**
- `test/Infrastructure/ExchangeRate/StoreSpec.hs`, `StorePropertySpec.hs`, `StoreIntegrationSpec.hs` → move to `test/Application/ReadModels/ExchangeRate*.hs` (content largely preserved; constructor calls updated).
- `test/Infrastructure/ExchangeRate/NBUSpec.hs`, `NBUIntegrationSpec.hs`, `ExchangeRateIntegrationSpec.hs` → imports updated, logic unchanged.
- `test/Application/Services/TransactionServiceSpec.hs` → swap store mock for read-model TVar; no logic changes.
- `test/Testkit/InMemoryEventStore.hs` → if it constructs an `AppConfig`, no change needed here; if it constructs an `AppEnv`, update to use the new read-model field.

### Change Scope Boundary

Out of scope (explicit):

- Historical backfill (fetching pre-deployment dates). Requires `fetchRatesForDate :: Day -> IO ...` on the provider interface; separate issue.
- Provider fallback / merge composition.
- Multi-node leader election for the publisher scheduler. The optimistic concurrency check handles accidental double-publishes correctly; a dedicated leader isn't required for home-scale.
- UI or API surface for inspecting historical rates.

### Migration

No database migration is needed — the event store is schemaless at the event-payload level (JSON). First deploy after merging will:

1. Start with an empty exchange-rate read model on the very first run.
2. The publisher's startup tick writes today's first `ExchangeRatesPublished`.
3. From then on, history accumulates.

No replay issue for existing deployments: the global event reader returns zero matching events for the new variant on pre-existing event logs, so `replayReadModels` sees an empty projection and proceeds normally.

## Open Questions

None — all design decisions were resolved during brainstorming (Q1–Q4).
