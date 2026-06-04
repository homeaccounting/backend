---
status: completed
date: 2026-06-01
depends_on:
  - 2026-05-20-transfer-amendment-saga-design.md
  - 2026-05-30-transaction-allocations-design.md
---

# Cross-Kind Transaction Amendment

> **Naming update (2026-06-02):** This spec was originally drafted before
> PR #95 renamed the `Transfer*` family to `Transaction*` (see
> [`2026-06-02-transaction-naming-consistency-design.md`](2026-06-02-transaction-naming-consistency-design.md)).
> All identifiers below now match the current codebase:
> `TransferType` → `TransactionType`, `TransferKind` → `TransactionKind`,
> `AmendTransfer` → `AmendTransaction`,
> `TransferAmendment{Initiated,Completed,Failed}` → `TransactionAmendment*`,
> `CompleteTransferAmendment` → `CompleteTransactionAmendment`,
> `deriveTransferKind` → `deriveTransactionKind`,
> `TransferAmendmentManager` → `TransactionAmendmentManager`.

## Problem

`AmendTransaction` today is **kind-preserving** by construction: the
service layer enforces `AccountType` equality on each leg, which
implicitly fixes the transaction's kind (Income / Expense / Transfer /
Adjustment) — kind is a function of `(sourceAccountType,
targetAccountType)`.

That invariant breaks in one specific real-world flow: **Monobank
imports**. When the user moves money between two of their own cards
(card-to-card transfer, MCC 4829), Monobank reports the row on a single
account with a positive amount. The bank-import service has no signal
that the counterparty is the user's other linked account, so the row
imports as an `Income` (`External → Regular`). The user later realises
this should be a `Transfer` between two of their own Regular accounts
and tries to fix it — but `AmendTransaction` refuses because that
would cross the `External → Regular` / `Regular → Regular` boundary.

The current workaround is delete-and-repost, which is awkward UX and
loses two things worth preserving:

- the `externalTransactionId` mapping (next Monobank resync re-imports
  the same row);
- the audit trail (the original misclassification disappears entirely
  rather than being recorded as an amendment).

The narrow Monobank case generalises: **any misclassified imported
transaction** (and any user-entry mistake) where the user wants to
change which kind of operation it was should be a first-class
amendment, not a delete-and-repost.

## Goals

- Allow `AmendTransaction` to change the transaction's kind across the
  Income ↔ Expense ↔ Transfer boundary in a single saga.
- Preserve `externalTransactionId`, labels, business date, and
  amendment history across the kind change.
- Keep the same end-to-end semantics as today: reversal of the original
  leg(s) and re-application of the new leg(s) on the affected
  accounts, with a single fallible step (the new-source debit).
- Keep the API surface lean: one command, one saga.

## Non-Goals

- **Adjustment** is out of scope. `Adjustment` has `source == target`
  (single-account balance write); converting into or out of Adjustment
  has materially different semantics from a two-leg amendment and
  remains its own command path (`AdjustAccountBalance` for posting;
  delete-and-repost for kind change involving Adjustment).
- **Detecting own-account transfers at import time** is a separate
  problem (would prevent the misclassification rather than make it
  amendable). Out of scope here; the user has explicitly chosen the
  "fix after the fact" path.
- **Cross-stream linkage** (recording that the amended transfer came
  from a particular bank import row beyond the existing
  `externalTransactionId`) is out of scope.

## Design

### Kind derivation

The transaction's kind remains structurally derived from the two
endpoints' `AccountType` values. Introduce an explicit helper used by
both `InitiateTransaction` (today via the service layer's
`pickCategoryDictForKind`) and the new amendment path:

```haskell
deriveTransactionKind :: AccountType -> AccountType -> TransactionKind
deriveTransactionKind (Regular _) External    = ExpenseKind
deriveTransactionKind External    (Regular _) = IncomeKind
deriveTransactionKind (Regular _) (Regular _) = TransferKind
deriveTransactionKind External    External    = TransferKind
```

The helper is total. The `External ↔ External` case is structurally
unreachable for valid inputs — every user owns exactly one `External`
account, and the service layer rejects `source == target` before
calling `deriveTransactionKind`. The case is kept exhaustive so the
function stays total per project rules; the chosen result
(`TransferKind`) is irrelevant because the branch is dead.

`AdjustmentKind` is never derivable through this helper because the
service layer rejects `source == target` before reaching it (an
Adjustment is a single-account write, not a two-leg amendment).

### Command surface (user-facing)

`AmendTransaction` gains one field; everything else stays:

```haskell
data AmendTransaction = AmendTransaction
  { transactionId       :: TransactionId
  , newSourceAccountId  :: AccountId
  , newTargetAccountId  :: AccountId
  , newSourceAmount     :: Money
  , newTargetAmount     :: Money
  , newExchangeRate     :: Maybe ExchangeRate
  , newAllocations      :: Maybe Allocations  -- NEW
  , amendedBy           :: UserId
  }
```

Caller responsibilities:

- For amount-only or endpoint-only edits **within the existing kind**,
  pass `newAllocations = Nothing`. The service rescales existing
  allocations against the new amount (today's `rescaleAllocations`
  behaviour, now applied service-side rather than handler-side).
- For edits **changing the kind into Income or Expense**, pass
  `newAllocations = Just …` covering the new categorised total.
- For edits **changing the kind into Transfer**, pass
  `newAllocations = Nothing` (Transfer has no allocations).

### Event shape

Both `TransactionAmendmentInitiated` and `TransactionAmendmentCompleted`
carry the full new `TransactionType` rather than the previous lean
"posting facts + maybe allocations" pair. Encoding kind ⊕ allocations
as one `TransactionType` value makes projection trivial and removes any
need to know "old kind" at replay time.

```haskell
data TransactionAmendmentInitiated = TransactionAmendmentInitiated
  { transactionId         :: TransactionId
  , newSourceAccountId    :: AccountId
  , newTargetAccountId    :: AccountId
  , newSourceAmount       :: Money
  , newTargetAmount       :: Money
  , newExchangeRate       :: Maybe ExchangeRate
  , newTransactionType    :: TransactionType  -- REPLACES implicit kind-preservation
  , amendedBy             :: UserId
  }

data TransactionAmendmentCompleted = TransactionAmendmentCompleted
  { transactionId         :: TransactionId
  , newSourceAccountId    :: AccountId
  , newTargetAccountId    :: AccountId
  , newSourceAmount       :: Money
  , newTargetAmount       :: Money
  , newExchangeRate       :: Maybe ExchangeRate
  , newTransactionType    :: TransactionType  -- REPLACES newAllocations :: Maybe Allocations
  , amendedBy             :: UserId
  }
```

`TransactionAmendmentFailed` is unchanged. `CompleteTransactionAmendment`
(saga-internal command) also gains `newTransactionType` to mirror the
event it produces.

Per project convention (no backcompat phase: see auto-memory
`project_no_backcompat_phase.md`), this is a clean event-shape break —
no upcaster from the old `newAllocations :: Maybe Allocations` field.

### Pure handler

`handleTransactionCommand` for `AmendTransactionTransactionCommand`:

Existing guards keep working unchanged: `Completed` status,
`amendmentInProgress == False`, no cancellation in flight,
`newSourceAccountId /= newTargetAccountId`, both amounts non-zero. New
guards on the supplied `newTransactionType`:

| `kindOf newTransactionType` | Required shape    | Sum check                            | Currency check                       |
| --------------------------- | ----------------- | ------------------------------------ | ------------------------------------ |
| `IncomeKind`                | `Income allocs`   | `sum allocs == newTargetAmount`      | all match `newTargetAmount.currency` |
| `ExpenseKind`               | `Expense allocs`  | `sum allocs == newSourceAmount`      | all match `newSourceAmount.currency` |
| `TransferKind`              | `Transfer`        | n/a                                  | n/a                                  |
| `AdjustmentKind`            | reject            | `CannotAmendToAdjustmentKind`        | —                                    |

The sum-check / currency-check / positivity errors reuse the existing
aggregate-local variants `AllocationsDoNotSumToTotal`,
`AllocationCurrencyMismatch`, and `AllocationAmountNotPositive` (the
same checks `InitiateTransaction` already runs against
`InitiateTransaction.transactionType`). The only new aggregate-local
error is `CannotAmendToAdjustmentKind`.

On success the handler emits a single `TransactionAmendmentInitiated`
carrying `newTransactionType` verbatim (no rescaling, no synthesis —
the service layer has already supplied a well-formed value).

`handleTransactionCommand` for `CompleteTransactionAmendmentTransactionCommand`:

Today's handler rescales the existing allocations against the new
amount and produces a `Maybe Allocations` payload. That logic moves to
the service layer (see below), so the handler simplifies to:

1. Guard on `amendmentInProgress == True` (unchanged).
2. Emit `TransactionAmendmentCompleted` echoing `newTransactionType`
   from the saga's `CompleteTransactionAmendment` verbatim.

### Projection

`Domain/Transaction/Projection.hs` — `handleTransactionEvent` for
`TransactionAmendmentCompletedTransactionEvent`:

```haskell
handleTransactionEvent transaction (TransactionAmendmentCompletedTransactionEvent evt) =
  transaction
    & #sourceAccountId    .~ evt.newSourceAccountId
    & #targetAccountId    .~ evt.newTargetAccountId
    & #sourceAmount       .~ evt.newSourceAmount
    & #targetAmount       .~ evt.newTargetAmount
    & #exchangeRate       .~ evt.newExchangeRate
    & #transactionType    .~ evt.newTransactionType
    & #amendmentCount     %~ (+ 1)
    & #amendmentInProgress .~ False
```

The previous handler-side rescale plus `replaceAllocations` call
disappears for the amendment-completed arm — the event is now
self-contained.

`replaceAllocations` and `rescaleAllocations` are both **kept** in
`Domain/Core/Types.hs`:

- `replaceAllocations` is still used by the `TransactionAllocationsChanged`
  projection arm (the `SetTransactionAllocations` flow).
- `rescaleAllocations` is still used by the service layer for
  within-kind amount-only amendments.

### Saga

`Application/ProcessManagers/TransactionAmendmentManager.hs` needs three
mechanical changes:

1. `TransactionAmendmentData` snapshot gains `newTransactionType ::
   TransactionType` (currently it holds the lean payload).
2. The saga's reaction to `TransactionAmendmentInitiatedEvent` reads
   `evt.newTransactionType` into the snapshot.
3. When finalising (issuing `CompleteTransactionAmendment`), the manager
   echoes `newTransactionType` from the snapshot onto the command.

No structural changes to the leg-diff algorithm (`diffAmendmentLegs`
in `TransactionAmendmentManager.hs`) — it operates on accounts and
amounts only and is already account-type-agnostic. Cross-kind
amendments produce the same leg shapes:

- **Income → Transfer** (replace External source with Regular):
  `[ReverseOldSource (oldExternal), DebitNewSource (newRegular)]`; no
  target leg (same target).
- **Expense → Transfer** (replace External target with Regular):
  `[ReverseOldTarget (oldExternal), CreditNewTarget (newRegular)]`; no
  source leg.
- **Transfer → Income** (replace Regular source with External): same
  diff shape as Income → Transfer with roles swapped.
- **Income → Expense** (swap source and target): produces both source
  and target legs (debit new source, reverse old source, reverse old
  target, credit new target).

The fallible step is still the new-source debit, and only when the new
source account is different from the old or its amount increased. When
the new source is External (Income → Income with new External, or
Expense / Transfer → Income), the debit cannot fail on funds (External
has unlimited overdraft); no special case in code — existing
`Account.debit` already covers this.

### Service layer

`Application/Services/TransactionService.hs:amendTransaction` keeps the
existing skeleton (`ensureEditorAccess`, `guardBooksClosed`,
`ensureEditorOnNewAccounts`, identity-amend short-circuit, dispatch)
with these specific changes:

1. **Drop** `validateAccountTypePreserved` (the helper is deleted).
2. **Resolve new endpoints**: `ensureEditorOnNewAccounts` already
   fetches both `AccountData`s for the permission check; return them
   so the kind derivation step doesn't re-fetch.
3. **Derive new kind** via `deriveTransactionKind` (total). The
   `source == target` (Adjustment-shaped) case is already rejected by
   the pure handler via `AmendTransferToSameAccountPair` (mapped to
   `DomainError.CannotAmendToSameAccountPair`) and remains there — no
   dedicated Adjustment-shaped rejection at the service layer.
4. **Synthesise `newTransactionType`** from `(derivedKind,
   cmd.newAllocations, existingTransactionType)`:

   | Caller `newAllocations` | Derived kind     | Action                                                                                                                                                                                       |
   | ----------------------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
   | `Just allocs`           | Income / Expense | `Income allocs` / `Expense allocs`. Validate each `categoryId` against the matching dictionary via the existing `validateAllocationsAgainstDictionary`.                                       |
   | `Just _`                | Transfer         | Reject `AllocationsNotAllowedForTransferKind`.                                                                                                                                               |
   | `Nothing`               | Income / Expense | If `kindOf existingTransactionType == derivedKind`: rescale existing allocations against the new categorised amount via `rescaleAllocations`. Else: reject `AllocationsRequiredForCategorisedKind`. |
   | `Nothing`               | Transfer         | `Transfer`.                                                                                                                                                                                  |

5. **Identity-amend** comparison now also includes `newTransactionType`
   (deep equality, including allocations); identical payload returns
   the existing read-model entry unchanged, no events emitted.
6. **Dispatch** the enriched `AmendTransaction`. Saga outcome handling
   unchanged.

New service-layer errors:

- `AllocationsNotAllowedForTransferKind` — caller supplied
  allocations with Transfer-derived kind.
- `AllocationsRequiredForCategorisedKind` — caller omitted
  allocations for a kind change into Income or Expense.

Existing service-layer error to delete: `CannotAmendAcrossAccountType`
(no longer reachable once `validateAccountTypePreserved` is removed —
amendment may now cross the boundary by design).

### Web API

`Web/Types.hs:AmendTransactionRequest` gains an `newAllocations ::
Maybe Allocations` field — same `Allocation` value type already
serialised by `SetTransactionAllocationsRequest` and `IncomeRequest`
/ `ExpenseRequest`. `Allocations = NonEmpty Allocation` is non-empty
by construction; absent → `Nothing`.

`Web/API/TransactionAPI.hs:amendTransactionHandler`:

1. Decode the DTO; pass `req.newAllocations` through verbatim
   (no extra shape validation — `Allocation`'s smart constructor and
   the `NonEmpty` requirement already guarantee positive amounts and
   non-emptiness).
2. Build `AmendTransaction` with `newAllocations`.
3. Map new errors to `400 ValidationErr`:
   `AllocationsRequiredForCategorisedKind`,
   `AllocationsNotAllowedForTransferKind`,
   `CannotAmendToAdjustmentKind`.
   Existing per-allocation errors (`AllocationsDoNotSumToTotal`,
   `AllocationCurrencyMismatch`, `AllocationAmountNotPositive`) and
   the existing `CannotAmendToSameAccountPair` /
   `CannotAmendToZeroAmount` all stay; they cover the new path too.
   `CannotAmendAcrossAccountType` is removed.

No new endpoint; same `PUT /api/transactions/{id}/amendment`.

### Read models

`Application/ReadModels/Transaction.hs` mirrors the projection change:
on `TransactionAmendmentCompletedTransactionEvent`, replace the
read-model entry's `transactionType` from `evt.newTransactionType`
(today it replaces allocations via `replaceAllocations`; the new code
replaces the whole field).

`Application/ReadModels/BankImportReadModel.hs` is unaffected — the
`externalTransactionId` mapping carries through because
`TransactionAmendmentCompleted` doesn't touch that key.

## Errors

Summary of new errors introduced by this change:

- **Pure handler** (`Domain.Transaction.CommandHandler.TransactionError`):
  - `CannotAmendToAdjustmentKind` — `newTransactionType` is `Adjustment`
- **Service layer** (`Domain.Core.Errors.DomainError`):
  - `AllocationsNotAllowedForTransferKind`
  - `AllocationsRequiredForCategorisedKind`

Existing errors reused unchanged for the amendment path: per-allocation
shape errors (`AllocationsDoNotSumToTotal`, `AllocationCurrencyMismatch`,
`AllocationAmountNotPositive`), `CannotAmendToSameAccountPair`,
`CannotAmendToZeroAmount`, `NoAmendmentInProgress`.

Existing error removed: `CannotAmendAcrossAccountType` (both the
`DomainError` constructor and its message mapping in
`Web/ErrorMapping.hs`).

All surfaced at the API as `400 ValidationErr`. No 4xx semantics
change for existing errors.

## Test plan

The project uses property-first testing; integration and unit tests
supplement.

**Property tests** (`test/Domain/Transaction/`):

1. **Cross-kind round-trip**: for any valid `(oldTransactionType,
   newTransactionType)` pair (excluding `Adjustment`), applying
   `AmendTransaction` then projecting yields a transaction whose
   `transactionType == newTransactionType` and whose categorised total
   equals the relevant amount leg.
2. **Allocations-amount agreement**: for any handler-accepted
   `AmendTransaction`, the sum of allocations equals the relevant leg
   amount.
3. **Currency consistency**: every allocation in `newTransactionType`
   shares the relevant leg's currency.
4. **`deriveTransactionKind` totality**: total over `(AccountType,
   AccountType)`; the three reachable cases produce the expected
   `IncomeKind` / `ExpenseKind` / `TransferKind`.
5. **Identity-amend idempotence**: a payload deep-equal to current
   state emits zero events and returns the unchanged read model.

**Unit tests** (`test/Domain/Transaction/CommandHandlerSpec.hs`,
`test/Application/Services/TransactionServiceSpec.hs`):

- Within-kind amount-only edit (`newAllocations = Nothing`,
  kind unchanged): service rescales, handler accepts.
- Cross-kind Income → Transfer with `newAllocations = Nothing`:
  accepted, allocations dropped.
- Cross-kind Income → Expense (endpoint swap): caller supplies new
  Expense allocations summing to new source amount; accepted.
- Cross-kind Transfer → Income with `newAllocations = Nothing`:
  rejected (`AllocationsRequiredForCategorisedKind`).
- Adjustment rejection at handler layer (`newTransactionType` is
  `Adjustment`): `CannotAmendToAdjustmentKind`.
- Allocations supplied for Transfer-derived kind:
  `AllocationsNotAllowedForTransferKind`.
- Allocations sum ≠ relevant leg: `AllocationsDoNotSumToTotal`.
- Allocations currency ≠ leg currency: `AllocationCurrencyMismatch`.
- Allocation `categoryId` not in matching dictionary: `CategoryNotFound`.

**Saga tests**
(`test/Application/ProcessManagers/TransactionAmendmentManagerSpec.hs`):

- Cross-kind diff with one endpoint preserved produces the expected
  leg set (e.g., Income → Transfer with same target: only source-side
  legs).
- New-source debit failure on cross-kind path emits
  `TransactionAmendmentFailed`; original transaction state intact.
- Diff is account-type-agnostic: feeding an External-source amendment
  produces the same leg shapes as a Regular-source amendment with
  identical accounts/amounts.

**Integration tests**
(new `test/Integration/CrossKindAmendmentIntegrationSpec.hs` or
extend `TransactionWorkflowSpec.hs`):

- End-to-end Income → Transfer: post an Income via Monobank-style
  import, amend into Transfer between two Regular accounts, verify
  balances on all three involved accounts and that
  `externalTransactionId` still maps to the same `TransactionId`.
- End-to-end Monobank own-card dedup: amend the imported Income into
  a Transfer, re-run resync, verify the original `externalTransactionId`
  is skipped by `isImported`.
- Amendment history: after a cross-kind amendment, the transaction
  read model exposes `amendmentCount == 1` and the original
  `TransactionPostingInitiated` event is still in the stream
  alongside the `TransactionAmendmentInitiated` /
  `TransactionAmendmentCompleted` pair.

**Existing tests to update**:

- Remove cases asserting `CannotAmendAcrossAccountType` —
  `validateAccountTypePreserved` is deleted. Replace with cases that
  exercise the new allowed transitions and rejections.
- The Monobank own-account-transfer import test (if any) keeps
  asserting today's behaviour (imports as Income); the new amend
  capability is what makes that behaviour acceptable.

## Migration

Per project policy (auto-memory `project_no_backcompat_phase.md`),
event/DTO shapes are broken cleanly during major changes — no
upcasters, no coexist-and-deprecate. The
`TransactionAmendmentInitiated` / `TransactionAmendmentCompleted`
payloads change shape (replacing `newAllocations :: Maybe Allocations`
with `newTransactionType :: TransactionType`); no migration path is
provided for streams written by the previous code.

No DB schema change (eventium stores payloads as JSONB).
