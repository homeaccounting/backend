---
status: draft
---

# Bank Integration Phase 2 Design

## Summary

Phase 2 adds configurable category routing to bank imports. The resync endpoint no longer takes a `defaultCategory` in its request body; instead it resolves each imported transaction to a category by (1) looking up the transaction's MCC in a per-user `Map MCC CategoryId` stored on the user's `Configuration`, with (2) a per-user default banking category as fallback. The MCC map and the two defaults live on a new `BankingConfiguration` sub-record of `Configuration`, exposed as `Configuration.banking` to mirror the `banking:` key already used in the server-side YAML configuration. In Phase 2 they are populated from hardcoded defaults at configuration-seed time (for the system default config) and propagated through clone-on-write (for user-specific configurations); the defaults and the MCC map are editable via the configuration API.

No migration / backfill path ships with Phase 2 — the database is recreated on deploy. Production data is not carried forward.

Naming note: Infrastructure already defines `BankingConfig` for the YAML-parsed server-level feature flags (`banking.enabled`, provider toggles). The new Domain aggregate type is `BankingConfiguration` — distinct module (`Domain.Configuration.*`), distinct purpose (per-user data, not deployment flags), no collision at the call site.

## Prerequisites

- `CategoryId` alias for `DictionaryEntryId` (introduced alongside `LabelId` in the transaction-labels work, `feat/transaction-labels` branch). Phase 2 assumes it has landed on `master`. If merging order slips, substitute `DictionaryEntryId` at call sites and schedule a follow-up rename.
- `Domain.Core.Types` gains `type MCC = Text` as part of this PR.

The webhook surface, persistent per-user token storage, `BankAccountsLinked` / `BankAccountsUnlinked` events, and `BankLinkState` read model described in the original 2026-04-10 design remain deferred. Phase 1's resync-on-demand flow with an `X-Banking-Token` header stays exactly as-is from an authentication standpoint; only the payload shape and the downstream category resolution change.

## Motivation

Phase 1 ships resync-only and requires the caller to hand the server a `defaultCategory :: UUID` in every request. Classification ignores MCC — every imported expense lands in whatever category the client picked. This forces all auto-categorization into the client (Telegram bot, future UI), which means:

- Every client re-implements the same MCC→category logic.
- Users get no category diversity on import: every expense is one category.
- Category choice is a per-request decision, not a per-user configuration, so the user's preference can't persist across devices.

MCC (ISO 18245 Merchant Category Codes) is a cross-provider standard. Modelling the mapping at the `Configuration` level — even when Phase 2 only populates it from hardcoded defaults — sets up future customization (per-user edits, additional providers) as a pure API/event addition rather than a schema change.

A new `MCC` type alias (`type MCC = Text`) lives alongside `CategoryId` in `Domain.Core.Types`. MCC values are 4-digit numeric codes in ISO 18245, but the ecosystem consistently renders them as strings (API payloads, JSON map keys, logs). Modelling as `Text` both matches that convention and leaves room for non-Monobank providers that may report non-numeric category keys through the same field. The alias documents intent at call sites without introducing a newtype.

## Out of Scope (Reaffirmed)

All items deferred from Phase 1 remain deferred:

- Webhook endpoints, webhook-secret derivation, signature verification, webhook registration.
- Per-user persistent storage of bank-provider API tokens.
- `BankAccountsLinked` / `BankAccountsUnlinked` events and the `BankLinkState` read model.
- `UserConfiguration.banking.enabled` per-user opt-in toggle beyond the existing global kill switches (`banking.enabled`, `providers.<name>.enabled`).

Additionally new to this phase's out-of-scope list:

- **Granular per-MCC editing of the map.** Phase 2 exposes the map as a single bulk-replace field on the banking-configuration endpoint (supply the full desired map, server replaces it wholesale). Per-MCC add / remove granular events and a per-key API are out of scope.
- **Per-provider category keys.** Some providers (e.g., PrivatBank) report category names as free-form text rather than MCC codes. Phase 2 models one map keyed by `MCC :: Text`; because the type is already text, mapping a PrivatBank "Groceries" category name to the same category entry is a mechanical extension rather than a schema change — only the provider adapter needs to populate `BankTransaction.mcc` with the provider's native key. Additional provider-specific maps, if the single map ever proves insufficient, remain future work.

## Design Decisions

- **`Dictionary` stays abstract.** No `kind`, no `default`, no category-specific fields on `DictionaryEntry` or `Dictionary`. The dictionary abstraction models labels, income categories, expense categories, and future lists without bank-import-specific concerns leaking in.
- **Banking settings are grouped.** A new `BankingConfiguration` record, exposed as `Configuration.banking`, holds the three banking-specific fields. Adding a future "manual-entry default category" or similar context-specific defaults stays a named sibling field on `Configuration`, not a reopening of `Dictionary`.
- **MCC map is data, not code.** Even though Phase 2 only ever writes the hardcoded default into it, the map lives on the aggregate. Making it customizable later is adding one event and one API endpoint; no migration.
- **Hardcoded defaults live in `Domain/Configuration/Defaults.hs`.** The content is Configuration-specific (well-known `DictionaryId`s, default entry names, deterministic UUIDv5 helper, MCC→category seed map) and belongs inside the Configuration bounded context next to `Commands`, `Events`, `Projection`, and `Errors`. `Domain.Core.*` stays reserved for cross-context primitive types (`Money`, `Currency`, `DictionaryEntryId` itself). The module also absorbs the `configNamespace` / `mkDeterministicEntryId` / `incomeCategoryDictId` / `expenseCategoryDictId` / `defaultIncome|ExpenseCategories` constants that currently live inline in `Application.Services.ConfigurationService`; moving them into Domain removes a cross-layer leak and lets `BankImportService` reuse them without importing Application.
- **Provider stays out of user-category-land.** The banking adapter does not import `Domain.Configuration` or `CategoryId`. `TransactionClassification` collapses to a direction discriminator (`ClassifiedIncome | ClassifiedExpense`). `BankImportService` does all category resolution using `BankTransaction.mcc :: Maybe MCC` and the user's configuration.
- **Existence check on MCC lookup.** If the MCC points at a `CategoryId` that no longer exists in the user's category dictionary (e.g., user deleted the default "Food" entry), the service falls back to the banking default for that direction rather than rejecting the transaction. Only if the default itself is unset does the import fail.
- **Fail individual transactions, not the whole resync.** A missing default produces a `BankingError` recorded in the per-account `failures` list (same mechanism Phase 1 already uses). The rest of the resync continues.
- **Granular, per-field events.** `BankingDefaultIncomeCategorySet` and `BankingDefaultExpenseCategorySet` match the existing per-field style in the Configuration aggregate (`BaseCurrencyChanged`, `DefaultCurrencyChanged`). The MCC map uses a single bulk `BankingMccExpenseCategoryMapSet` event for Phase 2; granular per-MCC events can be added when user-editing ships.

## Domain Changes

### New sub-record on `Configuration`

```haskell
data BankingConfiguration = BankingConfiguration
  { defaultIncomeCategory  :: Maybe CategoryId
  , defaultExpenseCategory :: Maybe CategoryId
  , mccExpenseCategoryMap         :: Map MCC CategoryId
  }
  deriving (Show, Eq, Generic)

instance FromJSON BankingConfiguration
instance ToJSON   BankingConfiguration

data Configuration = Configuration
  { baseCurrency    :: Currency
  , defaultCurrency :: Currency
  , dictionaries    :: Map DictionaryId Dictionary
  , banking         :: BankingConfiguration   -- NEW
  , createdBy       :: CreatedBy
  , isCreated       :: Bool
  }
```

Initial value (from `configurationDefault`):

```haskell
banking = BankingConfiguration
  { defaultIncomeCategory  = Nothing
  , defaultExpenseCategory = Nothing
  , mccExpenseCategoryMap         = Map.empty
  }
```

`Dictionary` and `DictionaryEntry` are unchanged.

### New events

All three are part of the Configuration aggregate; added to `configurationEvents` in `Domain/Configuration/Events.hs`.

```haskell
data BankingDefaultIncomeCategorySet = BankingDefaultIncomeCategorySet
  { categoryId :: CategoryId
  }

data BankingDefaultExpenseCategorySet = BankingDefaultExpenseCategorySet
  { categoryId :: CategoryId
  }

data BankingMccExpenseCategoryMapSet = BankingMccExpenseCategoryMapSet
  { mapping :: Map MCC CategoryId
  }
```

JSON derivation uses the existing `deriveJSON defaultOptions` pattern. Because all three fields sit under `banking` and the aggregate doesn't persist `Configuration` itself (events are the source of truth), existing events decode without migration — a fresh `BankingConfiguration` with empty fields is built and replayed forward.

### New commands

Added in `Domain/Configuration/Commands.hs`; wired into `ConfigurationCommandHandler`.

```haskell
data SetBankingDefaultIncomeCategory  = SetBankingDefaultIncomeCategory  { categoryId :: CategoryId }
data SetBankingDefaultExpenseCategory = SetBankingDefaultExpenseCategory { categoryId :: CategoryId }
data SetBankingMccExpenseCategoryMap         = SetBankingMccExpenseCategoryMap         { mapping    :: Map MCC CategoryId }
```

Command-handler invariants:

- `SetBankingDefaultIncomeCategory` / `SetBankingDefaultExpenseCategory`: the referenced entry must exist in `dictionaries[income-category]` / `dictionaries[expense-category]` respectively. Rejected with a new `ConfigurationError` variant otherwise.
- `SetBankingMccExpenseCategoryMap`: every `CategoryId` in the map must exist in either `dictionaries[income-category]` or `dictionaries[expense-category]`. Phase 2's seed path builds the map from deterministic UUIDs of known-to-be-present entries and the clone path carries the validated source map forward, so this is a defensive check. Rejected otherwise.

### Existing-command changes

`RemoveDictionaryEntry` gains two additional rejection cases (added to the existing "refuse to remove in-use dictionary entry" family):

- entry is currently `banking.defaultIncomeCategory` or `banking.defaultExpenseCategory`, or
- entry appears as a value in `banking.mccExpenseCategoryMap`.

Error messaging mirrors the existing in-use rejection path.

### `Domain/Configuration/Defaults.hs` — new module

Extracts content currently in `Application/Services/ConfigurationService.hs` so it can be shared with the seed path, the clone-on-write path, and test code without the Application-layer detour.

Each default category is declared once inside an `expense` or `income` record. Callers reach the category via record-dot syntax (`expense.travel.entryId`, `income.salary.entryName`), so the name string `"Travel"` appears exactly once in the module and every other reference — seed list, MCC map, banking default fallbacks — goes through the binding.

```haskell
module Domain.Configuration.Defaults
  ( -- * UUIDv5 helpers
    configNamespace
  , mkDeterministicEntryId

    -- * Well-known dictionary IDs
  , incomeCategoryDictId
  , expenseCategoryDictId

    -- * Default category namespaces (types only; no constructors exported)
  , DefaultEntry (..)
  , ExpenseDefaults
  , IncomeDefaults
  , expense
  , income

    -- * Derived lists (seed loop consumes these)
  , defaultExpenseCategories
  , defaultIncomeCategories

    -- * Banking seed data
  , defaultMccExpenseCategoryMap
  ) where

data DefaultEntry = DefaultEntry
  { entryName :: !Text
  , entryId   :: !CategoryId
  }

data ExpenseDefaults = ExpenseDefaults
  { food          :: !DefaultEntry
  , transport     :: !DefaultEntry
  , utilities     :: !DefaultEntry
  , rent          :: !DefaultEntry
  , entertainment :: !DefaultEntry
  , health        :: !DefaultEntry
  , education     :: !DefaultEntry
  , clothing      :: !DefaultEntry
  , insurance     :: !DefaultEntry
  , subscriptions :: !DefaultEntry
  , household     :: !DefaultEntry
  , travel        :: !DefaultEntry
  , gifts         :: !DefaultEntry
  , charity       :: !DefaultEntry
  , taxesFees     :: !DefaultEntry
  , other         :: !DefaultEntry
  }

data IncomeDefaults = IncomeDefaults
  { salary     :: !DefaultEntry
  , freelance  :: !DefaultEntry
  , investment :: !DefaultEntry
  , business   :: !DefaultEntry
  , rental     :: !DefaultEntry
  , gift       :: !DefaultEntry
  , refund     :: !DefaultEntry
  , other      :: !DefaultEntry
  }

-- Each name string appears exactly once, on the line that defines the entry.
expense :: ExpenseDefaults
expense = ExpenseDefaults
  { food          = mkExpense "Food"
  , transport     = mkExpense "Transport"
  , utilities     = mkExpense "Utilities"
  , rent          = mkExpense "Rent"
  , entertainment = mkExpense "Entertainment"
  , health        = mkExpense "Health & Wellness"
  , education     = mkExpense "Education"
  , clothing      = mkExpense "Clothing"
  , insurance     = mkExpense "Insurance"
  , subscriptions = mkExpense "Subscriptions"
  , household     = mkExpense "Household"
  , travel        = mkExpense "Travel"
  , gifts         = mkExpense "Gifts"
  , charity       = mkExpense "Charity"
  , taxesFees     = mkExpense "Taxes & Fees"
  , other         = mkExpense "Other"
  }

income :: IncomeDefaults
income = IncomeDefaults
  { salary     = mkIncome "Salary"
  , freelance  = mkIncome "Freelance"
  , investment = mkIncome "Investment"
  , business   = mkIncome "Business"
  , rental     = mkIncome "Rental"
  , gift       = mkIncome "Gift"
  , refund     = mkIncome "Refund"
  , other      = mkIncome "Other"
  }

mkExpense :: Text -> DefaultEntry
mkExpense n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictId n)

mkIncome :: Text -> DefaultEntry
mkIncome n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictId n)

defaultExpenseCategories :: [DefaultEntry]
defaultExpenseCategories =
  [ expense.food, expense.transport, expense.utilities, expense.rent
  , expense.entertainment, expense.health, expense.education, expense.clothing
  , expense.insurance, expense.subscriptions, expense.household, expense.travel
  , expense.gifts, expense.charity, expense.taxesFees, expense.other
  ]

defaultIncomeCategories :: [DefaultEntry]
defaultIncomeCategories =
  [ income.salary, income.freelance, income.investment, income.business
  , income.rental, income.gift, income.refund, income.other
  ]

defaultMccExpenseCategoryMap :: Map MCC CategoryId
defaultMccExpenseCategoryMap = Map.fromList
  [ ("5411", expense.food.entryId)          -- Grocery stores, supermarkets
  , ("5499", expense.food.entryId)          -- Misc food stores
  , ("5812", expense.food.entryId)          -- Restaurants
  , ("5814", expense.food.entryId)          -- Fast food
  , ("5813", expense.entertainment.entryId) -- Bars, nightclubs
  , ("5541", expense.transport.entryId)     -- Service stations (fuel)
  , ("4111", expense.transport.entryId)     -- Local transit
  , ("4121", expense.transport.entryId)     -- Taxis
  , ("4131", expense.transport.entryId)     -- Bus lines
  , ("4511", expense.travel.entryId)        -- Airlines
  , ("4722", expense.travel.entryId)        -- Travel agencies
  , ("5912", expense.health.entryId)        -- Drug stores, pharmacies
  , ("8011", expense.health.entryId)        -- Doctors
  , ("8062", expense.health.entryId)        -- Hospitals
  , ("8220", expense.education.entryId)     -- Colleges, universities
  , ("5651", expense.clothing.entryId)      -- Family clothing
  , ("5691", expense.clothing.entryId)      -- Apparel
  , ("4900", expense.utilities.entryId)     -- Utilities
  , ("4814", expense.utilities.entryId)     -- Telecom services
  , ("4829", expense.other.entryId)         -- Wire transfers
  , ("5968", expense.subscriptions.entryId) -- Direct-marketing subscriptions
  -- …continues
  ]
```

The per-user banking defaults resolve to record fields too: `expense.other` / `income.other` are the initial fallbacks emitted by `seedDefaultConfiguration` (for the system default) and propagated through `cloneConfiguration` (for user-specific configurations).

Both records use `DuplicateRecordFields` + `OverloadedRecordDot` (already enabled globally) so the shared `other` field disambiguates automatically via the record type at each call site. Constructors are not exported; outside code never constructs `ExpenseDefaults`/`IncomeDefaults`, it only reads through the `expense`/`income` CAFs.

The initial Phase 2 table targets roughly the 30–50 most common MCC codes, all resolving to entries guaranteed present in a freshly seeded default configuration. It is *not* intended as a complete MCC reference. Extending it later is a code-only change; because there is no backfill, the updated `defaultMccExpenseCategoryMap` takes effect for freshly seeded default configurations and for any clone that happens after the change — existing per-user maps stay as-is and must be updated via `PUT /api/users/me/configuration/banking`.

No income-side MCC mappings are seeded in Phase 2: bank-reported income transactions rarely carry a discriminating MCC (salary, rental and freelance typically arrive as inbound transfers without card-MCC data). Income always falls back to the `banking.defaultIncomeCategory` default.

## Service Layer

### `BankImportService` resolution flow

The classifier collapses to a direction discriminator:

```haskell
-- Infrastructure/Banking/Provider.hs
data TransactionClassification
  = ClassifiedIncome
  | ClassifiedExpense
  deriving (Show, Eq)
```

Monobank's classifier:

```haskell
monoClassifyTransaction tx
  | tx.amount >= 0 = ClassifiedIncome
  | otherwise      = ClassifiedExpense
```

`BankImportService.importTransaction` resolves the category:

```
direction = provider.classifyTransaction tx
config    = getConfigurationForUser userId          -- already available
dict      = case direction of
              ClassifiedIncome  -> dictionaries[income-category]
              ClassifiedExpense -> dictionaries[expense-category]
dflt      = case direction of
              ClassifiedIncome  -> banking.defaultIncomeCategory
              ClassifiedExpense -> banking.defaultExpenseCategory

mccHit    = tx.mcc >>= flip Map.lookup banking.mccExpenseCategoryMap
candidate = case mccHit of
              Just eid | eid ∈ dict.entries -> Just eid
              _                             -> dflt

case candidate of
  Just eid -> build InitiateTransfer with that category
  Nothing  -> record BankingError "No bank-import <direction> category configured"
              in AccountResyncResult.failures for this tx; continue
```

The MCC-miss fallback and the stale-MCC (`eid` no longer in the dictionary) fallback both route through `dflt`. This guarantees graceful degradation: if the user deletes the "Food" category, grocery imports land in their bank-import default rather than failing.

### `ResyncRequest` body change

```haskell
-- was
data ResyncRequest = ResyncRequest
  { from :: UTCTime
  , to :: UTCTime
  , defaultCategory :: UUID   -- DROPPED in Phase 2
  }

-- becomes
data ResyncRequest = ResyncRequest
  { from :: UTCTime
  , to :: UTCTime
  }
```

The `defaultCategory` field is removed, not deprecated — Phase 1 explicitly flagged it as temporary. Clients currently sending the field will have the extra property ignored by aeson's default parsing, so no coordinated client/server deploy is required; the field simply stops doing anything and clients should drop it on their next release.

### Seeding (`ConfigurationService.seedDefaultConfiguration`)

After creating the default configuration and its dictionary entries, additionally apply (in order):

1. `SetBankingDefaultIncomeCategory (mkDeterministicEntryId incomeCategoryDictId "Other")`
2. `SetBankingDefaultExpenseCategory (mkDeterministicEntryId expenseCategoryDictId "Other")`
3. `SetBankingMccExpenseCategoryMap defaultMccExpenseCategoryMap`

All three are idempotent against the event store (the `ConfigurationCommandHandler` accepts them again if replayed).

### Cloning

`cloneConfiguration` (clone-on-write for user-specific configurations) carries the three banking fields forward from the source configuration. When a user first mutates a shared system configuration, the clone they end up with retains the system's `banking.defaultIncomeCategory`, `banking.defaultExpenseCategory`, and `banking.mccExpenseCategoryMap`. Without this, every user would silently lose banking defaults the first time they edit any other configuration field.

### No backfill

Phase 2 does not ship a backfill for pre-Phase-2 configurations. The deployment plan recreates the database, so there is no pre-existing event stream to patch. If that changes, a backfill task would iterate every configuration with an empty banking sub-record and emit the three `Set*` commands — but this is not part of Phase 2.

## Web Layer

### Configuration API additions

Single endpoint, partial-update semantics:

```
PUT /api/users/me/configuration/banking
Body: { "defaultIncomeCategory":  "<uuid-or-null>"         -- optional
      , "defaultExpenseCategory": "<uuid-or-null>"         -- optional
      , "mccExpenseCategoryMap":  { "<mcc>": "<uuid>", ... } -- optional, bulk-replace
      }
```

Path mirrors the existing `/api/users/me/configuration/...` namespace used throughout the configuration API.

- Missing field → no change.
- Present non-null value → issue `SetBankingDefault{Income,Expense}Category` / `SetBankingMccExpenseCategoryMap`.
- Present `null` on either default category → Phase 2 does not emit a "cleared" event. Nulling is out of scope; unset only exists as an initial state. If we need to clear later, add `BankingDefault*CategoryCleared` events.
- Present non-null `mccExpenseCategoryMap` → wholesale replacement. An empty object resets the map to empty. Individual-key editing is not in scope for Phase 2; clients read the current map and submit the full desired state.
- Returns the new `BankingConfiguration` value on 200.

Path `banking` mirrors the `banking:` key in the server YAML config (`config/*.yaml`). The YAML-level `BankingConfig` (feature flags) and the per-user `BankingConfiguration` (aggregate data) are distinct types in distinct modules; the shared name is an alignment, not an ambiguity.

The MCC map is user-editable via the same endpoint as the defaults — wholesale bulk replace. Granular per-MCC edits are not in scope.

### Configuration read endpoint

Wherever `GET /api/configuration` currently returns `ConfigurationData`, grow the response with `banking` mirroring `BankingConfiguration`. Existing clients that ignore unknown fields keep working; new clients can surface the defaults in a settings screen.

### Banking API — `POST /api/banking/resync`

- Drop `defaultCategory` field from `ResyncRequest`.
- Handler loads the user's configuration inline (it already needs read-model access for account matching) and threads it through to `BankImportService.resync`. The `CategoryId` argument currently threaded as `defaultCategory` is removed — `resync`'s signature simplifies to:

```haskell
resync ::
  BankProvider ->
  UserId ->
  [(BankAccountId, AccountId)] ->
  UTCTime -> UTCTime ->
  AppM ResyncResult
```

`importTransaction` reads the configuration via `HasReadModel env`; the parameter list drops the explicit default-category argument.

## Error Handling

One new `ConfigurationError` payload used by the three new command handlers; reuses the `ConfigurationError Text` constructor that `Domain.Core.Errors` already carries.

One new import-failure message (surfaced into `AccountResyncResult.failures` as `Text`, via `renderDomainError`):

- `"No bank-import income category configured"`
- `"No bank-import expense category configured"`

The import service does not introduce a new `DomainError` constructor — it reuses `BankingError Text` from Phase 1.

## Test Coverage

Property / unit tests:

- `Domain.Configuration.DefaultsSpec` — `defaultMccExpenseCategoryMap` contains only `CategoryId`s generated for known default entry names; all MCC keys are distinct and non-empty text; roundtrip `mkDeterministicEntryId`.
- `Domain.Configuration.CommandHandlerSpec` — `SetBankingDefault{Income,Expense}Category` rejects when the entry does not exist in the appropriate dictionary; `SetBankingMccExpenseCategoryMap` rejects when any value references a missing entry; `RemoveDictionaryEntry` rejects when the entry is a current bank-import default or appears in the MCC map.
- `Domain.Configuration.ProjectionSpec` — replaying the three new events populates `banking` correctly; re-ordering events preserves last-wins semantics on `SetBankingMccExpenseCategoryMap`.
- `Application.Services.BankImportServiceSpec` — MCC-hit resolves to the mapped entry; stale MCC (entry missing from dict) falls back to `banking.defaultExpenseCategory`; missing MCC falls back to `banking.defaultExpenseCategory`; both defaults unset produces `BankingError` in `failures`; income direction equivalent.
- `Application.Services.ConfigurationServiceSpec` — `seedDefaultConfiguration` emits all three new events on a clean event store.

Integration tests:

- `Integration.BankImportWorkflowSpec` — end-to-end resync with a mock provider returning one tx per common MCC; assert each transfer's category matches the hardcoded map.
- Clone-on-write test in `ConfigurationServiceSpec` — after `seedDefaultConfiguration`, trigger clone-on-write for a user via any configuration edit; verify the cloned configuration inherits the source's three banking fields.

JSON backwards-compat: all three new events are additive to `ConfigurationEvent`; existing stored events decode unchanged. No `TransferInitiated` changes in Phase 2.

## Migration and Rollout

Not deployment-coordinated:

1. Recreate the database (Phase 2 deployment prerequisite). On first start, `seedDefaultConfiguration` emits the three `Set*` events for the system default configuration. Subsequent user edits trigger clone-on-write, which propagates those fields to per-user configurations.
2. `POST /api/banking/resync` still accepts requests carrying `defaultCategory` in the body — aeson ignores the extra field. Phase 1 clients continue to work; they simply stop influencing categorization.
3. New clients drop the field and pick up the per-user bank-import defaults automatically.

Rollback is safe: the new fields are additive, the new events decode into an old projection as unknown-event-type (which the projection treats as no-op per eventium's behavior), and resync still runs against the old client payload.

## File Structure

### New

- `src/Domain/Configuration/Defaults.hs` — constants and helpers extracted from `ConfigurationService`.

### Modified

- `src/Domain/Core/Types.hs` — add `type MCC = Text` alias; `Dictionary`, `DictionaryEntry` stay as-is.
- `src/Domain/Configuration/Events.hs` — three new event records; add to `configurationEvents`.
- `src/Domain/Configuration/Commands.hs` — three new command records.
- `src/Domain/Configuration/CommandHandler.hs` — three new handler branches; invariants on removal.
- `src/Domain/Configuration/Projection.hs` — `BankingConfiguration` field on `Configuration`, three new event applications.
- `src/Domain/Configuration/Errors.hs` — messages for the new invariants (reuse `ConfigurationError Text`).
- `src/Application/Services/ConfigurationService.hs` — import from `Domain.Configuration.Defaults`; seed the three new events; remove duplicate constants.
- `src/Application/Services/BankImportService.hs` — drop `defaultCategory` parameter; inline configuration lookup and MCC resolution; tighten `TransactionClassification` usage.
- `src/Application/ReadModels/Configuration.hs` — `ConfigurationData` gains `banking :: BankingConfiguration`.
- `src/Infrastructure/Banking/Provider.hs` — `TransactionClassification` collapses to `ClassifiedIncome | ClassifiedExpense`; `BankTransaction.mcc` changes from `Maybe Int32` to `Maybe MCC` (`= Maybe Text`).
- `src/Infrastructure/Banking/Monobank.hs` — `monoClassifyTransaction` stops consulting MCC for category lookup; MCC table moves out entirely; `toProviderTransaction` formats Mono's numeric `stmtMcc` as text (`Nothing` when the field is `0`, same zero-guard as today).
- `src/Web/API/BankingAPI.hs` — drop `defaultCategory` from `ResyncRequest`; update handler plumbing.
- `src/Web/API/ConfigurationAPI.hs` — new `PUT /api/configuration/banking` endpoint; read endpoint returns the new field.
- `test/Testkit/InMemoryEventStore.hs` — fixture `Configuration` records gain `banking`.

## Open Questions

- **Income MCC mapping.** Phase 2 seeds no income-side MCC entries. If user demand shows that specific MCCs reliably map to, say, "Refund" (e.g., 6012 on Monobank reversals), we extend `defaultMccExpenseCategoryMap` in a follow-up code change. Because there is no backfill, the updated map takes effect only for configurations seeded after the change — existing user configurations update their MCC map via `PUT /api/users/me/configuration/banking`.
- **MCC map size.** The initial table targets 30–50 of the highest-volume MCC codes. Monobank publishes ~250 MCCs in its reference; extending coverage is low-risk code work.
- **Null-to-clear on defaults.** Phase 2 intentionally does not support clearing `banking.defaultIncomeCategory` / `banking.defaultExpenseCategory` once set. If a user deletes the current default entry they hit the existing `RemoveDictionaryEntry` rejection and must pick a new default first. This is symmetric with the existing "refuse to remove the last entry in a dictionary" rule.
