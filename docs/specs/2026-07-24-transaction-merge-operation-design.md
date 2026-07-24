---
status: draft
---

# Transaction Merge Operation

Tracking issue: **tracker#30**. Builds on the typed-relationship substrate landed in
**backend#88** (`docs/specs/2026-07-05-transaction-relationships-design.md`, closed) — that
spec delivered the `Merge` `RelationKind`, the `AddTransactionRelation` command, and the
reverse `Merge` index. This spec delivers the **merge operation itself**, which was an
explicit non-goal there.

## Summary

A **merge** consolidates two or more Completed transactions into one. The user picks a
**target** (the survivor) and one or more **sources**; the operation:

1. amends the target so it absorbs the **combined amount** and the **combined allocations**
   of the target plus every source; and
2. for each source, records a `Merge` lineage edge (source → target) **while the source is
   still Completed**, then cancels the source.

The decisive constraint — as with refunds — is **event-sourcing provenance**: the
source → target lineage is only capturable at the instant of the operation, so each edge is
recorded as a domain fact (an event) before the source is cancelled. After cancellation the
edge survives (the reverse `Merge` index deliberately keeps cancelled sources, per the
relationships spec), so the target can always be traced back to what fed into it.

The operation is modelled **exactly like amend and cancel**: a single triggering command
(`MergeTransactions`) whose entire downstream cascade — amend the target, per-source edge +
cancel, complete — is driven by a new process manager and **commits in one database
transaction**. It introduces a new command triple (`MergeTransactions` /
`CompleteTransactionMerge` / `FailTransactionMerge`), a new event triple
(`TransactionMergeInitiated` / `TransactionMergeCompleted` / `TransactionMergeFailed`), a new
process manager (`TransactionMergeManager`), a `mergeInProgress` projection flag, a new HTTP
endpoint, and a request DTO. It reuses the existing `AmendTransaction`,
`AddTransactionRelation`, and `CancelTransaction` command vocabulary for the cascade legs, so
there is **no read-model change** (the merge events are read-model no-ops; the amend already
moves the canonical facts).

## Decisions

1. **Atomic single-transaction saga.** This backend's sagas are crash-safe by **atomicity**,
   not async recovery: Eventium's synchronous, depth-first, in-process publisher runs the
   whole `…Initiated → process manager reacts → account debit/credit → …Completed` cascade
   inside one `runSqlPool` write. Merge is therefore modelled like amend/cancel — one
   `MergeTransactions` command whose cascade (target amend + per-source Merge edge + cancel +
   `CompleteTransactionMerge`) commits in a single transaction via `TransactionMergeManager`.
   A failing leg leaves no partial state, so there is **no `MergeIncomplete` outcome**.
2. **Target is the survivor.** `POST /api/transactions/:id/merge` — `:id` is the target;
   the body lists the source ids. The response is the refreshed target
   `TransactionResponse` (200), exactly like `POST …/relations` (`addRelationHandler`). The
   endpoint stays **200 synchronous**: by the time the service's `dispatchAndAwaitMerge`
   returns, the cascade has fully committed.
3. **All read-model work up front; the PM is pure over aggregates.** The service performs
   every read-model-dependent step before emitting `MergeTransactions`: compatibility guards,
   contact resolution, books-close gates, the combined amount + allocations, and — crucially —
   currency/amount resolution (`resolveAmounts`) and `TransactionType` synthesis
   (`synthesiseAmendmentTransactionType`). The fully-resolved amend payload is baked into
   `TransactionMergeInitiated`, because the process manager cannot touch the read model or ECB
   rates.
4. **Amend first, then per-source edge+cancel.** The saga amends the target first; only on
   `TransactionAmendmentCompleted` does it touch the sources. For each source the **edge is
   added before the cancel** — `AddTransactionRelation` only accepts a Completed
   `from`-aggregate, so the ordering is mandatory. The last source's
   `TransactionCancellationCompleted` triggers `CompleteTransactionMerge`.
5. **Guard matrix.** `MergeTransactions` is accepted only when the target is `Completed` and
   no amendment/cancellation/merge is already in flight. The saga-internal `AmendTransaction`
   (on the target, which now carries `mergeInProgress = True`) and `CancelTransaction` (on the
   sources) are **not** gated on `mergeInProgress`, so the whole cascade runs to
   `CompleteTransactionMerge` in the one transaction. Because everything commits atomically,
   the `*InProgress` flags are only ever `True` on uncommitted state and always `False` once
   committed — so a *user* can never observe (and therefore never start work against) an
   aggregate mid-saga.
6. **Contact rule (product owner).** Collect the distinct **non-empty** contact ids across
   target + sources. Zero or one distinct contact is allowed; the merged result carries that
   single contact if any (so a contact present on only some of the inputs is carried onto the
   survivor), otherwise none. Two different contacts is a hard error
   (`CannotMergeConflictingContacts`).
7. **Compatibility is strict.** All inputs must share the same account pair, the same kind
   (Income or Expense only — Transfer/Adjustment cannot be merged), and the same
   categorised-side currency. Anything else is a 422.

## Endpoint

```
POST /api/transactions/:id/merge
  :id  = target (survivor) transaction id
  body = { "sourceTransactionIds": [<uuid>, …] }   -- MergeTransactionsRequest
  200  → refreshed target TransactionResponse (combined amount + allocations)
```

An **empty** `sourceTransactionIds` is a field-scoped 400 validation error at the handler
(before the service is called). The `:id` and each source id are validated as UUIDs the
same way sibling handlers validate `Capture "id"`.

`Web.Types.MergeTransactionsRequest` mirrors the web client DTO
(`web src/api/types.ts`).

## Saga & ordering

**Service** (`Application.Services.TransactionService.mergeTransactions`, inside `runExceptT`)
— all read-model work, then a single emit:

1. `ensureCanModifyTransaction userId targetId` → target; require `status == Completed`
   (else `CannotEditUncompletedTransaction`).
2. Reject `source == target` and duplicate source ids (`CannotMergeTransactionWithItself`).
3. `traverse (ensureCanModifyTransaction userId) sources`; require each `Completed`. This
   also enforces same-owner / Editor+ on every input.
4. Pure compatibility guards over target + sources (see below).
5. Books-close gate on `target.date` and each source `.date`, fail-fast.
6. Compose the combined categorised amount (Σ categorised amounts, single currency) and the
   combined `Allocations` (concatenate `.incomes` and `.expenses` across all inputs via
   `allocationsOf`). By construction the sum matches, so `mkIncome`/`mkExpense` validation in
   the amend passes.
7. Fully resolve the target amend payload (`resolveAmendment` — the resolution half of
   `amendTransaction`, shared): Editor+ on the accounts, kind derivation, contact validation,
   `TransactionType` synthesis, and `resolveAmounts` against the actual account currencies.
8. Emit `MergeTransactions` with the resolved payload + ordered source list, then
   `dispatchAndAwaitMerge`: dispatch the command (which runs the whole cascade synchronously)
   and read the target stream for the terminal `TransactionMergeCompleted` /
   `TransactionMergeFailed`. Return the refreshed target, or surface the failure.

**Process manager** (`TransactionMergeManager`), all within the one write transaction:

1. On `TransactionMergeInitiated` (target = stream key) → issue `AmendTransaction` on the
   target (the pre-resolved payload), with compensation → `FailTransactionMerge`.
2. On `TransactionAmendmentCompleted` for that target → per source, in order,
   `AddTransactionRelation … Merge` (edge on the still-Completed source) **then**
   `CancelTransaction`.
3. On the last source's `TransactionCancellationCompleted` → `CompleteTransactionMerge`.
4. On `TransactionAmendmentFailed` for the target → `FailTransactionMerge` (carrying the amend
   reason). Because the amend is sequenced first, a failure applies no canonical change and
   issues no source edge/cancel — the pre-merge ledger and read model stay fully intact.

## Compatibility rules

Over the set *target + all sources*:

| Rule | Requirement | Violation |
|---|---|---|
| Account pair | all share the same `(sourceAccountId, targetAccountId)` | `CannotMergeDifferentAccounts` |
| Kind | all share one `kindOf`, and it is `IncomeKind` or `ExpenseKind` (Transfer/Adjustment rejected) | `CannotMergeIncompatibleKinds` |
| Currency | all share the categorised-side `Money` currency | `CannotMergeDifferentCurrencies` |
| Contact | ≤ 1 distinct **non-empty** contact id; merged result = that contact or none | `CannotMergeConflictingContacts` |
| Identity | no source equals the target; no duplicate source ids | `CannotMergeTransactionWithItself` |

## Error / HTTP status table

| DomainError | HTTP | Machine code |
|---|---|---|
| `CannotMergeIncompatibleKinds` | 422 | `CANNOT_MERGE_INCOMPATIBLE_KINDS` |
| `CannotMergeDifferentCurrencies` | 422 | `CANNOT_MERGE_DIFFERENT_CURRENCIES` |
| `CannotMergeDifferentAccounts` | 422 | `CANNOT_MERGE_DIFFERENT_ACCOUNTS` |
| `CannotMergeConflictingContacts` | 422 | `CANNOT_MERGE_CONFLICTING_CONTACTS` |
| `CannotMergeTransactionWithItself` | 422 | `CANNOT_MERGE_TRANSACTION_WITH_ITSELF` |
| `NotFound "Transaction"` (missing/invisible target or source) | 404 | `NOT_FOUND` |
| `CannotEditUncompletedTransaction` (non-Completed input) | 409 | `TRANSACTION_NOT_COMPLETED` |
| `CannotEditClosedPeriod` (closed period) | 409 | `CANNOT_EDIT_CLOSED_PERIOD` |
| `InsufficientFundsForAmendment` (target amend rejected — the only realistic merge failure) | 409 | `INSUFFICIENT_FUNDS_FOR_AMENDMENT` |
| empty source list | 400 | validation (`sourceTransactionIds`) |

There is **no `MergeIncomplete`**: the single-transaction cascade either commits wholly or
leaves the pre-merge state untouched. A `TransactionMergeFailed` (in practice the target
amend's insufficient-funds debit) is surfaced by `dispatchAndAwaitMerge` as
`InsufficientFundsForAmendment` (409), matching a standalone amend failure.

## Testing

- **Service (`test/Application/Services/TransactionMergeSpec.hs`):** happy two-Expense
  (target amount = sum, combined allocations, sources Cancelled, `Merge` edge source → target
  present); happy three-Income fan-in; contact rule (all-none → none; one-has → merged has it;
  two-different → `CannotMergeConflictingContacts`); reject different currency / different
  account / mixed kinds / transfer source / self-merge or duplicate / non-Completed source /
  closed period; **atomicity** — forcing the target amend to fail (insufficient funds) leaves
  the target unamended (amount + `amendmentCount` unchanged), sources Completed, and no
  `Merge` edges; ordering invariant (edge exists on a Cancelled source).
- **Process manager (`test/Application/ProcessManagers/TransactionMergeManagerSpec.hs`):**
  phase machine — `MergeInitiated → AmendTransaction`; `AmendmentCompleted → per-source
  edge + cancel, in order`; last `CancellationCompleted → CompleteTransactionMerge`;
  `AmendmentFailed → FailTransactionMerge`; and the compensation path that catches a
  self-rejecting guard on the amend leg.
- **Integration (`test/Integration/TransactionMergeIntegrationSpec.hs`):** end-to-end →
  read-model target reflects combined amount + allocations; sources Cancelled; reverse `Merge`
  lineage lists all sources; balances net; the produced `Merge` edge is un-removable
  (`removeTransactionRelation` → `CannotRemoveLineageRelation`); a forced failing leg leaves
  the pre-merge ledger fully intact (balance, statuses, target amount, no edges).
- **HTTP (`test/Web/API/TransactionMergeAPISpec.hs`):** 200 happy; 400 empty list; 404
  missing; 422 each incompatibility incl. conflicting contacts; 409 non-Completed / closed /
  insufficient-funds. No 409 `MERGE_INCOMPLETE` (removed).

## Deferred alternatives

- **Fully async durable forward-recovery.** A variant where merge is a long-running saga with
  its own persisted saga-instance stream, a checkpointed subscription that resumes after a
  crash, and a `202 Accepted` + polling API. Rejected as unnecessary: because the entire
  cascade already commits in one database transaction, there is no durable intermediate state
  to recover — a crash rolls the whole merge back. The synchronous 200 endpoint is simpler and
  gives the caller the finished result.
- **`uncancel`-based compensation.** Compensating a partial merge by un-cancelling sources and
  reversing the amend. Rejected: an `uncancel` can itself fail (it re-posts, which can hit
  insufficient funds), so it is not crash-safe without persisted saga state, and it would
  leave non-removable `Merge` lineage edges behind. Single-transaction atomicity avoids the
  problem entirely.

## Non-goals

- No new `Merge` `transactionType` — the survivor stays an Income/Expense; lineage lives on
  the `Merge` edges.
- No read-model change — the merge events are read-model no-ops; the amend moves the canonical
  facts.
- No split operation (tracker#31) — separate feature.
- No cross-account, cross-kind, or cross-currency merge — explicitly rejected (422).
- No partial-failure outcome — the single-transaction cascade is all-or-nothing, so
  `MergeIncomplete` is removed.
