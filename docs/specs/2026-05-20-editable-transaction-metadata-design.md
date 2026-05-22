---
status: completed
date: 2026-05-20
issue: homeaccounting/backend#80
---

# Editable Transaction Metadata (Description, Date) + Leg-Event Slimming

## Problem

A completed transaction's `description` and business date (`at`) cannot
be edited. `category` and `labels` were addressed by
[`2026-04-22-transaction-labels-design.md`](2026-04-22-transaction-labels-design.md),
but the two remaining user-visible metadata fields remain frozen at
`InitiateTransfer` time. For an accounting (not banking) application
this is a usability gap — users routinely need to correct a typo in a
description or move a transaction to its real business date after a
batch import or a mistype.

A second, structural problem surfaced while specifying the edit work:
`description` and `at` are duplicated on the per-leg events
`AccountDebited` and `AccountCredited`, and the account ledger /
balance-as-of-date projection reads `e.at` directly from those leg
events
([`src/Application/ReadModels/Account.hs:562-568`](../../src/Application/ReadModels/Account.hs)).
Adding edit events on the TX aggregate alone would leave the ledger
stale. The duplication also disagrees with the convention used for
labels and category, which live only on the TX aggregate.

This spec aligns the codebase with the standard accounting-system
pattern: **posting facts are immutable on the leg events; metadata is
amendable on the TX aggregate; the ledger reads postings from the legs
and metadata from the TX aggregate via join.**

## Goals

1. Users can edit `description` and `at` on a `Completed` transaction
   through dedicated HTTP endpoints.
2. The account ledger view and balance-as-of-date projection reflect the
   edited description and date without replaying historical leg events.
3. The per-leg events (`AccountDebited`, `AccountCredited`) cease to be
   read for description / business date — they retain those fields only
   as immutable historical breadcrumb (see §5 for the migration shape).
4. A per-user "books closed through" cutoff date gates date edits and
   backdated creation: nothing can land or move into a closed period.
5. Existing event payloads on disk continue to deserialise (no event-log
   rewrite).

## Non-Goals

- Editing `amount`, source / target accounts, `currency`, `exchangeRate`,
  or `transferType`. These are posting facts; correction goes through
  reversing entries — separate spec.
- Multi-period close, approval workflows, or "reopen period" commands —
  the cutoff is a single user-settable date.
- A separate audit-log aggregate; the TX event stream is the audit log.
- Editing `description` / `at` on `Pending` or `Failed` transactions —
  rejected, matching the labels / category convention.
- UI / client work — backend only.
- Re-deriving exchange rates or revaluing past balances if `at` moves
  across a rate-change boundary; the recorded `sourceAmount` /
  `targetAmount` are the posting facts and are unaffected.

## Design

### 1. Domain types

No new id or value types are introduced. A new field on the user-scoped
configuration aggregate carries the close cutoff:

```haskell
-- Domain.Configuration.Projection.Configuration gains:
booksClosedThrough :: Maybe UTCTime
```

Semantics: if `Just t`, then any business date `at <= t` is considered a
closed period. `Nothing` (the default for existing users) means no
closure — equivalent to "books open from the beginning of time".

### 2. Configuration aggregate

#### 2.1 New command and event

```haskell
-- Domain.Configuration.Commands
data CloseBooksThrough = CloseBooksThrough
  { closedThrough :: UTCTime
  }

-- Domain.Configuration.Events
newtype BooksClosedThroughSet = BooksClosedThroughSet
  { closedThrough :: UTCTime
  }
```

`CloseBooksThrough` may only **advance** the cutoff; rewinding it
(setting an earlier or equal date than the current value) is rejected
with `CannotRewindBooksCloseDate`. Books may be closed for the first
time at any past date.

A separate `ReopenBooksThrough` command is deliberately out of scope —
real accounting workflows treat reopening as an exceptional operation
requiring approval; we defer it rather than provide a footgun.

#### 2.2 Projection / read model

`booksClosedThrough` is added to `Configuration` and folded by the new
event. The configuration read model surfaces the value on the existing
`GET /api/users/me/configuration` response under a new
`booksClosedThrough :: Maybe UTCTime` field. No new endpoint for
fetching it; the existing config endpoint is the authoritative read.

#### 2.3 HTTP

```
PUT /api/users/me/configuration/books-close
  body: { closedThrough :: UTCTime }
  -> 200 ConfigurationResponse
```

### 3. Transaction aggregate

#### 3.1 New commands

```haskell
-- Domain.Transaction.Commands
data ChangeTransactionDescription = ChangeTransactionDescription
  { transactionId  :: TransactionId
  , newDescription :: Text
  }

data ChangeTransactionDate = ChangeTransactionDate
  { transactionId :: TransactionId
  , newAt         :: UTCTime
  }
```

Both are accepted only when the aggregate is in `Completed`. In any
other state the command handler returns
`CannotEditCompletedTransactionMetadata` (a reuse / rename of the
existing `CannotEditTransactionLabelsInCurrentState`-shaped error;
see §6).

`ChangeTransactionDescription` has no further domain pre-conditions —
the new description follows the same length / non-empty rules already
applied at the web edge for creation.

`ChangeTransactionDate` is additionally rejected when **either** the
old `at` **or** the new `at` falls within a closed period, returning
`CannotEditClosedPeriod`. Both endpoints are checked because moving a
transaction out of a closed period is just as much a rewrite of closed
books as moving one in.

Books-close enforcement on `ChangeTransactionDate` runs at the **service
layer** (it requires the user's configuration, not in scope for the
pure command handler). The pure handler only enforces the
`Completed`-state rule.

#### 3.2 New events

```haskell
-- Domain.Transaction.Events
data TransactionDescriptionChanged = TransactionDescriptionChanged
  { transactionId  :: TransactionId
  , newDescription :: Text
  }

data TransactionDateChanged = TransactionDateChanged
  { transactionId :: TransactionId
  , newAt         :: UTCTime
  }
```

Replace-value semantics: each event carries the full new value.
Timestamps live in the Eventium envelope (`occurredAt`); the actor is
not recorded on these events — same convention as
`TransactionLabelsSet` / `TransactionCategoryChanged`.

#### 3.3 Projection

`Transaction` already carries `description :: Text`. A new field is
added:

```haskell
at :: UTCTime
```

Fold rules:

- `TransferInitiated` → initialise `at` from the event (existing event
  already carries it). Existing initialisation of `description` is
  unchanged.
- `TransactionDescriptionChanged` → replace `description`.
- `TransactionDateChanged` → replace `at`.
- `TransferCompleted` / `TransferFailed` / `TransactionLabelsSet` /
  `TransactionCategoryChanged` → unchanged.

The lifecycle state machine (`Pending → Completed | Failed`) is
unchanged.

#### 3.4 Process manager

`Application.ProcessManagers.TransferManager` is unchanged. Metadata
edits do not move money and do not feed the saga.

### 4. Account aggregate and ledger projection

#### 4.1 Leg events — payload slimming

`AccountDebited` and `AccountCredited` payloads contain `description`
and `at` today. Going forward they are no longer **read** by any
projection.

We keep the fields in the on-disk payload for now (do not rewrite the
event log) but mark them deprecated in the module docstring:

```haskell
data AccountDebited = AccountDebited
  { amount        :: Money
  , transactionId :: TransactionId
  -- | DEPRECATED — historical breadcrumb only. Authoritative
  --   description lives on the Transaction aggregate. Will be removed
  --   in a later spec.
  , description   :: Text
  -- | DEPRECATED — see `description`.
  , at            :: UTCTime
  }
```

The `DebitAccount` / `CreditAccount` commands continue to carry both
fields so the TransferManager can emit a complete-by-current-shape
event payload. A follow-up spec will drop them entirely after a
quiescence window; this spec deliberately limits the structural blast
radius.

#### 4.2 Account read model — metadata join

`Application.ReadModels.Account` exposes account activity / balance and
today reads `e.description` / `e.at` from the leg events. After this
spec, the ledger view computes a `TransactionMetadata` value by joining
to the **transaction read model** by `transactionId`:

```haskell
data LedgerEntry = LedgerEntry
  { transactionId :: TransactionId
  , delta         :: Money           -- +credit / -debit
  , description   :: Text            -- joined from TX read model
  , at            :: UTCTime         -- joined from TX read model
  , transferType  :: TransferType    -- joined
  , labels        :: Set LabelId     -- joined
  }
```

Implementation note: both read models are in-memory `TVar`s. The
account-side query function takes the transaction read model handle as
an argument and resolves metadata at query time. We do **not**
denormalise the joined fields into the account read model — that would
reintroduce duplication and a propagation problem on edits.

#### 4.3 Balance-as-of-date

`balanceAsOf` currently folds debit / credit deltas where
`e.at <= cutoff`. After this spec:

1. Build the set of `(transactionId, delta)` pairs from leg events on
   the account stream.
2. For each pair, look up `at` from the transaction read model.
3. Include pairs where `tx.at <= cutoff`.

This makes the historical balance reflect the **current** business
date, which is the correct accounting semantics: if a user moves a
transaction from March to February, the as-of-February-28 balance
should change accordingly. The leg event's now-deprecated `at` is not
consulted.

#### 4.4 Period reports

Any report that groups by month / year (currently sourced from `e.at`
on the leg events) is updated by the same join. No new module is
introduced.

### 5. Migration / event-log compatibility

- **Reads of existing leg events** continue to work — `description` and
  `at` remain in the payload and the `FromJSON` instance is unchanged.
- **The ledger projection stops consulting** those fields. Replaying
  the full event log against the new projection code yields exactly the
  same `LedgerEntry` values as before (TX `at` equals leg `at` at
  initiation time, before any date edits exist).
- **Existing transactions** start life with `Transaction.at` populated
  by the existing `TransferInitiated.at` field; no backfill required.
- **`booksClosedThrough`** defaults to `Nothing` for all existing users;
  no migration required.

A later spec will remove `description` / `at` from `AccountDebited` /
`AccountCredited` entirely (payload slimming) — that is deliberately
deferred so this change is observable-behaviour-preserving on replay.

### 6. Web API

#### 6.1 New transaction edit endpoints

```
PUT /api/transactions/:id/description
  body: { description :: Text }
  -> 200 TransactionResponse

PUT /api/transactions/:id/date
  body: { at :: UTCTime }
  -> 200 TransactionResponse
```

Auth: `AuthProtect "jwt"`. Authorization: the authenticated user must
have at least `Editor` on either the source or the target account —
same rule as the existing labels / category edit endpoints.

#### 6.2 New configuration endpoint

```
PUT /api/users/me/configuration/books-close
  body: { closedThrough :: UTCTime }
  -> 200 ConfigurationResponse
```

#### 6.3 Response DTO additions

`TransactionResponse` already includes `description` and `at`; the new
events feed directly into the existing transaction read model so no
shape change is needed beyond ensuring those fields are sourced from
the `Transaction` aggregate, not from leg events. The read model
already keys on `transactionId` and is updated by
`TransferInitiatedEvent` — additionally handle the two new events to
mutate `description` / `at` in place.

`ConfigurationResponse` gains:

```haskell
booksClosedThrough :: Maybe UTCTime
```

#### 6.4 Error mapping

New `DomainError` constructors in `Domain.Core.Errors`:

- `CannotEditCompletedTransactionMetadata` — generalisation of the
  existing `CannotEditTransactionLabelsInCurrentState`. The labels /
  category handlers also switch to this name; the constructor name
  better reflects the scope after this spec. Web error mapping
  preserves the existing 409 mapping.
- `CannotEditClosedPeriod { current :: UTCTime, attempted :: UTCTime }`
  — 409, returned by date edits or backdated creation that lands on or
  before the cutoff.
- `CannotRewindBooksCloseDate { current :: UTCTime, attempted :: UTCTime }`
  — 409, returned by `CloseBooksThrough` rewind attempts.

| HTTP | DomainError                                       | When                                                 |
| ---- | ------------------------------------------------- | ---------------------------------------------------- |
| 400  | `ValidationErr`                                   | Malformed body                                       |
| 403  | `AccessDenied`                                    | User lacks access to the transaction                 |
| 404  | `TransactionNotFound`                             | Unknown id                                           |
| 409  | `CannotEditCompletedTransactionMetadata`          | Transaction not `Completed`                          |
| 409  | `CannotEditClosedPeriod`                          | Edit affects a closed period                         |
| 409  | `CannotRewindBooksCloseDate`                      | `CloseBooksThrough` would rewind the cutoff          |

#### 6.5 Backdated creation revisited

`InitiateTransfer` already accepts a user-supplied `at`. After this
spec, creation is **also** gated by `booksClosedThrough`: creating a
transaction with `at <= closedThrough` returns
`CannotEditClosedPeriod`. This closes the only remaining route to
write into a closed period.

### 7. Testing

Follows the three-tier pattern (unit + property + integration) and TDD
ordering.

**Domain layer:**

- `test/Domain/Transaction/CommandHandlerSpec.hs` —
  `ChangeTransactionDescription` / `ChangeTransactionDate` accepted in
  `Completed`, rejected in `Pending` / `Failed`. Description content
  rules.
- `test/Domain/Transaction/ProjectionSpec.hs` — folding sequences of
  `TransactionDescriptionChanged` / `TransactionDateChanged` yields
  the expected `description` / `at`.
- `test/Domain/Transaction/PropertySpec.hs` — for any sequence of
  description / date edits, the final projection equals the last
  event's value.
- `test/Domain/Configuration/CommandHandlerSpec.hs` —
  `CloseBooksThrough` advances but cannot rewind; `BooksClosedThroughSet`
  fold sets the value.

**Application layer:**

- `test/Application/Services/TransactionServiceSpec.hs` —
  `changeTransactionDescription` / `changeTransactionDate` orchestrate
  the auth check, the books-close check (date only), and command
  dispatch. Books-close cases:
  (a) new `at` in closed period → reject,
  (b) current `at` in closed period, new `at` outside → reject,
  (c) both outside → accept.
- `test/Application/Services/ConfigurationServiceSpec.hs` —
  `closeBooksThrough` accepts a forward move, rejects rewind, and the
  configuration read model reflects the new value.
- `test/Application/Services/TransactionServiceSpec.hs` — backdated
  `InitiateTransfer` past the close cutoff is rejected.

**Read-model join (account ledger):**

- `test/Application/ReadModels/AccountSpec.hs` — `LedgerEntry`
  description and `at` reflect the **current** transaction aggregate
  value after an edit; balance-as-of-date moves with date edits.
- A property test asserts the structural invariant:
  `forall events. ledgerEntries account ≡ ledgerEntries account` is
  insensitive to the leg event's deprecated `description` / `at`
  fields (achieved by perturbing those fields in a copy of the event
  stream and observing identical output).

**Integration:**

- `test/Integration/TransactionMetadataEditIntegrationSpec.hs` —
  end-to-end: create transfer → edit description → edit date → list
  transactions returns latest values → account activity reflects the
  new description and date → balance-as-of-date moves correctly when
  the edited date crosses a month boundary.
- `test/Integration/BooksClosePeriodIntegrationSpec.hs` —
  end-to-end: close books at date D → attempt to backdate a new
  creation to D-1 (expect 409) → attempt to edit an existing
  transaction's date to D-1 (expect 409) → advance close to D+30 →
  attempt to rewind to D (expect 409) → attempt to edit a transaction
  whose current `at <= D` (expect 409, even when target is outside).

**Web layer:**

- `test/Web/API/TransactionAPISpec.hs` — happy + rejection paths for
  `PUT /:id/description` and `PUT /:id/date` (200, 400, 403, 404, 409).
- `test/Web/API/ConfigurationAPISpec.hs` — `PUT /books-close` happy and
  rewind-rejection paths; `GET /configuration` exposes the new field.

**LiquidHaskell:** no new refinement files; `UTCTime` and `Text`
inherit existing refinements (where present).

## Cross-Cutting Concerns

**Event-log compatibility.** No event payload is removed or modified.
`AccountDebited` / `AccountCredited` retain `description` and `at` —
they simply become unread by projections. Replaying the existing log
against new projection code yields identical balances and ledger
descriptions, because every transaction's TX-aggregate `at` and
`description` equal the leg event's at initiation time.

**Backwards compatibility.** `TransactionResponse` shape is unchanged.
`ConfigurationResponse` gains an optional `booksClosedThrough` field;
clients that ignore unknown fields continue to work. The renamed
`DomainError` constructor (`CannotEditCompletedTransactionMetadata`,
ex-`CannotEditTransactionLabelsInCurrentState`) maps to the same HTTP
status code and response shape — only the symbolic name changes.

**Forward compatibility.** A later spec can drop `description` / `at`
from the leg event payloads. Because nothing reads them after this
spec, removal is a straightforward `FromJSON`-defaulted-to-empty change
on read and field deletion on write.

**Performance.** The ledger join is `transactionId → TransactionData`
in the in-memory transaction read model — `O(1)` lookup per leg entry.
Balance-as-of-date is `O(n)` over leg events on the account stream with
an `O(1)` join per event; the asymptotic shape is unchanged from
today's `O(n)` direct fold.

**Determinism.** Edit events use replace-value semantics; the latest
event wins regardless of arrival order within a `Completed` state.

**Audit trail.** The full edit history is the TX aggregate's event
stream: every description and date a transaction ever held is
recoverable by replay. Combined with Eventium's envelope `occurredAt`
and (where available) the issuing user from request context, this is
the audit log — no separate change-log aggregate is needed.

**Period close as a safety rail.** The close cutoff is intentionally
minimal — a single `Maybe UTCTime` per user, advance-only, no
multi-period model, no per-account scope. This matches the YAGNI
posture of the rest of the codebase; a richer model (reopen with
approval, multiple closed periods, per-fiscal-year close) can be added
without breaking the data shape.
