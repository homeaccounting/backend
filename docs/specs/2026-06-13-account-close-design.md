---
status: completed
date: 2026-06-13
issue: homeaccounting/backend#99
---

# Account Close / Reopen (Deactivation)

## Problem

There is no way to deactivate an account. Once created, an account lives
forever in the user's account list. Users accumulate accounts they no longer
use — a sold car, a paid-off loan, a closed bank account — with no way to get
them out of the way. The web app needs a per-account lifecycle status it can
read on the GET and LIST endpoints so it can hide deactivated accounts from
the default UI.

From issue #99:

> Client should be able to close the existing account so that it will have
> status: Closed. Once account is created, its status should be Opened.
> Status should be reported on GET/LIST endpoints so that client (web app)
> be able to filter-out closed accounts and make them not-visible for UI.

## Scope and non-goals

**In scope:**

- An `AccountStatus` (`Opened` / `Closed`) on every account, surfaced on the
  GET-by-id and LIST responses.
- `CloseAccount` and `ReopenAccount` commands (owner-only; `External`
  accounts are never closable).
- The status flips between `Opened` and `Closed`; account creation seeds
  `Opened`.

**Explicit non-goals (decided during brainstorming):**

- **No mutation enforcement.** A closed account is *not* read-only. It still
  accepts transfers, renames, sharing, etc. `Closed` is purely a visibility
  label the web client filters on. This is the issue's literal scope and
  keeps the feature small.
- **No server-side LIST filtering.** `GET /api/accounts` continues to return
  every accessible account (still excluding `External`, as today); the status
  rides along and the client decides what to hide. The issue asks for status
  to be *reported* "so that client be able to filter-out", i.e. the client
  filters.
- **No zero-balance precondition** for closing. Event sourcing preserves the
  historical balance regardless; personal-finance apps close leniently.

### Why "flag only" over "read-only when closed"

Enforcing read-only would add: guards on six user-facing account commands,
guards at four transfer-initiation sites, new rejection errors, and — most
importantly — a non-obvious carve-out so that the saga's
`DebitAccount`/`CreditAccount`/`ReverseAccountDebit`/`ReverseAccountCredit`
commands stay *un*guarded (refusing a reversal would deadlock the
`TransactionAmendmentManager`/`TransactionPostingManager` sagas mid-flight).
That invariant is exactly the kind that breaks silently later. Because the UI
hides closed accounts, the user never issues operations against them anyway,
so the enforcement is redundant defense. If real enforcement is ever needed it
is a clean additive follow-up (add *only* the four transfer-initiation guards,
not the full lockdown).

## Design

The feature mirrors the existing `RenameAccount` flow end to end
(command → event → projection → read model → service → web endpoint), plus a
new status field threaded through the aggregate, read model, and response DTO.

### 1. `AccountStatus` (`Domain.Core.Types`)

```haskell
data AccountStatus = Opened | Closed
  deriving (Show, Eq, Generic)

instance ToJSON AccountStatus
instance FromJSON AccountStatus
```

A nullary-constructor enum modelled exactly on the neighbouring `AccountRole`
(`Owner`/`Editor`/`Viewer`): no LiquidHaskell refinement is required for a
plain enum, matching `AccountRole`'s precedent. Exported from
`Domain.Core.Types` alongside `AccountRole`.

### 2. Events (`Domain.Account.Events`)

```haskell
data AccountClosed   = AccountClosed   { by :: UserId } deriving (Show, Eq)
data AccountReopened = AccountReopened { by :: UserId } deriving (Show, Eq)
```

Actor field named `by` per the project convention (the
`refactor/event-actor-field-naming` work; Transaction events already use it).
Both are appended to `accountEvents` and given `deriveJSON`. The Template
Haskell in `Domain.Account.Projection` (`AccountEvent`) and `Domain.Models`
(`AccountingEvent`) then auto-generates the sum-type variants
`AccountClosedAccountEvent` / `AccountReopenedAccountEvent` and the global
`AccountClosedEvent` / `AccountReopenedEvent` constructors.

### 3. Commands (`Domain.Account.Commands`)

```haskell
data CloseAccount  = CloseAccount  { by :: UserId } deriving (Show, Eq)
data ReopenAccount = ReopenAccount { by :: UserId } deriving (Show, Eq)
```

Appended to `accountCommands` with `deriveJSON`. `by` is the issuing user
(must be the owner; checked in the handler).

### 4. Aggregate + projection (`Domain.Account.Projection`)

Add a field to `Account`:

```haskell
status :: AccountStatus
```

- `accountDefault`: `status = Opened`.
- `AccountCreated`: sets `status = Opened` (explicit, not relying on the seed).
- `AccountClosed`: `status = Closed`.
- `AccountReopened`: `status = Opened`.

All other event handlers leave `status` untouched.

### 5. Command handler (`Domain.Account.CommandHandler`)

New `AccountError` variants:

```haskell
ExternalAccountCannotBeClosed
| AccountAlreadyClosed
| AccountAlreadyOpen
```

Handlers:

- **`CloseAccount`**: reject if name empty (`AccountDoesNotExist`),
  `External` (`ExternalAccountCannotBeClosed`), not owner (`NotAccountOwner`),
  already `Closed` (`AccountAlreadyClosed`); otherwise emit `AccountClosed`.
- **`ReopenAccount`**: reject if name empty (`AccountDoesNotExist`), not owner
  (`NotAccountOwner`), already `Opened` (`AccountAlreadyOpen`); otherwise emit
  `AccountReopened`. (`External` accounts can never be `Closed`, so a reopen
  on one falls through to `AccountAlreadyOpen`.)

No guards are added to any existing command. Owner check reuses the existing
`isOwner` helper, consistent with `RenameAccount`.

### 6. Read model (`Application.ReadModels.Account`)

Add `status :: AccountStatus` to `AccountData`.

- `AccountCreated` handler: `status = Opened`.
- New `AccountClosedEvent` handler: `status = Closed`, bump `version`.
- New `AccountReopenedEvent` handler: `status = Opened`, bump `version`.

`getAccessibleAccounts` / `listAccountsForUser` are unchanged — no filtering;
status simply flows through.

### 7. Service (`Application.Services.AccountService`)

Two thin functions mirroring `renameAccount`:

```haskell
closeAccount  :: UserId -> UUID -> AppM (Either DomainError ())
reopenAccount :: UserId -> UUID -> AppM (Either DomainError ())
```

Each validates the UUID, constructs the command with `by = requestingUserId`,
and runs it via `runAccountCmd`. The owner / state-transition rules live in the
domain handler; rejections collapse to the generic
`AccountError "Account command rejected by domain"` exactly as `renameAccount`
and `shareAccount` already do (`runAccountCmd` in `Application.Services.Internal`).

### 8. Web (`Web.API.AccountAPI`, `Web.Types`)

Two new endpoints, action-style (matching `POST /:id/share`):

```
POST /api/accounts/:id/close   -> 200, NoContent
POST /api/accounts/:id/reopen  -> 200, NoContent
```

Handlers extract the authenticated user, delegate to the service, and map
errors via `throwDomainError` — identical shape to `renameAccountHandler`
minus the body. Added to the `AccountAPI` type and `accountServer`.

`AccountResponse` gains:

```haskell
status :: Text   -- "Opened" | "Closed"
```

rendered capitalised to match the existing `TransactionStatusResponse`
convention. `fromAccountData` maps `AccountData.status` to that text. The field
therefore appears on both `GET /api/accounts/:id` and every element of
`GET /api/accounts`.

## Data flow

```
POST /:id/close
  -> closeAccountHandler (auth user, accountUuid)
  -> AccountService.closeAccount
  -> runAccountCmd (CloseAccountAccountCommand { by = userId })
  -> handleAccountCommand: owner? not External? not already closed?
  -> AccountClosed { by } persisted
  -> read-model handler sets AccountData.status = Closed
GET /:id, GET / (LIST)
  -> fromAccountData -> AccountResponse.status = "Closed"
  -> web client hides closed accounts
```

## Error handling

| Situation                         | Domain error                    | HTTP (via existing mapping)        |
| --------------------------------- | ------------------------------- | ---------------------------------- |
| Close/reopen non-existent account | `AccountDoesNotExist`           | generic account rejection (4xx)    |
| Close an `External` account       | `ExternalAccountCannotBeClosed` | generic account rejection (4xx)    |
| Non-owner closes/reopens          | `NotAccountOwner`               | generic account rejection (4xx)    |
| Close an already-closed account   | `AccountAlreadyClosed`          | generic account rejection (4xx)    |
| Reopen an already-open account    | `AccountAlreadyOpen`            | generic account rejection (4xx)    |

This matches the existing granularity: `runAccountCmd` already collapses all
domain rejections to one generic `AccountError`, so close/reopen inherit the
same HTTP behaviour as rename/share without new mapping code.

## Testing (TDD, property-first)

- **`Domain/Account/CommandHandlerSpec` + `CommandHandlerPropertySpec`:**
  close happy path; reopen happy path; close→close rejected
  (`AccountAlreadyClosed`); reopen on open rejected (`AccountAlreadyOpen`);
  `External` close rejected; non-owner rejected; non-existent rejected.
  Property: `close` then `reopen` returns status to `Opened`; status is
  unaffected by unrelated events.
- **Projection:** `AccountClosed`/`AccountReopened` set status; created account
  is `Opened`.
- **`Application/ReadModels/Account` (Spec + PropertySpec):** status reflected
  after close/reopen events; version bumps; LIST returns closed accounts with
  `status = Closed`.
- **`AccountServiceSpec` / IntegrationSpec:** `closeAccount`/`reopenAccount`
  succeed for owner; reopen-after-close round-trips; GET/LIST report status.
- **`Web/API/AccountAPISpec`:** `POST /:id/close` and `/:id/reopen` return
  `NoContent`; `AccountResponse` carries `status`.

## Files touched

| File                                          | Change                                      |
| --------------------------------------------- | ------------------------------------------- |
| `src/Domain/Core/Types.hs`                    | `AccountStatus` type + JSON + export        |
| `src/Domain/Account/Events.hs`                | `AccountClosed`, `AccountReopened`          |
| `src/Domain/Account/Commands.hs`              | `CloseAccount`, `ReopenAccount`             |
| `src/Domain/Account/Projection.hs`            | `status` field + 3 handlers                 |
| `src/Domain/Account/CommandHandler.hs`        | 2 handlers + 3 error variants               |
| `src/Application/ReadModels/Account.hs`       | `status` on `AccountData` + 2 handlers      |
| `src/Application/Services/AccountService.hs`  | `closeAccount`, `reopenAccount`             |
| `src/Web/API/AccountAPI.hs`                   | 2 endpoints + handlers                      |
| `src/Web/Types.hs`                            | `status` on `AccountResponse` + mapping     |
| `test/Domain/Account/*`                       | command-handler + projection specs          |
| `test/Application/ReadModels/Account*`        | read-model specs                            |
| `test/Application/Services/AccountService*`   | service + integration specs                 |
| `test/Web/API/AccountAPISpec.hs`              | endpoint specs                              |

No `Main.hs` wiring changes: commands/events register through the existing
Template Haskell lists, and the read-model handler is already subscribed.
