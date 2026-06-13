# Account Close / Reopen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `Opened`/`Closed` lifecycle status to accounts, with owner-only `Close`/`Reopen` commands and the status reported on the GET and LIST endpoints, so the web app can hide closed accounts.

**Architecture:** CQRS + Event Sourcing. A new `AccountStatus` enum is threaded through the `Account` aggregate, its read model, and the `AccountResponse` DTO. Two new commands (`CloseAccount`/`ReopenAccount`) emit two new events (`AccountClosed`/`AccountReopened`) that only flip the status. `Closed` is a pure visibility label — **no mutation enforcement, no transfer guards, no saga changes** (see spec §"Why flag only"). Everything mirrors the existing `RenameAccount` flow.

**Tech Stack:** Haskell (GHC 9.10), RIO prelude, Eventium event store, Servant, Hspec/QuickCheck, Optics, Aeson. Build/test via `just build` / `just test`; format `just format`; lint `just lint`.

**Spec:** `docs/specs/2026-06-13-account-close-design.md`

**Conventions to honor:**
- Actor field is named `by :: UserId` (project convention; see Transaction commands/events).
- `NoFieldSelectors` + `DuplicateRecordFields` are on — multiple records may share the `by` field; access record fields via Optics labels (`account ^. #status`) or `RecordWildCards`.
- Never export data constructors of domain ID types; `AccountStatus` is a plain enum and *is* exported with `(..)` exactly like the neighbouring `AccountRole`.
- After each task: `just format` then `just lint` before committing. CI uses `-Werror` (`cabal build -fci`) for lib+exe; the test suite is gated by `just test`.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/Domain/Core/Types.hs` | Shared domain types | Add `AccountStatus` enum + JSON + export |
| `src/Domain/Account/Events.hs` | Account events | Add `AccountClosed`, `AccountReopened` |
| `src/Domain/Account/Commands.hs` | Account commands | Add `CloseAccount`, `ReopenAccount` |
| `src/Domain/Account/Projection.hs` | Aggregate state + fold | Add `status` field + 3 event handlers |
| `src/Domain/Account/CommandHandler.hs` | Command validation | Add 2 handlers + 3 error variants |
| `src/Application/ReadModels/Account.hs` | Denormalized read view | Add `status` to `AccountData` + 2 handlers |
| `src/Application/Services/AccountService.hs` | Use-case orchestration | Add `closeAccount`, `reopenAccount` |
| `src/Web/API/AccountAPI.hs` | Servant endpoints | Add 2 endpoints + handlers |
| `src/Web/Types.hs` | Response DTOs | Add `status` to `AccountResponse` + mapping |
| `test/Domain/Account/CommandHandlerSpec.hs` | Domain unit tests | Add close/reopen specs |
| `test/Application/Services/AccountServiceIntegrationSpec.hs` | End-to-end tests | Add read-model + service status tests |
| `test/Web/API/AccountAPISpec.hs` | HTTP tests | Add endpoint + response-status tests |

Four tasks, each a self-contained compilable unit (Haskell compiles whole-program, and adding command/event constructors forces exhaustiveness updates, so the domain layer is one atomic change).

---

## Task 1: Domain layer — type, events, commands, projection, command handler

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Modify: `src/Domain/Account/Events.hs`
- Modify: `src/Domain/Account/Commands.hs`
- Modify: `src/Domain/Account/Projection.hs`
- Modify: `src/Domain/Account/CommandHandler.hs`
- Test: `test/Domain/Account/CommandHandlerSpec.hs`

- [ ] **Step 1: Write the failing tests**

In `test/Domain/Account/CommandHandlerSpec.hs`, extend the imports and add two new spec groups.

Add to the command imports (the `Domain.Account.Commands` import line):
```haskell
import Domain.Account.Commands (CloseAccount (..), CreditAccount (..), DebitAccount (..), RenameAccount (..), ReopenAccount (..), SetOverdraftLimit (..))
```
Add to the events imports:
```haskell
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountClosed (..),
    AccountCreated (..),
    AccountRenamed (..),
    AccountReopened (..),
  )
```

Register the new groups in `spec`:
```haskell
  closeAccountSpec
  reopenAccountSpec
```

Add fixtures (place near the other fixtures; reuse `regularAccountWithOwner`, `testOwnerId`, `testEditorId`, `mockMoney`, `defaultCash`, and the existing external-account fixture — confirm its name in the file, e.g. `externalAccountWithOwner`):
```haskell
-- | A regular account that has been closed by its owner.
closedAccount :: Account
closedAccount =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated "Test Account" (mockMoney 1000) testOwnerId (Regular defaultCash) (Just (mockMoney 0)),
      AccountClosedAccountEvent (AccountClosed {by = testOwnerId})
    ]
```

Add the spec groups:
```haskell
closeAccountSpec :: Spec
closeAccountSpec = describe "CloseAccount Command" $ do
  context "Given an open regular account with an owner" $ do
    describe "When the owner closes it" $ do
      it "Then emits AccountClosed and the projected status is Closed" $ do
        let account = regularAccountWithOwner testOwnerId
            command = CloseAccountAccountCommand (CloseAccount {by = testOwnerId})
        case handleAccountCommand account command of
          Right events -> do
            events `shouldBe` [AccountClosedAccountEvent (AccountClosed {by = testOwnerId})]
            (applyEvents events ^. #status) `shouldBe` Closed
          Left err -> expectationFailure $ "expected success, got " <> show err

    describe "When a non-owner closes it" $ do
      it "Then rejects with NotAccountOwner" $ do
        let account = regularAccountWithOwner testOwnerId
            command = CloseAccountAccountCommand (CloseAccount {by = testEditorId})
        handleAccountCommand account command `shouldBe` Left NotAccountOwner

    describe "When it is already closed" $ do
      it "Then rejects with AccountAlreadyClosed" $ do
        let command = CloseAccountAccountCommand (CloseAccount {by = testOwnerId})
        handleAccountCommand closedAccount command `shouldBe` Left AccountAlreadyClosed

  context "Given an External account" $ do
    describe "When the owner tries to close it" $ do
      it "Then rejects with ExternalAccountCannotBeClosed" $ do
        let account = externalAccountWithOwner testOwnerId
            command = CloseAccountAccountCommand (CloseAccount {by = testOwnerId})
        handleAccountCommand account command `shouldBe` Left ExternalAccountCannotBeClosed

  context "Given a non-existent account" $ do
    describe "When anyone tries to close it" $ do
      it "Then rejects with AccountDoesNotExist" $ do
        let command = CloseAccountAccountCommand (CloseAccount {by = testOwnerId})
        handleAccountCommand emptyAccount command `shouldBe` Left AccountDoesNotExist

reopenAccountSpec :: Spec
reopenAccountSpec = describe "ReopenAccount Command" $ do
  context "Given a closed account" $ do
    describe "When the owner reopens it" $ do
      it "Then emits AccountReopened and the projected status is Opened" $ do
        let command = ReopenAccountAccountCommand (ReopenAccount {by = testOwnerId})
        case handleAccountCommand closedAccount command of
          Right events -> do
            events `shouldBe` [AccountReopenedAccountEvent (AccountReopened {by = testOwnerId})]
            -- Apply on top of the closed stream to confirm the round-trip.
            ( applyEvents
                [ AccountCreatedAccountEvent
                    (AccountCreated "Test Account" (mockMoney 1000) testOwnerId (Regular defaultCash) (Just (mockMoney 0))),
                  AccountClosedAccountEvent (AccountClosed {by = testOwnerId}),
                  AccountReopenedAccountEvent (AccountReopened {by = testOwnerId})
                ]
                ^. #status
              )
              `shouldBe` Opened
          Left err -> expectationFailure $ "expected success, got " <> show err

    describe "When a non-owner reopens it" $ do
      it "Then rejects with NotAccountOwner" $ do
        let command = ReopenAccountAccountCommand (ReopenAccount {by = testEditorId})
        handleAccountCommand closedAccount command `shouldBe` Left NotAccountOwner

  context "Given an already-open regular account" $ do
    describe "When the owner reopens it" $ do
      it "Then rejects with AccountAlreadyOpen" $ do
        let account = regularAccountWithOwner testOwnerId
            command = ReopenAccountAccountCommand (ReopenAccount {by = testOwnerId})
        handleAccountCommand account command `shouldBe` Left AccountAlreadyOpen

  context "Given an External account (never closable, so always Opened)" $ do
    describe "When the owner reopens it" $ do
      it "Then rejects with AccountAlreadyOpen" $ do
        let account = externalAccountWithOwner testOwnerId
            command = ReopenAccountAccountCommand (ReopenAccount {by = testOwnerId})
        handleAccountCommand account command `shouldBe` Left AccountAlreadyOpen

  context "Given a non-existent account" $ do
    describe "When anyone tries to reopen it" $ do
      it "Then rejects with AccountDoesNotExist" $ do
        let command = ReopenAccountAccountCommand (ReopenAccount {by = testOwnerId})
        handleAccountCommand emptyAccount command `shouldBe` Left AccountDoesNotExist
```

> If the external-account fixture has a different name, grep the file: `grep -n "external" test/Domain/Account/CommandHandlerSpec.hs` and use the real name (it builds an `AccountCreated` with `External`).

- [ ] **Step 2: Run tests to verify they fail (compile error)**

Run: `just test 2>&1 | tail -30`
Expected: FAIL — `AccountStatus`/`Opened`/`Closed`, `CloseAccount`, `ReopenAccount`, `AccountClosed`, `AccountReopened`, `AccountAlreadyClosed`, `AccountAlreadyOpen`, `ExternalAccountCannotBeClosed`, and the `CloseAccountAccountCommand`/`AccountClosedAccountEvent` constructors are not in scope.

- [ ] **Step 3: Add `AccountStatus` to `src/Domain/Core/Types.hs`**

Add `AccountStatus (..)` to the module export list (next to `AccountRole (..)`).

After the `AccountRole` block (around line 919), add:
```haskell
-- | Lifecycle status of an account.
--
-- Accounts are 'Opened' on creation. An owner may 'Closed' (deactivate) an
-- account to hide it from the default UI; this is a pure visibility label and
-- imposes no behavioural restrictions (see the account-close design spec).
data AccountStatus
  = Opened
  | Closed
  deriving (Show, Eq, Generic)

instance ToJSON AccountStatus

instance FromJSON AccountStatus
```

- [ ] **Step 4: Add events to `src/Domain/Account/Events.hs`**

Add to the export list:
```haskell
    AccountClosed (..),
    AccountReopened (..),
```
Add to the `accountEvents` Template Haskell list:
```haskell
    ''AccountClosed,
    ''AccountReopened
```
(insert before the closing `]`; remember the comma after the previous last entry `''AccountCreditReversed`).

Add the event types (near the other event declarations, before the `deriveJSON` block):
```haskell
-- | Event emitted when an account is closed (deactivated) by its owner.
data AccountClosed = AccountClosed
  { -- | User who closed the account (the Owner).
    by :: UserId
  }
  deriving (Show, Eq)

-- | Event emitted when a previously-closed account is reopened by its owner.
data AccountReopened = AccountReopened
  { -- | User who reopened the account (the Owner).
    by :: UserId
  }
  deriving (Show, Eq)
```
Add the JSON derivations to the `deriveJSON` block at the bottom:
```haskell
deriveJSON defaultOptions ''AccountClosed
deriveJSON defaultOptions ''AccountReopened
```

- [ ] **Step 5: Add commands to `src/Domain/Account/Commands.hs`**

Add to the export list:
```haskell
    CloseAccount (..),
    ReopenAccount (..),
```
Add to the `accountCommands` list:
```haskell
    ''CloseAccount,
    ''ReopenAccount
```
Add the command types (near the other command declarations):
```haskell
-- | Command to close (deactivate) an account.
--
-- Owner-only. External accounts cannot be closed. Rejected if already closed.
data CloseAccount = CloseAccount
  { -- | User issuing the close (must be the Owner).
    by :: UserId
  }
  deriving (Show, Eq)

-- | Command to reopen a previously-closed account.
--
-- Owner-only. Rejected if the account is already open.
data ReopenAccount = ReopenAccount
  { -- | User issuing the reopen (must be the Owner).
    by :: UserId
  }
  deriving (Show, Eq)
```
Add JSON derivations:
```haskell
deriveJSON defaultOptions ''CloseAccount
deriveJSON defaultOptions ''ReopenAccount
```

- [ ] **Step 6: Add `status` field + handlers to `src/Domain/Account/Projection.hs`**

Add `AccountStatus (..)`, `Opened`, `Closed` to the `Domain.Core.Types` import list. Add `AccountClosed (..)`, `AccountReopened (..)` to the `Domain.Account.Events` import list.

Add the field to `Account` (after `hasTransactions`):
```haskell
    -- | Lifecycle status. Opened on creation; flipped by Close/Reopen.
    status :: AccountStatus
  }
```
(add a comma after the previous `hasTransactions :: Bool` line).

Update `accountDefault` to seed the field:
```haskell
        hasTransactions = False,
        status = Opened
      }
```

In the `AccountCreated` handler, set status explicitly (append to the optics chain):
```haskell
        & #overdraftLimit
        .~ created.overdraftLimit
        & #status
        .~ Opened
```

Add two new handler equations (place them with the other `handleAccountEvent` cases):
```haskell
handleAccountEvent account (AccountClosedAccountEvent _) =
  account & #status .~ Closed
handleAccountEvent account (AccountReopenedAccountEvent _) =
  account & #status .~ Opened
```

- [ ] **Step 7: Add error variants + handlers to `src/Domain/Account/CommandHandler.hs`**

Add `AccountStatus (..)` (or at least `Opened`, `Closed`) to the `Domain.Core.Types` import list. Add the three error variants to `AccountError`:
```haskell
  | ExternalAccountCannotBeClosed
  | AccountAlreadyClosed
  | AccountAlreadyOpen
```
Add two handler equations (place near `RenameAccount`):
```haskell
-- Handle CloseAccount command (owner-only deactivation)
handleAccountCommand account (CloseAccountAccountCommand CloseAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | account ^. #accountType == External = Left ExternalAccountCannotBeClosed
  | not (isOwner by account) = Left NotAccountOwner
  | account ^. #status == Closed = Left AccountAlreadyClosed
  | otherwise =
      Right [AccountClosedAccountEvent AccountClosed {by = by}]
-- Handle ReopenAccount command (owner-only reactivation)
handleAccountCommand account (ReopenAccountAccountCommand ReopenAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | not (isOwner by account) = Left NotAccountOwner
  | account ^. #status == Opened = Left AccountAlreadyOpen
  | otherwise =
      Right [AccountReopenedAccountEvent AccountReopened {by = by}]
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `just format && just test 2>&1 | tail -30`
Expected: PASS — the new `CloseAccount Command` and `ReopenAccount Command` groups are green and the rest of the suite is unaffected.

- [ ] **Step 9: Lint, then commit**

```bash
just lint
git add src/Domain/Core/Types.hs src/Domain/Account/Events.hs src/Domain/Account/Commands.hs src/Domain/Account/Projection.hs src/Domain/Account/CommandHandler.hs test/Domain/Account/CommandHandlerSpec.hs
git commit -m "feat(account): AccountStatus + Close/Reopen commands and events (#99)"
```

---

## Task 2: Read model — `status` on `AccountData`

**Files:**
- Modify: `src/Application/ReadModels/Account.hs`
- Test: `test/Application/Services/AccountServiceIntegrationSpec.hs`

The live read-model handler (`processEvent`) is exercised end-to-end through the in-memory event store. We test it by applying the new commands directly via `applyAccountCommand` (already imported in the integration spec) and asserting `getAccount` reports the new `status`.

- [ ] **Step 1: Write the failing test**

In `test/Application/Services/AccountServiceIntegrationSpec.hs`:

Add `CloseAccount (..)`, `ReopenAccount (..)` to the `Domain.Account.Commands` import line.

This file already has a `setupUserWithAccount :: Currency -> Rational -> IO (AppEnv, UserId, AccountId)` helper that registers a user and creates a `Regular` account, and the `AppEnv` exposes `eventStoreWriter`, `eventStoreReader`, and `accountReadModel` as record fields (accessed via `env.field`). `applyAccountCommand` and `unAccountId` are already imported; `id` is the no-op `MetadataEnricher` (same value `runAccountCmd`/the other cases pass).

Register a new case in `spec`:
```haskell
  it
    "reports Closed status in the read model after a close, and Opened after reopen"
    closeReopenStatusSpec
```

Add the test — drive the new commands through the low-level `applyAccountCommand` (the service wrapper arrives in Task 3) and read back via `getAccount`. The read-model handler updates synchronously on publish, exactly as the existing cases rely on:
```haskell
closeReopenStatusSpec :: Expectation
closeReopenStatusSpec = do
  (env, userId, accountId) <- setupUserWithAccount USD 100
  let uuid = unAccountId accountId
      apply cmd = applyAccountCommand env.eventStoreWriter env.eventStoreReader id uuid cmd

  -- Newly created accounts are Opened.
  m0 <- getAccount env.accountReadModel accountId
  fmap (.status) m0 `shouldBe` Just Opened

  -- Close, then confirm the read model reports Closed.
  _ <- apply (CloseAccountAccountCommand (CloseAccount {by = userId}))
  m1 <- getAccount env.accountReadModel accountId
  fmap (.status) m1 `shouldBe` Just Closed

  -- Reopen, then confirm it flips back to Opened.
  _ <- apply (ReopenAccountAccountCommand (ReopenAccount {by = userId}))
  m2 <- getAccount env.accountReadModel accountId
  fmap (.status) m2 `shouldBe` Just Opened
```

> `Opened`/`Closed` come from `Domain.Core.Types`; add `AccountStatus (..)` to that import if not already pulled in. `getAccount`, `AccountData (..)`, `USD`, `unAccountId` are already imported. Sanity-check the helper name and `AppEnv` fields with `grep -n "setupUserWithAccount\|eventStoreWriter\|accountReadModel" test/Application/Services/AccountServiceIntegrationSpec.hs`.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tail -30`
Expected: FAIL — `AccountData` has no field `status` (record selector not in scope), so it won't compile.

- [ ] **Step 3: Add `status` to the read model**

In `src/Application/ReadModels/Account.hs`:

Add `AccountStatus (..)` to the `Domain.Core.Types` import list. Add `AccountClosed (..)`, `AccountReopened (..)` to the `Domain.Account.Events` import list (alongside the other event types).

Add the field to `AccountData` (after `hasTransactions`):
```haskell
    -- | Lifecycle status. Opened on creation; flipped by Close/Reopen events.
    status :: AccountStatus,
```
(this sits before `version :: Int`; keep the trailing comma correct).

In the `AccountCreatedEvent` branch of `processEvent`, add `status = Opened` to the `AccountData` record:
```haskell
                        hasTransactions = False,
                        status = Opened,
                        version = 1
                      }
```

Add two new branches to `processEvent` (place them before the final `_ -> accounts` catch-all; the global-event constructors drop the `Event`-less suffix, so they are `AccountClosedEvent` / `AccountReopenedEvent`):
```haskell
        AccountClosedEvent _ ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                (\account -> account {status = Closed, version = account.version + 1})
                accountId
                accounts
        AccountReopenedEvent _ ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                (\account -> account {status = Opened, version = account.version + 1})
                accountId
                accounts
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just format && just test 2>&1 | tail -30`
Expected: PASS — `closeReopenStatusSpec` is green.

- [ ] **Step 5: Lint, then commit**

```bash
just lint
git add src/Application/ReadModels/Account.hs test/Application/Services/AccountServiceIntegrationSpec.hs
git commit -m "feat(account): track status in the account read model (#99)"
```

---

## Task 3: Service — `closeAccount` / `reopenAccount`

**Files:**
- Modify: `src/Application/Services/AccountService.hs`
- Test: `test/Application/Services/AccountServiceIntegrationSpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/Application/Services/AccountServiceIntegrationSpec.hs`, add `closeAccount`, `reopenAccount` to the `Application.Services.AccountService` import. Add `import Data.Either (isLeft)` if not already present.

Register a case:
```haskell
  it
    "closeAccount then reopenAccount round-trips the status via the service layer"
    serviceCloseReopenSpec
```

Add the test — same `setupUserWithAccount` harness as Task 2, but driving the **service** functions via `runAppM env` and asserting their `Either` results:
```haskell
serviceCloseReopenSpec :: Expectation
serviceCloseReopenSpec = do
  (env, userId, accountId) <- setupUserWithAccount USD 100
  let uuid = unAccountId accountId

  closed <- runAppM env $ closeAccount userId uuid
  closed `shouldBe` Right ()
  m1 <- getAccount env.accountReadModel accountId
  fmap (.status) m1 `shouldBe` Just Closed

  -- Closing again is rejected by the domain (collapses to a generic AccountError).
  closedAgain <- runAppM env $ closeAccount userId uuid
  isLeft closedAgain `shouldBe` True

  reopened <- runAppM env $ reopenAccount userId uuid
  reopened `shouldBe` Right ()
  m2 <- getAccount env.accountReadModel accountId
  fmap (.status) m2 `shouldBe` Just Opened
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tail -30`
Expected: FAIL — `closeAccount` / `reopenAccount` not in scope (not exported by `AccountService`).

- [ ] **Step 3: Implement the service functions**

In `src/Application/Services/AccountService.hs`:

Add `closeAccount`, `reopenAccount` to the module export list. Add `CloseAccount (..)`, `ReopenAccount (..)` to the `Domain.Account.Commands` import list. Ensure `AccountCommand (..)` (already imported) covers the new constructors.

Add the two functions (model on `renameAccount`):
```haskell
-- | Close (deactivate) an account. Owner-only; enforced by the domain handler.
closeAccount ::
  UserId ->
  UUID ->
  AppM (Either DomainError ())
closeAccount requestingUserId accountUuid = runExceptT $ do
  lift $ logInfo $ "Closing account: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd = CloseAccountAccountCommand CloseAccount {by = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account closed successfully"

-- | Reopen a previously-closed account. Owner-only; enforced by the domain handler.
reopenAccount ::
  UserId ->
  UUID ->
  AppM (Either DomainError ())
reopenAccount requestingUserId accountUuid = runExceptT $ do
  lift $ logInfo $ "Reopening account: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd = ReopenAccountAccountCommand ReopenAccount {by = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account reopened successfully"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just format && just test 2>&1 | tail -30`
Expected: PASS — `serviceCloseReopenSpec` green.

- [ ] **Step 5: Lint, then commit**

```bash
just lint
git add src/Application/Services/AccountService.hs test/Application/Services/AccountServiceIntegrationSpec.hs
git commit -m "feat(account): closeAccount/reopenAccount service functions (#99)"
```

---

## Task 4: Web — endpoints + `AccountResponse.status`

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/AccountAPI.hs`
- Test: `test/Web/API/AccountAPISpec.hs`

- [ ] **Step 1: Write the failing test**

This file drives requests through `httpRequest f.fApp method path (authHeaders f.fToken) body :: IO SResponse` and asserts on `simpleStatus`/`simpleBody` (see the existing `putBalance` helper and `happyPathSpec`). The `Fixture` exposes `fApp`, `fToken`, `fAccountUuid`; `mkFixture "email"` creates a user + a fresh (Opened) account. `status200`, `eitherDecode`, `SResponse (..)` are already imported.

**Note on status code:** `Post '[JSON] NoContent` in Servant is `Verb 'POST 200 '[JSON] NoContent` — it returns **HTTP 200 with an empty body**, not 204 (204 would require `PostNoContent`/`Verb 'POST 204`). The existing `share`/`rename` endpoints (`Post`/`Put '[JSON] NoContent`) confirm this. So assert `status200`.

Add `AccountResponse (..)` to the `Web.Types` import (so the response body can be decoded and `.status` read; it is a `Text`, `"Opened"`/`"Closed"`).

The current `spec` is a single `describe "PUT /api/accounts/:id/balance"`. Restructure it so `spec` runs two describes (indent the existing block under the first):
```haskell
spec :: Spec
spec = do
  describe "PUT /api/accounts/:id/balance" $ do
    -- ... existing cases unchanged ...
  describe "POST /api/accounts/:id/close and /reopen" $ do
    it "closes then reopens, reporting status on GET" closeReopenEndpointSpec
```

Add the test:
```haskell
closeReopenEndpointSpec :: IO ()
closeReopenEndpointSpec = do
  f <- mkFixture "close-endpoint@test.com"
  let accPath seg = encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString f.fAccountUuid) <> seg
      getAcc = httpRequest f.fApp "GET" (accPath "") (authHeaders f.fToken) ""
      postAction seg = httpRequest f.fApp "POST" (accPath seg) (authHeaders f.fToken) ""
      statusOf resp = case eitherDecode (simpleBody resp) :: Either String AccountResponse of
        Right ar -> Just ar.status
        Left _ -> Nothing

  -- Precondition: a freshly created account is Opened.
  before <- getAcc
  simpleStatus before `shouldBe` status200
  statusOf before `shouldBe` Just "Opened"

  -- Close -> 200, and the account now reports Closed.
  closed <- postAction "/close"
  simpleStatus closed `shouldBe` status200
  afterClose <- getAcc
  statusOf afterClose `shouldBe` Just "Closed"

  -- Reopen -> 200, and the account reports Opened again.
  reopened <- postAction "/reopen"
  simpleStatus reopened `shouldBe` status200
  afterReopen <- getAcc
  statusOf afterReopen `shouldBe` Just "Opened"
```

> Confirm `mkFixture`, `httpRequest`, `authHeaders`, `simpleBody`/`simpleStatus`, and the `Fixture` field names with `grep -n "mkFixture\|httpRequest\|authHeaders\|simpleBody\|fAccountUuid" test/Web/API/AccountAPISpec.hs`.

- [ ] **Step 2: Run test to verify it fails**

Run: `just test 2>&1 | tail -30`
Expected: FAIL — endpoints/handlers not defined and/or `AccountResponse` has no `status` field.

- [ ] **Step 3: Add `status` to `AccountResponse` (`src/Web/Types.hs`)**

Add `AccountStatus (..)` to the `Domain.Core.Types` import list.

Add the field to `AccountResponse` (after `subtype`):
```haskell
    subtype :: Maybe Value,
    status :: Text,
    version :: Int
```

Map it in `fromAccountData` (the record is opened with `AccountData {..}`, so `status` is the `AccountStatus` in scope):
```haskell
      subtype = case accountType of
        Regular at -> Just (fromAccountSubtype at)
        External -> Nothing,
      status = case status of
        Opened -> "Opened"
        Closed -> "Closed",
      version = version
```

- [ ] **Step 4: Add the endpoints (`src/Web/API/AccountAPI.hs`)**

Add `closeAccountHandler`, `reopenAccountHandler` to the module export list.

Append two endpoints to the **end** of the `AccountAPI` type (after the `balance` endpoint), keeping the `:<|>` chaining:
```haskell
    -- POST /api/accounts/:id/close - Close (deactivate) an account (owner only)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "close"
      :> Post '[JSON] NoContent
    -- POST /api/accounts/:id/reopen - Reopen a closed account (owner only)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "reopen"
      :> Post '[JSON] NoContent
```

Append the handlers to `accountServer` in the **same order** (after `adjustBalanceHandler`):
```haskell
    :<|> closeAccountHandler
    :<|> reopenAccountHandler
```

Add the handler definitions:
```haskell
-- | Handler for POST /api/accounts/:id/close - Close (deactivate) an account.
closeAccountHandler :: AuthenticatedUser -> UUID -> AppM NoContent
closeAccountHandler user accountUuid = do
  result <- AccountService.closeAccount user.userId accountUuid
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for POST /api/accounts/:id/reopen - Reopen a closed account.
reopenAccountHandler :: AuthenticatedUser -> UUID -> AppM NoContent
reopenAccountHandler user accountUuid = do
  result <- AccountService.reopenAccount user.userId accountUuid
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err
```

- [ ] **Step 5: Run test to verify it passes**

Run: `just format && just test 2>&1 | tail -30`
Expected: PASS — the new web spec is green and `AccountResponse` carries `status`.

- [ ] **Step 6: Full build + lint, then commit**

```bash
just build && just lint
git add src/Web/Types.hs src/Web/API/AccountAPI.hs test/Web/API/AccountAPISpec.hs
git commit -m "feat(account): close/reopen endpoints + status on AccountResponse (#99)"
```

---

## Final verification

- [ ] `just build` — clean (lib+exe under `-fci -Werror`).
- [ ] `just test` — full suite green.
- [ ] `just check` (format + lint) — clean.
- [ ] Manually confirm the OpenAPI/route surface if the project exposes one (grep for where `accountServer` is mounted).
- [ ] Update `docs/specs/2026-06-13-account-close-design.md` frontmatter `status: draft` → `status: completed`.

## Notes / decisions carried from the spec

- **No mutation enforcement.** Do not add `Closed`-guards to other commands or to transfer initiation. If a reviewer asks "shouldn't a closed account reject transactions?", the answer is: deliberately out of scope (spec §"Why flag only"); it would require an un-guarded saga carve-out and is a clean additive follow-up.
- **No LIST filtering.** `listAccountsForUser` is unchanged; the client filters on `status`.
- **`by` field naming** is intentional (project convention), not `closedBy`/`reopenedBy`.
- **Not a breaking change.** `status` is *derived* in the projection/read model from the new additive `AccountClosed`/`AccountReopened` events — the persisted `AccountCreated` payload is unchanged, so no event-store rebuild or upcaster is needed. The `AccountResponse` DTO gains a field, which is additive for API consumers. Hence plain `feat`, no `!`.
