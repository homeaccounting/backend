# App-side Observability Interpreter (Spec 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn eventium's write-path `Signal`s into structured JSON logs + Prometheus metrics, establish per-request context (correlation-id + user-id) that flows to logs and persisted-event metadata, and ship the observability wiring — the operator-facing half of tracker#49.

**Architecture:** (B) JSON logging over a shared `fast-logger` `LoggerSet` with a per-request-rebuilt `LogFunc`; central request-context via a WAI middleware + a top-level Servant `Vault` + per-request env re-hoist; the `MetadataEnricher` derived from context (retiring the ~20 `id` sites); a `Telemetry (SqlPersistT IO)` interpreter replacing `silentTelemetry`; `prometheus-client` metrics at a WAI-mounted `/metrics`; decoupled Promtail/Loki + Prometheus/Grafana shipping.

**Tech Stack:** Haskell GHC 9.10, RIO, Servant, `fast-logger`, `vault`, `prometheus-client` + `prometheus-metrics-ghc` + `wai-middleware-prometheus`. All code in the **backend** repo `/Users/oleksandrsy/Projects/Current/Wix/server-infra`, branch `feat/eventium-telemetry`.

**Spec:** `docs/specs/2026-08-01-app-observability-interpreter-design.md` — read it for design rationale; this plan is the mechanical how. **Metric names are un-prefixed** (`events_persisted_total`, `events_write_conflicts_total`, `http_request_duration_seconds`, `ghc_*`) — `job`-label disambiguation, per the spec's final naming decision.

---

## Environment & conventions

- Toolchain on PATH. Build `just build`; test `just test`. The full suite needs a manual `eventium_test` Postgres DB; **~28 postgresql-integration failures are the pre-existing environmental baseline**, not regressions. Focused: `cabal test backend-test --test-option=--match --test-option="/Pattern/"`.
- `just format && just lint` before each commit (`-fci`/-Werror gate). Commits are GPG-signed; if signing refuses, leave staged and report.
- Builds against **local eventium 0.6.0** via `cabal.project.local`: `Telemetry(..)`, `Signal(..)`, `telemetryEventStoreWriter`, `insertCustomMetadata` are reachable from the `Eventium` umbrella (already imported in `Infrastructure/Eventium.hs`).
- Tests under `test/`, hspec-discover (`*Spec.hs`, module matches path, exports `spec`).
- **Ordering principle (why this order):** Tasks 2–5 add **pure, independently-unit-testable modules with NO `AppEnv` change**, so every commit builds green. Task 6 adds all four `AppEnv` fields + all `Main.hs` wiring **at once** (the only point `AppEnv` construction changes). Tasks 7–8 then use the new fields. Don't add an `AppEnv` field before Task 6.

## Confirmed facts (verified against the code — trust these)

- `Config.LoggingConfig` **already has** `format :: LogFormat` where `LogFormat = LogText | LogJson` (`Config.hs`), and `LogLevel = LogDebug|LogInfo|LogWarn|LogError`. **No Config change needed** — consume `config.logging.format` / `.level`.
- `Internal.hs` `run*Cmd` bodies do `writer <- lift (view eventStoreWriterL); reader <- lift (view eventStoreReaderL); result <- liftIO $ applyXxxCommand writer reader enricher …`. Adding `ctx <- lift (view requestContextL)` fits the identical pattern. `runConfigurationCmd`/`runTransactionCmd` take a `translate` arg **before** `enricher`.
- `Web/Server.hs`: `serveWithContext (Proxy @FullAPI) authContext (infoServer :<|> hoistedServer env)`; `infoServer = hoistServer infoAPI (appMToHandler env) infoHandler`; `hoistedServer env = hoistServerWithContext api (Proxy @AuthContext) (appMToHandler env) server`. The NT is **`appMToHandler`** (not `appToHandler`).
- `Auth.hs`: `getCurrentUser :: JWTConfig -> Maybe Text -> AppM (Maybe AuthenticatedUser)`; `AuthenticatedUser.userId :: UserId` (accessor via `OverloadedRecordDot`).
- `Infrastructure/Eventium.hs`: `accountingEventStoreWriter config = accountingEventStoreWriterWithRaw (postgresqlTaggedEventStoreWriter config) config` — **both** functions need the new telemetry param threaded; `Main.hs:275` calls `accountingEventStoreWriter`.
- `Main.hs`: `createLogOptions config` + `withLogFunc logOptions $ \logFunc -> runRIO logFunc $ … initializeEnvironment logFunc config …`; `spawnRatePublisher rateProvider writer reader pool logFunc` (line 347).

## File structure

- **Create** `src/Infrastructure/Logging.hs`, `src/Infrastructure/Observability/{Context,Metrics,Interpreter}.hs`, `src/Web/Middleware/Context.hs`.
- **Modify** `package.yaml`, `cabal.project` (allow-newer if needed), `app/Main.hs`, `src/Infrastructure/App.hs`, `src/Infrastructure/Eventium.hs`, `src/Application/Services/Internal.hs`, the ~20 `run*Cmd` call sites, `src/Web/Server.hs`.
- **Create** `docker-compose.observability.yaml`, `deploy/observability/*`; **Modify** `docs/deployment.md`.

---

## Task 1: Dependencies + RTS stats

**Files:** `package.yaml`, `cabal.project`

- [ ] **Step 1** — add to the library `dependencies:`: `prometheus-client`, `prometheus-metrics-ghc`, `wai-middleware-prometheus`, `fast-logger`, **`vault`** (Servant re-exports the `Vault` *combinator* but not `Data.Vault.Lazy` — GHC forbids importing a transitive-only dep). Conservative bounds.
- [ ] **Step 2** — enable GC stats so `ghc_*` metrics are non-zero: add `-with-rtsopts=-T` to the **executable** `ghc-options` in `package.yaml`.
- [ ] **Step 3** — `just build`. If a metrics lib's GHC-9.10 upper bound fails to solve, add a scoped `allow-newer:` in `cabal.project` (commented). Iterate to green (no code uses the deps yet).
- [ ] **Step 4** — commit `build(deps): prometheus + fast-logger + vault; -with-rtsopts=-T`.

---

## Task 2: Observability Context module (pure — no AppEnv change)

**Files:** Create `src/Infrastructure/Observability/Context.hs`; Test `test/Infrastructure/Observability/ContextSpec.hs`

> First of the pure modules — no dependency on the others; the Logging module (Task 3) imports `RequestContext` from here.

- [ ] **Step 1: RED test:**
  - `setCorrelationId cid (emptyMetadata "E")` → `correlationId == Just cid`.
  - `enricherFromContext (RequestContext cid (Just uid)) (emptyMetadata "E")` → `correlationId == Just cid` and `custom` has `("userId", renderUserId uid)`.
  - `enricherFromContext (RequestContext cid Nothing) …` → correlationId set, `custom` empty.
  - `readRequestContext key emptyVault` → `emptyRequestContext nil` (totality).
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement `Observability/Context.hs`:**
  - `data RequestContext = RequestContext { correlationId :: !UUID, userId :: !(Maybe UserId) }` (import `UserId` from `Domain.Core.Types`, `UUID` from eventium/`Data.UUID`).
  - `emptyRequestContext :: UUID -> RequestContext` (`userId = Nothing`); export a `nilRequestContext = emptyRequestContext Data.UUID.nil`.
  - `class HasRequestContext env where requestContextL :: Lens' env RequestContext` (the `AppEnv` instance lands in Task 6).
  - `readRequestContext :: Vault.Key RequestContext -> Vault.Vault -> RequestContext` (`fromMaybe nilRequestContext . Vault.lookup key`).
  - `setCorrelationId :: UUID -> EventMetadata -> EventMetadata = \md -> md { correlationId = Just cid }`.
  - `renderUserId :: UserId -> Text` (however `UserId` renders — `UUID.toText`/`textDisplay`; confirm the `UserId` shape).
  - `enricherFromContext :: RequestContext -> MetadataEnricher` = `setCorrelationId ctx.correlationId . maybe id (insertCustomMetadata "userId" . renderUserId) ctx.userId`.
- [ ] **Step 4: GREEN. Step 5: commit** `feat(observability): RequestContext + enricher-from-context`.

---

## Task 3: Logging module (pure — no AppEnv change)

**Files:** Create `src/Infrastructure/Logging.hs`; Test `test/Infrastructure/LoggingSpec.hs`

> Imports `RequestContext` from Task 2 (already committed).

- [ ] **Step 1: RED test** (pure functions, no IO logger needed):
  - `shouldLog :: LogLevel -> LogLevel -> Bool` — `shouldLog LevelInfo LevelDebug == False`, `shouldLog LevelInfo LevelWarn == True`.
  - `renderJsonLogLine :: LogLevel -> RequestContext -> Maybe Text -> Utf8Builder -> LBS.ByteString` — for `RequestContext cid (Just u)` the output is one line (no interior `\n`), decodes as JSON with `"level"="info"`, `"msg"="hi"`, `"correlationId"=<cid>`, `"userId"=<renderUserId u>`; for `userId=Nothing` there is no `userId` key (or it is null — pick one and assert it).
- [ ] **Step 2: RED** (`… --match "/Infrastructure.Observability.Logging/"`).
- [ ] **Step 3: Implement `Infrastructure/Logging.hs`:**
  - `shouldLog threshold ev = ev >= threshold`.
  - `renderJsonLogLine` builds an aeson `object`/encodes to one line + `\n`.
  - `mkContextLogFunc :: LogFormat -> LogLevel -> RequestContext -> LoggerSet -> LogFunc`:
    `mkLogFunc $ \_cs _src lvl msg -> when (shouldLog threshold lvl) $ pushLogStr set (toLogStr (render fmt lvl ctx msg))` where `render LogJson = renderJsonLogLine …`, `render LogText = <human line>`.
  - `newStdoutLoggerSet :: IO LoggerSet = FastLogger.newStdoutLoggerSet FastLogger.defaultBufSize`.
  - **Expose `rioLevel :: Config.LogLevel -> RIO.LogLevel`** here (the mapping is currently inlined as `convertLogLevel` in `Main.createLogOptions`, `Main.hs:233`) — Tasks 6 and 8 reuse it.
- [ ] **Step 4: GREEN. Step 5: commit** `feat(logging): JSON structured LogFunc over fast-logger`.

---

## Task 3.5 (PREREQUISITE for Task 4/5 labels): fix `EventMetadata.eventType` to carry the specific event tag — eventium + app

**Why:** the codec is `Codec AccountingEvent JSONString`, so eventium's metadata-enriching writer sets `eventType = eventTypeNameOf @AccountingEvent` = `"AccountingEvent"` for **every** event. The specific tag ("TransactionContactSet", …) lives only in the payload. So the write-path `Signal`'s `[EventMetadata]` can't distinguish event types → the `event_type`/`aggregate_type` metric labels (and any metadata-level analytics/log filtering) are useless. This is a latent defect, not telemetry-specific. **DECISION: fix it (Option B).**

**Mechanism — DECIDED: (a) the eventium improvement** (user preference: prefer an eventium improvement over a backend hotfix — see memory). Implemented on the **eventium branch `feat/telemetry-event-persistence`** (updating PR #14), consumed by the backend at Task 6.
- **eventium:** give `metadataEnrichingEventStoreWriterWithEnricher` an app-supplied `event -> EventTypeName` tag function instead of the Typeable `eventTypeNameOf`. Keep a default (= `eventTypeNameOf`) so existing callers are unchanged and it's backward compatible. Add a test (a written event's metadata carries the supplied tag). Bump CHANGELOG.
- **backend (Task 6):** supply the tag extractor at the `metadataEnrichingEventStoreWriterWithEnricher` sites — a value-level `AccountingEvent -> EventTypeName` (reuse `accountingEventTypeOf . toJSON`, or a constructor-tag function). Now `metadata.eventType` = the specific tag.
- **NOT the backend `contramap` hotfix** (re-deriving in `Infrastructure.*` what the library should provide) — rejected per the eventium-first preference.
- **Backward compat:** old stored rows keep `"AccountingEvent"`; nothing reads `metadata.eventType` for logic (schema evolution uses `payload.tag`), so changing new writes is safe.

**Tasks 4 & 5 don't wait on this:** they're pure modules and test with **constructed** specific-tag `EventMetadata` (e.g. `emptyMetadata "TransactionContactSet"`). This fix only makes *production* metadata carry the specific tag; the integration test (Task 8) verifies it end-to-end.

## Task 4: Metrics module (pure factory — no AppEnv change)

**Files:** Create `src/Infrastructure/Observability/Metrics.hs`; Test `test/Infrastructure/Observability/MetricsSpec.hs`

> Depends on Task 3.5: `metadata.eventType` now carries the specific tag, so the `event_type` label is meaningful (the tag itself).

**Labels simplified:** `events_persisted_total{event_type}` only — `event_type` = the specific tag from `metadata.eventType` (Task 3.5). **`aggregate_type` is dropped** (mapping ~40 tags → 4 aggregates by string is fragile; `event_type` is strictly more informative and PromQL can roll up by prefix). `events_write_conflicts_total` has **no label** (the Signal's `WriteConflict` carries no event type).

- [ ] **Step 1: RED test:**
  - metric handles increment: build a `Metrics` (below), `incEventPersisted metrics "TransactionContactSet"`, then read the counter value == 1 via `getCounter`/sample — **without** touching the global registry.
  - `incWriteConflict metrics` increments the (unlabeled) conflicts counter.
  - `registerMetrics` (exercised once) makes `exportMetricsAsText` contain `events_persisted_total` and `events_write_conflicts_total`.
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement `Observability/Metrics.hs`:**
  - `data Metrics = Metrics { eventsPersisted :: !(Vector Text Counter), eventWriteConflicts :: !Counter }` — `Vector Text Counter` (single `event_type` label), plain `Counter` for conflicts.
  - `registerMetrics :: IO Metrics` — `register (vector "event_type" (counter (Info "events_persisted_total" "…")))`, `register (counter (Info "events_write_conflicts_total" "…"))`, and `void $ register ghcMetrics` (from `Prometheus.Metric.GHC`).
  - Helpers `incEventPersisted :: Metrics -> Text -> IO ()` (via `withLabel`), `incWriteConflict :: Metrics -> IO ()` (via `incCounter`).
  - `class HasMetrics env where metricsL :: Lens' env Metrics` (the `AppEnv` instance lands in Task 6). No `aggregateTypeOf`.
  - **Test hygiene:** unit-test increments on handles built directly (no `register`) to avoid the process-global default-registry contamination; exercise `registerMetrics`/`exportMetricsAsText` in a single dedicated example.
- [ ] **Step 4: GREEN. Step 5: commit** `feat(observability): Prometheus metrics + aggregate-type mapping`.

---

## Task 5: Telemetry interpreter module (pure factory — no AppEnv change)

**Files:** Create `src/Infrastructure/Observability/Interpreter.hs`; Test `test/Infrastructure/Observability/InterpreterSpec.hs`

> The interpreter does **not** wire into the event-store writer here (that's Task 6, with the Main change) — it's a pure factory taking its deps explicitly, so it's unit-testable and adds no `AppEnv`/`Eventium.hs` change yet.

- [ ] **Step 1: RED test** — test the **IO** core directly (a `Telemetry (SqlPersistT IO)` value is awkward to run without a `SqlBackend`). Expose a top-level `interpretSignal :: LogLevel -> (LogStr -> IO ()) -> Metrics -> Signal -> IO ()` (the sink is `pushLogStr loggerSet` in prod; **unregistered** metric handles in the test — assert on `getCounter` deltas, never absolute values, to stay clean of the global registry). Assert:
  - `interpretSignal LevelDebug sink m (EventsPersisted nil [md "AccountOpened", md "AccountOpened"] wr)` → `events_persisted_total{event_type="AccountOpened"}` delta == 2, and `sink` received one line carrying the metadata's `correlationId`/`userId`.
  - `interpretSignal … (WriteConflict nil ci)` → `events_write_conflicts_total` (unlabeled) delta == 1.
  - a `debug` persist line is suppressed when the level is `LevelInfo` (`interpretSignal LevelInfo …` → sink not called for the debug line).
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement.**
  - `interpretSignal level sink metrics sig` (IO): `EventsPersisted _ metas wr → do { for_ metas $ \m -> incEventPersisted metrics m.eventType; when (shouldLog level LevelDebug) $ sink (renderJsonLogLine LevelDebug (contextFromMeta metas) …) }`; the conflict case symmetrically (`incWriteConflict metrics`). `contextFromMeta` reads `correlationId` + `custom!"userId"` from the first metadata; reuse `renderJsonLogLine` (shared schema).
  - `mkTelemetry :: LogLevel -> (LogStr -> IO ()) -> Metrics -> Telemetry (SqlPersistT IO)` = `Telemetry $ \sig -> lift (interpretSignal level sink metrics sig)` — a thin wrapper.
- [ ] **Step 4: GREEN. Step 5: commit** `feat(observability): Telemetry interpreter (logs+metrics)`.

---

## Task 6: AppEnv fields + Main wiring (the single AppEnv-changing task)

**Files:** Modify `src/Infrastructure/App.hs`, `app/Main.hs`, `src/Infrastructure/Eventium.hs`; Test: full build + a smoke test that a write emits a metric

This is the integration task — it adds all four `AppEnv` fields and every `Main` wiring at once so the build goes red→green in one coherent step.

- [ ] **Step 1: RED** — this task's gate is a **green `-fci` build** (the arity/field changes are compiler-enforced). Defer the behavioral write→metric assertion to Task 8's integration test. If adding a smoke assertion here, assert **name-presence only** (`exportMetricsAsText` *contains* `events_persisted_total`) — **never an absolute counter value**: `prometheus-client`'s `register` appends to a **process-global** default registry that accumulates across tests, and `registerMetrics` is **non-idempotent** (two `AppEnv`s → duplicate collectors). State which gate you use.
- [ ] **Step 2: Implement — `App.hs`:** add strict fields `loggerSet :: !LoggerSet`, `requestContext :: !RequestContext`, `contextVaultKey :: !(Vault.Key RequestContext)`, `metrics :: !Metrics`; add instances `HasRequestContext AppEnv` (lens on `requestContext`) and `HasMetrics AppEnv` (lens on `metrics`); update the `initializeAppEnv` constructor.
- [ ] **Step 3: Implement — `Eventium.hs`:** thread a `telemetry :: Telemetry (SqlPersistT m)` parameter through **both** `accountingEventStoreWriterWithRaw` and the public `accountingEventStoreWriter`, and replace the hardcoded `telemetryEventStoreWriter silentTelemetry rawWriter` with `telemetryEventStoreWriter telemetry rawWriter`. **Also remove the `eventLoggerHandler`** from `versionedHandler` (and delete `eventLoggerHandler`/`printEventJSON`) — the Telemetry interpreter now logs persisted events (structured, level-gated, with the specific `event_type` from Task 3.5 + correlationId), so the ad-hoc handler is redundant. (The interim `d21c7e8` compact-JSON fix is superseded here.) **Also implement the Task 3.5 `eventType`-specificity fix here** (mechanism (a) or (b)) so the persisted metadata + the Signal carry the specific event tag — add a test proving a written event's stored `metadata.eventType` is the specific tag, not `"AccountingEvent"`.
- [ ] **Step 4: Implement — `Main.hs` + `initializeEnvironment` bootstrap swap.** The writer wiring (`Main.hs:275`), the interpreter, and the `AppEnv` assembly (`Main.hs:384`) all live **inside** `initializeEnvironment :: LogFunc -> AppConfig -> VersionInfo -> RIO LogFunc AppEnv`, while the base `LogFunc` must be built in `main` from the shared `LoggerSet`. So thread **one** `LoggerSet` (and the derived resources) from `main` **into** `initializeEnvironment` — change its signature to also take `LoggerSet` (and mint `metrics`/`vaultKey` in `main` too, or inside `initializeEnvironment`; whichever, create each **exactly once**):
  - In `main`: `loggerSet <- newStdoutLoggerSet`; `let baseLogFunc = mkContextLogFunc config.logging.format (rioLevel config.logging.level) nilRequestContext loggerSet`; replace `withLogFunc logOptions $ \logFunc -> runRIO logFunc …` with `runRIO baseLogFunc $ … initializeEnvironment loggerSet config versionInfo` (drop `createLogOptions`, or keep only for `text`-mode dev). `spawnRatePublisher … logFunc` (line 347) now receives `baseLogFunc`.
  - In/around `initializeEnvironment` (with `loggerSet` in scope): `metrics <- liftIO registerMetrics`; `vaultKey <- liftIO Vault.newKey`; `let telemetry = mkTelemetry (rioLevel config.logging.level) (pushLogStr loggerSet) metrics`; pass `telemetry` into `accountingEventStoreWriter telemetry config`; pass `loggerSet` / `requestContext = nilRequestContext` / `contextVaultKey = vaultKey` / `metrics` into `initializeAppEnv`.
  - **Exactly one `LoggerSet` in the whole process** (two would interleave stdout buffers).
- [ ] **Step 5: GREEN** — `just build` clean; gate per Step 1. **Step 6: commit** `feat(observability): wire LoggerSet + metrics + interpreter into AppEnv/Main`.

---

## Task 7: Enricher from context — retire the `id` sites

**Files:** Modify `src/Application/Services/Internal.hs` + the ~20 call sites; Test `test/Application/…` (metadata carries context)

- [ ] **Step 1: RED test** — issue a command under a test env whose `requestContext` has known `correlationId`/`userId` (use the in-memory event-store harness), assert the stored `EventMetadata` has that `correlationId` and `custom!"userId"`. (Currently `id` → empty ⇒ RED.)
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement.** In `Internal.hs`, drop the `MetadataEnricher ->` param from all four `run*Cmd`; inside each add `ctx <- lift (view requestContextL); let enricher = enricherFromContext ctx` before the `liftIO $ applyXxxCommand … enricher …`. Then remove the `id` argument at every call site. **Enumerate by the compiler** (arity change is a hard error) — don't rely on a grep: note `runConfigurationCmd`/`runTransactionCmd` pass `translate` first, so `id` is their *second* arg. Sites are in `AccountService`, `UserService`, `TransactionService`, `ConfigurationService`, `AuthService`.
- [ ] **Step 4: GREEN** (build + the metadata test). **Step 5: commit** `refactor(services): derive metadata enricher from request context`.

---

## Task 8: Context middleware + Vault + `/metrics` + hoist

**Files:** Create `src/Web/Middleware/Context.hs`; Modify `src/Web/Server.hs`; Test `test/Web/ObservabilityIntegrationSpec.hs`

- [ ] **Step 1: RED integration test.** Reuse the existing integration harness (the one that builds a test `AppEnv` against `eventium_test`) and its **JWT-signing helper** to mint a valid token (grep the test suite for an existing `signToken`/auth-integration helper; do not hand-roll JWT). Assert:
  - response carries an `X-Correlation-Id` header;
  - an authenticated write yields a persisted event whose metadata has `userId` and a `correlationId` equal to the response header;
  - `GET /metrics` body contains `events_persisted_total` after the write.
  - (If a full authenticated integration env is not readily available, split: an unauthenticated request proves `X-Correlation-Id` + `/metrics`; assert `userId` at the unit level via Task 7. State the split.)
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement.**
  - `Web/Middleware/Context.hs`: `contextMiddleware :: AppEnv -> Middleware` (it needs the env to run `getCurrentUser`, which is `AppM`). Per request: `cid <- maybe UUID.nextRandom pure (parseInbound (lookup "X-Correlation-Id" (requestHeaders req)))`; `muser <- runAppM env (getCurrentUser env.jwtConfig (bearerHeader req))`; `let ctx = RequestContext cid (fmap (.userId) muser)`; `let req' = req { vault = Vault.insert env.contextVaultKey ctx (vault req) }`; add `X-Correlation-Id: cid` to the response; `app req' respond`.
  - `Web/Server.hs`: `type FullAPI = S.Vault S.:> (InfoAPI S.:<|> API)`. The server becomes `\vault -> let ctx = readRequestContext env.contextVaultKey vault; env' = env { requestContext = ctx, logFunc = mkContextLogFunc env.config.logging.format lvl ctx env.loggerSet } in (hoistServer infoAPI (appMToHandler env') infoHandler S.:<|> hoistServerWithContext api (Proxy @AuthContext) (appMToHandler env') server)`. Add `contextMiddleware env` to the WAI stack (outermost). **Remove `loggingMiddleware = logStdoutDev`** when `format == LogJson` (guard); it breaks the JSON-only stdout invariant.
  - **Unify the persistent/`monad-logger` SQL logs onto the JSON stream.** `persistent` emits `[Debug#SQL] …` **plaintext** via `runStdoutLoggingT` at three sites — `App.hs:665` (`runDb`, the main per-query path), `Database.hs:248` (`createConnectionPool`), `Database.hs:303` (`runDbLoggedDirect`) — a second, non-RIO stdout logger that also violates the JSON-only invariant (in `json`+`debug` mode; at `info` it's already `filterLogger`-gated off). In `json` mode, replace `runStdoutLoggingT` with `runLoggingT … sqlJsonSink` where `sqlJsonSink :: Loc -> LogSource -> LogLevel -> LogStr -> IO ()` writes a `debug` JSON line (`source:"sql"`) to the **same `LoggerSet`**, keeping the `filterLogger` level gate; since `runDb` is in `AppM`, stamp the line with the request's `correlationId` (read `requestContextL`) so SQL queries are traceable to their request in Loki. **DECISION: bridge-to-JSON chosen** (not silence) — keep SQL visible-but-structured, level-gated, correlationId-tagged.
  - Mount `/metrics` + HTTP instrumentation via `wai-middleware-prometheus`. **Low-cardinality:** use `instrumentApp "<constantHandler>"` (constant handler label ⇒ effectively `method`+`status`+constant, no per-path explosion) for request instrumentation, and the settings middleware `prometheus def { prometheusEndPoint = ["metrics"], prometheusInstrumentApp = False }` solely to serve `/metrics`. Verify the emitted series has no unbounded path label before finishing.
- [ ] **Step 4: GREEN** (integration; full build). **Step 5: commit** `feat(web): central request context, /metrics, JSON stdout`.

---

## Task 9: Deployment — hand-off + app-side docs only

**The observability *stack* (Prometheus/Loki/Promtail/Grafana) is NOT built in this
repo.** It lives in the infra repo (`homeaccounting/infra`, a.k.a. `fire-console`) —
tracked in **homeaccounting/infra#8** with design at that repo's
`docs/specs/2026-08-02-observability-stack-design.md`. server-infra owns only the
**app seams**: expose `GET /metrics` (Tasks 6/8) and write JSON logs to stdout (Task
3/6). Keep this repo product-scoped; the scraping/shipping/dashboards are infra.

**Files (this repo):** Modify `docs/deployment.md` only.

- [ ] **Step 1** — `docs/deployment.md`: document the two **operator seams** this app
  provides — `GET /metrics` (Prometheus text; unauthenticated; low-cardinality:
  `events_*` + `http_request_duration_seconds{handler,method,status}` + `ghc_*`, no
  per-user/per-path labels) and **JSON stdout logs** (one object per line;
  `correlationId`/`userId` are log *fields*). Note that the app runs **without** any
  observability backend, and point to **homeaccounting/infra#8** for the stack.
- [ ] **Step 2 — attribution (document it in `docs/deployment.md`):**
  - **Request-path events/logs** carry `correlationId` + `userId` (from the request context via the enricher).
  - **Saga/process-manager-emitted events DO carry them too** (`43a94dc`): our sagas run **synchronously within the originating request**, and `ProcessManager.react` receives the triggering event's metadata, so every `IssueCommand` in the 4 PMs uses `propagateContext trigMeta` (copies `correlationId` + `userId`) instead of `id` — the whole saga chain is attributed to the originating request. (Earlier framing of this as an inherent limitation was WRONG — corrected per user: sagas are sync/in-request.)
  - **Only genuine background writes remain unattributed:** the ExchangeRate publisher (timer) and startup seed — no request exists. Their log lines carry a **nil** `correlationId` (`00000000-…`) sentinel.
- [ ] **Step 3** — commit `docs(deployment): observability seams (/metrics + JSON logs); stack lives in infra#8`. The actual stack (compose services, Prometheus/Loki/Promtail config, Grafana dashboards, Caddy route) is done under **homeaccounting/infra#8**, not here.

---

## Done criteria (this repo — backend/app only)

- `just build` clean; focused suites green; the integration test passes (correlation-id end-to-end, `userId` in metadata, `/metrics` exports `events_*`).
- Persisted events carry `correlationId` + `userId`; stdout logs are single-line JSON with those fields; `/metrics` exposes `events_*` + `http_request_duration_seconds` + `ghc_*`, all low-cardinality (no user-id label, no per-path label).
- No behavioural regression: `just test` shows only the known ~28 `eventium_test` environmental failures.
- **The observability *stack* (Prometheus/Loki/Grafana) is out of scope for this repo — homeaccounting/infra#8.** The app requires no observability backend to run.
