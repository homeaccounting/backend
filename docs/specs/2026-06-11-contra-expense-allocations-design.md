---
status: completed
date: 2026-06-11
depends_on:
  - 2026-05-30-transaction-allocations-design.md
---

# Contra-Expense Allocations (Reimbursements)

## Problem

When a user spends money and is later compensated for part of it, there
is no honest way to record the compensation. Today a transaction is a
flow between two accounts whose direction fixes its kind
(`deriveTransactionKind`: Regular→External = `Expense`, External→Regular
= `Income`), and **every categorised amount must be positive** —
enforced at three layers: the `TransferAmountNotPositive` guard, the
`mkAllocation` smart constructor, and the LiquidHaskell refinement
`{m : Money | (amount m) > 0}` on `Allocation`.

So the only way to record "an expense was reduced" is to book a separate
`Income`. That is the wrong accounting treatment: it **inflates both
total income and total expense**. The user did not earn the money back —
they un-spent it. The professionally correct treatment is a
**contra-expense**: the inflow is netted against the original expense
category so net spending in that category falls, income untouched. This
is what personal-finance tools call a "reimbursement."

A second, sharper case makes a single transaction-type tag insufficient.
A user receives **one** transfer of $5500: $5000 salary plus $500 to
cover rent. They later pay $500 rent. The economically correct picture:

| Category | Amount | Effect |
|----------|--------|--------|
| Salary (income)  | $5000 | +income |
| Rent (expense)   | $500  | −expense (reimbursement) |
| Rent (expense)   | $500  | +expense (the rent payment) |

Net rent expense = $0, salary income = $5000, net cash = +$5000 — which
matches the account balance (`+5500 − 500`). To express this, **one
inbound transfer must carry both income allocations and contra-expense
allocations at once**. The current `TransactionType` carries a single
`Income` XOR `Expense` tag and validates *all* allocations against *one*
category dictionary, so the mix cannot be expressed — and a standalone
`Reimbursement` type would not help, because a transaction has exactly
one type.

This spec promotes `Allocations` from a flat `NonEmpty Allocation` into a
**two-bucket record** — income-dictionary categories and
expense-dictionary categories — and derives each allocation's sign from
the **flow direction** plus the **bucket**, never from a negative
amount. The `amount > 0` invariant is preserved everywhere.

## Non-goals

- **Contra-income** (an outflow that nets down an income category, e.g. a
  salary clawback). YAGNI — no real case today. The type *forbids* it
  (see validation), so it cannot be constructed by accident; adding it
  later is a localized change.
- **Server-side per-category reporting.** No category-aggregation read
  model exists today, and this spec does not add one. Scope is the
  **domain model + storage** that makes correct netting possible; the
  netting sign rule is documented as a contract (§ Reporting contract)
  for whoever computes totals.
- **Posting / balance changes.** All three sagas (posting, cancellation,
  amendment) move only the `sourceAmount`/`targetAmount` totals and never
  inspect allocations; contra-expense is purely a categorisation concern.
- **Linking a reimbursement to the specific expense it offsets.**
  Reimbursements are category-tagged only. No "refund-of-transaction-X"
  relationship, no validation that a reimbursement ≤ original spend.

## Goals

1. `Allocations` becomes a record with two buckets: `incomes`
   (income-dict categories) and `expenses` (expense-dict categories).
   `TransactionType` keeps its `Income` / `Expense` / `Transfer` /
   `Adjustment` constructors — only the payload shape changes.
2. A single inbound (`Income`) transaction may carry both buckets: the
   income bucket adds income, the expense bucket reduces expense
   (reimbursement). Either bucket may be empty; not both.
3. Outbound (`Expense`) transactions may carry only the expense bucket;
   a non-empty income bucket is rejected (`ContraIncomeNotSupported`).
4. Allocation amounts remain strictly positive; the contra effect is
   expressed by bucket + direction, never by a negative `Money`.
5. The sum invariant generalises: `Σincome + Σexpense` equals the
   categorised total (`targetAmount` for `Income`, `sourceAmount` for
   `Expense`).
6. Amount-changing amendments carry explicit allocations (one uniform
   rule, no proportional rescale); `SetTransactionAllocations` is retained
   for amount-preserving re-categorisation. All sum/currency checks anchor
   to the transaction's `Money` amount.
7. No back-compat shims: per project policy, old events/DTOs may break;
   no upcasters.

## Design

### 1. Core type redesign (`Domain/Core/Types.hs`)

`Allocations` stops being `type Allocations = NonEmpty Allocation` and
becomes a record carrying both category buckets:

```haskell
data Allocations = Allocations
  { incomes  :: [Allocation]   -- categories from the income-category dict
  , expenses :: [Allocation]   -- categories from the expense-category dict
  }
  deriving (Show, Eq, Generic)
```

`TransactionType` is **unchanged in shape** — the constructor is the
direction, the payload is the new record:

```haskell
data TransactionType
  = Income  Allocations
  | Expense Allocations
  | Transfer
  | Adjustment
```

`Allocation` is **unchanged**: `{ categoryId, amount }` with the
`amount > 0` smart constructor and refinement intact.

Field names describe *which dictionary the categories come from*, not the
effect — the effect is determined by direction + bucket (§2). This keeps
the names meaningful under both `Income` and `Expense` constructors.

A smart constructor enforces the cross-bucket invariants the refinement
cannot express alone:

```haskell
-- rejects: both buckets empty
-- (per-allocation amount > 0 is already guaranteed by mkAllocation)
mkAllocations :: [Allocation] -> [Allocation] -> Either DomainError Allocations
```

`mkAllocations` is intentionally **kind-agnostic** — it knows nothing
about direction, so its only structural check is "not both empty." The
directional rules (income-bucket-empty on `Expense`, per-bucket sums vs
the categorised amount) require the transaction's accounts and amount and
therefore live **only in the command handler** (§2), not duplicated in
the smart constructor.

### 2. Validation (pure — `Transaction/CommandHandler.hs`)

Driven by the kind from `deriveTransactionKind` (computed from account
types, already available in the pure domain). This generalises the
existing `checkAllocationsAgainst` from "one list vs one amount" to "two
buckets summing to the categorised amount."

- **`Income (Allocations inc exp)`** — inbound, External→Regular:
  - `inc` → `+income`; `exp` → `−expense` (reimbursement).
  - Either bucket may be empty (pure salary: `exp = []`; standalone
    refund: `inc = []`), but **not both** (`AllocationsEmpty`).
  - Sum: `Σinc + Σexp == targetAmount`.
- **`Expense (Allocations inc exp)`** — outbound, Regular→External:
  - `exp` → `+expense`; `exp` must be non-empty.
  - `inc` **must be empty**, else `ContraIncomeNotSupported`. This
    asymmetry *is* the no-contra-income decision encoded in the type.
  - Sum: `Σexp == sourceAmount`.
- **`Transfer` / `Adjustment`**: uncategorised — unchanged.

**Currency anchoring.** Today `sumAllocationsUnchecked` /
`validateAllocations` derive the currency from `NE.head` of the single
allocation list. With two lists either of which may be empty, that
partial `head` no longer holds. Every sum/currency check is instead
**anchored to the transaction's `Money` amount** — `targetAmount` for
`Income`, `sourceAmount` for `Expense` — which always carries a currency:
every allocation in *both* buckets must match it, and the sum invariant is
checked in it. This removes the partial `head` and folds cleanly over
empty buckets (an empty bucket contributes nothing to the sum and imposes
no currency constraint). Because §5 drops proportional rescale and §
*Set-allocations* (below) re-anchors to the transaction amount, **no
caller of `sumAllocationsUnchecked` needs the old allocations' currency
any more**, so the function either disappears or reduces to a pure
amount-sum.

The same two-bucket + anchor treatment applies to **both** validators:
`checkAllocationsAgainst` (the handler helper, generalised above) *and*
`validateAllocations` (Types.hs:1090, the body of the `mkIncome` /
`mkExpense` smart constructors), which has its own `NE.head`-based
`checkSum` / `checkCurrency`. Either give `validateAllocations` the same
fold-both-buckets/anchor-to-amount logic, or remove `mkIncome`/`mkExpense`
if the handler-level validation makes them redundant — that call is the
implementer's, but both paths must lose the partial `head`.

New `DomainError` constructors: `ContraIncomeNotSupported`,
`AllocationsEmpty`. `AllocationsEmpty` is the smart-constructor's
both-buckets-empty guard; it is distinct from the handler's existing
`AllocationsRequiredForCategorisedKind` (raised when a categorised kind
arrives with no allocations at all) — keep both, they fire at different
layers. The existing positivity / allocation-sum / currency-mismatch
errors (`AllocationAmountNotPositive`, `AllocationsDoNotSumToTotal`,
`AllocationCurrencyMismatch`) are reused as-is — the two-bucket fold
introduces **no per-bucket error variants**. (No
`CannotRescaleMixedAllocations` — see §5.)

### 3. Service-layer dictionary validation (`Application/Services/TransactionService.hs`)

Today `validateAllocationsAgainstDictionary` (TransactionService.hs) walks
`NE.toList allocs` against a single dictionary chosen per-kind by
`pickCategoryDictForKind`. The new rule is **per-bucket** and independent
of direction:

- every `incomes` category must exist in the `income-category`
  dictionary;
- every `expenses` category must exist in the `expense-category`
  dictionary.

So the dictionary choice is now per-bucket, not per-kind:
`pickCategoryDictForKind` is no longer the right abstraction — the
validator runs once per bucket against its fixed dictionary. This is
precisely what makes "rent (an expense-dict category) inside a salary
(income) transfer" valid.

### 4. Events, read model, DTOs

- `TransactionPostingInitiated` and `TransactionAllocationsChanged` carry
  the new `Allocations` shape.
- `replaceAllocations` is structurally identical — `Income _ -> Income
  new`, `Expense _ -> Expense new`, `Transfer`/`Adjustment` unchanged —
  only `new`'s type changes.
- `TransactionData` (read model) stores the new shape. **No new
  aggregation** (storage only).
- The create **request** DTOs (`IncomeRequest`/`ExpenseRequest`) change to
  accept the two buckets. The **response** DTO keeps its existing flattened
  shape (`transactionType :: Text` + first-allocation `category`) — widening
  the response to surface both buckets is deferred (consistent with
  "server-side reporting out of scope"). Per the no-back-compat policy, old
  events/request DTOs may break; no upcasters.
- The transitional flattening accessors `transactionTypeAllocationsText`
  and `transactionTypeCategoryText` (Web/Types.hs) currently `toList`
  the single allocation list; they must fold **both** buckets.

#### Set-allocations (`SetTransactionAllocations`) — kept, two-bucket-ified

This command re-categorises a transaction **without changing its amount**
(the bank-import-split use case: split one imported line into category
slices, or carve a reimbursement portion out of an imported salary line).
It is intentionally distinct from amendment: it touches **no posting
fact**, runs **no saga**, and has **no balance impact** — it emits
`TransactionAllocationsChanged` and updates projections only. It is *not*
subsumed by "amend carries allocations" (§5): folding it into amend would
force a reverse-and-repost for a change where no money moved.

Two updates: it sets **both buckets** (validated by §2), and its
sum/currency check **anchors to the transaction's existing `Money`
amount** (`targetAmount`/`sourceAmount`) rather than
`sumAllocationsUnchecked` of the old allocations — removing that no-anchor
caller.

### 5. Amendment: explicit allocations (no rescale)

**An amendment that changes the categorised amount carries the new
allocations explicitly.** One uniform rule, all directions: the handler
validates the supplied `Allocations` satisfy §2 (bucket rules,
sum-equals-new-amount, currency). An amendment that does *not* change the
amount does not touch allocations at all (re-categorisation without an
amount change goes through `SetTransactionAllocations`, §4).

This **supersedes** the proportional-rescale approach from
[`2026-05-30-transaction-allocations-design.md`](2026-05-30-transaction-allocations-design.md),
which had `AmendTransfer` keep a lean shape and let the handler rescale
existing allocations by `factor = newAmount / oldAmount`. Rescale cannot
work once allocations have two economically-independent buckets: a
reimbursement is an externally-fixed figure, not a proportion of the
transfer, so a global factor would fabricate amounts nobody paid.

Consequences (all simplifications):

- **Delete** `rescaleAllocations` and `rescaleTransactionType`
  (Types.hs:1144/1165).
- **Replace** `synthesiseAmendmentTransactionType`
  (TransactionService.hs:778) — it no longer computes `oldTotal` via
  `sumAllocationsUnchecked` and rescales; it validates caller-supplied
  allocations against the new amount. This removes the worst no-anchor
  `sumAllocationsUnchecked` caller.
- `AmendTransaction` / `AmendTransfer` and its web DTO gain an
  allocations field (breaking shape change; no upcasters).
- The amended `TransactionType` still rides through the amendment saga as
  the opaque `newTransactionType` field exactly as today (§6).

### 6. Sagas — no change

All three process managers drive account legs purely off the four `Money`
totals; allocations are never inspected by saga logic.

- **`TransactionPostingManager`** issues `DebitAccount`/`CreditAccount`
  with only `sourceAmount`/`targetAmount` and `transactionId`.
- **`TransactionCancellationManager`** reverses legs using the stored
  `sourceAmount`/`targetAmount`.
- **`TransactionAmendmentManager`** computes every leg (`DebitNewSource`,
  `ReverseOldSource`, `CreditNewTarget`, `ReverseOldTarget`, and the
  delta math) from `new`/`old` amounts only; it carries
  `newTransactionType` as an **opaque pass-through** to the completed
  event for read models, and never inspects it.

So the two-bucket `Allocations` change is invisible to all sagas, to
balances, and to overdraft enforcement — allocations only ever travel as
data on events. Verified against the managers under
`src/Application/ProcessManagers/` (amounts-only at
`TransactionAmendmentManager.hs:210–245`, `TransactionPostingManager.hs`
debit/credit, `TransactionCancellationManager.hs:206/219`).

### 7. LiquidHaskell

- `Allocation.amount > 0` refinement and `mkAllocation` validation:
  **unchanged**.
- New `Allocations` record: smart constructor `mkAllocations` mirrors the
  "not both empty" invariant; follow the project's RDD → TDD →
  implementation → verification sequence. Export all measures/predicates.

## Reporting contract (documented, not built)

Whoever computes per-category totals (frontend or a future read model)
applies this sign rule. Contra effect = inbound flow into an expense
bucket; nothing else nets.

```
expenseNet(category) = Σ(expense-bucket amounts on Expense txns)        -- spending
                     − Σ(expense-bucket amounts on Income  txns)        -- reimbursements
incomeNet(category)  = Σ(income-bucket amounts on Income txns)          -- earnings
```

The `incomeNet` formula need not subtract anything: the income bucket can
only appear on `Income` transactions (`ContraIncomeNotSupported` forbids
it on `Expense`), so there is no contra-income term by construction.

Worked example (salary $5000 + rent reimbursement $500, then $500 rent
paid):

- `incomeNet(Salary)` = $5000
- `expenseNet(Rent)`  = $500 (the payment) − $500 (the reimbursement) = $0
- Net = +$5000, matching the account balance change.

### Display note

A pure reimbursement is a real `Income`-kind transaction with an empty
`incomes` bucket — `Income` here is a **direction label** (money flowed
External→Regular), not a claim of earnings, and reporting nets it against
the expense category so it never inflates income. A client that labels
transactions by raw kind would therefore show a refund as "Income," which
reads oddly. Surfacing it as a "reimbursement" when an `Income`
transaction has `incomes == []` is a **presentation choice left to the
client** (server-side reporting is out of scope); it is called out here
so the direction-label behaviour is a deliberate, known consequence
rather than a surprise.

## Testing

Following the project's property-first discipline:

- **Property** (`*PropertySpec.hs`): for any valid `Income` allocation
  split, `Σinc + Σexp == targetAmount`; round-trip of `Allocations`
  through the smart constructor preserves both buckets; `mkAllocations`
  rejects the both-empty case.
- **Unit** (`*Spec.hs`): `Expense` with a non-empty income bucket →
  `Left ContraIncomeNotSupported`; `Income` with only `expenses`
  (standalone refund) is accepted; the salary+rent mixed case is accepted
  and sums to `targetAmount`. Verify each `Left` carries the correct
  `errorContext`.
- **Unit** (amendment, §5): amending an `Income` transaction's amount with
  explicit new allocations that re-sum to the new amount is accepted;
  supplying allocations that violate §2 (wrong sum, contra-income, both
  empty, currency mismatch) is rejected with the matching error.
- **Integration** (`*IntegrationSpec.hs`): (a) post a mixed-bucket
  `Income` transaction end-to-end; assert account balance reflects only
  the total (posting ignores buckets) and the stored `TransactionData`
  carries both buckets intact. (b) `SetTransactionAllocations` re-splits a
  posted transaction into two buckets summing to the unchanged amount —
  assert no balance change and updated `TransactionData`. (c) amend the
  amount with new allocations — assert the amended buckets ride through to
  the completed event and the balance reflects only the new total.

## Migration / compatibility

No back-compat phase (per project policy). The `Allocations` alias →
record change is a breaking shape change to events, read-model payloads,
and API DTOs. Existing stored events with the old single-list shape are
considered invalid; no upcasters are written. Single-category
transactions are the degenerate one-bucket, length-1 case — no special
path.

This spec **supersedes** the amendment-rescale mechanism described in
[`2026-05-30-transaction-allocations-design.md`](2026-05-30-transaction-allocations-design.md)
(§5): amount-changing amendments now carry explicit allocations instead of
the handler rescaling proportionally. `AmendTransaction` and its web DTO
gain an allocations field; `rescaleAllocations` / `rescaleTransactionType`
are removed.
