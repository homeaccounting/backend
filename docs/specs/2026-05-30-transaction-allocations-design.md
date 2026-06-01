---
status: draft
date: 2026-05-30
issue: homeaccounting/backend#89
depends_on:
  - 2026-05-20-transfer-amendment-saga-design.md
---

# Transaction Allocations (Multi-Category Splits)

## Problem

Today every `Income` or `Expense` transaction carries exactly one
`CategoryId` (embedded in `TransferType`). When a real-world purchase
spans multiple categories — the canonical example is a 1000 UAH
supermarket trip that is 200 UAH groceries and 800 UAH housekeeping —
the user is forced to record it as two separate transactions.

That workaround is acceptable for manual entry, but it breaks down for
**bank import** (planned in
[`2026-04-10-bank-integration-design.md`](2026-04-10-bank-integration-design.md)):
the bank reports a single line, the system imports a single line, and
the user has no way to retroactively split it across categories without
deleting and re-posting. The category breakdown is currently a
domain-level fiction: real receipts mix categories; the model insists
they don't.

This spec promotes the category side of a transaction from a single
`CategoryId` to a **`Allocations`** (= `NonEmpty Allocation`) — a list of
`(CategoryId, Money)` slices whose amounts sum to the categorised
total. The bank line stays one transaction with one balance impact; the
user can later split it into N category slices via a dedicated edit
command. Single-category transactions become the degenerate
length-1 case — no special path.

The framing is **constrained double-entry**: every categorised
transaction balances one account leg against N category allocations
whose sum equals the total. The account-side debit/credit machinery is
untouched; allocations are a richer breakdown of the same total on the
category side only.

## Goals

1. A categorised transaction (`Income` or `Expense`) carries a
   `Allocations`, replacing the single embedded `CategoryId`.
2. The sum of allocation amounts equals the categorised total
   (`targetAmount` for `Income`, `sourceAmount` for `Expense`), enforced
   at the smart-constructor level and refined in LiquidHaskell.
3. Splits are supported at registration time (single command, no
   special "import" path) and as a post-hoc edit on completed
   transactions.
4. `AmendTransfer` keeps its master-defined lean shape — it changes
   posting facts (accounts, amounts, FX, business date) but does **not**
   accept allocations from the caller. When the categorised amount
   changes via amendment, the **command handler** deterministically
   rescales existing allocations by `factor = newAmount / oldAmount`
   (exact Rational math), preserving the original ratio and the sum
   invariant, and emits the scaled `TransferType` as a field on the
   `TransferAmendmentCompleted` event. Projections and read models just
   apply the post-amendment `TransferType` they read off the event;
   they do not redo the rescale. Reshape of the allocation list is the
   separate responsibility of `SetTransactionAllocations`. The
   transaction's *kind* (Income / Expense / Transfer / Adjustment) is
   structurally preserved by the `AccountType` invariant on amendment;
   recategorising across the kind boundary is still "delete and repost."
5. The account-side debit/credit machinery, the transfer saga, the
   amendment saga's leg orchestration, and the cancellation saga are
   structurally unchanged. Only the category-side payload they carry
   grows richer.
6. The new shape is exposed faithfully through the existing tagged-sum
   JSON encoding of `TransferType`. The API surface gains exactly one
   new endpoint (`PATCH /transactions/{id}/allocations`); list / get
   responses continue using the same shape they do today, with
   `transferType` now carrying the allocations payload.

## Non-Goals

- **Multi-account-source splits** ("pay 500 cash + 500 card in one
  transaction"). The account leg side remains single-source /
  single-target. Future work; not blocked by this design.
- **Per-allocation labels, FX rates, or descriptions.** Labels and
  description remain per-transaction; exchange rate stays
  per-transaction; all allocations on one transaction share a single
  currency (matching the categorised side).
- **Budgets.** This spec does not introduce a budget aggregate or
  category-spend read model. It does, however, emit enough event detail
  that a future budget projection can compute per-category spend
  without further event changes.
- **Backward compatibility.** The DB will be recreated as part of
  rollout. No event upcaster, no JSON-shape coexistence period, no
  deprecated commands left in place.
- **Adjustment with a category.** `Adjustment` continues to carry no
  category; tagging discrepancies (as some accounting apps do) is out
  of scope.

## Design

### 1. Domain types

A new `Allocation` value type lives in `Domain.Core.Types` next to
`TransferType` — same module, no new file. `TransferType` is rewritten
to carry allocations on its categorised constructors.

```haskell
-- Domain.Core.Types

-- | A single category slice of a transaction's categorised amount.
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: Money     -- magnitude; sign is carried by TransferType
  }
  deriving (Show, Eq, Generic)

-- | A non-empty list of allocations — the categorised side of an
-- Income/Expense transaction.
type Allocations = NonEmpty Allocation

-- | Type of transfer operation.
--
-- Income and Expense carry one or more Allocations whose amounts sum
-- to the categorised total. Transfer (internal account-to-account) and
-- Adjustment (balance reconciliation) have no category side.
data TransferType
  = Income     Allocations
  | Expense    Allocations
  | Transfer
  | Adjustment
  deriving (Show, Eq, Generic)
```

Smart constructors (return `Either DomainError TransferType`):

```haskell
mkIncome  :: Money -> Allocations -> Either DomainError TransferType
mkExpense :: Money -> Allocations -> Either DomainError TransferType
```

Both validate, in order:

1. Each `allocation.amount > 0`.
2. Every `allocation.amount.currency` equals the categorised `Money`'s
   currency.
3. `sum (amount <$> allocations) == categorisedAmount`.

Non-emptiness is encoded by the `NonEmpty` type.

`Transfer` and `Adjustment` remain nullary constructors and are
constructed directly without a smart constructor.

**Canonical accessors** (also in `Domain.Core.Types`):

```haskell
-- | The allocations on a categorised TransferType, Nothing otherwise.
allocationsOf :: TransferType -> Maybe Allocations

-- | Sum of allocation amounts (= categorised total) where defined.
categorisedAmount :: TransferType -> Maybe Money

-- | True for Income / Expense; False for Transfer / Adjustment.
isCategorised :: TransferType -> Bool

-- | The kind of a TransferType, ignoring its payload. Used by command
-- handlers to enforce kind-preservation across edits.
data TransferKind = IncomeKind | ExpenseKind | TransferKind | AdjustmentKind
kindOf :: TransferType -> TransferKind
```

The module exports `Allocation(..)` (data + selectors), `TransferType`
(type only — no data constructors), the smart constructors, the
accessors, and `TransferKind` / `kindOf`. **No consumer outside
`Domain.Core.Types` destructures `Income` or `Expense` directly.** This
is the same hiding pattern the module already applies to `Money` and
`ExchangeRate`.

**Duplicates allowed.** Two allocations with the same `categoryId` are
permitted (`[(food, 100), (food, 200)]`); the system does not collapse
them. A future per-allocation memo or note may exploit this; for now
it's neutral and avoids a UX trap.

### 2. LiquidHaskell refinements

Added incrementally per the project's RDD → TDD → implementation
sequence:

- `Allocation`: `{ a : Allocation | a.amount.value > 0 }`.
- Currency consistency: a `measure allocationsCurrency :: NonEmpty
  Allocation -> Currency` is reflected, and the smart constructors
  refine `{ allocs | allocationsCurrency allocs == categorisedAmount.currency }`.
- Sum invariant: a `reflect` of `sumAllocations` plus a refinement on
  the smart-constructor result `{ tt | sumAllocations (allocationsOf
  tt) == categorisedAmount }`. Staged in last because it couples the
  list to an external `Money`; the project's pattern says to add this
  after sum-of-list properties are landed and stable.

All measures are exported. No bang patterns inside refinement
annotations.

### 3. Commands

Three commands change vs. today's surface; one is removed.

**`InitiateTransfer`** (existing — `Domain.Transaction.Commands`):
identical shape, but `transferType :: TransferType` now carries the
new payload. Handler-level invariants enforced before any event is
emitted:

- If `transferType = Income allocs`: `sum (amount <$> allocs) == targetAmount`.
- If `transferType = Expense allocs`: `sum (amount <$> allocs) == sourceAmount`.
- All allocation currencies match the categorised side's currency
  (`targetAmount.currency` for Income, `sourceAmount.currency` for Expense).

These are the same invariants the smart constructor enforces; the
command handler re-checks at the boundary because nothing prevents a
caller from hand-constructing an `Income` from outside the module if
the export list is bypassed.

**`SetTransactionAllocations`** (new — replaces `ChangeTransactionCategory`):

```haskell
data SetTransactionAllocations = SetTransactionAllocations
  { transactionId  :: TransactionId
  , newAllocations :: Allocations
  }
```

Handler invariants:

- Transaction must be in the `Completed` state. Reject with
  `CannotEditUncompletedTransaction` otherwise.
- Existing transaction must be categorised. If `existing.transferType
  ∈ {Transfer, Adjustment}`, reject with
  `CannotSetAllocationsOnUncategorisedTransaction`.
- Allocations sum must equal the existing categorised total
  (`categorisedAmount existing.transferType`). The transaction's
  amount does not change as part of this command; only the breakdown.
- Currency consistency: each allocation's currency must equal the
  existing categorised currency.
- Each allocation's `amount > 0`.

Kind preservation is structural — the command carries only allocations,
not a full `TransferType`, so the surrounding kind (Income / Expense)
cannot change on this command. Recategorising across the income/expense
boundary remains a delete-and-repost operation.

Service-layer (impure) checks remain orthogonal: cutoff-date enforcement,
authorization on `Editor` role, validation that each `CategoryId`
exists in the user's dictionary for the existing kind.

**`AmendTransfer`** (existing — matches master's lean shape):

```haskell
data AmendTransfer = AmendTransfer
  { transactionId      :: TransactionId
  , newSourceAccountId :: AccountId
  , newTargetAccountId :: AccountId
  , newSourceAmount    :: Money
  , newTargetAmount    :: Money
  , newExchangeRate    :: Maybe ExchangeRate
  , amendedBy          :: UserId
  }
```

`AmendTransfer` does **not** carry allocations. It is the
posting-facts command (accounts, amounts, FX, date); the category
breakdown is handled by `SetTransactionAllocations`. Kind preservation
is structurally guaranteed by `AccountType` invariants
(`validateAccountTypePreserved` at the service layer): the transaction
kind is a function of source/target `AccountType`, so kind cannot
change as long as account types are preserved.

When the categorised amount changes (Income's `newTargetAmount` or
Expense's `newSourceAmount`), the projection deterministically
rescales existing allocations by `factor = newAmount / oldAmount`
(exact `Rational` math). This preserves the proportional split. A
deliberate re-split of the categorised total — different category
mix, different relative weights — is done via a subsequent
`SetTransactionAllocations`.

The amendment saga (`TransferAmendmentManager`) is unchanged. Its leg
orchestration reads `newSourceAmount` / `newTargetAmount` /
`newExchangeRate` exactly as today.

**Removed**:

- `ChangeTransactionCategory` command (and its handler clause).
- `CannotChangeCategoryOnUncategorizedTransaction` error variant —
  replaced by `CannotSetAllocationsOnUncategorisedTransaction`.

The full `transactionCommands` list now reads (unchanged order, two
swaps):

```haskell
transactionCommands =
  [ ''InitiateTransfer
  , ''CompleteTransfer
  , ''FailTransfer
  , ''SetTransactionLabels
  , ''SetTransactionAllocations         -- replaces ChangeTransactionCategory
  , ''ChangeTransactionDescription
  , ''ChangeTransactionDate
  , ''AmendTransfer
  , ''CompleteTransferAmendment
  , ''FailTransferAmendment
  , ''CancelTransaction
  , ''CompleteTransactionCancellation
  ]
```

### 4. Events

Mirror the command changes.

**`TransferInitiated`** (existing): `transferType :: TransferType` now
carries the new payload. No field rename.

**`TransactionAllocationsChanged`** (new — replaces `TransactionCategoryChanged`):

```haskell
data TransactionAllocationsChanged = TransactionAllocationsChanged
  { transactionId  :: TransactionId
  , newAllocations :: Allocations
  }
```

The event carries only the new allocations; the surrounding kind is
preserved structurally from the existing transaction state. Projections
reconstruct the full `TransferType` via `replaceAllocations`.

**`TransferAmendmentInitiated`** (existing): matches master's shape
exactly. The saga-trigger event is a posting-facts payload only —
allocations are not on the saga-orchestration surface (the saga's leg
commands don't care about categorisation).

**`TransferAmendmentCompleted`** (existing, with one new field): adds
`newAllocations :: Maybe Allocations`. The field is
**handler-computed**, not user-supplied — the `AmendTransfer` /
`CompleteTransferAmendment` commands deliberately do **not** accept
allocations. When the categorised amount changes via amendment, the
command handler for `CompleteTransferAmendment` rescales the existing
allocations proportionally and emits the result as `Just allocs`;
otherwise the field is `Just` of the pre-amendment allocations. For
`Transfer` / `Adjustment` (no allocations) the field is `Nothing`.
Projections and read models apply the field via `replaceAllocations`
on the existing kind — kind is structurally preserved across amendment
by `AccountType` invariants, so the projection never has to reconstruct
the kind from the event.

`TransactionCancellationInitiated` and `TransactionCancellationCompleted`
are unchanged. Cancellation reverses leg events on accounts; the
category payload sits on the transaction aggregate and follows the
aggregate's status transition to `Cancelled` automatically.

The `transactionEvents` list reflects the rename
(`TransactionCategoryChanged` → `TransactionAllocationsChanged`).

### 5. Aggregate projection

`Domain.Transaction.Projection`'s `Transaction` record already has a
`transferType :: TransferType` field; the new payload threads through
unchanged.

`handleTransactionEvent` clauses:

- `TransferInitiatedTransactionEvent`: unchanged structurally; the
  embedded `transferType` is the new shape.
- `TransactionAllocationsChangedTransactionEvent` (new, replaces
  `TransactionCategoryChangedTransactionEvent`): sets
  `transaction.transferType` to
  `replaceAllocations evt.newAllocations transaction.transferType`.
  The kind is preserved from existing state — the event carries only
  allocations, never a kind.
- `TransferAmendmentCompletedTransactionEvent`: in addition to its
  existing amount / account / FX updates, applies `evt.newAllocations`
  via `replaceAllocations` when `Just`; otherwise (`Nothing`,
  `Transfer` / `Adjustment` existing) the `transferType` passes
  through unchanged. The event's `newAllocations` is a
  handler-computed snapshot — the command handler for
  `CompleteTransferAmendment` has already rescaled allocations
  proportionally when the categorised amount changed (Income's
  `newTargetAmount`, Expense's `newSourceAmount`), so the projection
  just applies the post-amendment value. Kind is structurally
  preserved by `AccountType` invariants — the projection does not
  change it.

No new transient flag on the projection. Allocations are part of the
canonical `transferType` value; nothing is "in progress" between
emitting an allocation edit event and applying it.

### 6. Read model

`Application.ReadModels.Transaction` does not change shape. Each row
already carries `transferType :: TransferType`; with the new payload
shape, callers that previously read `Income categoryId` now read
`Income allocations`. The same `allocationsOf` / `categorisedAmount`
helpers used by the domain are exported for read-model and web-layer
consumers.

The transactions list endpoint and the single-transaction get endpoint
return the same envelope as today; the `transferType` field's JSON
shape is the only thing that changes (Section 8).

The `TransferAmendmentCompleted` arm in the read model mirrors the
aggregate projection: it applies `evt.newAllocations` via
`replaceAllocations` on the row's existing `transferType` when
`Just`, leaving it unchanged when `Nothing`. The handler has already
rescaled allocations on amount-changing amendments before emitting the
event; the read model does not redo that math.

A category-spend read model — "how much spent in category X this
month" — is **out of scope**. The events emitted are sufficient to add
one cleanly later: a projection consuming `TransferInitiated`,
`TransactionAllocationsChanged`, `TransferAmendmentCompleted`, and
`TransactionCancellationCompleted` can maintain per-category totals
without any further event changes.

### 7. Service layer

`Application.Services.TransactionService` gains one new function and
removes one:

```haskell
setTransactionAllocations ::
  ( MonadReader env m, HasEventStore env, HasDbPool env
  , MonadError DomainError m, MonadIO m ) =>
  UserId ->
  TransactionId ->
  Allocations ->   -- newAllocations
  m ()
```

Responsibilities (matching the existing `changeTransactionCategory`
shape, which it replaces):

- Authorization: caller must have `Editor` role on the relevant
  account(s).
- Validate every `CategoryId` in the allocations exists in the user's
  dictionary for the matching kind (Income vs Expense).
- Cutoff-date / books-closed check (deferring to the same helper used
  by the existing edit commands).
- Issue the command to the aggregate.

`registerTransfer` / amendment service entry points keep their
signatures; the `transferType :: TransferType` parameter just carries
the new payload shape internally.

### 8. Web layer

The tagged-sum JSON encoding for `TransferType` is the existing
convention — `aeson` generic encoding with `tag` / `contents`:

```json
{ "tag": "Income",
  "contents": [
    { "categoryId": "...", "amount": { "currency": "UAH", "value": "200.00" } },
    { "categoryId": "...", "amount": { "currency": "UAH", "value": "800.00" } }
  ]
}

{ "tag": "Expense",
  "contents": [
    { "categoryId": "...", "amount": { "currency": "UAH", "value": "1000.00" } }
  ]
}

{ "tag": "Transfer" }
{ "tag": "Adjustment" }
```

`Web.API.TransactionAPI` endpoints:

| Endpoint                                       | Change                                                                                              |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `POST /transactions`                           | Body's `transferType` uses the new shape. No other field changes.                                  |
| `PATCH /transactions/{id}/allocations` (new)   | Replaces `PATCH /transactions/{id}/category`. Body: `{ "newAllocations": [<Allocation>, ...] }` — a flat allocation list. The transaction's kind is preserved structurally. |
| `PATCH /transactions/{id}` (amendment)         | Master's shape — no allocations on body. When amount changes, projection auto-scales allocations. |
| `GET /transactions`, `GET /transactions/{id}`  | Response envelope unchanged; the embedded `transferType` field carries the new payload shape.      |

`Web.ErrorMapping` gains new variants under `DomainError`:

- `AllocationsDoNotSumToTotal` → 400.
- `AllocationAmountNotPositive` → 400.
- `AllocationCurrencyMismatch` → 400.
- `CannotChangeKindOfCategorisedTransaction` → 400.
- `CannotSetAllocationsOnUncategorisedTransaction` → 400.
- `TransactionMustBeCompletedForAllocationsEdit` → 409.

And removes:

- `CannotChangeCategoryOnUncategorizedTransaction`.

All map through `mkValidationError` with field/message context.

The Telegram bot (`src/Telegram/Commands.hs`) does not currently expose
category editing through a single-category shortcut; the migration
there is mechanical (it constructs `TransferType` values, which now
carry allocations instead of a `CategoryId`).

### 9. DB / on-disk compatibility

**None.** The eventium-postgresql schema is recreated on deploy as part
of this rollout. There is no event upcaster, no dual-shape
deserialisation, no shim. Existing transactions in the dev DB are
discarded; production has no users with persisted state at the time of
this writing.

This is captured as a deploy step in the implementation plan, not
absorbed into runtime code.

## Testing

Property tests are primary; unit and integration tests supplement.

| File                                                                | Type        | Proves                                                                                                                                                                                            |
| ------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test/Domain/Core/AllocationPropertySpec.hs`                        | Property    | `Allocation` invariants: amount > 0. Generator law: roundtrip JSON.                                                                                                                              |
| `test/Domain/Core/TransferTypePropertySpec.hs`                      | Property    | `mkIncome` / `mkExpense` accept iff invariants hold; reject otherwise. `kindOf` is total. `allocationsOf` returns Nothing iff Transfer/Adjustment.                                              |
| `test/Domain/Transaction/CommandHandlerPropertySpec.hs` (extended)  | Property    | Kind-preservation invariant across `SetTransactionAllocations`. (For `AmendTransfer`, kind preservation is structurally guaranteed by `AccountType` invariants at the service layer — see §3.) |
| `test/Domain/Transaction/AllocationsSpec.hs`                        | Unit        | Worked examples: 200 + 800 grocery case; degenerate length-1 case; rejection of sum mismatch; rejection of currency mismatch; rejection of allocations on `Transfer`.                            |
| `test/Application/ReadModels/TransactionListSpec.hs` (extended)     | Unit        | Read-model row carries the new `transferType` payload; allocations preserved through registration, edit, amendment, cancellation.                                                                |
| `test/Web/API/TransactionAPISpec.hs` (extended)                     | Unit        | DTO encode/decode round-trip; 400-mapped validation errors for the new variants.                                                                                                                  |
| `test/Application/Services/TransactionAllocationsIntegrationSpec.hs`| Integration | E2E: register Expense with two allocations → GET → `SetTransactionAllocations` to three allocations → GET → `AmendTransfer` with a new amount → GET (allocations rescaled proportionally) → optional `SetTransactionAllocations` for a deliberate re-split → GET. Each step reflects in reads. |

LiquidHaskell verification runs as part of the existing `just build`
target; the new measures and refinements must verify without errors.

## Rollout

1. Land this design spec.
2. Write the implementation plan via the `writing-plans` skill
   (separate document in `docs/plans/`).
3. Implement in phases, each one PR:

   1. `Allocation` + revised `TransferType` + smart constructors + LH
      refinements + property tests.
   2. Command / event renames + handler updates + aggregate
      projection.
   3. Service layer + read-model update.
   4. Web layer DTOs + integration tests + error mapping.
   5. Telegram bot adjustment.

4. Deploy: drop the eventium tables and let auto-create rebuild them.
   No data migration.

## Open Questions

1. **`Allocation` JSON field naming.** The current convention uses
   `categoryId` / `amount` (matching the Haskell record). One
   alternative — `{ "category": ..., "value": ... }` — is shorter but
   diverges from the rest of the API. Going with `categoryId` /
   `amount` unless reviewers prefer otherwise.

2. **Whether to expose a denormalised `allocations` array** on the
   read-model row in addition to the tagged-sum `transferType`. The
   design says no (faithful to the domain shape; clients read the
   tagged sum), matching the current API. Easy to flip later if a UI
   client prefers the flat shape.

3. **Display-time category collapsing.** Allowing duplicate
   `categoryId` values across allocations means that two slices with
   the same category exist on the wire. A UI may want to collapse them
   for display. That's a UI concern; the backend stores them faithfully.

4. **Books-close interaction with allocation edits.** Allocation edits
   currently inherit the same cutoff-date gate as the other metadata
   edits. Whether reclassifying an old transaction should be
   *exempted* (because it doesn't change balances) is a policy
   question the design leaves to the service layer's existing rule —
   no special-casing here.

## Alternatives Considered

**Decompose split into N child transactions.** Make a single bank line
become a "parent" with N "child" transactions (one per category
portion). Children would be reporting-only.

- *Rejected* because it doubles the event vocabulary (parent/child
  semantics on top of every existing flow — amendment, cancellation,
  labels), invites parent/child sync bugs, and forces every read
  model to be aware of the relationship. The unified-allocations shape
  achieves the same reporting outcome with one transaction, one
  balance impact, and one canonical category surface.

**Allocations as a side-projection / overlay.** Keep the embedded
`CategoryId` as the "primary" category; add an optional
`Maybe Allocations` overlay that, when present, overrides the
primary for reporting.

- *Rejected* because it permanently bakes a fallback into every reader
  ("check allocations, else fall back to embedded category"). Two
  sources of truth for the same fact. The migration cost saved
  (no field rename) is outweighed by the operational tax forever
  thereafter.

**Postings / Beancount-style.** Generalise to `NonEmpty Posting` where
each posting carries either an `AccountId` or a `CategoryId` and a
signed `Money`, with sum-to-zero as the only invariant.

- *Rejected* because it removes the named, well-typed `TransferType`
  constructors that the rest of the system relies on (the saga, the
  amendment saga, the cancellation saga, the projection, every read
  model). Pure postings would force every consumer to detect the kind
  of a transaction by inspecting its postings. The chosen design
  *is* constrained double-entry — it's the postings idea with the
  shape pre-named for the cases this app actually has (Income,
  Expense, Transfer, Adjustment). Future extension to richer shapes
  (e.g., multi-account-source splits) is a constructor addition, not
  a refactor.

**`AmendTransfer` with `newAllocations :: Maybe Allocations`
(or with the full `newTransferType :: TransferType`) as a separate
field.** Considered, then rejected.

- *Rejected* because it widens `AmendTransfer` beyond master's
  deliberate single-responsibility shape — master keeps the amendment
  surface lean (posting facts only) precisely because the transaction
  kind is structural (a function of the source/target `AccountType`)
  and not user-amendable. Carrying allocations on the amendment
  command would also bring back the runtime "kind ↔ presence of
  allocations" invariant that the projection now sidesteps. The
  chosen design splits responsibilities cleanly:

  - `AmendTransfer` → posting facts (accounts / amounts / FX / date).
    When the categorised amount changes, the command handler for
    `CompleteTransferAmendment` rescales existing allocations
    proportionally (exact `Rational`) and emits the scaled
    `TransferType` on the event; this achieves the same end-state for
    the common case (proportional split preserved).
  - `SetTransactionAllocations` → category breakdown. The user calls
    this after an amendment if they want a deliberate re-split.

**Folding `SetTransactionAllocations` into `AmendTransfer` with
optional fields.** Single edit command, every field `Maybe`.

- *Rejected* because amendment is an expensive multi-step saga (leg
  reversal + repost) while allocation edits are a single aggregate
  event with no saga. Routing the cheap operation through the
  expensive code path conflates user intent and complicates the saga.
  The existing pattern in the codebase (separate
  `ChangeTransactionDescription`, `ChangeTransactionDate`) already
  establishes that small atomic edits get their own commands.

**Carrying a full `TransferType` on the three derivative surfaces
(`SetTransactionAllocations`, `TransactionAllocationsChanged`,
`TransferAmendmentCompleted`).** Considered, then tightened.

- Earlier iteration carried `newTransferType :: TransferType` on
  `SetTransactionAllocations` / `TransactionAllocationsChanged`, and
  `newTransferType :: TransferType` on `TransferAmendmentCompleted`.
  Tightened to `Allocations` / `Maybe Allocations`:
  kind cannot change in these events (handler invariants for the
  set-allocations command; structural `AccountType` preservation for
  amendment), and a small helper `replaceAllocations` reconstructs
  the full `TransferType` at the projection from existing state. The
  result is a flatter wire shape on `PATCH /allocations`
  (`{"newAllocations": [...]}` instead of a tagged sum), one fewer
  statically-impossible payload variant per event
  (a `TransactionAllocationsChanged` carrying a `Transfer` /
  `Adjustment` value), and no behavioural change for any consumer.
