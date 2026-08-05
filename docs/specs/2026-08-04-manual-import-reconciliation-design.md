---
status: completed
issues: [homeaccounting/backend#148]
related: [homeaccounting/tracker#50, homeaccounting/tracker#44]
---

# Manual ↔ import reconciliation: prevent duplicate/double-spend

## Context

A user can record a transaction **manually** on an account that is also linked to a
bank provider, and then **later import** the same real-world movement via the
bank-import module. Today the two are treated as independent transactions, so the
account balance is debited/credited **twice** — a double-spend / double-count.

Import deduplication is keyed **exclusively** on `ExternalTransactionId`:

- `Application.ReadModels.BankImportReadModel` records a permanent
  `(externalTransactionId → transactionId)` mapping (`imported_transactions`) and
  exposes `isImported`.
- `BankImportService.importTransaction` / `importTransferPair` skip a transaction only
  when `isImported` returns `True`.

Manual entries carry no `ImportInfo` / `externalTransactionId`, so they never populate
that table, and a later import of the same movement sees no dedup hit and books a
second ledger entry. The current mechanism only protects **import ↔ import**, not
**manual ↔ import**.

This spec adds a **fuzzy reconciliation** step: when an import has no exact external-id
hit, match it against existing manual transactions on the same account; on a confident
(unique) match, **attach** the incoming external id (+ MCC) to that manual transaction
— recording it in the dedup read model — instead of booking a new entry.

## Scope and non-goals

**In scope (approach A — conservative auto-only):**

- Confident, unique fuzzy match ⇒ auto-reconcile (adopt attribution onto the existing
  manual transaction; no second ledger entry).
- Ambiguous match (≥2 candidates) ⇒ **skip** the import leg with a new, distinct skip
  reason (`AmbiguousReconciliation`). This is a clean seam, later upgraded to
  *draft-on-ambiguous* once tracker#50 (Draft status) lands.
- Transfers: a two-leg import that matches a single manual `Transfer` reconciles as a
  whole (both external ids attached).
- Restructure the existing transfer-matching primitives into a shared
  `Domain.Transaction.Matching` namespace and add the reconciliation matcher.

**Non-goals (explicit deferrals):**

- **No review-queue subsystem** (option B). Ambiguity is skipped, not queued.
- **No `Draft` status** here. Split out to tracker#50; this spec only leaves the
  ambiguous seam clean so draft-on-ambiguous is a small follow-up.
- **No per-leg reconciliation of a transfer against two *separately* recorded manual
  entries** (a manual expense on A + a manual income on B that later imports as a
  detected internal transfer). That is really "merge two manual entries into a
  transfer" — the transfer-merge feature's job (tracker#44). Documented as a known v1
  limitation.
- **No amount fuzzing.** Amounts must match exactly; fuzzing money is where false
  merges happen.
- **No description/MCC matching** in v1 (manual descriptions rarely match a bank
  merchant string; MCC exists only on the bank side).

## §1 — Matching rule

An import, after the existing resolution, yields: local account **L**, currency **C**,
absolute amount **M**, direction **D** (income/expense), business date **T**. A manual
candidate transaction reconciles with it iff **all** of:

- **Pure manual entry** — the candidate `txId` is *not* already present in
  `imported_transactions` (reverse lookup on the existing dedup table). This excludes
  already-imported/already-reconciled transactions and prevents re-reconciling.
- **`Completed`** — not `Pending` / `Failed` / `Cancelled` (later: not `Draft`).
- **Correct leg for the direction** — expense ⇒ L is the *source* leg; income ⇒ L is
  the *target* leg (mirrors `classifyEndpoints`).
- **Exact amount + currency on that leg** — the candidate's local-leg amount equals
  **M** in **C**. Because the bank amount is already in L's currency, no FX enters the
  comparison.
- **Kind matches direction** — an `Income` candidate for income, `Expense` for expense.
- **Date within ±W days of T.** `W = 3` days, a constant to start (not yet a config
  field; surface later only if needed).

Decision:

| Candidates within tolerance | Action |
|---|---|
| exactly 1 | **Reconcile** — attach external id (+MCC) to that manual transaction; no new entry |
| 0 | **Import as new** (today's behaviour) |
| ≥ 2 | **Skip** with `AmbiguousReconciliation` (never guess a merge) |

## §2 — Transfers (two-leg import)

`importTransferPair` gains reconciliation ahead of the fresh post:

1. **Either leg already external-id-imported** ⇒ today's unwind path, unchanged.
2. **Neither imported** ⇒ try a **whole-pair match against a single manual `Transfer`**
   (touches both local accounts, matching leg amounts + currency, within ±W). A **unique**
   match ⇒ reconcile, attaching **both** legs' external ids to that manual transfer.
3. **No manual-transfer match** ⇒ post the fresh single `Transfer` exactly as today
   (does not regress the common no-manual-entry case).

The "two separately recorded manual legs" case is the documented non-goal above.

## §3 — Event, command, read-model, and audit wiring

### New command → event

`ReconcileTransactionImport` → `TransactionImportReconciled` (command name mirrors the
emitted event, per repo convention), on the **existing manual transaction's** stream.

- Payload: `externalTransactionIds :: NonEmpty ExternalTransactionId` (one for a plain
  income/expense reconcile; both legs for a transfer reconcile) and `mcc :: Maybe MCC`.
  Shape mirrors `ImportInfo`.
- **Balance-neutral** — pure attribution, no leg/amount change. Sibling in spirit to
  `TransactionContactSet`.
- **No `by`.** Per the actor-field rule this is a system-driven metadata attachment, not
  a whole-aggregate lifecycle action (create/amend/cancel), so it carries no actor.

### Aggregate command handler (`Domain.Transaction`)

`ReconcileTransactionImport` is accepted only when the target transaction exists, is
`Completed`, and is not already reconciled — keeping it idempotent/safe even though the
service pre-filters candidates. Emits `TransactionImportReconciled`.

### `Domain.Transaction.Projection` (aggregate)

Fold `TransactionImportReconciled` into a `reconciled :: Bool` flag on the transaction
aggregate state, so the command handler's "not already reconciled" guard is actually
enforceable (the pure handler can only guard on state the projection carries). This is
defense-in-depth — the service already pre-filters reconciled candidates — but the
guard's state must live somewhere, and this is it.

### `BankImportReadModel`

Extend `applyBankImportEvent` to also project `TransactionImportReconciled` into
`imported_transactions` (one `externalTransactionId → transactionId` row per external
id, via the same idempotent `insertUnique`). This is what makes **re-sync idempotent**:
the next import of the same movement sees the id through the ordinary `isImported` path
and skips (`AlreadyImported`).

The candidate-exclusion reverse lookup (§1: "candidate `txId` not already in
`imported_transactions`") is keyed on `transaction_id`, which the table does **not**
currently index (its only index is `UniqueExternalTransactionId` on
`externalTransactionId`). Add a `transaction_id` index and expose a
`isReconciled :: TransactionId -> SqlPersistT m Bool` query so the exclusion is an
indexed lookup, not a full scan.

### `Transaction` read model

`applyTransactionEvent` handles `TransactionImportReconciled` by updating the manual
row's `mcc` from the event (the reconciled entry gains the merchant code, consistent
with tracker#37 MCC surfacing). No other row field changes. **Overwrite semantics:** a
reconcile whose event `mcc = Nothing` leaves the existing row `mcc` untouched (it never
clobbers a present value back to `Nothing`).

### Audit history parity (per CLAUDE.md)

Add a matching `TransactionHistoryEntry` constructor and a
`TransactionHistoryService.toHistoryEntry` case for `TransactionImportReconciled`
("reconciled with bank import"), so the event is not silently dropped from the audit
trail (`toHistoryEntry` is a `mapMaybe`).

### Backward compatibility

`TransactionImportReconciled` is a **brand-new** event type — additive. It is registered
in the Template-Haskell event list, the `AccountingEvent` sum, and the schema registry
(`eventTypeOf` tag + `schemaVersion` v1). **No upcaster** is required (no existing event
changes shape). It gets its own encode/decode fixture test in
`Infrastructure.Eventium.SchemaSpec`.

## §4 — `Domain.Transaction.Matching` restructure

Today `Domain.Transaction.TransferMatch` (pure) holds `TransferDirection`,
`TransferLeg c`, and `isTransferMatch`, shared by `Infrastructure.Banking.Provider`
(import transfer-pairing) and `Application.Services.TransactionService` (manual
income+expense → transfer merge). Promote it to a namespace and add the reconciliation
matcher:

```
Domain.Transaction.Matching.Leg            -- shared kernel
Domain.Transaction.Matching.Transfer       -- relocated TransferMatch
Domain.Transaction.Matching.Reconciliation -- new (this issue)
```

- **`.Leg`** — extracted kernel: normalised `Leg c { magnitude :: Rational, currency ::
  c, time :: UTCTime }` and `sameMovement :: Eq c => NominalDiffTime -> Leg c -> Leg c ->
  Bool` = equal magnitude ∧ equal currency ∧ within window. Both matchers stand on this.
- **`.Transfer`** — `TransferDirection` + `isTransferMatch = opposite-direction ∧
  sameMovement`, rebuilt on `.Leg`. The two existing call sites repoint here; because it
  is all in-repo (no external compat), the module is moved outright rather than shimmed.
- **`.Reconciliation`** — the pure heart of this issue:
  - `isReconciliationMatch :: Eq c => NominalDiffTime -> Leg c -> Leg c -> Bool` =
    same-direction ∧ `sameMovement` (same side, unlike transfer's opposite).
  - `reconcile :: Eq c => NominalDiffTime -> Leg c -> [(a, Leg c)] ->
    ReconciliationOutcome a`, where
    `data ReconciliationOutcome a = NoMatch | UniqueMatch a | Ambiguous [a]`.
    This expresses the whole §1 decision purely over candidate legs keyed by `a`
    (a `TransactionId`).

The Application service builds candidate `Leg`s from a new `Transaction` read-model
query, calls `reconcile`, and acts on the outcome: `UniqueMatch` ⇒ issue
`ReconcileTransactionImport`; `NoMatch` ⇒ post fresh; `Ambiguous` ⇒ skip
`AmbiguousReconciliation`. Transfer pairing keeps its Application-level one-to-one
resolution but now shares the `.Leg` kernel through `.Transfer`.

Style note: the existing `TransferMatch` module carries no LiquidHaskell annotations
(pure predicates, no smart constructors); the new modules match that light style, adding
refinements only where a genuine invariant/smart-constructor exists.

## Where the logic runs

In `BankImportService.importTransaction` (and `importTransferPair`), between the failed
`isImported` check and the fresh post: query candidates via a new `Transaction`
read-model query (Completed, correct leg on account L, exact amount+currency, kind,
within ±W), exclude those already in `imported_transactions`, build `Leg`s, and call
`Domain.Transaction.Matching.Reconciliation.reconcile`.

### Concurrency — both import paths must be serialized

The candidate-select → reconcile step is a read-then-act TOCTOU: two concurrent imports
for the same user could both see "no match" and each post a fresh entry, or one could
reconcile while the other posts. The serialization primitive is `withUserLock userId`,
but **today only the pull path holds it** — `importConnection` wraps its work in
`withUserLock`, while the **file-import path calls `importMany` directly from
`Web.API.BankingAPI` with no lock** (and file import is the actively-expanding path).
The stated race-safety is therefore currently false for file imports.

The plan must serialize **both** paths through the shared sink. Preferred: relocate
`withUserLock userId` down into `importMany` (the single shared entry point for both
paths) and drop it from `importConnection` — noting the lock is **non-reentrant**
(`Infrastructure.App`), so it must live at exactly one level; moving it into `importMany`
means `importConnection`'s provider fetch runs *outside* the lock (harmless — fetches are
read-only network) and the lock covers only the import/reconcile work. Alternatively,
acquire the lock at the file-import handler to mirror `importConnection`; either way
`importMany` must never be reachable unlocked.

Independently of the lock, two constraints backstop idempotency: the aggregate's
"not already reconciled" guard (§3) prevents a second reconcile of the same manual
transaction (enforced via optimistic concurrency on that stream), and the
`imported_transactions` `UniqueExternalTransactionId` constraint prevents the same
external id being recorded twice.

New `Transaction` read-model query (sketch):

```haskell
-- Completed manual candidates on `account` on the given leg side, exact amount, kind,
-- within [T-W, T+W], excluding txIds already present in imported_transactions.
findReconciliationCandidates
  :: MonadIO m
  => AccountId -> LegSide -> Money -> TransactionKind -> Range UTCTime
  -> SqlPersistT m [(TransactionId, TransactionData)]
```

## Testing

Pure (primary — property tests over `reconcile`, no event store):

- Exact match (same account leg, equal amount, same day) ⇒ `UniqueMatch`.
- Near match within ±W (amount equal, date offset ≤ W) ⇒ `UniqueMatch`.
- Two genuinely distinct same-amount, same-day candidates ⇒ `Ambiguous` (**must not**
  merge).
- Off-by-more-than-W date, or differing amount/currency ⇒ `NoMatch`.
- `sameMovement` / `isTransferMatch` / `isReconciliationMatch` kernel laws (symmetry
  where applicable, window boundary inclusive).

Integration (event store):

- Manual expense then import of the same movement ⇒ one ledger entry; balance reflects
  it once; external id recorded in `imported_transactions`.
- **Re-sync idempotency** — re-importing after reconcile ⇒ `AlreadyImported`, no change.
- Transfer: manual `Transfer` then import of the detected pair ⇒ reconciled once; both
  external ids recorded.
- Ambiguous ⇒ `AmbiguousReconciliation` skip; no new entry, no reconcile event.
- Schema fixture: `TransactionImportReconciled` encode/decode round-trip in
  `SchemaSpec`.
- Audit trail includes the reconciliation history entry.

## Acceptance criteria (from #148)

- Importing a bank transaction that matches an already-recorded manual transaction does
  **not** create a second ledger entry; the balance reflects the movement once. ✔ §1/§3
- The reconciliation decision (auto vs. skip) is deterministic and testable. ✔ §4
  (`reconcile` is a pure total function).
- Once reconciled, subsequent re-syncs of the same external transaction remain
  deduplicated. ✔ §3 (`BankImportReadModel` projects the reconcile event).
- Transfer (two-leg) imports are covered. ✔ §2 (whole-pair reconcile; per-leg-of-a-pair
  deferred to tracker#44, documented).
- Property/integration tests cover exact, near, distinct-same-amount-same-day, and
  re-sync idempotency. ✔ Testing.
</content>
</invoke>
