# 003 - Process managers project through a snapshot cache

## Status
Accepted

## Context
Process managers (the transfer/amendment/cancellation/merge sagas) run
**synchronously in the write transaction**: every persisted event is delivered to
each saga's event handler so it can `react` and issue follow-up commands. To
`react`, a saga needs its projected state (e.g. the map of in-flight transfers).

The original handler (`processManagerEventHandler`) rebuilt that state **from the
entire global event stream on every event**, via `getLatestStreamProjection` over
the global reader. With N sagas wired into the write path, each appended event
triggered N full replays of the whole store.

This made write-path latency **O(events-in-write × sagas × total-events-in-store)**
— and, worse, it grew without bound as the log accumulated. It surfaced when a
bulk operation (localizing ~37 default-category names on a country change, see
`docs/specs/2026-08-20-backend-localization-design.md`) emitted many events in one
request: `PUT /country` took ~8–20 s on a local store of only ~4k events, and
*every* write (even a 2–3 event one) already paid a ~1 s floor that would keep
climbing. The database was not the bottleneck (measured sub-millisecond
statements); the cost was CPU replay in Haskell.

## Decision
Project saga state through a **snapshot cache** instead of replaying the whole
stream. eventium already had the machinery (`getLatestGlobalProjectionWithCache`,
`GlobalProjectionCache`, the `projection_snapshots` table); we added one generic
library function, `cachedProcessManagerEventHandler` (eventium-core 0.6.2), that
loads the last snapshot and folds only the events written **since** it, then
persists the advanced snapshot. `Infrastructure.Eventium.wireProcessManager` now
wires each saga a per-manager `sqlGlobalProjectionCache` (keyed by a stable,
unique name) and uses the cached handler.

The snapshot is written in the **same write transaction** as the events, so it
advances iff the events commit — preserving the previous handler's
rollback-safety exactly. The cache is a rebuildable derived view: a decode miss
(e.g. after a saga-state shape change) simply falls back to a one-time replay, so
snapshots are safe to evolve and require no migration.

The eventium change is deliberately **generic** (over event/command/state and
backend); all app-specific concerns — snapshot names, the JSON codec for saga
state, and which sagas are wired — live in the app.

## Consequences
- **Write latency is O(events-in-this-write)**, independent of total store size.
  `PUT /country` heavy path dropped from ~8 s to ~1× a single write; the per-write
  floor no longer grows with the log. This benefits **all** writes, not just the
  bulk case.
- **Saga state must be JSON-serializable.** The four saga state types (and their
  nested data) now derive `ToJSON`/`FromJSON`; `TransactionId` gained
  `ToJSONKey`/`FromJSONKey`. New saga state fields must remain serializable.
- **One-time cost on first write after deploy**: with an empty snapshot the first
  event folds the full history once, then the snapshot persists (across restarts).
  Optional startup catch-up (`updateGlobalProjectionCache`) could remove even that;
  not wired, as it is a single, persisted, one-off.
- The uncached `processManagerEventHandler` remains in eventium for callers that
  want it; correctness of the cached variant depends on the cache committing
  atomically with the write (true for the SQL cache in the write transaction).
