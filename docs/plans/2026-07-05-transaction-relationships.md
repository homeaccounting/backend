# Typed Transaction Relationships (Refunds + Merge/Split Lineage) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a general, typed, directed-edge model between transactions — recorded as domain events — and wire the `Refund` kind end-to-end (income create → read model → reporting → HTTP), plus the internal edge-creation hook that future merge/split operations will call.

**Architecture:** One new domain event `TransactionRelationAdded` (self = stream key) records every edge. At-creation edges (Refund) are emitted atomically with `TransactionPostingInitiated` via an optional `relation :: Maybe RelationSpec` on `InitiateTransaction`; post-hoc edges (Merge/Split) use a standalone `AddTransactionRelation` command. Edges project into a new indexed `transaction_relations` read-model table; the service validates per-kind rules effectfully; the Web layer exposes outbound edges on `TransactionResponse` and a `GET /:id/relations` endpoint.

**Tech Stack:** Haskell (GHC 9.10), RIO prelude (NoImplicitPrelude), Servant, Eventium (event sourcing), Persistent/PostgreSQL, Hspec + QuickCheck, ormolu, hlint. Build/test via `just` inside `nix develop`.

**Spec:** `docs/specs/2026-07-05-transaction-relationships-design.md`

---

## Background the implementer needs

- **Prelude:** RIO with `NoImplicitPrelude`. Use `logInfo`/`logDebug`, `tshow`, `Set`, `Map` from RIO. Modules that need `Text` literals turn on `OverloadedStrings`.
- **Extensions on by default (package.yaml):** `StrictData`, `GADTs`, `DataKinds`, `TypeFamilies`, `NoFieldSelectors`, `DuplicateRecordFields`, `OverloadedRecordDot`. Record fields are accessed with dot syntax (`x.field`); never export constructors/selectors — use smart constructors/accessors.
- **Event sourcing (Eventium):** aggregate events are declared as plain records, listed in a `[Name]` TH list, and fused into a sum type via `constructSumType`. Adding a name to `transactionEvents` in `Domain/Transaction/Events.hs` automatically produces `TransactionRelationAddedTransactionEvent` (aggregate sum) **and** `TransactionRelationAddedEvent` (unified `AccountingEvent` in `Domain/Models.hs`, via the `(++ "Event")` tag). Same for commands (`(++ "Command")`).
- **Layering:** `Domain.*` (pure) → `Application.*` → `Infrastructure.*`; `Web.*` on top. Do not import upward.
- **Errors:** pure handler returns `Either TransactionError [TransactionEvent]`; the service translates `CommandHandlerError TransactionError` → `DomainError`; the Web layer maps `DomainError` → HTTP via `Web.ErrorMapping`.
- **No backward-compat phase (project rule):** events/DTOs/DB may change shape freely; no upcasters. We add a *new* event rather than mutate `TransactionPostingInitiated`.
- **`-fci` gate:** `just build` / `just test` run with `-Werror` over lib+exe+test. Warm `.o` cache can mask `-Werror`; use `just rebuild` for a definitive check before finishing.
- **Full `cabal test all` needs a manually-created `eventium_test` Postgres DB** (`just docker-up` does not create it); ~28 integration failures without it are environmental, not regressions. Run targeted specs during development.

**Commands:**
```bash
just build          # hpack + cabal build -fci
just test           # cabal test -fci --test-show-details=direct
just format         # ormolu -i
just lint           # hlint src test
just rebuild        # clean + -fci build (definitive -Werror check)
# Run one spec by match:
cabal test all --test-option='--match' --test-option="/Domain.Transaction.Relations/"
```

**Commit discipline:** commit after each task's tests pass. Conventional Commits: `feat(transaction): …`, `test(transaction): …`. Run `just format` before every commit.

---

## File Structure

**Create:**
- `test/Domain/Transaction/RelationsCommandHandlerSpec.hs` — pure handler unit tests
- `test/Domain/Transaction/RelationsProjectionPropertySpec.hs` — projection no-op property
- `test/Application/ReadModels/TransactionRelationsSpec.hs` — read-model query tests (in-memory/SQLite)
- `test/Application/Services/RefundReportingSpec.hs` — pure `applyRefunds` tests
- `test/Integration/TransactionRelationsIntegrationSpec.hs` — end-to-end via event store
- `test/Web/API/TransactionRelationsAPISpec.hs` — HTTP request/response shape

**Modify:**
- `src/Domain/Core/Types.hs` — `RelationKind`, `RelationSpec`, `renderRelationKind`, `parseRelationKind`
- `src/Domain/Transaction/Events.hs` — `TransactionRelationAdded` + register
- `src/Domain/Transaction/Commands.hs` — `AddTransactionRelation`, `InitiateTransaction.relation` + register
- `src/Domain/Transaction/CommandHandler.hs` — emit relation events, `RelationSelfLink`
- `src/Domain/Transaction/Projection.hs` — no-op handler arm
- `src/Infrastructure/Database/Orphans.hs` — `PersistField RelationKind`
- `src/Application/ReadModels/Transaction.hs` — table, apply arm, queries, reset, indexes
- `src/Domain/Core/Errors.hs` — new constructors + `renderDomainError` arms
- `src/Web/ErrorMapping.hs` — HTTP status arms
- `src/Application/Services/TransactionService.hs` — refund validation, `recordTransactionRelation`, `getOutboundRelations`, error translation
- `src/Web/Types.hs` — `IncomeRequest.relatedTransactionId`, `RelationResponse`, `TransactionResponse.relations`, `TransactionRelationsResponse`, `fromTransactionData` signature
- `src/Web/API/TransactionAPI.hs` — income handler, relations endpoint, call-site wiring
- `src/Web/API/AccountAPI.hs` — `adjustBalanceHandler` (`fromTransactionData` call site; passes `[]`)
- `src/Web/API/PromptAPI.hs` — `promptHandler` (`fromTransactionData` call site; passes `[]`)
- `src/Application/Services/ReportingService.hs` — `applyRefunds` + `spendingByCategory` wiring
- `package.yaml` — no change expected (hspec-discover picks up new specs); run `hpack` via `just build`

---

## Phase 1 — Domain core type (`RelationKind`)

`RelationKind` must live in `Domain.Core.Types` (not `Domain.Transaction.Projection`, where `StatusKind` lives): `Domain.Transaction.Events` needs it, and `Events` cannot import `Projection` (that would create an import cycle). `Core.Types` is already imported by `Events`, the read model, Orphans, and Web.Types.

### Task 1: `RelationKind` enum + render/parse

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Test: `test/Domain/Transaction/RelationsCommandHandlerSpec.hs` (temporary home for the round-trip test; will also hold handler tests)

- [ ] **Step 1: Write the failing test**

Create `test/Domain/Transaction/RelationsCommandHandlerSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Domain.Transaction.RelationsCommandHandlerSpec (spec) where

import Domain.Core.Types (RelationKind (..), parseRelationKind, renderRelationKind)
import Test.Hspec

spec :: Spec
spec =
  describe "RelationKind wire token" $ do
    it "round-trips through render/parse for every constructor" $
      mapM_
        (\k -> parseRelationKind (renderRelationKind k) `shouldBe` Just k)
        [minBound .. maxBound]
    it "renders lowercase tokens" $ do
      renderRelationKind Refund `shouldBe` "refund"
      renderRelationKind Merge `shouldBe` "merge"
      renderRelationKind Split `shouldBe` "split"
    it "parse is case-insensitive and trims" $
      parseRelationKind "  Refund " `shouldBe` Just Refund
    it "rejects unknown tokens" $
      parseRelationKind "bogus" `shouldBe` Nothing
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/RelationKind wire token/"`
Expected: FAIL to compile (`RelationKind` not in scope).

- [ ] **Step 3: Implement in `Domain.Core.Types`**

Add to the export list (near the `StatusKind` / transaction-type exports):

```haskell
    RelationKind (..),
    renderRelationKind,
    parseRelationKind,
    RelationSpec (..),
```

Add the definitions (place near the other small enums; mirror `renderStatusKind`/`parseStatusKind` from `Domain.Transaction.Projection`). `RelationKind` exports its constructors (`(..)`) — this is an opaque closed enum with no smart-constructor validation, exactly like `StatusKind`:

```haskell
-- | The kind of a typed relationship between two transactions. See
-- docs/specs/2026-07-05-transaction-relationships-design.md.
--
--   * 'Refund' — an Income transaction partially/fully refunds an Expense.
--   * 'Merge'  — a cancelled source transaction was merged into a target.
--   * 'Split'  — a newly-created result was split from an origin.
--
-- Direction is a documented convention (the owning/self transaction is the
-- "from" endpoint; the referenced one is 'relatedTransactionId'), not encoded
-- in the constructor names.
data RelationKind = Refund | Merge | Split
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance ToJSON RelationKind

instance FromJSON RelationKind

-- | An at-creation relationship request threaded through 'InitiateTransaction':
-- the referenced (pre-existing) transaction and the kind of edge to record. The
-- owning ("from") transaction is the one being created, so it is not named here.
data RelationSpec = RelationSpec
  { relatedTransactionId :: TransactionId,
    relationKind :: RelationKind
  }
  deriving (Show, Eq, Generic)

instance ToJSON RelationSpec

instance FromJSON RelationSpec

-- | Render a 'RelationKind' to its lowercase wire/DB token.
renderRelationKind :: RelationKind -> Text
renderRelationKind Refund = "refund"
renderRelationKind Merge = "merge"
renderRelationKind Split = "split"

-- | Parse a wire/DB token (trimmed, case-insensitive) to a 'RelationKind'.
parseRelationKind :: Text -> Maybe RelationKind
parseRelationKind raw = case T.toLower (T.strip raw) of
  "refund" -> Just Refund
  "merge" -> Just Merge
  "split" -> Just Split
  _ -> Nothing
```

Confirm `T` (`Data.Text`), `ToJSON`, `FromJSON`, `Generic` are already imported in `Core.Types` (they are — used by existing types). `TransactionId` is defined earlier in the same module.

- [ ] **Step 4: Run test to verify it passes**

Run: `cabal test all --test-option='--match' --test-option="/RelationKind wire token/"`
Expected: PASS.

- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Domain/Core/Types.hs test/Domain/Transaction/RelationsCommandHandlerSpec.hs
git commit -m "feat(transaction): add RelationKind enum + RelationSpec"
```

---

## Phase 2 — Events & Commands

### Task 2: `TransactionRelationAdded` event

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Test: `test/Domain/Transaction/EventsSpec.hs` (add a JSON round-trip; follow existing cases there)

- [ ] **Step 1: Write the failing test**

Add to `test/Domain/Transaction/EventsSpec.hs` (mirror an existing `deriveJSON` round-trip case in that file; import `TransactionRelationAdded (..)`, `RelationKind (..)`, and a sample `TransactionId` via the testkit helper used elsewhere in the file):

```haskell
    it "TransactionRelationAdded round-trips through JSON" $ do
      let evt = TransactionRelationAdded sampleRelatedTxId Refund
      decode (encode evt) `shouldBe` Just evt
```

(Build `sampleRelatedTxId` via `unsafeTransactionId`/`mkTransactionIdSafe` from a fixed UUID as other tests in the file do.)

- [ ] **Step 2: Run test — FAIL** (`TransactionRelationAdded` not in scope).

- [ ] **Step 3: Implement**

In `src/Domain/Transaction/Events.hs`:
- Add `TransactionRelationAdded (..)` to the export list.
- Add `''TransactionRelationAdded` to the `transactionEvents` list.
- Import `RelationKind` from `Domain.Core.Types` (extend the existing import).
- Add the record (after the cancellation events):

```haskell
-- | Event emitted when a typed relationship from this transaction to another is
-- recorded. The owning ("from") endpoint is the stream key — it is NOT a payload
-- field, mirroring 'TransactionPostingInitiated' which also carries no self-id
-- (the pure InitiateTransaction handler cannot know the freshly-generated
-- aggregate id). The read model reads "from" from the stream key.
data TransactionRelationAdded = TransactionRelationAdded
  { -- | The referenced (pre-existing) transaction — the "to" endpoint.
    relatedTransactionId :: TransactionId,
    -- | The kind of relationship.
    relationKind :: RelationKind
  }
  deriving (Show, Eq)
```

Adjust the Task-2 test accordingly: `TransactionRelationAdded sampleRelatedTxId Refund`.

- Add `deriveJSON defaultOptions ''TransactionRelationAdded` alongside the other derivations at the bottom.

- [ ] **Step 4: Run test — PASS.**

- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Domain/Transaction/Events.hs test/Domain/Transaction/EventsSpec.hs
git commit -m "feat(transaction): add TransactionRelationAdded event"
```

### Task 3: `AddTransactionRelation` command + `InitiateTransaction.relation`

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs`

No dedicated test here (commands are plain records exercised by the handler tests in Task 4). This task must compile.

- [ ] **Step 1: Implement**

In `src/Domain/Transaction/Commands.hs`:
- Import `RelationKind`, `RelationSpec` from `Domain.Core.Types`.
- Add `AddTransactionRelation (..)` to exports; add `''AddTransactionRelation` to `transactionCommands`.
- Add field `relation :: Maybe RelationSpec` to `InitiateTransaction` (place last, after `labels`). Update its Haddock to mention the optional at-creation relation.
- Add the command record:

```haskell
-- | Post-hoc command to record a typed relationship on an already-existing
-- (Completed) transaction. Used by the merge/split domain operations to write
-- 'Merge'/'Split' lineage; not exposed as a public "create arbitrary edge"
-- endpoint. At-creation edges (Refund) are recorded via 'InitiateTransaction.relation'
-- instead. 'transactionId' is the owning ("from") aggregate the command routes to.
data AddTransactionRelation = AddTransactionRelation
  { transactionId :: TransactionId,
    relatedTransactionId :: TransactionId,
    relationKind :: RelationKind
  }
  deriving (Show, Eq)
```

- Add `deriveJSON defaultOptions ''AddTransactionRelation` at the bottom.
- **Note:** `InitiateTransaction` now has a `Maybe RelationSpec` field; its existing `deriveJSON` handles it automatically. Every place that constructs `InitiateTransaction` as a record must add `relation = Nothing` — this is Task 3b.

- [ ] **Step 2: Build — expect failures at `InitiateTransaction` construction sites**

Run: `just build`
Expected: FAIL — `InitiateTransaction` record construction missing `relation` at:
`TransactionService.hs` (income/expense/transfer, ~lines 264/321/384), `AccountService.hs:~500`, `BankImportService.hs:~469`, and any test fixtures constructing it.

### Task 3b: Thread `relation = Nothing` through existing construction sites

- [ ] **Step 1: Add `relation = Nothing` to every existing `InitiateTransaction { … }`**

Search: `grep -rn "InitiateTransaction$\|InitiateTransaction\b" src test | grep -v "data InitiateTransaction\|InitiateTransactionTransactionCommand"` to find record constructions. Add `relation = Nothing` to each (income handler will set it properly in Phase 7; leave `Nothing` here). Expense/transfer/bank-import/adjustment stay `Nothing` permanently.

- [ ] **Step 2: Build — PASS**

Run: `just build`
Expected: compiles.

- [ ] **Step 3: Format, commit**

```bash
just format && just lint
git add src/Domain/Transaction/Commands.hs src/Application/Services/*.hs
git commit -m "feat(transaction): add AddTransactionRelation command + InitiateTransaction.relation"
```

---

## Phase 3 — Command handler & projection

### Task 4: Emit relation events + `RelationSelfLink` guard

**Files:**
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Test: `test/Domain/Transaction/RelationsCommandHandlerSpec.hs`

**Self-link responsibility (decided):** the pure handler receives only `Transaction` state, no stream id. So:
- `AddTransactionRelation` carries `transactionId` (the routed aggregate) → its handler does the pure self-link check `transactionId == relatedTransactionId`.
- `InitiateTransaction` does **not** know its freshly-generated id, so its handler performs **no** self-link check; the service is the authoritative guard (Task 9). A freshly-generated UUID cannot equal an existing target, so a self-link is structurally impossible on the create path anyway. The emitted `TransactionRelationAdded` carries only `relatedTransactionId` + `relationKind` (per Task 2); the read model derives "from" from the stream key.

- [ ] **Step 1: Write failing tests**

Extend `RelationsCommandHandlerSpec` (import `handleTransactionCommand`, the command/event sum constructors, `transactionDefault`, a Completed-state helper, `InitiateTransaction`/`AddTransactionRelation`, `RelationSpec`, `RelationSelfLink`). Use the same testkit constructors `CommandHandlerSpec` uses to build a valid `InitiateTransaction` (`baseInitiate`) and a Completed `Transaction` (`completedTx :: TransactionId -> Transaction`):

```haskell
  describe "InitiateTransaction with a relation" $ do
    it "emits PostingInitiated then RelationAdded when relation is present" $ do
      let cmd = baseInitiate { relation = Just (RelationSpec purchaseId Refund) }
      case handleTransactionCommand transactionDefault (InitiateTransactionTransactionCommand cmd) of
        Right [TransactionPostingInitiatedTransactionEvent _,
               TransactionRelationAddedTransactionEvent r] -> do
          r.relatedTransactionId `shouldBe` purchaseId
          r.relationKind `shouldBe` Refund
        other -> expectationFailure ("unexpected: " <> show other)

    it "emits a single event when relation is Nothing (regression)" $ do
      let cmd = baseInitiate { relation = Nothing }
      case handleTransactionCommand transactionDefault (InitiateTransactionTransactionCommand cmd) of
        Right [TransactionPostingInitiatedTransactionEvent _] -> pure ()
        other -> expectationFailure ("unexpected: " <> show other)

  describe "AddTransactionRelation" $ do
    it "rejects a self-link" $ do
      let cmd = AddTransactionRelation selfId selfId Merge
      handleTransactionCommand (completedTx selfId) (AddTransactionRelationTransactionCommand cmd)
        `shouldBe` Left RelationSelfLink
    it "emits a single TransactionRelationAdded on a Completed tx" $ do
      let cmd = AddTransactionRelation selfId otherId Merge
      case handleTransactionCommand (completedTx selfId) (AddTransactionRelationTransactionCommand cmd) of
        Right [TransactionRelationAddedTransactionEvent r] -> do
          r.relatedTransactionId `shouldBe` otherId
          r.relationKind `shouldBe` Merge
        other -> expectationFailure ("unexpected: " <> show other)
```

- [ ] **Step 2: Run — FAIL** (`RelationSelfLink` / `AddTransactionRelationTransactionCommand` not in scope).

- [ ] **Step 3: Implement**
- Add `RelationSelfLink` to `TransactionError` (with Haddock).
- Import `RelationSpec (..)` from `Domain.Core.Types` and the new command from `Domain.Transaction.Commands`.
- In the `InitiateTransaction` arm, at the point it currently returns `Right [TransactionPostingInitiatedTransactionEvent …]`, append the relation event when `relation = Just spec`:

```haskell
                  let postingEvt = TransactionPostingInitiatedTransactionEvent
                        TransactionPostingInitiated { … }  -- unchanged fields
                  Right $ postingEvt : case relation of
                    Nothing -> []
                    Just spec ->
                      [ TransactionRelationAddedTransactionEvent
                          TransactionRelationAdded
                            { relatedTransactionId = spec.relatedTransactionId,
                              relationKind = spec.relationKind
                            }
                      ]
```

(No self-link check here — the aggregate id is unknown to the pure handler; the service enforces it in Task 9. Structurally, a self-link is impossible at creation anyway since the new id is freshly generated.)

- Add the `AddTransactionRelation` arm (Completed-only; pure self-link check):

```haskell
handleTransactionCommand transaction (AddTransactionRelationTransactionCommand AddTransactionRelation {..})
  | unTransactionId transactionId == unTransactionId relatedTransactionId = Left RelationSelfLink
  | otherwise = case transaction ^. #status of
      Completed ->
        Right
          [ TransactionRelationAddedTransactionEvent
              TransactionRelationAdded
                { relatedTransactionId = relatedTransactionId,
                  relationKind = relationKind
                }
          ]
      _ -> Left CannotEditUncompletedTransaction
```

(Import `unTransactionId` — already imported in this module.)

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Domain/Transaction/CommandHandler.hs test/Domain/Transaction/RelationsCommandHandlerSpec.hs
git commit -m "feat(transaction): handle relation commands (emit TransactionRelationAdded)"
```

### Task 5: projection no-op + property

**Files:** `src/Domain/Transaction/Projection.hs`, test `test/Domain/Transaction/RelationsProjectionPropertySpec.hs`

- [ ] **Step 1: Write failing property**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Domain.Transaction.RelationsProjectionPropertySpec (spec) where

import Domain.Core.Types (RelationKind (..))
import Domain.Transaction.Events (TransactionRelationAdded (..))
import Domain.Transaction.Projection
import Test.Hspec
import Test.QuickCheck
-- import arbitrary Transaction + TransactionId generators from Testkit.Generators

spec :: Spec
spec =
  describe "TransactionRelationAdded projection" $
    it "is a no-op on aggregate state" $
      property $ \tx relatedId ->
        let evt = TransactionRelationAddedTransactionEvent (TransactionRelationAdded relatedId Refund)
         in handleTransactionEvent tx evt === tx
```

(`handleTransactionEvent` is not exported today — export it from `Domain.Transaction.Projection` for the test, mirroring how `handleTransactionCommand` is exported from `CommandHandler` for tests. Alternatively apply via `latestProjection transactionProjection [evt]` seeded from `tx`; match whichever pattern `LabelsProjectionSpec` uses.)

- [ ] **Step 2: Run — FAIL** (no handler arm; pattern-match incomplete under `-Wall`, or the arm falls through to a state change).

- [ ] **Step 3: Implement** — add to `handleTransactionEvent`:

```haskell
handleTransactionEvent transaction (TransactionRelationAddedTransactionEvent _) =
  -- Relationships are a read-model concern; the aggregate never gates on them.
  transaction
```

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Domain/Transaction/Projection.hs test/Domain/Transaction/RelationsProjectionPropertySpec.hs
git commit -m "feat(transaction): project TransactionRelationAdded as aggregate no-op"
```

---

## Phase 4 — Persistence orphan

### Task 6: `PersistField RelationKind`

**Files:** `src/Infrastructure/Database/Orphans.hs`

- [ ] **Step 1: Implement** (mirror the `StatusKind` instance at `Orphans.hs:290`)
- Extend the `Domain.Core.Types` import to bring `RelationKind`, `renderRelationKind`, `parseRelationKind` into scope (they are re-exported from `Core.Types`; the module already imports `Domain.Core.Types` broadly at line 25 — confirm the enum is covered by the existing wildcard import; if the import is explicit, add the three names).

```haskell
-- | 'RelationKind' stored as its lowercase wire token (a queryable enum column
-- for the transaction_relations reverse index).
instance PersistField RelationKind where
  toPersistValue = PersistText . renderRelationKind
  fromPersistValue v = do
    t <- fromPersistValue v
    maybe (Left ("Invalid RelationKind token: " <> t)) Right (parseRelationKind t)

instance PersistFieldSql RelationKind where
  sqlType _ = SqlString
```

- [ ] **Step 2: Build — PASS** (`just build`).

- [ ] **Step 3: Commit**

```bash
just format
git add src/Infrastructure/Database/Orphans.hs
git commit -m "feat(infra): PersistField instance for RelationKind"
```

---

## Phase 5 — Read model

### Task 7: `transaction_relations` table + apply arm

**Files:** `src/Application/ReadModels/Transaction.hs`

- [ ] **Step 1: Add the entity** to the `share [mkPersist …, mkMigrate "migrateTransaction"]` quasi-quote block (after `TransactionLabelEntity`):

```
TransactionRelationEntity sql=transaction_relations
    transactionId TransactionId
    relatedTransactionId TransactionId
    relationKind RelationKind
    UniqueTransactionRelation transactionId relatedTransactionId relationKind
    deriving Show Eq
```

- [ ] **Step 2: Import `RelationKind`** in the `Domain.Core.Types (…)` import list of this module.

- [ ] **Step 3: Add indexes** in `createTransactionIndexes`:

```haskell
        "CREATE INDEX IF NOT EXISTS idx_transaction_relations_from ON transaction_relations (transaction_id)",
        "CREATE INDEX IF NOT EXISTS idx_transaction_relations_to_kind ON transaction_relations (related_transaction_id, relation_kind)"
```

- [ ] **Step 4: Extend `resetTransaction`** to clear the new table first:

```haskell
resetTransaction = do
  deleteWhere ([] :: [Filter TransactionRelationEntity])
  deleteWhere ([] :: [Filter TransactionLabelEntity])
  deleteWhere ([] :: [Filter TransactionEntity])
```

- [ ] **Step 5: Add the apply arm** in `applyTransactionEvent` (the `txId` in that function IS the stream key — the "from" endpoint under R1). Import `TransactionRelationAdded (..)` in the `Domain.Models (…)` import list at the top:

```haskell
          TransactionRelationAddedEvent evt ->
            void (insertUnique (TransactionRelationEntity txId evt.relatedTransactionId evt.relationKind))
```

Place it with the other event arms; remove any now-redundant `_ -> pure ()` shadowing if the catch-all still covers the remaining events (keep the catch-all).

- [ ] **Step 6: Build — PASS.**

- [ ] **Step 7: Commit**

```bash
just format && just lint
git add src/Application/ReadModels/Transaction.hs
git commit -m "feat(readmodel): transaction_relations table + projection arm"
```

### Task 8: relation queries (forward, reverse-per-kind, batched)

**Files:** `src/Application/ReadModels/Transaction.hs`, test `test/Application/ReadModels/TransactionRelationsSpec.hs`

- [ ] **Step 1: Write failing tests** (follow `PersistentTransactionReadModelSpec` for the in-memory SQLite harness — it sets up a pool, runs `migrateTransaction`, applies events, and queries). Cases:
  - insert two Refund edges (A→P, B→P) via `applyTransactionEvent`; `reverseRelations P Refund` returns `[A, B]` (order-insensitive).
  - `relationsFrom A` returns `[(P, Refund)]`.
  - after marking A `Cancelled` (apply `TransactionCancellationCompletedEvent` on A), `reverseRelations P Refund` returns only `[B]` (auto-orphan: cancelled Refund "from" skipped).
  - **kind-specific skip:** insert a `Merge` edge S→T, then cancel S; `reverseRelations T Merge` still returns `[S]` (a merge source is *deliberately* cancelled — lineage must survive). This is the key difference: `liveFroms` filtering applies to `Refund` only.
  - `relationsFromMany [A, B]` returns a map `{A:[(P,Refund)], B:[(P,Refund)]}`.

- [ ] **Step 2: Run — FAIL** (functions not defined).

- [ ] **Step 3: Implement** and export `relationsFrom`, `relationsFromMany`, `reverseRelations`, `relationsTo`:

```haskell
-- | Outbound edges declared by a transaction: (relatedTransactionId, kind).
relationsFrom :: (MonadIO m) => TransactionId -> SqlPersistT m [(TransactionId, RelationKind)]
relationsFrom txId = do
  rows <- selectList [TransactionRelationEntityTransactionId ==. txId] []
  pure [(r.transactionRelationEntityRelatedTransactionId, r.transactionRelationEntityRelationKind) | Entity _ r <- rows]

-- | Outbound edges for many transactions in one query (avoids N+1 on list responses).
relationsFromMany :: (MonadIO m) => [TransactionId] -> SqlPersistT m (Map TransactionId [(TransactionId, RelationKind)])
relationsFromMany [] = pure Map.empty
relationsFromMany txIds = do
  rows <- selectList [TransactionRelationEntityTransactionId <-. txIds] []
  pure $ Map.fromListWith (<>)
    [ (r.transactionRelationEntityTransactionId,
       [(r.transactionRelationEntityRelatedTransactionId, r.transactionRelationEntityRelationKind)])
    | Entity _ r <- rows ]

-- | Inbound edges of a given kind pointing at a transaction. For 'Refund' the
-- cancelled-"from" edges are skipped (auto-orphan, decision 3); for 'Merge'/'Split'
-- the "from" is deliberately cancelled (lineage) and is kept.
-- e.g. refundsOf = reverseRelations _ Refund.
reverseRelations :: (MonadIO m) => TransactionId -> RelationKind -> SqlPersistT m [TransactionId]
reverseRelations txId kind = do
  rows <- selectList [TransactionRelationEntityRelatedTransactionId ==. txId, TransactionRelationEntityRelationKind ==. kind] []
  let froms = [r.transactionRelationEntityTransactionId | Entity _ r <- rows]
  if kind == Refund then liveFroms froms else pure froms

-- | All inbound edges (any kind) pointing at a transaction. Refund edges from a
-- Cancelled source are skipped; Merge/Split lineage is kept even when cancelled.
relationsTo :: (MonadIO m) => TransactionId -> SqlPersistT m [(TransactionId, RelationKind)]
relationsTo txId = do
  rows <- selectList [TransactionRelationEntityRelatedTransactionId ==. txId] []
  let pairs = [(r.transactionRelationEntityTransactionId, r.transactionRelationEntityRelationKind) | Entity _ r <- rows]
      refundFroms = [f | (f, Refund) <- pairs]
  liveRefund <- Set.fromList <$> liveFroms refundFroms
  pure [p | p@(f, k) <- pairs, k /= Refund || Set.member f liveRefund]

-- | Filter a list of "from" transaction ids down to those NOT Cancelled.
liveFroms :: (MonadIO m) => [TransactionId] -> SqlPersistT m [TransactionId]
liveFroms [] = pure []
liveFroms ids = do
  rows <- selectList [TransactionEntityTransactionId <-. ids, TransactionEntityStatusKind !=. CancelledKind] []
  pure [e.transactionEntityTransactionId | Entity _ e <- rows]
```

Add `relationsFrom`, `relationsFromMany`, `reverseRelations`, `relationsTo` to the module export list.

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Commit**

```bash
just format && just lint
git add src/Application/ReadModels/Transaction.hs test/Application/ReadModels/TransactionRelationsSpec.hs
git commit -m "feat(readmodel): forward + reverse relation queries with cancelled-endpoint skip"
```

---

## Phase 6 — Errors & service

### Task 9: `DomainError` constructors + income refund validation + service hooks

**Files:** `src/Domain/Core/Errors.hs`, `src/Web/ErrorMapping.hs`, `src/Application/Services/TransactionService.hs`, test `test/Application/Services/TransactionServiceSpec.hs` (add refund cases) — or a focused new spec if simpler.

**9a — Errors**

- [ ] Add to `DomainError` (before the final `deriving`): `RefundTargetMustBeExpense`, `CannotRefundCancelledTransaction`, `CannotRelateTransactionToItself`, `CannotChainRelations` (all nullary), each with a Haddock line.
- [ ] Add `renderDomainError` arms (in the `case err of`):

```haskell
  RefundTargetMustBeExpense -> "Refund target must be an expense transaction"
  CannotRefundCancelledTransaction -> "Cannot refund a cancelled transaction"
  CannotRelateTransactionToItself -> "A transaction cannot be related to itself"
  CannotChainRelations -> "Relations cannot be chained (depth-1 only)"
```

- [ ] Add `Web.ErrorMapping.mapDomainError` arms: all four are 422 except pick per taste — recommended: `CannotRefundCancelledTransaction` → `err409`, the other three → `err422`. Follow the existing `err422`/`err409` arm shape (they build a JSON body with a code + message; copy an adjacent arm and give a snake-case code, e.g. `REFUND_TARGET_MUST_BE_EXPENSE`).
- [ ] Build — PASS. Commit: `feat(errors): relation validation errors + HTTP mapping`.

**9b — Service: translate handler error**

- [ ] In `TransactionService.translateTransactionError`, add:

```haskell
translateTransactionError (CommandRejected TxCh.RelationSelfLink) = CannotRelateTransactionToItself
```

**9c — Service: `getOutboundRelations`**

- [ ] Add a thin wrapper (exported):

```haskell
getOutboundRelations :: TransactionId -> AppM [(TransactionId, RelationKind)]
getOutboundRelations txId = runDb (ReadModel.relationsFrom txId)
```

**9d — Service: refund validation in `initiateIncome`**

- [ ] Change `initiateIncome` to accept a `Maybe TransactionId` (the refund target). Add a validation helper and thread `relation` into the `InitiateTransaction`:

```haskell
-- | Validate a refund target and produce the RelationSpec to attach. Runs the
-- common (exists/visible/self/depth) + Refund-specific (Expense/not-cancelled) rules.
validateRefundTarget :: UserId -> TransactionId -> TransactionId -> AppM (Either DomainError RelationSpec)
validateRefundTarget userId newTxId targetId = runExceptT $ do
  when (unTransactionId newTxId == unTransactionId targetId) $ throwE CannotRelateTransactionToItself
  target <- ExceptT (ensureVisible userId targetId)          -- NotFound if absent/invisible
  case target.transactionType of
    Expense _ -> pure ()
    _ -> throwE RefundTargetMustBeExpense
  when (target.status == Cancelled) $ throwE CannotRefundCancelledTransaction
  -- depth-1: target must not itself declare an outbound Refund edge
  outbound <- lift (getOutboundRelations targetId)
  when (any ((== Refund) . snd) outbound) $ throwE CannotChainRelations
  pure (RelationSpec targetId Refund)
```

- `ensureVisible`/`ensureVisibleAccess` = a read-only sibling of `ensureEditorAccess` requiring *any* role (Viewer+) on a leg. Build it by copying `ensureEditorAccess` but swapping `canModifyAccount` for **`canAccessAccount`** (both live in `Application.Services.AuthorizationService` and already exported; `canAccessAccount` is the Viewer+ predicate the spec's "visible to the caller (any role)" wants).
- The new txId is generated inside `initiateTransaction`. To keep the self-link check meaningful, generate the id in `initiateIncome` *before* dispatch and pass it down, OR (simpler, and correct because a fresh UUID can never equal an existing target) rely on the fresh-id guarantee and drop the `newTxId == targetId` check. **Recommended:** keep `validateRefundTarget` taking only `userId` + `targetId` (drop `newTxId`); a freshly generated id cannot collide, so the structural self-link case is vacuous for the income path and remains enforced only for `AddTransactionRelation`. Update the signature accordingly.
- In `initiateIncome`, when the caller passed `Just targetId`, run `validateRefundTarget` and set `relation = Just spec` on the built `InitiateTransaction`; otherwise `relation = Nothing`.

**9e — Service: `recordTransactionRelation` (Merge/Split hook)**

- [ ] Add the generic internal function (exported for future merge/split ops):

```haskell
-- | Record a typed relationship on an existing transaction (Merge/Split lineage).
-- Runs common + per-kind validation, then dispatches AddTransactionRelation on
-- the "from" stream. NOT a public endpoint.
recordTransactionRelation :: UserId -> TransactionId -> TransactionId -> RelationKind -> AppM (Either DomainError ())
recordTransactionRelation userId fromId toId kind = runExceptT $ do
  when (unTransactionId fromId == unTransactionId toId) $ throwE CannotRelateTransactionToItself
  _ <- ExceptT (ensureVisibleAccess userId fromId)
  _ <- ExceptT (ensureVisibleAccess userId toId)
  -- per-kind cancelled-endpoint rules
  target <- liftMaybeM (NotFound "Transaction" (tshow toId)) (runDb (ReadModel.getTransaction toId))
  case kind of
    Refund -> do
      case target.transactionType of Expense _ -> pure (); _ -> throwE RefundTargetMustBeExpense
      when (target.status == Cancelled) $ throwE CannotRefundCancelledTransaction
    Merge -> pure ()   -- target is the surviving transaction; may be Completed
    Split -> pure ()   -- origin may or may not be cancelled
  -- depth-1
  outbound <- lift (getOutboundRelations toId)
  when (any ((== kind) . snd) outbound) $ throwE CannotChainRelations
  runTransactionCmd translateTransactionError id (unTransactionId fromId)
    (AddTransactionRelationTransactionCommand (AddTransactionRelation fromId toId kind))
```

(Confirm imports: `AddTransactionRelation`, `AddTransactionRelationTransactionCommand`, `RelationSpec`, `RelationKind`, `when`, `Cancelled`.)

- [ ] Update the exports of `TransactionService` to add `initiateIncome` (signature changed), `recordTransactionRelation`, `getOutboundRelations`.

- [ ] **Tests (9):** add service-level cases (use the existing `TransactionServiceSpec` harness / in-memory event store fixtures):
  - refund income linked to a Completed expense → succeeds; `getOutboundRelations` on the new tx returns `[(expenseId, Refund)]`.
  - refund target is an Income → `Left RefundTargetMustBeExpense`.
  - refund target is Cancelled → `Left CannotRefundCancelledTransaction`.
  - refund target absent/invisible → `Left (NotFound "Transaction" …)`.
  - `recordTransactionRelation … Merge` on a Completed target → succeeds; reverse index shows it.

- [ ] Build + targeted tests PASS. Commit: `feat(transaction): refund-target validation + relation service hooks`.

---

## Phase 7 — Web layer

### Task 10: DTOs

**Files:** `src/Web/Types.hs`, test `test/Web/TypesSpec.hs`

- [ ] **Step 1: Write failing tests** — JSON encode/shape for `RelationResponse` and `TransactionRelationsResponse`; `IncomeRequest` decodes with and without `relatedTransactionId`.

- [ ] **Step 2: Implement**
- `IncomeRequest`: add `relatedTransactionId :: Maybe UUID`. Confirm its `FromJSON` tolerates the field's absence (a `Maybe` via generic instance already defaults to `Nothing` if the field's parser uses `.:?`; if `IncomeRequest` uses generic `FromJSON`, absence of a `Maybe` field decodes to `Nothing` automatically — verify with a decode test of an existing income JSON without the field).
- Add:

```haskell
data RelationResponse = RelationResponse
  { transactionId :: UUID,
    relatedTransactionId :: UUID,
    relationKind :: Text
  }
  deriving (Show, Eq, Generic)
instance ToJSON RelationResponse
instance FromJSON RelationResponse

data TransactionRelationsResponse = TransactionRelationsResponse
  { outbound :: [RelationResponse],
    inbound :: [RelationResponse]
  }
  deriving (Show, Eq, Generic)
instance ToJSON TransactionRelationsResponse
instance FromJSON TransactionRelationsResponse
```

- `TransactionResponse`: add `relations :: [RelationResponse]`.
- Change `fromTransactionData` to take outbound edges:

```haskell
fromTransactionData :: TransactionId -> [(TransactionId, RelationKind)] -> TransactionData -> TransactionResponse
fromTransactionData txId outbound td =
  TransactionResponse
    { …existing fields…,
      relations =
        [ RelationResponse (unTransactionId txId) (unTransactionId rel) (renderRelationKind k)
        | (rel, k) <- outbound
        ]
    }
```

(Import `RelationKind`, `renderRelationKind`, `unTransactionId`. Keep `fromTransaction` (the legacy aggregate variant) building `relations = []`.)

- [ ] **Step 3: Build — expect failures at all `fromTransactionData` call sites** (Task 11 fixes them).

- [ ] **Step 4: Commit after Task 11 builds** (grouped, since the signature change forces call-site edits).

### Task 11: handlers + `GET /:id/relations`

**Files:** `src/Web/API/TransactionAPI.hs`, test `test/Web/API/TransactionRelationsAPISpec.hs`

- [ ] **Step 1: Wire ALL `fromTransactionData` call sites** (11 total — `TransactionAPI.hs` ×9, plus `AccountAPI.hs` and `PromptAPI.hs`):
  - Single-item handlers in `TransactionAPI.hs` (`income`, `expense`, `transfer`, `labels`, `allocations`, `description`, `date`, `amendment`, `get`): fetch `edges <- TransactionService.getOutboundRelations txId` and pass to `fromTransactionData txId edges td`. Expense/transfer/get-of-a-non-refund will get `[]`.
  - `AccountAPI.hs:378` (`adjustBalanceHandler`, an Adjustment tx) and `PromptAPI.hs:125` (`promptHandler`, NL-created tx): both pass `[]` — these paths never declare a relation. `fromTransactionData txId [] txData`. (No new import needed beyond what's already there.)
  - `listTransactionsHandler`: after obtaining `results :: [(TransactionId, TransactionData)]`, batch `edgeMap <- runDb (ReadModel.relationsFromMany (map fst results))` (or add a service wrapper `getOutboundRelationsMany`), then `map (\(tid, td) -> fromTransactionData tid (Map.findWithDefault [] tid edgeMap) td) results`. **Do not** call `getOutboundRelations` per row (N+1). Add `TransactionService.getOutboundRelationsMany :: [TransactionId] -> AppM (Map TransactionId [(TransactionId, RelationKind)])` delegating to `ReadModel.relationsFromMany`.
- [ ] **Step 2: `incomeHandler`** — parse `request.relatedTransactionId` (a `Maybe UUID`) into `Maybe TransactionId` via `traverse (validateField "relatedTransactionId" . mkTransactionId)`, and pass to `TransactionService.initiateIncome` (new arg).
- [ ] **Step 3: Add the endpoint** to `TransactionAPI` type and `transactionServer`:

```haskell
    :<|> AuthProtect "jwt" :> "api" :> "transactions" :> Capture "id" UUID :> "relations"
      :> Get '[JSON] TransactionRelationsResponse
```

Place it near the `history` endpoint; add `relationsHandler` to the server tuple in the matching position.

```haskell
relationsHandler :: AuthenticatedUser -> UUID -> AppM TransactionRelationsResponse
relationsHandler user rawId = do
  transactionId <- validateField "id" (mkTransactionId rawId)
  -- visibility: reuse getTransaction's access path (404 if not visible/absent)
  _ <- either throwDomainError pure =<< (fmap (const (Right ())) <$> …)  -- see note
  outbound <- TransactionService.getOutboundRelations transactionId
  inbound <- runDb (ReadModel.relationsTo transactionId)
  let mk (a, b, k) = RelationResponse (unTransactionId a) (unTransactionId b) (renderRelationKind k)
  pure $ TransactionRelationsResponse
    { outbound = [mk (transactionId, rel, k) | (rel, k) <- outbound],
      inbound  = [mk (frm, transactionId, k) | (frm, k) <- inbound] }
```

**Visibility:** enforce the same check `getTransactionHandler` effectively allows. `getTransactionHandler` currently does NOT scope by access (it returns any transaction by id). For consistency, `relationsHandler` should apply at least the same behavior; if a visibility gate is desired, reuse `ensureVisibleAccess` via a small service function `TransactionService.getTransactionRelationsFor userId txId` that returns `Either DomainError TransactionRelationsResponse`-worth of data. **Recommended:** add `TransactionService.getRelations :: UserId -> TransactionId -> AppM (Either DomainError ([(TransactionId,RelationKind)], [(TransactionId,RelationKind)]))` that runs `ensureVisibleAccess` then returns `(outbound, inbound)`, and have the handler map/throw. This keeps access logic in the service. Implement that and simplify the handler accordingly.

- [ ] **Step 4: Build — PASS.**

- [ ] **Step 5: HTTP tests** in `test/Web/API/TransactionRelationsAPISpec.hs` (follow `TransactionLabelsAPISpec` for the wai/hspec harness): income create with `relatedTransactionId` → 200 and `relations` present; `GET /:id/relations` returns inbound+outbound; non-expense target → 422 `REFUND_TARGET_MUST_BE_EXPENSE`; cancelled target → 409; self-link path (via `AddTransactionRelation`) covered in integration.

- [ ] **Step 6: Commit** (Tasks 10+11 together):

```bash
just format && just lint
git add src/Web/Types.hs src/Web/API/TransactionAPI.hs src/Application/Services/TransactionService.hs test/Web/…
git commit -m "feat(web): expose transaction relations on responses + GET /:id/relations"
```

---

## Phase 8 — Reporting

### Task 12: `applyRefunds` pure helper + `spendingByCategory` wiring

**Files:** `src/Application/Services/ReportingService.hs`, test `test/Application/Services/RefundReportingSpec.hs`

- [ ] **Step 1: Write failing tests** (pure, no DB) for `applyRefunds`:
  - single-category expense E (cat X, 100), one refund income R (30) linked E→? — R is the "from", E is the related; input is `[(refundIncomeTx, refundedExpenseTx)]` resolved to amounts. Net for X = 100 − 30 = 70.
  - multi-category expense E (X:60, Y:40 = 100), refund 50 → pro-rata: X −30, Y −20 → X:30, Y:20.
  - cross-currency refund (refund income currency ≠ expense category currency) → skipped (no change), and the test asserts the category is unaffected.
  - refund whose linked expense is not in the reportable set → ignored.

- [ ] **Step 2: Implement** a pure function operating on already-materialised data. Signature (adjust to what `spendingByCategory` can cheaply supply):

```haskell
-- | Given base currency, the per-category spend map from aggregateSpending, and
-- each reportable expense paired with its (non-cancelled) refund income txns,
-- subtract each refund's total from the expense's categories pro-rata by the
-- expense's expense-bucket weights. Same-currency only: a refund whose income
-- currency differs from the expense's category currency is skipped.
applyRefunds :: Currency -> Map CategoryId Money -> [(TransactionData, [TransactionData])] -> Map CategoryId Money
```

(This signature intentionally supersedes the spec's *illustrative* `applyRefunds`
signature — it threads the pre-computed `aggregateSpending` output and resolved refund
`TransactionData` rather than re-deriving them. Implement the plan's shape.)

Compute, for each `(expense, refunds)`: the expense's expense-bucket allocations (in base via `allocationBase`), the total refund amount (income-bucket of each refund, in base, skipping currency mismatches), then distribute `−refundTotal` across the expense's categories proportionally to their base weights. Fold the deltas into the incoming per-category map (the output of `aggregateSpending`).

- [ ] **Step 3: Run — PASS.**

- [ ] **Step 4: Wire into `spendingByCategory`** (effectful): after `txs <- runDb (reportableTransactions …)` and `perCat = aggregateSpending base txs`, fetch refunds for the reportable expenses:

```haskell
  let expenses = [t | t <- txs, Expense _ <- [t.transactionType]]  -- established idiom in ReportingService (no isExpense helper exists)
  refundMap <- forM expenses $ \e -> do
    -- reverseRelations needs the expense's TransactionId; reportableTransactions
    -- must therefore return ids. If it does not, add a variant that does
    -- (reportableTransactionsWithIds) — see note.
    …
  let perCatNet = applyRefunds base perCat (zip expenses refundIncomeLists)
```

**Blocker to resolve:** `reportableTransactions` currently returns `[TransactionData]` **without ids**, but `reverseRelations` needs the expense's `TransactionId`. Add `reportableTransactionsWithIds :: Set AccountId -> Maybe UTCTime -> Maybe UTCTime -> SqlPersistT m [(TransactionId, TransactionData)]` (trivial variant of the existing query returning `withLabels rows` instead of `map snd`), and have `spendingByCategory` use it so each expense id is available to fetch `reverseRelations id Refund` and then load those refund incomes' `TransactionData` (batch by id set). Keep `incomeVsExpense` on the existing id-less query (out of scope — refund netting is per-category spend only for this issue).

- [ ] **Step 5: Build + tests PASS.** Commit: `feat(reporting): net refund-linked income out of per-category spend`.

---

## Phase 9 — Integration & final verification

### Task 13: end-to-end integration spec

**Files:** `test/Integration/TransactionRelationsIntegrationSpec.hs` (follow `TransactionCancellationIntegrationSpec` for the event-store harness; requires the `eventium_test` DB).

- [ ] **Cases:**
  - Post an expense (purchase P); post an income refund R linked to P → `ReadModel.reverseRelations P Refund == [R]`; `relationsFrom R == [(P, Refund)]`.
  - Cancel the refund R → `reverseRelations P Refund == []` (auto-orphan: the cancelled Refund "from" is skipped, per Task 8's `liveFroms`).
  - `recordTransactionRelation user src tgt Merge` then cancel `src` → `reverseRelations tgt Merge == [src]` (a Merge source is deliberately cancelled; the kind-specific filter keeps it — the guard against regressing this is why Task 8 filters `Refund` only).
  - Refund netting end-to-end: post expense (cat X, 100) and a linked refund income (30); `spendingByCategory` reports X net = 70.

### Task 14: full verification & docs

- [ ] **Run the whole targeted suite:**

```bash
just docker-up           # start postgres; ensure eventium_test DB exists (create manually if needed)
just rebuild             # definitive -Werror build (lib+exe+test)
cabal test all --test-option='--match' --test-option="/Relation/"
cabal test all --test-option='--match' --test-option="/Refund/"
just test                # full suite (expect only known env failures if eventium_test absent)
just lint
```

- [ ] **Update the spec's status** frontmatter to `status: completed` if the team convention is to do so on merge (check recent merged specs; several stay `draft`). Leave as-is if unsure.
- [ ] **Update `docs/architecture.md`** if it enumerates transaction events/read-model tables (grep for `transaction_labels` / event list); add `transaction_relations` and `TransactionRelationAdded` to keep the living doc accurate.
- [ ] **Final commit:**

```bash
just format
git add -A
git commit -m "docs(transaction): record transaction_relations in architecture doc"
```

- [ ] **PR:** open against `master` with title `feat(transaction): typed transaction relationships (refunds + merge/split lineage) (#88)`; body summarizes the substrate, the Refund wiring, the internal Merge/Split hook, and the deferred items (cross-currency refund reporting).

---

## Verification checklist (acceptance criteria → tasks)

- [ ] `RelationKind` + relation payload modelled; edges are events — Tasks 1–2, 4
- [ ] Per-kind validation (existence + access + cancelled-endpoint rules incl. the Refund/Merge contradiction) — Tasks 8, 9
- [ ] Income posts can specify a `Refund` edge; service validates — Tasks 9, 11
- [ ] `TransactionResponse` carries outbound relations; reverse index queryable per kind — Tasks 8, 10, 11
- [ ] Internal `recordTransactionRelation` for merge/split — Task 9e
- [ ] Per-category net-spend accounts for `Refund` edges — Task 12
- [ ] Tests: unit (handler incl. cancelled-endpoint contradiction), integration (purchase → refund → reverse index; simulate merge/split), HTTP — Tasks 4, 8, 9, 11, 13

## Known deferrals (do not implement)

- Cross-currency refund netting in reports (edge recorded; report skips mismatched currency).
- Merge (tracker#30) / split (tracker#31) *operations* — only their `recordTransactionRelation` hook lands here.
- Automatic refund detection from bank imports.
