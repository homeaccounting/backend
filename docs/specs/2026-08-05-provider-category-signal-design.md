---
status: draft
date: 2026-08-05
---

# Provider category: a single MCC-or-label map, seeded from defaults

## Problem

Bank providers describe a transaction's category in two fundamentally different
ways, and our import pipeline only understands one of them.

- Some providers report an **industry-standard numeric MCC** (ISO 18245). We map
  it to a user category through the per-user, editable `mccExpenseCategoryMap`
  (`resolveCategory`, `src/Application/Services/BankImportService.hs:558`).
- Other providers report **no MCC at all**, only their own **category token** — a
  localized free-text string (PrivatBank's `Категорія`, e.g. `Дім та ремонт`) or
  a fixed English enum (Monzo's `category`: `eating_out`, `groceries`, …).

Today `BankTransaction` carries `mcc :: Maybe MCC` **and** a dead
`categoryHint :: Maybe Text` (`src/Infrastructure/Banking/Provider.hs:69,76`).
PrivatBank populates `categoryHint` with its label, but **nothing reads it** —
`resolveCategory` only consults `mcc`. So every PrivatBank expense falls through
to the direction-default category even though the bank told us the category.

A first attempt (the current unmerged PR on this branch) smuggled the label into
`mcc` as a "non-numeric MCC key" and seeded Ukrainian strings into
`Domain.Configuration.Defaults`. That is wrong twice over — it overloads a
numeric-standard field with free text, and puts provider-specific,
native-language data in the domain. This spec replaces that approach.

**The foundation must be consistent and unified.** The import model has exactly
one notion — "the category the provider reported" — modelled as a single sum
type, **persisted verbatim** for every provider, and resolved through **one map**
keyed by that type (seeded from defaults, user-editable).

## Provider survey (validates the two-case model)

| Provider | Category signal | Field | Case |
|----------|-----------------|-------|------|
| Monobank | numeric MCC | (pull payload) | MCC |
| Revolut | numeric MCC | `merchant.category_code` (Business); `MerchantCategoryCode` (Open Banking) | MCC |
| Wise | numeric MCC **+** an MCC-*derived* English label | `merchant.category.code` (+ `.name`) | MCC (label is a 1:1 rendering of the code — redundant, dropped) |
| Monzo | independent enum, **no MCC** | `category` (`eating_out`, `groceries`, …) | Label |
| PrivatBank | localized free-text, **no MCC** | CSV `Категорія` | Label |

Findings that shape the design:

- The two cases are **mutually exclusive for the providers that need the label
  case** (Monzo, PrivatBank have no MCC), so there is no "both" to model. Wise's
  label is derivable from its MCC, so we keep the MCC and drop the label.
- Label-based providers are first-class (2 of 5 here; the file-import roadmap
  skews further that way).

## Design principle

**One type, one map.**

- The provider signal is a single sum type — an MCC or a provider label — and it
  is **persisted verbatim** on `ImportInfo` for every provider (no fabrication,
  no dropped data).
- Resolution is a **single lookup** in one per-user, editable
  `Map ProviderCategory CategoryId`, **seeded from banking defaults** (the
  universal MCC defaults plus each provider's label defaults). Keying by the sum
  type gives a collision-free keyspace (`ByMcc "5411"` ≠ `ByLabel "5411"`).
- All category **default** data lives in the banking layer
  (`Infrastructure.Banking.*`); the domain keeps only the user's category
  structure.

## Design

### 1. The `ProviderCategory` sum type (domain)

Because it is persisted on the domain `ImportInfo`, the type lives in
`src/Domain/Core/Types.hs` (beside `MCC` and `ImportInfo`):

```haskell
-- | How the provider reported a transaction's category: an industry-standard
-- numeric MCC, or the provider's own category token (a localized label or a
-- fixed enum). Persisted verbatim; used as the key of the user category map.
data ProviderCategory
  = ByMcc MCC        -- Monobank, Revolut, Wise
  | ByLabel Text     -- PrivatBank (localized), Monzo (enum)
```

**`MCC` becomes numeric.** With labels now carried by `ByLabel`, the old
`type MCC = Text` (`Domain/Core/Types.hs:664`, kept as `Text` precisely to leave
"room for non-numeric category keys") loses its reason to exist. `MCC` becomes a
validated domain **newtype over `Int`** — `newtype MCC = MCC Int`, ISO 18245
range `0..9999`, smart constructor `mkMcc` + LiquidHaskell refinement, and an
`unsafeMcc` for known-good literals (defaults, tests). It renders as a **4-digit
zero-padded string** in every text form (map key `mcc:0742`, DTO value `"0742"`),
preserving leading-zero codes (e.g. veterinary `0742`). External bank payloads
that carry an MCC parse their numeric string/int through `mkMcc` (custom
`FromJSON` at the source boundary, per the external-vs-stored rule).

Per project conventions: no exported constructors/selectors — smart constructors
(`mkByMcc`, `mkByLabel` rejecting empty), a fold/accessors, LiquidHaskell
refinements, and `Ord` (map key). `ProviderCategory` needs **two JSON encodings**:
a tagged *value* form for `ImportInfo` (`{ "kind": "mcc"|"label", "value": … }`)
and a `ToJSONKey`/`FromJSONKey` *key* form (e.g. `"mcc:0742"` /
`"label:eating_out"`) for serializing the map. No native-language literals live in
the type; concrete labels are transaction data / provider defaults only.

`BankTransaction`'s `mcc :: Maybe MCC` and `categoryHint :: Maybe Text` are
**replaced by** `category :: Maybe ProviderCategory` (Infrastructure uses the
domain type), retiring `categoryHint` and making "code XOR label" a type
guarantee.

### 2. The unified, user-editable category map

The per-user config map generalizes:

```haskell
-- Configuration projection / command / event / read-model table
mccExpenseCategoryMap :: Map MCC CategoryId
-- becomes
providerCategoryMap   :: Map ProviderCategory CategoryId
```

- Command/event `SetBankingMccExpenseCategoryMap` → `SetProviderCategoryMap`;
  read-model table `configuration_mcc_categories` → `configuration_provider_categories`.
- Seeded at config creation from
  `Infrastructure.Banking.CategoryDefaults.defaultProviderCategoryMap`
  (`ConfigurationService`).
- It is **user-editable exactly as the MCC map is today** — so labels gain full
  parity with MCCs from day one (a user can re-point `ByLabel "Дім та ремонт"`
  just like an MCC). The client editor gains label keys as a follow-up (#52); the
  backend is editable now.

### 3. Banking category defaults (seed)

New `Infrastructure.Banking.CategoryDefaults`:

```haskell
defaultProviderCategoryMap :: Map ProviderCategory CategoryId
defaultProviderCategoryMap =
  Map.mapKeys ByMcc defaultMccExpenseCategoryMap        -- universal MCC defaults
    <> Map.mapKeys ByLabel PrivatBank.labelCategories   -- static per-provider label defaults
    -- <> Map.mapKeys ByLabel Monzo.labelCategories     -- (future providers, #53)
```

- `defaultCategoryMccs` + `defaultMccExpenseCategoryMap` **move here from
  `Domain.Configuration.Defaults`** (values still reference default `CategoryId`s
  in `Domain.Configuration.Defaults`; Infrastructure→Domain permitted).
- **Label defaults come from a *pure, static* per-provider binding**, e.g.
  `Infrastructure.Banking.PrivatBank.labelCategories :: Map Text CategoryId` —
  **not** the runtime provider registry (`buildRegistry`/`candidates` are effectful,
  taking config + `Manager`, so they can't seed a pure top-level map).
  `CategoryDefaults` imports each label-provider's static binding directly and
  unions them. The provider's descriptor sets `TransactionInterpretation.labelCategories`
  from the *same* static binding (single source of truth). Acyclic: CategoryDefaults →
  provider modules → `Domain.Configuration.Defaults`.

### 4. Resolution (a single lookup — no threading)

`resolveCategory` (`BankImportService.hs:558`) takes `Maybe ProviderCategory` and
does **one lookup** in the banking config's `providerCategoryMap` (already on the
`BankingConfiguration` it receives):

1. Expense: `Map.lookup pc banking.providerCategoryMap`, verify the hit is in the
   user's expense dictionary.
2. Otherwise (income, `Nothing`, unmapped key, or not-in-dict) → direction
   default.

Because the label defaults are baked into the user map at seed time, resolution
**does not need the provider's label map** — so the current spec's
seven-function threading of `labelCategories` from `importMany` down to
`commitMatchingCurrencyImport` **is eliminated**. `resolveCategory` reads only the
banking config it already has.

`CategoryResolution` simplifies to `MapHit !ProviderCategory` /
`DefaultFallback !(Maybe ProviderCategory)`; `logCategoryResolution`
(`BankImportService.hs:688`) renders the new shapes.

### 5. Persistence (event-shape change, faithful)

`ImportInfo` (`Domain/Core/Types.hs:1400`):

```haskell
data ImportInfo = ImportInfo
  { externalTransactionIds :: NonEmpty ExternalTransactionId,
    category :: Maybe ProviderCategory   -- was: mcc :: Maybe MCC
  }
```

`BankTransaction.category` is stored **verbatim** (`ByMcc`/`ByLabel` alike). Two
persistence paths change from `mcc` to the full `category`:

- The `ImportInfo` construction in `commitMatchingCurrencyImport`
  (`BankImportService.hs:1009`).
- The reconcile path: `attemptReconcile` (`BankImportService.hs:855`) forwards the
  signal onto the `TransactionImportReconciled` event (read at
  `ReadModels/Transaction.hs:353`); its `mcc` field becomes
  `category :: Maybe ProviderCategory`.

### 6. Provider conversions

- **Monobank** (`Monobank/Internal.hs`): emit `category = Just (ByMcc <mcc>)`;
  drop `categoryHint`; `labelCategories = Map.empty`.
- **PrivatBank** (`PrivatBank/Internal.hs`): emit
  `category = if T.null rawCategory then Nothing else Just (ByLabel rawCategory)`;
  drop `categoryHint`; supply `labelCategories` (§7).

`TransactionInterpretation` gains `labelCategories :: Map Text CategoryId` (empty
for MCC-only providers), consumed by §3's seed — **not** at resolution.

### 7. PrivatBank label→category defaults (in the PrivatBank module)

Derived from 12 months of real exports. Only expense-meaningful labels; income
labels, own-card transfers (transfer matcher), and ambiguous labels are omitted
so they fall through to the direction default.

| Label (UA) | → default category |
|-----------|--------------------|
| Дім та ремонт, Побутова техніка | household |
| Комуналка та Інтернет, Поповнення мобільного | utilities |
| Супермаркети та продукти | groceries |
| Ресторани, кафе, бари | dining |
| Розваги, Кіно | entertainment |
| Авто | transport |
| Медичні послуги | health |
| Краса | beauty |
| Одяг та взуття | clothing |
| Цифрові товари | electronics |
| Інтернет-магазини | shopping |
| Квіти | gifts |
| Освіта | education |
| Страхування | insurance |
| Платежі до бюджету | taxesFees |
| Інше | other |

Omitted: `Перекази`, `Платежі за реквізитами`, `Послуги`, `Зняття готівки`,
`Кредити`, `Переказ на свою картку`, and income labels `Зарахування`,
`Зарахування переказу`, `Зарахування зі своєї картки`.

### 8. DTO / API surface

The read model `TransactionData.mcc :: Maybe MCC` becomes
`category :: Maybe ProviderCategory`; the API DTO (`Web/Types.hs:683`, today a
flat `mcc :: Maybe Text`) surfaces it as a tagged object:

```json
"providerCategory": { "kind": "mcc",   "value": "5411" }
"providerCategory": { "kind": "label", "value": "eating_out" }
"providerCategory": null
```

The config endpoints that read/write the category map switch from MCC keys to the
tagged `ProviderCategory` key form. Both are breaking DTO changes requiring a
matching web-client update (`../monorepo`).

## Backward compatibility & migration

This alters stored-event shape (`ImportInfo.category`,
`TransactionImportReconciled.category`, `SetProviderCategoryMap`), the
Configuration read-model table, and the DTO — **not** backward compatible. Per the
decision that we are still **alpha (beta-testers only)**, we take a **documented
one-time exception** and **recreate the database** rather than ship upcasters:

- Update `CLAUDE.md`'s "Backward compatibility" section to record the one-time
  exception (the standing rule otherwise stands — post-launch changes still need
  upcast-on-read). See the memory note on alpha status.
- The recreated DB holds only current-shape events, so the app's **historical
  upcasters and their legacy fixtures become dead code and are removed** (the
  generic eventium machinery stays). Exact set enumerated in the plan.
- Operational: beta-tester data is discarded on recreate; note in the deployment
  runbook.

## What is NOT built (and the additive door)

- **Client editor for label keys → #52.** The backend map is editable for
  `ByLabel` keys immediately; the web category-map editor must be extended to
  add/edit label keys (surfacing known provider labels for discoverability).
  Until then, labels use their seeded defaults.
- **Seeding & new providers.** The user map is seeded once, at config creation,
  with all then-registered providers' label defaults. A provider added
  *post-launch* is absent from existing users' maps → its label transactions fall
  to the direction default until a re-seed/backfill (a post-launch concern; noted,
  not built).
- **Monzo / Revolut / Wise providers → #53.** Surveyed only to validate the seam
  (`ByMcc` for Revolut/Wise; `ByLabel` + `labelCategories` for Monzo).

## Testing

- **Schema/round-trip** (`Infrastructure.Eventium.SchemaSpec`): stored-JSON
  fixtures for the new `ImportInfo`/`TransactionImportReconciled`/
  `SetProviderCategoryMap` shapes decode, re-encode, round-trip for both `ByMcc`
  and `ByLabel`; `ProviderCategory` value **and** key JSON round-trip.
- **Provider unit tests.** PrivatBank: mapped `ByLabel` row resolves to the
  expected category; blank/unmapped → default; persisted `category` is
  `Just (ByLabel …)`. Monobank: `Just (ByMcc <code>)`.
- **Seed** (`ConfigurationService`/`CategoryDefaults`):
  `defaultProviderCategoryMap` contains the numeric MCC defaults (as `ByMcc`) and
  each provider's labels (as `ByLabel`); a fresh user's `providerCategoryMap` is
  seeded from it.
- **Resolution** (`BankImportServiceSpec`): a `ByMcc` and a `ByLabel` key both
  resolve via the one map; unmapped keys and income fall back; not-in-dict falls
  back.
- **Domain** (`DefaultsSpec`): `Domain.Configuration.Defaults` no longer holds an
  MCC table; `ProviderCategory` smart-constructor/round-trip properties.
- **DTO**: tagged `providerCategory` encodes both cases and `null`.
- TDD: red before green.

**Fixture churn (highest-effort item).** Merging `mcc` + `categoryHint` into
`category`, and the map key-type change, break every `BankTransaction` literal and
every `.mcc`/`.categoryHint`/`mccExpenseCategoryMap` reference:
`Testkit/BankingHelpers.hs:57` (shared), `Integration/BankImportWorkflowSpec.hs`,
`BankImportServiceSpec.hs`, `PrivatBankSpec.hs`, `MonobankSpec.hs`,
`ConfigurationServiceSpec`, and the read-model tests.

## Layering check

- `ProviderCategory` is a **domain** type (`Domain.Core.Types`), no native-language
  literals. The category-default maps live in `Infrastructure.Banking.*`
  (`CategoryDefaults` for MCC defaults + aggregation; per-provider
  `labelCategories`).
- `Infrastructure.Banking.CategoryDefaults` references `Domain.Configuration.Defaults`
  category ids and the provider registry (Infra→Domain / Infra→Infra). New import
  edge, layer-legal.
- `Application.ConfigurationService` seeds the user map from
  `Infrastructure.Banking.CategoryDefaults` (Application→Infrastructure).
- `resolveCategory` reads only the `BankingConfiguration` it already receives —
  no provider dependency, no threading.
