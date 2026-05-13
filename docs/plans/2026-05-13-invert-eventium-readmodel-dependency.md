# Invert Eventium ↔ Read-Model Dependency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all `Application.ReadModels.*` imports from `Infrastructure.Eventium` by introducing an abstract `AccountingEventHandlers` bundle and wiring the concrete implementations at the composition root.

**Architecture:** Define `AccountingEventHandlers` (a record of `EventHandler IO [GlobalStreamEvent AccountingEvent]` values) in `Infrastructure.Eventium` — it only references Domain and Eventium types, so no Application import is needed. Move `ReadModels` and its construction to a new `Application.EventDispatch` module, which implements `fromReadModels :: ReadModels -> AccountingEventHandlers`. `Main.hs` and the test harness build the bundle and pass it into Infrastructure via the new `replayWith` / `createReadModelHandlersFrom` API.

**Tech Stack:** Haskell / GHC 9.10.3, Cabal (via `just build` which runs `hpack` first), RIO, Eventium, STM. All commands run inside `nix develop`.

---

## File Map

| File | Status | Responsibility after change |
|------|--------|-----------------------------|
| `src/Infrastructure/Eventium.hs` | **Modify** | Defines `AccountingEventHandlers`; exposes `replayWith` and `createReadModelHandlersFrom`; zero `Application.*` imports |
| `src/Application/EventDispatch.hs` | **Create** | Owns `ReadModels`, `createReadModels`, `fromReadModels` — the only place that names concrete read-model types |
| `app/Main.hs` | **Modify** | Import `ReadModels` / `createReadModels` / `fromReadModels` from `Application.EventDispatch`; use new Eventium API |
| `test/Testkit/InMemoryEventStore.hs` | **Modify** | Same swap as `Main.hs`; remove orphaned `createExchangeRateReadModel` call |

---

## Task 1: Establish a green baseline

**Files:** (read-only)

- [ ] **Step 1: Run the test suite**

```bash
nix develop --command just test
```

Expected: all tests pass. If any are already failing, note them — they are pre-existing and not caused by this refactor.

- [ ] **Step 2: Confirm the build is clean**

```bash
nix develop --command just build
```

Expected: zero errors, zero warnings (or the same warnings that exist before this change).

---

## Task 2: Add `AccountingEventHandlers` to `Infrastructure.Eventium`

The type lives here because it is the _interface_ Infrastructure requires. It references only `GlobalStreamEvent AccountingEvent` (Domain + Eventium), so no Application imports are needed.

**Files:**
- Modify: `src/Infrastructure/Eventium.hs`

- [ ] **Step 1: Add `AccountingEventHandlers` type and the two new functions**

In `src/Infrastructure/Eventium.hs`, make the following changes:

**a) Add to the export list** (after `ReadModels (..)` / before utilities):

```haskell
    -- * Event Handler Bundle
    AccountingReadModelHandler,
    AccountingEventHandlers (..),
    createReadModelHandlersFrom,
    replayWith,
```

**b) Add the type and functions** after the existing `Read Models` section (keep `createReadModelHandlers` and `replayReadModels` for now — they'll be deleted in Task 6 once everything compiles):

```haskell
-- | Batch event handler for one accounting read-model context.
--
-- Wraps a function @[GlobalStreamEvent AccountingEvent] -> IO ()@: the list
-- allows read models to do a single STM write covering all events in a replay
-- pass, rather than N individual writes.
type AccountingReadModelHandler = EventHandler IO [GlobalStreamEvent AccountingEvent]

-- | Abstract bundle of per-context batch event handlers.
--
-- The bundle is constructed at the composition root via
-- @Application.EventDispatch.fromReadModels@ and passed into Infrastructure;
-- Infrastructure never imports the concrete read-model modules.
data AccountingEventHandlers = AccountingEventHandlers
  { onAccount :: AccountingReadModelHandler,
    onTransaction :: AccountingReadModelHandler,
    onUser :: AccountingReadModelHandler,
    onConfiguration :: AccountingReadModelHandler,
    onBankImport :: AccountingReadModelHandler,
    onExchangeRate :: AccountingReadModelHandler
  }

-- | Build a list of per-event bus handlers from an 'AccountingEventHandlers'
-- bundle.
--
-- Adapts each single 'VersionedStreamEvent' from the real-time event bus into
-- the @[GlobalStreamEvent]@ batch shape expected by read models, then delegates
-- to the appropriate bundle field.
createReadModelHandlersFrom ::
  (MonadIO m) =>
  AccountingEventHandlers ->
  [AccountingEventHandler m]
createReadModelHandlersFrom handlers =
  let mkHandler batchHandler = EventHandler $ \versionedEvent -> do
        let globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
        liftIO $ handleEvent batchHandler [globalEvent]
   in [ mkHandler handlers.onAccount,
        mkHandler handlers.onTransaction,
        mkHandler handlers.onUser,
        mkHandler handlers.onConfiguration,
        mkHandler handlers.onBankImport,
        mkHandler handlers.onExchangeRate
      ]

-- | Replay all historical global events through an 'AccountingEventHandlers'
-- bundle and return the event count.
--
-- Must be called before the server starts so that in-memory read models are
-- fully populated from persisted history.
replayWith ::
  (MonadIO m) =>
  AccountingGlobalEventStoreReader m ->
  AccountingEventHandlers ->
  m Int
replayWith globalReader handlers = do
  events <- readEvents globalReader (allEvents ())
  liftIO $ handleEvent handlers.onAccount events
  liftIO $ handleEvent handlers.onTransaction events
  liftIO $ handleEvent handlers.onUser events
  liftIO $ handleEvent handlers.onConfiguration events
  liftIO $ handleEvent handlers.onBankImport events
  liftIO $ handleEvent handlers.onExchangeRate events
  pure (length events)
```

`AccountingEventHandlers` uses `EventHandler` and `GlobalStreamEvent` which are already in the existing `Eventium` import — no new imports required. `handleEvent` is the record accessor on `EventHandler`; it is already in scope via `EventHandler (..)`.

- [ ] **Step 2: Verify the module compiles**

```bash
nix develop --command just build 2>&1 | head -40
```

Expected: compiles (old `createReadModelHandlers` / `replayReadModels` still present — that's fine).

---

## Task 3: Create `Application.EventDispatch`

This is the only module that knows about concrete read-model types and their handler functions.

**Files:**
- Create: `src/Application/EventDispatch.hs`

- [ ] **Step 1: Write the new module**

The library uses `source-dirs: src` in `package.yaml` (no explicit module list), so Hpack will auto-discover this file. Run `just build` (which runs `hpack` first) — do not use `cabal build` directly for this task.

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.EventDispatch
-- Description : Read-model registry and event-handler bundle construction
--
-- Owns 'ReadModels' and provides 'fromReadModels' to build an
-- 'AccountingEventHandlers' bundle for 'Infrastructure.Eventium'.
-- This is the only module that imports concrete @Application.ReadModels.*@
-- handler functions; Infrastructure depends only on the abstract bundle type.
module Application.EventDispatch
  ( ReadModels (..),
    createReadModels,
    fromReadModels,
  )
where

import Application.ReadModels.Account
  ( AccountReadModel,
    createAccountReadModel,
    handleAccountEvents,
  )
import Application.ReadModels.BankImportReadModel
  ( BankImportReadModel,
    createBankImportReadModel,
    handleBankImportEvents,
  )
import Application.ReadModels.Configuration
  ( ConfigurationReadModel,
    createConfigurationReadModel,
    handleConfigurationEvents,
  )
import Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel,
    createExchangeRateReadModel,
    handleExchangeRateEvents,
  )
import Application.ReadModels.Transaction
  ( TransactionReadModel,
    createTransactionReadModel,
    handleTransactionEvents,
  )
import Application.ReadModels.User
  ( UserReadModel,
    createUserReadModel,
    handleUserEvents,
  )
import Eventium (EventHandler (..))
import Infrastructure.Eventium (AccountingEventHandlers (..))
import RIO

-- | Combined in-memory read-model state for all bounded contexts.
data ReadModels = ReadModels
  { account :: TVar AccountReadModel,
    transaction :: TVar TransactionReadModel,
    user :: TVar UserReadModel,
    configuration :: TVar ConfigurationReadModel,
    bankImport :: TVar BankImportReadModel,
    exchangeRate :: TVar ExchangeRateReadModel
  }

-- | Allocate fresh TVars for every read model.
createReadModels :: (MonadIO m) => m ReadModels
createReadModels = do
  accountRM <- createAccountReadModel
  transactionRM <- createTransactionReadModel
  userRM <- createUserReadModel
  configRM <- createConfigurationReadModel
  bankImportRM <- createBankImportReadModel
  exchangeRateRM <- createExchangeRateReadModel
  pure
    ReadModels
      { account = accountRM,
        transaction = transactionRM,
        user = userRM,
        configuration = configRM,
        bankImport = bankImportRM,
        exchangeRate = exchangeRateRM
      }

-- | Build an 'AccountingEventHandlers' bundle from concrete read-model TVars.
--
-- Wraps each @handle*Events@ function in 'EventHandler'. GHC infers the
-- field type (@AccountingReadModelHandler@) from the 'AccountingEventHandlers'
-- record declaration, specialising @m@ to @IO@.
fromReadModels :: ReadModels -> AccountingEventHandlers
fromReadModels rms =
  AccountingEventHandlers
    { onAccount = EventHandler $ \es -> handleAccountEvents rms.account es,
      onTransaction = EventHandler $ \es -> handleTransactionEvents rms.transaction es,
      onUser = EventHandler $ \es -> handleUserEvents rms.user es,
      onConfiguration = EventHandler $ \es -> handleConfigurationEvents rms.configuration es,
      onBankImport = EventHandler $ \es -> handleBankImportEvents rms.bankImport es,
      onExchangeRate = EventHandler $ \es -> handleExchangeRateEvents rms.exchangeRate es
    }
```

- [ ] **Step 2: Verify the new module compiles**

```bash
nix develop --command just build 2>&1 | head -40
```

Expected: no errors. (`just build` runs `hpack` before `cabal build`, picking up the new module.)

---

## Task 4: Update `app/Main.hs`

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Swap imports**

Replace the current `Infrastructure.Eventium` import block in `Main.hs`:

```haskell
import Infrastructure.Eventium
  ( ReadModels (..),
    accountingEventStoreWriter,
    accountingGlobalEventStoreReader,
    accountingVersionedEventStoreReader,
    createReadModelHandlers,
    liftGlobalReader,
    liftIOEventHandler,
    liftTaggedWriter,
    liftVersionedReader,
    replayReadModels,
  )
```

with:

```haskell
import Application.EventDispatch
  ( ReadModels (..),
    createReadModels,
    fromReadModels,
  )
import Infrastructure.Eventium
  ( accountingEventStoreWriter,
    accountingGlobalEventStoreReader,
    accountingVersionedEventStoreReader,
    createReadModelHandlersFrom,
    liftGlobalReader,
    liftIOEventHandler,
    liftTaggedWriter,
    liftVersionedReader,
    replayWith,
  )
```

- [ ] **Step 2: Update `initializeEnvironment`**

Replace the block:

```haskell
  -- 3. Initialize read models (must happen before creating the writer)
  logInfo "Initializing read models..."
  (readModels, readModelHandlers) <- liftIO createReadModelHandlers
  logInfo "Read models initialized"
```

with:

```haskell
  -- 3. Initialize read models (must happen before creating the writer)
  logInfo "Initializing read models..."
  readModels <- liftIO createReadModels
  let handlers = fromReadModels readModels
      readModelHandlers = createReadModelHandlersFrom handlers
  logInfo "Read models initialized"
```

Replace:

```haskell
  eventCount <- liftIO $ replayReadModels globalReader readModels
```

with:

```haskell
  eventCount <- liftIO $ replayWith globalReader handlers
```

- [ ] **Step 3: Build and verify**

```bash
nix develop --command just build 2>&1 | head -40
```

Expected: compiles cleanly.

---

## Task 5: Update `test/Testkit/InMemoryEventStore.hs`

**Files:**
- Modify: `test/Testkit/InMemoryEventStore.hs`

- [ ] **Step 1: Swap imports**

The test file (around lines 39-81) has two imports to change:

**a)** Replace the standalone `Application.ReadModels.ExchangeRate` import (line ~39) and the following `User ()` line:

```haskell
import Application.ReadModels.ExchangeRate (createExchangeRateReadModel)
import Application.ReadModels.User ()
```

with:

```haskell
import Application.EventDispatch (ReadModels (..), createReadModels, fromReadModels)
import Application.ReadModels.User ()
```

**b)** Replace the `Infrastructure.Eventium` import block (lines ~73-81):

```haskell
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
    ReadModels (..),
    commandDispatcher,
    createReadModelHandlers,
  )
```

with:

```haskell
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
    commandDispatcher,
    createReadModelHandlersFrom,
  )
```

- [ ] **Step 2: Update `mkAppEnv`**

Replace:

```haskell
  (readModels, readModelHandlers) <- createReadModelHandlers
```

with:

```haskell
  readModels <- createReadModels
  let handlers = fromReadModels readModels
      readModelHandlers = createReadModelHandlersFrom handlers
```

Delete the standalone line:

```haskell
  exchangeRateRM <- createExchangeRateReadModel
```

Replace:

```haskell
        exchangeRateReadModel = exchangeRateRM,
```

with:

```haskell
        exchangeRateReadModel = readModels.exchangeRate,
```

- [ ] **Step 3: Build the test suite**

```bash
nix develop --command just build 2>&1 | head -40
```

Expected: compiles.

---

## Task 6: Remove the old API from `Infrastructure.Eventium`

Only do this after Tasks 4 and 5 compile cleanly — this is the deletion step.

**Files:**
- Modify: `src/Infrastructure/Eventium.hs`

- [ ] **Step 1: Remove the six `Application.ReadModels.*` imports**

Delete these lines from the import section:

```haskell
import Application.ReadModels.Account
  ( AccountReadModel,
    createAccountReadModel,
    handleAccountEvents,
  )
import Application.ReadModels.BankImportReadModel
  ( BankImportReadModel,
    createBankImportReadModel,
    handleBankImportEvents,
  )
import Application.ReadModels.Configuration
  ( ConfigurationReadModel,
    createConfigurationReadModel,
    handleConfigurationEvents,
  )
import Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel,
    createExchangeRateReadModel,
    handleExchangeRateEvents,
  )
import Application.ReadModels.Transaction
  ( TransactionReadModel,
    createTransactionReadModel,
    handleTransactionEvents,
  )
import Application.ReadModels.User
  ( UserReadModel,
    createUserReadModel,
    handleUserEvents,
  )
```

- [ ] **Step 2: Remove `ReadModels`, `createReadModelHandlers`, `replayReadModels` from exports and bodies**

In the export list, remove:

```haskell
    -- * Read Models
    ReadModels (..),
    createReadModelHandlers,

    -- * Read Model Replay
    replayReadModels,
```

Delete the `ReadModels` data type, the `createReadModelHandlers` function, and the `replayReadModels` function from the module body.

Also remove the `TVar` import from `Control.Concurrent.STM` if it is no longer used after these deletions (`TVar` was only referenced by `ReadModels`).

- [ ] **Step 3: Full build**

```bash
nix develop --command just build 2>&1 | head -60
```

Expected: zero errors, zero new warnings.

---

## Task 7: Run the full test suite and verify

- [ ] **Step 1: Run all tests**

```bash
nix develop --command just test
```

Expected: same result as Task 1 (all tests that passed before still pass; no new failures).

- [ ] **Step 2: Confirm no downward import from Infrastructure into Application**

```bash
grep "Application\." src/Infrastructure/Eventium.hs
```

Expected: no output.

- [ ] **Step 3: Format and lint**

```bash
nix develop --command just check
```

Expected: no formatting changes, no lint warnings.

- [ ] **Step 4: Commit**

```bash
git add src/Infrastructure/Eventium.hs \
        src/Application/EventDispatch.hs \
        app/Main.hs \
        test/Testkit/InMemoryEventStore.hs
git commit -m "refactor(infra): invert eventium ↔ read-model dependency (#76)

Introduce AccountingEventHandlers bundle in Infrastructure.Eventium so
infra holds only the abstract handler shape (Domain + Eventium types).
Move ReadModels and its wiring into new Application.EventDispatch.
fromReadModels builds the concrete bundle; Main.hs / test harness pass
it to replayWith and createReadModelHandlersFrom at the composition root.
Structural cycle (Infra → App.ReadModels → Infra.App → Infra) is now
impossible by construction."
```

---

## Appendix: What This Unlocks

Before this refactor, any read model that imported `Infrastructure.App` (e.g., to use `AppM` or a `Has*` capability) would recreate the cycle:

```
Infrastructure.Eventium
  → Application.ReadModels.Account
    → Infrastructure.App        (for AppM / HasEventStore)
      → Infrastructure.Eventium ← CYCLE
```

After this refactor, `Infrastructure.Eventium` has zero `Application.*` imports, so the path above cannot close into a cycle. Read models are now free to depend on infrastructure.

### The primary example: `balanceAsOf`

The workaround in #75 (passing the global reader as an explicit argument instead of pulling it from env) can be replaced with the natural signature:

```haskell
-- Application.ReadModels.Account
balanceAsOf ::
  (MonadReader env m, MonadIO m, HasGlobalEventStoreReader env) =>
  TVar AccountReadModel ->
  AccountId ->
  Day ->
  m (Maybe Money)
```

This compiles cleanly now because `Application.ReadModels.Account → Infrastructure.App` is Application → Infrastructure (allowed), and `Infrastructure.Eventium` no longer closes the cycle back.

### General pattern now available

Any `Application.ReadModels.*` function can:

- Use `MonadReader env m` with `Has*` capabilities (`HasDbPool`, `HasEventStore`, etc.)
- Call `AppM` helpers directly (logging, config access)
- Return `AppM a` in its signature

The only constraint is the layering rule: `Application.*` may depend on `Infrastructure.*`, but never the reverse.

### Suggested follow-up

Implement `balanceAsOf` in `Application.ReadModels.Account` as the first function using the unlocked capability, removing the explicit-reader workaround from commit `2d59207`. This serves as the live proof that the cycle is gone.
