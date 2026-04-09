---
status: completed
---

# User Configurations

## Summary

Introduce a Configuration bounded context that manages per-user accounting parameters: base currency, default currency, and dynamic dictionaries (income categories, expense categories, and future extensible lists). Configurations are standalone aggregates that can be shared across users. Users reference a configuration; modifying a shared configuration triggers an implicit clone-on-write. A system default configuration is seeded on application startup.

## Motivation

Currently, key accounting parameters are hardcoded:
- Default currency (`USD`) in `mkDefaultMoney`, `AuthService`, and `AccountAPI`
- Income categories as a fixed enum: `Salary | Freelance | Investment | IncomeGift | IncomeOther`
- Expense categories as a fixed enum: `Food | Transport | Utilities | Rent | Entertainment | ExpenseOther`
- Telegram keyboards and Web API parsers reference these enums directly

As a SaaS product, each user needs to configure these parameters. Categories must also be renamable (propagating to all historical transactions) and extensible to new list types (labels, tags, payment methods) without new aggregate types.

## Design Decisions

- **Separate bounded context**: Configuration is a different concern from User (identity/auth) and Transaction. It has its own aggregate, events, and projection. `UserId` links them.
- **Shared configurations with clone-on-write**: Configurations are standalone entities. Multiple users can reference the same one (e.g., the system default). When a user modifies a shared config, the system transparently clones it, reassigns the user's reference, and applies the change.
- **System-only creation, user cloning**: Only the system seeds configurations (like the default). Users create new ones exclusively by cloning (implicit via clone-on-write).
- **Two currencies**: `baseCurrency` (accounting/External account currency) and `defaultCurrency` (convenience default for new Regular accounts). Changing `baseCurrency` also changes the External account's currency via `ChangeAccountCurrency`. This is only possible while the account has no transactions — once any account has debit/credit events, its currency locks permanently (`AccountCurrencyLocked`). This is a general Account domain constraint, not Configuration-specific. The `ChangeBaseCurrency` service flow: attempt `ChangeAccountCurrency` on External account → if accepted, apply `ChangeBaseCurrency` on Configuration.
- **Dictionary abstraction**: Categories are modeled as entries in typed dictionaries. The Configuration context manages dictionaries keyed by opaque `DictionaryId` — it has no knowledge of what the dictionaries represent. Consumer contexts (Transaction, future Label) define their own well-known `DictionaryId` constants.
- **Entries have IDs**: Dictionary entries have stable `DictionaryEntryId` UUIDs. Transactions reference entry IDs, not names. Renaming an entry updates the display name without affecting stored events.
- **Seed on startup**: The application checks for the default configuration on startup and creates it if absent. Default values are defined in code.
- **LiquidHaskell**: New domain types (`ConfigurationId`, `DictionaryId`, `DictionaryEntryId`, `EntryName`, `Configuration`, `CreatedBy`) require refinement types per project convention. `EntryName` in particular: non-empty, trimmed, max 50 characters.

## Domain Model

### New Types

```haskell
-- Configuration identity
newtype ConfigurationId = ConfigurationId UUID
newtype DictionaryEntryId = DictionaryEntryId UUID

-- Opaque dictionary key — no domain semantics in Configuration context
newtype DictionaryId = DictionaryId Text

-- Display name for a dictionary entry (non-empty, trimmed, max 50 chars)
newtype EntryName = EntryName Text

-- Who created a configuration
data CreatedBy
  = System
  | ClonedBy UserId ConfigurationId  -- user who cloned, source config

-- A single dictionary entry
data DictionaryEntry = DictionaryEntry
  { entryId :: DictionaryEntryId
  , name :: EntryName
  }

-- A typed collection of entries
data Dictionary = Dictionary
  { entries :: [DictionaryEntry] }

-- Configuration aggregate state
data Configuration = Configuration
  { baseCurrency :: Currency
  , defaultCurrency :: Currency
  , dictionaries :: Map DictionaryId Dictionary
  , createdBy :: CreatedBy
  }
```

### Well-Known Constants (defined in consumer contexts)

Transaction domain:
```haskell
incomeCategoryDictId :: DictionaryId
incomeCategoryDictId = DictionaryId "income-category"

expenseCategoryDictId :: DictionaryId
expenseCategoryDictId = DictionaryId "expense-category"
```

Default configuration:
```haskell
defaultConfigurationId :: ConfigurationId
defaultConfigurationId = ConfigurationId "00000000-0000-0000-0000-000000000001"
```

### TransferCategory (modified)

```haskell
data TransferCategory
  = IncomeCat DictionaryEntryId
  | ExpenseCat DictionaryEntryId
  | InternalCat
```

Replaces the current enum-based `IncomeCategory` / `ExpenseCategory` types. `InternalCat` carries no dictionary reference — internal transfers (Regular → Regular) have no category. The existing `validateTransferCategory` function is updated to verify that `IncomeCat`/`ExpenseCat` carry a `DictionaryEntryId` that exists in the correct dictionary (validated at the application layer against the user's configuration read model), while `InternalCat` requires no validation.

## Events

### Configuration Events

```haskell
-- Aggregate lifecycle
data ConfigurationCreated = ConfigurationCreated
  { baseCurrency :: Currency
  , defaultCurrency :: Currency
  , dictionaries :: Map DictionaryId Dictionary
  , createdBy :: CreatedBy
  }

-- Currency updates
data BaseCurrencyChanged = BaseCurrencyChanged { newCurrency :: Currency }
data DefaultCurrencyChanged = DefaultCurrencyChanged { newCurrency :: Currency }

-- Dictionary entry operations (generic across all dictionary types)
data DictionaryEntryAdded = DictionaryEntryAdded
  { dictionaryId :: DictionaryId
  , entryId :: DictionaryEntryId
  , name :: EntryName
  }

data DictionaryEntryRenamed = DictionaryEntryRenamed
  { dictionaryId :: DictionaryId
  , entryId :: DictionaryEntryId
  , newName :: EntryName
  }

data DictionaryEntryRemoved = DictionaryEntryRemoved
  { dictionaryId :: DictionaryId
  , entryId :: DictionaryEntryId
  }
```

### Account Events (addition to existing)

```haskell
data AccountCurrencyChanged = AccountCurrencyChanged { newCurrency :: Currency }
```

### User Events (addition to existing)

```haskell
data UserConfigurationAssigned = UserConfigurationAssigned
  { configurationId :: ConfigurationId }
```

## Commands

### Configuration Commands

```haskell
data CreateConfiguration = CreateConfiguration
  { baseCurrency :: Currency
  , defaultCurrency :: Currency
  , dictionaries :: Map DictionaryId Dictionary
  , createdBy :: CreatedBy
  }

data ChangeBaseCurrency = ChangeBaseCurrency { newCurrency :: Currency }
data ChangeDefaultCurrency = ChangeDefaultCurrency { newCurrency :: Currency }

data AddDictionaryEntry = AddDictionaryEntry
  { dictionaryId :: DictionaryId
  , entryId :: DictionaryEntryId
  , name :: EntryName
  }

data RenameDictionaryEntry = RenameDictionaryEntry
  { dictionaryId :: DictionaryId
  , entryId :: DictionaryEntryId
  , newName :: EntryName
  }

data RemoveDictionaryEntry = RemoveDictionaryEntry
  { dictionaryId :: DictionaryId
  , entryId :: DictionaryEntryId
  }
```

### Account Commands (addition to existing)

```haskell
data ChangeAccountCurrency = ChangeAccountCurrency { newCurrency :: Currency }
```

### User Commands (addition to existing)

```haskell
data AssignConfiguration = AssignConfiguration
  { configurationId :: ConfigurationId }
```

## Invariants

- Dictionary entries must have unique names within their dictionary
- `ConfigurationCreated` must be the first event on the aggregate
- `DictionaryId` must exist in the configuration for entry operations (except `AddDictionaryEntry`, which auto-creates the dictionary if absent)
- `DictionaryEntryId` must exist in the dictionary for rename/remove
- Cannot remove the last entry in a dictionary

## Error Types

A new `ConfigurationError` type following the existing per-context pattern (`UserError`, `AccountError`, `TransactionError`), with a corresponding `ConfigurationError` variant added to the top-level `DomainError` union.

```haskell
data ConfigurationError
  = ConfigurationNotFound { configurationId :: ConfigurationId }
  | DictionaryNotFound { configurationId :: ConfigurationId, dictionaryId :: DictionaryId }
  | EntryNotFound { dictionaryId :: DictionaryId, entryId :: DictionaryEntryId }
  | DuplicateEntryName { dictionaryId :: DictionaryId, name :: EntryName }
  | CannotRemoveLastEntry { dictionaryId :: DictionaryId }
```

New `AccountError` variant (addition to existing `AccountError` type):

```haskell
  | AccountCurrencyLocked { accountId :: AccountId }
      -- account has transactions, currency cannot change
```

The `ChangeBaseCurrency` flow uses this: the application service attempts `ChangeAccountCurrency` on the External account first — if the account rejects with `AccountCurrencyLocked`, the base currency change is also rejected. The lock is enforced at the account level, not the configuration level.

## Clone-on-Write Flow

When a user requests a configuration change (e.g., "change default currency to EUR"):

1. Application service checks: is the user the owner of their referenced config? (`createdBy` is `ClonedBy thisUserId _`)
2. **If owned**: apply the update command directly
3. **If shared** (e.g., system default):
   a. Read current configuration state from read model
   b. Create a new Configuration aggregate via `CreateConfiguration` (copying state, `createdBy = ClonedBy userId sourceConfigId`)
   c. Issue `AssignConfiguration` on the User aggregate (pointing to new config)
   d. Apply the update command to the new Configuration aggregate

This is application service orchestration, not a saga — no compensating actions needed. An unused clone is harmless.

**Concurrency note**: If two concurrent requests both trigger clone-on-write for the same user, two clones may be created. Optimistic concurrency on the User aggregate (via Eventium's `(uuid, version)` constraint) ensures only one `AssignConfiguration` succeeds — the other retries and sees the user now owns a config, applying the update directly. This is an accepted edge case; orphaned clones are inert.

## Read Model

### ConfigurationReadModel

```haskell
data ConfigurationReadModel = ConfigurationReadModel
  { configurations :: Map ConfigurationId ConfigurationData }

data ConfigurationData = ConfigurationData
  { baseCurrency :: Currency
  , defaultCurrency :: Currency
  , dictionaries :: Map DictionaryId DictionaryData
  , createdBy :: CreatedBy
  , version :: Int                              -- used for optimistic concurrency in clone-on-write
  }

data DictionaryData = DictionaryData
  { entries :: Map DictionaryEntryId EntryName }  -- display order: alphabetical by EntryName
```

Added to `AppEnv` as `configurationReadModel :: TVar ConfigurationReadModel` with `HasConfigurationReadModel` typeclass.

### User Read Model Extension

`UserData` gains `configurationId :: ConfigurationId`.

### Transaction Read Model

Stores `DictionaryEntryId` references. Display names are resolved at query time by joining with the configuration read model — always fresh after renames.

## API Endpoints

```
GET    /api/users/me/configuration                                       -- get my configuration
PUT    /api/users/me/configuration/base-currency                         -- update base currency
PUT    /api/users/me/configuration/default-currency                      -- update default currency
GET    /api/users/me/configuration/dictionaries/:dictId                  -- list dictionary entries
POST   /api/users/me/configuration/dictionaries/:dictId/entries          -- add entry
PUT    /api/users/me/configuration/dictionaries/:dictId/entries/:entryId -- rename entry
DELETE /api/users/me/configuration/dictionaries/:dictId/entries/:entryId -- remove entry
```

All endpoints are scoped to the authenticated user. The `ConfigurationId` is an internal concern — the service resolves it from the user read model on every request. Clone-on-write is transparent; after a clone, the user's reference updates automatically.

### Authorization

- All endpoints require authentication (JWT, same as existing API).
- The service resolves the authenticated user's `configurationId` from the user read model. No configuration ID is exposed in the API.
- Mutating endpoints trigger clone-on-write when the referenced config is shared.
- The system default configuration is immutable via the API — clone-on-write ensures users never modify it directly.

## Default Configuration

Seeded on application startup if `defaultConfigurationId` aggregate does not exist.

**Base currency**: `USD`
**Default currency**: `USD`

**Income categories** (`income-category` dictionary):
Salary, Freelance, Investment, Business, Rental, Interest, Dividends, Gift, Refund, Other

**Expense categories** (`expense-category` dictionary):
Food, Groceries, Dining, Transport, Utilities, Rent, Entertainment, Healthcare, Education, Clothing, Insurance, Subscriptions, Household, Personal, Travel, Gifts, Charity, Taxes, Fees, Other

Each entry receives a deterministic `DictionaryEntryId` (UUID v5 derived from dictionary ID + entry name) so that historical event migration can map old enum values to known IDs.

## Registration Flow Changes

Current flow:
1. Create User aggregate
2. Create External account with hardcoded `USD`

New flow:
1. Create User aggregate
2. Issue `AssignConfiguration` with `defaultConfigurationId`
3. Read default config's `baseCurrency`
4. Create External account with `baseCurrency`

## Migration

No event migration is needed — the database will be recreated from scratch. Old `IncomeCategory`/`ExpenseCategory` enum serialization formats do not need backward-compatible `FromJSON` handling.

## Impact Summary

### New Code

| Layer | Module | Purpose |
|-------|--------|---------|
| Domain | `Domain/Configuration/Types.hs` | ConfigurationId, DictionaryId, DictionaryEntryId, EntryName, Dictionary, DictionaryEntry, Configuration, CreatedBy |
| Domain | `Domain/Configuration/Events.hs` | All configuration events |
| Domain | `Domain/Configuration/Commands.hs` | All configuration commands |
| Domain | `Domain/Configuration/CommandHandler.hs` | Command handling + invariant enforcement |
| Domain | `Domain/Configuration/Projection.hs` | Event folding to Configuration state |
| Application | `Application/ReadModels/Configuration.hs` | ConfigurationReadModel |
| Application | `Application/Services/ConfigurationService.hs` | Clone-on-write orchestration, CRUD |
| Web | `Web/API/ConfigurationAPI.hs` | REST endpoints, DTOs |

### Modified Code

| File | Change |
|------|--------|
| `Domain/Core/Types.hs` | Remove `IncomeCategory`, `ExpenseCategory` enums. Update `TransferCategory` to use `DictionaryEntryId`. |
| `Domain/Account/Events.hs` | Add `AccountCurrencyChanged` event |
| `Domain/Account/Commands.hs` | Add `ChangeAccountCurrency` command |
| `Domain/Account/CommandHandler.hs` | Handle `ChangeAccountCurrency` — reject with `AccountCurrencyLocked` if account has debit/credit events |
| `Domain/Account/Errors.hs` | Add `AccountCurrencyLocked` variant |
| `Domain/Transaction/Events.hs` | `TransferInitiated.category` type change. |
| `Domain/User/Events.hs` | Add `UserConfigurationAssigned` |
| `Domain/User/Commands.hs` | Add `AssignConfiguration` |
| `Domain/User/CommandHandler.hs` | Handle `AssignConfiguration` |
| `Domain/User/Projection.hs` | Add `configurationId` to `User` |
| `Application/Services/AuthService.hs` | Registration assigns default config, reads `baseCurrency` for External account |
| `Application/Services/TransactionService.hs` | Validate `DictionaryEntryId` against user's config dictionaries |
| `Application/ReadModels/User.hs` | Add `configurationId` to `UserData` |
| `Infrastructure/App.hs` | Add `configurationReadModel` to `AppEnv`, `HasConfigurationReadModel` typeclass |
| `Web/API/AccountAPI.hs` | Replace hardcoded `"USD"` fallback with `defaultCurrency` from config |
| `Web/Types.hs` | Remove `parseIncomeCategory`/`parseExpenseCategory` |
| `Telegram/Keyboards.hs` | Dynamic keyboards from config read model — fetch user's configuration on each interaction, render entry names as buttons with `DictionaryEntryId` in callback data |
| `Telegram/Commands.hs` | Remove hardcoded category parsing, resolve `DictionaryEntryId` from callback data |
| `app/Main.hs` | Seed default config on startup, wire `ConfigurationReadModel` |

### Removed Code

- `IncomeCategory` enum
- `ExpenseCategory` enum
- `parseIncomeCategory` / `parseExpenseCategory`
- Hardcoded category keyboards in Telegram
- Hardcoded `USD` in `AuthService` and `AccountAPI`
