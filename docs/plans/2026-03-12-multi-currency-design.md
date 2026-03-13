---
status: completed
---

# Multi-Currency Support

## Summary

Add currency awareness to the Money type and enforce same-currency constraints on account operations and transfers.

## Currency Type

New sum type in `Domain.Core.Types`:

```haskell
data Currency = UAH | USD | EUR | GBP
```

Extensible as needed. Derives `Eq`, `Ord`, `Enum`, `Bounded`, `Generic`. JSON serialization as string (`"UAH"`, `"USD"`, etc.).

## Money Type

Changes from `newtype Money = Money { unMoney :: Rational }` to:

```haskell
data Money = Money { amount :: Rational, currency :: Currency }
```

Smart constructor: `mkMoney :: Currency -> Rational -> Either Text Money` (validates non-negative amount).

### Operations

- `addMoney :: Money -> Money -> Either Text Money` — returns `Left` on currency mismatch (signature change: previously always succeeded)
- `subtractMoney :: Money -> Money -> Either Text Money` — also checks currency match
- `subtractMoneyAllowNegative :: Money -> Money -> Either Text Money` — now returns `Either` due to possible currency mismatch

New accessor: `moneyCurrency :: Money -> Currency`.

## Account Currency

No new field on Account. The account's currency is `account.balance.currency` — single source of truth.

`CreateAccount` command carries initial `Money` (which includes currency). Currency is immutable after creation (all subsequent operations must match).

## Command Handler Validation

`DebitAccount` and `CreditAccount` handlers validate that `operationAmount.currency == balance.currency`. On mismatch, return new `CurrencyMismatch` error variant in `AccountError`.

## Transfer Saga

No changes to `TransferManager` logic. If a transfer targets accounts with different currencies, the account command handler rejects the debit/credit, the compensation fires, and the transfer fails through the existing error flow.

## Serialization

Clean break — no backwards compatibility with old single-number Money format. New JSON format:

```json
{ "amount": 100.50, "currency": "UAH" }
```

## LiquidHaskell

- Money refinement: non-negative `amount` field
- `sameCurrency :: Money -> Money -> Bool` predicate for operations

## Testing

- Property tests: same-currency Money operations preserve existing behavior; mismatched currencies return `Left`
- Property tests: Currency JSON roundtrip
- Unit tests: `CurrencyMismatch` error from account command handler
- Integration tests: same-currency transfer succeeds; cross-currency transfer fails
- All existing `mkMoney` calls updated with `Currency` argument
