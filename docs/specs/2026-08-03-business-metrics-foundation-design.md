---
status: draft
---

# Business metrics foundation — design

## Context

tracker#49 (operator observability) delivered a Prometheus `/metrics` endpoint
scraped into the Grafana stack (infra#8). Those metrics are **operator** signals —
event-driven counters and histograms that describe how the *system* is running
(`events_persisted_total`, `events_write_conflicts_total`,
`http_request_duration_seconds`). See
[`2026-08-01-app-observability-interpreter-design.md`](2026-08-01-app-observability-interpreter-design.md).

This spec adds the first **business** metrics — signals that describe how the
*product* is doing — and establishes a small, reusable foundation for them, which
the project does not have today:

- `users` — how many users have registered
- `accounts` — how many (regular) accounts have been created
- `transactions` — how many transactions have been recorded

## Decisions

These were settled during brainstorming and drive the design:

1. **Surface: the existing Prometheus `/metrics` endpoint.** No new endpoint, no
   admin JSON screen. Grafana picks the new series up alongside the operator
   metrics. One dashboard stack. A "HomeAccounting — Business" Grafana dashboard
   (stat panels for the three totals + a growth timeseries) is provisioned in the
   **infra** repo (`../fire-console/observability/grafana/dashboards/business.json`,
   infra#8) — a separate change from this backend work.

2. **Naming: no `business_` prefix.** Bare `users`, `accounts`,
   `transactions`, consistent with the existing no-prefix convention
   (`events_persisted_total`).

3. **No labels (low cardinality).** The three series are unlabelled aggregates.
   Per the tracker#49 guardrail — *user-id is a log field, not a metric label* —
   we do **not** add a `user_id` label (one time series per user). "Per user"
   questions are answered either as a Grafana ratio (`accounts /
   users`, `transactions / users`) or, if exact per-user counts
   are ever needed, by an admin read-model query — never by a metric label.

4. **Semantics: current count (snapshot).** The number answers *"how many
   users/accounts/transactions exist right now"* — a `COUNT(*)` recomputed at each
   scrape. Today, because rows are not hard-deleted, that equals "ever created"
   (see [Semantics & the type choice](#semantics--the-type-choice)).

5. **Metric type: gauge.** The value is a recomputed snapshot, not an accumulated
   total, so it is a **gauge** — free to move up or down. A read-model rebuild
   under *changed projection rules* (e.g. tightening what counts as a regular
   account) can settle it at a permanently lower number; a Prometheus counter
   would misread any such decrease as a reset and corrupt `increase()`/`rate()`.
   Because it's a gauge, the series carry **no `_total` suffix** (that convention
   is counter-only): `users`, `accounts`, `transactions`.

6. **Source of truth: the existing persisted read-model tables, counted at scrape
   time.** No new projection, no new table, no migration, no backfill.

7. **What counts as a row:**
   - `users` — every user row (both registration paths already insert one).
   - `accounts` — **regular accounts only**; `External` accounts are
     bank-import plumbing, not a business figure.
   - `transactions` — **all** transaction rows, including ones later
     cancelled or failed (they still "happened").

## Why the app computes the number (and Prometheus does not)

Prometheus has its own time-series DB, but it stores **the history of whatever
value we expose at each scrape** — not the authoritative current count. At every
scrape our app must produce "users ever registered = N"; Prometheus merely records
that N landed at time T. So the count itself must come from **our** durable data,
for three reasons:

1. **Prometheus only knows what it scraped.** A signup during app or Prometheus
   downtime is never captured — an in-process counter bumped on events would
   permanently undercount across any gap. A self-hosted app not running 24/7 next
   to an always-up Prometheus cannot rely on this.
2. **Prometheus can't be backfilled.** A self-hoster already has users/accounts/
   transactions in their event log from before this metric existed; Prometheus
   would start from zero at first scrape.
3. **The absolute total must be correct at any instant**, independent of scrape
   continuity.

The durable data we need already exists: the persisted read-model tables
(`users`, `accounts`, `transactions`) hold every row, survive restarts, and
contain the full history. So the count is simply `COUNT(*)` against them at scrape
time — always correct, no backfill, no in-process accumulator.

This is also why we do **not** add a separate `business_metrics` projection: it
would only earn its keep if rows were ever hard-deleted (to preserve "ever
created" vs "currently exists"). They are not — see below — so it is YAGNI.

## Semantics & the type choice

The value is a **gauge**: a `COUNT(*)` snapshot recomputed at each scrape. A gauge
is the honest type precisely because the number is *not* guaranteed monotonic —
it can legitimately decrease, and a gauge represents that without the reset
semantics a counter would impose. Two independent ways it can drop:

- **Changed projection rules on rebuild.** A read-model rebuild (`resetX` + replay)
  that runs under new rules — e.g. a tightened definition of "regular account", or
  excluding a transaction kind from the count — recomputes the total and can settle
  it *permanently lower* than before the deploy. This is the decisive reason for
  gauge over counter.
- **Future hard-deletion.** Today primary rows are never hard-deleted (the only
  `deleteWhere` on `UserEntity` / `AccountEntity` / `TransactionEntity` is the
  `resetX` rebuild path; cancel/close are status flags). If a feature ever deletes
  rows, the gauge simply reflects the lower current count — which is correct.

So today the number happens to equal "ever created", but nothing in the design
*relies* on that, and the gauge stays honest if it ever diverges.

> **If you later want cumulative "ever created" instead** (a monotonic total
> immune to deletion and rule changes — a different product choice), that is an
> **increment-only persisted projection**: bump a stored counter on the creation
> event, ignore deletion events, backfill by a one-time replay, and expose it as a
> Prometheus *counter*. Deliberately not built now — the current product question
> is "how many exist", which the gauge answers.

## Components

### 1. Count queries on the existing read models

Add small, total count helpers next to the existing queries (mirroring
`countTransactions :: (MonadIO m) => SqlPersistT m Int`, `Transaction.hs:457`):

- `Application.ReadModels.Transaction.countTransactions` — **already exists**
  (`count ([] :: [Filter TransactionEntity])`); reuse as-is.
- `Application.ReadModels.User.countUsers :: (MonadIO m) => SqlPersistT m Int` —
  `count ([] :: [Filter UserEntity])`.
- `Application.ReadModels.Account.countRegularAccounts :: (MonadIO m) =>
  SqlPersistT m Int` — count accounts excluding `External`:
  `count [AccountEntityAccountType !=. External]`. This is a SQL-level filtered
  COUNT (the `AccountType` `PersistField` encoding makes every `Regular _`
  variant compare unequal to `External`), giving the same regular/External split
  `getRegularAccounts` intends. Note: `getRegularAccounts` filters *in Haskell*
  (`accountTypeSubtypeKind`), which is not usable inside a persistent `count`
  filter — so we express the equivalent condition in SQL here rather than reusing
  that predicate directly. `accountType` is not an indexed column, so this is a
  full-table COUNT (trivial at self-hoster scale).

Each is exported for the composition root to call via `runDbDirect`.

### 2. Scrape-time collector — extend `Infrastructure.Observability.Metrics`

The scrape-time gauge collector is **generic** and lives in the *existing*
operator-metrics module — "business" is a caller concern, not an infrastructure
one, so the infra module stays metric-generic and any future computed-at-scrape
gauge (business or not) has a home there. It emits **gauge-typed** samples at
scrape time from an injected fetch action:

```haskell
data GaugeSample = GaugeSample
  { name  :: Text   -- e.g. "users"
  , help  :: Text
  , value :: Int64
  }

-- Pure, directly unit-testable: builds the exposition sample groups.
toSampleGroups :: [GaugeSample] -> [SampleGroup]

-- Thin wrapper: registers a scrape-time collector over the fetch action.
registerGaugeCollector :: IO [GaugeSample] -> IO ()
```

The concrete `users` / `accounts` / `transactions` series (the
only place the "business" framing appears) are named by the caller in `Main`.

Built on the concrete `prometheus-client` 1.1 API (confirmed available):
`register :: MonadIO m => Metric s -> m s`, with
`newtype Metric s = Metric { construct :: IO (s, IO [SampleGroup]) }`. The
collector is `register $ Metric (pure ((), collect))`, where `collect :: IO
[SampleGroup]` runs the injected fetch and returns
`toSampleGroups`. Each metric becomes
`SampleGroup (Info name help) GaugeType [Sample name [] value]`, where
`SampleType` includes `GaugeType` and `Sample`'s value is the number rendered to
a decimal UTF-8 `ByteString` (call out the `Int64`→bytes encoding explicitly).

- Stays in `Infrastructure` and takes the fetch action as an argument, so it does
  **not** import `Application` (layering: Infrastructure must not depend on
  Application). The concrete "run the count queries" action is supplied at the
  composition root, which may import both — mirroring how
  `Infrastructure.Observability.Metrics` defines `HasMetrics` but leaves the
  `AppEnv` wiring to a later step.
- Emits `GaugeType` sample groups so Grafana/PromQL treat the series as
  gauges.
- Registered once into the process-global registry, mirroring `registerMetrics`.
  (The registry is shared and not deduplicated — see the Testing note.)
- Sibling to the existing `Infrastructure.Observability.Metrics` (operator
  metrics), which is left unchanged.

### 3. Wiring — `app/Main.hs`

During metrics setup, build the fetch closure that runs the three counts in one
DB action and maps them to `[GaugeSample]` (bare names, no `_total`) + help text.
The `handleAny` lambda runs later, at scrape time, in a bare-IO closure with no
reader context, so it logs via a `LogFunc` captured up front (`view logFuncL`):

```haskell
-- runDbDirect :: ConnectionPool -> SqlPersistT IO a -> IO a  (Database.hs)
-- NOT the RIO/HasDbPool `runDb` — fetch must be a plain IO closure over the pool,
-- exactly as initializePersistentReadModels already uses runDbDirect.
baseLogFunc <- view logFuncL
registerGaugeCollector
  $ handleAny (\e -> runRIO baseLogFunc (logWarn ("business-metrics fetch failed: " <> displayShow e)) >> pure [])
  $ runDbDirect pool
  $ do
      u <- countUsers
      a <- countRegularAccounts
      t <- countTransactions
      pure
        [ gaugeSample "users"        "Registered users"      (fromIntegral u)
        , gaugeSample "accounts"     "Regular accounts"      (fromIntegral a)
        , gaugeSample "transactions" "Recorded transactions" (fromIntegral t)
        ]
```

No projection registration, no migration, no read-model reset changes.

## Data flow

```
Prometheus scrape  →  registerGaugeCollector fetch
        ▼
runDbDirect (countUsers / countRegularAccounts / countTransactions)   -- COUNT(*)
        ▼
gauge-typed samples: users N, accounts M, transactions K
```

The read-model tables are the durable source; each scrape reads the current truth.

## Backward compatibility / migration

**None required.** No stored-event shape changes (so no upcaster), no schema
changes (no new table), and no backfill (the read-model tables already hold full
history). Purely additive: three exported query helpers, one new Infrastructure
module, and collector registration in `Main`.

## Error handling

The collector's fetch runs at scrape time, *on the same `/metrics` exposition
path as the operator metrics*. If the fetch threw, the **entire** `/metrics`
response would fail — dropping `events_persisted_total`, GC stats, and
`http_request_duration_seconds` too. That is exactly backwards: during a DB
incident the operator metrics are what you most need.

So the fetch action **must not escape as an exception**. It wraps the DB work in
`catchAny` (shown in the `Main` wiring): on any DB error it returns `[]` — the
business series are simply absent for that scrape while all operator metrics still
expose — and `logWarn`s (optionally bumping an operator error counter). We
deliberately degrade only the business series, never couple operator-metric
availability to business-DB health.

## Performance

Each scrape (~every 15s) runs three `COUNT(*)` queries. At self-hoster scale these
are trivial and indexed. If a table ever grows large enough for `COUNT(*)` to
matter, the mitigation is the increment-only projection from the deletion-caveat
trigger (which also gives O(1) reads) — not premature optimisation now.

## Testing

- **Count helpers** (`UserSpec` / `AccountSpec` unit or integration): after
  seeding rows, `countUsers` / `countRegularAccounts` / `countTransactions` return
  the expected totals; `countRegularAccounts` **excludes** `External` accounts.
- **Collector unit** (in `MetricsSpec`): test the **pure**
  `toSampleGroups :: [GaugeSample] -> [SampleGroup]` directly — assert names,
  values, and `GaugeType`. Do **not** drive the test through
  `registerGaugeCollector`, because the process-global Prometheus
  registry is shared and not deduplicated (repeated registration accumulates,
  making tests order-dependent and leaky). `register` stays a thin, untested
  wrapper.
- **Integration** (`*IntegrationSpec`): register users, create regular + External
  accounts, post transactions through the event store, then run the **fetch
  closure** (the `[GaugeSample]` result) and assert `users`,
  `accounts` (regular-only, External excluded), `transactions`.
  Confirm a cancelled transaction still counts. Prefer asserting on the
  fetch result over scraping `/metrics` (which also shares the global registry).

Reuse Testkit fixtures/generators and the in-memory event store; do not
re-implement setup helpers.

## Out of scope / future

- **Additional business metrics** (active users, per-currency volume, import
  counts). The foundation makes each a small "add a count query + a
  `gaugeSample` entry" change.
- **Per-user figures** — an admin read-model query, not a metric label (see
  Decision 3).
- **Increment-only persisted projection** — deferred until/unless hard-deletion is
  introduced (see the deletion-caveat trigger).
- Any admin-facing JSON/dashboard endpoint (Grafana is the surface).
