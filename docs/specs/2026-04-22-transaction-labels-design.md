---
status: in-progress
date: 2026-04-22
issue: homeaccounting/backend#30
---

# Transaction Labels

## Problem

Transactions today can carry a single category (for income/expense) or no
classification at all (for internal transfers). Users need a second,
orthogonal classification axis — free-form, multi-valued tags like
`kids`, `school`, `vacation` — that is:

- common to **all** transaction types (income, expense, internal
  transfer),
- **optional** and **multi-valued** (zero or more per transaction),
- **defined per-user** in the same way income / expense categories are,
- **editable after the transaction is created**.

While specifying the labels feature, a parallel gap surfaced in the
existing category system: once a transaction is created, its category
cannot be changed. The same edit requirement applies there. This spec
therefore covers two linked changes:

1. A new `labels` dictionary in user configuration, plus the ability to
   attach a set of labels to any transaction.
2. The ability to edit labels and the category on existing completed
   transactions.

## Goals

1. Users can define, rename, and delete labels in their configuration,
   reusing the existing generic dictionary CRUD.
2. Every transaction type can carry zero or more labels, chosen from the
   user's labels dictionary.
3. After a transaction is completed, users can replace its label set and
   change its category (for income / expense) through dedicated HTTP
   endpoints.
4. Deleting a label or category that is still referenced by any
   transaction is refused with a clear, actionable error.
5. The labels dictionary is permitted to be empty; income and expense
   category dictionaries remain required-non-empty.
6. Existing behaviour, events, and HTTP routes are preserved.

## Non-Goals

- Filtering `GET /api/transactions` by label — deferred.
- Filtering by category on the list endpoint — out of scope (deferred
  with label filtering).
- Editing labels or category on `Pending` or `Failed` transactions —
  rejected.
- Editing a transaction's `description`, `date`, amounts, or accounts —
  unchanged; out of scope.
- A dedicated reverse index `entryId → transactions` on the read model —
  a linear scan is sufficient at current volume.
- A label-hierarchy / nested tags model — labels are a flat set.
- UI / client work — this spec only covers the backend.

## Design

### 1. Domain types

`LabelId` is an alias, not a newtype. Income / expense categories
already share `DictionaryEntryId` as their id type — treating labels the
same keeps the read-model and event payloads uniform.

```haskell
-- Domain.Core.Types
type LabelId = DictionaryEntryId

labelsDictionaryId :: DictionaryId
labelsDictionaryId = DictionaryId "labels"
```

The existing `incomeCategoryDictionaryId` and
`expenseCategoryDictionaryId` gain a sibling. Name refinements,
`EntryName` smart constructor, and length/trim rules are reused as-is;
labels inherit identical constraints.

On a transaction, labels are stored as `Set DictionaryEntryId` —
unordered, deduplicated, and serialised to JSON as a sorted array of
UUIDs for deterministic output.

### 2. Configuration aggregate

#### 2.1 Seeded default

`Domain.Configuration.Projection` is extended so the initial
`Configuration` value contains three dictionaries: `income-category`,
`expense-category`, and `labels` (empty). New users and the shared
default configuration carry the empty labels dictionary from the
start.

#### 2.2 Existing users / cloned configurations

Configurations that predate this change do not carry a `labels` entry.
The projection handler is relaxed so that applying
`DictionaryEntryAdded` for a dictionary that is not yet present in the
`Map` auto-initialises it with the given entry (instead of silently
dropping the event). `DictionaryEntryRenamed` and
`DictionaryEntryRemoved` against a missing dictionary cannot legally
occur — the command handler refuses both when the dictionary has no
corresponding `Added` history — but the projection defensively treats
them as no-ops for robustness. This avoids rewriting historical events
and is harmless for the generic dictionary shape. No new event type is
introduced.

#### 2.3 "Cannot remove last entry" becomes dictionary-specific

`Domain.Configuration.CommandHandler` currently refuses
`RemoveDictionaryEntry` when the targeted dictionary would become empty.
That rule is preserved for income / expense categories — the domain
requires every income / expense transfer to carry a category, so an
empty category dictionary would make new transactions uncreatable.

A local helper governs the rule:

```haskell
requiresNonEmpty :: DictionaryId -> Bool
requiresNonEmpty d =
  d == incomeCategoryDictionaryId || d == expenseCategoryDictionaryId
```

For `labels` the check is skipped — the dictionary may be left empty.

#### 2.4 "Cannot remove entry in use" (new)

A second pre-condition for `RemoveDictionaryEntry` is enforced at the
**service layer**, not in the pure command handler: the check depends
on the transaction read model.

In `Application.Services.ConfigurationService.removeDictionaryEntry`,
before issuing the command:

1. Query the `TransactionReadModel` for any transaction whose
   `transferType` references `entryId` (applies to income / expense
   categories), or whose `labels` set contains `entryId` (applies to
   `labels`).
2. If any match is found, return
   `Left (CategoryInUse entryId count)` or
   `Left (LabelInUse entryId count)` (both constructors carry the
   pair `(DictionaryEntryId, Int)` — consistent with the helper's
   `Int` return and the error-mapping DTOs).
3. Otherwise, proceed with `RemoveDictionaryEntry` as before.

The "not in use" pre-condition is independent of the "not the last
entry" rule from §2.3: for `labels`, §2.3 is skipped (empty labels
dictionary is allowed) and only the in-use check applies; for
`income-category` / `expense-category`, both checks apply.

The command handler does not duplicate this check — the service-layer
guard is authoritative. Command-handler tests continue to assert the
pure-domain rule (`requiresNonEmpty`).

#### 2.5 CRUD endpoints

No new HTTP routes. Labels reuse the generic dictionary endpoints:

```
GET    /api/users/me/configuration
POST   /api/users/me/configuration/dictionaries/labels/entries
PUT    /api/users/me/configuration/dictionaries/labels/entries/:entryId
DELETE /api/users/me/configuration/dictionaries/labels/entries/:entryId
```

Responses are unchanged in shape. The root `GET` already keys
dictionaries by id so clients see `labels` alongside `income-category`
and `expense-category` automatically.

### 3. Transaction aggregate

#### 3.1 Extended creation event

`InitiateTransfer` command and `TransferInitiated` event gain a new
field:

```haskell
labels :: Set DictionaryEntryId
```

The set may be empty. During `InitiateTransfer` handling the service
layer validates every label id against the user's labels dictionary
before issuing the command; invalid ids yield
`LabelNotFound entryId`.

#### 3.2 Two edit commands (new)

Both commands are accepted only when the aggregate is in the
`Completed` state. In any other state (`Pending` or `Failed _`) the
command handler returns
`CannotEditTransactionLabelsInCurrentState`.

```haskell
-- Domain.Transaction.Commands
data SetTransactionLabels = SetTransactionLabels
  { transactionId :: TransactionId
  , labels        :: Set DictionaryEntryId
  }

data ChangeTransactionCategory = ChangeTransactionCategory
  { transactionId :: TransactionId
  , newCategory   :: DictionaryEntryId
  }
```

`ChangeTransactionCategory` is additionally rejected when the
transaction's `transferType` is `Transfer` (internal transfer — no
category), with `CannotChangeCategoryOnInternalTransfer`. For `Income`
and `Expense` the category is replaced in place
(`Income _ → Income newId`, `Expense _ → Expense newId`).

**Invariant:** `TransactionCategoryChanged` is emitted only after an
`Income` or `Expense` `TransferInitiated`. The command handler enforces
this by inspecting the current projection; any future snapshot /
rehydration strategy must preserve this ordering so the projection
fold in §3.4 is well-defined.

#### 3.3 Two edit events (new)

Payloads carry only domain-meaningful data. Timestamps live in the
Eventium envelope (`occurredAt`); actor is not recorded on these
events.

```haskell
-- Domain.Transaction.Events
data TransactionLabelsSet = TransactionLabelsSet
  { transactionId :: TransactionId
  , labels        :: Set DictionaryEntryId
  }

data TransactionCategoryChanged = TransactionCategoryChanged
  { transactionId :: TransactionId
  , newCategory   :: DictionaryEntryId
  }
```

Replace-set semantics for labels (see Q5 — each event carries the full
new set, giving a clean audit trail).

#### 3.4 Projection

`Domain.Transaction.Projection.Transaction` gains:

```haskell
labels :: Set DictionaryEntryId
```

Fold rules:

- `TransferInitiated` → initialise `labels` from the event's set and
  `transferType` as today.
- `TransactionLabelsSet` → replace `labels` with the event's set.
- `TransactionCategoryChanged` → mutate `transferType`:
  `Income _ → Income newId`, `Expense _ → Expense newId`. `Transfer`
  is unreachable here because the command handler rejects such edits.
- `TransferCompleted` / `TransferFailed` — unchanged.

The lifecycle state machine is unchanged: `Pending → Completed` or
`Pending → Failed`. Edit events do not change `status`; they mutate
only `labels` / `transferType` and are valid only against `Completed`.

#### 3.5 Process manager

`Application.ProcessManagers.TransferManager` is unchanged. Label /
category edits do not move money and do not feed the saga.

### 4. Read models

#### 4.1 `ConfigurationData`

Structurally unchanged: `dictionaries :: Map DictionaryId
DictionaryData` already accommodates arbitrary dictionary ids. The
seeded default gains a `labels` key; projection event handlers
auto-initialise a missing dictionary on first related event, matching
§2.2.

#### 4.2 `TransactionData`

Add a field:

```haskell
labels :: Set DictionaryEntryId
```

Event handlers in `Application.ReadModels.Transaction`:

- `TransferInitiated` → populate `labels` from the event (and keep the
  existing population of `transferType`, `sourceAccountId`, etc.).
- `TransactionLabelsSet` → replace `labels`.
- `TransactionCategoryChanged` → replace the category embedded in
  `transferType`.

The rest of the read model — keys, indexing, `TransactionQuery` — is
unchanged. No label filter is added this iteration.

#### 4.3 In-use lookup

A helper on the transaction read model powers §2.4:

```haskell
findReferencingTransactions ::
  MonadIO m =>
  TVar TransactionReadModel ->
  DictionaryEntryId ->
  m Int
```

Linear scan; returns a count used by the service layer to attach to
`CategoryInUse` / `LabelInUse`.

### 5. Web API

#### 5.1 Request DTO additions (creation endpoints)

`IncomeRequest`, `ExpenseRequest`, `InternalTransferRequest` each gain:

```haskell
labels :: Maybe [UUID]
```

Decoding rules:

- Field absent or `null` → treated as `Just []` (no labels).
- Duplicate ids in the array are deduplicated into the `Set` with no
  error.
- Unknown ids → `400` with `LabelNotFound`.

#### 5.2 Response DTO additions (get / list endpoints)

`TransactionResponse` gains:

```haskell
labels :: [UUID]
```

Always present (possibly empty). Serialised sorted for deterministic
output.

#### 5.3 New edit endpoints

```
PUT /api/transactions/:id/labels
  body: { labels :: [UUID] }
  -> 200 TransactionResponse
```

```
PUT /api/transactions/:id/category
  body: { categoryId :: UUID }
  -> 200 TransactionResponse
```

Both endpoints require `AuthProtect "jwt"` and enforce the standard
access check — the authenticated user must have at least
`Editor`-level access to one of the transaction's accounts (same rule
as creation endpoints). Access is computed via
`AccountReadModel.getAccessibleAccounts`.

Error responses:

| HTTP | DomainError                                   | When                                              |
| ---- | --------------------------------------------- | ------------------------------------------------- |
| 400  | `ValidationErr`                               | Malformed UUIDs, empty body                       |
| 403  | `AccessDenied`                                | User lacks access to the transaction              |
| 404  | `TransactionNotFound`                         | Unknown id                                        |
| 404  | `LabelNotFound` / `CategoryNotFound`          | Unknown label or category id                      |
| 409  | `CannotEditTransactionLabelsInCurrentState`   | Transaction not `Completed`                       |
| 409  | `CannotChangeCategoryOnInternalTransfer`      | Target is an internal transfer                    |

Configuration-side deletion errors surfaced by §2.4 map to:

| HTTP | DomainError                                   | When                                              |
| ---- | --------------------------------------------- | ------------------------------------------------- |
| 409  | `CategoryInUse entryId count`                 | Category referenced by ≥1 transaction             |
| 409  | `LabelInUse entryId count`                    | Label referenced by ≥1 transaction                |

New `DomainError` constructors added to `Domain.Core.Errors`:

- `LabelNotFound DictionaryEntryId`
- `CategoryNotFound DictionaryEntryId` (new — today the creation
  handlers surface generic validation errors for unknown category ids;
  this spec promotes the case to a first-class error so both the
  creation and the new edit path share one mapping)
- `LabelInUse DictionaryEntryId Int`
- `CategoryInUse DictionaryEntryId Int`
- `CannotEditTransactionLabelsInCurrentState`
- `CannotChangeCategoryOnInternalTransfer`

Each gets a matching case in `Web.ErrorMapping`.

### 6. Testing

Follows the project's three-tier pattern (unit + property + integration)
and TDD ordering (failing test → green → refactor).

**Domain layer:**

- `test/Domain/Configuration/CommandHandlerSpec.hs` — adding / renaming /
  removing entries in the `labels` dictionary; `requiresNonEmpty`
  allows removing the last label entry but still refuses for income /
  expense.
- `test/Domain/Transaction/CommandHandlerSpec.hs` —
  `SetTransactionLabels` / `ChangeTransactionCategory` accepted only
  in `Completed`; `ChangeTransactionCategory` rejected on `Transfer`.
- `test/Domain/Transaction/ProjectionSpec.hs` — folding sequences of
  `TransactionLabelsSet` / `TransactionCategoryChanged` yields the
  expected `labels` / `transferType`.
- `test/Domain/Transaction/PropertySpec.hs` — for any sequence of
  `TransactionLabelsSet` events, the final projection's `labels`
  equals the last event's set; analogous for category.

**Generators (`test/Testkit/Generators.hs`):**

- `genLabelSet` drawing from a bounded label universe per test run.
- Extend transfer / transaction generators to include labels (with
  empty-set bias so the "optional" path is well covered).

**Application layer:**

- `test/Application/Services/ConfigurationServiceSpec.hs` —
  `removeDictionaryEntry` refuses when an entry is referenced by any
  transaction (for each dictionary); succeeds when not referenced.
- `test/Application/Services/TransactionServiceSpec.hs` —
  `setTransactionLabels` / `changeTransactionCategory` orchestration,
  label / category validation against the user's dictionary, access
  control.

**Integration:**

- `test/Integration/TransactionLabelsIntegrationSpec.hs` — end-to-end:
  add labels to config → create expense with labels → rename one
  label → re-set labels on the expense → delete an in-use label
  (expect 409) → remove label from transaction → delete succeeds.
- `test/Integration/TransactionCategoryEditIntegrationSpec.hs` —
  end-to-end: create income → change category → attempt to change
  category on an internal transfer (expect 409).

**Web layer:**

- `test/Web/API/TransactionAPISpec.hs` — list / get responses include
  `labels`; `PUT /labels` and `PUT /category` happy + rejection paths
  (including 404, 409, 403).
- `test/Web/API/ConfigurationAPISpec.hs` — CRUD for the `labels`
  dictionary through the generic endpoints; in-use deletion returns
  409 with the correct `DomainError` payload.

**LiquidHaskell:** `LabelId` is a type alias over `DictionaryEntryId`
and inherits all refinements. No new `.hs` refinement files required.

## Cross-Cutting Concerns

**Event-log compatibility.** Existing `TransferInitiated` events were
persisted without a `labels` field. The `FromJSON` instance for the
event must default `labels` to `Set.empty` when the field is absent
(matches the "optional-in, defaulted-to-empty" pattern used elsewhere
for forward-compatible event evolution). Replaying old events yields
transactions with empty label sets.

**Backwards compatibility.** `TransactionResponse` gains a new field —
any existing client that ignores unknown fields continues to work.
Request DTOs treat `labels` as optional, so existing creation clients
that omit the field keep working.

**Forward compatibility.** Adding label or category filters to
`TransactionQuery` in a future change is non-breaking: the smart
constructor takes each filter as a distinct argument, the HTTP layer
adds optional `QueryParam`s.

**Performance.** The in-use check on dictionary entry deletion is a
linear scan of the transaction read model. Personal accounting volumes
make this acceptable; if measurements later show it is a hot path,
adding a reverse index `entryId → Set TransactionId` is a localised
follow-up.

**Ordering / determinism.** Labels are stored as `Set` domain-side,
serialised as a sorted UUID array over the wire — ensures stable
fixtures and diffable responses.

**Audit trail.** The replace-set shape of `TransactionLabelsSet`
preserves complete history — every edit records the full new set as it
was at that moment. Combined with the Eventium envelope `occurredAt`,
the event log is a faithful record without a separate change-log
aggregate.
