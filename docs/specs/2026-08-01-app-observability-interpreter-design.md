---
status: draft
issues: [homeaccounting/tracker#49, aleks-sidorenko/eventium#10]
---

# App-side observability: structured logging + metrics + request context (Spec 2)

## Context

**Spec 2 of the observability initiative** (tracker#49). Spec 1 shipped the generic
eventium `Telemetry` sink + the event-persistence write decorator (eventium PR
#14); the backend wired it with `silentTelemetry` (no-op). This spec makes it do
something: a real interpreter that turns `Signal`s into structured logs +
Prometheus metrics, plus the per-request context (correlation-id + user-id) that
makes logs filterable — the operator-facing half of tracker#49.

Today: RIO's line-oriented `LogFunc`, ad-hoc `logInfo` strings, no metrics, no
request context, and the `MetadataEnricher` seam is wired but **always `id`**
(every call site passes `id`, so `correlationId`/`causationId`/`custom` are never
populated).

## Goals

- **Structured JSON logs** on stdout carrying stable fields — at minimum
  `correlationId`, `userId`, level, message, caller.
- **Per-request context** (`correlationId` always, `userId` for authenticated
  requests) established **once, centrally**, flowing to logs, the metadata
  enricher, and the write-path interpreter.
- **`correlationId` + `userId` persisted on events** via the enricher, so
  write-path telemetry (which runs in IO, detached from the request reader) and
  any async/replay consumer can attribute a stored event.
- **Prometheus metrics** — domain (`events_*`), HTTP (standard), GHC runtime —
  exposed at `/metrics`, low-cardinality (no `user-id` label).
- **Decoupled shipping**: app emits JSON to stdout + exposes `/metrics`; infra
  (Promtail→Loki, Prometheus, Grafana) ships/scrapes. Observability backend is
  **optional** — the app runs without it.

## Non-goals (deferred)

- Read-model lag, subscription, checkpoint, command-dispatch, and process-manager
  telemetry — **Spec 3** (needs the eventium observers on those subsystems).
- Migrating the existing ~150 `logInfo` call sites' *wording* — they keep working;
  they simply gain the JSON envelope + ambient context for free.
- Distributed-trace continuation from an inbound `X-Correlation-Id` header — the
  hook is left in place; wiring it is a trivial later add.
- Alerting rules — dashboards only for now.

## Design

### 1. Logging — a JSON `LogFunc` over a shared `fast-logger` `LoggerSet`

Keep RIO's `LogFunc` abstraction (no katip migration), but be precise about RIO's
shape: `LogFunc` is **opaque and message-only** — it is built solely via
`mkLogFunc :: (CallStack -> LogSource -> LogLevel -> Utf8Builder -> IO ()) ->
LogFunc`, has no exported accessor to introspect/wrap, and its callback carries
only a `Utf8Builder` message (no key/value field slot). So context fields cannot be
"wrapped onto" an existing `LogFunc`; they must be **baked into the formatter when
the `LogFunc` is constructed.**

Design:

- **`AppEnv` holds a shared `fast-logger` `LoggerSet`** (stdout, thread-safe,
  buffered, atomic whole-line writes) plus the `LogFunc` derived from it.
  `fast-logger` must be added to `build-depends` (it is only transitive today via
  `monad-logger`; GHC forbids importing a transitive-only dep).
- A **builder** `mkContextLogFunc :: LogFormat -> LogLevel -> RequestContext ->
  LoggerSet -> LogFunc` constructs, via `mkLogFunc`, a formatter that closes over
  the context and emits through the `LoggerSet` (`pushLogStr`).
- **Min-level filtering must be re-implemented (RIO does not do it for us here).**
  RIO's managed `LogFunc` (built through `logOptionsHandle`/`setLogMinLevel`) gates
  emission by minimum level; a `mkLogFunc`-built `LogFunc` receives the callback for
  **every** level with no gate. So `mkContextLogFunc` takes the configured
  `logging.level` threshold and **drops below-threshold lines** — otherwise §6's
  per-persisted-event `debug` line would flood stdout on every write even at
  `info`. The interpreter (§6) applies the same threshold to its direct writes.
- **One shared line renderer.** Both this formatter and the §6 interpreter encode
  JSON through a single `renderJsonLogLine :: <fields> -> LogStr` so the line schema
  (`{"ts":…,"level":…,"msg":…,"caller":…,"correlationId":…,"userId":…}`) is
  identical from both emitters — no drift for Promtail's `| json` / Grafana.
- **Format-aware.** In `json` mode the formatter renders JSON; in `text` mode it
  renders today's human-readable form (and the §3 rebuild honors the same format —
  it is not hardcoded to JSON). Existing `logInfo "…"` call sites are **unchanged**:
  they invoke the env's `LogFunc`, and because the per-request env carries a
  `LogFunc` **rebuilt** for that request's context (§3, `set logFuncL`, not `over …
  wrap`), they render with the context fields automatically.
- Startup / background work uses a base `LogFunc` built from `emptyRequestContext`
  (nil correlationId) + the same `LoggerSet`.
- Config: `LoggingConfig` gains `format: json | text` (default `json` in
  prod/local; `text` keeps today's human-readable behaviour for dev). In `text`
  mode `logStdoutDev` may be retained; in `json` mode it is removed (below).
- **Remove the existing `loggingMiddleware = logStdoutDev`** (`Web/Server.hs`): it
  writes *colored plaintext* request lines to the same stdout, which would break
  the "every stdout line is one JSON object" invariant Promtail's `| json` pipeline
  (§7) relies on. HTTP metrics (§5) cover request rate/latency/status; if a
  per-request access log is still wanted, emit it as a **JSON** line from the
  context middleware (optional). In `text` log mode, `logStdoutDev` may be retained
  for dev.

**Transport (decoupled, agent-based):** the app only writes JSON to stdout. A log
agent (Promtail / Grafana Alloy) tails the container's stdout and pushes to Loki;
Grafana queries. The app never opens a socket to Loki — same "expose, don't push"
stance as metrics. Loki is optional; without it, stdout JSON is still
human/greppable.

### 2. `RequestContext` on `AppEnv`

```haskell
data RequestContext = RequestContext
  { correlationId :: !UUID,
    userId :: !(Maybe UserId)
  }

emptyRequestContext :: UUID -> RequestContext   -- userId = Nothing
```

A field on `AppEnv` behind a `HasRequestContext` capability, defaulting to an
empty context (nil correlationId, no userId) for non-request work (startup,
background). Overridden per request by the **hoist seam** (§3) building a
per-request env — not by `local` (there is no ambient `AppM` at that Servant
boundary to `local` over).

### 3. Central context establishment — middleware + top-level `Vault`

`AppEnv` is global, and Servant's hoist natural transformation is
request-agnostic, so context is established **once** at a single seam rather than
per-handler:

**Shared vault key.** A `Vault.Key RequestContext` is an IO-minted unique token
(`Vault.newKey`), not a name. Mint it **once at startup** and thread the *same*
`Key` into both the middleware (writer) and the server builder (reader). Keep it on
`AppEnv` (or pass it explicitly). `readRequestContext` runs in the pure `server
vault` position (no IO to mint a UUID), so its **total-default** when the key is
absent is `emptyRequestContext` with a **nil** correlationId — a sentinel, not a
fresh id. In practice the outermost middleware always populates the key, so the
fallback is only a totality guard.

1. **Context WAI middleware** (outermost, before auth): generate a `correlationId`
   (or continue an inbound `X-Correlation-Id`); **best-effort** decode the JWT to
   `Maybe UserId` — reuse the existing non-enforcing `getCurrentUser :: JWTConfig ->
   Maybe Text -> AppM (Maybe AuthenticatedUser)` (`Web/Middleware/Auth.hs`); *no
   enforcement* — `authHandler` still gates protected routes; insert a
   `RequestContext` into the request vault under the shared key; set an
   `X-Correlation-Id` response header.
2. **One top-level `Vault` seam**: `type FullAPI = Vault :> (InfoAPI :<|> API)`.
   The top handler receives the request's `Vault`, reads the `RequestContext`, and
   hoists **both** sub-servers with a per-request env — the `LogFunc` is **rebuilt**
   for the context (not wrapped, per §1):

   ```haskell
   server vault =
     let ctx  = readRequestContext key vault
         env' = env & set requestContextL ctx
                    & set logFuncL (mkContextLogFunc fmt lvl ctx env.loggerSet)  -- rebuild (format+level aware), not wrap
      in hoistServerWithContext api authCtx (appToHandler env') innerServer
   ```

   The existing setup already uses `serveWithContext (Proxy @FullAPI) authContext
   (…)` with `authContext = authHandler jwtConfig :. multipartOptions :.
   EmptyContext` and `hoistServerWithContext api (Proxy @AuthContext) …`; a
   top-level `Vault :>` is orthogonal to that `Context`. Every handler — read or
   write, authenticated or not — runs under an env with context set and a
   context-bound `LogFunc`. **Zero per-handler churn.** Unauthenticated routes
   (`InfoAPI`) get `userId = Nothing`. Because context is established centrally,
   `userId` is populated for every authenticated request by construction — there is
   no "forgot to set it" failure mode to guard against.

- **Accepted wart:** the JWT is decoded twice per authenticated request (best-effort
  in the middleware for context, then in `authHandler` for enforcement, both with
  the same `jwtConfig`). JWT verify is cheap; a later cleanup can have `authHandler`
  read the vault. Documented, not fixed now.

### 4. Enricher wired from context — remove the `id` sprawl

The `MetadataEnricher` is the AppM→IO bridge (command application runs under
`liftIO`). The four command-issuing functions (`runAccountCmd`/`runUserCmd`/
`runTransactionCmd`/`runConfigurationCmd`, `Application.Services.Internal`) stop
taking an `enricher` argument and instead **derive it from `RequestContext`** read
from the env:

```haskell
enricherFromContext :: RequestContext -> MetadataEnricher
enricherFromContext ctx =
  setCorrelationId ctx.correlationId
    . maybe id (insertCustomMetadata "userId" . renderUserId) ctx.userId
```

Each `run*Cmd` reads the context from the env (it already does `lift (view
eventStoreWriterL)` etc. before the `liftIO $ applyXxxCommand … enricher …`, so
adding `ctx <- lift (view requestContextL)` fits the existing shape) and builds the
enricher — the `enricher` **parameter is removed** from the four functions, and the
~20 `id` call sites drop the argument.

Two small helpers are **defined app-side** (not eventium exports):

- `setCorrelationId :: UUID -> EventMetadata -> EventMetadata` = `\md -> md {
  correlationId = Just cid }` (unambiguous record update — `correlationId` is unique
  to `EventMetadata`, in scope via `EventMetadata(..)`).
- `renderUserId :: UserId -> Text` (`UserId` from `Domain.Core.Types`).

`insertCustomMetadata` is already reachable from the `Eventium` umbrella (eventium
0.6.0). `setCorrelationId` sets `EventMetadata.correlationId`; `userId` goes in
`custom`. Both are persisted, so the write-path interpreter and any async/replay
consumer can attribute the event.

- **No command-seam safety net needed:** because context is established centrally
  (§3), `userId` is present for every authenticated request by construction; the
  seam can't distinguish "legitimately unauthenticated" from "dropped" anyway
  (`RequestContext` carries no "auth required" signal — that lives only at the
  handler boundary), so no assertion is placed here.

### 5. Metrics stack

Libraries: **`prometheus-client`** + **`prometheus-metrics-ghc`** +
**`wai-middleware-prometheus`**.

- **`Metrics` record** on `AppEnv` (behind `HasMetrics`) holds the custom metric
  handles, registered into `prometheus-client`'s default registry at startup;
  GHC metrics registered once; HTTP handled by the middleware.
- **`/metrics`** mounted at the **WAI layer** (via `wai-middleware-prometheus`),
  outside the business Servant API, unauthenticated. Prometheus scrapes it.
- **HTTP instrumentation — label by `method` + `status` ONLY (cardinality trap).**
  At the WAI layer the middleware cannot see the Servant route *template*, and its
  default instrumentation labels by request **path/handler** — so
  `/api/accounts/<uuid>`, `/api/transactions/<uuid>`, … would each mint a distinct
  series (unbounded, per-id cardinality). This spec therefore instruments with a
  **constant/dropped handler label**, keeping only `method` + `status`. (Per-route
  latency, which *is* bounded since route templates are a finite set, is a possible
  later enhancement via Servant-aware instrumentation — out of scope here.)
- **Series** (all low-cardinality; **no `user-id` label** — per-user analysis lives
  in logs):

  | Metric | Type | Labels |
  |---|---|---|
  | `events_persisted_total` | Counter | `event_type` (the specific event tag) |
  | `events_write_conflicts_total` | Counter | — |
  | `http_request_duration_seconds` (count via `_count`) | Histogram | `method`, `status` |
  | `ghc_*` | Gauges | — |

- **Naming:** **no application prefix** — disambiguate by the `job` label
  Prometheus attaches. Domain metrics use `events_` as a **subsystem descriptor**
  (`<subsystem>_<name>_<suffix>`, idiomatic — not an app namespace); library/infra
  metrics keep their standard names (`http_request_duration_seconds`, `ghc_*`). This
  keeps every metric name conventional and uniform (no mix of prefixed/unprefixed),
  and needs no custom collectors to fight the libraries. `job`-label
  disambiguation is the common practice for a single-service scrape target.
- **Units:** time in **seconds** (base unit, standard buckets); Grafana panels set
  the display unit to milliseconds. No millisecond-valued metrics.

### 6. The `Telemetry` interpreter — replaces `silentTelemetry`

A `Telemetry (SqlPersistT IO)` built in `Main` as a closure over `Metrics` + the
shared **`LoggerSet`** (both from `AppEnv`), replacing the hardcoded
`silentTelemetry` in `accountingEventStoreWriterWithRaw`. That function currently
hardcodes `telemetryEventStoreWriter silentTelemetry rawWriter`, so it gains a
`Telemetry (SqlPersistT IO)` **parameter** (supplied from `Main`).

The interpreter runs in the write transaction (`SqlPersistT IO`), with **no request
reader** and a **per-signal** context that varies with each `EventMetadata` — which
a field-less RIO `LogFunc` cannot carry. So it does **not** route structured logs
through a `LogFunc`; it emits JSON **directly to the shared `LoggerSet`**
(`pushLogStr`) via the same shared `renderJsonLogLine` (§1) — so its line schema
matches the request-scoped logs — with the fields taken from the signal, applying
the **same configured min-level threshold** (§1 NEW note), and bumps metrics via IO
(`lift`ed into `SqlPersistT`):

- `EventsPersisted _uuid metas wr` → `events_persisted_total{event_type}`
  incremented per event, labeled by each `EventMetadata.eventType` (the specific
  event tag — see §4a) + a `debug`-level JSON line to the `LoggerSet` carrying
  `correlationId`/`userId` **read from the metadata** (this is why §4 persists them).
- `WriteConflict _uuid _ci` → `events_write_conflicts_total` (unlabeled) incremented
  + a `warn`-level JSON line.
- Emit is best-effort and **must not throw** (the Spec 1 contract): logging and
  metric bumps are non-throwing IO.

### 4a. `EventMetadata.eventType` must carry the specific event tag

The codec is `Codec AccountingEvent JSONString`, so eventium's metadata-enriching
writer sets `eventType = "AccountingEvent"` for **every** event (the specific tag —
"TransactionContactSet", … — lives only in the payload). Left unfixed, the
`event_type` label (and any metadata-level filtering) is useless. **Fix (an
eventium improvement, preferred over a backend hotfix):** give eventium's
metadata-enriching writer an app-supplied `event -> EventTypeName` tag function
(default = the current Typeable `eventTypeNameOf`, so it's backward compatible);
the backend supplies one that returns the specific tag (via `accountingEventTypeOf`).
Backward-compatible (old rows keep `"AccountingEvent"`; nothing reads
`metadata.eventType` for logic — schema evolution uses `payload.tag`).

Also **remove the ad-hoc `eventLoggerHandler`/`printEventJSON`** (an unconditional,
formerly multi-line event dump) — the interpreter's structured, level-gated,
typed event log supersedes it.

### 7. Deployment / provisioning (self-hosted, docker-compose)

Additive infra services + provisioning (in `deployment.md` + compose):

- **Loki** (log store), **Promtail** (scrapes the backend container's stdout; JSON
  pipeline; **labels kept small** — `job`, `level`; `correlationId`/`userId` remain
  log *fields* queried via LogQL `| json`).
- **Prometheus** (scrapes `backend:PORT/metrics`).
- **Grafana** provisioned with **Prometheus + Loki datasources** and starter
  dashboards (HTTP rate/latency, event throughput via `rate(events_persisted_total[5m])`,
  write-conflict rate, GHC runtime; a Logs panel filtered by `userId`/`correlationId`).
- All optional: the app requires none of them to run.

## Testing

- **Unit** — `enricherFromContext` **always** sets `correlationId` (a
  `RequestContext` always carries one — background/non-request work supplies its own
  generated or nil id) and sets the `userId` custom key **only when** `userId` is
  `Just`. `mkContextLogFunc` renders a JSON line with the expected fields; `text`
  mode unchanged; a `debug` line is **suppressed at `info`** (min-level filtering,
  NEW-1). `EventsPersisted` labels `events_persisted_total` by the specific
  `event_type` tag from the metadata.
- **Interpreter** — a `Telemetry` over a test `Metrics` + capturing log sink:
  `EventsPersisted` bumps the counter by the batch size with correct labels and logs
  with the metadata's `correlationId`/`userId`; `WriteConflict` bumps conflicts.
- **Integration** — a request through the stack carries a `correlationId` end to end:
  the persisted event's metadata has it, and it appears on the response header; an
  authenticated request populates `userId` in metadata; `/metrics` exports the
  `events_*` series after a write.
- Metrics assertions read `prometheus-client`'s registry snapshot, not scraped text.

## Backward compatibility / rollout

- New dependencies: `prometheus-client`, `prometheus-metrics-ghc`,
  `wai-middleware-prometheus`, and `fast-logger` (the last is transitive-only today
  via `monad-logger`, but must be added to `build-depends` to import
  `System.Log.FastLogger`). All app-level; eventium untouched. The three metrics
  packages are real Hackage libs but can lag GHC releases — **verify/pin their
  GHC-9.10 bounds** during implementation (an `allow-newer` may be needed in
  `cabal.project`).
- Log format defaults to JSON; `text` retained for dev. No API/DTO changes.
- The enricher change is internal; events simply start carrying
  `correlationId`/`userId` (additive metadata, omit-empty from Spec 1 — old rows
  unaffected).
- Depends on eventium `0.6.0` (Spec 1) — already the backend's bound.

## Open questions

- Log `format` default per environment (JSON everywhere vs text in dev) — leaning
  JSON in local/prod, text opt-in.
- Whether to also emit `events_persisted_total` from the *synchronous* read-model
  path or only the write decorator — write decorator only for Spec 2 (single source
  of truth for "persisted").
