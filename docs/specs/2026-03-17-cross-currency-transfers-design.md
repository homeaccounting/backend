# Cross-Currency Transfer Support

## Problem

Income/expense operations fail with `CurrencyMismatch` for non-USD accounts. The External account is hardcoded to USD, but user Regular accounts can be in UAH, EUR, GBP. The Account command handler correctly rejects transfers where the amount currency doesn't match the account currency — the bug is that the transfer flow doesn't convert currencies.

Additionally, cross-currency transfers between Regular accounts (e.g., UAH card → USD car account) must also be supported — this is not limited to External account operations.

## Solution Overview

Add exchange rate infrastructure (ECB daily rates) and extend the transfer flow with universal cross-currency support. Any transfer where source and target account currencies differ is automatically converted using the ECB daily rate. Users can optionally provide a custom exchange rate to override the ECB rate. For cross-currency internal transfers, users can alternatively provide both amounts directly (source and target), and the system derives the rate — this is the natural UX when the user has both bank statements.

**Important:** ECB rates are a convenience approximation, not a source of truth. Bank rates differ from ECB mid-market rates. For past-dated transactions or when accuracy matters, users should provide their actual rate or both amounts from their bank statements.

No new transfer types or categories are needed — cross-currency support is orthogonal to transfer type.

## Design

### Exchange Rate Infrastructure

**New module: `Infrastructure.ExchangeRate`**

- Fetches daily rates from ECB's XML feed (all rates are EUR-based; cross-rates are derived)
- Cached in-memory with daily refresh — lazy refresh on first request after midnight CET
- `ExchangeRateCache` added to `AppEnv` (e.g., `IORef` or `TVar` holding latest rates map)
- On cache miss or fetch failure, operations return `ExchangeRateUnavailable` error
- `Main.hs` fetches initial rates on startup; if ECB is unreachable, starts with empty cache (first transfer will fail with `ExchangeRateUnavailable`)

**New domain type: `ExchangeRate`** in `Domain.Core.Types`

- Fields: source currency, target currency, rate (Rational, must be positive — enforced by smart constructor)
- Smart constructor `mkExchangeRate` rejects zero or negative rates
- Pure `convert :: ExchangeRate -> Money -> Money` function producing the converted amount
- No rounding: `Money.amount` is `Rational`, so conversion preserves full precision. Round-trip A->B->A may not recover the exact original due to rational division, but no precision is lost to floating-point.

### Transfer Events & Commands

**`TransferInitiated` event** — replace `amount` field with:

- `sourceAmount :: Money` — amount in source account's currency (what gets debited)
- `targetAmount :: Money` — amount in target account's currency (what gets credited)
- `exchangeRate :: Maybe ExchangeRate` — the rate used (`Nothing` for same-currency transfers). Stored explicitly for audit trail — while derivable from `sourceAmount`/`targetAmount`, recording the exact rate used documents intent and avoids precision ambiguity.

**`InitiateTransfer` command** — same shape change: `sourceAmount`, `targetAmount`, `exchangeRate` instead of single `amount`.

For same-currency transfers: `sourceAmount == targetAmount`, `exchangeRate` is `Nothing`.

**No backward compatibility needed** — database will be recreated.

### TransferManager Changes

Instead of passing `evt.amount` to both `DebitAccount` and `CreditAccount`:

- Uses `evt.sourceAmount` for `DebitAccount` (source account's currency)
- Uses `evt.targetAmount` for `CreditAccount` (target account's currency)

`TransferData` (saga state) must be updated to store both `sourceAmount :: Money` and `targetAmount :: Money` instead of the current single `amount :: Money`. The react function uses `TransferData` (not the original event) when issuing the `CreditAccount` command after debit succeeds.

Each account receives money in its own currency. No other changes to the saga flow.

### Universal Cross-Currency Conversion in TransactionService

TransactionService handles currency conversion for all transfer types uniformly:

1. User provides amount in their **Regular account's currency** — the account they interact with. The `Money` value's currency must match that account's currency; if it doesn't, the service rejects with a validation error.
   - **Income:** user's Regular account is the target (External is source). User says "I earned 1000 UAH."
   - **Expense:** user's Regular account is the source (External is target). User says "I spent 500 UAH."
   - **InternalTransfer:** user provides amount in source account's currency. Alternatively, for cross-currency internal transfers, the user can provide **both amounts** (source and target) — see below.
2. Service looks up both accounts' currencies (derived from account balance via `moneyCurrency`).
3. **Same currency:** `sourceAmount == targetAmount`, `exchangeRate` is `Nothing`. No conversion needed.
4. **Different currencies:**
   - If user provided a custom exchange rate → use it (validated as positive by `mkExchangeRate`)
   - If no rate provided → fetch from `ExchangeRateCache`
   - Convert user-provided amount to the other account's currency
   - For Income: `targetAmount` = user amount (UAH), `sourceAmount` = converted (USD)
   - For Expense: `sourceAmount` = user amount (UAH), `targetAmount` = converted (USD)
   - For InternalTransfer: `sourceAmount` = user amount, `targetAmount` = converted
5. Issues `InitiateTransfer` with both amounts + rate

This applies uniformly to all transfer types. The only per-type logic is which side the user-provided amount maps to (source vs target).

#### Two-Amounts Input for InternalTransfer

For cross-currency internal transfers, the user can provide **both `sourceAmount` and `targetAmount`** directly instead of a single amount + rate. This is the natural UX when the user has both bank statements (e.g., "I moved 10,000 UAH from my UAH card and received $263 in my USD account").

When both amounts are provided:
- Service validates that `sourceAmount` currency matches source account and `targetAmount` currency matches target account
- The exchange rate is **derived** from the two amounts (`sourceAmount / targetAmount`) and stored in the event for audit
- No ECB lookup is needed

This option is **only available for InternalTransfer**. For Income/Expense, the External account is a system abstraction with no real-world statement — the user only knows their Regular account side. Income/Expense uses the single amount + optional rate flow.

**Input precedence for InternalTransfer cross-currency:**
1. Both amounts provided → derive rate (highest priority, most accurate)
2. Amount + custom rate → compute other amount
3. Amount only → fetch ECB rate and compute other amount

### Error Handling

- **Rate unavailability:** Service returns `ExchangeRateUnavailable` error, transfer rejected. No partial state.
- **Zero/negative rate:** `mkExchangeRate` smart constructor rejects non-positive rates. If ECB returns invalid data, treated as rate unavailable.
- **Money currency vs account currency mismatch:** Service validates that the user-provided `Money` currency matches the Regular account's currency (target for Income, source for Expense/InternalTransfer).
- **Two-amounts currency mismatch:** When both amounts are provided for InternalTransfer, service validates `sourceAmount` currency matches source account and `targetAmount` currency matches target account.
- **Conflicting inputs:** If user provides both amounts AND a custom rate, service rejects with a validation error — these are mutually exclusive inputs.
- **Stale rates:** No staleness check beyond daily cache refresh. ECB updates once per day.

### Testing Strategy

**Domain (pure, property-based):**

- `ExchangeRate` smart constructor rejects zero and negative rates
- `convert` preserves currency correctly (output currency matches target)
- `convert` with rate 1.0 and same currency is identity
- Round-trip A->B->A: `sourceAmount / rate * rate == sourceAmount` (exact with Rational)

**Application (unit):**

- TransactionService: cross-currency income produces correct `sourceAmount`/`targetAmount`
- TransactionService: cross-currency internal transfer (e.g., UAH → USD) works with single amount + rate
- TransactionService: cross-currency internal transfer with both amounts derives correct rate
- TransactionService: rejects when both amounts AND custom rate are provided
- TransactionService: rejects when two-amounts currencies don't match respective accounts
- TransactionService: same-currency transfer skips conversion
- TransactionService: rejects when Money currency doesn't match source account currency
- TransactionService: user-provided rate overrides ECB rate
- TransactionService: missing ECB rate returns `ExchangeRateUnavailable`
- TransferManager: uses `sourceAmount` for debit, `targetAmount` for credit (via `TransferData`)

**Infrastructure (integration):**

- ECB client fetches and parses real rates
- Cache refreshes correctly
- Invalid ECB data handled gracefully

## Scope Summary

| Component | Change |
|---|---|
| `Domain.Core.Types` | New `ExchangeRate` type with smart constructor, `convert` function |
| `Domain.Transaction.Commands` | `InitiateTransfer`: replace `amount` with `sourceAmount`/`targetAmount`/`exchangeRate` |
| `Domain.Transaction.Events` | `TransferInitiated`: replace `amount` with `sourceAmount`/`targetAmount`/`exchangeRate` |
| `Domain.Transaction.CommandHandler` | Construct `TransferInitiated` with new field shape |
| `Domain.Transaction.Projection` | Update projection state to use `sourceAmount`/`targetAmount`/`exchangeRate` |
| `Application.ProcessManagers.TransferManager` | `TransferData` stores `sourceAmount`/`targetAmount`; uses them for debit/credit |
| `Application.Services.TransactionService` | Universal cross-currency conversion: detect mismatch, resolve rate (ECB, user-provided, or derived from two amounts), compute both amounts |
| `Application.ReadModels.Transaction` | Update `TransactionData` read model to expose `sourceAmount`/`targetAmount`/`exchangeRate` |
| `Infrastructure.ExchangeRate` | New module: ECB client, rate cache, `ExchangeRateCache` in `AppEnv` |
| `Infrastructure.App` / `Main.hs` | Add `ExchangeRateCache` to `AppEnv`; initialize cache on startup |
| `Web` layer | Update DTOs for new transfer fields, add optional `exchangeRate` and optional `targetAmount` to transfer endpoints |
| Tests | Property tests for ExchangeRate, unit tests for service/manager changes, test setup updates for `ExchangeRateCache` |
