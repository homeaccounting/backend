# 006 - Import attribution is capacity-limited, not once-only

## Status
Accepted

## Context

A transaction's `reconciled` field — a boolean guard introduced to prevent a double
attach — became incorrect when a single logical transfer with two accounting legs
appeared on the write side. Each leg receives its own import attribution from the
bank statement, so rejecting the second leg's reconcile outright meant that
single-leg imports could not match existing transfers. The field was documented
as "guard against a double attach" and the aggregate enforcement enforced it
strictly, so legacy code (and later maintainers) had no way to distinguish between
"this transaction is already fully attributed" and "this transaction is not a
transfer."

The defect surfaced on backend#3 when a converted-to-transfer re-import could not
reconcile onto an existing transfer: the source leg matched as expected, but the
target leg's reconcile command was rejected by the boolean guard, even though the
transfer was only half-attributed. Both legs then imported as new transactions,
duplicating the movement.

## Decision

1. **Import attribution is capacity-limited, not once-only.** The `reconciled`
   boolean is replaced by counting attributed external ids. Each `TransactionType`
   has an attribution capacity: transfers (two legs) get 2, and income/expense (one
   movement) get 1.

2. **The capacity rule has one definition.** `importAttributionCapacity :: TransactionType -> Int`
   lives in `Domain.Core.Types` with a single home, so the write-side aggregate
   guard (`Domain.Transaction.CommandHandler`) and the import-side candidate
   filter (`Application.Services.BankImportService`) can never derive the
   *capacity* differently — the duplicate-posting bug (backend#3) was a
   consequence of them drifting apart on how many legs may attach.

   What is shared is the capacity, **not the count**, and deliberately so: the
   two count from different sources. The filter's `importAttributionCount` reads
   the `imported_transactions` read model, which the projection fills from
   `TransactionPostingInitiated`-with-`importInfo` *as well as*
   `TransactionImportReconciled`; the aggregate folds only the latter. So an
   import-*created* transaction has read-model count 1 and aggregate count 0.
   The read-model count is a superset, hence always the safe side — the filter
   is strictly more conservative than the aggregate, and for an import-created
   transaction the stricter answer is also the correct one (it already carries
   its own bank id). Making the two symmetric by counting the aggregate's ids on
   the import side would re-open a duplicate-posting path; the asymmetry is the
   design, not drift.

3. **It counts attributed external ids, not events.** The whole-pair transfer path
   emits a single `TransactionImportReconciled` event carrying two ids
   (one per leg), so counting events would leave a fully-attributed transfer with
   spare capacity.

4. **Behaviour for income/expense is preserved bit-for-bit:** 0 attributions
   allowed, then 1 allowed, then rejection — exactly what the boolean `0 + 1 = 1
   (clamped to boolean true, reject)` did.

5. **It is retroactive and needs no migration.** The count folds from the same
   `TransactionImportReconciled` events the boolean did, so a production transfer
   already reconciled on one leg replays to a count of 1 and gains its second slot
   automatically. The aggregate is never persisted or snapshotted, so no stored
   shape changed and no upcaster is required.

6. **The error name was deliberately reused.** `TransactionAlreadyReconciled` is
   still the error case — when a transaction's capacity is full and another id
   arrives. This keeps the change additive; the error message remains the same.

### Out of scope (deliberately not changed)

- **Per-leg attribution.** The current limit counts ids per transaction side,
  not per leg. A same-side over-attaching scenario — a transfer whose source leg
  absorbs two unrelated expense ids — remains possible (e.g. an unrelated
  same-amount expense with no same-kind candidate could attach to the source leg,
  and the transfer's own debit leg could then take the second slot). This follows
  from the id-counting choice and is the same mis-attribution class the
  same-kind-first ordering in the matching logic already tolerates. It is a known
  residual limitation, deferred pending a specific requirement for per-leg
  attribution.

  **What it costs when it happens, spelled out:** the absorbed import never
  posts. There is no duplicate to delete and no error — the transaction is
  simply missing, the account balance is understated by its amount, and because
  bank-import dedup is permanent by design its external id is now bound to the
  transfer forever, so a re-sync will not bring it back. The only recovery is
  manual re-entry. Round amounts are exactly what both transfers and cash
  spends use, so this is not an exotic shape.

  Two mitigations, neither a fix: the cross-kind pass runs on its own **±1 day**
  window (`transferLegReconciliationWindow`) rather than the ±3 days used for
  same-transaction reconciliation — it cannot go below 24h, because a
  date-picker client sends a midnight date and a legitimate same-day pair is
  already ~24h apart — and every cross-kind attach emits a `logWarn` naming the
  external id, transaction and amount (grep `cross-kind reconcile`), so the
  suppression leaves a trace the user can find instead of being invisible.

## Consequences

- **Transfers can be reconciled on both legs.** A single-leg import now gains
  capacity to match an existing transfer without rejecting the second leg's
  reconcile, fixing the core of backend#3.
- **The rule is durable.** One source of truth (`importAttributionCapacity`)
  eliminates the coordination bug that allowed the boolean guard and the filter
  to drift apart on capacity. Their *counts* stay intentionally asymmetric (see
  Decision 2), which a maintainer must not "correct".
- **No migration needed.** Existing production transfers already reconciled on one
  leg replay to a count of 1 and gain capacity for the second leg automatically.
- **Backward compatible.** For income/expense, `0 → 1 → rejected` is identical to
  the boolean `false → true → rejected`. The semantic change is single-direction:
  transfers go from fully-rejected-if-any to properly-pairwise.
- **Honest about residual risk.** Per-side counting leaves an edge case where both
  ids land on one leg of a transfer. This is documented and deferred, not hidden
  by claiming the rule is perfect.
