---
status: completed
issues: [homeaccounting/backend#108, aleks-sidorenko/eventium#12]
---

# Event schema evolution: versioned envelope + chained upcast-on-read

## Context

We now operate in production. Self-hosters own their event-store database, so
every released change to a stored event's shape must let **older stored events
still replay**, and must not corrupt the append-only money log.

Today events are stored as raw JSON in `events.payload` (jsonb) and decoded with
**derived Aeson `FromJSON`** — no schema-version tag, no upcasting. The first
breaking event change already landed: `TransactionAmendmentInitiated` gained a
required `allowOverdraft :: Bool` (backend #145 / commit 442ff8d). Every *older*
stored amend event lacks that key and now fails to decode, so the transaction
stream can't rebuild. This is the motivating, concrete case.

This supersedes the earlier "no backward-compatibility phase" policy: from now on
every change is backward compatible and/or ships a migration.

## Decision: upcast-on-read against an immutable log

We normalize old events to the current shape **in memory, on every read**. Stored
bytes are never mutated.

Rationale, pressure-tested for accounting (not merely inherited from the issue):

- The transform logic is identical under either strategy. Version-skipping is in
  scope (restore an N-releases-old backup against today's app), so *any* approach
  must carry a chain of single-hop transforms `v1→v2→v3`. Rewrite-on-upgrade does
  **not** collapse that into one migration — it runs the same chain. So the only
  real difference is *when* transforms apply: once on write (upgrade) or on each
  read.
- Upcast-on-read keeps the log immutable → the irreplaceable financial history is
  preserved verbatim; a buggy upcaster is a code fix + redeploy, not corrupted
  money data; and we can **fix-forward** a wrong transform because the source
  bytes are still there. Rewrite-on-upgrade destroys the input, mutates the log on
  every upgrade, and needs a locking/resumable batch job.
- `pg_dump`/restore and version-skipping are free: any app version reads any dump
  because normalization happens on load.
- At home-accounting scale (thousands→low-millions of events over years), read-time
  replay cost is a non-issue; if it ever isn't, snapshots bound it.

Rewrite-on-upgrade's one genuine win — stored bytes in current shape — is
recovered later by an **opt-in compaction tool that reuses this same registry**,
not by a competing mechanism. So the registry is the foundation under any future
decision.

## Architecture

Two layers. The generic machinery goes into **eventium-core** (per the
"eventium is a first-class goal" rule); the app supplies only the concrete
registry.

### 1. Versioned envelope (eventium-core)

Serialized payload gains an envelope:

```json
{ "schemaVersion": 2, "payload": { "tag": "TransactionAmendmentInitiated", ... } }
```

- **Detection sentinel**: a top-level numeric `schemaVersion` key. Legacy bare
  JSON (no such key) is defined as `schemaVersion = 1`, payload = the whole value.
- Existing rows are **never rewritten**; they simply read as v1.

### 2. Upcaster registry (eventium-core)

Keyed by event-type name (`Text`):

```
SchemaRegistry
  = eventType -> ( currentVersion :: Int
                 , upcasters      :: [Value -> Value] )   -- ordered v1→v2, v2→v3, …
```

- Each upcaster is a **pure single-hop** `Value -> Value`.
- Version-skipping = run the sub-list from the stored version to current.
- An event type absent from the registry = current version 1, no upcasters
  (identity).
- `currentVersion` is derived as `1 + length upcasters` so the two can never drift.

### 3. `upcastingCodec` (eventium-core)

A drop-in `Codec a encoded`, replacing `jsonStringCodec` at the reader/writer
call sites. Parameterized by:

- `eventTypeOf :: Value -> Maybe Text` — reads the type name from a payload value
  (app convention: read the `tag` field). Keeps eventium agnostic to how apps tag.
- `SchemaRegistry`.

Behavior:

- **encode** `a -> encoded`: `p = toJSON a`; `et = eventTypeOf p`; wrap
  `{ schemaVersion = currentVersion registry et, payload = p }`; serialize.
- **decode** `encoded -> Maybe a`: parse value; if it has a numeric top-level
  `schemaVersion` → envelope `(ver, payload)`, else `(1, wholeValue)`;
  `et = eventTypeOf payload`; fold the upcaster hops `ver → current`;
  `Aeson.fromJSON` the result.

Because it is a plain `Codec`, it slots into both the versioned and global readers
and the publishing writer with a one-line swap — it serves synchronous
(in-transaction) and asynchronous (polling) consumers identically, with no
reader/metadata plumbing.

Failure handling: an event that can't be upcast+decoded returns `Nothing` from the
codec, preserving the store reader's existing strict-vs-lenient behavior. A formal
minimum-supported-version floor (which lets us *reject* below-floor events with a
clear error and retire old upcasters) is deferred (see below).

### 4. App-side registry + the `allowOverdraft` migration (backend)

- `eventTypeOf` reads the `tag` field of the `AccountingEvent` JSON.
- Registry entry: `TransactionAmendmentInitiated`, current version **2**, one
  upcaster **v1→v2** that injects `"allowOverdraft": false`.
  - Correct because the only `True` producer is the merge saga, whose amend events
    postdate the field and are always written at v2. Any v1-shaped stored event
    therefore predates merge, where `false` is the exact original semantics.
- All other event types stay at v1 with no upcasters.
- Swap `jsonStringCodec` → `upcastingCodec eventTypeOf schemaRegistry` in
  `Infrastructure.Eventium` (versioned reader, global reader, publishing writer,
  command dispatcher, logger).

## Testing

- **eventium (property/unit)**: round-trip at current version; legacy bare JSON
  decodes as v1; multi-hop chain across a 3-version type (version-skipping);
  unregistered type = identity at v1; envelope detection is not fooled by a payload
  that merely *contains* a nested `schemaVersion`-named field.
- **backend (unit)**: a v1-shaped `TransactionAmendmentInitiated` JSON (no
  `allowOverdraft`) decodes to `allowOverdraft = False`; a current event
  round-trips; the merge-saga (v2) event keeps `allowOverdraft = True`.
- **backend (integration)**: replay a stream containing a legacy-shaped amend event
  and assert the aggregate rebuilds.

## Scope

**In this task:**
- eventium: envelope + registry + `upcastingCodec` + tests (eventium#12).
- backend: registry + `allowOverdraft` upcaster + call-site swap + tests (#108).
- Flip the backward-compat policy in project memory + `CLAUDE.md`.
- Operator doc: dump/restore is version-independent; how to add an upcaster.

**Deferred to follow-up issues (consumers of this registry, not competing
mechanisms):**
- Snapshot-bounded replay (performance valve).
- Opt-in operator compaction (upcast-and-persist, backup-gated, off the hot path).
- Minimum-supported-schema-version floor + enforcement (retire old upcasters).
