# Live Data-Change Signal + Balance/Transaction Consistency — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every open client a coarse, per-user "your data changed" signal that fires on any out-of-band Account/Transaction write, and make the web UI show balance and transactions consistently (never a new balance beside a stale list).

**Architecture:** Backend adds a DB-backed persistent read model (`sync_data_version`) that, inside the event-append transaction, increments a per-user counter for every user who can see an affected account — race-free because the counter row and the event data commit atomically. A tiny `GET /api/sync/version` exposes the caller's counter. The web client polls it and, on any change, invalidates a fixed key set; a coordinating view then swaps balance + the displayed transaction window in together, backed by a paging fix that makes the list settle in one shot.

**Tech Stack:** Haskell (GHC 9.10, RIO, Servant, persistent/eventium, hspec/QuickCheck); TypeScript React + TanStack Query + Vitest (`../monorepo`).

**Spec:** `docs/specs/2026-08-10-live-data-change-signal-design.md`

**Branch:** `feat/live-data-change-signal` (already created off `master`).

**Phasing:** Phase A (backend) is independently mergeable — it produces a tested read model + endpoint on its own. Phase B (web, in `../monorepo`) consumes the endpoint and can merge separately. Commit after every task. Note: GPG signing is unavailable this session; commit with `--no-gpg-sign` (re-sign later if required).

---

## Reference facts (verified against the codebase — rely on these)

- **`GlobalStreamEvent AccountingEvent` is doubly nested.** In an event handler `ge`:
  - `ge.payload` = inner `VersionedStreamEvent AccountingEvent`; call it `inner`.
  - `inner.key :: UUID` = the aggregate stream key (an accountId for Account events, a transactionId for Transaction events). Parse with `mkAccountIdSafe` / `mkTransactionIdSafe`.
  - `inner.payload :: AccountingEvent` = the decoded event; match its `…Event`-suffixed constructors.
- **Account events carry the accountId as the stream key**, not a payload field. Balance changes are `AccountDebitedEvent` / `AccountCreditedEvent` (Account events), so the transfer saga's money movement is captured on the Account branch.
- **`AccountAccessRevokedEvent`** payload has `userId :: UserId` = the *revoked* user (must be bumped explicitly — they're already gone from `account_access`). **`AccountAccessGrantedEvent`** payload has `userId` = the grantee (already inserted into `account_access` by the Account read model, which runs *before* this one).
- **Transaction posting/amend/merge events carry accounts in the payload:** `TransactionPostingInitiatedEvent { sourceAccountId, targetAccountId, … }`; amend/merge use `newSourceAccountId` / `newTargetAccountId`.
- **Transaction in-place-edit events carry only a `transactionId`** (no accountId): `TransactionLabelsSetEvent`, `TransactionContactSetEvent`, `TransactionAllocationsChangedEvent`, `TransactionDescriptionChangedEvent`, `TransactionDateChangedEvent`, `TransactionCancellation{Initiated,Completed}Event`, `TransactionImportReconciledEvent`. Relation events (`TransactionRelation{Added,Removed}Event`) reference the "from" transaction via the **stream key**. All of these require a transactionId→accounts lookup in the Transaction read model.
- **`account_access` includes the owner** (written with role `Owner` at creation), so "all users who can access account X" = `selectList [AccountAccessEntityAccountId ==. accId] []`. No union with `accounts.created_by` needed.
- Persistent read models use plain `Database.Persist` (`getBy`, `selectList`, `insertUnique`, `deleteWhere`, `upsert`, `rawExecute`) — **no esqueleto**. Custom column types need `import Infrastructure.Database.Orphans ()`.
- Each read model owns its migration (`mkMigrate` + `runMigrationSilent` in `initialize`); there is no central `migrateAll`. Registering in `persistentReadModels` wires both live in-transaction updates and startup catch-up/migration.
- `SqlIO = SqlPersistT IO` (`Infrastructure.Database`).

---

## File Structure

**Phase A — backend (`server-infra`)**
- Create `src/Application/ReadModels/DataVersion.hs` — the `sync_data_version` entity + migration, projection name, pure event→scope classifier, effectful handler, `bumpVersions`, `getDataVersion`, `dataVersionReadModel`. One responsibility: maintain + read the per-user change counter.
- Modify `src/Application/ReadModels/Transaction.hs` — export a `transactionAccounts :: TransactionId -> SqlPersistT m [AccountId]` helper (reused by DataVersion to map edit events to accounts).
- Modify `src/Application/ReadModels/Persist.hs` — register `dataVersionReadModel`.
- Create `src/Web/API/SyncAPI.hs` — `GET /api/sync/version` endpoint + handler.
- Modify `src/Web/Types.hs` — `SyncVersionResponse` DTO.
- Modify `src/Web/API.hs` — wire `SyncAPI` into `type API` and `server`.
- Create `test/Application/ReadModels/DataVersionSpec.hs` — unit tests for the pure classifier.
- Create `test/Application/ReadModels/DataVersionIntegrationSpec.hs` — DB-backed tests (needs `eventium_test`).
- Modify `package.yaml` only if a new module needs no extra deps (it won't) — hpack picks up new files automatically; run `just build` which runs hpack.

**Phase B — web (`../monorepo`)**
- Create `src/features/sync/useDataChangeSignal.ts` — poll + invalidate hook (the transport-agnostic seam).
- Create `src/api/sync.ts` — `getSyncVersion()` client call.
- Create `src/features/transactions/useConsistentAccountView.ts` (name per local convention) — atomic balance+list swap.
- Modify `src/features/transactions/useWindowedTransactions.ts` — paging fix.
- Modify `src/features/transactions/useEditTransaction.ts` — phantom-key fix.
- Mount `useDataChangeSignal` once under the authenticated app shell (e.g. `src/App.tsx` or the authed layout).
- Tests colocated per existing `*.test.ts(x)` convention in each feature folder.

---

# PHASE A — Backend

## Task A1: `transactionAccounts` helper on the Transaction read model

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs` (add to export list + define function)
- Test: `test/Application/ReadModels/TransactionIntegrationSpec.hs` (add a case; create if the file doesn't exist, following an existing `*IntegrationSpec.hs`)

- [ ] **Step 1: Write the failing test** — after seeding a transfer transaction, `transactionAccounts txId` returns both the source and target account ids (deduped); for a single-entry transaction it returns the one non-duplicate account; for an unknown id, `[]`.

```haskell
-- in an integration spec that already builds a SqlPersistT runner over eventium_test
it "returns both accounts of a transfer, deduped" $ \pool -> do
  -- seed via the transaction read model's event handler or a posting event
  accs <- runDb pool (transactionAccounts seededTransferId)
  accs `shouldMatchList` [sourceAcc, targetAcc]

it "returns [] for an unknown transaction" $ \pool -> do
  -- build an unknown id via the safe/smart ctor (there is no mkTransactionIdUnsafe;
  -- use mkTransactionIdSafe or a Testkit id helper)
  accs <- runDb pool (transactionAccounts unknownTxId)
  accs `shouldBe` []
```

- [ ] **Step 2: Run it, verify it fails** — `cabal test all --test-option='--match' --test-option="/transactionAccounts/"` → FAIL (not in scope / undefined). (Full `cabal test all` needs a manually-created `eventium_test` Postgres DB — see CLAUDE.md; if unavailable, run the unit specs and note the integration gap.)

- [ ] **Step 3: Implement + export**

```haskell
-- add `transactionAccounts` to the module export list

-- | Distinct non-external accounts a transaction posts to (source + target).
-- Used by the DataVersion read model to attribute an edit event (which carries
-- only a transactionId) to the accounts whose users must be signalled.
transactionAccounts :: (MonadIO m) => TransactionId -> SqlPersistT m [AccountId]
transactionAccounts txId = do
  mEnt <- getBy (UniqueTransactionId txId)   -- match the actual unique key name in this module
  pure $ case mEnt of
    Nothing -> []
    Just (Entity _ e) -> nub [e.transactionEntitySourceAccountId, e.transactionEntityTargetAccountId]
```

Verify the real field/unique-constructor names in this module (they were reported as `sourceAccountId`/`targetAccountId` columns on `TransactionEntity`); adjust selector names to the generated ones. `nub` from `RIO.List`.

- [ ] **Step 4: Run test, verify pass.**
- [ ] **Step 5: Commit** — `git commit --no-gpg-sign -m "feat(readmodel): expose transactionAccounts for change-signal attribution"`

---

## Task A2: Pure event→scope classifier (unit-tested, no DB)

**Files:**
- Create: `src/Application/ReadModels/DataVersion.hs` (start the module with just the pure part + types)
- Test: `test/Application/ReadModels/DataVersionSpec.hs`

The classifier isolates all event-shape knowledge into a pure, exhaustively-tested function, keeping the SQL handler thin.

- [ ] **Step 1: Write failing unit tests** for `classifyEvent :: UUID -> AccountingEvent -> EventScope`:

```haskell
-- EventScope accumulates what a single event implies about who to bump.
-- data EventScope = EventScope
--   { directAccounts :: [AccountId]      -- accounts known straight from the event
--   , viaTransaction :: Maybe TransactionId  -- resolve accounts from the tx read model
--   , extraUsers     :: [UserId]         -- e.g. a revoked user, gone from account_access
--   }

describe "classifyEvent" $ do
  it "account lifecycle → the stream-key account" $
    classifyEvent accUuid (AccountRenamedEvent renamed)
      `shouldBe` EventScope [accId] Nothing []
  it "access revoked → the account AND the revoked user" $
    classifyEvent accUuid (AccountAccessRevokedEvent revoked{userId = revokedUser})
      `shouldBe` EventScope [accId] Nothing [revokedUser]
  it "posting initiated → both source and target accounts" $
    classifyEvent txUuid (TransactionPostingInitiatedEvent posting)
      `shouldBe` EventScope [sourceAcc, targetAcc] Nothing []
  it "label edit → via the transaction id" $
    classifyEvent txUuid (TransactionLabelsSetEvent lbl{transactionId = txId})
      `shouldBe` EventScope [] (Just txId) []
  it "pure system signal → empty scope" $
    classifyEvent txUuid (TransactionPostingCompletedEvent completed)
      `shouldBe` EventScope [] Nothing []
```

Use the mock/smart constructors from `Testkit/Helpers.hs` / `Testkit/Generators.hs` to build event payloads; reuse existing fixtures rather than hand-rolling.

- [ ] **Step 2: Run, verify fail** — `cabal test all --test-option='--match' --test-option="/classifyEvent/"` → FAIL (undefined).

- [ ] **Step 3: Implement the pure classifier.** **Do not** match the flat `AccountingEvent` with a catch-all — a `_ -> emptyScope` makes the match exhaustive and *defeats* `-Wincomplete-patterns`, so a future Account/Transaction event would silently map to "no invalidation" with no compile error. Instead, **project into the two smaller event sum types** via the existing embeddings (`accountEventEmbedding` / `transactionEventEmbedding` in `Domain.Models` — confirm their exact projection API; they give `AccountingEvent -> Maybe AccountEvent` / `-> Maybe TransactionEvent`), then match `AccountEvent` and `TransactionEvent` **exhaustively with no catch-all**. Now a new constructor in either family forces a compile-time decision. Sketch:

```haskell
data EventScope = EventScope
  { directAccounts :: [AccountId],
    viaTransaction :: Maybe TransactionId,
    extraUsers :: [UserId]
  }
  deriving (Show, Eq)

emptyScope :: EventScope
emptyScope = EventScope [] Nothing []

classifyEvent :: UUID -> AccountingEvent -> EventScope
classifyEvent streamKey ev =
  case (projectAccountEvent ev, projectTransactionEvent ev) of
    (Just ae, _) -> classifyAccount streamKey ae
    (_, Just te) -> classifyTransaction streamKey te
    _            -> emptyScope        -- User / Configuration / ExchangeRate — genuinely out of scope
  where
    -- use whatever the embedding exposes; e.g. accountEventEmbedding's projection
    projectAccountEvent = ...
    projectTransactionEvent = ...

-- Account family: accountId is the stream key. NO catch-all — list every AccountEvent constructor.
classifyAccount :: UUID -> AccountEvent -> EventScope
classifyAccount streamKey ae = case ae of
  AccountCreated _        -> acc
  AccountRenamed _        -> acc
  AccountDebited _        -> acc
  AccountCredited _       -> acc
  AccountDebitReversed _  -> acc
  AccountCreditReversed _ -> acc
  OverdraftLimitSet _     -> acc
  AccountSubtypeSet _     -> acc
  AccountCurrencyChanged _-> acc
  AccountClosed _         -> acc
  AccountReopened _       -> acc
  AccountAccessGranted _  -> acc                       -- grantee already in account_access (Account RM ran first)
  AccountAccessRevoked e  -> acc { extraUsers = [e.userId] }
  where
    acc = maybe emptyScope (\a -> emptyScope { directAccounts = [a] }) (mkAccountIdSafe streamKey)

-- Transaction family. NO catch-all — list every TransactionEvent constructor (incl. the
-- *Failed / MergeCompleted ones the first draft missed).
classifyTransaction :: UUID -> TransactionEvent -> EventScope
classifyTransaction streamKey te = case te of
  TransactionPostingInitiated e   -> both e.sourceAccountId e.targetAccountId
  TransactionAmendmentInitiated e -> both e.newSourceAccountId e.newTargetAccountId
  TransactionAmendmentCompleted e -> both e.newSourceAccountId e.newTargetAccountId
  TransactionMergeInitiated e     -> both e.newSourceAccountId e.newTargetAccountId
  TransactionLabelsSet e          -> viaTx e.transactionId
  TransactionContactSet e         -> viaTx e.transactionId
  TransactionAllocationsChanged e -> viaTx e.transactionId
  TransactionDescriptionChanged e -> viaTx e.transactionId
  TransactionDateChanged e        -> viaTx e.transactionId
  TransactionCancellationInitiated e -> viaTx e.transactionId
  TransactionCancellationCompleted e -> viaTx e.transactionId
  TransactionImportReconciled e   -> viaTx e.transactionId
  TransactionRelationAdded _      -> viaStreamKeyTx      -- NOTE: bumps only the "from" side (stream key)
  TransactionRelationRemoved _    -> viaStreamKeyTx      --       users who see only the "to" tx are not signalled (accepted)
  -- pure system/saga signals — nothing user-visible changed on its own; balance moves
  -- are carried by the Account Debited/Credited events, so these are safely empty:
  TransactionPostingCompleted _   -> emptyScope
  TransactionPostingFailed _      -> emptyScope
  TransactionAmendmentFailed _    -> emptyScope
  TransactionMergeCompleted _     -> emptyScope          -- balance effect covered by Account Debited/Credited
  TransactionMergeFailed _        -> emptyScope
  where
    both a b = emptyScope { directAccounts = [a, b] }
    viaTx t = emptyScope { viaTransaction = Just t }
    viaStreamKeyTx = maybe emptyScope viaTx (mkTransactionIdSafe streamKey)
```

Confirm the sub-type constructor names against `Domain.Account.Events` / `Domain.Transaction.Events` (these are the *bare* names, no `Event` suffix — the suffix is only on the flat `AccountingEvent` tags) and the payload field names; the full `transactionEvents` list is at `Domain/Transaction/Events.hs:69-89`. Fix as the compiler dictates. **Keep both sub-matches catch-all-free** so `-Wincomplete-patterns` under `-fci` is a real guard.

- [ ] **Step 4: Run, verify pass** (add a QuickCheck property if a generator over `AccountingEvent` exists: "classify never throws and returns disjoint-or-empty scope").
- [ ] **Step 5: Commit** — `git commit --no-gpg-sign -m "feat(sync): pure event→scope classifier for the data-version signal"`

---

## Task A3: `sync_data_version` table, `bumpVersions`, `getDataVersion`

**Files:**
- Modify: `src/Application/ReadModels/DataVersion.hs`
- Test: `test/Application/ReadModels/DataVersionIntegrationSpec.hs`

- [ ] **Step 1: Write failing integration tests:**

```haskell
it "increments a user's counter and reads it back" $ \pool -> runDb pool $ do
  v0 <- getDataVersion u
  liftIO (v0 `shouldBe` 0)
  bumpVersions [u]
  v1 <- getDataVersion u
  liftIO (v1 `shouldBe` 1)
  bumpVersions [u]
  v2 <- getDataVersion u
  liftIO (v2 `shouldBe` 2)

it "unknown user reads as 0 without inserting a row" $ \pool -> runDb pool $ do
  v <- getDataVersion strangerId
  liftIO (v `shouldBe` 0)
  -- a read must not create a row (non-mutating)
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement the entity + functions.**

```haskell
share
  [mkPersist sqlSettings, mkMigrate "migrateDataVersion"]
  [persistLowerCase|
DataVersionEntity sql=sync_data_version
    userId UserId
    version Int
    UniqueDataVersionUser userId
    deriving Show Eq
|]

dataVersionProjectionName :: CheckpointName
dataVersionProjectionName = CheckpointName "data_version"

-- | Non-mutating read: a user with no row reads as 0.
getDataVersion :: (MonadIO m) => UserId -> SqlPersistT m Word64
getDataVersion uid = do
  mEnt <- getBy (UniqueDataVersionUser uid)
  pure $ case mEnt of
    Nothing -> 0
    Just (Entity _ e) -> fromIntegral (max 0 e.dataVersionEntityVersion)

-- | +1 per user, atomic with the surrounding write transaction. Idempotent
-- upsert; the per-user row lock serializes concurrent same-user increments so no
-- commit-order reorder can hide a change (see spec callout).
bumpVersions :: (MonadIO m) => [UserId] -> SqlPersistT m ()
bumpVersions users =
  forM_ (nub users) $ \uid ->
    void $ upsert (DataVersionEntity uid 1) [DataVersionEntityVersion +=. 1]
```

`upsert` and `+=.` from `Database.Persist.Sql`. `Word64` in the API type; store as `Int` (household counters never approach `Int` range; keep it simple and Postgres-native). Add `import Infrastructure.Database.Orphans ()` for `UserId`'s `PersistField`.

- [ ] **Step 4: Run, verify pass.** Note: a *sequential* `bump; bump → 2` test only proves increments accumulate — it does **not** distinguish `+1` from the rejected `GREATEST(seqNo)` design, because the reorder hazard only manifests under genuine concurrency. To actually cover the reorder-safety property you need two forked threads on **separate pool connections** with a barrier so both transactions overlap, then assert the final counter reflects both. Write that if the harness supports it; otherwise be explicit that the reorder property is argued (row-lock serialization + atomic-with-own-commit), not test-covered, and don't let the sequential test masquerade as covering it.
- [ ] **Step 5: Commit** — `git commit --no-gpg-sign -m "feat(sync): sync_data_version table with atomic per-user counter"`

---

## Task A4: The `dataVersionReadModel` (effectful handler)

**Files:**
- Modify: `src/Application/ReadModels/DataVersion.hs`
- Test: `test/Application/ReadModels/DataVersionIntegrationSpec.hs`

- [ ] **Step 1: Write failing integration tests** driving `applyDataVersionEvent` directly with `GlobalStreamEvent`s (build them with a testkit helper mirroring how other read-model specs feed events):
  - An account write on an account shared owner↔editor bumps **both** users; an unrelated user is untouched.
  - A transfer posting bumps the users of **both** legs' accounts.
  - A label edit (carries only txId) bumps the transaction's account users (requires the transaction row to pre-exist — seed it first).
  - `AccountAccessRevokedEvent` bumps the revoked user even though they're no longer in `account_access`.
  - A `TransactionPostingCompletedEvent` / a `Configuration` event bumps nobody.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement the handler + read model.**

```haskell
applyDataVersionEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyDataVersionEvent ge = do
  let inner = ge.payload
      scope = classifyEvent inner.key inner.payload
  viaAccs <- maybe (pure []) transactionAccounts scope.viaTransaction
  let accIds = nub (scope.directAccounts <> viaAccs)
  -- Batched to avoid an N+1 across accIds: one selectList over all accounts.
  accessMap <- loadAccessLists accIds
  let accessors = [a.userId | accs <- Map.elems accessMap, a <- accs]
  bumpVersions (accessors <> scope.extraUsers)

dataVersionReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
dataVersionReadModel =
  ReadModel
    { initialize = void (runMigrationSilent migrateDataVersion),
      eventHandler = EventHandler applyDataVersionEvent,
      checkpointStore = postgresqlCheckpointStore dataVersionProjectionName,
      reset = deleteWhere ([] :: [Filter DataVersionEntity])
    }
```

**Reuse** the existing batched `loadAccessLists :: [AccountId] -> SqlPersistT m (Map AccountId [AccountAccess])` from `Account.hs` (export it if it isn't already) — a single `selectList [AccountAccessEntityAccountId <-. accIds]`. Do **not** add a per-account `accessorsOf` helper; that re-implements `loadAccessList` and causes one query per account. `AccountAccess` exposes `.userId` via OverloadedRecordDot (it's `AccountAccess { userId, role }` in `Domain.Core.Types` — confirm). Import `qualified RIO.Map as Map`.

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `git commit --no-gpg-sign -m "feat(sync): DataVersion read model bumping per-user counters by access scope"`

---

## Task A5: Register the read model

**Files:**
- Modify: `src/Application/ReadModels/Persist.hs`

- [ ] **Step 1:** Add import `import Application.ReadModels.DataVersion (dataVersionProjectionName, dataVersionReadModel)`.
- [ ] **Step 2:** Add `(unCheckpointName dataVersionProjectionName, dataVersionReadModel)` to `persistentReadModels`. **Order matters:** place it **after** `accountReadModel` and `transactionReadModel` so `account_access` and the transactions table already reflect the current event when it runs.
- [ ] **Step 3: Build** — `just build` (runs hpack; picks up the new module). Expected: clean under `-fci`. If `.o` cache masks a `-Werror` issue, `just rebuild`.
- [ ] **Step 4: Commit** — `git commit --no-gpg-sign -m "feat(sync): register DataVersion read model (after account/transaction)"`

---

## Task A6: `SyncVersionResponse` DTO

**Files:**
- Modify: `src/Web/Types.hs`

- [ ] **Step 1:** Add, following the generic-instance convention:

```haskell
newtype SyncVersionResponse = SyncVersionResponse
  { version :: Word64
  }
  deriving (Show, Eq, Generic)

instance ToJSON SyncVersionResponse
instance FromJSON SyncVersionResponse
```

`Word64` serializes as a JSON number (< 2^53, safe as a JS number). Ensure `Word64` is in scope (`RIO` re-exports it).

- [ ] **Step 2: Build.** Expected clean.
- [ ] **Step 3: Commit** — `git commit --no-gpg-sign -m "feat(web): SyncVersionResponse DTO"`

---

## Task A7: `GET /api/sync/version` endpoint

**Files:**
- Create: `src/Web/API/SyncAPI.hs`
- Modify: `src/Web/API.hs`
- Test: `test/Web/SyncAPIIntegrationSpec.hs` (follow an existing Web integration spec; if none, assert the handler via `runDb` + `getDataVersion` and cover the routing in an app-level spec)

- [ ] **Step 1: Write failing test** — an authenticated `GET /api/sync/version` returns the caller's counter; after a write affecting the caller, a subsequent GET returns a strictly greater number; an unauthenticated request is 401.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement the module:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.API.SyncAPI (SyncAPI, syncAPI, syncServer) where

import Application.ReadModels.DataVersion (getDataVersion)
import Infrastructure.App (AppM, runDb)
import RIO
import Servant
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types (SyncVersionResponse (..))

type SyncAPI =
  AuthProtect "jwt"
    :> "api"
    :> "sync"
    :> "version"
    :> Get '[JSON] SyncVersionResponse

syncAPI :: Proxy SyncAPI
syncAPI = Proxy

syncServer :: ServerT SyncAPI AppM
syncServer = versionHandler

versionHandler :: AuthenticatedUser -> AppM SyncVersionResponse
versionHandler user = do
  v <- runDb (getDataVersion user.userId)
  pure (SyncVersionResponse {version = v})
```

Confirm the exact `runDb` name/location (`Infrastructure.App`); match how `ReportingAPI` handlers reach the DB (they call a service that uses `runDb`).

- [ ] **Step 4: Wire into `Web/API.hs`** — add `import Web.API.SyncAPI` (and re-export if the module re-exports sub-APIs), append `:<|> SyncAPI` to `type API`, and `:<|> syncServer` to `server` at the **same** position.
- [ ] **Step 5: Build + run test, verify pass.**
- [ ] **Step 6: Commit** — `git commit --no-gpg-sign -m "feat(web): GET /api/sync/version endpoint"`

---

## Task A8: End-to-end producer test (honors sharing, fires from import)

**Files:**
- Test: `test/Application/ReadModels/DataVersionIntegrationSpec.hs` (add) or a dedicated `*IntegrationSpec.hs`

- [ ] **Step 1:** Drive a real command through the shared command path (the same one HTTP/Telegram/import use) so the whole write transaction runs including the DataVersion read model, then assert `getDataVersion` advanced for exactly the right users:
  - Post a transaction on an account shared owner↔viewer → both advance; a stranger does not.
  - Import a batch (reuse the import service test path if one exists) → the importing account's users advance; the counter advances once per affecting event (a bigger jump is fine).
- [ ] **Step 2: Run, verify pass** (needs `eventium_test`).
- [ ] **Step 3: Commit** — `git commit --no-gpg-sign -m "test(sync): producer fires from command path and honors account sharing"`

- [ ] **Step 4: Phase A gate** — `just build` and `just test` clean under `-fci`; `just lint` clean. Then run the `verify` skill against the endpoint (hit `/api/sync/version`, make a write, confirm the number moves). This is the point Phase A can be merged/PR'd independently.

---

# PHASE B — Web (`../monorepo`)

> Work in `../monorepo` on its own branch (e.g. `feat/live-data-change-signal`). Follow the repo's existing Vitest + Testing-Library patterns; write the test first in each task. Inspect a sibling hook's test (e.g. `useImportStatement`) for the exact `QueryClientProvider` / MSW setup before writing the first test.

## Task B1: `getSyncVersion` API client

**Files:**
- Create: `src/api/sync.ts`
- Test: `src/api/sync.test.ts`

- [ ] **Step 1:** Test that `getSyncVersion(client)` issues `GET /api/sync/version` with the Bearer header and returns `number`.
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3:** Implement using the existing `ApiClient` pattern (`src/api/client.ts`): a typed `get('/api/sync/version')` returning `{ version: number }`, unwrap to `number`.
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5:** Commit.

## Task B2: `useDataChangeSignal` — poll + invalidate (the transport seam)

**Files:**
- Create: `src/features/sync/useDataChangeSignal.ts`
- Test: `src/features/sync/useDataChangeSignal.test.tsx`

- [ ] **Step 1: Write failing tests:**
  - First successful poll seeds `lastSeen` and does **not** invalidate.
  - A poll returning a **different** value (`polled !== lastSeen`, higher *or* lower) invalidates exactly: `['accounts']`, `['transactions']`, `['reports']`, `['transaction-relations']`, `['account-access']` — and **not** `['configuration']`.
  - Polling is disabled when logged out and paused when `document.hidden` (assert the query's `enabled`/`refetchInterval` reflect visibility + auth).
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3: Implement.** A `useQuery({ queryKey: ['sync','version'], queryFn: () => getSyncVersion(client), refetchInterval: focused ? 10_000 : false, enabled: isAuthenticated })`, plus an effect comparing `data` to a `useRef` last-seen; on first value set the ref, on change invalidate the key set via a single exported `invalidateDataScopes(queryClient)` helper (so the scope→key map lives in one place). Drive focus via `visibilitychange`.

```ts
const SCOPE_KEYS = [['accounts'], ['transactions'], ['reports'], ['transaction-relations'], ['account-access']] as const;
export function invalidateDataScopes(qc: QueryClient) {
  SCOPE_KEYS.forEach((key) => void qc.invalidateQueries({ queryKey: key }));
}
```

- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5:** Commit.

## Task B3: Mount the signal once under the authed shell

**Files:**
- Modify: the authenticated layout/`App` component
- Test: a render test asserting the hook is active only when authenticated

- [ ] **Step 1–5:** TDD the mount; call `useDataChangeSignal()` once in the authed shell so a single poller runs per tab. Commit.

## Task B4: Paging fix in `useWindowedTransactions`

**Files:**
- Modify: `src/features/transactions/useWindowedTransactions.ts`
- Test: `src/features/transactions/useWindowedTransactions.test.ts`

- [ ] **Step 1: Write failing tests:** the hook returns the complete window in a single settling query (no per-page accumulation observable to consumers); under a simulated concurrent insert between pages, no row is skipped or duplicated.
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3: Implement.** First **verify the backend paging contract**: the transactions endpoint currently pages at `limit=200` (`Transaction.hs` `OffsetBy`/`LimitTo`) — confirm whether it accepts a large/unbounded limit for a period before committing to option (a). Then replace the sequential `offset += 200` loop with either (a) a single ranged request if the period-scoped row count is bounded and the endpoint allows a big limit, or (b) `useInfiniteQuery` with a stable cursor (safe default if (a)'s contract isn't there). Keep the public return shape stable so callers don't change. The key property: the query resolves in one `settled` transition.
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5:** Commit.

## Task B5: Atomic balance+list swap

**Files:**
- Create: `src/features/transactions/useConsistentAccountView.ts`
- Modify: `src/features/transactions/AccountHeader.tsx` (consume it) and the list container
- Test: `src/features/transactions/useConsistentAccountView.test.tsx`

- [ ] **Step 1: Write failing test:** given a fast `['accounts']` refetch and a slow **current-window** `['transactions', scope, from, to]` refetch, the exposed `{ balance, transactions }` never updates the balance ahead of the list — both change in the same commit, and previous values (`keepPreviousData`) show until both settle.
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3: Implement.** A hook that reads both queries with `placeholderData: keepPreviousData`, and only surfaces `{ balance, transactions, isSyncing }` derived from a snapshot taken when **both** `isFetching` are false; while either is fetching, return the last consistent snapshot. Coordinate on the **exact currently-displayed** transactions key, not the `['transactions']` prefix. (Depends on B4 making "settled" a single moment.)
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5:** Commit.

## Task B6: Fix the phantom-key optimistic write

**Files:**
- Modify: `src/features/transactions/useEditTransaction.ts`
- Test: `src/features/transactions/useEditTransaction.test.ts`

- [ ] **Step 1: Write failing test:** the optimistic `setQueryData` targets the key an active list query reads (`['transactions', accountId, from, to]`), so the edit is visible before `onSettled`.
- [ ] **Step 2:** Run, verify fail.
- [ ] **Step 3: Implement.** Either target the correct windowed key (using the currently-active from/to) or drop the optimistic write and rely on invalidation. Simplest correct: drop the no-op optimistic write and keep the `onSettled` invalidation (which the signal path also covers). If keeping optimism, update all matching windowed queries via `queryClient.setQueriesData({ queryKey: ['transactions', accountId] }, …)` (predicate match, not exact).
- [ ] **Step 4:** Run, verify pass.
- [ ] **Step 5:** Commit.

## Task B7: Phase B verification

- [ ] Run the full web test suite + typecheck + lint.
- [ ] Manual/`verify`: with two browser sessions (or a Telegram write / an import) on a shared account, confirm the other open tab refreshes within ~10s and that during a multi-row import the balance and list never visibly disagree.
- [ ] Open the cross-repo PRs (backend + web), cross-linking `tracker#45`.

---

## Definition of Done

- `GET /api/sync/version` returns a per-user counter that strictly advances on any Account/Transaction write the user can see, honoring sharing (incl. revoke), and never clamps a concurrent write to a no-op. Entry-point independence is covered by testing the **shared command path** (A8) that HTTP, Telegram, and import all funnel through — the read model sits below all of them, so one command-path test proves all three; add a Telegram-path assertion only if you want the spec's three-way claim honored literally.
- The web tab refreshes out-of-band changes within ~10s while focused, backed off when hidden.
- Balance and the displayed transaction window always change together; the paging loop no longer lags or skips/dupes.
- All backend tests green under `-fci`; web suite + lint + typecheck green.
- No stored-event shape change; no event-store recreate; API additive.
