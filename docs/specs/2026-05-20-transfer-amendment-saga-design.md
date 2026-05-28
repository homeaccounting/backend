---
status: completed
date: 2026-05-20
issue: homeaccounting/backend#81
depends_on:
  - 2026-05-20-editable-transaction-metadata-design.md
---

# Transfer Amendment Saga (Editable Amount and Source/Target Accounts)

## Problem

After
[`2026-05-20-editable-transaction-metadata-design.md`](2026-05-20-editable-transaction-metadata-design.md)
lands, completed transactions are editable for `description`, `at`,
`category`, and `labels`. The remaining edit gap is the **posting
facts** — `sourceAmount`, `targetAmount`, `exchangeRate`,
`sourceAccountId`, and `targetAccountId`. An accounting (not banking)
application must allow correcting these after the fact: wrong account
picked, wrong amount entered, wrong currency rate.

`transferType` is *not* amendable: it is structurally determined by
the source / target accounts' `AccountType` (Regular vs External), so
the amendment endpoint preserves it by construction. Recategorising
across the internal/external boundary is a delete-and-repost
operation. See §3.5.

The metadata-edit spec deliberately locked the per-leg events
(`AccountDebited`, `AccountCredited`) as immutable posting facts.
Editing amount or accounts in place would either rewrite history (a
non-starter for an event-sourced ledger) or break the
immutable-postings invariant we just established.

The standard accounting-system resolution is **reversing entries**:
posting facts stay immutable; corrections are expressed as
counter-postings on the original accounts plus fresh postings on the
new accounts. This spec implements that pattern as a process manager
(saga) that orchestrates the cross-aggregate work and emits a single
`TransferAmendmentCompleted` event on the TX aggregate to update the canonical
amount and accounts.

## Goals

1. Users can correct a completed transaction's amount, source / target
   accounts, and exchange rate through a single edit endpoint.
   `transferType` is preserved by construction (see §3.5).
2. The original `TransferInitiated` event and all original leg events
   remain unmodified — the amendment appears as additional events in
   the stream, never as overwrites.
3. The account ledger view (default, net-collapsed) reflects the
   amended values; a separate audit endpoint exposes the full event
   history per transaction.
4. Reversing entries always succeed: they undo a prior fact and may
   take a Regular account negative without an overdraft check.
5. Insufficient funds on the **new** source account is the only failure
   mode; on rejection the original transfer is left intact (no partial
   amend lands).
6. Amend is gated by the books-close cutoff (spec #80) on both the old
   and the new business dates.
7. Existing event payloads on disk continue to deserialise unchanged.

## Non-Goals

- Voiding / cancelling a transaction. A degenerate case of amend with
  no new postings — separate spec.
- Splitting one transaction into multiple, or merging multiple into one.
- Bulk amendment endpoints.
- Editing `description` / `at` via the amendment endpoint — those
  remain on their own endpoints (spec #80). An amendment may
  legitimately also change them, but if so the client should issue
  the dedicated edit commands; this spec keeps `AmendTransfer`
  focused on posting facts.
- Per-leg amendments (e.g., "change only the source account, leave the
  amount alone"). The amendment endpoint is treated as a full
  replacement of the posting facts — the client supplies the complete
  desired end-state. Idempotency falls out: re-submitting the same
  amend produces no new events (see §4.3).
- A UI for browsing the amendment audit chain.
- Approval workflows or per-role amendment limits.

## Design

### 1. Domain types

No new id or value types. The TX aggregate gains a single new field
during amendment:

```haskell
-- Domain.Transaction.Projection.Transaction is extended with:
amendmentCount :: Word
-- Count of TransferAmendmentCompleted events folded so far. Exposed
-- on TransactionResponse so clients can detect amendments and decide
-- whether to fetch the audit history. Always 0 for a transaction
-- that has never been amended.
```

### 2. Account aggregate — reversing-entry events

#### 2.1 New events

```haskell
-- Domain.Account.Events
data AccountDebitReversed = AccountDebitReversed
  { amount        :: Money         -- positive; reverses a prior debit
  , transactionId :: TransactionId -- correlation with the original debit
  , at            :: UTCTime       -- TX aggregate's current business date
  }

data AccountCreditReversed = AccountCreditReversed
  { amount        :: Money         -- positive; reverses a prior credit
  , transactionId :: TransactionId -- correlation with the original credit
  , at            :: UTCTime
  }
```

Both events are **guaranteed-success**: the account command handler
emits them unconditionally. Specifically:

- `AccountDebitReversed` adds the recorded amount back to the account
  balance (undoes a prior debit).
- `AccountCreditReversed` subtracts the recorded amount from the
  account balance (undoes a prior credit).
- Neither event consults the overdraft limit. A Regular account
  receiving an `AccountCreditReversed` may go negative; that negative
  state is the truthful representation of the user having spent money
  they were never legitimately credited.

Both events carry the **current TX-aggregate `at`** (post any date
edits), not the original leg's `at`. This is consistent with the
metadata-join model from spec #80: the ledger's business-date axis
follows the TX aggregate.

#### 2.2 New commands

```haskell
-- Domain.Account.Commands
data ReverseAccountDebit = ReverseAccountDebit
  { amount        :: Money
  , transactionId :: TransactionId
  , at            :: UTCTime
  }

data ReverseAccountCredit = ReverseAccountCredit
  { amount        :: Money
  , transactionId :: TransactionId
  , at            :: UTCTime
  }
```

Issued **exclusively** by the `TransferAmendmentManager` process
manager. Not exposed via any HTTP endpoint. The command handler
accepts them unconditionally (subject to the account existing) and
emits the corresponding event.

#### 2.3 Account projection / read model

The account aggregate's balance fold gains two cases:

```haskell
handleAccountEvent acc (AccountDebitReversedEvent e)  = acc { balance = balance acc + e.amount }
handleAccountEvent acc (AccountCreditReversedEvent e) = acc { balance = balance acc - e.amount }
```

No overdraft check on the fold. The account aggregate has no way to
refuse a reversal — by the time the event is in the stream, the
reversal is a recorded fact.

The account read model gains symmetric handlers for the two new events.

### 3. Transaction aggregate

#### 3.1 New commands

```haskell
-- Domain.Transaction.Commands
data AmendTransfer = AmendTransfer
  { transactionId        :: TransactionId
  , newSourceAccountId   :: AccountId
  , newTargetAccountId   :: AccountId
  , newSourceAmount      :: Money
  , newTargetAmount      :: Money
  , newExchangeRate      :: Maybe ExchangeRate
  , amendedBy            :: UserId
  }
```

Accepted only in `Completed`. The new accounts may equal the old
accounts (the common "edit amount only" case); the amount may equal
the existing amount (the saga still validates and produces a no-op,
see §4.3).

Rejection cases (in the pure handler):

- `CannotEditCompletedTransactionMetadata` — TX is not `Completed`.
- `CannotAmendToSameAccountPair` — `newSourceAccountId == newTargetAccountId`.
- `CannotAmendToZeroAmount` — `newSourceAmount` is zero, or
  `newTargetAmount` is zero.
- `CannotAmendAcrossAccountType` — at least one leg's new account has a
  different `AccountType` (Regular vs External) from the original; see
  §3.5. Surfaced from the service layer, not the pure handler.

The books-close gate and the auth check are enforced at the **service
layer**, not in the pure handler:

- `CannotEditClosedPeriod` (already from spec #80) — current TX `at` or
  any of the four affected leg events would land on or before the
  cutoff. Since reversing and forward leg events all carry the current
  TX `at`, this is a single check against `transaction.at`.
- Editor+ on the old source, old target, new source, and new target.

#### 3.2 New events

```haskell
-- Domain.Transaction.Events
data TransferAmendmentInitiated = TransferAmendmentInitiated
  { transactionId        :: TransactionId
  , newSourceAccountId   :: AccountId
  , newTargetAccountId   :: AccountId
  , newSourceAmount      :: Money
  , newTargetAmount      :: Money
  , newExchangeRate      :: Maybe ExchangeRate
  , amendedBy            :: UserId
  }

data TransferAmendmentCompleted = TransferAmendmentCompleted
  { transactionId        :: TransactionId
  , newSourceAccountId   :: AccountId
  , newTargetAccountId   :: AccountId
  , newSourceAmount      :: Money
  , newTargetAmount      :: Money
  , newExchangeRate      :: Maybe ExchangeRate
  , amendedBy            :: UserId
  }

newtype TransferAmendmentFailed = TransferAmendmentFailed
  { reason :: Text
  }
```

`transferType` is intentionally absent from the amendment events: it is
a function of the source / target accounts' `AccountType` (Regular vs
External) and is preserved across amendments by service-layer
validation (§3.5). Recategorising across the internal/external
boundary is a delete-and-repost operation; editing the category in
place on an Income / Expense uses the existing
`PUT /api/transactions/:id/category` endpoint.

`TransferAmendmentInitiated` is the saga-trigger marker emitted when
the `AmendTransfer` command is accepted. `TransferAmendmentCompleted`
is emitted only after the saga's reversing + forward legs have all
landed (see §4.1) and carries the same payload, replayed from the
saga's tracked state so the event itself is self-contained.
`TransferAmendmentFailed` is emitted when the saga's only fallible
step rejects.

Replace-value semantics on the TX aggregate: each
`TransferAmendmentCompleted` event sets the canonical amount /
accounts / exchange rate to the new values. `transferType` is
unchanged — see §3.5. The original values remain recoverable from
`TransferInitiated`, and intermediate amendments from prior
`TransferAmendmentCompleted` events.

#### 3.3 Projection

```haskell
handleTransactionEvent tx (TransferAmendmentInitiatedTransactionEvent _) =
  tx  -- no canonical state change; saga-internal marker
handleTransactionEvent tx (TransferAmendmentCompletedTransactionEvent e) =
  -- transferType is preserved across amendments (see §3.5).
  tx & #sourceAccountId .~ e.newSourceAccountId
     & #targetAccountId .~ e.newTargetAccountId
     & #sourceAmount    .~ e.newSourceAmount
     & #targetAmount    .~ e.newTargetAmount
     & #exchangeRate    .~ e.newExchangeRate
     & #amendmentCount  %~ (+ 1)
handleTransactionEvent tx (TransferAmendmentFailedTransactionEvent _) =
  tx  -- no state change; failure is informational
```

The lifecycle state (`Pending` / `Completed` / `Failed`) is unchanged
by these events. Amendment is permitted only in `Completed`; the
command handler enforces this and the projection trusts well-formed
streams.

#### 3.4 Interaction with labels / category / description / date edits

All four metadata edits (from spec #80 and the labels spec) remain on
their own dedicated events and endpoints. `TransferAmendmentCompleted`
does not touch them. A transaction whose category was changed and then was
amended retains the latest category — the projection folds events in
order, each replacing only the fields it owns.

Changing `transferType` is **not** an amendment operation. The
classification of a transaction (Income, Expense, Transfer) is
determined by the `AccountType` pair of its legs:

| Source / Target          | transferType           |
| ------------------------ | ---------------------- |
| External → Regular       | `Income categoryId`    |
| Regular → External       | `Expense categoryId`   |
| Regular → Regular        | `Transfer`             |
| External → External      | *invalid*              |

Recategorising a transaction across this boundary (e.g. "I posted as
Income but it should have been Transfer") is a delete-and-repost
operation, matching standard accounting practice of reversing a
misclassified posting rather than editing it in place. Editing the
*category* in place on a Completed Income / Expense remains available
via `PUT /api/transactions/:id/category`.

`Adjustment` is reserved for balance-set reconciliations and is not a
valid `transferType` for amendable transactions.

#### 3.5 Account-type preservation

To keep `transferType` immutable across amendments, the service layer
enforces that each leg's `AccountType` (Regular vs External) is
preserved:

- An Income's External source must remain External (and Regular target
  must remain Regular); the user may swap the Regular target to a
  different Regular account.
- An Expense's Regular source must remain Regular (and External target
  must remain External); the user may swap the Regular source to a
  different Regular account.
- A Transfer's two Regular legs must both remain Regular; the user may
  swap either leg to a different Regular account.

A change in the `Regular` *subtype* (e.g. `Cash` → `BankAccount`) is
permitted — it does not affect `transferType`. Subtypes are a
user-facing classification of Regular accounts and do not enter the
posting algebra.

Mismatch (any leg's new account has a different `AccountType` from the
original's) returns `CannotAmendAcrossAccountType`.

### 4. Process manager: `TransferAmendmentManager`

A new process manager (a sibling to `TransferManager`) lives at
`Application.ProcessManagers.TransferAmendmentManager`. It reacts to
`TransferAmendmentInitiated` (see §4.4) on the TX stream and
orchestrates the four leg-event steps, emitting
`TransferAmendmentCompleted` on completion.

#### 4.1 Saga step sequence

The saga must produce, in order:

1. **`DebitAccount` on the new source** — the only fallible step.
   - On rejection (insufficient funds, account missing, etc.):
     emit `FailTransferAmendment` on the TX stream, which produces a
     `TransferAmendmentFailed` event. No other events. The original
     transfer is intact.
   - On acceptance: proceed to step 2.

2. **`ReverseAccountCredit` on the old target** — always succeeds.
   Argument: original `targetAmount`.

3. **`ReverseAccountDebit` on the old source** — always succeeds.
   Argument: original `sourceAmount`.

4. **`CreditAccount` on the new target** — always succeeds (credits
   never fail in this codebase).

5. **`CompleteTransferAmendment` on the TX stream** — produces
   `TransferAmendmentCompleted`. Amendment-count increments; canonical values
   updated.

#### 4.2 Collapsing legs when accounts are unchanged

When `newSourceAccountId == oldSourceAccountId` and
`newSourceAmount == oldSourceAmount`, steps 1 and 3 cancel out — the
saga emits **neither**. The same applies to steps 2 and 4 on the
target side. Possible cases:

| Amendment shape                          | Leg events emitted                                              |
| ---------------------------------------- | --------------------------------------------------------------- |
| Both amounts changed, accounts unchanged | net `DebitAccount` (delta) + net `CreditAccount` (delta) on existing accounts |
| Only target account changed              | `ReverseAccountCredit` old target + `CreditAccount` new target  |
| Only source account changed              | `ReverseAccountDebit` old source + `DebitAccount` new source    |
| Both accounts changed                    | full 4-event sequence                                           |
| Nothing changed (no-op amend)            | none — saga short-circuits, no `TransferAmendmentCompleted` event          |

The collapsing logic lives in a pure helper inside the saga's
`reactToTransferEvent` (compute the diff between current TX state and
the amend payload, derive the minimum leg-event set).

For the "both amounts changed, accounts unchanged" case, the saga
issues a **net delta debit/credit** rather than a reverse-plus-fresh
pair. If the new amount is *larger*, that's a `DebitAccount` for the
positive delta on the source (which **can** fail if the account lacks
funds for the increase — same handling as step 1). If the new amount
is *smaller*, that's a `ReverseAccountDebit` for the negative delta on
the source. Symmetric for the target.

#### 4.3 Idempotency / no-op amendment

If the amendment payload exactly matches the current TX state, the
saga's diff produces an empty set of leg events. The saga then emits
neither `TransferAmendmentCompleted` nor any leg events. The endpoint returns
`200 TransactionResponse` with the current state and
`amendmentCount` unchanged — a true no-op.

Edge case: if a client submits the same amendment twice in succession,
the first lands and updates the TX, the second submits values that
now match the (post-amend) current state — the second is a no-op.
This is the intended idempotency behaviour.

#### 4.4 Saga-trigger event

The saga is triggered by an intermediate event on the TX stream:

```haskell
data TransferAmendmentInitiated = TransferAmendmentInitiated
  { -- payload identical to AmendTransfer command
    newSourceAccountId :: AccountId
  , newTargetAccountId :: AccountId
  , newSourceAmount    :: Money
  , newTargetAmount    :: Money
  , newExchangeRate    :: Maybe ExchangeRate
  , amendedBy          :: UserId
  }
```

The flow becomes:

1. `AmendTransfer` command (HTTP-issued) → handler validates → emits
   `TransferAmendmentInitiated` on TX stream.
2. Process manager reacts to `TransferAmendmentInitiated` → issues leg
   commands per §4.1 / §4.2.
3. On the final leg's success → process manager issues
   `CompleteTransferAmendment` (internal command) → handler emits
   `TransferAmendmentCompleted` (the canonical-update event).
4. On step-1 rejection → process manager issues
   `FailTransferAmendment` → handler emits `TransferAmendmentFailed`.

This mirrors the existing `TransferInitiated` → saga →
`CompleteTransfer` → `TransferCompleted` shape — same pattern users of
the codebase already understand.

`TransferAmendmentInitiated` and `TransferAmendmentFailed` are saga-internal
markers; the TX aggregate's canonical state is moved only by
`TransferAmendmentCompleted`. Read models that present "current transaction state"
ignore the in-flight markers and key off `TransferInitiated` +
`TransferAmendmentCompleted`.

#### 4.5 Saga state

The amendment manager keeps per-amendment tracking in a `Map
TransactionId TransferAmendmentData`, analogous to `TransferManager`'s
`TransferData`. Tracking is cleared when `TransferAmendmentCompleted` (or
`TransferAmendmentFailed`) fires.

`TransferAmendmentData` captures:

```haskell
data TransferAmendmentData = TransferAmendmentData
  { oldSourceAccountId :: AccountId  -- snapshot at amend-start
  , oldTargetAccountId :: AccountId
  , oldSourceAmount    :: Money
  , oldTargetAmount    :: Money
  , newSourceAccountId :: AccountId
  , newTargetAccountId :: AccountId
  , newSourceAmount    :: Money
  , newTargetAmount    :: Money
  , newExchangeRate    :: Maybe ExchangeRate
  , amendedBy          :: UserId
  , phase              :: TransferAmendmentPhase
  }

data TransferAmendmentPhase
  = AwaitingDebitNewSource
  | DebitIssued
  | ReversingOldLegs
  | CreditingNewTarget
  | Completing
```

Snapshotting the old values at amend-start ensures the saga doesn't
race against another concurrent amendment on the same transaction —
the projection state captures what to reverse before the new amend's
own leg events change anything.

Concurrent amendments on the same transaction are serialised by the
TX aggregate's optimistic-concurrency check on
`(transactionUuid, version)`: a second amend on the same TX must wait
for the first amend's `TransferAmendmentCompleted` to land before its
`TransferAmendmentInitiated` can be appended.

### 5. Read models

#### 5.1 Account read model — net-collapsed ledger

The default account-history endpoint groups leg events by
`transactionId` and presents one `LedgerEntry` per transaction with
the net effect on this account:

```haskell
data LedgerEntry = LedgerEntry
  { transactionId :: TransactionId
  , delta         :: Money  -- net signed amount across all leg events
                            -- (regular + reversed) for this tx on this account
  , description   :: Text           -- joined from TX aggregate
  , at            :: UTCTime        -- joined from TX aggregate
  , transferType  :: TransferType   -- joined
  , labels        :: Set LabelId    -- joined
  , amendmentCount :: Word          -- joined; 0 = never amended
  }
```

Computation:

1. For each leg event in the account stream, accumulate into a
   per-`transactionId` running total: `+amount` for credits and
   reversed-debits, `-amount` for debits and reversed-credits.
2. Drop entries whose final delta is `0` (fully reversed transactions
   on this account — e.g., a transaction that was amended to move to a
   different account pair).
3. Join each remaining entry to the TX read model for metadata.

This collapses a transaction with several reversals + new-postings on
this account into a single row reflecting current net truth.

#### 5.2 Balance-as-of-date

`balanceAsOf` becomes:

1. Compute per-`transactionId` net delta on this account, including
   reversing entries. (Same `+`/`-` rule as §5.1.)
2. Join each `transactionId` to the TX read model's current `at`.
3. Sum deltas where `tx.at <= cutoff`.

A transaction's contribution to a past balance reflects its current
amended state — same accounting semantics already established by
spec #80.

#### 5.3 Transaction read model

The transaction read model's `TransactionData` gains the same fields
as the projection (`amendmentCount`) and grows new event handlers:

- `TransferAmendmentInitiated` — no-op (in-flight marker).
- `TransferAmendmentCompleted` — replace amount / accounts / exchange
  rate; increment `amendmentCount`. `transferType` is preserved.
- `TransferAmendmentFailed` — no-op (informational).

#### 5.4 Audit history

A new read-side service:

```haskell
getTransactionHistory ::
  TransactionId ->
  AppM (Maybe TransactionHistory)

data TransactionHistory = TransactionHistory
  { transactionId :: TransactionId
  , entries       :: [TransactionHistoryEntry]  -- chronological
  }

data TransactionHistoryEntry
  = HistoryInitiated TransferInitiated
  | HistoryAmended TransferAmendmentCompleted
  | HistoryAmendFailed TransferAmendmentFailed
  | HistoryCategoryChanged TransactionCategoryChanged
  | HistoryDescriptionChanged TransactionDescriptionChanged
  | HistoryDateChanged TransactionDateChanged
  | HistoryLabelsSet TransactionLabelsSet
  | HistoryCompleted
  | HistoryFailed Text
```

Backed by a direct event-store read (`getEventsForStream` /
equivalent), not by a cached projection — audit views are
low-frequency and need the canonical stream, not a denormalised
snapshot.

### 6. Web API

#### 6.1 Amendment endpoint

```
PUT /api/transactions/:id/amendment
  body: {
    sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount    :: Money,
    targetAmount    :: Money,
    exchangeRate    :: Maybe ExchangeRate
  }
  -> 200 TransactionResponse
```

`transferType` is intentionally absent from the body — it is a
function of the account-type pair and is preserved across amendments
(see §3.5).

Auth: `AuthProtect "jwt"`. Authorization: Editor+ on **all four** of
old source, old target, new source, new target. (Old accounts looked
up from the transaction's current state.)

Synchronous response semantics: the endpoint blocks until the saga
emits either `TransferAmendmentCompleted` or `TransferAmendmentFailed`. Same shape
as creation's wait-for-saga pattern.

#### 6.2 Audit endpoint

```
GET /api/transactions/:id/history
  -> 200 { transactionId, entries: [...] }
```

Auth: same access rule as transaction read (Editor or Viewer on at
least one of the current source/target accounts).

#### 6.3 `TransactionResponse` additions

```haskell
amendmentCount :: Word  -- 0 = never amended
```

No removal or breaking change to existing fields.

#### 6.4 Error mapping

| HTTP | DomainError                                       | When                                                 |
| ---- | ------------------------------------------------- | ---------------------------------------------------- |
| 400  | `ValidationErr`                                   | Malformed body, zero amount, same-account pair       |
| 403  | `AccessDenied`                                    | User lacks Editor+ on any of the four accounts       |
| 404  | `TransactionNotFound`                             | Unknown id                                           |
| 404  | `AccountNotFound`                                 | Unknown new account id                               |
| 409  | `CannotEditCompletedTransactionMetadata`          | Transaction not `Completed`                          |
| 409  | `CannotEditClosedPeriod`                          | TX's current `at` is in a closed period              |
| 409  | `CannotAmendToSameAccountPair`                    | newSource == newTarget                               |
| 409  | `CannotAmendToZeroAmount`                         | Either new amount is zero                            |
| 409  | `CannotAmendAcrossAccountType`                    | A leg's new account has a different AccountType      |
| 409  | `InsufficientFundsForAmendment`                   | New source rejected the debit (saga failure)         |

`InsufficientFundsForAmendment` is the HTTP response when the
synchronous wait observes `TransferAmendmentFailed`. The body carries the
original rejection reason.

### 7. Testing

Three-tier pattern (unit + property + integration), TDD ordering.

**Domain layer (Transaction):**

- `test/Domain/Transaction/CommandHandlerSpec.hs` — `AmendTransfer`
  accepted in `Completed`; rejected in `Pending` / `Failed`; rejected
  on same-account pair and zero amount. Account-type preservation is
  service-layer (§3.5), not pure-handler.
- `test/Domain/Transaction/ProjectionSpec.hs` — `TransferAmendmentCompleted` event
  replaces amount / accounts / exchange rate and bumps amendmentCount;
  `transferType` is unchanged; `TransferAmendmentFailed` and
  `TransferAmendmentInitiated` are no-ops on the canonical projection.
- `test/Domain/Transaction/PropertySpec.hs` — for any sequence of
  `TransferAmendmentCompleted` events, the final projection equals the last
  event's payload; amendmentCount equals the number of `TransferAmendmentCompleted`
  events.

**Domain layer (Account):**

- `test/Domain/Account/CommandHandlerSpec.hs` — `ReverseAccountDebit`
  / `ReverseAccountCredit` are accepted unconditionally (no overdraft
  check, allowed on negative balances).
- `test/Domain/Account/ProjectionSpec.hs` — folding reversal events
  symmetrically inverts the corresponding debit/credit; balance can
  go arbitrarily negative.
- `test/Domain/Account/PropertySpec.hs` —
  `forall amount tx at acc. fold [Debited, DebitReversed] acc == acc`
  (and symmetric for credit). Pair-cancellation property.

**Process manager:**

- `test/Application/ProcessManagers/TransferAmendmentManagerSpec.hs` —
  saga emits the correct minimal leg-event set for each of the five
  cases in §4.2's table; collapses identity amends to no events;
  emits `TransferAmendmentFailed` and no leg events when new source
  rejects.
- Concurrent-amend property: two amendments on the same TX serialise
  via optimistic concurrency; the second observes the first's amended
  state as `old*` and reverses accordingly.

**Application services:**

- `test/Application/Services/TransactionAmendmentSpec.hs` — amendment
  orchestration: auth check on four accounts, books-close check,
  account-type preservation (Regular subtype changes pass; flips
  across the Regular/External boundary reject with
  `CannotAmendAcrossAccountType`), end-to-end success / failure paths.

**Read-model:**

- `test/Application/ReadModels/AccountSpec.hs` — net-collapsed ledger:
  after one amend, the account stream's leg events collapse to a
  single `LedgerEntry` per transaction with the amended net delta;
  fully-reversed transactions on this account are dropped from the
  result.
- Balance-as-of-date property: amending a transaction's amount shifts
  the as-of-date balance by the delta for all dates ≥ `tx.at`.
- `test/Application/ReadModels/TransactionSpec.hs` —
  `amendmentCount` reflects the number of folded `TransferAmendmentCompleted`
  events.

**Integration:**

- `test/Integration/TransferAmendmentIntegrationSpec.hs` —
  end-to-end across all amendment shapes:
  - amount-only amend (collapsed delta legs)
  - source-account-only amend
  - target-account-only amend
  - both-accounts amend (full 4-leg saga)
  - identity amend (no-op response, count unchanged)
  - amend that flips an account's AccountType across the
    Regular/External boundary (409 `CannotAmendAcrossAccountType`)
  - amend on Pending / Failed transaction (409)
  - amend with insufficient funds on new source (409,
    `TransferAmendmentFailed` recorded)
  - amend whose TX `at` is in a closed period (409)
  - audit endpoint returns the complete event history including
    reversals and amendments.
- Reversal-on-spent-target scenario: target had been credited $100,
  then spent $80 (other transfer), then this transfer is amended to a
  different target. Verify the old target's balance goes to -$80 (the
  spent portion is now unbacked, accurately reflected).

**LiquidHaskell:** the existing `Money` and `AccountId` refinements
cover the new event payloads. The reversal-event handlers in the
account projection need explicit invariants documenting that they
bypass the `balance + overdraftLimit >= 0` post-condition that
applies to regular debits.

## Cross-Cutting Concerns

**Event-log compatibility.** Pure additions. No existing event payload
is modified. The two new account events and three new transaction
events use Template Haskell to register with the existing sum types;
old events deserialise unchanged.

**Backwards compatibility.** `TransactionResponse` gains the new
`amendmentCount` field; clients that ignore unknown fields are
unaffected. New endpoints are additive. Existing endpoints
(`PUT /labels`, `PUT /category`, `PUT /description`, `PUT /date`)
continue to operate without amendment-related awareness.

**Forward compatibility.** A `TransferVoided` command (out of scope
here) can be added later as a degenerate amendment: emit reversal
events on both legs, emit `TransferVoided` on the TX stream. The
account read-model collapsing rule (drop transactions with net delta
0 on this account) already handles voided transactions correctly.

**Performance.** Saga adds ~4 events per amendment. Personal-accounting
volumes (a few amendments per user per month at most) make this a
non-issue. Net-collapsing the account ledger is `O(n)` per account
stream — same asymptotic shape as the current fold; the additional
factor is the per-`transactionId` `Map` for collapse, which is
constant relative to amendment frequency.

**Audit semantics.** Reversal events carry the current TX `at`, not
the original leg's `at`. Combined with Eventium's envelope
`occurredAt` (system time), this gives:

- Business-date axis (`at`): when did the transaction logically occur
  (current best understanding, after corrections).
- System-time axis (envelope `occurredAt`): when was each correction
  recorded.

Both axes are recoverable from the event stream; both are exposed
via the audit endpoint.

**Concurrency.** Amendments on the same TX serialise via the existing
optimistic-concurrency check on `(uuid, version)` of the transaction
aggregate. Concurrent amendments on **different** TXs are
independent — each amends its own TX stream and its own (possibly
overlapping) account streams. The account aggregate's
optimistic-concurrency check handles ordering of overlapping leg
events.

**Domain consistency — reversing entries and overdraft.** The new
reversal events deliberately bypass the overdraft check. This is a
correctness property, not a relaxation: a reversal records the
undoing of a prior fact, and refusing it would mean the books no
longer reflect reality. The user-visible consequence — an account
showing a negative balance after a reversal of a credit they already
spent — is the correct accounting representation. The product UI can
surface this state prominently (e.g., a warning banner), but the
domain has no business refusing the truth.

**Saga failure containment.** Only step 1 (debit new source) can fail.
On rejection, the saga emits `TransferAmendmentFailed` and no leg events
have been written. The original transfer is bit-for-bit intact: the
projection ignores `TransferAmendmentInitiated` and `TransferAmendmentFailed`
for canonical state. The amendment endpoint returns a 409 with the
rejection reason; the client may retry with a different amend.
