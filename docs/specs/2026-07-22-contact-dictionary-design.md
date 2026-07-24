---
status: completed
date: 2026-07-22
---

# Optional contact (counterparty) on income & expense transactions

Backend portion of tracker#41. The web portion (contact picker on
create/edit, manage-contacts UI, filter/report by contact) is a separate
effort in the client repo and is out of scope here.

## Problem

Categories answer *what kind* of movement a transaction was; labels are
free-form tags. Neither captures **the counterparty** — the concrete entity
on the other side of an income or expense:

- **Expense** → the **beneficiary** (payee / merchant / recipient).
- **Income** → the **source** (payer / employer / origin).

Today the only trace of a counterparty is the free-text `description` memo,
which is not a stable, reusable, filterable entity. A user cannot ask
"everything I paid to X" or "all income from Y" without string-matching noisy
memos.

Bank import makes this worse: `BankTransaction.description`
(`src/Infrastructure/Banking/Provider.hs:61`) is, for monobank, essentially
the merchant/counterparty string, but it is only stored as the memo
(`src/Application/Services/BankImportService.hs:635`) and never linked to
anything structured.

## Goal

1. Add an **optional** per-transaction contact reference to income and expense,
   drawn from a single user-curated **contact dictionary**, mirroring how
   `categoryId` / `labels` already work.
2. **Transfers and adjustments carry no contact** — money moving between the
   user's own accounts has no external counterparty.
3. During **bank import**, link an existing curated contact when the statement
   description matches one — **match-only, never auto-create**.

### Deliberately out of scope

- **Auto-creating contacts from import or free text.** Dictionaries are
  user-curated; auto-populating from raw bank strings would flood the list with
  near-duplicates ("NETFLIX.COM AMSTERDAM", "SILPO 123 KYIV") and invert the
  dictionary's purpose (a *stable, deduplicated* entity list). Import is
  match-only; the raw description remains available as the memo.
- **Dictionary dedup/merge tooling.** Only relevant *because* auto-create would
  flood the list; with creation being manual-only, duplicates are a rare,
  user-caused thing. Deferred to a possible future issue. If ever built, the
  non-polluting path is a learned alias map (normalized-description → contactId,
  populated when the user manually assigns) or surfacing unmatched descriptions
  as promotable suggestions — not a cross-aggregate merge saga.
- **Resolved contact name on the DTO.** The response exposes the contact **id**
  only, matching how `categoryId` / `labels` are surfaced today; the client
  resolves names from the dictionary it already holds.
- **A default contact.** Absence is the norm, not an error; there is no
  `SetDefault*Contact` command.
- **Fuzzy / normalized-alias matching at import.** Exact normalized-name match
  only; fuzzy matching is a future enhancement.
- **Contact on a per-allocation basis.** A transaction has one counterparty even
  when split across categories, so contact attaches at transaction level.

## Design

### Key existing machinery (reused, not rebuilt)

`ContactKind` **already exists** in the `DictionaryKind` enum
(`src/Domain/Configuration/Dictionary.hs:59`, slug `"contact"`) but is wired
nowhere else. Because dictionary CRUD is generic over `DictionaryKind`:

- The commands/events `AddDictionaryEntry` / `RenameDictionaryEntry` /
  `RemoveDictionaryEntry` / `MoveDictionaryEntry` already accept `ContactKind`
  unchanged (`src/Domain/Configuration/Commands.hs:134-186`,
  `Events.hs:132-175`).
- The REST CRUD at `/dictionaries/contact/...` works for free via the generic
  slug router (`src/Web/API/ConfigurationAPI.hs:174-227` →
  `requireDictionaryKind` → `parseDictionaryKind`).

So no new dictionary machinery is needed. The work is threading an **optional
scalar `contactId`** through the transaction stack (mirroring `LabelId`, but
scalar-and-nullable rather than a set with a join table), plus a match-only
import resolver.

### Decisions

- **Reference shape:** `contactId :: Maybe ContactId` where
  `type ContactId = DictionaryEntryId` (alias in `Domain.Core.Types`, alongside
  `LabelId` / `CategoryId`). Flat on the transaction (like `labels`), not inside
  allocations (unlike `categoryId`), because contact is transaction-level.
- **Persistence:** a **nullable column** on `TransactionEntity`, not a join
  table — the reference is scalar-optional. No backward-compat phase (per
  project policy), so the column is added directly.
- **Transfer guard:** hard reject via a new `ContactNotAllowedOnTransfer`
  domain error, enforced in the service. Note the layering: at the web edge the
  `CreateTransfer` request DTO and the typed `initiateTransfer` service function
  **already structurally exclude** the field, so the normal create-transfer path
  cannot carry a contact at all. The runtime guard is therefore a **defensive
  check for the paths that share a command shape** — chiefly amendment
  (`AmendTransaction`/`CompleteTransactionAmendment` carry `contactId` with a
  kind that may be transfer/adjustment) and any internal command construction —
  where the field cannot be structurally excluded.
- **Editing surfaces:** a dedicated `SetTransactionContact` command /
  `TransactionContactSet` event (mirrors `SetTransactionLabels` /
  `TransactionLabelsSet`), **and** the optional `contactId` threaded through the
  amendment path.
- **DTO:** `contactId :: Maybe UUID` on `TransactionResponse` (id only).
- **Import extraction:** match-only. A `resolveContact` in `BankImportService`,
  beside `resolveCategory`, runs only for income/expense; it links an existing
  contact when the normalized description matches, else leaves `Nothing`. It
  never issues `AddDictionaryEntry`.

### 1. Types & errors

`src/Domain/Core/Types.hs`
- Add `type ContactId = DictionaryEntryId` (near `LabelId` :645 / `CategoryId`
  :650) and export it (export list ~66).

`src/Domain/Core/Errors.hs`
- Add three `DomainError` constructors alongside the existing label/category
  ones (`LabelNotFound` :73, `CategoryNotFound` :75, `LabelInUse` :77,
  `CategoryInUse` :82):
  - `ContactNotFound` — validation: a supplied `contactId` is not an assignable
    entry in the contact dictionary.
  - `ContactInUse` — deletion guard: removing a contact still referenced by
    transactions.
  - `ContactNotAllowedOnTransfer` — a contact supplied on a transfer/adjustment.

`src/Application/Services/ConfigurationService.hs`
- Add and export `contactsDictKind = ContactKind` (beside `labelsDictKind` :186).

### 2. Commands & events

`src/Domain/Transaction/Commands.hs`
- `InitiateTransaction` (:103-133): add `contactId :: Maybe ContactId`
  (defaults to `Nothing` at all non-import call sites). Update the TH field list
  and JSON.
- New `SetTransactionContact` command (mirror `SetTransactionLabels` :181-187):
  carries `transactionId`, `contactId :: Maybe ContactId`, and the actor `by`.

`src/Domain/Transaction/Events.hs`
- `TransactionPostingInitiated` (:96-121): add `contactId :: Maybe ContactId`.
  Extend the hand-written backward-tolerant `FromJSON` (:340-353) with
  `.:? "contactId"` defaulting to `Nothing` (a scalar optional needs the same
  old-event tolerance labels got).
- New `TransactionContactSet` event (mirror `TransactionLabelsSet` :152-160).
- Amendment events `TransactionAmendmentInitiated` / `...Completed`
  (:217-265): thread `contactId :: Maybe ContactId` so amendment can change the
  contact.

`src/Domain/Transaction/Commands.hs` (amendment)
- `AmendTransaction` / `CompleteTransactionAmendment` (:297-340): thread the
  optional `contactId`.

Naming follows the repo conventions (memory): command `SetTransaction<Thing>`,
event `Transaction<Thing>Set`; actor field named `by :: UserId`.

### 3. Aggregate & projection (domain)

- The transaction aggregate applies `TransactionPostingInitiated.contactId`,
  `TransactionContactSet`, and amendment-completed `contactId` to aggregate
  state so it is available to the domain and rebuilt from events.
- Contact is only meaningful for income/expense; on the aggregate the field is
  present but the service guard prevents it ever being set for transfer kinds.

### 4. Validation & guards (`src/Application/Services/TransactionService.hs`)

- Add `validateContact :: Maybe ContactId -> AppM ()` (model on `validateLabels`
  :736-749): when `Just`, verify membership via
  `assignableEntryIds contactsDictKind`; else throw `ContactNotFound`. `Nothing`
  is always valid.
- Add a transfer guard helper: a `Just contactId` on a transfer/adjustment kind
  throws `ContactNotAllowedOnTransfer`.
- Wire into call sites:
  - `initiateIncome` (:254-305) and `initiateExpense` (:320-366): call
    `validateContact` and set `contactId` on the emitted command.
  - `initiateTransfer` (:386-433): assert no contact (guard).
  - New `setTransactionContact` service action (mirror `setTransactionLabels`
    :445-465): validate (and guard against transfer target) then emit
    `SetTransactionContact`.
  - Amendment dispatch (~942-973): validate the amended `contactId` and apply
    the transfer guard when the amended kind is transfer/adjustment.

### 5. Read model & DTO

`src/Application/ReadModels/Transaction.hs`
- `TransactionData`: add `contactId :: Maybe ContactId` (:146-168).
- `TransactionEntity`: add a **nullable** contact column (not a join table).
  Adapt `entToData` (:386-399) and `getTransaction` (:450-456). No
  `loadLabelsMany`-style batch fetch needed — the value lives on the row.
- Projection application (:291-332): set the column on
  `TransactionPostingInitiated`, on `TransactionContactSet`, and on
  amendment-completed events.
- Deletion guard: extend `findReferencingTransactions` (:542-543) to count the
  nullable contact column for `ContactKind`, and convert the currently **binary**
  label-vs-category `if/else` in `ConfigurationService.removeDictionaryEntry`
  (:283-287) into a **three-way branch** (label / category / contact) that raises
  `ContactInUse` for the contact kind. (Explicit callout: this is a shape change
  from two branches to three, not a drop-in addition.)
- Optional (nice-to-have, not required): a `contactId` filter on the list query
  parallel to `labelFilters` (:516) so "all transactions with contact X" is
  queryable server-side. Include if cheap; otherwise defer to the client repo.

`src/Web/Types.hs`
- `TransactionResponse` (:611-638): add `contactId :: Maybe UUID`.
- `fromTransactionData` (:1083-1109): map the contact id (id only, no name).
- Request DTOs: add `contactId` to `CreateIncome` / `CreateExpense` requests;
  add a `SetTransactionContactRequest`. Add `parseContactId` (beside
  `parseCategoryId` :1203 / `parseLabelIds` :1212). `CreateTransfer` request
  gets **no** contact field.

`src/Web/API/TransactionAPI.hs`
- New route + handler for set-contact (mirror `setLabelsHandler` :350-352);
  create handlers (:292-338) pass `contactId` through.

### 6. Import extraction — match-only (`src/Application/Services/BankImportService.hs`)

- Add `resolveContact`, beside `resolveCategory` (:358-387), returning the
  matched `Maybe ContactId` plus a `ContactResolution` provenance tag
  (`MatchedExisting` / `NoMatch`). It runs **only for income/expense**.
- Matching: normalize `BankTransaction.description` (trim + collapse internal
  whitespace); blank → `NoMatch`. Look it up case-insensitively against
  `dictionaryItems (dictionaries ! ContactKind)` from the already-loaded
  `ConfigurationData` (loaded at `commitMatchingCurrencyImport` :566-572). No
  new by-name helper is strictly required, but a small
  `lookupContactByName`-style scan keeps the resolver readable.
- Thread the result into `buildTransferCmd` (:628-647) as
  `InitiateTransaction.contactId`. **No `ImportInfo` change** — contact is a
  first-class transaction field, not an import-only field.
- Provenance logged like `logCategoryResolution` (:396-432). **No
  `AddDictionaryEntry` is ever issued from import.**
- Because resolution runs only for income/expense, the transfer guard is never
  triggered by import.

### 7. Bootstrap

No changes. No default contact is seeded; `seedDefaultConfiguration`
(`src/Application/Services/ConfigurationService.hs:786-875`) is untouched.

## Error handling

- Supplying a `contactId` that is not an assignable contact entry →
  `ContactNotFound` (validation error with field/value context via
  `mkValidationError`, consistent with `LabelNotFound`).
- Supplying a contact on a transfer/adjustment → `ContactNotAllowedOnTransfer`.
- Removing a contact still referenced by transactions → `ContactInUse`.
- Removing a contact is otherwise allowed and must **not** corrupt historical
  transactions; consistent with category/label removal, the id remains
  resolvable on already-recorded transactions.
- Import match-only never errors on a missing contact — a non-match is simply no
  contact.

## Testing

Mirror the existing category/label coverage.

- **Property / unit** (`test/Domain`, `test/Application`):
  - `validateContact`: `Just` known → ok; `Just` unknown → `ContactNotFound`;
    `Nothing` → ok.
  - Transfer guard: contact on transfer/adjustment (create *and* amendment) →
    `ContactNotAllowedOnTransfer`.
  - Aggregate/projection: contact set on create, changed via
    `SetTransactionContact`, changed via amendment; back-compat `FromJSON`
    tolerates events with no `contactId`.
  - `ContactInUse` on removing a referenced contact; removal allowed when
    unreferenced and leaves historical rows resolvable.
- **Import** (`test/Application/Services/BankImportServiceSpec.hs`):
  - Description matching an existing contact → transaction gets that
    `contactId`; no new dictionary entry created.
  - Non-matching / blank description → `Nothing`; dictionary unchanged.
  - Case/whitespace-insensitive matching.
- **Integration** (`test/Integration`): create → `SetTransactionContact` →
  amend → project path surfaces the right `contactId`; end-to-end import links
  a curated contact.
- **Web API** (`test/Web/API`): create income/expense with `contactId`;
  set-contact endpoint; `contactId` in `TransactionResponse`. Note there is no
  create-transfer-with-contact web test — the `CreateTransfer` DTO has no contact
  field, so the endpoint cannot submit one; the transfer reject is exercised at
  the domain/service layer instead (amend a transfer to add a contact →
  `ContactNotAllowedOnTransfer`, covered under Property/unit).
- **Testkit**: extend `TransactionEvents.postingInitiatedGlobal` (:49-67) to
  accept an optional `contactId`; add a contact generator/fixture beside the
  label ones (`Generators.genLabelSet` :290, `Fixtures.MetadataFixture`
  :231-260). Reuse existing dictionary fixtures rather than re-defining.

All domain types added must carry LiquidHaskell refinements consistent with the
existing `DictionaryEntryId` treatment; `ContactId` is a type alias so it
inherits `DictionaryEntryId`'s refinements.
