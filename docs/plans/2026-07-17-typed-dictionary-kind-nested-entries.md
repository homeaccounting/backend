# Typed `DictionaryKind` + Nested Dictionary Entries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stringly-typed `DictionaryId` with a closed `DictionaryKind`, give dictionary entries an adjacency-list parent reference so they form a tree, add a `MoveDictionaryEntry` command, enforce cycle-free / bounded-depth / group-removal rules, and surface a server-materialised nested tree in the read model & API. Unblocks tracker#41 (Contacts).

**Architecture:** CQRS + event sourcing on the Configuration aggregate. Domain stays pure (`Either DomainError`/aggregate-local errors); the tree is *derived* from a flat `parentId` adjacency, never stored as nesting. `groupsSelectable` and depth/cycle rules are pure functions/invariants, not stored fields. The read model persists flat rows (`+ parentId` column) and the DTO layer builds the nested tree.

**Tech Stack:** GHC 9.10, RIO prelude, Servant, Persistent/PostgreSQL, Eventium (TH-generated command/event sum types), Hspec + QuickCheck, LiquidHaskell refinements on domain types.

**Spec:** `docs/specs/2026-07-17-typed-dictionary-kind-nested-entries-design.md`

---

## Conventions for every task

- Enter the Nix shell once: `nix develop` (gives `just`, `cabal`, `ormolu`, `hlint`).
- After each task: `just format && just lint`, then the task's build/test command.
- Definitive build check (warm `.o` cache can mask `-Werror`): `just rebuild` at the end of a task that changed many modules.
- Integration tests need the `eventium_test` Postgres DB (`just docker-up` does **not** create it — create it once manually). Pure unit/property specs do not.
- Commit messages follow Conventional Commits; scope `configuration` (or `configuration,transaction` where both move).
- Never export data constructors/field selectors directly — the modules already re-export via smart constructors/accessors; follow suit.
- `just build`/`just test` pass `-fci` (`-Werror`). Occasional spurious `Cabal-7125`/`-j` failures — re-run once before treating as real.

## File structure (what changes and why)

| File | Responsibility after change |
|------|------------------------------|
| `src/Domain/Core/DictionaryKind.hs` (NEW) | `DictionaryKind`, `groupsSelectable`, `dictionaryKindSlug`, `parseDictionaryKind`, and (Task 5) `entryAssignable`. Lives in its own module because `IncomeKind`/`ExpenseKind` collide with `TransactionKind`'s constructors declared in `Domain.Core.Types` — a same-module declaration clash. |
| `src/Domain/Core/Types.hs` | Add `parentId` to `DictionaryEntry`; **delete** `DictionaryId`/`unDictionaryId`. |
| `src/Infrastructure/Database/Orphans.hs` | `PersistField`/`PersistFieldSql` for `DictionaryKind` (replaces `DictionaryId`'s), via the slug. |
| `src/Domain/Configuration/Commands.hs` | Commands key on `dictionaryKind`; `AddDictionaryEntry` gains `parentId`; **new** `MoveDictionaryEntry`. |
| `src/Domain/Configuration/Events.hs` | Events mirror commands; **new** `DictionaryEntryMoved`. |
| `src/Domain/Configuration/CommandHandler.hs` | Tree helpers (children/descendants/depth/height), new guards + errors, sibling-scoped duplicate check, `Move` handler. |
| `src/Domain/Configuration/Projection.hs` | `Map DictionaryKind Dictionary`; store `parentId`; `DictionaryEntryMoved` handler. |
| `src/Domain/Configuration/Defaults.hs` | Kinds instead of id literals; `mkDeterministicEntryId` keys off kind (reseed). |
| `src/Domain/Configuration/Errors.hs` | Context-carrying `ConfigurationError` re-keyed to `DictionaryKind`. |
| `src/Application/Services/ConfigurationService.hs` | Kind-typed dictionary ops; `moveDictionaryEntry`; `copyDictionaries` re-key. |
| `src/Application/Services/TransactionService.hs` | `pickCategoryDict`/`dictionaryEntryIds` on kinds. |
| `src/Application/Services/BankImportService.hs` | Swap `incomeCategoryDictId`/`expenseCategoryDictId` usages to the renamed `*Kind` exports. |
| `src/Application/Services/Prompt/Transaction/Handler.hs` | Migrate `DictionaryId` signature to `DictionaryKind`. |
| `src/Telegram/Commands.hs` | `getCategoryEntries` on `DictionaryKind`. |
| `src/Application/ReadModels/Configuration.hs` | `dictionaryKind` + `parentId` columns; `DictionaryData` carries `parentId`; store/move handlers. |
| `src/Web/API/ConfigurationAPI.hs` | Parse slug→kind; nested-tree DTO + `groupsSelectable`; `parentId` on add; move endpoint. |
| `test/**` | Property/unit/integration specs; Testkit generators/fixtures. |

## Task ordering rationale

Task 1 is an **atomic structural migration** — deleting `DictionaryId` breaks the whole program, so it is one coherent change that ends green (build + existing tests). Tasks 2–8 then add new *behavior* test-first on top of the migrated shape.

---

### Task 1: Structural migration — `DictionaryKind` + `parentId` (compile-breaking sweep, ends green)

One logical change: the codebase speaks `DictionaryKind` and every `DictionaryEntry` has a `parentId :: Maybe DictionaryEntryId` (defaulting to `Nothing`). No new commands/endpoints yet. Includes the **sibling-scoped duplicate-name** behavior change and the **deterministic-id reseed**, because both live in files touched here.

**Files:** all rows in the table above except the `Move`/tree-guard/DTO-tree specifics (those are Tasks 2–8). Test files that reference `DictionaryId`/`DictionaryEntry` constructors.

- [ ] **Step 1: Add `DictionaryKind` to `Domain/Core/Types.hs`**

Replace the `DictionaryId` block (`src/Domain/Core/Types.hs:665-683`) with:

```haskell
-- -----------------------------------------------------------------------------
-- Dictionary Kind
-- -----------------------------------------------------------------------------

-- | The closed, code-defined set of dictionaries. There is no user-created
-- dictionary, so this is a sum type rather than a free-text id.
data DictionaryKind
  = IncomeKind
  | ExpenseKind
  | LabelKind
  | ContactKind
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- | Whether a group (a node with children) is itself a valid selectable value.
-- Fully determined by the kind and uniform across the whole dictionary; never
-- stored (storing it beside the kind would allow the two to contradict).
groupsSelectable :: DictionaryKind -> Bool
groupsSelectable ContactKind = False
groupsSelectable _ = True

-- | Wire/persistence slug, DERIVED from the constructor: drop the "Kind"
-- suffix and lowercase, inserting '-' before each interior capital.
-- IncomeKind -> "income", ExpenseKind -> "expense", LabelKind -> "label",
-- ContactKind -> "contact". Single source of truth; adding a kind cannot drift
-- its slug. (No multi-word kinds exist yet, so kebab-casing is a no-op today,
-- but the helper handles them for future kinds.)
dictionaryKindSlug :: DictionaryKind -> Text
dictionaryKindSlug = T.pack . kebab . stripKindSuffix . show
  where
    stripKindSuffix s = fromMaybe s (stripSuffix "Kind" s)
    kebab [] = []
    kebab (c : cs) = toLower c : concatMap (\x -> if isUpper x then ['-', toLower x] else [x]) cs

-- | Parse a slug back to its kind. Total over the closed set; 'Nothing' for
-- an unknown slug (surfaces as a 404 at the API boundary).
parseDictionaryKind :: Text -> Maybe DictionaryKind
parseDictionaryKind t =
  find (\k -> dictionaryKindSlug k == t) [minBound .. maxBound]

instance ToJSON DictionaryKind where
  toJSON = toJSON . dictionaryKindSlug

instance FromJSON DictionaryKind where
  parseJSON = withText "DictionaryKind" $ \t ->
    maybe (fail ("unknown DictionaryKind: " <> show t)) pure (parseDictionaryKind t)
```

Add imports if missing: `find` (`RIO`/`Data.List`), `withText` (`Data.Aeson`),
`stripSuffix` (`Data.List`), `toLower`/`isUpper` (`RIO.Char`/`Data.Char`). Export
`DictionaryKind (..)`, `groupsSelectable`, `dictionaryKindSlug`,
`parseDictionaryKind`; remove `DictionaryId (..)`, `unDictionaryId`.

> **Naming note:** `IncomeKind`/`ExpenseKind` collide with `TransactionKind`'s
> same-named constructors. In the two modules that use both — `TransactionService.hs`
> and `Prompt/Transaction/Resolve.hs` — import `DictionaryKind`'s constructors
> qualified (e.g. `import qualified Domain.Core.Types as Dict` → `Dict.IncomeKind`)
> or import the transaction ones qualified; pick whichever touches fewer sites.

- [ ] **Step 2: Add `parentId` to `DictionaryEntry`**

`src/Domain/Core/Types.hs:730-735`:

```haskell
-- | A single dictionary entry / tree node. @parentId = Nothing@ is a root node;
-- otherwise it names the containing group (adjacency list). A "group" is
-- emergent — any node that has children — not a distinct type.
data DictionaryEntry = DictionaryEntry
  { entryId :: DictionaryEntryId,
    name :: EntryName,
    parentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq, Generic)
```

- [ ] **Step 3: `PersistField` for `DictionaryKind`** in `src/Infrastructure/Database/Orphans.hs:335-341`

Replace the `DictionaryId` instances with:

```haskell
-- | 'DictionaryKind' persists as its stable slug text.
instance PersistField DictionaryKind where
  toPersistValue = toPersistValue . dictionaryKindSlug
  fromPersistValue v = do
    t <- fromPersistValue v
    maybe (Left ("Invalid DictionaryKind: " <> t)) Right (parseDictionaryKind t)

instance PersistFieldSql DictionaryKind where
  sqlType _ = SqlString
```

Update the import from `Domain.Core.Types` (`DictionaryId` → `DictionaryKind`, `dictionaryKindSlug`, `parseDictionaryKind`).

- [ ] **Step 4: Migrate Commands & Events (kind key + `parentId` on add)** — `Commands.hs`, `Events.hs`

In both, change the `Domain.Core.Types` import `DictionaryId` → `DictionaryKind`. In `AddDictionaryEntry`/`DictionaryEntryAdded`, `RenameDictionaryEntry`/`DictionaryEntryRenamed`, `RemoveDictionaryEntry`/`DictionaryEntryRemoved`: rename field `dictionaryId :: DictionaryId` → `dictionaryKind :: DictionaryKind`. Add `parentId :: Maybe DictionaryEntryId` to `AddDictionaryEntry` **and** `DictionaryEntryAdded` (place after `name`). Leave the `deriveJSON`/`configurationCommands`/`configurationEvents` lists as-is (no new type yet — that's Task 2).

- [ ] **Step 5: Migrate the projection** — `Projection.hs`

- `Configuration.dictionaries :: Map DictionaryKind Dictionary` (`:179`), import `DictionaryKind` not `DictionaryId`.
- `DictionaryEntryAdded` handler (`:281-291`) constructs `DictionaryEntry {entryId, name, parentId}` and keys `Map.alter` on `dictionaryKind`.
- Rename/remove handlers key on `dictionaryKind`; rename preserves `parentId` (`DictionaryEntry {entryId = entry.entryId, name = n, parentId = entry.parentId}`).

- [ ] **Step 6: Migrate `CommandHandler.hs` (sibling-scoped duplicates; kind keys)**

- Imports: `DictionaryKind` not `DictionaryId (..)`.
- `dictionaryExists`, `entryExists`, `requireEntryIn` take `DictionaryKind`.
- Replace `hasDuplicateName` with sibling-scoped:

```haskell
-- | True if a sibling (same parent) in the dictionary already has this name.
-- @exclude@ skips a specific entry (used by rename so a no-op rename passes).
hasDuplicateSiblingName ::
  EntryName -> Maybe DictionaryEntryId -> Maybe DictionaryEntryId -> DictionaryKind -> Configuration -> Bool
hasDuplicateSiblingName ename parent exclude kind config =
  case Map.lookup kind config.dictionaries of
    Nothing -> False
    Just dict ->
      any
        (\e -> e.name == ename && e.parentId == parent && Just e.entryId /= exclude)
        dict.entries
```

- `requiresNonEmpty :: DictionaryKind -> Bool` matches `IncomeKind`/`ExpenseKind` → `True`, else `False`.
- Update the `AddDictionaryEntry`/`Rename`/`Remove` handler branches to the new field names and the new duplicate check (Add: `hasDuplicateSiblingName name parentId Nothing dictionaryKind`; Rename: `hasDuplicateSiblingName newName <lookup entry's parent> (Just entryId) dictionaryKind`). Emit events with `dictionaryKind`/`parentId`. **Depth/parent-exists/cycle guards are Task 3 — do not add them here.**
- `SetDefaultIncomeCategory`/`Expense`/`MccMap` branches use the new `incomeCategoryDictKind`/`expenseCategoryDictKind` from `Defaults` (Step 8).

- [ ] **Step 7: Migrate `Errors.hs`** — re-key the context-carrying `ConfigurationError`

Change the `DictionaryId` import → `DictionaryKind`; in `DictionaryNotFound`, `EntryNotFound`, `DuplicateEntryName`, `CannotRemoveLastEntry` replace the `DictionaryId` field/param types with `DictionaryKind`; update the `mk*` constructor signatures accordingly.

- [ ] **Step 8: Migrate `Defaults.hs` (reseed)**

- Rename `incomeCategoryDictId`/`expenseCategoryDictId` → `incomeCategoryDictKind = IncomeKind` / `expenseCategoryDictKind = ExpenseKind` (`:70-74`); import `DictionaryKind (..)` not `DictionaryId (..)`.
- Re-type `mkDeterministicEntryId :: DictionaryKind -> Text -> CategoryId`, keying off the kind's tag (reseed accepted):

```haskell
mkDeterministicEntryId :: DictionaryKind -> Text -> CategoryId
mkDeterministicEntryId kind entryNameText =
  unsafeDictionaryEntryId
    $ UUID5.generateNamed configNamespace
    $ BS.unpack (encodeUtf8 (tshow kind <> ":" <> entryNameText))
```

- `mkExpense`/`mkIncome` pass the kinds. Update the module export list names.

- [ ] **Step 9: Migrate `ConfigurationService.hs`**

- `labelsDictId :: DictionaryId = DictionaryId "labels"` → `labelsDictKind :: DictionaryKind = LabelKind` (`:184-185`).
- `addDictionaryEntry`/`renameDictionaryEntry`/`removeDictionaryEntry` signatures take `DictionaryKind`; `addDictionaryEntry` gains a `Maybe DictionaryEntryId` parent param, passed into the command's `parentId`. (New `moveDictionaryEntry` is Task 7.)
- `removeDictionaryEntry`'s label-vs-category branch compares against `labelsDictKind`.
- `copyDictionaries :: UUID -> Map DictionaryKind DictionaryData -> AppM ()` (`:912`) — re-key.
- Update the `Domain.Core.Types` import.

- [ ] **Step 10: Migrate `TransactionService.hs` (type-only here)**

`dictionaryEntryIds :: DictionaryKind -> ConfigurationData -> Set DictionaryEntryId` and `pickCategoryDict :: TransactionType -> Maybe DictionaryKind` (`:1151,1159`) use `ConfigurationService.incomeCategoryDictKind`/`expenseCategoryDictKind`. `validateAllocationsAgainstDictionary` unchanged apart from the kind names. (`entryAssignable` is Task 5.)

- [ ] **Step 11: Migrate `Prompt/Transaction/Handler.hs`, `Telegram/Commands.hs`, `BankImportService.hs`**

Change each `DictionaryId` import + signature (`Handler.hs:58,118`; `Telegram/Commands.hs:87,842`) to `DictionaryKind`; callers pass the kind. In `BankImportService.hs` (import `:59`, uses `:367-368,:417-418`) swap `incomeCategoryDictId`/`expenseCategoryDictId` to the renamed `incomeCategoryDictKind`/`expenseCategoryDictKind` from `Defaults`.

- [ ] **Step 12: Migrate the read model** — `Application/ReadModels/Configuration.hs`

- `ConfigDictionaryEntryEntity` (`:183-189`): `dictionaryId DictionaryId` → `dictionaryKind DictionaryKind`; add `parentId DictionaryEntryId Maybe`. Keep `UniqueConfigDictEntry configId dictionaryKind entryId`.
- `DictionaryData` (`:157-161`): carry parent per entry. Use `newtype DictionaryData = DictionaryData { entries :: Map DictionaryEntryId (EntryName, Maybe DictionaryEntryId) }`.
- `ConfigurationData.dictionaries :: Map DictionaryKind DictionaryData` (`:142`).
- Event handlers (`:283-304`): `DictionaryEntryAddedEvent` upserts `ConfigDictionaryEntryEntity configId evt.dictionaryKind evt.entryId evt.name evt.parentId` (and sets `...ParentId =. evt.parentId` in the update list); rename/remove filter on `...DictionaryKind ==. evt.dictionaryKind`.
- `loadDictionaries :: ... -> SqlPersistT m (Map DictionaryKind DictionaryData)` (`:416-426`): build `(name, parentId)` values; `mergeDict` unions the inner maps.
- Update imports (`DictionaryId` → `DictionaryKind`).

- [ ] **Step 13: Migrate the API to compile (flat DTO, slug parse — no tree yet)** — `Web/API/ConfigurationAPI.hs`

- Add a helper that resolves a slug to a kind or 404s:

```haskell
requireDictionaryKind :: Text -> AppM DictionaryKind
requireDictionaryKind t =
  maybe (throwDomainError (NotFound "Dictionary" t)) pure (parseDictionaryKind t)
```

- `listDictionaryHandler`/`addEntryHandler`/`renameEntryHandler`/`removeEntryHandler` (`:712-764`): replace `let dictId = DictionaryId dictIdText` with `dictKind <- requireDictionaryKind dictIdText`, pass `dictKind`. `addEntryHandler` passes `Nothing` parent for now (parentId param is Task 7). Adapt `Map.toList dictData.entries` to the new `(name, parentId)` value (ignore parentId here; tree DTO is Task 8) so it compiles.
- `toConfigurationResponse` (`:920-922`): `Map.mapKeys dictionaryKindSlug` instead of `unDictionaryId`.
- `toDictionaryResponse` (`:955-962`): adapt to the `(EntryName, Maybe _)` value shape (project the name for now).
- Update imports (`DictionaryId (..)`/`unDictionaryId` → `DictionaryKind`, `dictionaryKindSlug`, `parseDictionaryKind`).

- [ ] **Step 14: Fix tests to the new shapes**

Update every test constructing `DictionaryEntry {...}` (add `parentId = Nothing`), referencing `DictionaryId`/`incomeCategoryDictId`/etc., or asserting the old dictionary-wide duplicate behavior. In Testkit (`test/Testkit/Generators.hs`, `Fixtures.hs`, `Helpers.hs`): the `DictionaryEntry` generator emits `parentId = Nothing`; any `DictionaryId` helpers become `DictionaryKind`. Search: `grep -rn "DictionaryId\|incomeCategoryDictId\|expenseCategoryDictId\|labelsDictId" test/ src/`.

- [ ] **Step 15: Add the sibling-scoped duplicate unit test (behavior change)**

In the Configuration command-handler spec, add: adding `"Other"` under parent A succeeds even when `"Other"` exists under parent B (previously rejected dictionary-wide); adding a second `"Other"` under the *same* parent fails `DuplicateEntryName`. (Uses only Task-1 machinery.)

- [ ] **Step 16: Build + test green, format, lint, commit**

```
just rebuild
just test
just check
```
Expected: PASS (bar the known environmental `eventium_test` failures if that DB is absent). Then:
```
git add -A
git commit -m "refactor(configuration)!: typed DictionaryKind + entry parentId; sibling-scoped name uniqueness (tracker#42)"
```

---

### Task 2: `MoveDictionaryEntry` / `DictionaryEntryMoved`

**Files:** `Commands.hs`, `Events.hs`, `CommandHandler.hs`, `Projection.hs`, read model + API compile only where the new event's sum-type match is required; **Test:** `test/Domain/Configuration/*Spec.hs`.

- [ ] **Step 1: Write the failing projection test**

In the Configuration projection spec: applying `DictionaryEntryAdded` (root) then `DictionaryEntryMoved` to a new parent yields an entry whose `parentId == Just newParent`.

- [ ] **Step 2: Run it — expect FAIL** (`DictionaryEntryMoved` not in scope)

`cabal test all --test-option='--match' --test-option="/Configuration/Projection/"`

- [ ] **Step 3: Add the command + event types**

`Commands.hs`: add to `configurationCommands` list `''MoveDictionaryEntry`, the type, and `deriveJSON`:

```haskell
data MoveDictionaryEntry = MoveDictionaryEntry
  { dictionaryKind :: DictionaryKind,
    entryId :: DictionaryEntryId,
    newParentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq)
```

`Events.hs`: same for `DictionaryEntryMoved` (fields identical) + `configurationEvents` + `deriveJSON`. Export both.

- [ ] **Step 4: Projection handler**

`Projection.hs`: import `DictionaryEntryMoved (..)`; add handler that, for the entry in `dictionaryKind`, sets `parentId = evt.newParentId`:

```haskell
handleConfigurationEvent config (DictionaryEntryMovedConfigurationEvent DictionaryEntryMoved {..}) =
  let reparent e
        | e.entryId == entryId = DictionaryEntry {entryId = e.entryId, name = e.name, parentId = newParentId}
        | otherwise = e
   in config {dictionaries = Map.adjust (\d -> d {entries = map reparent d.entries}) dictionaryKind config.dictionaries}
```

- [ ] **Step 5: Minimal handler branch (no guards yet)**

`CommandHandler.hs`: emit `DictionaryEntryMoved` when entry exists (reuse `entryExists`); guards come in Task 3. Add the branch so the sum type is total.

- [ ] **Step 6: Read model + API totality**

`ReadModels/Configuration.hs`: add `DictionaryEntryMovedEvent` handler — `updateWhere [...ConfigId, ...DictionaryKind, ...EntryId] [ConfigDictionaryEntryEntityParentId =. evt.newParentId]`. `ConfigurationAPI.hs`/anywhere matching the event sum type exhaustively: add the case.

- [ ] **Step 7: Run the test — expect PASS**, then `just format && just lint`.

- [ ] **Step 8: Commit** — `feat(configuration): MoveDictionaryEntry/DictionaryEntryMoved command+event (tracker#42)`

---

### Task 3: Tree guards — parent-exists, cycle-free, bounded depth

**Files:** `CommandHandler.hs`; **Test:** `test/Domain/Configuration/ConfigurationCommandHandlerSpec.hs` + a new `*PropertySpec.hs`.

- [ ] **Step 1: Failing unit tests** for each rejection:
  - Add with `parentId = Just <absent>` → `Left ParentEntryNotFound`.
  - Add a 5th level under a 4-deep chain → `Left MaxDepthExceeded`.
  - Move an entry onto its own descendant → `Left MoveWouldCreateCycle`.
  - Move onto self → `Left MoveWouldCreateCycle`.
  - Move a subtree of height 2 under a level-3 parent → `Left MaxDepthExceeded`.

- [ ] **Step 2: Run — expect FAIL** (constructors/guards absent).

- [ ] **Step 3: Add error constructors** to the **aggregate-local** `ConfigurationError` (`CommandHandler.hs:58-80`): `ParentEntryNotFound`, `MoveWouldCreateCycle`, `MaxDepthExceeded`, `GroupNotEmpty`.

- [ ] **Step 4: Add tree helpers + constant** in `CommandHandler.hs`:

```haskell
maxDictionaryDepth :: Int
maxDictionaryDepth = 4 -- root nodes are level 1

entriesOf :: DictionaryKind -> Configuration -> [DictionaryEntry]
entriesOf kind config = maybe [] (.entries) (Map.lookup kind config.dictionaries)

lookupEntry :: DictionaryEntryId -> [DictionaryEntry] -> Maybe DictionaryEntry
lookupEntry eid = find (\e -> e.entryId == eid)

childrenOf :: DictionaryEntryId -> [DictionaryEntry] -> [DictionaryEntry]
childrenOf pid = filter (\e -> e.parentId == Just pid)

-- | Depth of a node counting itself: a root node is 1. Bounded by the number
-- of entries so a (pre-existing invariant: acyclic) chain always terminates.
depthOf :: DictionaryEntryId -> [DictionaryEntry] -> Int
depthOf eid es = go (length es) eid
  where
    go 0 _ = maxBound -- defensive: corrupt cycle in stored data
    go fuel x = case lookupEntry x es >>= (.parentId) of
      Nothing -> 1
      Just p -> 1 + go (fuel - 1) p

-- | All transitive descendants of a node (excludes the node itself).
descendantsOf :: DictionaryEntryId -> [DictionaryEntry] -> [DictionaryEntryId]
descendantsOf eid es =
  let kids = map (.entryId) (childrenOf eid es)
   in kids <> concatMap (\k -> descendantsOf k es) kids

-- | Height of the subtree rooted at a node counting itself: a leaf is 1.
subtreeHeight :: DictionaryEntryId -> [DictionaryEntry] -> Int
subtreeHeight eid es = case childrenOf eid es of
  [] -> 1
  kids -> 1 + maximum (map (\k -> subtreeHeight k.entryId es) kids)
```

- [ ] **Step 5: Wire guards into `AddDictionaryEntry`** (after the duplicate check):

```haskell
  | Just p <- parentId, isNothing (lookupEntry p (entriesOf dictionaryKind config)) = Left ParentEntryNotFound
  | parentDepth + 1 > maxDictionaryDepth = Left MaxDepthExceeded
```

where `parentDepth = maybe 0 (\p -> depthOf p (entriesOf dictionaryKind config)) parentId`.

- [ ] **Step 6: Wire guards into `MoveDictionaryEntry`** (replace Task-2's minimal branch):

```haskell
  | not (entryExists entryId dictionaryKind config) = Left EntryNotFound
  | Just p <- newParentId, isNothing (lookupEntry p es) = Left ParentEntryNotFound
  | Just p <- newParentId, p == entryId || p `elem` descendantsOf entryId es = Left MoveWouldCreateCycle
  | newParentDepth + subtreeHeight entryId es > maxDictionaryDepth = Left MaxDepthExceeded
  | hasDuplicateSiblingName entryName newParentId (Just entryId) dictionaryKind config = Left DuplicateEntryName
```
with `es = entriesOf dictionaryKind config`, `newParentDepth = maybe 0 (\p -> depthOf p es) newParentId`, and `entryName` looked up from the moved entry.

- [ ] **Step 7: Property spec** (`test/Domain/Configuration/ConfigurationTreePropertySpec.hs`, hspec-discover picks it up):
  - Generate an acyclic dictionary + a random `(entry, newParent)`; assert: if `newParent ∈ {entry} ∪ descendants(entry)` the move is `Left MoveWouldCreateCycle`.
  - Assert no accepted `Add`/`Move` ever yields a tree with `depthOf` any node `> 4`.
  Reuse/extend a Testkit tree generator (add to `test/Testkit/Generators.hs`).

- [ ] **Step 8: Run all — expect PASS**; `just format && just lint`.

- [ ] **Step 9: Commit** — `feat(configuration): cycle-free + bounded-depth + parent-exists guards for dictionary tree (tracker#42)`

---

### Task 4: Reject removal of a non-empty group

**Files:** `CommandHandler.hs`; **Test:** command-handler spec.

- [ ] **Step 1: Failing test** — `RemoveDictionaryEntry` on an entry that has children → `Left GroupNotEmpty`; removing a leaf still succeeds.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Add guard** to the `RemoveDictionaryEntry` branch, before the emit:
  `| not (null (childrenOf entryId (entriesOf dictionaryKind config))) = Left GroupNotEmpty`
- [ ] **Step 4: Run — expect PASS**; format, lint.
- [ ] **Step 5: Commit** — `feat(configuration): reject removing a non-empty dictionary group (tracker#42)`

---

### Task 5: `entryAssignable` predicate (transaction-side seam)

**Files:** `src/Domain/Core/DictionaryKind.hs` (predicate beside `groupsSelectable` — this module was split out from `Types.hs` in Task 1); **Test:** `test/Domain/Core/*PropertySpec.hs`. (Nothing to change in `TransactionService.hs` — the predicate is deliberately *not* wired into `validateAllocationsAgainstDictionary`; tracker#41 wires it for contacts.)

Rationale: categories are group-selectable, so allocation validation behavior is unchanged; this lands the reusable predicate + property coverage that tracker#41 wires into contacts. **Do not add a no-op branch to `validateAllocationsAgainstDictionary`.**

- [ ] **Step 1: Failing property test**: for all kinds/entries, `entryAssignable kind hasKids == (groupsSelectable kind || not hasKids)`; specifically a group under `ContactKind` is not assignable, a group under `ExpenseKind` is, leaves always are.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** in `Domain/Core/DictionaryKind.hs` (export it):

```haskell
-- | Whether an entry may be attached to a transaction. Leaves are always
-- assignable; a group (node with children) is assignable iff its kind is
-- group-selectable. @hasChildren@ is supplied by the caller (it depends on the
-- full entry set, which this pure predicate does not carry).
entryAssignable :: DictionaryKind -> Bool -> Bool
entryAssignable kind hasChildren = groupsSelectable kind || not hasChildren
```

- [ ] **Step 4: Run — expect PASS**; format, lint.
- [ ] **Step 5: Commit** — `feat(configuration): entryAssignable predicate for group selectability (tracker#42)`

---

### Task 6: Service + API — parent on add, move endpoint

**Files:** `ConfigurationService.hs`, `Web/API/ConfigurationAPI.hs`; **Test:** an API/service spec if one exists, else covered by Task 8 integration.

- [ ] **Step 1: `moveDictionaryEntry` service fn** in `ConfigurationService.hs`, mirroring `renameDictionaryEntry` but issuing `MoveDictionaryEntryConfigurationCommand MoveDictionaryEntry {dictionaryKind, entryId, newParentId}`. Export it.
- [ ] **Step 2: Add `parentId` to `AddEntryRequest`** (`ConfigurationAPI.hs:444`) as `parentId :: Maybe UUID`; in `addEntryHandler` validate to `Maybe DictionaryEntryId` (`traverse (validateFieldCtx ... . mkDictionaryEntryId)`) and pass to `addDictionaryEntry`.
- [ ] **Step 3: Move route + handler + request DTO.** Add to the API type (near `:189`):

```haskell
    :<|> AuthProtect "jwt" :> "api" :> "users" :> "me" :> "configuration"
      :> "dictionaries" :> Capture "dictId" Text :> "entries" :> Capture "entryId" UUID
      :> "parent" :> ReqBody '[JSON] MoveEntryRequest :> Patch '[JSON] NoContent
```
`data MoveEntryRequest = MoveEntryRequest { newParentId :: Maybe UUID }` (+ JSON). `moveEntryHandler` parses slug→kind, validates ids, calls `ConfigService.moveDictionaryEntry`, returns `NoContent`. Register the handler in the server tuple (match the existing `:<|>` wiring order).
- [ ] **Step 4: Error translation** — ensure the aggregate errors from Task 3/4 map to sensible `DomainError`s (400/409) in `defaultTranslateConfigurationError` / the service translator. Add cases for `ParentEntryNotFound`, `MoveWouldCreateCycle`, `MaxDepthExceeded`, `GroupNotEmpty` (grep the existing translator for `EntryIsGlobalDefault` to find it).
- [ ] **Step 5: `just build`**, format, lint.
- [ ] **Step 6: Commit** — `feat(configuration): add parentId on add + move-entry endpoint (tracker#42)`

---

### Task 7: Read model & API — server-materialised nested tree DTO

**Files:** `Web/API/ConfigurationAPI.hs` (DTO + builders), `Application/ReadModels/Configuration.hs`; **Test:** `test/Web/**` DTO spec (pure) + Task 8 integration.

- [ ] **Step 0 (carried from Task 1 code review): promote `DictionaryData`'s entry value from a tuple to a named record.** In `Application/ReadModels/Configuration.hs`, replace the `Map DictionaryEntryId (EntryName, Maybe DictionaryEntryId)` value with `Map DictionaryEntryId DictionaryEntryValue` where `data DictionaryEntryValue = DictionaryEntryValue { name :: EntryName, parentId :: Maybe DictionaryEntryId }`. Update the `fst`/`snd`/positional destructures at the 4+ call sites (`ConfigurationAPI`, `BankImportService`, `Prompt/Handler`, `Telegram/Commands`) to field access. This makes the tree builder below read cleanly.
- [ ] **Step 1: Failing DTO test** (`test/Web/API/ConfigurationDictionaryTreeSpec.hs`): given a `DictionaryData` with `Food(root)`, `Dining(parent=Food)`, `Groceries(parent=Food)`, the builder returns one root `Food` with two children, `groupsSelectable = True` for `ExpenseKind`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: New DTO shape** in `ConfigurationAPI.hs`:

```haskell
data DictionaryEntryNode = DictionaryEntryNode
  { id :: UUID, name :: Text, children :: [DictionaryEntryNode] }
  deriving (Show, Eq, Generic)

data DictionaryResponse = DictionaryResponse
  { groupsSelectable :: Bool, roots :: [DictionaryEntryNode] }
  deriving (Show, Eq, Generic)
```
(+ JSON instances; drop the old flat `DictionaryEntryResponse`/`entries` or keep the record name but change fields — update all references).

- [ ] **Step 4: Tree builder** — pure function from `(DictionaryKind, DictionaryData)` to `DictionaryResponse`: group entries by `parentId`, build roots (`parentId == Nothing`) recursively via the `Map DictionaryEntryId (EntryName, Maybe DictionaryEntryId)`, set `groupsSelectable = Domain...groupsSelectable kind`. Sibling order = insertion order (see note); since the read-model value is a `Map`, order by nothing stronger than the map's `Ord` on ids — acceptable (ordering is out of scope). Use it in `toConfigurationResponse` (keyed by `dictionaryKindSlug`) and `listDictionaryHandler`.
- [ ] **Step 5: Run — expect PASS**; `just build`, format, lint.
- [ ] **Step 6: Commit** — `feat(configuration): expose nested dictionary tree + groupsSelectable in API (tracker#42)`

---

### Task 8: Integration — add → add child → move → project → DTO

**Files:** `test/**IntegrationSpec.hs` (Configuration). Needs `eventium_test` DB.

- [ ] **Step 1: Failing integration test**: through the real event store + read model — create config, add `Food` (root), add `Dining` under `Food`, `Groceries` under `Food`, move `Dining` under `Groceries`; assert the read-model DTO tree is `Food → Groceries → Dining`, and that moving `Food` under `Dining` is rejected (cycle).
- [ ] **Step 2: Run — expect FAIL** (until wiring complete; if Tasks 1–7 done it may already pass — then it's a characterization test).
- [ ] **Step 3: Fix any gaps surfaced**; format, lint.
- [ ] **Step 4: `just rebuild && just test`** — full green (bar environmental).
- [ ] **Step 5: Commit** — `test(configuration): integration for dictionary tree add/move/project (tracker#42)`

---

### Task 9: Docs + final sweep

- [ ] **Step 1:** Update `docs/architecture.md` Configuration section (dictionaries are now a typed, nested tree) if it describes dictionaries.
- [ ] **Step 2:** Flip the spec frontmatter `status: draft` → `completed`.
- [ ] **Step 3:** `grep -rn "DictionaryId" src test` returns nothing.
- [ ] **Step 4:** `just rebuild && just test && just check` — green.
- [ ] **Step 5: Commit** — `docs(configuration): mark tracker#42 dictionary-tree spec complete`

---

## Verification checklist (before PR)

- [ ] `just rebuild` green (`-Werror`).
- [ ] `just test` green (note any environmental `eventium_test` skips explicitly).
- [ ] `just check` (format + lint) clean.
- [ ] No `DictionaryId` references remain.
- [ ] Property specs cover: cycle-free move, depth ≤ 4, `entryAssignable`, sibling-name uniqueness.
- [ ] Manual: exercise add(parent)/move/remove-group endpoints against a running server (`just run`) per superpowers:verification-before-completion.
- [ ] PR title: `feat(configuration): typed DictionaryKind + nested dictionary entries (tracker#42)`.
