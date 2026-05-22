---
status: completed
date: 2026-05-20
spec: docs/specs/2026-05-20-editable-transaction-metadata-design.md
issue: homeaccounting/backend#80
---

# Editable Transaction Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit `description` and business date (`at`) on `Completed` transactions, gated by a per-user `booksClosedThrough` cutoff that also blocks backdated creation into a closed period. Re-point `balanceAsOf` from the leg event's `at` to the transaction aggregate's current `at` so date edits flow into period balances.

**Architecture:** Two new events on the Transaction aggregate (`TransactionDescriptionChanged`, `TransactionDateChanged`) follow the replace-value pattern already established by `TransactionLabelsSet` / `TransactionCategoryChanged`. One new event on the Configuration aggregate (`BooksClosedThroughSet`) carries an advance-only cutoff. `balanceAsOf` is refactored to take a `TransactionId → Maybe UTCTime` lookup so leg events' deprecated `at` is no longer consulted. No event-log rewrites — leg events keep their now-unread `description` / `at` payloads as historical breadcrumb.

**Tech Stack:** Haskell 9.10.3, RIO prelude, Servant, Eventium (event sourcing), PostgreSQL, Hspec + QuickCheck + hspec-discover, `just` task runner, ormolu + hlint via `just check`.

**Branch:** `feat/editable-transaction-metadata` (already created during brainstorming — the spec commit lives here).

**Design reference:** `docs/specs/2026-05-20-editable-transaction-metadata-design.md`. Read the whole spec before starting; the plan is a delivery schedule, the spec is authoritative for semantics. If plan and spec disagree, flag it — do not silently diverge.

**Reference implementation:** The labels / category edit work in commit history (`docs/plans/2026-04-22-transaction-labels.md`) is the closest precedent for the TX-aggregate edit-event shape, the service-layer orchestration, the auth-via-account-access pattern, and the HTTP wiring. Read it before starting Tasks 5–7.

---

## File Map

Files created:

- `test/Domain/Transaction/DescriptionAndDateSpec.hs` — command-handler unit tests + projection-fold tests for the two new TX events.
- `test/Domain/Transaction/DescriptionAndDatePropertySpec.hs` — QuickCheck properties for the replace-value semantics (last-write-wins).
- `test/Domain/Configuration/BooksCloseSpec.hs` — command-handler tests for `CloseBooksThrough` (advance-only; first-time set).
- `test/Application/Services/TransactionMetadataEditSpec.hs` — orchestration tests for `changeTransactionDescription` / `changeTransactionDate`, including books-close gating on date edits.
- `test/Application/Services/BooksCloseServiceSpec.hs` — orchestration tests for `closeBooksThrough` (advance-only at the service edge as well, since the pure handler also checks this — keep both).
- `test/Application/ReadModels/BalanceAsOfJoinSpec.hs` — `balanceAsOf` reflects edited TX `at` (date moved across a month boundary changes the as-of-EOM balance).
- `test/Integration/TransactionMetadataEditIntegrationSpec.hs` — end-to-end create → edit description → edit date → list / get reflects new values → account `balanceAsOf` moves with the edited date.
- `test/Integration/BooksClosePeriodIntegrationSpec.hs` — end-to-end close → reject backdated creation → reject `ChangeTransactionDate` into closed period → advance close → reject rewind → reject edit of a transaction whose current `at` is closed.

Files modified:

- `src/Domain/Core/Errors.hs` — rename `CannotEditTransactionLabelsInCurrentState` → `CannotEditCompletedTransactionMetadata` (same HTTP mapping); add `CannotEditClosedPeriod { current :: UTCTime, attempted :: UTCTime }` and `CannotRewindBooksCloseDate { current :: UTCTime, attempted :: UTCTime }`.
- `src/Web/ErrorMapping.hs` — update the renamed constructor; add 409 mappings for the two new errors.
- `src/Domain/Transaction/Events.hs` — add `TransactionDescriptionChanged`, `TransactionDateChanged`; register in `transactionEvents`; derive JSON.
- `src/Domain/Transaction/Commands.hs` — add `ChangeTransactionDescription`, `ChangeTransactionDate`; register in `transactionCommands`; derive JSON.
- `src/Domain/Transaction/CommandHandler.hs` — accept the new commands only in `Completed`; otherwise return `CannotEditCompletedTransactionMetadata`. Description has no further domain pre-condition (length/non-empty enforced at the web edge as it is for creation). Date has no further domain pre-condition (books-close is enforced at the service layer).
- `src/Domain/Transaction/Projection.hs` — add `at :: UTCTime` to `Transaction`; initialise from `TransferInitiated.at` (already on the event); fold `TransactionDescriptionChanged` → replace `description`; fold `TransactionDateChanged` → replace `at`; extend `transactionDefault`.
- `src/Domain/Configuration/Events.hs` — add `BooksClosedThroughSet`; register in `configurationEvents`; derive JSON.
- `src/Domain/Configuration/Commands.hs` — add `CloseBooksThrough`; register in `configurationCommands`; derive JSON.
- `src/Domain/Configuration/CommandHandler.hs` — handle `CloseBooksThrough`: rewind attempt returns `CannotRewindBooksCloseDate`; otherwise emit `BooksClosedThroughSet`.
- `src/Domain/Configuration/Projection.hs` — add `booksClosedThrough :: Maybe UTCTime` to `Configuration`; default `Nothing`; fold `BooksClosedThroughSet`.
- `src/Application/ReadModels/Configuration.hs` — surface `booksClosedThrough` in `ConfigurationData`; fold the new event.
- `src/Application/ReadModels/Transaction.hs` — add `at :: UTCTime` to `TransactionData` (already populated from `TransferInitiated.at`, just exposed); fold `TransactionDescriptionChanged` → replace description; fold `TransactionDateChanged` → replace `at`. Also extend `TransactionEvent` pattern handlers in `handleTransactionEvents` if it uses a wildcard today (verify; otherwise add the two arms explicitly).
- `src/Application/ReadModels/Account.hs` — refactor `balanceAsOf` / `foldBalanceAsOf` to take a `TransactionId → Maybe UTCTime` lookup; use TX `at` (via lookup) instead of leg `e.at` when comparing to the cutoff. Add a deprecation note on `AccountDebited` / `AccountCredited` consumption of `description`/`at`. The current-balance fold (`handleAccountReadModelEvents`) is unaffected — it only uses `amount`.
- `src/Application/Services/AccountService.hs` — `balanceAsOf` caller now supplies the lookup (a closure over the transaction read model handle).
- `src/Application/Services/TransactionService.hs` — add `changeTransactionDescription` and `changeTransactionDate` (mirror `setTransactionLabels` / `changeTransactionCategory`). The date path consults the configuration read model and rejects with `CannotEditClosedPeriod` if either the transaction's current `at` or `newAt` falls on or before `booksClosedThrough`. Also gate `initiateIncome` / `initiateExpense` / `initiateInternalTransfer` against backdated creation past the cutoff (same error).
- `src/Application/Services/ConfigurationService.hs` — add `closeBooksThrough`. Even though the pure handler enforces advance-only, also re-check at the service edge to surface a clean error before dispatching the command (matches the labels in-use pattern).
- `src/Web/Types.hs` — add `ChangeTransactionDescriptionRequest`, `ChangeTransactionDateRequest`, `CloseBooksThroughRequest`. Add `booksClosedThrough :: Maybe UTCTime` to `ConfigurationResponse`. `TransactionResponse.description` / `.at` already come from `TransactionData` — no shape change.
- `src/Web/API/TransactionAPI.hs` — wire `PUT /:id/description` and `PUT /:id/date`. Re-use the existing access check / DTO conversion shape from `PUT /:id/labels`.
- `src/Web/API/ConfigurationAPI.hs` — wire `PUT /api/users/me/configuration/books-close`.
- `test/Testkit/Generators.hs` — generators for `UTCTime` near a cutoff (if not already present) and for the new edit commands / events.

Every source edit lands in a commit that ships with its associated tests — the build stays green at every task boundary.

---

## Task 1 — Rename / extend `DomainError`; HTTP mapping

Foundation for everything else: tasks below reference these constructors.

**Files:**
- Modify: `src/Domain/Core/Errors.hs`
- Modify: `src/Web/ErrorMapping.hs`
- Touched: `src/Application/Services/TransactionService.hs` (existing reference to renamed constructor)
- Touched: `src/Domain/Transaction/CommandHandler.hs` (existing reference)

- [ ] **Step 1.1: Rename `CannotEditTransactionLabelsInCurrentState` → `CannotEditCompletedTransactionMetadata`.**

```
sed -n on the file to find both lines, then Edit them. Locations:
  src/Domain/Core/Errors.hs:79   (declaration)
  src/Domain/Core/Errors.hs:155  (errorContext helper case)
  src/Web/ErrorMapping.hs:215    (HTTP mapping)
  src/Application/Services/TransactionService.hs:498
  src/Domain/Transaction/CommandHandler.hs (any reference; verify with grep)
```

- [ ] **Step 1.2: Add `CannotEditClosedPeriod`.**

In `src/Domain/Core/Errors.hs`, after `FeatureDisabled Text`:

```haskell
  | -- | Edit (or backdated creation) would land in a closed period.
    --   @current@ is the user's `booksClosedThrough`; @attempted@ is the
    --   business date that triggered the rejection.
    CannotEditClosedPeriod
      { current :: UTCTime,
        attempted :: UTCTime
      }
```

Extend the `errorContext`/`errorMessage` helper(s) with a matching case. Mirror the shape used by `LabelInUse`/`CategoryInUse` for record-style errors.

- [ ] **Step 1.3: Add `CannotRewindBooksCloseDate`.**

Same shape:

```haskell
  | -- | `CloseBooksThrough` would rewind the cutoff (advance-only rule).
    CannotRewindBooksCloseDate
      { current :: UTCTime,
        attempted :: UTCTime
      }
```

- [ ] **Step 1.4: Wire HTTP mapping.**

In `src/Web/ErrorMapping.hs`:

```haskell
mapDomainError CannotEditCompletedTransactionMetadata =
  -- (existing 409 mapping; only the constructor name changes)
  ...
mapDomainError CannotEditClosedPeriod { current, attempted } =
  ErrorResponse
    { status = status409,
      code = "CANNOT_EDIT_CLOSED_PERIOD",
      message = "Cannot edit a transaction in a closed period",
      details = Just $ object
        [ "current"   .= current,
          "attempted" .= attempted
        ]
    }
mapDomainError CannotRewindBooksCloseDate { current, attempted } =
  ErrorResponse
    { status = status409,
      code = "CANNOT_REWIND_BOOKS_CLOSE",
      message = "Books-close date may only advance",
      details = Just $ object
        [ "current"   .= current,
          "attempted" .= attempted
        ]
    }
```

Match the exact `ErrorResponse` constructor / field names used by surrounding cases; copy the form of a nearby record-bearing error.

- [ ] **Step 1.5: Build green.**

Run: `just build`
Expected: PASS. If any callsite still references the old constructor, fix it inline before committing.

- [ ] **Step 1.6: Commit.**

```bash
git add src/Domain/Core/Errors.hs src/Web/ErrorMapping.hs src/Application/Services/TransactionService.hs src/Domain/Transaction/CommandHandler.hs
git commit -m "refactor(errors): rename and extend DomainError for metadata edits

- CannotEditTransactionLabelsInCurrentState -> CannotEditCompletedTransactionMetadata
- add CannotEditClosedPeriod
- add CannotRewindBooksCloseDate

Refs #80"
```

---

## Task 2 — Books-close on the Configuration aggregate

Pure-domain piece: event + command + projection field + command handler.

**Files:**
- Modify: `src/Domain/Configuration/Events.hs`
- Modify: `src/Domain/Configuration/Commands.hs`
- Modify: `src/Domain/Configuration/Projection.hs`
- Modify: `src/Domain/Configuration/CommandHandler.hs`
- Test: `test/Domain/Configuration/BooksCloseSpec.hs`

- [ ] **Step 2.1: Write the failing command-handler tests.**

Create `test/Domain/Configuration/BooksCloseSpec.hs`:

```haskell
module Domain.Configuration.BooksCloseSpec (spec) where

import RIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Domain.Configuration.CommandHandler (handleConfigurationCommand)
import Domain.Configuration.Commands (CloseBooksThrough (..))
import Domain.Configuration.Events (BooksClosedThroughSet (..))
import Domain.Configuration.Projection (Configuration, configurationDefault)
import Domain.Core.Errors (DomainError (..))
import Test.Hspec

day :: Integer -> Int -> Int -> UTCTime
day y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

spec :: Spec
spec = describe "CloseBooksThrough" $ do
  it "first-time set: emits BooksClosedThroughSet" $ do
    let cmd = CloseBooksThroughConfigurationCommand
                CloseBooksThrough { closedThrough = day 2026 3 31 }
    handleConfigurationCommand configurationDefault cmd
      `shouldBe`
      Right [BooksClosedThroughSetConfigurationEvent
              (BooksClosedThroughSet (day 2026 3 31))]

  it "advance: emits the event" $ do
    let cfg = applyEvent configurationDefault
                (BooksClosedThroughSetConfigurationEvent
                  (BooksClosedThroughSet (day 2026 3 31)))
        cmd = CloseBooksThroughConfigurationCommand
                CloseBooksThrough { closedThrough = day 2026 4 30 }
    handleConfigurationCommand cfg cmd
      `shouldBe`
      Right [BooksClosedThroughSetConfigurationEvent
              (BooksClosedThroughSet (day 2026 4 30))]

  it "rewind: returns CannotRewindBooksCloseDate" $ do
    let cfg = applyEvent configurationDefault
                (BooksClosedThroughSetConfigurationEvent
                  (BooksClosedThroughSet (day 2026 4 30)))
        cmd = CloseBooksThroughConfigurationCommand
                CloseBooksThrough { closedThrough = day 2026 3 31 }
    handleConfigurationCommand cfg cmd
      `shouldBe`
      Left (CannotRewindBooksCloseDate
              { current   = day 2026 4 30,
                attempted = day 2026 3 31
              })

  it "equal: rewind (cutoff must strictly increase)" $ do
    let cfg = applyEvent configurationDefault
                (BooksClosedThroughSetConfigurationEvent
                  (BooksClosedThroughSet (day 2026 4 30)))
        cmd = CloseBooksThroughConfigurationCommand
                CloseBooksThrough { closedThrough = day 2026 4 30 }
    handleConfigurationCommand cfg cmd
      `shouldBe`
      Left (CannotRewindBooksCloseDate
              { current   = day 2026 4 30,
                attempted = day 2026 4 30
              })
```

Use the existing `applyEvent` helper if present in `Testkit`; otherwise import the projection's `handleConfigurationEvent` directly. Match the project's actual sum-type constructor names — verify against existing tests in `test/Domain/Configuration/`.

- [ ] **Step 2.2: Run the test, see it fail at compile time.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Configuration.BooksClose/"`
Expected: COMPILE FAIL — `CloseBooksThrough`, `BooksClosedThroughSet`, `CannotRewindBooksCloseDate` not defined.

- [ ] **Step 2.3: Add the event type.**

In `src/Domain/Configuration/Events.hs`, alongside the existing dictionary events:

```haskell
newtype BooksClosedThroughSet = BooksClosedThroughSet
  { closedThrough :: UTCTime
  }
  deriving (Show, Eq)
```

Add `''BooksClosedThroughSet` to `configurationEvents` and `deriveJSON defaultOptions ''BooksClosedThroughSet`.

- [ ] **Step 2.4: Add the command type.**

In `src/Domain/Configuration/Commands.hs`:

```haskell
newtype CloseBooksThrough = CloseBooksThrough
  { closedThrough :: UTCTime
  }
  deriving (Show, Eq)
```

Add `''CloseBooksThrough` to `configurationCommands` and `deriveJSON defaultOptions ''CloseBooksThrough`.

- [ ] **Step 2.5: Add the projection field and fold.**

In `src/Domain/Configuration/Projection.hs`, extend `Configuration` with `booksClosedThrough :: Maybe UTCTime`; initialise to `Nothing` in `configurationDefault`. Add a fold case:

```haskell
handleConfigurationEvent cfg (BooksClosedThroughSetConfigurationEvent e) =
  cfg & #booksClosedThrough ?~ e.closedThrough
```

(Mirror the optic style used by surrounding cases — `& #field .~ value` vs `?~` depending on whether the field is `Maybe`.)

- [ ] **Step 2.6: Add the command handler arm.**

In `src/Domain/Configuration/CommandHandler.hs`:

```haskell
handleConfigurationCommand cfg (CloseBooksThroughConfigurationCommand c) =
  case cfg ^. #booksClosedThrough of
    Just current | c.closedThrough <= current ->
      Left CannotRewindBooksCloseDate
        { current   = current,
          attempted = c.closedThrough
        }
    _ ->
      Right [ BooksClosedThroughSetConfigurationEvent
                (BooksClosedThroughSet c.closedThrough)
            ]
```

- [ ] **Step 2.7: Run the tests, see them pass.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Configuration.BooksClose/"`
Expected: PASS.

- [ ] **Step 2.8: Run the full Configuration test bucket to confirm no regressions.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Configuration/"`
Expected: PASS.

- [ ] **Step 2.9: `just check`.**

Run: `just check`
Expected: PASS (format + lint clean).

- [ ] **Step 2.10: Commit.**

```bash
git add src/Domain/Configuration/Events.hs src/Domain/Configuration/Commands.hs src/Domain/Configuration/Projection.hs src/Domain/Configuration/CommandHandler.hs test/Domain/Configuration/BooksCloseSpec.hs
git commit -m "feat(configuration): add CloseBooksThrough (advance-only)

Adds the BooksClosedThroughSet event, CloseBooksThrough command, and a
field on the Configuration projection. Used downstream to gate
backdated transaction creation and date edits.

Refs #80"
```

---

## Task 3 — Configuration read model and service for books-close

The read model surfaces `booksClosedThrough`; the service layer adds `closeBooksThrough`.

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs`
- Modify: `src/Application/Services/ConfigurationService.hs`
- Test: `test/Application/Services/BooksCloseServiceSpec.hs`

- [ ] **Step 3.1: Extend `ConfigurationData`.**

Add `booksClosedThrough :: Maybe UTCTime` to `ConfigurationData`; default `Nothing`. Add an event handler:

```haskell
applyConfigurationEvent cfg (BooksClosedThroughSetConfigurationEvent e) =
  cfg { booksClosedThrough = Just e.closedThrough }
```

Match the existing `applyConfigurationEvent` / `handleConfigurationEvents` shape in the file.

- [ ] **Step 3.2: Write the failing service test.**

Create `test/Application/Services/BooksCloseServiceSpec.hs` covering:

- happy path: first-time close emits `BooksClosedThroughSet` against the user's stream and the read model exposes the new value.
- rewind: returns `CannotRewindBooksCloseDate` and emits no event.
- advance: re-issues with a later date, read model reflects the latest.

Use the existing in-memory event store from `Testkit/InMemoryEventStore.hs` and follow the shape of `ConfigurationServiceSpec.hs` for setup.

- [ ] **Step 3.3: Run, see it fail.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.BooksClose/"`
Expected: COMPILE FAIL — `closeBooksThrough` not defined.

- [ ] **Step 3.4: Add the service function.**

In `src/Application/Services/ConfigurationService.hs`:

```haskell
closeBooksThrough ::
  UserId ->
  UTCTime ->
  AppM (Either DomainError ConfigurationData)
closeBooksThrough userId newCutoff = runExceptT $ do
  lift $ logInfo $ "Closing books through " <> displayShow newCutoff
                <> " for user " <> displayShow userId
  cfg <- ExceptT (getConfigurationForUser userId)
  -- Service-edge advance-only check for clean error before dispatch.
  case cfg.booksClosedThrough of
    Just current | newCutoff <= current ->
      throwE (CannotRewindBooksCloseDate
                { current = current, attempted = newCutoff })
    _ -> pure ()
  let cmd =
        CloseBooksThroughConfigurationCommand
          CloseBooksThrough { closedThrough = newCutoff }
  ExceptT (dispatchConfigurationCommand userId cmd)
  ExceptT (getConfigurationForUser userId)
```

Use whatever the existing module names for `dispatchConfigurationCommand` and `getConfigurationForUser` are — copy the shape of an existing command-dispatch service function nearby.

Export `closeBooksThrough` from the module.

- [ ] **Step 3.5: Run, see it pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.BooksClose/"`
Expected: PASS.

- [ ] **Step 3.6: `just check`.**

- [ ] **Step 3.7: Commit.**

```bash
git add src/Application/ReadModels/Configuration.hs src/Application/Services/ConfigurationService.hs test/Application/Services/BooksCloseServiceSpec.hs
git commit -m "feat(configuration): expose booksClosedThrough + closeBooksThrough service

Refs #80"
```

---

## Task 4 — Books-close web endpoint and ConfigurationResponse field

**Files:**
- Modify: `src/Web/Types.hs` (add request DTO; extend `ConfigurationResponse`)
- Modify: `src/Web/API/ConfigurationAPI.hs` (new route)
- Modify: `test/Web/API/ConfigurationAPISpec.hs` if such file exists; otherwise rely on the integration test in Task 9.

- [ ] **Step 4.1: Add request DTO.**

In `src/Web/Types.hs`:

```haskell
newtype CloseBooksThroughRequest = CloseBooksThroughRequest
  { closedThrough :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance FromJSON CloseBooksThroughRequest
instance ToJSON CloseBooksThroughRequest
```

Use whatever JSON-deriving convention matches the rest of the file (it may use `deriveJSON defaultOptions`).

- [ ] **Step 4.2: Extend `ConfigurationResponse`.**

Add `booksClosedThrough :: Maybe UTCTime`; thread it through the existing conversion from `ConfigurationData`.

- [ ] **Step 4.3: Wire the endpoint.**

In `src/Web/API/ConfigurationAPI.hs`:

```haskell
:<|> "books-close"
       :> ReqBody '[JSON] CloseBooksThroughRequest
       :> Put '[JSON] ConfigurationResponse
```

(Inside the existing `users/me/configuration` group.) Handler:

```haskell
closeBooksHandler ::
  UserId ->
  CloseBooksThroughRequest ->
  AppM ConfigurationResponse
closeBooksHandler userId req = do
  result <- ConfigurationService.closeBooksThrough userId req.closedThrough
  toConfigurationResponseOrError result
```

Match the existing handler-shape used by `renameDictionaryEntryHandler` or similar.

- [ ] **Step 4.4: Build green.**

Run: `just build`

- [ ] **Step 4.5: Commit.**

```bash
git add src/Web/Types.hs src/Web/API/ConfigurationAPI.hs
git commit -m "feat(api): PUT /api/users/me/configuration/books-close

Adds the books-close endpoint and exposes booksClosedThrough on
ConfigurationResponse.

Refs #80"
```

---

## Task 5 — TX aggregate: `at` field + description/date edit events and commands

The core domain change for editability.

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Modify: `src/Domain/Transaction/Projection.hs`
- Test: `test/Domain/Transaction/DescriptionAndDateSpec.hs`
- Test: `test/Domain/Transaction/DescriptionAndDatePropertySpec.hs`

- [ ] **Step 5.1: Write the failing command-handler + projection tests.**

Create `test/Domain/Transaction/DescriptionAndDateSpec.hs`. Cover, at minimum:

- Description edit on `Completed` → emits `TransactionDescriptionChanged`; projection replaces `description`.
- Description edit on `Pending` → returns `CannotEditCompletedTransactionMetadata`.
- Description edit on `Failed _` → returns `CannotEditCompletedTransactionMetadata`.
- Date edit on `Completed` → emits `TransactionDateChanged`; projection replaces `at`.
- Date edit on `Pending` / `Failed` → returns `CannotEditCompletedTransactionMetadata`.
- After `TransferInitiated` with `at = t1`, the projection's `at` is `t1`.

Use existing testkit helpers from `test/Testkit/Helpers.hs` for building a Completed transaction (look at `LabelsAndCategorySpec.hs` for the pattern).

- [ ] **Step 5.2: Write the property tests.**

Create `test/Domain/Transaction/DescriptionAndDatePropertySpec.hs`:

```haskell
prop_lastDescriptionWins :: Property
prop_lastDescriptionWins =
  forAll (listOf1 arbitraryText) $ \descs ->
    let events = map (TransactionDescriptionChangedTransactionEvent
                       . TransactionDescriptionChanged anyTxId)
                     descs
        tx = foldl' handleTransactionEvent completedTx events
    in tx.description === last descs

prop_lastDateWins :: Property
-- analogous
```

- [ ] **Step 5.3: Run, see failures.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Transaction.DescriptionAndDate/"`
Expected: COMPILE FAIL.

- [ ] **Step 5.4: Add the events.**

In `src/Domain/Transaction/Events.hs`:

```haskell
data TransactionDescriptionChanged = TransactionDescriptionChanged
  { transactionId  :: TransactionId,
    newDescription :: Text
  }
  deriving (Show, Eq)

data TransactionDateChanged = TransactionDateChanged
  { transactionId :: TransactionId,
    newAt         :: UTCTime
  }
  deriving (Show, Eq)
```

Add both to `transactionEvents`; `deriveJSON defaultOptions` for both.

- [ ] **Step 5.5: Add the commands.**

In `src/Domain/Transaction/Commands.hs`:

```haskell
data ChangeTransactionDescription = ChangeTransactionDescription
  { transactionId  :: TransactionId,
    newDescription :: Text
  }
  deriving (Show, Eq)

data ChangeTransactionDate = ChangeTransactionDate
  { transactionId :: TransactionId,
    newAt         :: UTCTime
  }
  deriving (Show, Eq)
```

Add both to `transactionCommands`; `deriveJSON defaultOptions`.

- [ ] **Step 5.6: Add the `at` field to the projection and the fold rules.**

In `src/Domain/Transaction/Projection.hs`:

```haskell
data Transaction = Transaction
  { ...,
    -- existing fields,
    ...,
    -- | Business time of the transaction. Initialised from
    --   TransferInitiated.at; mutated by TransactionDateChanged.
    at :: UTCTime
  }
```

In `transactionDefault`, initialise `at` to a sentinel like `UTCTime (fromGregorian 1970 1 1) 0`. Pattern after the dummy values already in `transactionDefault`.

In `handleTransactionEvent`:

```haskell
handleTransactionEvent transaction (TransferInitiatedTransactionEvent evt) =
  -- existing body
  ...
    & #at .~ evt.at  -- ← add this line

handleTransactionEvent transaction (TransactionDescriptionChangedTransactionEvent evt) =
  transaction & #description .~ evt.newDescription
handleTransactionEvent transaction (TransactionDateChangedTransactionEvent evt) =
  transaction & #at .~ evt.newAt
```

Note: the existing wildcard for un-handled events should keep working for the two new event types if you don't add explicit arms — but matching the labels/category style, **add explicit arms** so the intent is documented in code.

- [ ] **Step 5.7: Add the command handler arms.**

In `src/Domain/Transaction/CommandHandler.hs`:

```haskell
handleTransactionCommand tx (ChangeTransactionDescriptionTransactionCommand c) =
  case tx ^. #status of
    Completed ->
      Right [ TransactionDescriptionChangedTransactionEvent
                (TransactionDescriptionChanged c.transactionId c.newDescription)
            ]
    _ -> Left CannotEditCompletedTransactionMetadata

handleTransactionCommand tx (ChangeTransactionDateTransactionCommand c) =
  case tx ^. #status of
    Completed ->
      Right [ TransactionDateChangedTransactionEvent
                (TransactionDateChanged c.transactionId c.newAt)
            ]
    _ -> Left CannotEditCompletedTransactionMetadata
```

(Books-close enforcement lives in the service layer — the pure handler stays free of read-model dependencies.)

- [ ] **Step 5.8: Run, see the unit + property tests pass.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Transaction.DescriptionAndDate/"`
Expected: PASS.

- [ ] **Step 5.9: Run all Domain tests.**

Run: `cabal test all --test-option='--match' --test-option="/Domain/"`
Expected: PASS — including existing `LabelsAndCategorySpec` (the rename to `CannotEditCompletedTransactionMetadata` must have been picked up in Task 1; the test should still pass with the renamed constructor).

- [ ] **Step 5.10: `just check`.**

- [ ] **Step 5.11: Commit.**

```bash
git add src/Domain/Transaction/Events.hs src/Domain/Transaction/Commands.hs src/Domain/Transaction/CommandHandler.hs src/Domain/Transaction/Projection.hs test/Domain/Transaction/DescriptionAndDateSpec.hs test/Domain/Transaction/DescriptionAndDatePropertySpec.hs
git commit -m "feat(transactions): description/date edit events and commands

Adds ChangeTransactionDescription / ChangeTransactionDate commands and
their corresponding events, valid only in the Completed state. Extends
the Transaction projection with a top-level 'at' field, initialised
from TransferInitiated.at and mutated by TransactionDateChanged.

Refs #80"
```

---

## Task 6 — Transaction read model handles the new events

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Test: extend `test/Application/ReadModels/...` if there's an existing transaction-read-model spec; otherwise covered transitively by Task 9.

- [ ] **Step 6.1: Add `at :: UTCTime` to `TransactionData`.**

The field is already populated from `TransferInitiated.at` internally — but `TransactionData` may not expose it yet. Verify; if absent, add it.

- [ ] **Step 6.2: Fold the new events.**

In `handleTransactionEvents` (or whatever the per-event handler is named — check the file):

```haskell
applyTxEvent tx (TransactionDescriptionChangedTransactionEvent e) =
  tx { description = e.newDescription }
applyTxEvent tx (TransactionDateChangedTransactionEvent e) =
  tx { at = e.newAt }
```

Match the actual record-update or optic style of the surrounding handlers (the labels / category cases are the closest reference).

- [ ] **Step 6.3: Build green.**

Run: `just build`
Expected: PASS.

- [ ] **Step 6.4: Commit.**

```bash
git add src/Application/ReadModels/Transaction.hs
git commit -m "feat(read-model): apply description/date edits to TransactionData

Refs #80"
```

---

## Task 7 — Transaction service: orchestration for edits and books-close gates

This is the largest task — three orchestration paths plus updates to the three creation paths.

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`
- Test: `test/Application/Services/TransactionMetadataEditSpec.hs`

- [ ] **Step 7.1: Write the failing orchestration tests.**

In `test/Application/Services/TransactionMetadataEditSpec.hs`, cover (using the in-memory event store and the existing `Testkit/Helpers.hs` builders):

- `changeTransactionDescription` happy path: Editor on source/target, transaction Completed → state mutates; read model reflects new description.
- `changeTransactionDescription` rejection: caller has no Editor access → `AccessDenied`.
- `changeTransactionDate` happy path: no books-close set → succeeds.
- `changeTransactionDate` rejection: `newAt` ≤ `booksClosedThrough` → `CannotEditClosedPeriod`.
- `changeTransactionDate` rejection: TX's current `at` ≤ `booksClosedThrough` → `CannotEditClosedPeriod` (even when `newAt` is in the open period).
- `changeTransactionDate` rejection: transaction not `Completed` → `CannotEditCompletedTransactionMetadata`.
- Backdated `initiateExpense` with `at ≤ booksClosedThrough` → `CannotEditClosedPeriod`.

- [ ] **Step 7.2: Run, see them fail.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.TransactionMetadataEdit/"`
Expected: COMPILE FAIL.

- [ ] **Step 7.3: Implement `changeTransactionDescription`.**

Mirror `setTransactionLabels`:

```haskell
changeTransactionDescription ::
  UserId ->
  TransactionId ->
  Text ->
  AppM (Either DomainError TransactionData)
changeTransactionDescription userId transactionId newDescription = runExceptT $ do
  lift $ logInfo $ "Changing description on " <> displayShow transactionId
  _transaction <- ExceptT (ensureEditorAccess userId transactionId)
  let cmd =
        ChangeTransactionDescriptionTransactionCommand
          ChangeTransactionDescription
            { transactionId  = transactionId,
              newDescription = newDescription
            }
  ExceptT (dispatchEdit transactionId cmd)
```

Export.

- [ ] **Step 7.4: Implement `changeTransactionDate`.**

```haskell
changeTransactionDate ::
  UserId ->
  TransactionId ->
  UTCTime ->
  AppM (Either DomainError TransactionData)
changeTransactionDate userId transactionId newAt = runExceptT $ do
  lift $ logInfo $ "Changing date on " <> displayShow transactionId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  cutoff <- ExceptT (booksClosedThroughFor userId)
  let inClosed t = case cutoff of
        Just c  -> t <= c
        Nothing -> False
  when (inClosed transaction.at)
    (throwE (CannotEditClosedPeriod
              { current   = fromMaybe transaction.at cutoff,
                attempted = transaction.at }))
  when (inClosed newAt)
    (throwE (CannotEditClosedPeriod
              { current   = fromMaybe newAt cutoff,
                attempted = newAt }))
  let cmd =
        ChangeTransactionDateTransactionCommand
          ChangeTransactionDate
            { transactionId = transactionId,
              newAt         = newAt
            }
  ExceptT (dispatchEdit transactionId cmd)
```

Add a private helper `booksClosedThroughFor :: UserId -> AppM (Either DomainError (Maybe UTCTime))` that reads from `ConfigurationService.getConfigurationForUser`.

Export `changeTransactionDate`.

- [ ] **Step 7.5: Add the books-close gate to the three creation paths.**

In each of `initiateIncome`, `initiateExpense`, `initiateInternalTransfer`, after the existing validation and before dispatching `InitiateTransfer`:

```haskell
cutoff <- ExceptT (booksClosedThroughFor userId)
case cutoff of
  Just c | at <= c ->
    throwE (CannotEditClosedPeriod { current = c, attempted = at })
  _ -> pure ()
```

Use the same `at` value that's already passed into `InitiateTransfer`. Verify the variable name — it may be `transferDate` or `businessDate` in the existing code. Do not introduce a new parameter.

- [ ] **Step 7.6: Run, see the tests pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.TransactionMetadataEdit/"`
Expected: PASS.

- [ ] **Step 7.7: Run the full Application bucket.**

Run: `cabal test all --test-option='--match' --test-option="/Application/"`
Expected: PASS (existing labels/category service tests must continue to work).

- [ ] **Step 7.8: `just check`.**

- [ ] **Step 7.9: Commit.**

```bash
git add src/Application/Services/TransactionService.hs test/Application/Services/TransactionMetadataEditSpec.hs
git commit -m "feat(transactions): description/date edit services + books-close gate

Adds changeTransactionDescription and changeTransactionDate; the latter
rejects edits affecting a closed period. Backdated creation through
initiateIncome / initiateExpense / initiateInternalTransfer is gated
by the same cutoff.

Refs #80"
```

---

## Task 8 — Web endpoints for description and date edits

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/TransactionAPI.hs`

- [ ] **Step 8.1: Add request DTOs.**

In `src/Web/Types.hs`:

```haskell
newtype ChangeTransactionDescriptionRequest = ChangeTransactionDescriptionRequest
  { description :: Text
  }
  deriving (Show, Eq, Generic)

instance FromJSON ChangeTransactionDescriptionRequest
instance ToJSON ChangeTransactionDescriptionRequest

newtype ChangeTransactionDateRequest = ChangeTransactionDateRequest
  { at :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance FromJSON ChangeTransactionDateRequest
instance ToJSON ChangeTransactionDateRequest
```

Match the surrounding JSON convention.

- [ ] **Step 8.2: Add routes.**

In `src/Web/API/TransactionAPI.hs`, alongside `PUT /:id/labels`:

```haskell
:<|> Capture "txId" UUID
       :> "description"
       :> ReqBody '[JSON] ChangeTransactionDescriptionRequest
       :> Put '[JSON] TransactionResponse
:<|> Capture "txId" UUID
       :> "date"
       :> ReqBody '[JSON] ChangeTransactionDateRequest
       :> Put '[JSON] TransactionResponse
```

(Exact Servant combinator style follows the existing labels/category endpoints — copy structure.)

- [ ] **Step 8.3: Add handlers.**

```haskell
changeDescriptionHandler ::
  UserId ->
  UUID ->
  ChangeTransactionDescriptionRequest ->
  AppM TransactionResponse
changeDescriptionHandler userId rawTxId req = do
  txId <- liftEitherDomain (mkTransactionId rawTxId)
  result <- TransactionService.changeTransactionDescription userId txId req.description
  toTransactionResponseOrError result

changeDateHandler ::
  UserId ->
  UUID ->
  ChangeTransactionDateRequest ->
  AppM TransactionResponse
changeDateHandler userId rawTxId req = do
  txId <- liftEitherDomain (mkTransactionId rawTxId)
  result <- TransactionService.changeTransactionDate userId txId req.at
  toTransactionResponseOrError result
```

Match the existing labels/category handler shape; reuse helpers (`liftEitherDomain`, `toTransactionResponseOrError`) by name even if signatures differ slightly — adopt whatever the surrounding code uses.

- [ ] **Step 8.4: Build green.**

Run: `just build`

- [ ] **Step 8.5: Commit.**

```bash
git add src/Web/Types.hs src/Web/API/TransactionAPI.hs
git commit -m "feat(api): PUT /api/transactions/:id/description and /date

Refs #80"
```

---

## Task 9 — Refactor `balanceAsOf` to join TX `at`

The structural change. The current `foldBalanceAsOf` uses `e.at` from the leg event; the new shape uses a `TransactionId → Maybe UTCTime` lookup so date edits are reflected in historical balances.

**Files:**
- Modify: `src/Application/ReadModels/Account.hs`
- Modify: `src/Application/Services/AccountService.hs` (caller)
- Test: `test/Application/ReadModels/BalanceAsOfJoinSpec.hs`

- [ ] **Step 9.1: Write the failing test.**

`test/Application/ReadModels/BalanceAsOfJoinSpec.hs`:

- Create an account with `initialBalance = 1000`.
- Apply `AccountDebited` with `at = 2026-03-15`, amount = 200, transactionId = T.
- `balanceAsOf 2026-03-31` (with TX-lookup mapping T → 2026-03-15) → 800.
- After "T's date moved to 2026-04-01": `balanceAsOf 2026-03-31` (with lookup T → 2026-04-01) → 1000 (the debit moved out of March).
- `balanceAsOf 2026-04-30` (with lookup T → 2026-04-01) → 800.

The lookup is a pure function for this test (`Map TransactionId UTCTime`).

- [ ] **Step 9.2: Run, see it fail.**

Expected: COMPILE FAIL on the lookup parameter.

- [ ] **Step 9.3: Refactor `foldBalanceAsOf` and `balanceAsOf`.**

New signatures:

```haskell
foldBalanceAsOf ::
  UTCTime ->
  (TransactionId -> Maybe UTCTime) ->
  [AccountingEvent] ->
  Maybe Money

balanceAsOf ::
  (Monad m) =>
  EventStoreReader UUID EventVersion m (VersionedStreamEvent AccountingEvent) ->
  (TransactionId -> Maybe UTCTime) ->
  AccountId ->
  UTCTime ->
  m (Maybe Money)
```

Inside `applyAsOf`, replace `e.at <= cutoff` with:

```haskell
applyAsOf cutoff lookupAt bal (AccountDebitedEvent e)
  | maybe e.at id (lookupAt e.transactionId) <= cutoff =
      case subtractMoney bal e.amount of
        Right newBal -> newBal
        Left _ -> bal
applyAsOf cutoff lookupAt bal (AccountCreditedEvent e)
  | maybe e.at id (lookupAt e.transactionId) <= cutoff =
      case addMoney bal e.amount of
        Right newBal -> newBal
        Left _ -> bal
applyAsOf _ _ bal _ = bal
```

Semantics: prefer the TX-aggregate `at`; fall back to the leg's `at` only when the TX is missing from the lookup (defensive; should not happen in valid streams). Add a Haddock note above the function explaining this.

Add a module-level deprecation comment near `AccountDebited` / `AccountCredited` payload fields in `src/Domain/Account/Events.hs`:

```haskell
-- | DEPRECATED — no longer read by any projection. The authoritative
--   business date lives on the Transaction aggregate (see spec
--   2026-05-20-editable-transaction-metadata-design.md §4). Retained
--   on the event payload to avoid rewriting the event log; will be
--   removed in a later spec.
```

Apply to both `description` and `at` on both leg events.

- [ ] **Step 9.4: Update the `AccountService` caller.**

In `src/Application/Services/AccountService.hs:419`, the existing call to `balanceAsOf reader accountId asOf` needs the new lookup argument. Provide it from the transaction read model:

```haskell
txReadModel <- view (#readModels % #transaction)  -- or however the env exposes it
let lookupAt tid = (.at) <$> Map.lookup tid (txReadModel ^. ...)
result <- liftIO (balanceAsOf reader lookupAt accountId asOf)
```

Look at how `ensureEditorAccess` reaches the transaction read model in `TransactionService` for the exact accessor path; copy.

- [ ] **Step 9.5: Run the test, see it pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.ReadModels.BalanceAsOfJoin/"`
Expected: PASS.

- [ ] **Step 9.6: Run full read-model tests.**

Run: `cabal test all --test-option='--match' --test-option="/Application.ReadModels/"`
Expected: PASS — the existing `balanceAsOf` tests still pass because if the lookup returns `Nothing`, the fold falls back to leg `e.at`, which equals TX `at` on streams without any `TransactionDateChanged` event.

- [ ] **Step 9.7: `just check`.**

- [ ] **Step 9.8: Commit.**

```bash
git add src/Application/ReadModels/Account.hs src/Application/Services/AccountService.hs src/Domain/Account/Events.hs test/Application/ReadModels/BalanceAsOfJoinSpec.hs
git commit -m "refactor(balance-as-of): join TX aggregate 'at' instead of leg event

balanceAsOf now consults the transaction aggregate's current 'at' via
a lookup parameter, so date edits propagate into period balances.
Falls back to the leg event's 'at' when the TX is absent from the
lookup (defensive; valid streams always have a TX).

AccountDebited.description, AccountDebited.at, AccountCredited.description,
AccountCredited.at are now unread by any projection. They remain in the
on-disk payload as historical breadcrumb; removal is deferred to a
later spec.

Refs #80"
```

---

## Task 10 — Integration tests

End-to-end coverage from spec §7.

**Files:**
- Test: `test/Integration/TransactionMetadataEditIntegrationSpec.hs`
- Test: `test/Integration/BooksClosePeriodIntegrationSpec.hs`

- [ ] **Step 10.1: Write `TransactionMetadataEditIntegrationSpec`.**

End-to-end scenarios (copy the harness setup from `TransactionLabelsIntegrationSpec.hs`):

- Create a transfer (Income or Expense) with `at = 2026-03-15`, description = "Initial".
- `PUT /api/transactions/:id/description` with `"Edited"` → 200; `GET` returns `description = "Edited"`.
- `PUT /api/transactions/:id/date` with `2026-04-02` → 200; `GET` returns `at = 2026-04-02`.
- List endpoint reflects edited values.
- `balanceAsOf 2026-03-31` for the source account: before the date edit, includes the leg; after, excludes it (balance differs by the leg amount).

- [ ] **Step 10.2: Write `BooksClosePeriodIntegrationSpec`.**

- `PUT .../books-close` with `2026-03-31` → 200.
- Attempt to create a transaction with `at = 2026-03-15` → 409 `CANNOT_EDIT_CLOSED_PERIOD`.
- Create a transaction with `at = 2026-04-15` (open period); attempt to `PUT /:id/date` with `2026-03-30` → 409.
- `PUT .../books-close` with `2026-02-28` (rewind) → 409 `CANNOT_REWIND_BOOKS_CLOSE`.
- `PUT .../books-close` with `2026-04-30` (advance) → 200.
- Attempt to `PUT /:id/description` (or `/date`) on a transaction whose `at` is `2026-04-15` (now closed) → 409 (description edit is fine — books-close only gates date moves; verify against the spec: **description edits are NOT gated by books-close**. The spec says only date moves are gated; description is purely informational. Update tests accordingly).

- [ ] **Step 10.3: Run, see them fail / pass.**

Run: `cabal test all --test-option='--match' --test-option="/Integration.(TransactionMetadata|BooksClosePeriod)/"`
Expected: PASS once the integration scenarios match the implementation.

- [ ] **Step 10.4: Run the full suite.**

Run: `just test`
Expected: PASS.

- [ ] **Step 10.5: `just check`.**

- [ ] **Step 10.6: Commit.**

```bash
git add test/Integration/TransactionMetadataEditIntegrationSpec.hs test/Integration/BooksClosePeriodIntegrationSpec.hs
git commit -m "test(integration): description/date edits and books-close enforcement

Refs #80"
```

---

## Task 11 — Verification + draft PR follow-up

- [ ] **Step 11.1: Full test run.**

```bash
just build
just test
just check
```

Expected: PASS at every step. Use `superpowers:verification-before-completion` to ensure no claim of "done" is made without evidence.

- [ ] **Step 11.2: Self-review the diff.**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Confirm every new file maps to a spec section; no surprise edits.

- [ ] **Step 11.3: Push and mark PR #82 ready.**

```bash
git push
gh pr ready 82
```

(Decision deferred to user — do not flip from draft to ready without explicit confirmation. Default: leave as draft and surface to the user.)

- [ ] **Step 11.4: Update spec frontmatter status.**

In `docs/specs/2026-05-20-editable-transaction-metadata-design.md`, flip `status: draft` → `status: in-progress` once Task 1 commits, then to `completed` at the end. Use a separate, dedicated commit per status change so the spec history reads cleanly.

---

## Cross-cutting checks (run after each task; not their own task)

- After Task 1: `grep -rn "CannotEditTransactionLabelsInCurrentState" src/ test/` returns nothing.
- After Task 5: `cabal test all --test-option='--match' --test-option="/Domain.Transaction/"` passes (the labels and category specs still work because they use the renamed constructor).
- After Task 9: `grep -n "e\.at" src/Application/ReadModels/Account.hs` only appears inside the `Nothing` fallback branch of `applyAsOf` (and in the deprecated docstring); the equality `e.at <= cutoff` no longer exists as a primary condition.
- Anywhere a `Maybe UTCTime` participates in a comparison: confirm `Nothing` is correctly treated as "no cutoff" (i.e. the user has not closed any period).

## Order-of-operations notes

- Task 1 must land first — every subsequent task uses the renamed / new error constructors.
- Tasks 2–4 (books-close) can be parallelised with Tasks 5–8 (description/date), but Task 7 depends on Task 2's events / Task 3's read model. Suggested order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11.
- Task 9 is independent of Tasks 5–8 but the integration tests in Task 10 exercise the join, so 9 must precede 10.
- Tasks are deliberately small (~20 minutes of focused work each). Subagent-driven execution is recommended; if running inline, take an explicit checkpoint after Tasks 4, 7, and 9 to verify the build and tests.
