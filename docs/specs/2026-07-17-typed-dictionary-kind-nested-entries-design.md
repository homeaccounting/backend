---
status: completed
date: 2026-07-17
---

# Typed `DictionaryKind` + nested/grouped dictionary entries

Backend implementation of tracker#42. Gives the dictionary mechanism the
ability to organise entries into a tree and replaces the stringly-typed
`DictionaryId` with a closed, typed `DictionaryKind`. Unblocks #41
(`ContactDictionary`), the first dictionary expected to hold hundreds of entries.

> **Revised by [ADR 002](../decisions/002-structural-group-item-dictionary-entries.md).**
> The original design made group-ness **emergent** (a node with children) with a
> per-kind `groupsAssignable` and depth 4. ADR 002 replaces that with a
> **structural** group/item distinction: an entry is created as either a **group**
> (pure container, never assignable) or an **item** (leaf, always assignable), the
> role is **immutable**, all groups are non-assignable across every kind, and the
> tree is capped at **2 levels** (extensible to 3 via validation). The sections
> below are updated to that model; where this spec and ADR 002 disagree, ADR 002
> wins.

The web client (tree picker, drag/reparent management UI) is a separate effort
in `../monorepo` and is **out of scope** here.

## Problem

Dictionaries today are:

- **Stringly-typed.** Keyed by a free-text `newtype DictionaryId = DictionaryId Text`,
  with well-known literals scattered across the code (`"income-category"`,
  `"expense-category"`, `"labels"`), plus an "unknown dictionary id" error path.
  The set is small, closed, and entirely code-defined — there is no
  user-created dictionary.
- **Flat.** `Dictionary` is `{ entries :: [DictionaryEntry] }` with no notion of
  grouping. Contacts (#41) will hold hundreds of entries and cannot stay flat.

## Decisions

Confirmed with the issue author during brainstorming:

1. **Scope: backend only.** Web UI is a follow-up in `../monorepo`.
2. **Structural group vs item (ADR 002).** An entry is created as a **group**
   (container, never assignable) or an **item** (leaf, always assignable); the
   role is immutable. Assignability is universal and structural — not per-kind.
3. **Non-empty group removal: reject while non-empty.** `RemoveDictionaryEntry`
   fails if the group has children; the user must move/remove children first.
   Mirrors the existing "cannot remove last entry" guard and never orphans ids
   referenced by historical transactions.
4. **Bounded depth: max 2 levels (ADR 002).** Groups hold only items; items live
   at root or inside a group; groups live at root. Add/Move reject nodes that
   would exceed the limit. Extensible to 3 by relaxing one rule and bumping the
   constant.
5. **Deterministic entry ids: accept a one-time reseed.** `mkDeterministicEntryId`
   keys off the `DictionaryKind` (its derived tag) rather than the old id text,
   so default-category ids change once. Acceptable under the project's
   no-backward-compat phase.

## Model

### Closed `DictionaryKind` (replaces `DictionaryId`)

In `Domain.Core.Types`:

```haskell
data DictionaryKind
  = IncomeKind
  | ExpenseKind
  | LabelKind
  | ContactKind
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- NOTE (ADR 002): the per-kind `groupsAssignable :: DictionaryKind -> Bool` is
-- DELETED. Assignability is now structural — a function of the entry's role
-- (group vs item), uniform across every kind — not a property of the kind.

-- Wire/persistence slug, DERIVED mechanically from the constructor: drop the
-- "Kind" suffix, kebab-case, lowercase. IncomeKind -> "income",
-- ExpenseKind -> "expense", LabelKind -> "label", ContactKind -> "contact".
-- No hand-maintained per-constructor table — the derivation is the single
-- source of truth (adding a kind cannot drift its slug).
dictionaryKindSlug  :: DictionaryKind -> Text
parseDictionaryKind :: Text -> Maybe DictionaryKind   -- find over [minBound..maxBound]
```

Instances: `ToJSON`/`FromJSON` via the slug; `PersistField`/`PersistFieldSql`
in `Infrastructure.Database.Orphans` (replacing `DictionaryId`'s). `DictionaryId`,
`unDictionaryId`, and all its instances are **deleted**.

Constructors are singular (`LabelKind`, not `LabelsKind`) and short. `IncomeKind`
/ `ExpenseKind` **collide** with `TransactionKind`'s constructors of the same
name in the two modules that use both (`TransactionService`, `Resolve`);
resolve by importing `DictionaryKind` qualified there (e.g. `Dict.IncomeKind`).
This is a deliberate reversal of the issue's original "avoid the clash" note in
favour of short, mechanically-derived slugs (`income` / `expense`), which are
the client-facing API path segments.

Because the slug (`income`/`expense`/…) differs from the pre-migration id text
(`income-category`/…), API dictionary paths change — acceptable under the
no-backward-compat phase and consistent with the deterministic-id reseed.

### Structural tree node (ADR 002)

`DictionaryEntry` carries an immutable **role** plus an optional parent
reference (adjacency list):

```haskell
data EntryRole = GroupRole | ItemRole          -- immutable; declared at creation

data DictionaryEntry = DictionaryEntry
  { entryId  :: DictionaryEntryId
  , name     :: EntryName
  , role     :: EntryRole                -- GroupRole = container; ItemRole = leaf
  , parentId :: Maybe DictionaryEntryId   -- Nothing = root-level node
  }
```

A **group** is a pure container and is **never** assignable; an **item** is a
leaf and is **always** assignable. Group-ness is a *stored, immutable fact* of
the node — **not** emergent from whether it has children — which is what removes
the transition hazard the emergent model would otherwise create (see ADR 002).
Only groups may hold children; adding under an item is rejected structurally.

The recursive tree is a **derived, materialized** ADT that validation and the DTO
speak (an item cannot carry children by construction):

```haskell
data DictionaryNode
  = GroupNode DictionaryEntryId EntryName [DictionaryNode]  -- container
  | ItemNode  DictionaryEntryId EntryName                    -- leaf
```

Persistence stays flat — each `DictionaryEntry` carries its `role` and
`parentId`; the `DictionaryNode` tree is built on demand, never stored (events
are granular deltas and the read-model row is flat, so a flat entry
representation must exist regardless; the tree is materialized at the validation
and DTO edges). `DictionaryEntryId` and the `CategoryId` / `LabelId` /
(`ContactId`, #41) aliases are unchanged. `Dictionary` stays
`{ entries :: [DictionaryEntry] }`; the kind is the map key, so it is not
duplicated onto the dictionary.

### Kind-keyed dictionaries

`Configuration.dictionaries :: Map DictionaryKind Dictionary` (was
`Map DictionaryId Dictionary`). The tree is **derived** from `parentId` by
consumers that want a hierarchy; consumers wanting a flat list ignore it.

### Path identity & sibling-scoped name uniqueness (behavior change)

An entry's qualified identity is its **root-to-node path**, filesystem-style:

- **id-path** — `parentId₁/…/parentIdₓ/entryId`
- **name-path** — the ancestor names joined down to the node, e.g. `Food/Dining`

`entryId` is a globally-unique UUID, so id-paths are inherently unique. The
constraint that must be *enforced* is on the name-path: **no two siblings share
a name**, which is exactly what makes every full name-path unique.

Concretely, `hasDuplicateName` changes from dictionary-wide to **sibling-scoped**:
a name must be unique among nodes sharing the same `parentId`, like filenames
within a directory. Required for Contacts (two "John Smith"s under different
groups must be allowed) and is the natural tree semantics. This is the one
behavior change beyond what the issue spells out.

The qualified name-path is *derivable* from the materialised tree (walk
ancestors), so the DTO does not carry a precomputed path string — the client
renders `Food / Dining` from the node's position.

## Commands & events

`Domain.Configuration.Commands` / `Events`:

- `AddDictionaryEntry`: `dictionaryId → dictionaryKind`, **plus
  `role :: EntryRole`** and **`parentId :: Maybe DictionaryEntryId`**. The role
  is chosen at creation (add a group vs add an item). `DictionaryEntryAdded`
  mirrors it (carries `role`).
- `RenameDictionaryEntry` / `RemoveDictionaryEntry`: `dictionaryId → dictionaryKind`.
  Events mirror.
- **New** `MoveDictionaryEntry { dictionaryKind, entryId, newParentId :: Maybe DictionaryEntryId }`
  → `DictionaryEntryMoved`. Without this, the only way to reorganise is
  remove+re-add, which loses the id and orphans references. Wired into
  `configurationCommands` / `configurationEvents` and their generated sum types.

## Command-handler validation

`Domain.Configuration.CommandHandler`. Tree helpers are derived from the flat
`[DictionaryEntry]` via the `parentId` adjacency (children, descendants, depth,
subtree height). A `maxDictionaryDepth = 2` constant lives beside them (root
nodes are level 1). Bumping this to 3 later — with the group-under-group rule
relaxed — is the whole "extend to 3" change.

New constructors on the **aggregate-local** `ConfigurationError` in
`CommandHandler.hs` (the simple-constructor type alongside the existing remove
guards, not the context-carrying `Domain.Configuration.Errors` type):
`ParentEntryNotFound`, `ParentNotAGroup`, `MoveWouldCreateCycle`,
`MaxDepthExceeded`, `GroupNotEmpty`. Each is translated to its
`Domain.Core.Errors.DomainError` counterpart at the service boundary, exactly as
the existing aggregate errors are.

- **AddDictionaryEntry**: config created; if `parentId = Just p`, `p` exists in
  the same dictionary (else `ParentEntryNotFound`) **and `p` is a group** (else
  `ParentNotAGroup`); sibling-name unique under `parentId` (else
  `DuplicateEntryName`); `depth(parent) + 1 ≤ 2` (else `MaxDepthExceeded`) — with
  depth 2 this means a group may be added only at root. Item-under-item is
  impossible because the parent must be a group.
- **MoveDictionaryEntry**: config created; entry exists (else `EntryNotFound`);
  if `newParentId = Just p`, `p` exists in the same dictionary (else
  `ParentEntryNotFound`) **and is a group** (else `ParentNotAGroup`);
  **cycle-free** — `p` must not be the entry itself or a descendant of it (else
  `MoveWouldCreateCycle`); resulting subtree fits —
  `depth(newParent) + height(subtree rooted at entry) ≤ 2` (else
  `MaxDepthExceeded`); sibling-name unique under the new parent (else
  `DuplicateEntryName`).
- **RemoveDictionaryEntry**: keep existing guards — cannot empty a required
  dictionary (`CannotRemoveLastEntry`), not a global default
  (`EntryIsGlobalDefault`), not referenced in the MCC map (`EntryIsInMccMap`) —
  **plus reject if the group has children** (`GroupNotEmpty`).
- **RenameDictionaryEntry**: unchanged apart from kind key + sibling-scoped
  duplicate check.

`requiresNonEmpty` re-keys onto `IncomeKind` / `ExpenseKind`
(pattern match on the kind, no more text literals).

## Projection

`Domain.Configuration.Projection`: `dictionaries :: Map DictionaryKind Dictionary`.

- `DictionaryEntryAdded` stores `role` and `parentId` on the new `DictionaryEntry`.
- **New** `DictionaryEntryMoved` handler updates the targeted entry's `parentId`
  (role is immutable — a move never changes it).
- Rename/remove handlers unchanged apart from the key type.

The projection keeps the flat list; the tree stays derived.

## Transaction-side validation

`Application.Services.TransactionService`:

- Migrate `pickCategoryDict` and `dictionaryEntryIds` to `DictionaryKind`.
- Add a reusable domain predicate — **structural, no kind parameter** (ADR 002):

  ```haskell
  entryAssignable :: DictionaryEntry -> Bool
  entryAssignable entry = case entry.role of
    ItemRole  -> True
    GroupRole -> False
  ```

  Items are always assignable; groups never are — uniformly across all kinds.

Because the rule is structural, it applies to income/expense **now**, not only
to contacts: an allocation may reference only items. Whether this is enforced on
the server or surfaced for the client to gate the picker is settled per ADR 002 —
land the predicate with property coverage; wiring it into allocation validation
is safe (no transition hazard, since roles are immutable) and no longer blocked
on rollup reporting.

## Defaults / ConfigurationService (drop id literals)

- `Domain.Configuration.Defaults`: `incomeCategoryDictId` / `expenseCategoryDictId`
  → the kinds. `mkDeterministicEntryId :: DictionaryKind -> Text -> CategoryId`
  keys off the kind (its derived tag), producing a one-time reseed of default
  category ids. `defaultMccExpenseCategoryMap` follows automatically (derived
  from the reseeded ids).
- `Application.Services.ConfigurationService`: drop the `labelsDictId = DictionaryId "labels"`
  literal and the income/expense wiring in favour of kinds; `addDictionaryEntry`
  / `renameDictionaryEntry` / `removeDictionaryEntry` signatures take
  `DictionaryKind`; `addDictionaryEntry` gains `parentId`; **add
  `moveDictionaryEntry`**.
- `Telegram.Commands.getCategoryEntries` migrates to `DictionaryKind`.

## Read model & DTO — server materialises the tree

`Application.ReadModels.Configuration`, `Web.API.ConfigurationAPI`.

Read-model storage stays **flat**:

- `configuration_dictionary_entries` table: column `dictionaryId → dictionaryKind`
  (`DictionaryKind` PersistField), **plus `role EntryRole`** and
  **`parentId DictionaryEntryId Maybe`**. The read model rebuilds from events, so
  no data migration is needed under the no-backward-compat phase.
- `DictionaryData` carries `role` and `parentId` per entry internally.

The DTO returns a **nested tree per dictionary** (built server-side; the client
renders it directly, no assembly, no `parentId` juggling):

```
dictionary = { roots :: [Node] }
Node = { entryId, name, role :: "group" | "item", children :: [Node] }
```

Each node carries its `role` **explicitly** (ADR 002): the per-dictionary
`groupsAssignable` field is **gone**, and role cannot be inferred from
`children` because an **empty group** has none yet is still a non-assignable
container. `role` is what the client gates the picker on (items pickable, groups
expand-only). Items never carry `children`. Sibling order within `children` is
insertion order (see out-of-scope).

API surface:

- `GET` configuration returns the nested tree shape above.
- The add endpoint accepts an optional `parentId`.
- A **new move endpoint** (`PATCH .../dictionaries/{kind}/entries/{id}/parent`
  with `{ newParentId }`) issues `MoveDictionaryEntry`.
- Dictionary path param parses text → `DictionaryKind` via `parseDictionaryKind`;
  an unrecognised slug returns 404 (no more "unknown dictionary id" domain
  error path).

## Out of scope / noted

- **Sibling ordering** — insertion order only; explicit sort keys deferred
  (per the issue's open question).
- **Web client** tree picker / drag-reparent management UI — follow-up in
  `../monorepo`.
- **No eventium change** — the tree is dictionary-domain-specific; there is no
  generic event-sourcing machinery to push down into the library here.
- **Per-entry typed metadata** — deferred to #41. When a kind needs structured
  metadata (Contacts: phone/email/IBAN/…), the idiomatic representation in this
  architecture is a **closed `EntryMetadata` sum** carried on `DictionaryEntry`
  (a literal `Dictionary t` type parameter does not compose with the single
  `Map DictionaryKind Dictionary` aggregate, the TH-generated event/command sum
  types, or their JSON — the aggregate must persist a concrete representation
  regardless). Per-kind typing is then an enforced invariant
  (`metadataMatchesKind :: DictionaryKind -> EntryMetadata -> Bool`) plus a
  `SetDictionaryEntryMetadata` command/event. Building it now — with no kind
  consuming it — would be speculative; the no-backward-compat phase makes adding
  the field to the entry/event shape in #41 a clean reshape rather than a
  migration. The tree/kind shapes introduced here are the extension point.

## Testing

- **Property** (`*PropertySpec.hs`): cycle-free invariant on `MoveDictionaryEntry`
  (a move onto a descendant is always rejected); depth-limit invariant (no
  accepted add/move produces a tree deeper than 2); `entryAssignable` — items
  always assignable, groups never (structural, immutable role); sibling-name
  uniqueness; **role immutability** (no command changes an entry's role).
- **Unit** (`*Spec.hs`): each new command-handler rejection —
  `ParentEntryNotFound`, `ParentNotAGroup`, `MoveWouldCreateCycle`,
  `MaxDepthExceeded`, `GroupNotEmpty` — with correct error and preserved state;
  add-under-item rejected; sibling-scoped duplicate-name accept/reject.
- **Integration** (`*IntegrationSpec.hs`): add root → add child → move subtree →
  project, asserting the derived tree and the materialised DTO shape.

Reuse `test/Testkit/*` fixtures/generators; add generic helpers there rather
than per-spec one-offs.

## Affected files (survey)

- `src/Domain/Configuration/Dictionary.hs` — the whole dictionary domain model in one
  home: `DictionaryKind` + slug helpers (`dictionaryKindSlug`,
  `parseDictionaryKind`); `EntryRole` (`GroupRole | ItemRole`); `role` +
  `parentId` on `DictionaryEntry`; the `Dictionary` collection; the structural
  `entryAssignable :: DictionaryEntry -> Bool` beside it; the derived
  `DictionaryNode` tree ADT and name-path helpers. (`groupsAssignable` and the
  kind-parameterised `entryAssignable` were dropped — assignability no longer
  depends on the kind. The data model was consolidated here from
  `Domain.Core.Types`, which retains only the shared
  `DictionaryEntryId`/`EntryName` primitives; `DictionaryKind` was later folded
  in from its own `Domain.Core.DictionaryKind` module. Callers needing both
  `DictionaryKind` and `TransactionKind` — whose `IncomeKind`/`ExpenseKind`
  constructors clash — qualify this module.)
- `src/Domain/Core/Types.hs` — remove `DictionaryId`.
- `src/Domain/Configuration/{Commands,Events,CommandHandler,Projection,Defaults,Errors}.hs`
  (add `role` to add-command/event; `ParentNotAGroup`; `maxDictionaryDepth = 2`)
- `src/Application/Services/{ConfigurationService,TransactionService}.hs`
  (incl. `copyDictionaries`, which re-keys `Map DictionaryId DictionaryData`)
- `src/Application/Services/Prompt/Transaction/Handler.hs` — imports and uses
  `DictionaryId` in a function signature; migrate to `DictionaryKind`.
- `src/Application/ReadModels/Configuration.hs`
- `src/Web/API/ConfigurationAPI.hs`
- `src/Infrastructure/Database/Orphans.hs`
- `src/Telegram/Commands.hs`
- `test/…` (Configuration + Transaction specs, Testkit generators/fixtures)
