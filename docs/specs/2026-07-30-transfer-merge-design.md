---
status: draft
---

# Merge an Income + Expense Pair into a Single Transfer

Tracker: homeaccounting/tracker#44

## Problem

An internal transfer between two of the user's own accounts is often recorded as
**two independent transactions** whenever the two legs enter the system by different
means:

- **Different providers** — money moved PrivatBank → Monobank: the PrivatBank export
  records an `Expense`, the Monobank sync records an `Income`, each in its own import.
- **A bank with no import** — e.g. Sense Bank exposes no pull/export, so its leg is
  entered by hand while the other bank's leg is imported.
- **Cash / pocket accounts** — an ATM cash-out is an imported bank `Expense` paired with
  a manual `Income` on a cash account (cash accounts are never imported).

Import-time internal-transfer detection (#143,
`Application.Services.BankImport.TransferPairing`) pairs the two legs **only within a
single import batch** via a provider-supplied `TransferMatcher`. It structurally cannot
join legs that arrive from different providers, from an import + a manual entry, or from
a bank that cannot be imported at all. The user is left with a phantom `Expense` on one
account and a phantom `Income` on the other — inflating both spend and income totals —
with no way to reconcile them into one movement.

## Goal

Let the user select an existing `Income` + `Expense` pair that is really one transfer and
merge them into a single `Transfer`, regardless of how each leg was recorded.

The merge:

1. **Converts the Income leg into a `Transfer`** (the survivor). Its source account
   becomes the Expense leg's real account; its own account stays the destination. Amount
   and currency are unchanged, and it **keeps the Income leg's date and description**.
2. **Cancels the Expense leg.**
3. **Records a `Merge` lineage edge** (expense → resulting transfer) so the event log
   captures why the Expense was cancelled and what absorbed it.

## Non-goals (v1)

- **Automatic detection / suggestion** of candidate pairs. v1 is user-initiated manual
  selection; a detection layer that reuses this same merge operation is a follow-up.
- **Cross-currency transfers** (send UAH, receive USD). Different amounts + an FX rate are
  explicitly out of scope; v1 requires equal `Money` (same amount ∧ same currency).
- **Multi-source transfer-merge.** Exactly one Expense merges into one Income.

## Design

### Trigger — reuse the existing merge endpoint

No new endpoint or DTO. The client uses the existing
`POST /api/transactions/:id/merge` with `MergeTransactionRequest { sourceTransactionIds }`:

- `:id` = the **Income** transaction (the survivor).
- `sourceTransactionIds = [expenseId]`.

`mergeTransactionsHandler` and `MergeTransactionRequest` are unchanged. The empty-source
400 stays. The client is responsible for passing the Income as `:id`.

### Shared matching criterion — new pure Domain module

The generic "are these two legs the same movement?" criterion is today entangled in the
import-only stack (`TransferPairing` + the provider `TransferMatcher` in
`Infrastructure.Banking.Provider`). Extract the **generic** part into a shared, pure
Domain module so both import and merge use one definition:

```haskell
-- Domain.Transaction.TransferMatch
data TransferDirection = DebitLeg | CreditLeg

data TransferLeg = TransferLeg
  { direction :: TransferDirection
  , amount    :: Money      -- absolute; Money carries currency, so Eq covers amount ∧ currency
  , at        :: UTCTime
  }

newtype TransferMatchWindow = TransferMatchWindow NominalDiffTime

-- opposite direction ∧ equal Money ∧ |Δt| ≤ window
isTransferMatch :: TransferMatchWindow -> TransferLeg -> TransferLeg -> Bool
```

Because `Money` equality already covers "same amount ∧ same currency," the amount/currency
check collapses to a single `Money` equality.

**Consumers**

- **Bank import** projects `BankTransaction → TransferLeg` (signed `amount` → direction).
  Its *default* `TransferMatcher` becomes `isTransferMatch importWindow`; provider-specific
  matchers (e.g. PrivatBank's self-labelled "На свою картку") compose on top of the generic
  criterion. The greedy one-to-one pairing engine in `TransferPairing` is retained and
  simply calls the shared predicate as its "same movement?" test.
- **Merge** projects the two domain `Transaction`s → `TransferLeg`
  (`Expense → DebitLeg`, `Income → CreditLeg`) and calls `isTransferMatch mergeWindow`.

**Windows are named constants.** Import uses a strict window (the existing ±5 min); the
merge uses a **more relaxed** window, because a manually-selected pair may be dated further
apart (settlement lag, day-level manual dates). Both share one predicate; only the
tolerance differs.

**Layering.** The criterion is pure business logic over `Money`/`UTCTime`, so it lives in
`Domain`. `BankTransaction → TransferLeg` is projected in Infrastructure (which may import
Domain); `Transaction → TransferLeg` is projected in Domain. All layering arrows remain
valid.

### Merge service — the transfer-merge branch

`Application.Services.TransactionService.mergeTransactions` gains a branch: when the target
and its single source are **opposite kinds** (one `Income`, one `Expense`), it routes to
transfer-merge instead of the existing same-kind allocation merge. The branch must run
**before** the existing `guardMergeCompatible`, which rejects opposite kinds with
`CannotMergeIncompatibleKinds` — the two merge modes are dispatched on kind, not collided.

**Guards** (typed `DomainError`s, reusing the existing merge-error vocabulary):

- exactly **one** source
- target + source are opposite `Income`/`Expense` kinds
- **different real accounts**
- `isTransferMatch mergeWindow` holds for the two projected legs (equal `Money`, opposite
  direction, within window)

**Amend payload for the survivor (the Income):**

- `newSourceAccountId` = the Expense's real account (`expense.sourceAccountId`, the debited
  `Regular` account)
- `newTargetAccountId` = the Income's real account (`income.targetAccountId`, the credited
  `Regular` account)
- → `deriveTransactionKind Regular Regular = TransferKind`
- `newSourceAmount = newTargetAmount` = the shared `Money`; `newExchangeRate = Nothing`
- `newAllocations = Nothing` (a `Transfer` carries no allocations — the Income's
  allocations are dropped)
- `contactId = Nothing` (a transfer between the user's own accounts has no counterparty)
- `sourceTransactionIds = [expenseId]`, `by = current user`

The payload is routed through the shared `resolveAmendment` (the same resolver the same-kind
merge uses), which derives `TransferKind` from the `Regular`/`Regular` account pair and
re-resolves the amounts/rate/type. Under the equal-`Money` / same-currency constraints that
re-resolution is a no-op, so the outcome equals a directly-built payload — reuse just keeps
the two merge paths on one resolver.

The service emits `InitiateTransactionMerge`. The merge **command, event, and HTTP endpoint
are reused unchanged**; `TransactionMergeManager` changes only to set `allowOverdraft = True`
on the amend it issues (see the balance guard below). The existing cascade runs atomically:
amend the Income → `AddTransactionRelation (Merge, expense → income)` → cancel the Expense →
`CompleteTransactionMerge`. Date and description are untouched by the amendment, so the
survivor keeps the Income leg's values automatically.

### Balance guard during the amend — requires an amend-command change

The saga amends the Income (currently a credit) into a `Transfer` that **debits the
Expense's account** *before* the Expense's own debit is reversed by the subsequent cancel.
The account is therefore transiently double-debited (original expense still live + new
transfer debit), which could trip the overdraft guard on an otherwise-valid merge. These
are already-settled facts (as with imports), so the merge-originated amend must **bypass the
balance guard**.

This bypass is **not free**, and this is the one place the plan must touch shared,
pre-existing machinery:

- `TransactionAmendmentManager` currently **hard-codes** `allowOverdraft = False` on the
  new-source `DebitAccount` ("User-initiated amendment: keep the balance guard"), and
  neither `InitiateTransactionAmendment` nor `TransactionAmendmentInitiated` carries any
  flag to change that.
- **Change (additive):** add an `allowOverdraft :: Bool` field to
  `InitiateTransactionAmendment` **and** `TransactionAmendmentInitiated`, read by
  `TransactionAmendmentManager` when issuing the `DebitAccount`. It **defaults to `False`**,
  so ordinary user-initiated amendments keep the guard exactly as today.
- `TransactionMergeManager` issues its amend with `allowOverdraft = True` (all
  merge-originated amends are settled-fact reconciliations). The ordinary amend web handler
  passes `False`. **Do not flip the guard globally** — it is gated to the merge-originated
  amend only.

Net balances after the cascade are correct: the Expense's account is debited exactly once
(original expense reversed by the cancel, re-applied by the transfer), and the Income's
account is credited exactly once (unchanged by the amend). This ordering + bypass is the one
spot requiring a deliberate integration test.

Under the no-backward-compat policy, adding the `allowOverdraft` field to the amend command
and event is a clean shape change (the event is a wire/DB-visible addition; no upcaster
needed).

### Read model

No changes. Existing `applyTransactionEvent` already handles every emitted event:
`TransactionAmendmentCompleted` rewrites the Income row into a `Transfer` (accounts,
amounts, type, bumped `amendmentCount`); `TransactionCancellationCompleted` flips the
Expense row to `Cancelled`; `TransactionRelationAdded` inserts the `Merge` edge into
`transaction_relations`.

### History / audit parity

`Application.Services.TransactionHistoryService.toHistoryEntry` currently drops the merge
and relation events (`TransactionMergeInitiated/Completed/Failed`,
`TransactionRelationAdded/Removed`) through its `_ -> Nothing` catch-all — a pre-existing
gap since #30. Per the audit-parity rule (a new user-visible transaction event must be
mapped if its siblings are), this work **adds history entries for the merge and relation
events in-scope**, with matching `TransactionHistoryEntry` constructors, so a transfer-merge
is visible in the audit trail on both the survivor and the cancelled leg. This adds new
`TransactionHistoryEntry` constructors and their JSON — a wire-visible DTO addition (clean
under the no-backward-compat policy).

## Error handling

Two new typed `DomainError` values guard the transfer-merge branch, following the existing
merge guard style (`guardMergeCompatible`):

- `TransferMergeSameAccount` — the income and expense resolve to the same account.
- `TransferMergeLegsDoNotMatch` — the legs fail `isTransferMatch` (unequal `Money`, same
  direction, or outside the merge time window). One bundled error, since a manually-selected
  pair that isn't a transfer is a single "these two aren't a transfer" condition.

Shapes that are *not* a transfer-merge at all reuse the existing same-kind error rather than
adding new vocabulary: a target that isn't an Income, a source that isn't an Expense, or
more than one source all fail the `asTransferMerge` classifier and fall through to the
same-kind path, where `guardMergeCompatible` rejects the incompatible kinds with
`CannotMergeIncompatibleKinds`.

## Testing

- **Property** (`Domain.Transaction.TransferMatch`): symmetry of `isTransferMatch`; window
  boundary (inclusive at the edge); opposite-direction requirement; `Money` inequality
  (amount or currency) ⇒ no match.
- **Unit** (service guards): rejects same-kind, same-account, unequal-`Money`, and
  multi-source inputs with the correct `DomainError`; accepts a valid Income+Expense pair
  and builds the expected `InitiateTransactionMerge` payload (accounts, amounts, `Transfer`
  type, `Nothing` allocations/contact, single source).
- **Integration**: income + expense → merge → a single `Transfer` with source =
  expense's account and target = income's account; expense `Cancelled`; `Merge` edge
  present (expense → transfer); **both account balances net correct**; plus the
  overdraft-bypass scenario from the balance-guard section.
- **Amend-guard regression**: an ordinary user-initiated amendment (default
  `allowOverdraft = False`) still rejects an over-balance debit — proving the merge bypass
  did not flip the guard globally.
- **History**: the merge + relation events appear in `getTransactionHistory` for the
  survivor and the cancelled leg.
- **Import regression**: existing `TransferPairing` / #143 tests continue to pass after the
  predicate extraction (the default `TransferMatcher` now delegates to `isTransferMatch`).

## References

- homeaccounting/tracker#44 — this feature.
- #143 / `docs/specs/2026-07-29-import-internal-transfer-detection-design.md` — import-time
  detection this generalizes beyond a single import batch; source of the reused matching
  criterion.
- #30 / `docs/specs/2026-07-24-transaction-merge-operation-design.md` — the merge command,
  event, saga, and lineage backbone reused here (`InitiateTransactionMerge`,
  `TransactionMergeManager`, `Merge` relation kind).
- #34 — explicit transaction relations; the `Merge` lineage edge between the cancelled
  Expense and the resulting Transfer.
