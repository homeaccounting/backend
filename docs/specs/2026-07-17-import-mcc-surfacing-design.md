---
status: completed
date: 2026-07-17
---

# Surface original MCC on imported transactions

Backend portion of tracker#37. The web portion (display, "map this MCC"
prefill, static MCC→name table) is a separate effort in the client repo and is
out of scope here.

## Problem

Bank import auto-categorises expenses via the user's `mccExpenseCategoryMap`
(MCC code → expense category). But the mapping is write-only from the user's
side: once a transaction is imported, nothing surfaces **what its original MCC
was**. The MCC is read from the provider statement, consumed once to pick a
category, and then discarded — it never reaches the command, event, aggregate,
read model, or DTO.

Concretely, MCC lives only on `BankTransaction.mcc`
(`src/Infrastructure/Banking/Provider.hs:63`) and dies at
`src/Application/Services/BankImportService.hs:573`, where `resolveCategory`
uses it and returns only a `CategoryResolution` provenance tag that is logged
and dropped. `TransactionResponse` (`src/Web/Types.hs:611`) carries no `mcc`
field.

The result is a chicken-and-egg problem: to build a useful map the user must
know which MCCs actually appear in their statements, but the app hides exactly
that. The mapping editor is unusable without guessing codes.

## Goal

Make the original MCC visible on imported transactions so the client can build
and refine `mccExpenseCategoryMap` from real data:

1. **Persist** the original MCC on imported transactions at import time.
2. **Expose** it on `TransactionResponse` as `mcc :: Maybe MCC`, populated only
   for imports; `null` for manual entries and for providers with no MCC (e.g.
   PrivatBank).
3. **Improve** the built-in `defaultMccExpenseCategoryMap` so a fresh user gets
   good auto-categorisation out of the box, adding new default expense
   categories where common MCCs have no good home today.

Deliberately **out of scope** (marked optional in the issue, deferred to keep
this simple):

- A backend MCC→name dictionary. The client ships a small static table; MCC
  codes are a stable finite set.
- Backend "which rule fired" attribution. The client already holds
  `mccExpenseCategoryMap` and the transaction's category, so it derives
  "matched vs fallback" itself.
- A dedicated import-source marker on the response. `mcc` is the only new field;
  a manual entry and a MCC-less import look alike, which is acceptable for the
  MCC-visibility goal.
- Retroactive re-categorisation of already-imported rows when the map changes.

## Design

### Decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Grouping | Introduce `ImportInfo { externalTransactionId, mcc }`, threaded as `importInfo :: Maybe ImportInfo` — **replacing** the top-level `externalTransactionId :: Maybe ExternalTransactionId` on the command/event | Both have value only for imports. `externalTransactionId` is behaviourally load-bearing (drives the overdraft-bypass guard + dedup), `mcc` is descriptive; grouping makes "is this imported?" one typed fact (`isJust importInfo`), keeps `externalTransactionId` **required within** an import, and gives future provider metadata one extensible home. Mirrors `RelationSpec` (the existing at-creation spec threaded through `InitiateTransaction`). |
| MCC wire representation | `mcc :: Maybe MCC` (JSON string, e.g. `"5411"`) | `MCC = Text` throughout the domain and `mccExpenseCategoryMap` keys; no boundary conversion; tolerant of any provider's format. |
| Read-model / DTO surface | Flat `mcc` only (no `externalTransactionId`, no nested object) | The read model/DTO project just what the client needs (MCC visibility); `externalTransactionId` stays internal. The domain grouping is independent of the read projection. |
| Default-map scope | Comprehensive | Broad coverage of common MCC ranges so fresh users get useful categorisation. |
| Old events | Optional decode, default `Nothing` | `<*> o .:? "importInfo" .!= Nothing` matches the existing hand-written `TransactionPostingInitiated` decoder pattern; historical events (which serialised `externalTransactionId`) decode to `importInfo = Nothing`. Consistent with the no-back-compat stance — clean shape, no upcaster. |

### The `ImportInfo` type

Add to `src/Domain/Core/Types.hs` (next to `RelationSpec`), exported `ImportInfo (..)`:
```haskell
data ImportInfo = ImportInfo
  { externalTransactionId :: ExternalTransactionId, -- required: every import has one
    mcc :: Maybe MCC                                -- optional: only some providers supply it
  }
  deriving (Show, Eq, Generic)
instance ToJSON ImportInfo
instance FromJSON ImportInfo
```
`Nothing :: Maybe ImportInfo` = manual entry; `Just` = imported.

### Write-path threading

1. **Command** — `InitiateTransaction` (`src/Domain/Transaction/Commands.hs:103`):
   replace `externalTransactionId :: Maybe ExternalTransactionId` with
   `importInfo :: Maybe ImportInfo`.
2. **Event** — `TransactionPostingInitiated` (`src/Domain/Transaction/Events.hs:96`):
   same replacement. In the hand-written positional `FromJSON` (`Events.hs:339`)
   replace the `externalTransactionId` decode line with
   `<*> o .:? "importInfo" .!= Nothing` (keep record-field order and parser order
   in lockstep).
3. **Command handler** (`CommandHandler.hs:219`): `importInfo = importInfo`.
4. **Aggregate** — `Transaction` (`Projection.hs`): **unchanged**. It never
   carried `externalTransactionId` and nothing reads import data off the
   aggregate, so `importInfo` is not added here.
5. **Behavioural read sites** (read import data off the *event*):
   - Overdraft guard `TransactionPostingManager.hs:209`:
     `allowOverdraft = isJust evt.importInfo`.
   - Dedup projection `BankImportReadModel.hs:120`: key on
     `fmap (.externalTransactionId) evt.importInfo` (i.e. `Just extId` only when imported).
6. **Transactions read model** — `src/Application/ReadModels/Transaction.hs`:
   - `TransactionData` (line 144): new field `mcc :: Maybe MCC`.
   - `TransactionEntity` (line 211): new **nullable** column `mcc Text Maybe`.
   - Projection handler (line 294): write from `evt.importInfo >>= (.mcc)`.
   - `entToData` (line 379): carry the column into `TransactionData`.
7. **DTO** — `src/Web/Types.hs`:
   - `TransactionResponse` (line 611): new field `mcc :: Maybe Text`.
   - `fromTransactionData` (line 1080): populate from `TransactionData.mcc`.
   - `fromTransaction` (line 1116, legacy aggregate builder): `mcc = Nothing`
     (the aggregate carries no MCC).

### Producing the value at import

In `BankImportService`, `buildTransferCmd` (`BankImportService.hs:628`) currently
builds `externalTransactionId = Just bankTx.externalId` and drops MCC. Replace with
`importInfo = Just (ImportInfo { externalTransactionId = bankTx.externalId, mcc = bankTx.mcc })`.
`resolveCategory` is unchanged. All other `InitiateTransaction` / event
construction sites (manual creation, prompt import, tests) pass `importInfo = Nothing`.

### Schema migration

`transactions` is a persistent read-model table (per the persistent read-models
rollout). The new column is nullable, so it is additive. Follow the established
per-model migration recipe from that rollout; no data backfill is required
(existing rows are simply `NULL`, which is correct — they carry no MCC).

### New default expense categories

Five expense categories are added to `Defaults.hs` because common MCC groups
have no good home in the current set and would otherwise fall into `Other`:

| New category | Name string | Covers (examples) |
| --- | --- | --- |
| Dining | `"Dining"` | Restaurants, bars, fast food (5812, 5813, 5814) — split out of `Food`, which retains groceries. |
| Beauty & Personal Care | `"Beauty & Personal Care"` | Barbers, salons, spas, cosmetics (7230, 7298, 5977). |
| Pets | `"Pets"` | Pet stores, veterinary, pet food (5995, 0742). |
| Electronics | `"Electronics"` | Computer/electronics stores, software (5732, 5734, 5045, 5816). |
| Shopping | `"Shopping"` | General merchandise: department, discount, warehouse, variety (5311, 5310, 5300, 5331). |

Each is threaded through the same three places every existing default category
uses, so it is seeded and MCC-mappable exactly like the others:

- a field on `ExpenseDefaults` (`Defaults.hs:91`) + its export list entry
  (`Defaults.hs:29`),
- construction in the `expense` record (`Defaults.hs:125`) via `mkExpense`,
- an entry in `defaultExpenseCategories` (`Defaults.hs:160`) so the seed loop
  creates the dictionary entry.

Their `CategoryId`s are deterministic UUIDv5 (via `mkExpense`), so the MCC map
can reference them the same way it references existing categories. No income
categories are added.

### Default MCC→category map

Expand `defaultMccExpenseCategoryMap`
(`src/Domain/Configuration/Defaults.hs:193`) comprehensively. Remap the three
dining MCCs to the new `Dining` category: 5812 (Restaurants) and 5814 (Fast
food) move from `Food`, and 5813 (Bars, nightclubs) moves from `entertainment`
(its current target) — `Food` keeps grocery codes 5411/5499. Add the
new-category codes above. Additionally
cover common gaps mapped to existing categories: hardware/home-improvement,
books & news, alcohol/tobacco, hotels, additional transport/fuel/auto codes,
additional health/medical codes, additional education codes, insurance codes,
government & postal, and telecom. Each entry keeps the inline `-- code —
meaning` comment style already used in the file. Income MCCs remain unmapped
(income skips the map by design).

## Testing

- **Import persists MCC** (integration): import a monobank statement row with a
  known MCC; assert the resulting `TransactionData`/`TransactionResponse`
  carries that MCC.
- **Manual transaction has no MCC**: a manually created transaction yields
  `mcc = Nothing` / JSON `null`.
- **MCC-less provider**: a PrivatBank (or MCC-`0`) row yields `mcc = Nothing`.
- **Event round-trip / backward compat** (unit): a serialized
  `TransactionPostingInitiated` without an `importInfo` key decodes to
  `importInfo = Nothing`; one carrying `importInfo` round-trips.
- **Overdraft guard preserved** (property/unit): a posting event with
  `importInfo = Just …` sets `allowOverdraft = True`; `Nothing` keeps the guard.
- **Dedup preserved**: an imported event still records its
  `externalTransactionId` in the bank-import read model; a manual event does not.
- **Default map** (unit): a sample of newly added MCC codes resolve to their
  intended default categories via `defaultMccExpenseCategoryMap`; the dining
  MCCs 5812/5813/5814 resolve to `Dining` (positive assertion).
- **New categories seeded** (unit): the five new categories appear in
  `defaultExpenseCategories`, and every `CategoryId` referenced by
  `defaultMccExpenseCategoryMap` is present in `defaultExpenseCategories` (no
  dangling map targets).

Reuse existing Testkit fixtures/generators and the in-memory event store; do not
re-define import setup helpers.

## Files touched

- `src/Domain/Core/Types.hs` (new `ImportInfo` type)
- `src/Domain/Transaction/Commands.hs`
- `src/Domain/Transaction/Events.hs`
- `src/Domain/Transaction/CommandHandler.hs`
- `src/Application/ProcessManagers/TransactionPostingManager.hs` (overdraft guard reads `importInfo`)
- `src/Application/ReadModels/BankImportReadModel.hs` (dedup reads `importInfo`)
- `src/Application/ReadModels/Transaction.hs`
- `src/Application/Services/BankImportService.hs`
- `src/Web/Types.hs`
- `src/Domain/Configuration/Defaults.hs` (done)
- Tests under `test/` (Transaction + BankImport + Configuration defaults) — many construction sites updated `externalTransactionId`→`importInfo`
