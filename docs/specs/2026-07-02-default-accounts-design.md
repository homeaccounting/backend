---
status: completed
date: 2026-07-02
issue: homeaccounting/tracker#26
---

# Default accounts & `configuration.defaults` sub-structure

## Problem

The natural-language transaction resolver (`POST /api/prompt`, backend #86)
matches accounts **by name only**. `cash 123 food` works only if an account is
literally named "Cash", and a user with several cash-like accounts gets an
ambiguous match → 400. People refer to accounts by **type** ("cash", "card",
"from the bank") or omit the account entirely ("spent 50 on food"). Neither
resolves today.

The Configuration aggregate already carries per-user global defaults
(`defaultIncomeCategory` / `defaultExpenseCategory`), but they sit as two flat
fields on `Configuration` and are surfaced flat on the API. This design does two
things:

1. **Introduces default accounts** — a global default account plus a default
   account per account subtype — so account references align with intent and
   resolve deterministically. Useful beyond the LLM (quick-entry, importers), so
   it belongs in the Configuration domain, not as an LLM-only feature.
2. **Groups all defaults** into a single `defaults` sub-structure —
   `configuration.defaults.{incomeCategory, expenseCategory, account,
   subtypeAccounts}` — on the aggregate, the read model, and the API.

## Scope

Full #26: the Configuration domain-model foundation **and** the NL
resolver/extraction changes.

Explicitly **out of scope** (deferred to follow-ups):

- Returning candidate accounts in the 400 body on ambiguity (#26 "Related").
- Multi-allocation NL expenses (#27).

## Non-goals / constraints

- **No backward-compat phase.** DB schema, in-memory state, and DTO shapes are
  reshaped to the clean target directly — no upcasters, no coexist-and-deprecate.
  The event log is treated as append-only history, so existing events are kept
  and only *new* event types are added.
- The pure Configuration command handler stays pure and has no knowledge of the
  Account aggregate; cross-aggregate account validation lives in the service
  layer, exactly as `setBankConnectionAccountMap` already does.

## Design

### 1. Domain model

#### 1.1 `AccountSubtypeKind` (new, `Domain.Core.Types`)

`AccountSubtype` is a payload-carrying sum (`Cash CashProperties`,
`BankAccount …`, …), so it cannot key a map. Introduce a flat, payload-free
discriminator, mirroring how `StatusKind` was introduced for the query language.
Naming follows the repo's full-`Kind`-suffix convention.

```haskell
data AccountSubtypeKind
  = CashKind | BankAccountKind | EWalletKind | AssetKind | LoanKind
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance ToJSON AccountSubtypeKind
instance FromJSON AccountSubtypeKind
instance ToJSONKey AccountSubtypeKind   -- for Map-keyed JSON (API + storage)
instance FromJSONKey AccountSubtypeKind

-- Payload-free projection.
accountSubtypeKind :: AccountSubtype -> AccountSubtypeKind
```

`Ord` is required for `Map` keys; `Enum`/`Bounded` are convenient for
exhaustiveness. `ToJSONKey`/`FromJSONKey` let a `Map AccountSubtypeKind _`
serialise as a JSON object keyed by the constructor name (`"CashKind"`); this is
needed both by the API response and by the read-model column (§3). LiquidHaskell:
a nullary enum needs no non-trivial refinement.

#### 1.2 `ConfigurationDefaults` sub-record (`Domain.Configuration.Projection`)

Replace the two flat fields on `Configuration` with a single sub-record, exactly
as `BankingConfiguration` is nested under `Configuration.banking`:

```haskell
data ConfigurationDefaults = ConfigurationDefaults
  { incomeCategory  :: !(Maybe CategoryId)
  , expenseCategory :: !(Maybe CategoryId)
  , account         :: !(Maybe AccountId)                  -- global fallback
  , subtypeAccounts :: !(Map AccountSubtypeKind AccountId) -- per-subtype default
  }
  deriving (Show, Eq)

emptyConfigurationDefaults :: ConfigurationDefaults

-- Configuration gains:  defaults :: ConfigurationDefaults
-- (removes the flat defaultIncomeCategory / defaultExpenseCategory fields)
```

Field naming note: the global fallback is the singular `account`; the per-subtype
map is `subtypeAccounts` (not `accounts`) to avoid the near-collision between
`defaults.account` and `defaults.accounts` at `OverloadedRecordDot` call sites.

Access is `config.defaults.incomeCategory`, `config.defaults.subtypeAccounts`,
etc. `configurationDefault` seeds `defaults = emptyConfigurationDefaults`.

### 2. Events & commands

Events are **additive** to the log; nothing is renamed or rewritten.

- **Unchanged**: `DefaultIncomeCategorySet` / `DefaultExpenseCategorySet` and
  their `SetDefaultIncomeCategory` / `SetDefaultExpenseCategory` commands. Their
  projection handlers now write into `defaults.incomeCategory` /
  `defaults.expenseCategory`.
- **New events**:
  - `DefaultAccountSet { accountId :: AccountId }`
  - `DefaultSubtypeAccountsSet { subtypeAccounts :: Map AccountSubtypeKind AccountId }`
- **New commands**:
  - `SetDefaultAccount { accountId :: AccountId }`
  - `SetDefaultSubtypeAccounts { subtypeAccounts :: Map AccountSubtypeKind AccountId }`
    — **wholesale replace**, mirroring `SetBankingMccExpenseCategoryMap`. Clearing
    all = send an empty map; clearing one = omit that key.

Both are registered in `configurationEvents` / `configurationCommands`, get
`deriveJSON`, and get projection handlers + command-handler arms.

**Validation split:**

- *Pure command handler*: emits unconditionally for the two account commands (no
  Account-aggregate knowledge). Category defaults keep their existing
  `requireEntryIn` dictionary-membership guard.
- *Service layer* (`ConfigurationService`): `setDefaultAccount` /
  `setDefaultSubtypeAccounts` validate every target `AccountId` against
  `getAccessibleAccounts` — must be a **Regular** account owned/editable by the
  user (`Owner`/`Editor`) — before clone-on-write + dispatch, rejecting an
  invalid target with a `ValidationErr`. This is the same pattern
  `setBankConnectionAccountMap` uses.

**`RemoveDictionaryEntry`** is unaffected — default *accounts* are not dictionary
entries, so the existing `isGlobalDefault` category guard needs no change. A
default account referencing a later-closed account may dangle; accounts are never
hard-deleted (only `Closed`), and the resolver treats a missing/closed default as
"no default" and falls through the precedence ladder. No cross-aggregate guard is
added here.

### 3. Read model + database (`Application.ReadModels.Configuration`)

`ConfigurationData` gets a nested `defaults :: ConfigurationDefaults` (reusing the
domain sub-record, as it already reuses `BankingConfiguration`), replacing the two
flat fields.

Schema (reshaped directly, no migration/upcaster). Both new defaults live as
**columns on the existing `configurations` row** — no child table. The
`subtypeAccounts` map is bounded (≤5 entries), always fetched whole with the
config, never queried or joined by key, and replaced wholesale, so a single
JSON-serialised column is the right fit. This matches the established house
pattern: `Money`, `AccountType` (which itself embeds `AccountSubtype`),
`AccountRole`, `AccountStatus`, `CreatedBy`, `ExchangeRate` are all stored in one
column via `jsonToPersist` / `jsonFromPersist` with `sqlType = SqlString`. Child
tables (`configuration_mcc_categories`, the bank-account map) are reserved for
the larger, unbounded, row-like collections.

- `configurations` table gains two columns:
  - `default_account AccountId Maybe` — plain column (`AccountId` already has a
    `PersistField`).
  - `default_subtype_accounts` — holds the whole `Map AccountSubtypeKind
    AccountId`, serialised as JSON text via the same `jsonToPersist` /
    `jsonFromPersist` (`SqlString`) approach as `AccountType`, reusing the
    `AccountSubtypeKind` `ToJSONKey`/`FromJSONKey` instances. Stored as a domain
    newtype (e.g. `DefaultSubtypeAccounts`) so the `PersistField` instance lives
    in `Infrastructure.Database.Orphans` next to `AccountType` — no orphan
    instance on `Map` itself, no `jsonb` column type.
- No new child table, so `resetConfiguration` and the child-load helpers are
  unchanged.

`applyConfigurationEvent` gains two `modifyConfig` row-update arms:

- `DefaultAccountSetEvent` → `configurationEntityDefaultAccount = Just evt.accountId`.
- `DefaultSubtypeAccountsSetEvent` → `configurationEntityDefaultSubtypeAccounts =
  evt.subtypeAccounts` (whole-map replace — a plain column write, simpler than
  the MCC-map child-table case).

`getConfiguration` reads the two new columns into `defaults.account` /
`defaults.subtypeAccounts`. The `ConfigurationCreated` insert seeds
`default_account = Nothing` and `default_subtype_accounts = mempty`.

### 4. Web DTO / API (`Web.API.ConfigurationAPI`)

`ConfigurationResponse` — the two top-level default-category fields move into a
nested object (the core deliverable):

```jsonc
"defaults": {
  "incomeCategory":  "uuid | null",
  "expenseCategory": "uuid | null",
  "account":         "uuid | null",
  "subtypeAccounts": { "CashKind": "uuid", "BankAccountKind": "uuid" }
}
```

A `ConfigurationDefaultsDTO` record carries this; `toConfigurationResponse` maps
`configData.defaults` into it.

`UpdateDefaultsRequest` (the existing set-only `PUT …/configuration/defaults`)
gains:

```haskell
data UpdateDefaultsRequest = UpdateDefaultsRequest
  { incomeCategory  :: Maybe UUID
  , expenseCategory :: Maybe UUID
  , account         :: Maybe UUID
  , subtypeAccounts :: Maybe (Map AccountSubtypeKind UUID)
  }
```

(The two existing fields are renamed to match the nested shape — no
backward-compat.) Present → validate & apply the matching service call;
absent/null → no change. Account-ownership validation happens in the service.

### 5. Resolver + extraction (`Application.Services.Prompt.Transaction`)

`ResolveContext`:

- `accounts :: [(AccountId, Text, Currency, AccountSubtypeKind)]` — 4th element
  new. `getUserRegularAccounts` today returns `[(AccountId, Text, Money)]`; it is
  extended to also return the subtype kind (it already reads `accountType`, which
  carries the subtype via `Regular AccountSubtype`). The resolver derives the
  account's native `Currency` from its `Money` as it does now.
- carries the four defaults from `ConfigurationDefaults` (`incomeCategory`,
  `expenseCategory`, `account`, `subtypeAccounts`), replacing the two flat
  default fields.

`resolveAccount` becomes the #26 precedence ladder (pure), applied whenever an
account slot is referenced or omitted:

1. specific **name** match wins (current `matchByName`);
2. else a recognized **subtype keyword** in the account text → that subtype's
   `subtypeAccounts` default (if present);
3. else exactly **one** account of that subtype → use it (config only needed to
   break ties);
4. else the **global** `account` default (covers omitted account, e.g.
   "spent 50 on food");
5. else `Ambiguous` / `NoMatch` → 400 (unchanged error shape).

Keyword extraction stays in the existing `account` text field — **no LLM schema
change**. Keyword map:

| keyword(s)              | subtype kind      |
| ----------------------- | ----------------- |
| `cash`                  | `CashKind`        |
| `bank`, `bank account`, `card` | `BankAccountKind` |
| `wallet`, `e-wallet`, `ewallet` | `EWalletKind` |

`card` is an alias for `BankAccountKind` (cards are typically bank cards);
`Asset`/`Loan` get no keyword (rarely referenced conversationally) but remain
addressable by name. **Transfers still require an explicit destination** — the
step-4 global default does not auto-fill a transfer's target account.

### 6. Seeding & clone-on-write (`ConfigurationService`)

- `seedFresh`: the default *category* defaults keep being seeded as today. No
  default *accounts* are seeded (the system configuration owns no accounts).
- `cloneConfiguration` / `copyDefaults`: extend to copy the new
  `defaults.account` and `defaults.subtypeAccounts` into the clone, best-effort
  (per-field failures logged and skipped), matching the existing category-default
  copy behaviour.

## Testing

Following the repo's TDD sequence (property → unit → integration):

- **Domain**
  - `AccountSubtypeKind` ↔ `AccountSubtype` projection: `accountSubtypeKind` total
    and stable (property).
  - Projection: `DefaultAccountSet` / `DefaultSubtypeAccountsSet` fold into
    `defaults`; wholesale-replace semantics for the map.
  - Command handler: new commands emit the right events; category commands still
    enforce `requireEntryIn`.
- **Read model**: round-trip `getConfiguration` after the new events; JSON-column
  encode/decode of `subtypeAccounts` (including the empty map); wholesale-replace
  overwrites the column.
- **Resolver** (pure, accuracy-critical): a table covering each precedence rung —
  name match, subtype-keyword → default, single-of-subtype tie-break, global
  fallback, and the ambiguous/no-match 400s; transfer still needs an explicit
  destination.
- **Service / integration**: account-ownership validation rejects a
  non-owned/non-Regular target; `PUT …/configuration/defaults` partial updates;
  clone copies the new defaults; end-to-end `POST /api/prompt` resolving via a
  configured default account.
- **Web**: `ConfigurationResponse` serialises the nested `defaults` object;
  `UpdateDefaultsRequest` parses the new fields.

## Rollout / migration

No data migration. The `configurations` table gains two columns (a nullable
`default_account` and a JSON `default_subtype_accounts`), created by the existing
`runMigrationSilent` / `migrateConfiguration` path on startup. No new tables. Because there is no backward-compat phase,
the reshaped read-model tables are rebuilt from the event log via the standard
read-model rebuild if needed.

## Alternatives considered

- **Inject subtype + currency into the prompt** so the LLM disambiguates
  multiple cash accounts itself — cheaper (no domain change) but nondeterministic
  and doesn't capture "my usual cash account". Rejected.
- **Clarification round-trip** on ambiguity — best UX for one-offs but needs
  conversational state; prompting is deliberately stateless/auto-commit.
  Rejected.
- **Per-subtype set/clear command** instead of wholesale replace — more granular
  but more event/command surface and per-row read-model churn; the MCC-map
  wholesale-replace pattern is the established precedent. Rejected.
- **Keep the flat `accounts` field name** from the issue text — collides with the
  singular `account` at call sites. Renamed to `subtypeAccounts`.
