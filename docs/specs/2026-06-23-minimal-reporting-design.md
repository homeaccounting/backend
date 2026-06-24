---
status: draft
date: 2026-06-23
issue: homeaccounting/tracker#24
---

# Minimal Reporting (backend)

## Problem

The backend has no reporting/aggregation capability. `GET /api/transactions`
filters and paginates but never aggregates; there are no summary endpoints.
This is a gap against our own strategy:

- The business model lists **reports** as part of the always-free core.
- Retention is the north-star metric; reporting is the payoff that makes
  transaction-logging worthwhile.
- Switcher audiences come from apps with rich reporting (Firefly, Actual,
  Maybe); zero reporting reads as a toy.

We already carry the raw material — transactions have two-bucket
`allocations` (category breakdowns) and every cross-currency transaction
already stores its base-currency leg. The backend just needs aggregation
endpoints.

## Goals

1. Expose three read-only HTTP endpoints feeding the launch reports:
   **spending by category**, **income vs. expense**, and **net across
   accounts** (normalized to base currency).
2. Reuse existing read models (Transaction, Account, ExchangeRate,
   Configuration) — no new write-side events, no new read model, no
   projection rebuilds.
3. Honour the existing access model: aggregate only over accounts the
   authenticated user can see (same RBAC as `GET /api/transactions`).
4. Lead on multi-currency: normalize to base currency exactly, using the
   base-currency leg already recorded on every transaction.

## Non-Goals

- Budgets / envelopes, net-worth-over-time, investments, forecasting,
  household sharing (explicitly out of scope for launch per the issue).
- A dedicated reporting read model / running aggregates (compute on-the-fly;
  personal-accounting volumes do not warrant it).
- Server-side category-name resolution (responses carry `categoryId` only,
  consistent with `TransactionResponse`; the web resolves names via its
  existing configuration query).
- Pagination of report results.
- Changes to commands, events, or the write side.
- Web/client work (separate PR in the `monorepo`).

## Background: the data we build on

Verified against the codebase:

- **External account**: exactly one per user, created at registration, always
  denominated in `Configuration.baseCurrency` (`AuthService.hs:181-193`).
- **Expense** (`Regular → External`): `sourceAmount` is in the user-account
  currency; **`targetAmount` is the base-currency leg**. Allocations are in the
  user-account currency and sum to `sourceAmount`.
- **Income** (`External → Regular`): **`sourceAmount` is the base-currency
  leg**; `targetAmount` is in the user-account currency. Allocations are in the
  user-account currency and sum to `targetAmount`.
- Money amounts are `Rational` (exact arithmetic). Same-currency transactions
  store `exchangeRate = Nothing` and equal legs.

Consequence: **spending-by-category and income-vs-expense need no FX
read-model lookups.** Each allocation is converted to base currency exactly via
its own transaction's leg ratio:

```
externalLeg = base-currency leg   (Expense: targetAmount; Income: sourceAmount)
regularLeg  = user-account leg     (Expense: sourceAmount; Income: targetAmount)

base(alloc) =
  case txn.exchangeRate of
    Nothing -> alloc.amount                              -- same currency: legs are equal
    Just _  -> alloc.amount * (externalLeg / regularLeg) -- cross-currency
```

The leg ratio is deliberately direction-agnostic: it is correct for both an
Expense (stored rate is `Regular → base`) and an Income (stored rate is
`base → Regular`, i.e. inverted relative to the allocation currency) without any
inverse-rate reasoning. Division is well-defined: it is taken only in the
`Just` (genuinely cross-currency) branch, and there `regularLeg > 0` always —
the categorised total *is* the sum of the strictly-positive allocations
(`mkIncome`/`mkExpense` reject empty/non-positive allocations), so it can never
be zero. `exchangeRate = Nothing` is exactly the same-currency case
(`resolveAmounts`, `TransactionService.hs:1078-1079`) and takes no division.

Because amounts are `Rational`, `Σ base(allocᵢ) = (Σ allocᵢ) * ratio =
regularLeg * (externalLeg / regularLeg) = externalLeg` exactly — no rounding
drift between a transaction's per-category base amounts and its base total.

Only **net-worth** (standing account balances, which are not transactions) uses
the ExchangeRate read model.

## Design

### 1. Placement

No new read model. A new `Application.Services.ReportingService` aggregates
on-the-fly over the existing read models. Pure aggregation functions (no IO)
do the arithmetic; the service performs read-model access and FX lookup at the
boundary, so the math is unit/property-testable in isolation.

```
src/Web/API/ReportingAPI.hs                  -- 3 endpoints + handlers + DTO mapping
src/Application/Services/ReportingService.hs  -- orchestration + pure aggregation helpers
src/Web/Types.hs                              -- response DTOs (existing *Response convention)
src/Web/API.hs                                -- compose ReportingAPI into API / server
```

Layering: `Web → Application → (Transaction/Account/ExchangeRate/Configuration
read models)`. No Domain changes; no new domain types, so no new LiquidHaskell
refinements.

### 2. HTTP surface

```
GET /api/reports/spending-by-category ?from=<ISO-8601> &to=<ISO-8601>
GET /api/reports/income-vs-expense    ?from=<ISO-8601> &to=<ISO-8601>
GET /api/reports/net-worth
```

- Auth: `AuthProtect "jwt"` on all three.
- `from`/`to` are optional, inclusive `UTCTime` bounds matched against the
  transaction business date (`Transaction.at`), mirroring `GET
  /api/transactions`. Omitting both = all-time. `net-worth` takes no period
  (current balances).
- **spending-by-category** and **income-vs-expense** are scoped to the caller's
  **accessible accounts** (Owner / Editor / Viewer), the same visibility set
  `TransactionService.listTransactions` builds (via `getAccessibleAccounts`).
  That set includes the caller's own External account (they are its
  `createdBy`/Owner); this is harmless because those reports filter by
  transaction kind.
- **net-worth** uses a stricter scope: **owned accounts only** (`createdBy ==
  caller`, i.e. `Domain.Account.Projection.isOwner`). Net worth is the caller's
  own money — accounts shared *to* them as Editor/Viewer are someone else's
  assets and are excluded.
- Aggregation iterates the read model's **de-duplicated** transaction set — the
  `Map TransactionId TransactionData` returns each transaction exactly once.
  Every Income/Expense touches the External account on one leg and a Regular
  account on the other (both visible to the caller), but because we fold over
  transactions (not over visible legs) each is counted once, with no
  double-counting.
- Every monetary value **reuses the domain `Money` DTO** — serialized as
  `{ "amount": <number>, "currency": "UAH" }`, exactly as
  `AllocationResponse.amount :: Money` already does (`Web.Types`). No separate
  `amount :: Double` + `currency :: Text` pairs. The currency travels inside each
  `Money`, so the web's `formatMoney(amount, code)` reads `money.amount` /
  `money.currency` per value, and base-currency figures carry the base
  `Currency`. Internal computation stays in `Rational`; the `Money` JSON instance
  renders `amount` as a `Double` only at the boundary.

### 3. Included data

Spending-by-category and income-vs-expense aggregate only:

- **Completed** transactions (exclude Pending / Failed / Cancelled).
- **Income / Expense** kinds. Transfers and Adjustments carry no allocations
  and are excluded (filtered explicitly by kind, not relied upon implicitly).
- Transactions touching the caller's accessible accounts.

### 4. Two-bucket / reimbursement semantics

The two-bucket allocation model is respected. A reimbursement (an expense-bucket
allocation on an **Income** transaction) is a contra-expense — it reduces spend
in its category — never a negative amount stored anywhere. Signed contribution
of an allocation to its category, by bucket and flow direction:

| Allocation bucket | On Expense txn | On Income txn   |
| ----------------- | -------------- | --------------- |
| expense-bucket    | `+spend`       | `−spend` (reimbursement) |
| income-bucket     | (impossible¹)  | `+income`       |

¹ `mkExpense` rejects a non-empty income bucket (`ContraIncomeNotSupported`).

- **spending-by-category**: group signed expense-bucket contributions (in base
  currency) by `categoryId`. Slices originating in different user-account
  currencies are comparable because every slice is normalized to the single
  report `baseCurrency` before grouping. A category may net to zero or negative
  if reimbursements exceed spend in the period; such categories are still
  returned.
- **income-vs-expense**:
  - `income`  = Σ income-bucket contributions (base)
  - `expense` = Σ signed expense-bucket contributions (base)
  - `net`     = `income − expense`

### 5. Net-worth

```
netWorth = Σ base(account.balance)
           over accounts that are Regular ∧ Opened ∧ owned-by-caller
```

- **Owner-scoped**, not accessible-scoped: only accounts where `createdBy ==
  caller` (`isOwner`) count. Accounts shared to the caller as Editor/Viewer are
  another user's assets and are excluded.
- The **External** account is excluded — it is the system counterparty (the
  mirror of all flows), not a user asset. (The caller does own their External
  account, so the owner filter alone would keep it; it is removed by the
  `Regular`-kind filter.)
- **Closed** accounts are excluded.
- Accounts already denominated in `baseCurrency` contribute their balance
  **unconverted** and never enter the FX path or the missing-rate failure (no
  `base → base` rate is ever published; `mkExchangeRate` rejects same-currency
  pairs).
- Each non-base-currency balance is converted with the rate **on or nearest to
  today** via `ExchangeRate.lookupHistoricalRate rm provider today src base`
  (which delegates to `lookupNearestDate`; provider from
  `AppConfig.exchangeRate.provider`; `today` from `getCurrentTime`). In practice
  rates are published for past/current dates, so this is the latest known rate.
- **Missing rate ⇒ fail.** If any included non-base-currency account has no
  published rate to base, the endpoint returns `422` (`ExchangeRateUnavailable`,
  identical to the transaction cross-currency path). No partial result.
- Response carries a per-account breakdown plus the base `total`.

### 6. Response DTOs (`Web.Types`)

Every amount is a domain `Money` (`{ amount, currency }`). Because each `Money`
carries its own currency, there is no separate top-level `baseCurrency` field —
the report currency is read from any base-currency `Money` in the payload
(`total.currency`). `categoryId` is rendered as `Text` (UUID-as-text), matching
`AllocationResponse.categoryId`; `accountId` as `UUID`, matching the account
DTOs.

```haskell
-- GET /api/reports/spending-by-category
data SpendingByCategoryResponse = SpendingByCategoryResponse
  { categories :: [CategorySpend]   -- expense categories with non-trivial net
  , total      :: Money             -- Σ categories[].total, in base currency
  }

data CategorySpend = CategorySpend
  { categoryId :: Text
  , total      :: Money             -- net spend, base currency (may be ≤ 0)
  }

-- GET /api/reports/income-vs-expense
data IncomeVsExpenseResponse = IncomeVsExpenseResponse
  { income  :: Money                -- base currency
  , expense :: Money                -- base currency
  , net     :: Money                -- income − expense, base currency
  }

-- GET /api/reports/net-worth
data NetWorthResponse = NetWorthResponse
  { accounts :: [AccountNetWorth]
  , total    :: Money               -- Σ accounts[].baseBalance, base currency
  }

data AccountNetWorth = AccountNetWorth
  { accountId   :: UUID
  , balance     :: Money            -- native balance + native currency
  , baseBalance :: Money            -- converted to base currency
  }
```

Per house style: no exported constructors/field selectors beyond the module's
DTO convention; JSON via the existing aeson setup in `Web.Types`, reusing the
domain `Money`/`Currency` instances.

### 7. Service surface (`ReportingService`)

```haskell
spendingByCategory :: UserId -> Maybe UTCTime -> Maybe UTCTime
                   -> AppM (Money, [(CategoryId, Money)])      -- (base total, per-category base)
incomeVsExpense    :: UserId -> Maybe UTCTime -> Maybe UTCTime
                   -> AppM (Money, Money, Money)               -- (income, expense, net) in base
netWorth           :: UserId
                   -> AppM (Money, [(AccountId, Money, Money)]) -- (base total, [(acct, native, baseBal)])
```

Each total `Money` carries the base `Currency` even when the report is empty
(the service resolves `baseCurrency` up front, so a zero total is
`Money 0 baseCurrency`, never an arbitrary default).

The service:
1. Resolves `baseCurrency` from the Configuration read model.
2. Builds the relevant account scope: the **accessible** set (via
   `getAccessibleAccounts`) for the category/income-expense reports; the
   **owned** set (`createdBy == caller` / `isOwner`) for net-worth.
3. Reads transactions / accounts from their read models.
4. Calls the pure aggregation helpers below.
5. For net-worth, performs FX lookups and throws `ExchangeRateUnavailable` on a
   miss.

Pure helpers (no IO; the testable core), e.g.:

```haskell
-- base-currency value of one allocation via its transaction's leg ratio
allocationBase :: TransactionData -> Money -> Money

-- signed per-category fold over completed income/expense txns in range
aggregateSpending :: [TransactionData] -> Map CategoryId Money
aggregateIncomeExpense :: [TransactionData] -> (Money, Money)
```

### 8. Errors

- Net-worth missing FX rate → `ExchangeRateUnavailable` (→ `422`, via existing
  `Web.ErrorMapping`).
- No special errors otherwise; empty ranges yield empty/zero reports (`200`).

## Testing

Following the project's TDD ordering (property → unit → integration):

- **Property** (`ReportingPropertySpec`):
  - Conservation: for any set of completed income/expense txns, `net ==
    income − expense`, and `Σ spending-by-category(expense buckets) == expense`
    (signs and reimbursements included).
  - Exactness: `Σ allocationBase(txn, alloc) == externalLeg(txn)` for every txn
    (no `Rational` drift).
  - Currency invariance for same-currency txns: `allocationBase == alloc`.
- **Unit** (`ReportingSpec`): cross-currency expense, cross-currency income,
  reimbursement nets a category down, Pending/Failed/Cancelled excluded,
  Transfers/Adjustments excluded, closed/External excluded from net-worth,
  net-worth owner-scoping (an account shared *to* the caller as Editor/Viewer is
  excluded; the category/income-expense reports still see its transactions),
  accessible-account scoping for the transaction reports, empty-period zero
  reports.
- **Integration** (`ReportingIntegrationSpec`): end-to-end over the event store
  — seed accounts + income/expense/transfer events + a published rate, hit each
  endpoint, assert payloads; assert net-worth `422` when a rate is absent.

## Open questions

None outstanding — API shape (three endpoints), FX strategy (transaction legs
for spend/income; latest rate for net-worth), reimbursement contra semantics,
External exclusion, and the net-worth missing-rate policy (fail `422`) are all
settled.
