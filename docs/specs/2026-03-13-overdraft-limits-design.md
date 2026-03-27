---
status: completed
---

# Overdraft Limits

## Summary

Allow accounts to carry negative balances with configurable overdraft limits. Clean up the Money type to always allow negative amounts — overdraft enforcement moves to the account level.

## Money Type Changes

Remove the non-negative constraint from `mkMoney` smart constructor — accept any `Rational` value. Merge `subtractMoney` and `subtractMoneyAllowNegative` into a single `subtractMoney` that always allows negative results (validates currency match only). Update LiquidHaskell refinements to remove `isNonNegative` measure on Money.

## Account Domain Changes

### New field: `overdraftLimit :: Maybe Money`

- `Nothing` — unlimited overdraft, no balance check on debit (any account type)
- `Just limit` — debit succeeds only if `balance - debitAmount >= -limit`
- Defaults: Regular accounts → `Just (Money 0 currency)`, External accounts → `Nothing`

### New command: `SetOverdraftLimit`

- Fields: `accountId`, `overdraftLimit :: Maybe Money`, `userId`
- Validation: caller must be Owner; if `Just limit`, currency must match account currency
- Setting a limit below the current negative balance is allowed (limit applies to future debits only)

### New event: `OverdraftLimitSet`

- Fields: `overdraftLimit :: Maybe Money`
- Projection updates the `overdraftLimit` field on the account aggregate

### Debit validation (CommandHandler)

Replace the current External/Regular branching with a single overdraft check:

- `Nothing` → debit always succeeds
- `Just limit` → `balance - debitAmount >= -limit`, otherwise `InsufficientFunds`

## Testing

- Property tests: debit succeeds when within overdraft limit, fails when exceeding it
- Property tests: Money type accepts negative values in construction
- Unit tests: `SetOverdraftLimit` access control (owner only), currency mismatch rejection
- Update existing Money and Account tests that assert non-negative constraints
