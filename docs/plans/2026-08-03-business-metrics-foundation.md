# Business Metrics Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose three unlabelled Prometheus gauge series — `users`, `accounts` (regular only), `transactions` — on the existing `/metrics` endpoint, computed by scrape-time `COUNT(*)` on the persisted read-model tables.

**Architecture:** Add total-count query helpers to the existing User / Account / Transaction read models. Extend the existing `Infrastructure.Observability.Metrics` module with a generic scrape-time Prometheus **gauge** collector over an *injected* `IO [GaugeSample]` fetch action (so Infrastructure never imports Application — layering). `app/Main.hs` builds that fetch closure over the connection pool (`runDbDirect`, wrapped in `handleAny` so a DB error drops only the business series, not operator metrics) and registers the collector once. Gauge (not counter) because the value is a recomputed `COUNT(*)` snapshot that a rebuild under changed rules can lower. No new table, projection, migration, or backfill — the read-model tables already hold full history.

**Tech Stack:** Haskell (GHC 9.10, RIO, `NoImplicitPrelude`), `persistent` (`SqlPersistT`), `prometheus-client` 1.1, Hspec + `hspec-discover`, in-memory SQLite test harness (`Testkit.InMemoryEventStore`).

**Spec:** [`docs/specs/2026-08-03-business-metrics-foundation-design.md`](../specs/2026-08-03-business-metrics-foundation-design.md)

**Conventions to honor throughout:**
- `NoFieldSelectors`, `StrictData`, `-Wall`/`-Werror` (via `-fci`). No unused imports.
- Never export data constructors or field selectors — expose a smart constructor + a consumer in the same module instead.
- Run `just build` (runs hpack) after adding any file so new modules are picked up; `hspec-discover` auto-finds new `*Spec.hs`.
- Use `@superpowers:test-driven-development` (Red → Green → Refactor) for every task and `@superpowers:verification-before-completion` before claiming done.
- Commit after each task.

---

## File Structure

**Modify:**
- `src/Application/ReadModels/User.hs` — add `countUsers` (export + `count` import + impl).
- `src/Application/ReadModels/Account.hs` — add `countRegularAccounts` (export + impl; `count`/`(!=.)`/`External` already reachable).
- `src/Infrastructure/Observability/Metrics.hs` — add the generic scrape-time gauge collector (`GaugeSample` abstract + `gaugeSample` smart ctor, pure `toSampleGroups`, `registerGaugeCollector`) alongside the existing operator-metric handles. **No new module** — "business" is a caller concern, so the infra module stays metric-generic and any future computed-at-scrape gauge lives here too.
- `test/Infrastructure/Observability/MetricsSpec.hs` — pure unit tests for `toSampleGroups` (no registry touch).
- `app/Main.hs` — build the fetch closure + register the collector during metrics setup (the only place the concrete `users`/`accounts`/`transactions` "business" series are named).

**Modify (tests):**
- `test/Application/ReadModels/PersistentUserReadModelSpec.hs` — `countUsers` example.
- `test/Application/ReadModels/PersistentAccountReadModelSpec.hs` — `countRegularAccounts` example (regular counted, External excluded).
- `test/Application/ReadModels/PersistentTransactionReadModelSpec.hs` — `countTransactions` example (all rows, incl. cancelled/failed).

`countTransactions :: (MonadIO m) => SqlPersistT m Int` **already exists** (`src/Application/ReadModels/Transaction.hs:457`, already exported) — reuse as-is; Task 3 only adds a locking test for its business-metric semantic.

**Cross-repo (separate PR, infra#8):**
- Create: `../fire-console/observability/grafana/dashboards/business.json` — Grafana dashboard (Task 7). Lands in the `homeaccounting/infra` repo on branch `feat/observability-stack`, not the backend repo.

---

## Task 1: `countUsers` query

**Files:**
- Modify: `src/Application/ReadModels/User.hs` (export list; `Database.Persist` import; new function)
- Test: `test/Application/ReadModels/PersistentUserReadModelSpec.hs`

- [ ] **Step 1: Write the failing test.** In `PersistentUserReadModelSpec.hs`, add `countUsers` to the `Application.ReadModels.User` import list, and add an example inside the spec tree (it reuses the file's existing `registered` / `registeredViaTelegram` builders and `seedEnv`):

```haskell
  describe "countUsers" $ do
    it "counts every registered user, both registration paths" $ do
      env <-
        seedEnv
          [ registered (user 1) "a@test.com" 0 0,
            registered (user 2) "b@test.com" 0 1,
            registeredViaTelegram (user 3) 777 0 2
          ]
      runDbIn env countUsers `shouldReturn` 3
```

- [ ] **Step 2: Run it, verify it fails to compile** (`countUsers` not in scope).

Run: `cabal test all --test-option='--match' --test-option='/Persistent User read model/countUsers/'`
Expected: build failure — `Variable not in scope: countUsers`.

- [ ] **Step 3: Implement.** In `src/Application/ReadModels/User.hs`: add `countUsers` to the module export list (near `userExists`); add `count` to the `Database.Persist (...)` import list; add:

```haskell
-- | Total number of registered users (both registration paths). Backs the
-- @users@ business metric.
countUsers :: (MonadIO m) => SqlPersistT m Int
countUsers = count ([] :: [Filter UserEntity])
```

(`Filter` is already imported; `MonadIO` and `SqlPersistT` are already in scope — mirror `countTransactions` in `Transaction.hs`.)

- [ ] **Step 4: Run the test, verify it passes.**

Run: `cabal test all --test-option='--match' --test-option='/Persistent User read model/countUsers/'`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add src/Application/ReadModels/User.hs test/Application/ReadModels/PersistentUserReadModelSpec.hs
git commit -m "feat(readmodel): countUsers total query for users metric"
```

---

## Task 2: `countRegularAccounts` query

**Files:**
- Modify: `src/Application/ReadModels/Account.hs` (export list; import `count` + `(!=.)`; new function)
- Test: `test/Application/ReadModels/PersistentAccountReadModelSpec.hs`

Note: `AccountType (..)` (with the `External` constructor) is already imported in `Account.hs`; `Filter` is imported; `count` and `(!=.)` need adding to the `Database.Persist` import list.

- [ ] **Step 1: Write the failing test.** The account persistent spec seeds via services; to target regular-vs-External directly, add a small local event-builder + a focused example. This raw-event pattern needs import additions the current spec lacks — add them all:
  - to `import Application.ReadModels.Account (...)`: `applyAccountEvent`, `countRegularAccounts`
  - to `import Testkit.InMemoryEventStore (...)`: `seedGlobals`
  - to `import Testkit.Helpers (...)`: `globalEvent`, `mockAccountId`, `mockUserId`
  - to `import Domain.Core.Types (...)`: `AccountType (..)`, `AccountSubtype (..)`, `defaultCash`, `AccountId`
  - add `import Domain.Account.Events (AccountCreated (..))`
  - `AccountingEvent (..)` (for `AccountCreatedEvent`) from `Domain.Models`, and `qualified Eventium` / `qualified Data.UUID as UUID` if not already imported.

  The account spec has **no `user` helper** (that lives only in the user spec) — define one locally. Add these helpers + example (follows the `userGlobal`/`registered` pattern from the User spec):

```haskell
-- near the top-of-spec helpers
user :: Word32 -> UserId
user n = mockUserId (UUID.fromWords n 0 0 0)

acctCreated :: AccountId -> UserId -> AccountType -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
acctCreated accId owner ty =
  globalEvent
    (unAccountId accId)
    0
    ( AccountCreatedEvent
        AccountCreated
          { name = "acc",
            initialBalance = unsafeMoney USD 0,
            by = owner,
            accountType = ty,
            overdraftLimit = Nothing
          }
    )

-- in the spec tree
  describe "countRegularAccounts" $ do
    it "counts regular accounts and excludes External" $ do
      env <-
        seedGlobals
          applyAccountEvent
          [ acctCreated (mockAccountId (UUID.fromWords 1 0 0 0)) (user 1) (Regular defaultCash) 0,
            acctCreated (mockAccountId (UUID.fromWords 2 0 0 0)) (user 1) (Regular defaultCash) 1,
            acctCreated (mockAccountId (UUID.fromWords 3 0 0 0)) (user 1) External 2
          ]
      runDbIn env countRegularAccounts `shouldReturn` 2
```

Note: `AccountSubtype`'s regular constructor is `Cash CashProperties` (takes an argument) — use the exported `defaultCash :: AccountSubtype` rather than a bare `Cash`. Reuse existing `mockAccountId` / `mockUserId` / `unsafeMoney` / `USD` from `Testkit.Helpers` — do not invent new ones.

- [ ] **Step 2: Run it, verify it fails** (`countRegularAccounts` not in scope).

Run: `cabal test all --test-option='--match' --test-option='/countRegularAccounts/'`
Expected: build failure — not in scope.

- [ ] **Step 3: Implement.** In `src/Application/ReadModels/Account.hs`: add `countRegularAccounts` **and** `applyAccountEvent` to the export list (`applyAccountEvent` is currently *not* exported — the test needs it, matching `applyUserEvent`/`applyTransactionEvent` in the sibling read models); add `count` and `(!=.)` to the `Database.Persist (...)` import (currently only `Filter`/`(<-.)`/`(==.)`); add:

```haskell
-- | Total number of regular (non-'External') accounts. Backs the
-- @accounts@ business metric. Filters in SQL: the 'AccountType'
-- 'PersistField' encoding makes every @Regular _@ value compare unequal to
-- 'External'. (@getRegularAccounts@ filters in Haskell via
-- @accountTypeSubtypeKind@, which is not usable inside a persistent @count@;
-- this expresses the equivalent condition at the SQL level. @accountType@ is
-- not indexed, so this is a full-table COUNT — trivial at self-hoster scale.)
countRegularAccounts :: (MonadIO m) => SqlPersistT m Int
countRegularAccounts = count [AccountEntityAccountType !=. External]
```

- [ ] **Step 4: Run the test, verify it passes.**

Run: `cabal test all --test-option='--match' --test-option='/countRegularAccounts/'`
Expected: PASS (result is 2 — External excluded).

- [ ] **Step 5: Commit.**

```bash
git add src/Application/ReadModels/Account.hs test/Application/ReadModels/PersistentAccountReadModelSpec.hs
git commit -m "feat(readmodel): countRegularAccounts total query for accounts metric"
```

---

## Task 3: Lock `countTransactions` business-metric semantic

`countTransactions` already exists; this task only adds a test pinning the semantic the metric relies on (all rows count, including cancelled/failed).

**Files:**
- Test: `test/Application/ReadModels/PersistentTransactionReadModelSpec.hs`

- [ ] **Step 1: Write the failing/execution test.** Reusing that spec's existing builders (`postingInitiatedGlobal` from `Testkit.TransactionEvents`, and its cancellation/terminal edit builder), seed several transactions including one later cancelled, then assert `countTransactions` counts them all. Add `countTransactions` to the `Application.ReadModels.Transaction` import if not present. Example shape:

```haskell
  describe "countTransactions (business-metric semantic)" $ do
    it "counts all transaction rows, including cancelled/failed" $ do
      env <- seedEnv [ <postingInitiated tx1>, <postingInitiated tx2>, <cancellation of tx2> ]
      runDbIn env countTransactions `shouldReturn` 2
```

Fill `<...>` using the spec's existing helper functions (match their exact names/params already used elsewhere in the file). If the spec has no cancellation builder, use two `postingInitiatedGlobal` transactions and assert `2` — the key assertion is "a terminal event does not remove the row."

- [ ] **Step 2: Run it.**

Run: `cabal test all --test-option='--match' --test-option='/countTransactions (business-metric semantic)/'`
Expected: PASS (no src change needed — this documents/locks existing behavior). If it does not compile, fix the helper names to match the file's conventions.

- [ ] **Step 3: Commit.**

```bash
git add test/Application/ReadModels/PersistentTransactionReadModelSpec.hs
git commit -m "test(readmodel): lock countTransactions counts all rows incl cancelled"
```

---

## Task 4: Scrape-time gauge collector in `Infrastructure.Observability.Metrics`

**Files:**
- Modify: `src/Infrastructure/Observability/Metrics.hs` (extend, don't replace)
- Test: `test/Infrastructure/Observability/MetricsSpec.hs` (add examples)

Design: extend the *existing* operator-metrics module with a **generic** scrape-time gauge collector — no "business" naming in infra. `GaugeSample` is abstract (no exported constructor/selectors — honors project rule). Expose a smart constructor `gaugeSample`, the pure `toSampleGroups` (the unit-tested surface), and the thin `registerGaugeCollector`. The pure function is tested directly so the process-global registry is never touched in tests (avoids the shared-registry leakage the module's own `MetricsSpec` note warns about).

- [ ] **Step 1: Write the failing test.** In `test/Infrastructure/Observability/MetricsSpec.hs`, extend the `Infrastructure.Observability.Metrics` import with `gaugeSample, toSampleGroups`, add `Info (..), Sample (..), SampleGroup (..), SampleType (..)` to the `Prometheus` import, and add these examples to the spec tree:

```haskell
  describe "scrape-time gauge collector" $ do
    it "renders each gauge sample as a gauge-typed sample group" $ do
      let groups = toSampleGroups [gaugeSample "users" "Users ever registered" 3]
      case groups of
        [SampleGroup (Info n h) ty [Sample sn _ v]] -> do
          n `shouldBe` "users"
          h `shouldBe` "Users ever registered"
          ty `shouldBe` GaugeType
          sn `shouldBe` "users"
          v `shouldBe` "3" -- decimal-encoded value bytes
        other -> expectationFailure ("unexpected shape: " <> show other)

    it "preserves order and encodes each Int64 value as decimal bytes" $ do
      let groups =
            toSampleGroups
              [ gaugeSample "users" "u" 0,
                gaugeSample "accounts" "a" 42
              ]
      [n | SampleGroup (Info n _) _ _ <- groups] `shouldBe` ["users", "accounts"]
      [v | SampleGroup _ _ [Sample _ _ v] <- groups] `shouldBe` ["0", "42"]
```

(If `SampleType`/`Sample` lack `Eq`, compare via `show`. The reviewer confirmed `SampleGroup`, `Sample`, `Info`, `SampleType`, `GaugeType` are exported from the top-level `Prometheus` module in `prometheus-client` 1.1.)

- [ ] **Step 2: Run it, verify it fails** (`gaugeSample`/`toSampleGroups` not in scope).

Run: `cabal test all --test-option='--match' --test-option='/scrape-time gauge collector/'`
Expected: build failure — not in scope.

- [ ] **Step 3: Implement.** In `src/Infrastructure/Observability/Metrics.hs`: extend the export list with `GaugeSample, gaugeSample, toSampleGroups, registerGaugeCollector`; add `Metric (..), Sample (..), SampleGroup (..), SampleType (..)` to the `Prometheus` import and `import qualified Data.ByteString.Char8 as BS8`; append:

```haskell
-- -----------------------------------------------------------------------------
-- Scrape-time gauge collector
--
-- A generic, computed-at-scrape counter (as opposed to the imperatively-bumped
-- handles in 'Metrics' above): the value is produced by a fetch action each time
-- Prometheus scrapes. The concrete series and their meaning (e.g. the business
-- @users@ / @accounts@ / @transactions@ totals) are decided by
-- the caller in the composition root; this module stays metric-generic and
-- Application-agnostic (the fetch is injected, so no 'Application.*' import).
-- -----------------------------------------------------------------------------

-- | One scrape-time counter to expose: a Prometheus name, help text, and current
-- value. Abstract — construct via 'gaugeSample'.
data GaugeSample = GaugeSample
  { name :: !Text,
    help :: !Text,
    value :: !Int64
  }

-- | Build a 'GaugeSample'. @name@ is the full Prometheus series name
-- (e.g. @"users"@).
gaugeSample :: Text -> Text -> Int64 -> GaugeSample
gaugeSample = GaugeSample

-- | Render gauge samples as gauge-typed Prometheus sample groups. Pure and
-- order-preserving; this is the unit-tested surface.
toSampleGroups :: [GaugeSample] -> [SampleGroup]
toSampleGroups = map render
  where
    render m =
      SampleGroup
        (Info m.name m.help)
        GaugeType
        [Sample m.name [] (BS8.pack (show m.value))]

-- | Register a scrape-time collector that runs @fetch@ on every scrape and emits
-- the resulting counters. Registers once into the process-global registry
-- (mirrors 'registerMetrics'); call exactly once at startup.
registerGaugeCollector :: IO [GaugeSample] -> IO ()
registerGaugeCollector fetch =
  void $ register $ Metric $ pure ((), toSampleGroups <$> fetch)
```

Verify the exact `Metric` shape against the pinned `prometheus-client` (reviewer: `newtype Metric s = Metric { construct :: IO (s, IO [SampleGroup]) }`). If the field/constructor differs, adjust the `register $ Metric ...` line only — the pure `toSampleGroups` is unaffected. Note the module's existing `import RIO hiding (Vector)` already covers `Text`/`Int64`/`void`.

- [ ] **Step 4: Run the test, verify it passes.**

Run: `cabal test all --test-option='--match' --test-option='/scrape-time gauge collector/'`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add src/Infrastructure/Observability/Metrics.hs test/Infrastructure/Observability/MetricsSpec.hs
git commit -m "feat(observability): generic scrape-time gauge collector in Metrics"
```

---

## Task 5: Wire the collector into `app/Main.hs`

**Files:**
- Modify: `app/Main.hs` (imports + one registration block near the metrics/read-model setup, after `pool` and `initializePersistentReadModels`)

- [ ] **Step 1: Add imports.** In `app/Main.hs`, import the query helpers and the collector:

```haskell
import Application.ReadModels.User (countUsers)
import Application.ReadModels.Account (countRegularAccounts)
import Application.ReadModels.Transaction (countTransactions)
import Infrastructure.Observability.Metrics (gaugeSample, registerGaugeCollector)
import Infrastructure.Database (runDbDirect)
```

(Some of these modules may already be imported — extend the existing import rather than duplicating. `runDbDirect` lives in `Infrastructure.Database`, `src/Infrastructure/Database.hs:299`.)

- [ ] **Step 2: Register the collector.** After `initializePersistentReadModels pool sqlGlobalReader` (Main.hs ~line 293), add:

```haskell
  -- Business metrics: scrape-time COUNT(*) on the read-model tables, exposed as
  -- counters on /metrics. Wrapped so a DB error drops only the business series,
  -- never the operator metrics on the same exposition path.
  logInfo "Registering business metrics collector..."
  baseLogFunc <- view logFuncL
  liftIO
    $ registerGaugeCollector
    $ handleAny (\e -> runRIO baseLogFunc (logWarn ("business-metrics fetch failed: " <> displayShow e)) >> pure [])
    $ runDbDirect pool
    $ do
      u <- countUsers
      a <- countRegularAccounts
      t <- countTransactions
      pure
        [ gaugeSample "users" "Users ever registered" (fromIntegral u),
          gaugeSample "accounts" "Regular accounts ever created" (fromIntegral a),
          gaugeSample "transactions" "Transactions ever recorded" (fromIntegral t)
        ]
```

**Logging note (important):** the `handleAny` lambda runs later, at *scrape time*, in a bare `IO` closure with no `HasLogFunc` reader — so `logWarn`/`logInfo` do **not** work there directly (`logGenericIO`/`logWarnIO` do not exist in this codebase). Capture the base `LogFunc` first (`baseLogFunc <- view logFuncL`, available because this block runs inside `runRIO baseLogFunc` in `runApp`) and log via `runRIO baseLogFunc (logWarn …)` — the exact pattern used at `src/Application/Services/ExchangeRatePublisher.hs:153`. The outer `logInfo "Registering…"` is fine as-is (it has the reader context). Use `handleAny`/`catchAny` from `RIO`/`UnliftIO.Exception`. The critical property: **the fetch must never throw into the collector** — on error it returns `[]` so only the business series drop for that scrape. Compile cleanly under `-Werror`.

- [ ] **Step 3: Build.**

Run: `just build`
Expected: clean build, no warnings (`-fci`/`-Werror`).

- [ ] **Step 4: Verify end-to-end** with `@superpowers:verification-before-completion` — the `/metrics` output must include the three counter series. Start Postgres + app and scrape:

Run:
```bash
just docker-up
CONFIG_PATH=config/test.yaml cabal run backend &   # or: just run
sleep 5
curl -s localhost:PORT/metrics | grep -E '^(# (TYPE|HELP) )?(users|accounts|transactions)_total'
```
Expected: each of `users`, `accounts`, `transactions` appears with `# TYPE <name> counter` and a numeric value (0 on an empty DB). Confirm the port from `config/test.yaml`. Stop the app afterward.

- [ ] **Step 5: Commit.**

```bash
git add app/Main.hs
git commit -m "feat(observability): expose users/accounts/transactions on /metrics"
```

---

## Task 6: Full verification pass

- [ ] **Step 1: Rebuild clean** (warm `.o` cache can mask `-Werror`):

Run: `just rebuild`
Expected: success, zero warnings.

- [ ] **Step 2: Full test suite.**

Run: `just test`
Expected: green. (Full `cabal test all` needs a manually-created `eventium_test` Postgres DB; the ~28 environmental failures from its absence are pre-existing and unrelated — see project memory. The new specs use the in-memory SQLite harness and must pass regardless.)

- [ ] **Step 3: Lint + format.**

Run: `just check`
Expected: clean (ormolu + hlint).

- [ ] **Step 4: Confirm no stray backward-compat concerns.** Sanity-check the diff is purely additive: no stored-event shape change, no schema migration, no read-model reset change. `git diff --stat master...HEAD` should show only the six files above.

---

## Task 7: Grafana dashboard (cross-repo: `../fire-console`, infra#8)

The Grafana stack lives in the **separate** `homeaccounting/infra` repo (`../fire-console`, branch `feat/observability-stack`). Dashboards are provisioned from `observability/grafana/dashboards/*.json` (auto-loaded — `provisioning/dashboards/dashboards.yaml` globs the folder; no registration step). Add a "Business" dashboard alongside the existing `events.json` / `http.json` / `logs.json` / `runtime.json`.

**Files:**
- Create: `../fire-console/observability/grafana/dashboards/business.json`

- [ ] **Step 1: Create the dashboard.** Since these series are absolute cumulative totals, use `stat` panels showing the current value (`lastNotNull`) plus a growth timeseries — not `rate()`. Match the existing dashboards' format (`schemaVersion: 39`, datasource uid `prometheus`, tags `homeaccounting`/`product`):

```json
{
  "uid": "ha-business",
  "title": "HomeAccounting — Business",
  "tags": ["homeaccounting", "product"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "refresh": "30s",
  "time": { "from": "now-30d", "to": "now" },
  "templating": { "list": [] },
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Users (total)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" },
      "targets": [ { "refId": "A", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "users", "legendFormat": "users" } ]
    },
    {
      "id": 2, "type": "stat", "title": "Accounts (total, regular)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 6, "w": 6, "x": 6, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" },
      "targets": [ { "refId": "A", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "accounts", "legendFormat": "accounts" } ]
    },
    {
      "id": 3, "type": "stat", "title": "Transactions (total)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 6, "w": 6, "x": 12, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area" },
      "targets": [ { "refId": "A", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "transactions", "legendFormat": "transactions" } ]
    },
    {
      "id": 4, "type": "stat", "title": "Accounts per user (avg)",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 6, "w": 6, "x": 18, "y": 0 },
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 2 }, "overrides": [] },
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "none" },
      "targets": [ { "refId": "A", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "accounts / clamp_min(users, 1)", "legendFormat": "accounts/user" } ]
    },
    {
      "id": 5, "type": "timeseries", "title": "Growth over time",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "gridPos": { "h": 9, "w": 24, "x": 0, "y": 6 },
      "fieldConfig": { "defaults": { "unit": "short" }, "overrides": [] },
      "targets": [
        { "refId": "A", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "users", "legendFormat": "users" },
        { "refId": "B", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "accounts", "legendFormat": "accounts" },
        { "refId": "C", "datasource": { "type": "prometheus", "uid": "prometheus" }, "expr": "transactions", "legendFormat": "transactions" }
      ]
    }
  ]
}
```

`clamp_min(users, 1)` avoids divide-by-zero on a fresh instance.

- [ ] **Step 2: Validate JSON.**

Run: `python3 -m json.tool ../fire-console/observability/grafana/dashboards/business.json > /dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: (Optional) Verify in Grafana** if the stack is running locally. From `../fire-console`, bring the stack up per its `justfile`, scrape the backend (Task 5), and confirm the "HomeAccounting — Business" dashboard shows the three stats. Provisioning reloads every 30s (`updateIntervalSeconds: 30`) — no restart needed.

- [ ] **Step 4: Commit (in the `fire-console` repo, on its `feat/observability-stack` branch).**

```bash
git -C ../fire-console add observability/grafana/dashboards/business.json
git -C ../fire-console commit -m "feat(grafana): business metrics dashboard (users/accounts/transactions totals)"
```

Note: this commit lands in the **infra** repo (infra#8), not the backend repo — keep the two changes on their respective branches/PRs.

---

## Out of scope (do not build)

- No `business_metrics` table / projection / backfill (deferred until hard-deletion exists — see spec's deletion-caveat trigger).
- No per-user labels (cardinality; use Grafana ratios).
- No admin JSON endpoint.
