---
status: draft
date: 2026-08-10
---

# Live data-change signal + balance/transaction consistency

Tracker: `homeaccounting/tracker#45`. Spans two repos: the Haskell backend
(`homeaccounting/backend`, this repo) and the web client
(`homeaccounting/monorepo`, `../monorepo`).

## Problem

The shared backend has many writers — the web SPA, the Telegram bot
(`record_transactions` / prompt, #39), a future mobile app, and the backend
itself during a bank **import/sync** (#38) — but the web cache only learns about
its *own* writes. A change made out of band (a Telegram entry, a completed
import, an edit from another device or tab) is invisible while the web tab is
open and focused; the only refresh paths today are each mutation hook's own
`onSuccess` invalidation plus `staleTime: 30_000` + `refetchOnWindowFocus`.

Layered on top of that visibility gap is a sharper, user-reported symptom:
**account balances and the transaction list disagree with each other in the UI,
worst during a banking import — the more transactions imported, the bigger the
discrepancy.** Investigation of `../monorepo` found this is *not* a
missing-invalidation bug (the import path already invalidates both `['accounts']`
and `['transactions']` symmetrically). The real causes, in order of impact:

1. **Refetch-latency asymmetry (dominant, scales with #transactions).**
   `['accounts']` is a single fast request, so the header balance snaps to the
   new all-time value almost instantly. The transaction list is fetched by a
   **sequential offset-paging loop** (`limit=200`, page after page) inside one
   `queryFn` that only resolves after the *last* page. While `ceil(N/200)`
   requests grind through, the UI shows the **pre-import list** beside an
   already-updated balance. More rows → more pages → longer disagreement.
2. **All-time balance vs. date-windowed list (permanent, by construction).**
   `account.balance` is a server-computed *all-time* running total; the list is
   bounded by the selected period. An import brings in rows dated outside the
   current window — they move the balance but never render in the list.
3. **Offset pagination is fragile under concurrent writes (secondary).** A write
   landing mid-paging shifts rows between pages, so the accumulated list silently
   skips or duplicates entries.

There is also a latent web bug: `useEditTransaction`'s optimistic
`setQueryData(['transactions', accountId])` writes to a **phantom key** nothing
reads (the real key is `['transactions', accountId, from, to]`), so the
optimistic patch is a silent no-op that only self-heals via the `onSettled`
invalidation.

A backend push/signal alone does **not** fix causes #1–#3 — it would trigger the
same asymmetric refetch. The visibility gap and the consistency symptom are two
tangled problems; this design addresses both.

## Goals

- A **generic**, backend-produced, client-consumed data-change signal so any open
  client refetches shortly after *any* writer mutates transactions/accounts —
  regardless of which client caused it. One mechanism, not another per-feature
  one-off.
- Balance and the transaction list are **consistent with each other** in the UI:
  they may lag reality (eventual consistency is acceptable) but must never
  *visibly disagree*.
- The signal's transport is swappable (polling now, SSE later) behind a single
  client-side abstraction, with **no** mutation-hook or backend-producer changes
  required to swap it.

## Non-goals

- SSE / WebSocket streaming (deferred; see "Transport decision").
- Per-entity versions (one coarse per-user version is deliberate — see Q2).
- `['configuration']` / dictionary invalidation via the signal.
- Windowed / opening-closing account balances (the all-time header balance is
  accepted as correct — see "Balance semantics").

## Transport decision — revision-cursor polling (Approach A)

The issue floated three transports: (A) revision-cursor polling, (B) SSE, (C)
WebSockets. This design chooses **A**, decisively, for reasons specific to this
codebase:

- **Auth.** The backend authenticates strictly via the `Authorization: Bearer`
  header (custom `AuthProtect "jwt"`, `Web/Middleware/Auth.hs`) — there is no
  cookie path and no query-param token path anywhere. A browser `EventSource`
  cannot set headers, so SSE would require **new** auth plumbing (query-param
  token or short-lived stream ticket) plus reconnect/`Last-Event-ID` replay.
  Approach A reuses the existing Bearer flow untouched.
- **Streaming is greenfield.** No SSE / raw-WAI / `SourceIO` usage exists in the
  repo; B would be built from scratch.
- **Freshness target fits.** For "a Telegram entry / finished import appears
  within a few seconds," a ~10s poll interval is adequate; the sub-2s live feel
  that justifies SSE is not required.
- **Non-foreclosing.** Because the client hides polling behind a
  transport-agnostic "version advanced → invalidate keys" module, swapping to SSE
  later touches only that module — not the mutation hooks or the backend producer.

WebSockets (C) are rejected outright: we need only server→client, so the
bidirectional channel and its lifecycle/heartbeat machinery aren't justified.

### SSE upgrade path — when and how (deferred, not day-1)

Polling is chosen *now*; it is deliberately hidden behind seams so push (SSE) is a
later drop-in, not a rewrite. This subsection records the trigger to make that
switch and why it stays cheap.

**The requirement drives the transport, not the backend architecture.** Being
event-sourced makes the push *producer* natural (the in-transaction
`GlobalEventPublisher` fan-out we already hook), and de-risks the *hardest* part
of push — missed-event replay on reconnect: `Last-Event-ID` maps directly to the
global `SequenceNumber`, so a reconnecting client replays exactly what it missed,
correct by construction. But that is a reason SSE is a clean *future* move
*because* we're event-sourced — **not** a reason to pay for it before a latency
requirement demands it. The connection cost (below) is unrelated to ES.

**Switch polling → SSE when any of these becomes true:**

- A concrete requirement for sub-~2s liveness while a tab is focused (today's need
  is "a Telegram entry / finished import shows up within a few seconds", which
  ~10s polling meets).
- Polling's idle traffic or latency becomes a real complaint at higher concurrency
  (many open tabs / users).
- Import (or another writer) moves fully async and "it finished" must surface
  promptly to all clients.

**What the switch costs (and doesn't):**

- **Reuses**, unchanged: the producer (event fan-out), the per-user scope
  resolution (`account_access`), the entire web consumer's "data changed →
  invalidate keys" mapping, and the atomic balance/list swap. These are
  transport-independent — roughly the bulk of this feature.
- **Adds:** an authenticated `GET /api/events` stream endpoint; a per-user
  **subscriber registry** with per-event access filtering; heartbeat + reconnect;
  and a new **auth path** for the stream, because `EventSource` cannot send the
  `Authorization: Bearer` header (short-lived stream ticket or query-param token,
  wired into the existing JWT/`onUnauthorized` flow). On the client, only the
  single `useDataChangeSignal` transport module changes — no mutation hook and no
  producer change.
- **Watch-out — horizontal scaling:** an in-process subscriber registry only works
  single-instance. Running >1 backend instance requires a shared bus (Postgres
  `LISTEN/NOTIFY` or Redis pub/sub) to fan committed events to all instances'
  connections. Polling is stateless and sidesteps this; SSE inherits it. For a
  self-hosted single-instance deployment this may never bite, but it is latent
  complexity SSE signs up for.

**WebSockets remain out of scope even at the SSE stage.** Cache invalidation is
one-directional; WS's full-duplex channel is pure overhead here. Revisit WS only
if the product grows a genuinely bidirectional realtime feature (presence, live
collaborative editing); SSE→WS is then a reasonable upgrade.

## Design

### Backend (`server-infra`)

#### The version is one coarse, per-user, monotonic value

A single `version` per user, **not** per-entity. The goal is that balance and
transactions *agree*; a per-entity scheme would let them advance independently —
exactly the divergence we are killing. One version that changes on **any**
account/transaction write the user can see means the client always refetches
balance and list **together**, off one signal. The harmless cost is that an
account-only change (rename) also nudges the list, and a transaction-only change
(label edit) also nudges the balance — one cheap refetch each.

The version value is an **always-incrementing per-user counter** (`version =
version + 1` on each affecting event), *not* the global event-store
`SequenceNumber`.

> **Why a counter, not the `SequenceNumber`.** A global `SequenceNumber` is
> assigned at event *append*, but transactions do not necessarily *commit* in
> append order. Two concurrent writes both affecting user U — T1 at `seqNo=100`,
> T2 at `seqNo=101` — can commit T2-before-T1; a `version = GREATEST(v, seqNo)`
> upsert would set `version=101`, let a client advance its last-seen to `101`,
> and then clamp T1's late `GREATEST(101, 100)` to a **no-op** — so T1's change is
> never signaled (a missed invalidation, self-healing only via the `staleTime`
> backstop). An always-incrementing counter is immune: under the per-user row
> lock the two upserts serialize, each `+1` becomes visible atomically with *its
> own* transaction's data, and the late transaction still yields a strictly
> higher value that re-triggers the client — regardless of commit/`seqNo` order.
> The client's coarse `!==` trigger tolerates the skipped intermediate values.
> (This is the correctness axis the earlier in-memory-counter draft got right;
> its only defect was living in memory, which the DB move fixes.)

#### 1. Producer — an in-transaction persistent read model (race-free)

The version is maintained by a **new persistent read model** (`DataVersion`)
registered in `Application/ReadModels/Persist.hs` alongside the existing ones. It
therefore rides the same machinery every read model uses: it is applied
**synchronously inside the event-append DB transaction** via eventium's
`GlobalEventPublisher` fan-out, it checkpoints its global position, and it
catches up / rebuilds on boot for free.

> **Why in the DB transaction is correct here (and why in-memory was wrong).** An
> earlier draft bumped an in-memory `TVar` inside the transaction. That has a
> **missed-invalidation race**: the `TVar` mutation is visible immediately, but
> the Postgres `COMMIT` lands a moment later; a client polling in that gap sees
> its version advance, refetches on another connection that cannot yet see the
> uncommitted write, reads stale data, and advances its last-seen version — so it
> never refetches that change. Writing the version to a **DB row in the same
> transaction** eliminates the race by construction: the version row and the
> events it describes become visible to other connections **atomically** at
> commit. It is also durable, so a backend restart does not reset it (no
> "blanket refetch on restart" wrinkle).

**Table** `sync_data_version`: `(user_id PRIMARY KEY, version BIGINT NOT NULL)`,
`version` = a per-user counter, incremented once per affecting event
(`INSERT … VALUES (user, 1) ON CONFLICT (user_id) DO UPDATE SET version =
sync_data_version.version + 1`). Absent user reads as `0`.

**Per-event handler.** For each committed event:

1. **Determine affected `accountId`(s)** (see mapping table below).
2. **Determine affected users** = the union, over those accounts, of each
   account's access scope (owner + editors + viewers) read from `account_access`
   — **plus**, for an access-revoke event, the user named in the event payload
   (they have just been removed from `account_access`, so they must be bumped
   explicitly or they keep seeing an account they lost).
3. **Increment** the counter (`version = version + 1`) for each affected user.
   The per-user row lock serializes concurrent same-user increments, and each
   increment commits atomically with its own transaction's data — so no
   commit-order reordering can hide a change (see the callout above). The
   increment is the read model's only write and runs at the end of the fan-out
   chain, giving a consistent lock-acquisition order.

Because the `DataVersion` read model is registered **after** the Account and
Transaction read models in the fan-out chain, `account_access` and the
transaction→account mapping already reflect the just-committed event when it runs
(required for grant/revoke correctness and for resolving a transaction's
accounts).

**Event → affected `accountId`(s) mapping.**

| Event group | Affected account(s) |
|---|---|
| Account lifecycle (created, balance-adjusted, renamed, subtype/status changed) | the event's `accountId` |
| Account access granted / **revoked** | the event's `accountId`; for **revoke**, additionally bump the revoked `userId` from the payload |
| Transaction single-entry (income/expense: posted, amended, cancelled, allocations/labels/contact changed, imported/reconciled) | the transaction's one account, resolved via the Transaction read model |
| Transaction **transfer** (both legs) | **both** the debit and credit accounts (union of both access scopes) |
| Transaction merge | the account(s) of all transactions involved (union) |
| Pure saga/system signals with no user-facing data change (posting completed/failed handshakes) | none — skipped |

**Error handling.** As with every persistent read model, the handler runs in the
write transaction, so it must be total. Its only effects are a `SELECT` on
`account_access` / the transaction read model and an idempotent upsert — no
partial functions, no throw. (A DB-level failure would fail the whole write, same
as any other read model; that is the existing, accepted tradeoff.)

#### 2. Query + endpoint — `GET /api/sync/version`

A read-model query `getDataVersion :: UserId -> SqlPersistT m Word64` returns the
user's row, or **`0`** if absent (a user with no accessible writes yet). This is
a plain non-mutating `SELECT` — a read never inserts, so it cannot race a bump.

New `Web/API/SyncAPI.hs` following the `ReportingAPI` template:

```haskell
type SyncAPI = AuthProtect "jwt" :> "api" :> "sync" :> "version" :> Get '[JSON] SyncVersionResponse
-- SyncVersionResponse { version :: Word64 }   -- JSON number; stays < 2^53, safe as a JS number
```

Wired into the `API` union and `server` value in `Web/API.hs`. Reuses the
existing JWT context and `AppM`→`Handler` hoisting; no `Server.hs` change. 401
handling is the existing Bearer path unchanged.

### Web (`monorepo`)

#### 3. Transport-agnostic signal module — `useDataChangeSignal`

A single hook that:

- Polls `GET /api/sync/version` on an interval (~10s while the tab is focused,
  backed off / paused when hidden via the visibility API; paused when logged out).
- Tracks the last-seen version; invalidates the key set below whenever the polled
  version **differs** from the last-seen value (`polled !== lastSeen`, *not*
  `>`), so a backend that somehow reports a lower value is still treated as "data
  changed, refetch." First poll seeds `lastSeen` without invalidating.
- Is the sole seam a future SSE transport swaps behind — no mutation hook knows
  the transport.

**Scope → invalidation map** (on version change):

| Query key | Reason |
|---|---|
| `['accounts']` | balance |
| `['transactions', …]` (prefix, all windows) | the list |
| `['reports', …]` (spending-by-category, income-vs-expense, net-worth) | closes an existing gap — the import path never invalidated reports |
| `['transaction-relations']`, `['account-access']` | cheap; keeps side-panels correct |

`['configuration']` / dictionaries are deliberately **not** invalidated (the
producer never bumps on config events, and config changes are self-initiated).

#### 4. Atomic consistency view

A coordinating hook keeps the **previous** balance *and* list visible
(`placeholderData: keepPreviousData`) until **both** the `['accounts']` query and
the **currently-displayed** transactions-window query
(`['transactions', scope, from, to]` — the exact key the view is showing, not the
whole prefix) have settled, then surfaces both at once. The displayed balance and
list therefore always come from the same settled generation — the "new balance
beside stale list" contradiction becomes impossible to observe.

This guarantee **depends on §5**: it holds cleanly only if the displayed window is
a *single* settling query. While the transaction fetch remains a multi-request
paging loop, "settled" means the whole loop resolved — which is precisely the lag
§5 removes. §5 is therefore a prerequisite, not an optional polish.

#### 5. Paging fix

Replace the sequential offset-paging loop in `useWindowedTransactions` with
fewer/larger (ideally a single ranged) requests, so the window settles fast and
atomically. This removes both the latency lag (cause #1) and the
skip/duplicate-under-concurrent-write hazard (cause #3), and makes §4's "settled"
a single well-defined moment.

#### 6. Latent-bug fix

Fix `useEditTransaction`'s optimistic write to target the real
`['transactions', accountId, from, to]` key (or drop the optimistic write and
rely on invalidation), so the optimistic patch is no longer a silent no-op.

### Balance semantics (accepted, not changed)

The account header shows the **all-time** server-computed balance while the list
is period-scoped; the visible rows will not sum to the header. This is accepted
as a normal, correct finance-app convention (cause #2). The atomic swap (§4)
fixes the *actual* defect — the transient contradiction — and the UI must simply
avoid implying that the header equals the visible-rows sum. No windowed-balance
query is added.

## Data flow

```
any writer (HTTP / Telegram / import) commits Account/Transaction event(s)
   │  (single DB transaction)
   ├─ account & transaction read models update
   └─ DataVersion read model: affected accountId(s) → account_access scope
        → increment version (+1) for owner+editors+viewers
          (+ the revoked user, for revoke events)
   COMMIT  ← version row and event data become visible atomically
                                   │
web client polls GET /api/sync/version (~10s, focused)
   → polled !== lastSeen
   → invalidates [accounts, transactions, reports, relations, access]
   → both queries refetch; atomic swap surfaces balance + list together
```

## Testing

**Backend**
- `DataVersion` read model bumps the correct users from **each** entry point (HTTP
  handler, Telegram handler, import service) — proving it sits below all of them.
- Sharing scope honored: a write on a shared account bumps owner **and**
  editors/viewers; an unrelated user's version does not move.
- A share/**grant** event bumps the new grantee; a **revoke** event bumps the
  removed user (they must learn the account is gone).
- A **transfer** bumps the users of **both** legs' accounts.
- Configuration/user events do **not** bump any version.
- `getDataVersion` returns the user's counter; an unknown user gets `0`; the
  value strictly increases on each successive affecting write.
- The version row and its events are visible atomically (a read on another
  connection never sees an advanced version without the corresponding data) —
  i.e. no notify-before-commit race.
- **Concurrent-write reorder safety:** two overlapping transactions both
  affecting user U each advance the counter, and neither can clamp the other to a
  no-op — the client is re-triggered for both, whatever order they commit in.

**Web**
- Version change invalidates exactly the §3 key set (and not `configuration`);
  first poll seeds without invalidating; a lower polled value still invalidates.
- The atomic view never surfaces balance and list from different generations
  (simulate slow list refetch beside fast balance refetch).
- The new paging scheme returns a complete window (no skip/duplicate) under a
  concurrent write.
- The edit optimistic write now targets a key an active query reads.

## Rollout / backward compatibility

- **No stored-event shape change**: the `DataVersion` read model only *reads*
  committed events and derives a projection; it adds nothing to the event log. No
  upcaster, no event-store recreate. (Per the alpha backcompat policy, this change
  is invisible to the event log.)
- **New read-model table** `sync_data_version` is created by the read-model
  initialization path and back-filled by the standard catch-up/rebuild on boot,
  exactly like the other persistent read models — no manual migration.
- **API is additive**: a new `GET /api/sync/version` endpoint; no existing
  endpoint or DTO changes.
- **Web is additive + fixes**: a new polling hook and consistency/paging changes;
  existing per-mutation `onSuccess` invalidation and optimistic updates are kept
  (the signal supplements them for out-of-band writes).

## Open questions

- Poll interval tuning (10s focused / backoff when hidden) — starting values,
  refine against feel.
