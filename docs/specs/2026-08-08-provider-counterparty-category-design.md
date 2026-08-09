---
status: completed
date: 2026-08-08
---

# Provider category by counterparty, and categorizing income

Tracker: `homeaccounting/tracker#55`. Extends the category-signal foundation
(`2026-08-05-provider-category-signal-design.md`, #51) and reuses the counterparty
token introduced by the contact-signal foundation
(`2026-08-06-provider-contact-signal-design.md`, #54). Unblocks the PrivatBank
business import (#46, `2026-08-07-privatbank-business-file-import-design.md`).

## Problem

#51 gave us one clean notion — "the category the provider reported" —
`BankProviderCategory = ByMcc MCC | ByLabel Text`, persisted verbatim on
`ImportInfo`, resolved through one seeded, user-editable map
(`bankProviderExpenseCategoryMap`). It categorizes **expenses that carry a
merchant signal**. Two whole classes of transaction carry no such signal and so
receive no real categorization:

1. **Income — on every provider.** Incoming transfers never carry an MCC or a
   merchant label. And `resolveCategory`
   (`src/Application/Services/BankImportService.hs:627`) is **expense-only** — the
   `ClassifiedIncome` branch is hard-wired to `Nothing`
   (`BankImportService.hs:642-644`). So income is never categorized, no matter what
   the provider tells us. Every income row lands on the income direction-default.

2. **MCC-less expenses.** PrivatBank *business* (XLSX) rows are inter-account and
   wire transfers, not card-merchant charges. Its parser sets `category = Nothing`
   unconditionally (`src/Infrastructure/Banking/PrivatBankBusiness/Internal.hs:72-85`);
   the export has neither an MCC nor a category-label column. Every business
   expense falls to the expense direction-default.

Yet these transactions **do** carry a strong, deterministic category signal that
is *already captured on the transaction*: the counterparty's stable identifier —
a legal-entity code (PrivatBank business's `ЄДРПОУ`/EDRPOU) or an IBAN. This is the
very token #54 persists as `BankProviderContact` and resolves against the contact
map. The same token can drive **category** resolution, for income and expense
alike.

## Provider survey (which signal each provider has)

| Provider | Expense signal | Income signal | Notes |
|----------|----------------|---------------|-------|
| Monobank | MCC (`ByMcc`) | none → counterparty | income transfers carry no MCC |
| PrivatBank retail | label (`ByLabel`) | label, where present | card export has `Категорія` |
| PrivatBank business | none → counterparty | none → counterparty | XLSX bank transfers; `ЄДРПОУ` present |

Findings that shape the design:

- **A transaction only ever needs one category signal.** Income never has an MCC
  anywhere, and an MCC-bearing expense keeps using its MCC. So the provider can
  pick the single best signal it has; there is no "MCC *and* counterparty on the
  same row" case to resolve between. (This is a deliberate scope decision — see
  Extensibility for why resolution is still built ladder-shaped.)
- The counterparty token is **universal, not provider-scoped** (identical to #54):
  an EDRPOU/IBAN means the same thing regardless of which provider surfaced it, so
  its keyspace is shared and many-to-one.

## Design principle

**One more signal variant, a per-kind income map alongside the existing expense
map, no new resolution path.**

- `BankProviderCategory` gains a third case, `ByCounterparty Text`, keyed on the
  universal counterparty token. It stays a single value persisted verbatim on
  `ImportInfo`; resolution stays a single map lookup.
- Direction is split at the **command/event level, per kind** — mirroring the
  system's existing `SetDefaultIncomeCategory` / `SetDefaultExpenseCategory` pair.
  The existing expense map/command/event/table are left **untouched**; an income
  sibling is **added**. Resolution picks the map by the transaction's direction.
- Each provider emits the **single best signal it has** for a given transaction.
- Counterparty→category entries are **match-only and not seeded** (a specific
  EDRPOU/IBAN is user-specific, unlike a universal ISO MCC) — exactly like #54's
  contact map. No auto-creation of categories (dictionaries stay user-curated).

### Reflecting the domain: per-kind events, direction-opaque `CategoryId`

Two established conventions decide the shape, and both point the same way:

- **Per-kind events.** Directional configuration in this system is expressed as
  **separate per-kind commands/events**, not one command carrying both directions:
  `SetDefaultIncomeCategory` (`CommandHandler.hs:415`) and
  `SetDefaultExpenseCategory` (`:423`) are distinct, each validating against its own
  dictionary. The category map follows suit — keep the expense event, add an income
  event.
- **Direction-opaque `CategoryId`, validated by membership.** A `CategoryId` is a
  bare UUID newtype (`Types.hs:1246`) with **no direction tag**; the transaction
  domain establishes direction structurally (the `incomes`/`expenses` buckets of
  `Allocations`, `Types.hs:1288`) and validates category direction only by
  **dictionary membership** — `requireEntryIn expenseCategoryDictKind` /
  `incomeCategoryDictKind` (`CommandHandler.hs:239,446`). The import maps do the
  same: each per-kind map validates its values against its dictionary; **no
  synthetic `CategoryDirection` tag is introduced** (an earlier draft used a
  `(CategoryDirection, signal)` tuple key — dropped).

Two properties fall out, which are the reasons a single signal-only map fails:

1. **The editor scopes its category dropdown per kind** — the income editor offers
   only income categories, the expense editor only expense. A wrong-direction pick
   is *unrepresentable*, not silently dropped at import.
2. **A counterparty can transact in both directions** — the same EDRPOU/IBAN gets
   an entry in each map with a different category.

Direction lives on the **config maps** (which map an entry is in). The persisted
signal (`ImportInfo.category`) stays a plain `BankProviderCategory` — a transaction
has no direction of its own to store; its direction comes from `classify` at lookup
time.

## Design

### 1. `ByCounterparty` on `BankProviderCategory` (domain)

`src/Domain/Core/Types.hs:753`:

```haskell
data BankProviderCategory
  = ByMcc MCC
  | ByLabel Text
  | ByCounterparty Text   -- universal counterparty token (EDRPOU / IBAN / stable descriptor)
```

Per #51's established pattern and project conventions (no exported constructors):
add a smart constructor `mkByCounterparty :: Text -> Maybe BankProviderCategory`
(trim, reject blank — same as `mkByLabel`), extend the fold, `Ord`, and
LiquidHaskell. Two JSON encodings extend to the new case:

- **Value form** (on `ImportInfo`): `{ "kind": "counterparty", "value": "<token>" }`.
- **Key form** (`ToJSONKey`/`FromJSONKey`, for the maps): `counterparty:<token>`,
  reusing the existing split-on-first-colon rule so tokens containing colons
  round-trip. **No direction prefix** — the map an entry lives in carries direction (§2).

Adding a constructor to the `BankProviderCategory` tagged sum is a
**backward-compatible superset extension**: every previously-stored payload
(`kind: mcc | label`) remains a valid current-shape payload, so no upcaster and no
recreate are needed (see Migration).

The token is the *same* value #54 computes for `BankProviderContact`
(`renderBankProviderContactKey` semantics — verbatim, trimmed). Providers compute
it once and route it into both signals where appropriate (see §5).

### 2. A per-kind income map alongside the untouched expense map

Today the expense map, its command, event, and read-model table exist and
resolution short-circuits income. **Keep the expense side byte-for-byte** and
**add an income sibling**, mirroring the `SetDefault{Income,Expense}Category`
pair — purely additive:

```haskell
-- Domain/Configuration/Projection.hs:98 — bankProviderExpenseCategoryMap UNCHANGED
bankProviderExpenseCategoryMap :: Map BankProviderCategory CategoryId   -- existing
bankProviderIncomeCategoryMap  :: Map BankProviderCategory CategoryId   -- NEW, starts Map.empty
```

- Values are bare, direction-opaque `CategoryId`s; *which map* an entry lives in is
  the sole carrier of direction. No `CategoryDirection` type. The signal key form is
  unchanged (`mcc:0742` / `label:eating_out` / `counterparty:12345678`).
- **Unchanged (expense):** command `SetBankProviderExpenseCategoryMap`
  (`Commands.hs:219`), event `BankProviderExpenseCategoryMapSet` (`Events.hs:208`),
  read-model table `configuration_bank_provider_expense_categories`, and their
  `requireEntryIn expenseCategoryDictKind` validation (`CommandHandler.hs:446`).
- **Added (income), a sibling of each:** command `SetBankProviderIncomeCategoryMap`,
  event `BankProviderIncomeCategoryMapSet`, projection field
  `bankProviderIncomeCategoryMap`, read-model table
  `configuration_bank_provider_income_categories`, and validation
  `requireEntryIn incomeCategoryDictKind` (the same `requireEntryIn`,
  `CommandHandler.hs:239`, against the income dictionary — exactly as
  `SetDefaultIncomeCategory` does).
- **Seeding** (`ConfigurationService.hs:890`): the expense seeding
  (`defaultBankProviderExpenseCategoryMap`,
  `Infrastructure/Banking/CategoryDefaults.hs:249` — universal MCC defaults ∪
  per-provider label defaults) is **unchanged**. The income map seeds **empty**
  (no universal income signal to seed; `ByCounterparty` is user-specific). No new
  default binding.

### 3. Resolution — ladder-shaped, per-kind map selected by direction

`resolveCategory` (`BankImportService.hs:627`) is rewritten as an **ordered ladder
of resolver steps** returning the first hit, rather than a single inline lookup.
Today there is exactly one map rung; structuring it as a ladder now is the
extensibility hedge (see Extensibility — a future description matcher becomes an
appended rung, not a rewrite).

Rungs, in order:

1. **Category-map hit.** Select the map from `classify tx`
   (`ClassifiedIncome → bankProviderIncomeCategoryMap`,
   `ClassifiedExpense → bankProviderExpenseCategoryMap`), then
   `Map.lookup tx.category thatMap`. Because the map is chosen by direction, the
   lookup is direction-correct with no routing guard; the expense-only short-circuit
   (`ClassifiedIncome → Nothing`) is simply deleted. A **staleness check** is
   retained (the mapped `CategoryId` must still exist in its dictionary),
   generalizing #51's existing "verify the hit is still in the expense dict" check
   to the selected map's dictionary.
2. **Direction default** (unchanged final rung): the appropriate
   income/expense default category, or `BankingError` if none is configured.

`CategoryResolution` (`BankImportService.hs:598`) keeps its
`MapHit !BankProviderCategory` / `DefaultFallback !(Maybe BankProviderCategory)`
shape; `logCategoryResolution` is unchanged in shape (it already renders any
`BankProviderCategory`). The `ByMcc`/`ByLabel`/`ByCounterparty` distinction is
invisible to the resolver — it is just a map key — which is exactly why adding
`ByCounterparty` needs no new resolution path.

### 4. Persistence (additive, backward-compatible)

`ImportInfo.category :: Maybe BankProviderCategory` (`Domain/Core/Types.hs:1621`)
is unchanged in shape — it already holds a `BankProviderCategory` — and now admits
`ByCounterparty` values, as does the `TransactionImportReconciled.category`
reconcile path. No field is added or removed; a previously-unused variant may now
appear in newly-written payloads. Old payloads (`mcc`/`label`) remain valid, so
this needs no upcaster (see Migration). The only genuinely new stored event is the
additive `BankProviderIncomeCategoryMapSet` (§2); the expense event is untouched.

### 5. Provider conversions — each emits its single best signal

The selection rule per transaction: **merchant signal if present, else the
counterparty token, else `Nothing`.**

- **Monobank** (`Monobank/Internal.hs:118`): expense keeps
  `category = Just (ByMcc <mcc>)` when `stmtMcc /= 0`; **income** (and any row
  without an MCC) sets `category = ByCounterparty <token>` when a stable
  counterparty token is available, else `Nothing`. (Confirm during implementation
  that the Monobank payload yields a stable counterparty identifier for the
  `contact` signal; category reuses whatever token that computes.)
- **PrivatBank business** (`PrivatBankBusiness/Internal.hs:72`): both directions set
  `category = ByCounterparty <EDRPOU>`, reusing the exact token already computed for
  the `contact` signal (`col "ЄДРПОУ"`). Falls back to `Nothing` when the EDRPOU
  column is blank.
- **PrivatBank retail** (`PrivatBank/Internal.hs:128`): unchanged (`ByLabel`).

No change to `TransactionInterpretation` or the classify/direction seam — the
direction still comes from `classify`; only which `BankProviderCategory` the
provider stamps changes.

### 6. DTO / API surface

Two DTO surfaces change, both breaking, requiring a matching web-client update
(`../monorepo`):

**Transaction signal** — the tagged `providerCategory` DTO gains the third kind
(no direction here; the transaction's own kind carries direction):

```json
"providerCategory": { "kind": "counterparty", "value": "12345678" }
```

**Config category maps** — keep the existing `expenseCategoryMap` DTO field and
**add** an `incomeCategoryMap` field, each a `{ "<signal-key>": categoryId }` map
with the **unchanged** signal key form (`mcc:0742` / `counterparty:12345678` — no
direction prefix). Additive: existing clients keep working against
`expenseCategoryMap`.

Web client (`src/features/profile/`):

- Keep the expense editor (`BankProviderExpenseCategoryMapEditor.tsx`) and **add a
  second instance** for income — reusing the same component, one bound to
  `expenseCategoryMap` + `expenseCategories`, one to `incomeCategoryMap` +
  `incomeCategories` (the pane currently loads only
  `expenseCategories = flattenDictionary(c.dictionaries['expense'])`
  — `ProfileBankingPane.tsx:152`; add the income dictionary).
- Each editor's category dropdown offers **only its kind's** categories, so a
  wrong-direction mapping is unrepresentable. The income editor's Kind dropdown
  offers only `Counterparty` (income has no MCC/label); the expense editor keeps
  `MCC | Label | Counterparty`.
- `parseBankProviderCategoryKey`/`renderBankProviderCategoryKey`
  (`bankConnectionSchema.ts`) are **unchanged** — each editor edits its own map with
  the existing signal keys; no direction prefix to parse.

## Extensibility

Two distinct axes; the design stays clean on both **provided resolution is
ladder-shaped from day one** (§3).

- **More exact-key signals** (a bank's own transaction-type code, a dedicated IBAN
  keyspace distinct from EDRPOU, …): trivial — add a `BankProviderCategory`
  constructor + its JSON/key form, have the provider emit it. Still a map lookup;
  the resolver is unchanged because it treats every variant as an opaque key.
- **Fuzzy / derived signals — notably "guess category by description":** a
  *different shape*. A description is free text, matched by keyword/substring/
  pattern, never by exact key (a raw description would never hit a map twice). So
  it is **not** another `BankProviderCategory` variant. It is a new **resolver rung**
  that reads the already-persisted `tx.description` at resolution time — the exact
  analog of #54's contact name-match fallback. Adding it later touches **nothing
  stored**: `BankProviderCategory` stays the exact-key type, no migration; it lands
  as an appended rung in the §3 ladder plus an additive config (a keyword/pattern →
  category rule set). Deferred to a follow-up issue.

## Backward compatibility & migration

**This ships fully additive — no upcaster and no DB recreate.** The per-kind
approach (§2) avoids every breaking change:

- `BankProviderCategory` gains `ByCounterparty` — a **superset extension** of a
  tagged sum. Every previously-stored `ImportInfo` /
  `TransactionImportReconciled` payload (`kind: mcc | label`) is still a valid
  current-shape payload; there is nothing to transform, so no upcaster is needed
  and `accountingSchemaRegistry` stays empty. A **legacy-shape decode test**
  (`Infrastructure.Eventium.SchemaSpec`, the CLAUDE.md guardrail) proves an old
  `mcc`/`label` fixture still decodes and round-trips.
- The income side is entirely **new**: `BankProviderIncomeCategoryMapSet` event,
  `bankProviderIncomeCategoryMap` projection field,
  `configuration_bank_provider_income_categories` read-model table (new-table DDL),
  and an `incomeCategoryMap` DTO field. Adding an event type / projection field /
  read-model table / DTO field is additive by construction.
- The expense event, command, table, seeding, and DTO field are **unchanged**.

So unlike #51/#54, this change does **not** consume the alpha DB-recreate escape
hatch. (If a recreate happens anyway for an unrelated reason, this feature is
unaffected.)

## What is NOT built

- **Fuzzy description → category matching** — the additive resolver rung described
  in Extensibility. Separate follow-up issue.
- **Contact-derived category inheritance** (mapping a resolved contact to a default
  category) — considered and rejected; it couples the contact and category
  dictionaries and can't categorize a counterparty the user doesn't want as a
  contact.
- **Re-seed/backfill** of existing users when a provider is added post-launch —
  same post-launch concern noted by #51; not built.

## Testing (TDD — red before green)

- **Legacy-shape decode** (`Infrastructure.Eventium.SchemaSpec`, backcompat
  guardrail): a committed old `ImportInfo` / `TransactionImportReconciled` fixture
  with `kind: mcc` / `kind: label` still decodes, upcast-free, and round-trips —
  proving the `ByCounterparty` addition is a compatible superset.
- **Schema/round-trip**: `ByCounterparty` value JSON round-trips; the new
  `BankProviderIncomeCategoryMapSet` event round-trips (populated and empty).
- **Domain** (`BankProviderCategory` props): `mkByCounterparty` trims/rejects
  blank; `Ord`/fold cover the new case; the signal key form (`counterparty:…`)
  renders/parses.
- **Resolution** (`BankImportServiceSpec`): an **income** row with an entry in
  `bankProviderIncomeCategoryMap` resolves to that income category; an **expense**
  counterparty hit resolves via `bankProviderExpenseCategoryMap`; the same
  counterparty token present in **both** maps resolves independently per direction;
  unmapped/`Nothing` falls through; a stale entry (mapped category removed) falls
  through; the ladder returns the first hit.
- **Command-handler validation** (per kind): `SetBankProviderIncomeCategoryMap`
  targeting an income category is accepted; targeting an expense category (wrong
  dictionary) is rejected; the existing expense command's behaviour is unchanged.
- **Providers**: PrivatBank business emits `Just (ByCounterparty <EDRPOU>)` and
  `Nothing` on a blank EDRPOU; Monobank income emits `ByCounterparty`, Monobank
  expense still `ByMcc`.
- **DTO**: tagged `providerCategory` encodes the `counterparty` kind; the config
  endpoint round-trips both `expenseCategoryMap` and the new `incomeCategoryMap`
  (counterparty keys, income-category values).

## Layering check

- `ByCounterparty` is a **domain** type addition (`Domain.Core.Types`), no
  provider- or native-language-specific data. Counterparty tokens are transaction
  data, computed in `Infrastructure.Banking.*`.
- No new seed data in `Infrastructure.Banking.CategoryDefaults` (counterparty keys
  and the income map are unseeded); expense seeding is unchanged.
- `resolveCategory` still reads only the `BankingConfiguration` it already receives
  — the ladder adds no new dependency or threading.
