# Structural group/item dictionary entries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the tracker#42 dictionary tree from the emergent/per-kind model (a group is "a node with children"; per-kind `groupsAssignable`; depth 4) to the structural model in [ADR 002](../decisions/002-structural-group-item-dictionary-entries.md): every entry is created as an immutable **group** (container, never assignable) or **item** (leaf, always assignable), only items are assignable, and the tree is capped at **2 levels** by validation (extensible to 3).

**Architecture:** `DictionaryEntry` gains an immutable `role :: EntryRole` (`GroupRole | ItemRole`). Assignability becomes structural (`entryAssignable = role == ItemRole`) — the per-kind `groupsAssignable` is deleted. Persistence stays flat (each entry carries `role` + `parentId`); a new pure domain materialiser `buildDictionaryTree :: [DictionaryEntry] -> [DictionaryNode]` (recursive `GroupNode | ItemNode` ADT) is what the DTO renders. Command-handler validation adds "parent must be a group" (`ParentNotAGroup`) and role-aware depth. Allocation/label validation, Telegram, and the LLM prompt are restricted to items.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude, `NoFieldSelectors`, `OverloadedRecordDot`), Servant, Persistent/Esqueleto, Eventium (event sourcing), Hspec + QuickCheck. Build: `just build`; tests: `just test` (both pass `-fci`/`-Werror`). Formatter `ormolu`, linter `hlint`.

---

## Migration note (read before starting)

Adding a non-optional `role` field to `DictionaryEntry` (and to the Add command/event, read-model value, persistent entity, DTO) breaks **every** construction and pattern-match site at once — Haskell records have no defaults. So the build is **red from Task 2 onward** through the "type-migration phase."

Two things to know about the checkpoints:
- `just build` is `cabal build all -fci` and **`tests: True`** is set (`cabal.project.local`), so `cabal build all` compiles the **test suites too**. The test files aren't reworked until Tasks 14–16, so `just build`/`just test` cannot be green until Task 16.
- Therefore the interim checkpoint at end of Task 13 is a **lib+exe-only** build: `cabal build lib:backend exe:backend -fci`. That proves all production call sites are fixed. The first **full** green (`just build` + `just test`) is at the end of Task 16.

Commit at the Task 13 lib+exe checkpoint, then Tasks 14–16 rework the tests with normal red→green TDD, reaching full green at Task 16.

Work in the existing branch `feat/dictionary-kind-nested-entries` (it already holds the old-model implementation this reworks). Run `ormolu` + `hlint` before every commit (`just check`).

Key current-state facts (verified against the working tree):
- `DictionaryEntry` (`src/Domain/Core/Types.hs:708-718`) has exactly `entryId, name, parentId`. Generic JSON.
- `entryAssignable`/`groupsAssignable` live in `src/Domain/Core/DictionaryKind.hs:41-50`; consumed **only** in `buildDictionaryResponse` (`ConfigurationAPI.hs`) and the `DictionaryKindPropertySpec` tests.
- `maxDictionaryDepth = 4` (`CommandHandler.hs:153-154`); aggregate `ConfigurationError` at `CommandHandler.hs:70-101`.
- DTO `DictionaryResponse { groupsAssignable, roots }` / `DictionaryEntryNode { id, name, children }` at `ConfigurationAPI.hs:431-457`; materialised by `buildDictionaryResponse` (`:1029-1049`).
- Read model: `DictionaryEntryValue { name, parentId }` (`ReadModels/Configuration.hs:167-174`); entity `ConfigDictionaryEntryEntity` (`:196-203`).
- Defaults: `DefaultEntry { entryName, entryId, parentId }` + `mkExpense/mkExpenseChild/mkIncome/mkIncomeChild` (`Defaults.hs:84-105`); group wiring at `:157-211`.

---

## File Structure

**New files**
- `src/Domain/Core/DictionaryTree.hs` — `DictionaryNode` ADT (`GroupNode | ItemNode`) + pure `buildDictionaryTree :: [DictionaryEntry] -> [DictionaryNode]`. One responsibility: materialise the flat adjacency list into a typed tree. Testable in isolation.
- `test/Domain/Core/DictionaryTreePropertySpec.hs` — properties for `buildDictionaryTree` + structural `entryAssignable`.

**Modified — domain**
- `src/Domain/Core/Types.hs` — `EntryRole` ADT, `role` on `DictionaryEntry`, structural `entryAssignable :: DictionaryEntry -> Bool`.
- `src/Domain/Core/DictionaryKind.hs` — delete `groupsAssignable` + old `entryAssignable` (+ exports).
- `src/Domain/Configuration/{Commands,Events}.hs` — `role` on `AddDictionaryEntry` / `DictionaryEntryAdded`.
- `src/Domain/Configuration/CommandHandler.hs` — `maxDictionaryDepth = 2`, `ParentNotAGroup`, `maxDepthForRole`, parent-must-be-group, role-aware depth.
- `src/Domain/Configuration/Projection.hs` — store/preserve `role`.
- `src/Domain/Configuration/Defaults.hs` — group vs item roles for defaults.

**Modified — infra/app/web**
- `src/Infrastructure/Database/Orphans.hs` — `PersistField`/`PersistFieldSql EntryRole`.
- `src/Application/ReadModels/Configuration.hs` — `role` on `DictionaryEntryValue`, entity column, apply, `loadDictionaries`.
- `src/Application/Services/ConfigurationService.hs` — `addDictionaryEntry` gains `EntryRole`; translate `ParentNotAGroup`.
- `src/Application/Services/TransactionService.hs` — items-only allocation/label validation.
- `src/Application/Services/Prompt/Transaction/Handler.hs` — items only in prompt contexts.
- `src/Web/API/ConfigurationAPI.hs` — DTO carries `type`, drop `groupsAssignable`, `AddEntryRequest` gains `type`, materialise via `buildDictionaryTree`.
- `src/Telegram/Commands.hs` — `getCategoryEntries` offers items only.

**Modified — tests / testkit**
- `test/Testkit/Generators.hs` — role-aware `genDictionaryEntry`/`genDictionaryTree`, depth 2.
- `test/Domain/Core/DictionaryKindPropertySpec.hs` — drop `entryAssignable`/`groupsAssignable` (moved to the new tree spec).
- `test/Domain/Configuration/ConfigurationTreePropertySpec.hs`, `CommandHandlerSpec.hs`, `ProjectionSpec.hs`, `DefaultsSpec.hs` — depth 2, roles, `ParentNotAGroup`.
- `test/Web/API/ConfigurationDictionaryTreeSpec.hs`, `test/Application/Services/ConfigurationDictionaryTreeIntegrationSpec.hs` — DTO `type`, drop `groupsAssignable`, depth-2 fixtures.

---

## Task 1: `EntryRole` ADT + structural `entryAssignable` (leaf, no build impact yet)

**Files:**
- Modify: `src/Domain/Core/Types.hs` (near `DictionaryEntry`, ~708-730; export list ~62-75)

- [ ] **Step 1: Add the `EntryRole` type, exports, and structural predicate.** In `Types.hs`, add to the export list (beside `DictionaryEntry (..)`): `EntryRole (..), entryAssignable`. Add the type + JSON + predicate:

```haskell
-- | Whether a dictionary entry is a pure container ('GroupRole', never assignable)
-- or a leaf ('ItemRole', always assignable). Declared at creation and immutable —
-- there is no group<->item conversion (ADR 002).
data EntryRole = GroupRole | ItemRole
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- Wire form is the lowercased constructor: "group" / "item".
instance ToJSON EntryRole where
  toJSON GroupRole = "group"
  toJSON ItemRole = "item"

instance FromJSON EntryRole where
  parseJSON = withText "EntryRole" $ \case
    "group" -> pure GroupRole
    "item" -> pure ItemRole
    other -> fail ("unknown EntryRole: " <> show other)

-- | Whether an entry may be attached to a transaction. Structural and uniform
-- across all kinds: items are always assignable, groups never (ADR 002).
entryAssignable :: DictionaryEntry -> Bool
entryAssignable entry = entry.role == ItemRole
```

(`withText` needs `Data.Aeson (withText)` — check it is imported; add if missing. `LambdaCase` is on project-wide.)

- [ ] **Step 2: Add `role` to `DictionaryEntry`.** Replace the record (Types.hs:711-716):

```haskell
data DictionaryEntry = DictionaryEntry
  { entryId :: DictionaryEntryId,
    name :: EntryName,
    role :: EntryRole,
    parentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq, Generic)
```

- [ ] **Step 3: Format only (no build yet — dependent sites are fixed in later tasks).**

Run: `ormolu -i src/Domain/Core/Types.hs`

> Build is expected to break here (every `DictionaryEntry { entryId, name, parentId }` site). It comes green at the end of Task 13. Proceed.

---

## Task 2: `DictionaryNode` ADT + `buildDictionaryTree` (new domain module)

**Files:**
- Create: `src/Domain/Core/DictionaryTree.hs`
- Modify: `package.yaml` is not needed (library picks up `src/**`), but confirm the module compiles once Task 13 completes.

- [ ] **Step 1: Write the module.**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

-- | Materialise the flat dictionary adjacency list into a typed tree. An
-- 'ItemNode' cannot carry children by construction (ADR 002). The flat list is
-- the source of truth (events + read-model rows are flat); this tree is derived.
module Domain.Core.DictionaryTree
  ( DictionaryNode (..),
    buildDictionaryTree,
  )
where

import Domain.Core.Types
  ( DictionaryEntry (..),
    DictionaryEntryId,
    EntryName,
    EntryRole (..),
  )
import RIO
import qualified RIO.Map as Map

-- | A node in the materialised tree. Groups hold children; items are leaves.
data DictionaryNode
  = GroupNode DictionaryEntryId EntryName [DictionaryNode]
  | ItemNode DictionaryEntryId EntryName
  deriving (Show, Eq, Generic)

-- | Build the roots-first tree from a flat entry list. Entries whose parent id
-- does not resolve to an existing group are dropped (orphans/cycles), matching
-- the previous materialiser's behaviour. An 'ItemRole' is always a leaf even if some
-- entry erroneously points at it (that child is dropped).
buildDictionaryTree :: [DictionaryEntry] -> [DictionaryNode]
buildDictionaryTree entries = buildLevel Nothing
  where
    childrenByParent :: Map (Maybe DictionaryEntryId) [DictionaryEntry]
    childrenByParent =
      Map.fromListWith (flip (<>)) [(e.parentId, [e]) | e <- entries]

    buildLevel :: Maybe DictionaryEntryId -> [DictionaryNode]
    buildLevel parent =
      [ toNode e
      | e <- Map.findWithDefault [] parent childrenByParent
      ]

    toNode :: DictionaryEntry -> DictionaryNode
    toNode e = case e.role of
      ItemRole -> ItemNode e.entryId e.name
      GroupRole -> GroupNode e.entryId e.name (buildLevel (Just e.entryId))
```

Note: `Map.fromListWith (flip (<>))` preserves insertion order within a sibling group (fold prepends, `flip` restores). This mirrors the DTO's "insertion order" contract.

- [ ] **Step 2: Register the module in `backend.cabal` via hpack.** Run: `hpack` (or `just build` later regenerates). No manual edit if `source-dirs: src` globs modules; verify `Domain.Core.DictionaryTree` appears in `backend.cabal` `exposed-modules` after `hpack`.

- [ ] **Step 3: Format.** Run: `ormolu -i src/Domain/Core/DictionaryTree.hs`

---

## Task 3: Delete `groupsAssignable` + old `entryAssignable` from `DictionaryKind`

**Files:**
- Modify: `src/Domain/Core/DictionaryKind.hs:14-21` (exports), `:38-50` (bodies)

- [ ] **Step 1: Remove exports.** Delete `groupsAssignable,` and `entryAssignable,` from the export list (lines 16-17).

- [ ] **Step 2: Remove the two functions** (lines 38-50, including their haddocks). Leave `DictionaryKind`, `dictionaryKindSlug`, `parseDictionaryKind` and the JSON instances untouched.

- [ ] **Step 3: Format.** Run: `ormolu -i src/Domain/Core/DictionaryKind.hs`

(The only consumers were `buildDictionaryResponse` and the `DictionaryKindPropertySpec`, both reworked in Tasks 10 and 14.)

---

## Task 4: `role` on the Add command and event

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs:134-144`
- Modify: `src/Domain/Configuration/Events.hs:132-142`

- [ ] **Step 1: Add `role` to `AddDictionaryEntry`** (Commands.hs), after `name`:

```haskell
data AddDictionaryEntry = AddDictionaryEntry
  { dictionaryKind :: DictionaryKind,
    entryId :: DictionaryEntryId,
    name :: EntryName,
    -- | Whether the new entry is a group (container) or item (leaf). Immutable.
    role :: EntryRole,
    parentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq)
```

Add `EntryRole` to the `Domain.Core.Types` import list at the top of `Commands.hs`.

- [ ] **Step 2: Mirror on `DictionaryEntryAdded`** (Events.hs) with the same `role` field and import. The other three commands/events are unchanged (role is immutable — rename/move/remove never carry it).

- [ ] **Step 3: Format.** Run: `ormolu -i src/Domain/Configuration/Commands.hs src/Domain/Configuration/Events.hs`

(`deriveJSON defaultOptions` picks up the new field automatically.)

---

## Task 5: Command-handler validation — depth 2, `ParentNotAGroup`, role-aware depth

**Files:**
- Modify: `src/Domain/Configuration/CommandHandler.hs` — `ConfigurationError` (70-101), `maxDictionaryDepth` (153-154), helpers (156-196), Add (300-317), Move (356-375), exports (37-44)

- [ ] **Step 1 (test first): add failing unit specs** in `test/Domain/Configuration/CommandHandlerSpec.hs` for the new/changed rules (see Task 15 for the full spec rework; land these expectations first so they drive the code):
  - Adding an entry under an **item** parent → `Left ParentNotAGroup`.
  - Adding an entry under a missing parent → `Left ParentEntryNotFound` (unchanged).
  - Adding a **group** under a root group → `Left MaxDepthExceeded` (no nested groups at depth 2).
  - Adding an **item** under a root group → `Right` (depth 2 leaf ok).
  - Adding an **item** two levels deep (under a level-2 item is impossible; under a level-2 group) → `Left MaxDepthExceeded`.

- [ ] **Step 2: `maxDictionaryDepth = 2`** (line 154). Update its haddock ("root nodes are level 1; a root group's items are level 2; extend to 3 by bumping this and relaxing the group rule").

- [ ] **Step 3: add `ParentNotAGroup`** to `ConfigurationError` (after `ParentEntryNotFound`, ~line 82):

```haskell
  | -- | An add/move named a parent that exists but is an item, not a group.
    -- Only groups may hold children (ADR 002).
    ParentNotAGroup
```

- [ ] **Step 4: add role-aware depth helper** beside `maxDictionaryDepth`:

```haskell
-- | The deepest level at which a node of this role may sit. An item is a leaf
-- (may go to the full depth); a group must leave room for at least one level of
-- item children, so it is capped one level shallower. At 'maxDictionaryDepth'
-- = 2: items <= 2, groups <= 1 (root only). Bumping the constant to 3 lets
-- groups nest one level — the whole "extend to 3" change.
maxDepthForRole :: EntryRole -> Int
maxDepthForRole ItemRole = maxDictionaryDepth
maxDepthForRole GroupRole = maxDictionaryDepth - 1
```

Add a helper to read a parent's role from the flat list:

```haskell
-- | 'True' when the id resolves to a group entry in the list.
isGroupEntry :: DictionaryEntryId -> [DictionaryEntry] -> Bool
isGroupEntry eid es = maybe False (\e -> e.role == GroupRole) (lookupEntry eid es)
```

Export `maxDepthForRole` and `isGroupEntry` alongside the existing tree helpers (line 37-44).

- [ ] **Step 5: rewrite the Add guard** (CommandHandler.hs:300-317). Note the command now binds `role`:

```haskell
handleConfigurationCommand config (AddDictionaryEntryConfigurationCommand AddDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | hasDuplicateSiblingName name parentId Nothing dictionaryKind config = Left DuplicateEntryName
  | Just p <- parentId, isNothing (lookupEntry p es) = Left ParentEntryNotFound
  | Just p <- parentId, not (isGroupEntry p es) = Left ParentNotAGroup
  | parentDepth + 1 > maxDepthForRole role = Left MaxDepthExceeded
  | otherwise =
      Right
        [ DictionaryEntryAddedConfigurationEvent
            DictionaryEntryAdded
              { dictionaryKind = dictionaryKind,
                entryId = entryId,
                name = name,
                role = role,
                parentId = parentId
              }
        ]
  where
    es = entriesOf dictionaryKind config
    parentDepth = maybe 0 (`depthOf` es) parentId
```

- [ ] **Step 6: rewrite the Move guard** (CommandHandler.hs:356-375). A move target must be a group; the moved subtree (with a group floor of 2) must fit:

```haskell
handleConfigurationCommand config (MoveDictionaryEntryConfigurationCommand MoveDictionaryEntry {..})
  | not (entryExists entryId dictionaryKind config) = Left EntryNotFound
  | Just p <- newParentId, isNothing (lookupEntry p es) = Left ParentEntryNotFound
  | Just p <- newParentId, not (isGroupEntry p es) = Left ParentNotAGroup
  | Just p <- newParentId, p == entryId || p `elem` descendantsOf entryId es = Left MoveWouldCreateCycle
  | newParentDepth + requiredHeight > maxDictionaryDepth = Left MaxDepthExceeded
  | maybe False (\nm -> hasDuplicateSiblingName nm newParentId (Just entryId) dictionaryKind config) entryName =
      Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryMovedConfigurationEvent
            DictionaryEntryMoved
              { dictionaryKind = dictionaryKind,
                entryId = entryId,
                newParentId = newParentId
              }
        ]
  where
    es = entriesOf dictionaryKind config
    newParentDepth = maybe 0 (`depthOf` es) newParentId
    movedEntry = lookupEntry entryId es
    entryName = (.name) <$> movedEntry
    -- A group must reserve room for its items even when currently empty.
    requiredHeight = case (.role) <$> movedEntry of
      Just GroupRole -> max (subtreeHeight entryId es) 2
      _ -> subtreeHeight entryId es
```

- [ ] **Step 7: format** (`ormolu -i src/Domain/Configuration/CommandHandler.hs`). Build stays red until Task 13; the CommandHandlerSpec goes green in Task 15.

---

## Task 6: Projection stores and preserves `role`

**Files:**
- Modify: `src/Domain/Configuration/Projection.hs:282-320`

- [ ] **Step 1: Added handler** — set `role` on the new entry:

```haskell
  let newEntry = DictionaryEntry {entryId = entryId, name = name, role = role, parentId = parentId}
```

- [ ] **Step 2: Renamed handler** — preserve role when rebuilding:

```haskell
      renameEntry n entry
        | entry.entryId == entryId = entry {name = n}
        | otherwise = entry
```

(Record update avoids re-listing every field and cannot drop `role`.)

- [ ] **Step 3: Moved handler** — preserve role:

```haskell
      reparent entry
        | entry.entryId == entryId = entry {parentId = newParentId}
        | otherwise = entry
```

- [ ] **Step 4: format.** Run: `ormolu -i src/Domain/Configuration/Projection.hs`

---

## Task 7: Default categories declare group vs item

**Files:**
- Modify: `src/Domain/Configuration/Defaults.hs:84-105` (`DefaultEntry`, constructors), `:157-211` (wiring)

- [ ] **Step 1: add `role` to `DefaultEntry`:**

```haskell
data DefaultEntry = DefaultEntry
  { entryName :: !Text,
    entryId :: !CategoryId,
    role :: !EntryRole,
    parentId :: !(Maybe CategoryId)
  }
  deriving (Show, Eq)
```

Import `EntryRole (..)` from `Domain.Core.Types`.

- [ ] **Step 2: split the constructors** into group vs item makers:

```haskell
mkExpenseGroup :: Text -> DefaultEntry
mkExpenseGroup n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictKind n) GroupRole Nothing

mkExpense :: Text -> DefaultEntry
mkExpense n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictKind n) ItemRole Nothing

mkExpenseChild :: CategoryId -> Text -> DefaultEntry
mkExpenseChild pid n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictKind n) ItemRole (Just pid)

mkIncomeGroup :: Text -> DefaultEntry
mkIncomeGroup n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictKind n) GroupRole Nothing

mkIncome :: Text -> DefaultEntry
mkIncome n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictKind n) ItemRole Nothing

mkIncomeChild :: CategoryId -> Text -> DefaultEntry
mkIncomeChild pid n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictKind n) ItemRole (Just pid)
```

- [ ] **Step 3: switch the five expense group bindings and two income group bindings to the `*Group` makers** (Defaults.hs:188-192, 209-210):

```haskell
    foodAndDiningGroup = mkExpenseGroup "Food & Dining"
    housingGroup = mkExpenseGroup "Housing"
    healthWellnessGroup = mkExpenseGroup "Health & Wellness"
    shoppingGoodsGroup = mkExpenseGroup "Shopping & Goods"
    leisureTravelGroup = mkExpenseGroup "Leisure & Travel"
```
```haskell
    earnedGroup = mkIncomeGroup "Earned"
    passiveGroup = mkIncomeGroup "Passive"
```

All `mkExpenseChild`/`mkIncomeChild` and the root `mkExpense`/`mkIncome` leaves stay as items. `mkDeterministicEntryId` is unchanged, so ids do not move because of the role addition. This keeps the existing 2-level shape (groups at root, items under them or at root) — already depth-2 compliant.

- [ ] **Step 4: format.** Run: `ormolu -i src/Domain/Configuration/Defaults.hs`

---

## Task 8: Read model carries `role`

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs:167-174` (value), `:196-203` (entity), `:297-328` (apply), `:440-459` (`loadDictionaries`)

- [ ] **Step 1: `DictionaryEntryValue` gains `role`:**

```haskell
data DictionaryEntryValue = DictionaryEntryValue
  { name :: EntryName,
    role :: EntryRole,
    parentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq, Generic)
```

Import `EntryRole` (from `Domain.Core.Types`).

- [ ] **Step 2: entity column** (persistent block ~196-203) — add `role EntryRole` after `name`:

```
    name EntryName
    role EntryRole
    parentId DictionaryEntryId Maybe
```

- [ ] **Step 3: Added-event apply** (~297-306) — include role in the inserted entity and the update list:

```haskell
                  (ConfigDictionaryEntryEntity configId evt.dictionaryKind evt.entryId evt.name evt.role evt.parentId)
                  [ ConfigDictionaryEntryEntityName =. evt.name,
                    ConfigDictionaryEntryEntityRole =. evt.role,
                    ConfigDictionaryEntryEntityParentId =. evt.parentId
                  ]
```

(Rename/Move/Remove applies unchanged — role is immutable.)

- [ ] **Step 4: `loadDictionaries`** (~440-459) — reconstruct `DictionaryEntryValue` with `role = e.role` (field name from the entity: `entity.role` via `OverloadedRecordDot` on the `ConfigDictionaryEntryEntity` value, or the generated `configDictionaryEntryEntityRole` accessor — match the surrounding style in that fold).

- [ ] **Step 5: format.** Run: `ormolu -i src/Application/ReadModels/Configuration.hs`

---

## Task 9: `PersistField EntryRole`

**Files:**
- Modify: `src/Infrastructure/Database/Orphans.hs` (beside the `DictionaryKind` instances, ~335-343)

- [ ] **Step 1: add the instances** (persist as `"group"`/`"item"` text, mirroring `DictionaryKind`):

```haskell
-- | 'EntryRole' persists as its lowercased constructor text.
instance PersistField EntryRole where
  toPersistValue GroupRole = toPersistValue ("group" :: Text)
  toPersistValue ItemRole = toPersistValue ("item" :: Text)
  fromPersistValue v = do
    t <- fromPersistValue v
    case (t :: Text) of
      "group" -> Right GroupRole
      "item" -> Right ItemRole
      other -> Left ("Invalid EntryRole: " <> other)

instance PersistFieldSql EntryRole where
  sqlType _ = SqlString
```

Ensure `EntryRole (..)` is in scope — add it to the `Domain.Core.Types` import in `Orphans.hs` unless that import is already open/unqualified.

- [ ] **Step 2: format.** Run: `ormolu -i src/Infrastructure/Database/Orphans.hs`

---

## Task 10: `ConfigurationService.addDictionaryEntry` takes a role; translate `ParentNotAGroup`

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs:239-256` (add), `:771-783` (translator)

- [ ] **Step 1: thread `EntryRole` through `addDictionaryEntry`:**

```haskell
addDictionaryEntry :: UserId -> DictionaryKind -> EntryName -> EntryRole -> Maybe DictionaryEntryId -> AppM (Either DomainError DictionaryEntryId)
addDictionaryEntry userId dictKind entryName role parentId = runExceptT $ do
  ...
  let entryId = unsafeDictionaryEntryId entryUuid
      cmd =
        AddDictionaryEntryConfigurationCommand
          AddDictionaryEntry
            { dictionaryKind = dictKind,
              entryId = entryId,
              name = entryName,
              role = role,
              parentId = parentId
            }
  ...
```

Import `EntryRole`. Update the **three** seed/clone constructions that build `AddDictionaryEntry`: the income block (`seedFresh`, ~829) and expense block (`seedFresh`, ~844) each pass `role = entry.role` from their `DefaultEntry`; `copyDictionaries` (~968) passes `role = v.role` from the `DictionaryEntryValue`.

- [ ] **Step 2: translate `ParentNotAGroup`** in `defaultTranslateConfigurationError` (~771):

```haskell
defaultTranslateConfigurationError (CommandRejected ConfigCh.ParentNotAGroup) =
  ConfigurationError "The specified parent is not a group; only groups can contain entries"
```

(`ConfigurationError` maps to HTTP 400 in `Web/ErrorMapping.hs` — no new mapping needed.)

- [ ] **Step 3: format.** Run: `ormolu -i src/Application/Services/ConfigurationService.hs`

---

## Task 11: DTO carries `type`, drops `groupsAssignable`; materialise via `buildDictionaryTree`

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs` — DTO (431-457), `AddEntryRequest` (469-475), `buildDictionaryResponse` (1029-1049), `addEntryHandler` (777-790)

- [ ] **Step 1: reshape the DTO types.** Drop `groupsAssignable`; give the node a `type` tag:

```haskell
newtype DictionaryResponse = DictionaryResponse
  { roots :: [DictionaryEntryNode]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryResponse
instance FromJSON DictionaryResponse

-- | A node in the materialised tree. @type@ is "group" or "item"; a group may
-- have children, an item never does. Role is explicit (an empty group has no
-- children yet is still a group).
data DictionaryEntryNode = DictionaryEntryNode
  { id :: UUID,
    name :: Text,
    type_ :: EntryRole,
    children :: [DictionaryEntryNode]
  }
  deriving (Show, Eq, Generic)
```

Because the JSON key must be `type` (a Haskell keyword), **hand-write** `DictionaryEntryNode`'s `ToJSON`/`FromJSON` mapping the `type` key to/from `type_` (every other DTO in this module uses bare generic instances — there is no custom-`Options` precedent to follow, so don't invent one). `EntryRole`'s own JSON already emits `"group"`/`"item"`, so `"type" .= n.type_` and `o .: "type"` are all you need.

- [ ] **Step 2: `AddEntryRequest` gains `type`:**

```haskell
data AddEntryRequest = AddEntryRequest
  { name :: Text,
    type_ :: EntryRole,
    parentId :: Maybe UUID
  }
  deriving (Show, Eq, Generic)
```

with matching JSON mapping `type` -> `type_`.

- [ ] **Step 3: rewrite `buildDictionaryResponse`** to delegate to the domain materialiser (no `kind` needed anymore):

```haskell
buildDictionaryResponse :: DictionaryData -> DictionaryResponse
buildDictionaryResponse dictData =
  DictionaryResponse {roots = map toNode (buildDictionaryTree flatEntries)}
  where
    flatEntries =
      [ DictionaryEntry {entryId = eid, name = v.name, role = v.role, parentId = v.parentId}
      | (eid, v) <- Map.toList dictData.entries
      ]
    toNode :: DictionaryNode -> DictionaryEntryNode
    toNode (ItemNode eid nm) =
      DictionaryEntryNode {id = unDictionaryEntryId eid, name = unEntryName nm, type_ = ItemRole, children = []}
    toNode (GroupNode eid nm kids) =
      DictionaryEntryNode {id = unDictionaryEntryId eid, name = unEntryName nm, type_ = GroupRole, children = map toNode kids}
```

Update the two call sites: `toConfigurationResponse` (~979-990) becomes `Map.mapKeys dictionaryKindSlug $ Map.map buildDictionaryResponse configData.dictionaries` (drop `mapWithKey`); `listDictionaryHandler` (~765-774) drops the `kind` argument. Remove the now-unused `DictKind` qualified import if nothing else uses it. Import `Domain.Core.DictionaryTree (DictionaryNode (..), buildDictionaryTree)` and `Domain.Core.Types (DictionaryEntry (..), EntryRole (..))`.

- [ ] **Step 4: `addEntryHandler`** (~777-790) — parse `req.type_` and pass it: `ConfigService.addDictionaryEntry userId kind (unsafeEntryName req.name) req.type_ (unsafeDictionaryEntryId <$> req.parentId)` (match the existing name-validation path).

- [ ] **Step 5: format.** Run: `ormolu -i src/Web/API/ConfigurationAPI.hs`

---

## Task 12: Items-only allocation & label validation

**Files:**
- Modify: `src/Application/Services/TransactionService.hs:1149-1184` (`dictionaryEntryIds`, allocation validation), `:737-749` (`validateLabels`)

- [ ] **Step 1 (test first):** in `test/Application/Services/` add/extend a spec asserting that setting an allocation whose `categoryId` is a **group** id fails with `CategoryNotFound` (or a dedicated error if preferred), while an item id succeeds. (Use the integration harness already used by `ConfigurationDictionaryTreeIntegrationSpec`.)

- [ ] **Step 2: restrict the known-id set to items.** Add beside `dictionaryEntryIds`:

```haskell
-- | Assignable (item) entry ids for a dictionary — groups are excluded, since
-- only items may be attached to a transaction (ADR 002).
assignableEntryIds :: DictionaryKind -> ConfigurationData -> Set DictionaryEntryId
assignableEntryIds dictKind cfg =
  case Map.lookup dictKind cfg.dictionaries of
    Just dict -> Map.keysSet (Map.filter (\v -> entryAssignableValue v) dict.entries)
    Nothing -> Set.empty
  where
    entryAssignableValue v = v.role == ItemRole
```

Point `validateAllocationsAgainstDictionary` (`incomeKnown`/`expenseKnown`) and `validateLabels` at `assignableEntryIds` instead of `dictionaryEntryIds`. Keep `dictionaryEntryIds` if still used elsewhere; otherwise remove it. Import `entryAssignable` is not needed here (we read `.role` on the read-model value, which has no `DictionaryEntry`); the local `v.role == ItemRole` is correct.

- [ ] **Step 3: format + verify the new test.** Run: `ormolu -i src/Application/Services/TransactionService.hs`

---

## Task 13: Telegram & prompt offer items only — LIB+EXE GREEN CHECKPOINT

**Files:**
- Modify: `src/Telegram/Commands.hs:842-877` (`getCategoryEntries`, `getDictionaryEntryNames`)
- Modify: `src/Application/Services/Prompt/Transaction/Handler.hs:117-123` (`entriesOfDict`)

- [ ] **Step 1: filter groups out** in `getCategoryEntries` and `entriesOfDict` — keep only `v.role == ItemRole` before mapping to `(id, name)`. E.g. in `entriesOfDict`:

```haskell
entriesOfDict dictKind cfg =
  maybe
    []
    (map (\(cid, v) -> (cid, v.name)) . filter (\(_, v) -> v.role == ItemRole) . Map.toList . (.entries))
    (Map.lookup dictKind cfg.dictionaries)
```

Apply the same `filter` in `getCategoryEntries` (Telegram) and in `getDictionaryEntryNames`'s per-dict extraction so groups are never offered as selectable categories/labels.

- [ ] **Step 2: format.** Run: `ormolu -i src/Telegram/Commands.hs src/Application/Services/Prompt/Transaction/Handler.hs`

- [ ] **Step 3: production compile — every non-test construction site is now updated.** Run: `cabal build lib:backend exe:backend -fci`
  Expected: **PASS** (first green production build since Task 2). Do **not** run `just build`/`just test` yet — they compile the test suites, which are reworked in Tasks 14–16. If any `DictionaryEntry`/`DictionaryEntryValue`/`AddDictionaryEntry`/`DefaultEntry`/DTO construction still misses `role`, the error names the file:line — fix and rebuild.

- [ ] **Step 4: lint + commit the type-migration phase.**

```bash
just lint
git add -A
git commit -m "refactor(configuration): structural group/item roles for dictionary entries (tracker#42)

Replace emergent group-ness + per-kind groupsAssignable with an immutable
EntryRole (GroupRole|ItemRole); items-only assignable; depth 2; ParentNotAGroup;
derived DictionaryNode tree. Implements ADR 002."
```

---

## Task 14: Rework `DictionaryTree`/`entryAssignable` property spec

**Files:**
- Create: `test/Domain/Core/DictionaryTreePropertySpec.hs`
- Modify: `test/Domain/Core/DictionaryKindPropertySpec.hs` (strip the assignability block)

- [ ] **Step 1: strip `DictionaryKindPropertySpec.hs`.** Remove the whole `describe "entryAssignable"` block and the `entryAssignable`/`groupsAssignable` imports. If nothing else remains, replace the body with a minimal slug round-trip property (`parseDictionaryKind (dictionaryKindSlug k) == Just k` over `[minBound..maxBound]`) so the file still earns its place; otherwise delete the file and its `hspec-discover` reference will drop it automatically.

- [ ] **Step 2: write the new spec** (test-first was impossible pre-migration; write now and confirm green):

```haskell
module Domain.Core.DictionaryTreePropertySpec (spec) where

import Domain.Core.DictionaryTree
import Domain.Core.Types
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Testkit.Generators (genDictionaryTree)

spec :: Spec
spec = do
  describe "entryAssignable" $ do
    it "items are assignable, groups are not" $ do
      -- build two entries differing only by role
      pending  -- replace with concrete item/group entries via Testkit helpers

  describe "buildDictionaryTree" $ do
    prop "an ItemNode never has children" $
      forAll genDictionaryTree $ \es ->
        all noItemChildren (buildDictionaryTree es)
    prop "every input entry appears at most once and only under a group" $
      forAll genDictionaryTree $ \es ->
        True  -- replace with a concrete structural invariant
  where
    noItemChildren (ItemNode _ _) = True
    noItemChildren (GroupNode _ _ kids) = all noItemChildren kids
```

Flesh out the `pending`/placeholder props with concrete assertions (item vs group `entryAssignable`; no orphan appears; a group's children are exactly the entries whose `parentId` is that group). Run: `cabal test all --test-option=--match --test-option="/Domain.Core.DictionaryTree/"` → PASS.

---

## Task 15: Rework command-handler & projection specs

**Files:**
- Modify: `test/Domain/Configuration/CommandHandlerSpec.hs`, `test/Domain/Configuration/ProjectionSpec.hs`, `test/Domain/Configuration/ConfigurationTreePropertySpec.hs`

- [ ] **Step 1: `CommandHandlerSpec.hs`** — every `AddDictionaryEntry`/`DictionaryEntry` literal now needs a `role`. Update the `MaxDepthExceeded` scenarios (lines ~1111-1215) to the depth-2 world: a root **group** + an **item** child is the max; a group under a group and an item under a level-2 node now trip `MaxDepthExceeded`. Add the `ParentNotAGroup` scenario (add under an item id). Keep the existing `GroupNotEmpty`/`MoveWouldCreateCycle` scenarios, adjusting fixtures to depth 2 and giving parents `role = GroupRole`, leaves `role = ItemRole`.

- [ ] **Step 2: `ProjectionSpec.hs`** — add `role` to every `DictionaryEntry`/`DictionaryEntryAdded` literal; add an assertion that rename and move **preserve** `role`.

- [ ] **Step 3: `ConfigurationTreePropertySpec.hs`** — the depth invariant now asserts `<= maxDictionaryDepth` (= 2) using the role-aware generator; add an invariant that no accepted tree has an entry whose parent is an item (parents are always groups). Note: at depth 2 the `MoveWouldCreateCycle` **descendant** branch is unreachable (groups have only item descendants, and the target must be a group), so the "move onto a descendant is rejected" property must assert `isLeft` / `ParentNotAGroup` rather than specifically `MoveWouldCreateCycle` — only the `p == entryId` self-move branch of the cycle check is reachable here. Keep `MoveWouldCreateCycle` in place; it becomes reachable at depth 3.

- [ ] **Step 4: run** `cabal test all --test-option=--match --test-option="/Domain.Configuration/"` → PASS. Commit.

---

## Task 16: Rework defaults, web, and integration specs

**Files:**
- Modify: `test/Domain/Configuration/DefaultsSpec.hs`, `test/Web/API/ConfigurationDictionaryTreeSpec.hs`, `test/Application/Services/ConfigurationDictionaryTreeIntegrationSpec.hs`, `test/Application/Services/ConfigurationServiceIntegrationSpec.hs`

- [ ] **Step 0: fix the non-obvious `DictionaryEntryValue` construction site.** `test/Application/Services/ConfigurationServiceIntegrationSpec.hs:231,233` builds `DictionaryEntryValue {name = …, parentId = …}` (and imports `DefaultEntry (..)` at line 39). Under `-fci`/`-Werror` a missing `role` field is a build error, so this file blocks the whole test build even though it is not a dictionary-tree spec. Add `role` to both constructions (Housing → `GroupRole`, Household/leaf → `ItemRole`, consistent with Task 7). Do this first — otherwise the Task 16 suite won't compile.

- [ ] **Step 1: `DefaultsSpec.hs`** — assert the five expense group + two income group defaults have `role = GroupRole` and `parentId = Nothing`; children/root leaves have `role = ItemRole`; the tree is depth-2.

- [ ] **Step 2: `ConfigurationDictionaryTreeSpec.hs`** — drop the `groupsAssignable` assertions (lines 93-95). Give `sampleDict` entries roles (Food = GroupRole, Dining/Groceries = ItemRole). Assert each node's `type_` (`GroupRole`/`ItemRole`) and that an **empty group** (a GroupRole entry with no children) still materialises as a `type: "group"` node with `children = []`. Keep the orphan-drop and multi-level tests but reshape to a valid depth-2 tree (group → items); the old Food→Dining→FastFood 3-level fixture must become a group with item children.

- [ ] **Step 3: `ConfigurationDictionaryTreeIntegrationSpec.hs`** — `buildMovedTree` currently nests Food→Groceries→Dining (depth 3) — reshape to depth 2: Food = GroupRole; Groceries, Dining = items under Food. Drop `responseGroupsAssignable` (line 60, 149-150). The cycle test (move Food under Dining) now also violates `ParentNotAGroup` (Dining is an item) — assert the rejection message accordingly (either "cycle" or "not a group"; pick the guard that fires first — with the Task 5 ordering, `ParentNotAGroup` precedes the cycle check, so assert on that). Add `role` to `addEntry` (default new entries appropriately: a helper `addGroup`/`addItem`).

- [ ] **Step 4: full suite.** Run: `just test`
  Expected: PASS (modulo the known-environmental `eventium_test` DB failures — see project memory; those are not regressions). Commit.

---

## Task 17: Docs + final verification

- [ ] **Step 1: mark the spec complete.** In `docs/specs/2026-07-17-typed-dictionary-kind-nested-entries-design.md`, flip `status: in-progress` → `completed` once the suite is green.

- [ ] **Step 2: rebuild clean** to defeat the warm-`.o` `-Werror` masking (project memory `latent -fci test debt`). Run: `just rebuild && just test`.

- [ ] **Step 3: `/verify`** — drive the real add-group / add-item / move / GET-config flow against the running app to confirm the DTO `type` field and the `ParentNotAGroup`/depth-2 rejections behave end-to-end (not just in tests).

- [ ] **Step 4: final commit** of doc status + any verification fixes.

---

## Notes for the implementer
- **DRY:** role-aware depth lives in one helper (`maxDepthForRole`); tree materialisation lives in one place (`buildDictionaryTree`) reused by the DTO and tests. Do not re-derive either.
- **YAGNI:** do **not** build rollup reporting or a 3-level relaxation now — ADR 002 defers both. The extend-to-3 change touches three spots, all in `CommandHandler.hs`: `maxDictionaryDepth`, `maxDepthForRole`, **and** the hard-coded group floor `2` in the Move guard's `requiredHeight`. Leave a comment at that `2` pointing to `maxDepthForRole` so the future change doesn't miss it.
- **Immutability:** no command or event ever carries `role` except `AddDictionaryEntry`/`DictionaryEntryAdded`. Rename/Move/Remove must preserve it (record updates, not full reconstruction).
- **No backward compat** (project memory): the read model rebuilds from events, so the new `role` column needs no data migration; deterministic default ids are unchanged by the role addition.
