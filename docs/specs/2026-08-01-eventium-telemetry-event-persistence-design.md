---
status: draft
issues: [homeaccounting/tracker#49, aleks-sidorenko/eventium#10]
---

# Eventium telemetry: a generic structured signal sink (event-persistence slice)

## Context

The operator has no usable observability. eventium runs almost silent: nothing
logs when an event is persisted, no metric counts writes, and there is no way to
filter by user or trace a request. tracker#49 asks for operator-facing logging &
metrics in Grafana, filterable by `user-id` / correlation id; eventium#10 asks
for first-class lifecycle observability across all of eventium.

This spec is **Spec 1 of that effort** — the foundation. It establishes *one*
generic observability mechanism in eventium and implements it for the
**event-persistence (write) path** only. Later specs consume it from the app
(structured logger + Prometheus, correlation/user-id enrichment, Grafana — Spec
2) and extend it to the other subsystems (read models, subscriptions, checkpoint
cache, command dispatch, process managers — Spec 3).

### Why a sink, not per-mechanism hooks, and not a logging framework

Three shapes were considered:

1. **Per-subsystem observer records** (`EventStoreObserver`, `ReadModelObserver`,
   … one per subsystem, mirroring the existing `RetryConfig` callback record).
   Granular, but grows N bespoke records + N wiring points.
2. **A logging framework inside eventium** (`monad-logger`/`katip` with pluggable
   backends, configured in the app). Rejected:
   - It only solves *logging*. **Metrics are not a logging backend** — Prometheus
     counters/histograms cannot be emitted through katip/monad-logger, so the app
     would have to derive metrics by parsing log lines. tracker#49's headline
     deliverable is metrics in Grafana; this shape cannot produce them without a
     *second* mechanism, leaving us with both a framework dependency and hooks.
   - It **breaks eventium-core's defining property**: core depends only on `base,
     aeson, containers, contravariant, http-api-data, path-pieces,
     template-haskell, text, time, transformers, uuid` — zero logging frameworks.
     A `MonadLogger`/`Katip` constraint forces that framework on every consumer
     and pushes level/format decisions into the library.
3. **One generic structured signal sink** (chosen). Collapses the N records into a
   single `Telemetry` sink over one `Signal` sum type. eventium emits typed
   values; the app supplies one interpreter that does logging **and** metrics
   **and** context enrichment, and wires it once. This keeps eventium
   framework-free and structured while giving the app a single integration point.

The app still gets "a real logging framework with pluggable backends, configured
in the app" — it just lives at the *app boundary* (where RIO / `monad-logger`
already are), fed structured signals, rather than inside eventium. `contravariant`
is already a core dependency, so a `LogAction`-shaped contravariant sink is
idiomatic there.

## Goals

- One generic, framework-free, structured observability mechanism in
  eventium-core, extensible to every subsystem.
- Implement it for the write path: emit a signal when events are persisted and
  when an optimistic-concurrency write conflict occurs.
- Let the app attach arbitrary context (notably `user-id`) to the event envelope
  so it survives detached saga/process-manager writes and is available to the
  signal — without baking any app concept into the generic library.
- Zero behaviour change and full backward compatibility: silent by default, old
  stored rows still decode.

## Non-goals (deferred)

- App-side interpreter (structured logger, Prometheus, `/metrics`, Grafana),
  correlation/user-id enrichment at the request boundary — **Spec 2 (tracker#49
  Half A)**.
- Telemetry for read models, subscriptions, checkpoint cache, command dispatch,
  process managers, and store **reads** — **Spec 3**.
- Write latency / timing signals — added when Spec 2's metrics need them.
- Migrating existing app-side command-*rejection* logging
  (`Application/Services/Internal.hs`) onto telemetry — that is command-dispatch,
  handled in Spec 3.

## Design

### 1. `Eventium.Telemetry` — the sink and signal (new module, eventium-core)

```haskell
-- | A structured telemetry sink: the app supplies one interpreter; eventium
-- emits typed 'Signal's through it. No logging-framework dependency — a
-- 'LogAction'-shaped contravariant sink over a domain signal type.
newtype Telemetry m = Telemetry { emit :: Signal -> m () }

-- | Everything eventium can report, across all subsystems. One growing closed
-- sum type. This spec introduces only the write-path constructors; later specs
-- add read-model / subscription / dispatch / process-manager constructors to the
-- same type. (Adding a constructor makes app interpreters' exhaustive matches
-- warn — a desired nudge that a new signal exists.)
data Signal
  = -- | Events were durably written on the versioned (aggregate) write path.
    -- Carries the stream 'UUID' (eventium's own stream identifier — the write
    -- decorator is versioned-path-specialized, so the key is concretely a
    -- 'UUID'; interpreters render it as they like), the per-event metadata
    -- (each carries 'eventType', 'correlationId', and the app 'custom' map),
    -- and the assigned per-stream versions + global positions.
    EventsPersisted !UUID ![EventMetadata] !EventWriteResult
  | -- | An expected-position (optimistic concurrency) check failed; nothing was
    -- written.
    WriteConflict !UUID !ConflictInfo

-- | Optimistic-concurrency conflict detail. Typed (not stringly-rendered)
-- because the write decorator is specialized to the versioned path
-- (@position ~ EventVersion@ — see §3): 'expected' is the caller's asserted
-- position (the @ExpectedPosition@ argument to @storeEvents@); 'actual' is the
-- stream's real end version returned in @EventStreamNotAtExpectedVersion@.
data ConflictInfo = ConflictInfo
  { expected :: !(ExpectedPosition EventVersion),
    actual   :: !EventVersion
  }
  deriving (Show, Eq)   -- ExpectedPosition and EventVersion both derive these

-- 'Signal' derives (Show, Eq) too (all payloads already do) — the capturing-sink
-- test and interpreters want them.

-- | No-op sink. The default everywhere; guarantees silent, zero-cost behaviour
-- unless the app opts in.
silentTelemetry :: Applicative m => Telemetry m
silentTelemetry = Telemetry (const (pure ()))
```

Notes:

- **`Signal` is non-parametric.** The store is generic over `key`/`position`, but
  a single `Signal` type cannot be parametric over every subsystem's type
  variables (in particular it cannot embed `EventWriteError position`). Because
  the write decorator is specialized to the versioned path (§3), the write-path
  constructors carry the concrete stream key as a **`UUID`** (eventium's existing
  stream identifier — no new type, no lossy text rendering), the
  versions/positions come through the already-concrete `EventWriteResult`
  (`= [(EventVersion, SequenceNumber)]`), and `ConflictInfo` carries the concrete
  `ExpectedPosition EventVersion` / `EventVersion` directly.
- **`emit` runs in `m`.** The app builds `Telemetry IO` / `Telemetry (SqlPersistT
  IO)` as a closure over its env (log function, metrics registry). `IO` is just
  the instantiation; the type stays polymorphic.
- **Emit must not throw.** Write-path emits may run inside the write transaction,
  so a throwing interpreter could roll back a committed money write. Documented as
  a hard constraint on interpreters (mirrors the existing `RetryConfig` callbacks,
  which are also unguarded). Guarding is a possible later addition, not v1.

### 2. `EventMetadata.custom` — generic app context (Option A)

```haskell
data EventMetadata = EventMetadata
  { eventType     :: !EventTypeName
  , correlationId :: !(Maybe UUID)
  , causationId   :: !(Maybe UUID)
  , createdAt     :: !(Maybe UTCTime)
  , custom        :: !(Map Text Text)   -- NEW, default 'mempty'
  }

-- | Ergonomic enricher: @insertCustomMetadata "userId" uid@.
insertCustomMetadata :: Text -> Text -> EventMetadata -> EventMetadata
```

- **Generic bag, no app concept in the library.** The app stashes `"userId"`
  (and anything else) via the existing `MetadataEnricher` seam. eventium never
  learns about users.
- **Read-compatible — the envelope, not a registry-keyed payload.**
  `EventMetadata` is decoded by the store backend, not through the
  schema-evolution registry, so upcasters do not apply; the compatibility
  contract is purely about what the decoder tolerates. Every optional field —
  the three `Maybe`s and the new `custom` map — reads as **absent ⇒ empty**: a
  missing key, an explicit `null`, or (for `custom`) `{}` all decode to
  `Nothing`/`mempty`.
- **Encoding switches to omit absent/empty fields — a deliberate change from
  today's explicit-`null` output.** Today `EventMetadata` uses `genericToJSON
  defaultOptions` (`omitNothingFields = False`), which writes `"correlationId":
  null` etc. We move to **omitting** any `Nothing` `Maybe` field and omitting
  `custom` when empty, so rows are leaner and the "absent = empty" rule is
  uniform — `custom` is no longer a special case sitting next to fields that emit
  explicit `null`.
  - **This is a cleanliness/leanness change, not a compat fix.** The `.:?`
    decoder reads both a missing key and an explicit `null` as `Nothing`
    (`explicitParseFieldMaybe` collapses `Just Null → Nothing`; use `.:?`, **not**
    `.:!`, which does not null-collapse), so read compatibility is unchanged
    either way. It is **fully read-compatible**: pre-existing rows carrying
    explicit `null`s still decode unchanged.
  - **Ad-hoc SQL — scoped, not blanket.** `->>`-based NULL checks stay equivalent
    across old and new rows (`metadata->>'correlationId' IS NULL` holds for both
    an omitted key and an explicit `null`). But key-existence (`metadata ?
    'correlationId'`) and single-arrow (`metadata -> 'correlationId' IS NULL`)
    checks **differ** between old (`null`-bearing) and new (omitted) rows — an
    accepted consequence of the heterogeneous store. eventium itself runs no such
    query; this only touches self-hoster ad-hoc SQL.
  - **Consequence, accepted:** new writes are **no longer byte-identical** to
    historical rows; the store becomes heterogeneous (old rows with `null`s, new
    rows without). The tolerant decoder handles both. We take the cleaner shape
    over byte-for-byte stability, which buys nothing here.
- **This needs a hand-written `FromJSON`/`ToJSON` pair — do NOT reach for
  `deriveJSON`/`defaultOptions`.** `custom :: Map Text Text` is not `Maybe`, so it
  gets no aeson optional-field special-casing: generic decode **parse-errors** on
  a missing `custom` key (breaking old rows), and generic encode emits
  `"custom":{}`. The instances:
  - `FromJSON`: `eventType` required; `correlationId`/`causationId`/`createdAt`
    via `.:?` (→ `Nothing` when the key is missing *or* `null`); `custom` via
    `.:? "custom" .!= mempty`.
  - `ToJSON`: always emit `eventType`; emit each `Maybe` field **only when
    `Just`**; emit `"custom"` **only when non-empty**.

  This is **not** the banned custom-`FromJSON`-as-migration pattern. That ban is
  about stored *payloads* keyed by the schema registry, where `.:?`/`.!=` fakes
  versioning across shapes. Here every field is an **always-optional current-shape
  field** on a non-registry envelope (absent/empty is a valid *present-day* value,
  not a legacy artifact), and both instances describe exactly one shape. Reviewer
  confirmation of the envelope/registry distinction is recorded in the review
  notes for this spec.
- `emptyMetadata` and the positional `EventMetadata` constructions in eventium
  (`emptyMetadata` at Types.hs, and the two `metadataEnriching*` writers at
  Class.hs) are updated to seed `custom = mempty`.
- Doc drift: `eventium-sql-common/README.md`'s metadata example currently shows
  `"causationId": null`; update it to the omitted-key shape fresh writes now
  produce, alongside the code change.

### 3. `telemetryEventStoreWriter` — the write decorator

**Specialized to the versioned write path** (`key ~ UUID`, `position ~
EventVersion`). This is deliberate: every aggregate write is a
`VersionedEventStoreWriter` (`= EventStoreWriter UUID EventVersion`), and a fully
`key`/`position`-polymorphic decorator could not carry a concrete stream key nor
a concrete position in `ConflictInfo` without extra renderer parameters.
Specializing lets the write-path `Signal` constructors carry the stream `UUID`
directly (no render) and typed `EventVersion`/`ExpectedPosition EventVersion` for
free. The reusable core
(`Telemetry`, `Signal`) stays fully generic; only this one decorator is
path-specific. A renderer-parameterized generic variant can be added later if a
non-`UUID` stream ever needs write telemetry (YAGNI now).

```haskell
telemetryEventStoreWriter
  :: Monad m
  => Telemetry m
  -> VersionedEventStoreWriter m (TaggedEvent encoded)   -- EventStoreWriter UUID EventVersion …
  -> VersionedEventStoreWriter m (TaggedEvent encoded)
```

- Composes into the existing writer decorator stack (`codecEventStoreWriter`,
  `metadataEnrichingEventStoreWriter`, `publishing*`), at the **`TaggedEvent`
  layer** so each event's `.metadata` (including `custom`) is in hand.
- Body — wraps `storeEvents key expectedPos events`:
  - **Empty input (`null events`) → emit nothing, in all cases** (including a
    `Left`): an empty write persists nothing, so there is no signal to report.
    Gate on this first.
  - Otherwise run the inner write; on `Right result` emit
    `EventsPersisted (UUID.toText key) (map (.metadata) events) result`; on
    `Left (EventStreamNotAtExpectedVersion actual)` emit
    `WriteConflict (UUID.toText key) (ConflictInfo expectedPos actual)` — note the
    **expected** position comes from the decorator's own `expectedPos` argument
    (the error value carries only the *actual* end version), and the **actual**
    from the error. Return `result` unchanged.
- **Deferred (named, not silently absent):** a store-level *exception* thrown by
  the inner `storeEvents` (e.g. a DB failure) produces **no** signal — the
  decorator does not bracket. Only the `Left` optimistic-conflict path is
  reported. A `WriteFailed` signal via bracketing is left to a later spec, in step
  with the emit-must-not-throw constraint.

### 4. Seam left for Spec 2

Wire `telemetryEventStoreWriter silentTelemetry` into the backend writer stack in
`Infrastructure/Eventium.hs` — **zero behaviour change**, proving the decorator
composes with the real stack. The concrete `Telemetry AppM`-style interpreter
(logging + metrics) and the `insertCustomMetadata "userId"` enricher land in
Spec 2.

## Testing (eventium-testkit + in-memory / sqlite)

- **Capturing sink** — `Telemetry` that appends signals to a `TVar`. Assert:
  - `EventsPersisted` fires once per successful write, with the expected stream
    key, event types, `custom` map, and assigned versions + global positions.
  - `WriteConflict` fires on an expected-position mismatch, and no
    `EventsPersisted` is emitted.
  - `silentTelemetry` fires nothing across the same operations.
  - Empty-batch write fires nothing.
- **Metadata round-trip + omission** — `custom` survives write → read; a
  non-empty `custom` encodes with `"custom"`, an empty one omits it; a `Nothing`
  `Maybe` field is omitted (not `null`); a `Just` field is present.
- **Legacy decode fixtures (both historical shapes)** — decoding must accept
  pre-change rows. Cover **both**:
  - an old row with **explicit `null`s** for `correlationId`/`causationId`/
    `createdAt` and **no `custom` key** → decodes to the same value as
  - a new row that **omits** those keys.

  Both must yield `Nothing`/`mempty`, proving the encoding switch is
  read-compatible. Because `EventMetadata` is an **eventium-core** type (not an
  app registry payload), these tests live in **eventium's own suite**
  (eventium-core / eventium-testkit), not the app's
  `Infrastructure.Eventium.SchemaSpec` — which stays scoped to registry-keyed
  *payloads*.

## Backward compatibility

- eventium-core gains no dependency (`Map`/`containers` already present).
- `EventMetadata` change is read-compatible: the `custom` field is additive, and
  the switch to omit-`Nothing`/empty encoding is decode-tolerant of the historical
  explicit-`null` rows (see §2). New writes are leaner and no longer byte-identical
  to old rows; the store is heterogeneous and the decoder accepts both.
- All new behaviour is opt-in behind `silentTelemetry`; default wiring is silent.
- Ships in the next eventium minor (0.6.0) alongside a CHANGELOG entry.

## Open questions

- Should `telemetryEventStoreWriter` guard `emit` against exceptions (swallow, to
  protect the write) rather than only documenting the must-not-throw rule?
  Deferred; revisit if a real interpreter makes throwing plausible.
- Final home of the write decorator: `Eventium.Store.Class` vs. a dedicated
  `Eventium.Store.Telemetry`. Leaning dedicated module to keep `Store.Class`
  focused.
