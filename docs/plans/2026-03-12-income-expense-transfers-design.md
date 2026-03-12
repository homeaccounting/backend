---
status: completed
---

# Income/Expense Transfers via External Singleton Account

## Summary

Add explicit transfer types (Income, Expense, InternalTransfer) and predefined category enums to the Transaction bounded context. Income and expense flow through a per-user singleton External account that is auto-created on registration (already implemented). Three separate API endpoints provide ergonomic interfaces for each transfer type.

## Domain Types

### TransferType

```haskell
data TransferType = Income | Expense | InternalTransfer
```

### TransferCategory

Three direction-specific category enums, unified under a sum type:

```haskell
data IncomeCategory = Salary | Freelance | Investment | IncomeGift | IncomeOther
data ExpenseCategory = Food | Transport | Utilities | Rent | Entertainment | ExpenseOther
data InternalCategory = Rebalance | Savings | InternalOther

data TransferCategory
  = IncomeCat IncomeCategory
  | ExpenseCat ExpenseCategory
  | InternalCat InternalCategory
```

Smart constructor enforces type/category consistency:
- `Income` only accepts `IncomeCat`
- `Expense` only accepts `ExpenseCat`
- `InternalTransfer` only accepts `InternalCat`

### Future Extensibility

The `TransferCategory` sum type is the seam for future dynamic categories. To go dynamic later: replace inner enums with `CategoryId` references and add a Category aggregate with CRUD. The outer sum type stays — it enforces direction consistency. Old enum-based events remain valid as "built-in" categories.

## Transaction Aggregate Changes

`InitiateTransfer` command and `TransferInitiated` event gain two fields:

- `type :: TransferType`
- `category :: TransferCategory`

Command handler validates type/category consistency (pure). Direction validation (checking account types) happens at the service layer.

No changes to Account aggregate, DebitAccount/CreditAccount, or TransferManager saga.

Transaction projection and read model include `type` and `category`.

## External Account (Already Implemented)

The External account singleton per user is already created during registration in `AuthService.register`, `createUserViaOAuth`, and `createUserViaTelegram`. The `UserData` read model already stores `externalAccountId :: AccountId`.

No new work needed for External account creation.

## Service Layer

`TransactionService` gains three functions corresponding to the three endpoints:

- **`initiateIncome`**: accepts regular account ID, amount, category, reason. Looks up user's External account via User read model. Sets `type = Income`, source = External, target = regular account.
- **`initiateExpense`**: accepts regular account ID, amount, category, reason. Looks up user's External account via User read model. Sets `type = Expense`, source = regular account, target = External.
- **`initiateTransfer`**: accepts both account IDs, amount, category, reason. Sets `type = InternalTransfer`. Validates neither account is External.

All three ultimately issue the same `InitiateTransfer` command to the domain. The saga and account aggregates don't change.

## API Endpoints

Three separate endpoints with focused DTOs:

### POST /api/transactions/income
```json
{ "accountId": "<regular>", "amount": 100, "category": "salary", "reason": "..." }
```

### POST /api/transactions/expense
```json
{ "accountId": "<regular>", "amount": 100, "category": "food", "reason": "..." }
```

### POST /api/transactions/transfer
```json
{ "fromAccountId": "<id>", "toAccountId": "<id>", "amount": 100, "category": "savings", "reason": "..." }
```

The existing `POST /api/transactions` endpoint is replaced by these three.

## Read Model

Transaction read model adds `type` and `category` to `TransactionData`. Supports filtering by type and category.

No changes to Account read model.

## Response DTO

`TransactionResponse` gains `type` and `category` fields:
```json
{
  "id": "...",
  "fromAccountId": "...",
  "toAccountId": "...",
  "amount": 100,
  "reason": "...",
  "type": "income",
  "category": "salary",
  "status": "Completed",
  "failureReason": null
}
```

## Testing Strategy

### Property Tests
- Type/category consistency: `Income` only accepts `IncomeCat`, etc.
- Smart constructor rejects mismatched pairs
- Category enum serialization roundtrip

### Unit Tests
- Command handler rejects type/category mismatch
- Direction validation in service layer rejects wrong account type combinations

### Integration Tests
- Full income flow via `/api/transactions/income`
- Full expense flow via `/api/transactions/expense`
- Internal transfer via `/api/transactions/transfer`
- Category persisted in events and visible in read model
