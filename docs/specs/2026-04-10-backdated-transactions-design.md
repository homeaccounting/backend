---
status: draft
date: 2026-04-10
---

# Backdated Transactions

## Problem

The accounting system always records transfers with the current timestamp. Users cannot enter transactions that occurred in the past — a common need when logging forgotten purchases, importing bank statements, or correcting records. Additionally, the exchange rate provider only serves today's rates, so cross-currency backdated transfers have no rate to use.

## Goals

1. Allow users to specify a past datetime when creating any transfer (income, expense, internal)
2. Introduce `occurredAt` to eventium's `EventMetadata` — a generic "when this happened in the real world" timestamp, distinct from `createdAt` ("when this was recorded")
3. Replace the in-memory exchange rate cache with an event-sourced rate store that maintains historical rates
4. Propagate `occurredAt` through the transfer saga so all related events share the same business timestamp

## Non-Goals

- Balance-at-date queries (future work, enabled by `occurredAt` on all events)
- Historical rate backfill from provider APIs
- On-demand historical rate fetching
- Sub-second precision for `occurredAt` (UTCTime is used, but practical granularity is seconds)

## Design

### 1. Eventium: `occurredAt` in EventMetadata

Add a new optional field to `EventMetadata` in `eventium-core`:

```haskell
data EventMetadata = EventMetadata
  { eventType :: !Text,
    correlationId :: !(Maybe UUID),
    causationId :: !(Maybe UUID),
    createdAt :: !(Maybe UTCTime),
    occurredAt :: !(Maybe UTCTime)
  }
```

**Semantics:**

- `createdAt` — when the event was persisted (system clock, set by the event store)
- `occurredAt` — when the event happened in the real world (set by the application)
- `Nothing` means "same as `createdAt`" — fully backwards compatible

**Changes required:**

- `emptyMetadata` initializes `occurredAt` to `Nothing`
- New `type MetadataEnricher = EventMetadata -> EventMetadata` — a builder function for metadata customization (see Section 4)
- `metadataEnrichingEventStoreWriter` generates base metadata, then applies the `MetadataEnricher`
- `tagEvents` leaves `occurredAt` as-is
- `applyCommandHandler`, `CommandDispatcher`, `ProcessManagerEffect`, and `runProcessManagerEffects` all accept/thread a `MetadataEnricher` (see Section 4)
- PostgreSQL backend: no schema change needed — `occurredAt` is serialized into the existing JSONB `metadata` column via the `Generic`-derived `ToJSON`/`FromJSON` instances
- In-memory backend: carried in metadata, no special handling
- Testkit: updated to support the new field
- Update `docs/architecture.md` in eventium: document `occurredAt` field, `MetadataEnricher` type, updated `applyCommandHandler`/`CommandDispatcher`/`ProcessManagerEffect` signatures
- Bump minor version of all eventium packages

### 2. Event-Sourced Exchange Rate Store

Replace the current `IORef`-based `ExchangeRateCache` with an event-sourced store.

**Event:**

```haskell
data ExchangeRateEvent
  = ExchangeRatesPublished
      { date :: Day,
        provider :: Text,
        rates :: ExchangeRateMap
      }
```

This is an application-level event stored in a dedicated stream (single stream, not per-aggregate). The stream key is a well-known UUID constant.

**Read model:**

```haskell
type ExchangeRateHistory = Map Day ExchangeRateMap
```

Rebuilt on startup by replaying all `ExchangeRatesPublished` events. Each event overwrites the entry for its `date` (last-write-wins if multiple fetches for the same day).

**Rate lookup:**

```haskell
lookupRate :: ExchangeRateHistory -> Day -> Currency -> Currency -> Maybe ExchangeRate
```

1. Exact date match — use it
2. No exact match — nearest available date (prefer earlier date, fall back to later if no earlier exists)
3. No rates at all — return `Nothing` (caller must handle)

**Daily fetch:**

On first request after UTC midnight (same lazy-refresh trigger as the current cache), fetch from the configured provider and append an `ExchangeRatesPublished` event. This also updates the in-memory map.

**Startup sequence:**

1. Replay all `ExchangeRatesPublished` events → populate `ExchangeRateHistory`
2. If no entry exists for today, fetch from provider and append event

**Migration:**

The `ExchangeRateCache` type with its `IORef (Maybe (UTCTime, ExchangeRateMap))` is removed. The `RateProvider` abstraction (ECB/NBU) remains unchanged — only the storage/caching layer changes.

### 3. Backdated Transfers

**API changes:**

All three request DTOs gain an optional `date` field:

```haskell
data IncomeRequest = IncomeRequest
  { accountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    description :: Text,
    date :: Maybe UTCTime        -- new, optional
  }
```

Same for `ExpenseRequest` and `InternalTransferRequest`.

- Format: ISO 8601 datetime string with seconds precision, e.g. `"2026-03-15T14:30:00Z"`
- Omitted or `null` — defaults to current time (`getCurrentTime`)
- Seconds precision

**Validation:**

- Date must not be in the future (compared against current time)
- No minimum bound — any past date is valid

**Domain flow:**

1. Handler parses optional `date`, defaults to `getCurrentTime`
2. `TransactionService.resolveAmounts` gains a `Day` parameter (derived from `utctDay date`) and uses it for rate lookup from the event-sourced rate store instead of always fetching today's rate
3. `InitiateTransfer` command is executed; the resulting `TransferInitiated` event gets `occurredAt` set in its `EventMetadata`
4. `TransferManager` propagates `occurredAt` from the `TransferInitiated` event metadata to all saga-produced events:
   - `AccountDebited` — inherits `occurredAt`
   - `AccountCredited` — inherits `occurredAt`
   - `TransferCompleted` — inherits `occurredAt`

**Read model changes:**

`TransactionData` gains a new field:

```haskell
data TransactionData = TransactionData
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    status :: TransactionStatus,
    transferType :: TransferType,
    date :: UTCTime                    -- new
  }
```

Populated from `occurredAt` of the `TransferInitiated` event (falling back to `createdAt` if `occurredAt` is `Nothing`, for backwards compatibility with pre-existing events).

**Response DTO changes:**

```haskell
data TransactionResponse = TransactionResponse
  { id :: UUID,
    -- ... existing fields ...
    date :: Text                       -- new, ISO 8601
  }
```

### 4. Metadata Enricher — Unified `occurredAt` Propagation

The `TransferManager` needs to propagate `occurredAt` from the originating `TransferInitiated` event to all saga-produced events (`AccountDebited`, `AccountCredited`, `TransferCompleted`). The `TransactionService` also needs to set `occurredAt` on the initial `TransferInitiated` event.

**Problem:** The current eventium pipeline has no mechanism for threading metadata through command dispatch. The flow is:

1. `ProcessManagerEffect` (`IssueCommand UUID command`) carries no metadata
2. `CommandDispatcher.dispatchCommand` passes `(UUID, command)` to `applyCommandHandler`
3. `applyCommandHandler` calls `writer.storeEvents` which goes through `metadataEnrichingEventStoreWriter`
4. `metadataEnrichingEventStoreWriter` auto-generates metadata with `createdAt = now`, `occurredAt = Nothing`

**Solution — `MetadataEnricher` builder function:**

A single mechanism threaded through the entire command pipeline:

```haskell
type MetadataEnricher = EventMetadata -> EventMetadata
```

- Default (no override): `id`
- Set occurredAt: `\m -> m { occurredAt = Just someTime }`
- Composable: `enricher1 . enricher2` for multiple fields

**Eventium changes — single path through `applyCommandHandler`:**

```haskell
applyCommandHandler ::
  (Monad m) =>
  VersionedEventStoreWriter m event ->
  VersionedEventStoreReader m event ->
  CommandHandler state event command err ->
  MetadataEnricher ->
  UUID ->
  command ->
  m (Either (CommandHandlerError err) [event])
```

`metadataEnrichingEventStoreWriter` generates the base metadata (`eventType`, `createdAt`), then applies the enricher before writing.

The enricher flows through the entire dispatch chain:

```haskell
-- CommandDispatcher accepts enricher
newtype CommandDispatcher m command = CommandDispatcher
  { dispatchCommand :: UUID -> command -> MetadataEnricher -> m CommandDispatchResult
  }

-- ProcessManagerEffect carries enricher
data ProcessManagerEffect command
  = IssueCommand UUID command MetadataEnricher
  | IssueCommandWithCompensation UUID command MetadataEnricher (RejectionReason -> [ProcessManagerEffect command])

-- runProcessManagerEffects threads enricher into dispatchCommand
```

Callers that don't need metadata enrichment pass `id`. No special variants, no `Maybe`, no wrapper types.

**Backend usage — both paths use the same mechanism:**

*TransactionService (initial command):*

```haskell
let enricher = \m -> m { occurredAt = Just userDate }
applyCommandHandler writer reader handler enricher uuid cmd
```

*TransferManager (saga commands):*

The react function reads `occurredAt` from the `TransferInitiated` event's metadata and builds an enricher:

```haskell
let enricher = case event.metadata.occurredAt of
      Just t  -> \m -> m { occurredAt = Just t }
      Nothing -> id
```

Then passes it via `IssueCommand uuid cmd enricher` and `IssueCommandWithCompensation uuid cmd enricher onFailure`.

The `TransferData` tracking type gains an `occurredAt :: Maybe UTCTime` field, populated from the `TransferInitiated` event metadata, so it's available when reacting to subsequent events (`AccountDebited`).

This ensures all events in a transfer saga share the same business timestamp, regardless of when the saga steps actually execute.

## Cross-Cutting Concerns

**Backwards compatibility:**

- All existing events have `occurredAt = Nothing`, which is interpreted as "same as `createdAt`"
- Existing API clients can omit `date` — behavior is identical to today
- The exchange rate store starts empty; the first fetch populates it

**Cross-currency backdated transfers:**

- Rate lookup uses nearest available date from the event-sourced history
- If no rates exist at all (fresh system, no history), the transfer is rejected with an error suggesting the user provide a manual exchange rate
- Same-currency transfers are unaffected by rate availability
- No maximum staleness threshold — arbitrarily old rates may be used for nearest-date fallback. This is acceptable for a personal accounting app where the user can always override with a manual exchange rate. The user-provided rate always takes precedence over the looked-up rate.

**Ordering:**

- Event store ordering remains by `createdAt` / sequence number (append order)
- `occurredAt` is purely informational metadata — it does not affect event replay order
- Read models that need date-based ordering (e.g., transaction list) sort by `occurredAt`
