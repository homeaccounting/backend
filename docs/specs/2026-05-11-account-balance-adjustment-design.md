---
status: in-progress
---

# Account Balance Adjustment (Set-to-Value with Backdated Reconciliation)

Tracking issue: [#75](https://github.com/homeaccounting/backend/issues/75)

## Summary

Add a user-facing affordance to reconcile an account's balance to a known value at a specific business date. The user submits a target balance and the date on which that balance was correct; the system computes the delta against the historical balance and records a backdated correction. Adjustments are first-class transactions but use a new dedicated `TransferType = Adjustment` so they remain excluded from income/expense reports by construction. The change reuses the existing transfer saga and the per-user singleton External account as the contra side — no changes to the Account aggregate, `TransferManager`, or any balance-changing event.

## Motivation

Every real-world balance drifts: bank fees the user forgot to enter, cash spent without recording, a wrong initial balance, a bank statement that disagrees with what the system tracked. Today the only way to correct it is to invent a fake Income or Expense against an arbitrary category — which pollutes P&L reporting and obscures real spending patterns. Every comparable tool (YNAB, GnuCash, Money Lover, Wallet) supports a reconcile / adjust-balance flow as a first-class operation.

## Goals

- Allow an Editor+ of a Regular account to set its balance to an arbitrary target value at a given business date.
- Treat the adjustment as backdated: future-dated transactions ride on top of the adjusted value, matching the existing semantics of `at` on events.
- Keep adjustments out of P&L (income/expense) analytics.
- Reuse existing transfer rails; do not introduce new event types or change the saga.

## Non-Goals

- Bulk or multi-account reconciliation.
- A separate per-user "Adjustment" contra account (the existing External singleton serves the role).
- A permissive ("force") mode that bypasses overdraft. Adjustments respect overdraft like any debit.
- Delta-style entry. Set-to-value is the only entry mode.
- Adjustments on External accounts.

## Domain Model

### `TransferType` extension

```haskell
data TransferType
  = Income     CategoryId
  | Expense    CategoryId
  | Transfer
  | Adjustment       -- new; carries no category
```

The `Adjustment` constructor carries no `CategoryId`. JSON encoding adds a `{"tag":"Adjustment"}` form (consistent with the existing tagging convention). The compiler will surface every non-exhaustive match on `TransferType`; each site must explicitly decide how to handle `Adjustment` (reports exclude; transaction listing includes; etc.).

### Direction derivation

For target balance `X` at business date `D` against account `A`:

```
currentAtD = balanceAsOf(A, D)
delta      = X − currentAtD
```

`X`, `currentAtD`, and `delta` are all expressed in `A`'s currency. The External account may be denominated in a different currency; that asymmetry is handled exclusively on the External leg inside `resolveAndInitiate` (the same ECB-rate code path Income/Expense already use). The adjustment service performs **no** currency conversion of its own — it computes the delta in the target account's currency and hands `(sourceAmount, targetAmount)` to `resolveAndInitiate`, which produces the cross-currency pair.

- `delta > 0` → source = External, target = A, amount = `delta`
- `delta < 0` → source = A, target = External, amount = `|delta|`
- `delta = 0` → reject; the adjustment is a no-op

### Why External as contra side

The double-entry invariant ("every balance change has a counterpart somewhere") is preserved by routing through the user's existing External singleton account. External is already the bookkeeping device that absorbs all non-internal flows (income, expense). Adjustments are conceptually corrections of prior tracking gaps — the External account's balance reflects the net "outside world" position, which already includes mis-tracked items. Adding adjustments to that stream is consistent with what External is for.

## Components

### Read model: `balanceAsOf`

New function exposed from `Application.ReadModels.Account`:

```haskell
balanceAsOf :: AccountId -> UTCTime -> AppM (Maybe Money)
```

The function reads the account's event stream from eventium directly (this is an on-demand event-store fold, not a maintained projection state). It lives alongside the read model module because callers will reach for it in the same place they reach for current balance, but the live `AccountReadModel` value is not an input — there is no per-account in-memory state involved.

Fold rules:

- Genesis balance from `AccountCreated.initialBalance`.
- For each subsequent event with `at ≤ D`: `AccountCredited` adds, `AccountDebited` subtracts. Other events (`AccountAccessGranted`, `OverdraftLimitSet`, etc.) do not affect balance.

Returns `Nothing` if the account has no events at all (i.e. doesn't exist). Returns the genesis `initialBalance` when `D` precedes any debit/credit event (including when `D` precedes account creation — there is no separate "before creation" error). The service is responsible for lifting `Nothing` to `NotFound "Account" <id>`; the read function itself does not raise domain errors.

Cost is one event-stream load per adjustment, acceptable for an interactive UI operation.

### Service: `AccountService.adjustAccountBalance`

```haskell
adjustAccountBalance
  :: UserId        -- caller
  -> AccountId     -- target account
  -> Money         -- target balance (in account currency)
  -> UTCTime       -- business date
  -> Text          -- reason / description
  -> AppM (Either DomainError (TransactionId, TransactionData))
```

Orchestration:

1. Authorize caller has Editor+ on the account (existing `AuthorizationService`).
2. Load the account read model; reject if `accountType == External`.
3. Reject if `currency targetBalance ≠ currency account.balance`.
4. Reject if `at > now`.
5. Look up the caller's External account id from the User read model.
6. `currentAtD ← balanceAsOf(accountId, at)`.
7. `delta = targetBalance − currentAtD`. Reject if zero.
8. Derive `(source, target)` from `signum delta`.
9. Call the existing `resolveAndInitiate` (the same helper used by Income/Expense) with `transferType = Adjustment`. This handles cross-currency (External may differ in currency from the target account) using ECB rates exactly as Income/Expense do today. The user-supplied `reason` is passed as the `description` field on the resulting `InitiateTransfer` command, which is the same field Income/Expense use today and is persisted through the existing `TransferInitiated` event.

The function returns the resulting `(TransactionId, TransactionData)` so the caller can render the transaction the user just produced.

### Web layer: `PUT /api/accounts/:id/balance`

Authenticated; Editor+ role enforced inside the service.

Request DTO:

```json
{
  "targetBalance": "1234.56",
  "currency": "EUR",
  "at": "2026-05-10T00:00:00Z",
  "reason": "Reconcile with May bank statement"
}
```

Response: existing `TransactionResponse` body; HTTP `200 OK`.

### Reports / read paths

Any aggregator that pattern-matches `TransferType` to compute income, expense, or P&L totals must add an explicit case for `Adjustment` that excludes it from those totals. The compiler will surface every site once the new constructor is added. The transaction listing endpoint, however, **includes** adjustments — they are real transactions and must appear in the user's history.

### Out of scope

- No changes to the Account aggregate, `DebitAccount` / `CreditAccount` command handlers, `TransferManager` saga, or `AccountDebited` / `AccountCredited` events.
- No new event types.
- No new domain error constructors — all failure modes reuse `NotFound`, `ValidationErr`, `AuthorizationError`, and the existing overdraft / saga-failure paths.

## Data Flow

```
HTTP  PUT /api/accounts/:id/balance                AdjustBalanceRequest
        │
        ▼
Web.API.AccountAPI.adjustBalanceHandler
   • parse currency, decimal → Money
   • extract caller from JWT
        │
        ▼
AccountService.adjustAccountBalance
   • authorize (Editor+)                            ← AuthorizationService
   • load account + user (External account id)      ← AccountRM / UserRM
   • validate currency, account is Regular, at ≤ now
   • currentAtD ← AccountReadModel.balanceAsOf(id, at)
   • delta = targetBalance − currentAtD            (reject if 0)
   • (source, target) = delta > 0 ? (External, id) : (id, External)
   • resolveAndInitiate(at, |delta|, srcCur, tgtCur, …)
        │
        ▼
TransactionCommandHandler.handle(InitiateTransfer{transferType=Adjustment})
   • emits TransferInitiated
        │
        ▼
TransferManager  (unchanged)
   • issues DebitAccount → AccountDebited (or AccountDebitRejected → FailTransfer)
   • issues CreditAccount → AccountCredited
   • issues CompleteTransfer → TransferCompleted
        │
        ▼
AccountReadModel & TransactionReadModel updated
HTTP 201 ← TransactionResponse { transactionId, … }
```

Two properties worth highlighting:

- **No new events.** Every event emitted already exists today.
- **`balanceAsOf` is the only new read-side capability.** It reads from the event store on demand; no projection state to maintain.

## Error Handling

All failures reuse the existing `DomainError` constructors. No new error tags.

| Trigger | Error | HTTP |
|---|---|---|
| JWT missing/invalid | (middleware) | 401 |
| Caller lacks Editor+ on account | `AccountError "User does not have edit access to this account"` | 400 |
| Account doesn't exist | `NotFound "Account" <id>` | 404 |
| Account is External | `ValidationErr "accountType" "Cannot adjust an External account"` | 400 |
| Currency mismatch | `ValidationErr "currency" "Currency does not match account currency"` | 400 |
| `date > now` | `ValidationErr "date" "Adjustment date must be in the past or present"` | 400 |
| `targetBalance == balanceAsOf(date)` | `ValidationErr "targetBalance" "Target balance equals current balance at this date"` | 400 |
| `mkMoney` parse failure | `ValidationErr "targetBalance" "<reason>"` | 400 |
| Overdraft would be exceeded on debit leg | propagated from existing handler (`InsufficientFunds` via `FailTransfer`) | 400 |
| Exchange-rate lookup fails (cross-currency) | propagated from `resolveAndInitiate` (existing mapping) | 400 / 503 |

Notes:

- Pre-saga validations (`accountType`, currency, `at`, no-op) run before the command is issued; they fail synchronously with no transaction emitted.
- Overdraft failure surfaces via the existing saga-completion path used by Income/Expense overdraft failures. The HTTP response reports the saga's failure reason. This is the only failure mode that is decided post-command.
- The no-op rejection is deliberate. A user who lands on "balance is already X" gets clear feedback rather than a phantom zero-amount transaction.
- Authorization rejection uses `AccountError` (mapping to HTTP 400 via the existing `Web.ErrorMapping`), matching the established convention used by `TransactionService.ensureEditorAccess`. A semantically-stronger 403 would require either a new `DomainError` variant (forbidden by the spec rule "no new error tags") or a refactor of the existing convention; both are out of scope for this feature. Revisit if/when the project standardises on 403 for authorization rejections.

## Testing

Three layers, following the project's existing categories.

### Unit (`*Spec.hs`)

- `Domain.Core.TypesSpec` — JSON round-trip for `TransferType = Adjustment`.
- `Application.ReadModels.AccountSpec.balanceAsOf` against fixture event lists:
  - empty stream → `Nothing`
  - `AccountCreated` only → returns `initialBalance` for any `D ≥ creation`
  - debits/credits with various `at` values → fold respects `at ≤ D`
  - mix of in-scope and out-of-scope events → out-of-scope excluded

### Property (`*PropertySpec.hs`)

- `balanceAsOf(id, t∞) == currentBalance` for any event sequence (collapses to the running balance when no events are filtered out).
- Monotonicity: `balanceAsOf(id, t₁) ≤ balanceAsOf(id, t₂)` when `t₁ ≤ t₂` and the events between them are credits only (dual for debits).
- Round-trip: for any account state and target `X` reachable within overdraft, `adjustAccountBalance(X, t)` followed by `balanceAsOf(t)` yields exactly `X`. Driven against `Testkit/InMemoryEventStore`.
- Direction determinism: across arbitrary states, the source/target choice equals `signum (X − balanceAsOf(t))`.

### Integration (`*IntegrationSpec.hs`)

`Application.Services.AccountServiceIntegrationSpec.adjustAccountBalance`:

- Happy path, positive delta — assert balance update and `Adjustment` row in the transaction listing.
- Happy path, negative delta within overdraft.
- **Backdate semantics**: create account, post a credit at `t₂`, adjust at `t₁ < t₂` to value `X`. Assert `balanceAsOf(t₁) == X` and current balance `== X + (credit at t₂)`.
- Rejects on External account.
- Rejects on currency mismatch.
- Rejects on `at > now`.
- Rejects on zero delta.
- Rejects on overdraft breach (negative delta exceeding limit) — surfaced via saga failure path.
- Rejects on Viewer authorization.
- Cross-currency: External in USD, account in EUR — verifies ECB rate path is exercised.

### Report exclusion

A test asserting `Adjustment` rows do not contribute to income or expense totals at the read-model level. The concrete aggregator(s) to cover (`TransactionReadModel` summary queries, configuration-driven dashboards, etc.) are enumerated during the implementation plan — the compiler will surface every non-exhaustive `TransferType` match once `Adjustment` is added, which becomes the working list.

### LiquidHaskell

No new refinements required. `Money` and `AccountId` reuse existing refinements; `TransferType` is a plain enum-like sum type that does not need refinement.

## Open Questions

None at design time. Two items intentionally deferred:

- **Permissive overdraft mode.** Revisit only if users hit the strict overdraft wall often in practice. Adding a `force` flag would be invasive (saga, event payload, audit trail) and is not justified without evidence.
- **Telegram bot affordance.** This spec covers the REST API and service only. A Telegram surface for adjustments can follow once the core works.
