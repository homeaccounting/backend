---
status: draft
---

# Account Types

## Summary

Introduce user-facing account types (Cash, Bank Account, E-Wallet, Asset, Loan) with per-type structured properties and a freeform metadata bag. Account types are organizational metadata — they do not alter business rules. The existing `AccountKind` (Regular | External) is renamed to `AccountKind`, and `AccountSubtype` is nested inside the `Regular` constructor.

## Motivation

Currently all regular accounts are undifferentiated — the only distinction is the free-form `name` field. Users need to categorize accounts for better organization and display (icons, grouping, filtering). Different account kinds naturally carry different metadata (e.g., bank name for a bank account, lender for a loan).

## Design Decisions

- **Organizational only**: Account types do not introduce new business rules. All accounts follow the same transfer, overdraft, and access control mechanics.
- **Orthogonal to AccountKind**: `AccountKind` (Regular | External) drives business behavior. `AccountSubtype` drives UI categorization. They are separate concerns, with `AccountSubtype` nested inside `Regular`.
- **Sum type with per-variant records**: Leverages Haskell's type system — the compiler ensures valid field combinations per type.
- **Smart overdraft defaults**: Account type influences the default overdraft limit at creation time, but users can always override.

## Domain Model

### AccountKind (renamed from AccountType)

```haskell
data AccountKind
  = Regular AccountSubtype
  | External
```

### AccountSubtype (new)

```haskell
data AccountSubtype
  = Cash CashProperties
  | BankAccount BankAccountProperties
  | EWallet EWalletProperties
  | Asset AssetProperties
  | Loan LoanProperties
```

### Per-Variant Property Records

```haskell
data CashProperties = CashProperties
  { storageLocation :: Maybe Text
  , metadata :: Map Text Text
  }

data CardNetwork = Visa | Mastercard | Amex | OtherCardNetwork Text

data BankAccountProperties = BankAccountProperties
  { bankName :: Maybe Text
  , accountNumber :: Maybe Text       -- masked/last 4 digits
  , cardNetwork :: Maybe CardNetwork
  , metadata :: Map Text Text
  }

data EWalletProperties = EWalletProperties
  { provider :: Maybe Text
  , accountIdentifier :: Maybe Text
  , metadata :: Map Text Text
  }

data AssetKind = Property | Vehicle | Stocks | RetirementFund | OtherAsset Text

data AssetProperties = AssetProperties
  { assetKind :: Maybe AssetKind
  , description :: Maybe Text
  , metadata :: Map Text Text
  }

data LoanProperties = LoanProperties
  { lender :: Maybe Text
  , interestRate :: Maybe Rational
  , dueDate :: Maybe Day
  , metadata :: Map Text Text
  }
```

### Account Aggregate

```haskell
data Account = Account
  { balance :: Money
  , name :: Text
  , createdBy :: UserId
  , kind :: AccountKind  -- renamed from accountType
  , accessList :: [AccountAccess]
  , overdraftLimit :: Maybe Money
  }
```

### Default Constructors

Each properties record has a `default*` with all fields `Nothing`/`mempty`:

```haskell
defaultCashProperties :: CashProperties
defaultBankAccountProperties :: BankAccountProperties
defaultEWalletProperties :: EWalletProperties
defaultAssetProperties :: AssetProperties
defaultLoanProperties :: LoanProperties

-- Convenience: type with default empty properties
defaultCash :: AccountSubtype
defaultBankAccount :: AccountSubtype
defaultEWallet :: AccountSubtype
defaultAsset :: AccountSubtype
defaultLoan :: AccountSubtype
```

## Events & Commands

### Modified: AccountCreated

The `kind` field is renamed from `accountType` in Haskell but keeps `accountType` as JSON key for backwards compatibility.

```haskell
data AccountCreated = AccountCreated
  { name :: Text
  , initialBalance :: Money
  , by :: UserId
  , kind :: AccountKind  -- renamed from accountType
  , overdraftLimit :: Maybe Money
  }
```

### New Event: AccountSubtypeSet

```haskell
data AccountSubtypeSet = AccountSubtypeSet
  { subtype :: AccountSubtype
  , by :: UserId
  }
```

### Modified: CreateAccount Command

```haskell
data CreateAccount = CreateAccount
  { name :: Text
  , initialBalance :: Money
  , createdBy :: UserId
  , kind :: AccountKind  -- renamed, carries AccountSubtype inside Regular
  , overdraftLimit :: Maybe (Maybe Money)
  }
```

### New Command: SetAccountSubtype

```haskell
data SetAccountSubtype = SetAccountSubtype
  { subtype :: AccountSubtype
  , setBy :: UserId
  }
```

### TH Registration

`AccountSubtypeSet` must be added to `accountEvents` in `Events.hs` and `SetAccountSubtype` to `accountCommands` in `Commands.hs` for Template Haskell to generate the corresponding sum type constructors.

### Command Handler Rules for SetAccountSubtype

- Account must exist
- Account must be `Regular` (reject `External`)
- User must be Owner (matching `SetOverdraftLimit` pattern — account type is a management-level setting)
- Emits `AccountSubtypeSet` event

### New Error Variants

Two error types following the existing dual-error pattern:

```haskell
-- In Domain.Account.CommandHandler.AccountError (simple enum for pure logic)
| ExternalTypeNotSettable

-- In Domain.Account.Errors.AccountError (rich type for service/API layer)
| ExternalTypeNotSettable { externalTypeNotSettableId :: AccountId }
```

With a corresponding `mkExternalTypeNotSettable` constructor in `Errors.hs`.

### Projection Update

```haskell
-- Note: this handler is only reached if the event was stored, which means
-- the command handler already validated the account is Regular.
-- The projection trusts the event stream.
handleAccountEvent account (AccountSubtypeSetAccountEvent e) =
  account { kind = Regular e.subtype }
```

## Overdraft Defaults by Account Type

When `overdraftLimit` is not specified at creation (`Nothing` in the `Maybe (Maybe Money)` field), the default depends on account type:

| Account Type | Default Overdraft Limit |
|-------------|------------------------|
| Cash | `Just 0` (no overdraft) |
| Bank Account | `Just 0` (no overdraft) |
| E-Wallet | `Just 0` (no overdraft) |
| Asset | `Just 0` (no overdraft) |
| Loan | `Nothing` (unlimited) |
| External | `Nothing` (unlimited, unchanged) |

Users can always override with an explicit value. Defaults apply only at creation time.

The existing two-branch pattern match in `CommandHandler.hs` (Regular → `Just 0`, External → `Nothing`) expands to match on `AccountKind` and then the nested `AccountSubtype`:

```haskell
Nothing -> case kind of
  External -> Nothing
  Regular (Loan _) -> Nothing
  Regular _ -> Just (unsafeMoney (moneyCurrency initialBalance) 0)
```

## Web Layer

### Modified: POST /api/accounts

```haskell
data CreateAccountRequest = CreateAccountRequest
  { name :: Text
  , initialBalance :: Double
  , currency :: Text
  , overdraftLimit :: Maybe Double
  , accountType :: Maybe AccountSubtypeRequest  -- NEW, defaults to Cash
  }
```

### New Endpoint: PUT /api/accounts/:id/type

```haskell
data SetAccountSubtypeRequest = SetAccountSubtypeRequest
  { accountType :: AccountSubtypeRequest
  }
```

### AccountSubtypeRequest DTO

Discriminated JSON using a `type` field:

```haskell
data AccountSubtypeRequest = AccountSubtypeRequest
  { type_ :: Text                       -- "cash" | "bankAccount" | "eWallet" | "asset" | "loan"
  , bankName :: Maybe Text
  , accountNumber :: Maybe Text
  , cardNetwork :: Maybe Text           -- "visa" | "mastercard" | "amex" | "<other>"
  , provider :: Maybe Text
  , accountIdentifier :: Maybe Text
  , storageLocation :: Maybe Text
  , assetKind :: Maybe Text             -- "property" | "vehicle" | "stocks" | "retirementFund" | "<other>"
  , description :: Maybe Text
  , lender :: Maybe Text
  , interestRate :: Maybe Double
  , dueDate :: Maybe Text               -- ISO 8601 date
  , metadata :: Maybe (Map Text Text)
  }
```

Conversion function `toAccountSubtype :: AccountSubtypeRequest -> Either Text AccountSubtype` validates the `type_` discriminator and extracts relevant fields. Unknown `type_` values produce a `Left` error (mapped to HTTP 400). Fields irrelevant to the given type are silently ignored.

### Modified: toCreateAccountCommand

The existing `toCreateAccountCommand :: UserId -> AccountKind -> CreateAccountRequest -> Either Text CreateAccount` changes signature. The old `AccountKind` parameter (Regular/External) is replaced — the handler determines `AccountKind` by combining the request's `accountType` field with the endpoint context:

```haskell
toCreateAccountCommand :: UserId -> CreateAccountRequest -> Either Text CreateAccount
```

The handler passes `Regular <parsed AccountSubtype>` as `kind`. External accounts are created through a separate internal code path (user registration), not through this endpoint.

### JSON Examples

```json
{ "type": "cash", "storageLocation": "wallet" }
{ "type": "bankAccount", "bankName": "Monobank", "cardNetwork": "visa" }
{ "type": "eWallet", "provider": "PayPal", "accountIdentifier": "user@email.com" }
{ "type": "asset", "assetKind": "vehicle", "description": "Toyota Camry" }
{ "type": "loan", "lender": "PrivatBank", "interestRate": 12.5, "dueDate": "2028-01-15" }
```

### Modified: AccountResponse

```haskell
data AccountResponse = AccountResponse
  { id :: UUID
  , name :: Text
  , balance :: Double
  , currency :: Text
  , overdraftLimit :: Maybe Double
  , accountType :: Maybe Value          -- NEW: JSON object with type + properties, Nothing for External
  , version :: Int
  }
```

## Event Serialization & Backwards Compatibility

### AccountKind JSON

The serialized JSON key remains `accountType` for backwards compatibility with existing events in the store.

- `External` serializes as `"External"`
- `Regular subtype` serializes as `{"tag": "Regular", "accountType": <subtype JSON>}`
- Old events contain `"RegularAccount"` and `"ExternalAccount"` (the previous Generic-derived format) — custom `FromJSON` instance handles both old and new formats: `"RegularAccount"` → `Regular (Cash defaultCashProperties)`, `"ExternalAccount"` → `External`

### AccountSubtype JSON

Same discriminated format as the web DTO:

```json
{ "type": "cash", "storageLocation": "wallet", "metadata": {} }
{ "type": "bankAccount", "bankName": "Monobank", "metadata": {} }
```

### AccountSubtypeSet Event JSON

New event type, no backwards compatibility needed:

```json
{
  "accountType": { "type": "bankAccount", "bankName": "Monobank" },
  "by": "uuid-here"
}
```

## Testing Strategy

### Property Tests

- **Roundtrip serialization**: `AccountSubtype` and `AccountKind` survive JSON encode/decode, including backwards compat with old `"RegularAccount"`/`"ExternalAccount"` string formats
- **Default overdraft by type**: Creating an account without explicit overdraft limit produces the correct default for each `AccountSubtype`
- **SetAccountSubtype idempotence**: Setting the same type twice produces identical state
- **External rejection**: `SetAccountSubtype` always fails on `External`

### Unit Tests

- **Command handler for SetAccountSubtype**: Owner can set, non-Owner rejected, External rejected
- **AccountCreated with each type variant**: Projection correctly initializes `kind` with properties
- **Backwards compat deserialization**: Old `AccountCreated` events with `"RegularAccount"` / `"ExternalAccount"` strings deserialize to `Regular defaultCash` / `External`
- **Overdraft defaults**: Each account type gets correct default when `overdraftLimit` is `Nothing` in `CreateAccount`
- **DTO conversion**: `AccountSubtypeRequest` → `AccountSubtype` for each variant, including validation of unknown `type_` values

### Integration Tests

- **Create account with type → query → verify type in response**: End-to-end through event store
- **Change account type**: Create as Cash, set to BankAccount with properties, verify properties persisted
- **Migration scenario**: Seed old-format events, verify read model rebuilds correctly with defaulted types

### Generators (Testkit)

- `Arbitrary AccountSubtype` — generates random variant with random properties
- `Arbitrary AccountKind` — generates `Regular <random type>` or `External`
- `Arbitrary` for each properties record and sub-enums (`CardNetwork`, `AssetKind`)

## Notes

- `interestRate` in `LoanProperties` is a percentage value (e.g., 12.5 means 12.5%), stored as `Rational` internally and `Double` in JSON — consistent with Money handling.
- `metadata` map has no size or key/value length constraints in this iteration. Validation can be added later if needed.

## Scope Exclusions

- No business rule changes per account type (all types follow same transfer/overdraft/access mechanics)
- No account type migration tool for existing accounts (they default to Cash via backwards compat)
- No filtering/grouping API endpoints (can be added later)
- No icons or display metadata (frontend concern)
- No Telegram bot updates (deferred — will need updating if Telegram bot exposes account creation with type selection)
