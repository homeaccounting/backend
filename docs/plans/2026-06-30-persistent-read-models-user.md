---
status: completed
---

# Persistent Read Models — Phase 4a: User

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:test-driven-development for each task. Steps use `- [ ]` checkboxes.

**Goal:** Migrate the **User** read model from a single in-memory `TVar UserReadModel` (a primary `Map UserId UserData` plus three lookup-index maps) to persistent, indexed Postgres tables (`users` + `user_oauth` + `user_telegram`), driven by the eventium dual-mode `ReadModel` already wired in Phase 2 — turning the email / Telegram / OAuth lookups into indexed unique queries and removing the bespoke index maps.

**Architecture:** Follows the Phase 2 Account / Phase 3 Transaction template exactly (`docs/plans/2026-06-26-persistent-read-models-account.md` #112; `docs/plans/2026-06-30-persistent-read-models-transaction.md` #114). User becomes an eventium `ReadModel (SqlPersistT IO) AccountingEvent` registered in `Application.ReadModels.Persist.persistentReadModels`, projected synchronously in the event-append transaction. Per-row `version` is recorded from the event's real per-stream `EventVersion` (no `version + 1`). Queries become indexed `SqlPersistT` lookups; the in-memory `userReadModel` field is removed from `AppEnv`/`HasReadModel`/`ReadModels`/`EventDispatch`. `HasReadModel` **survives** — it still carries `configurationReadModelL` (Configuration not yet migrated).

**Spec:** `docs/specs/2026-06-25-persistent-read-models-design.md` (rollout step 4; User table sketch in the per-read-model schema table).

**Tech Stack:** Haskell (GHC 9.10), persistent (quasi-quoter schema), eventium 0.4.0 `ReadModel`/`catchUpReadModel`/`rebuildReadModel`, Hspec, SQLite test harness.

---

## Design decisions (locked)

- **Schema.** Three tables, mirroring the spec sketch:
  - `users` — one row per user. Columns: `userId` (unique), `email` (`Text Maybe`, unique), `hasPassword` (`Bool`), `externalAccountId` (`AccountId`), `configurationId` (`ConfigurationId`), `version` (`EventVersion`).
  - `user_oauth` — `(userId, provider, subject)`; unique `(provider, subject)` (the `getUserByOAuthIdentity` lookup + global linking constraint); index on `userId` (load a user's identity list). A user may have several rows.
  - `user_telegram` — `(userId, telegramId, username?, firstName)`; unique `telegramId` (the `getUserByTelegramId` lookup) **and** unique `userId` (at most one Telegram identity per user). Stores the full `TelegramIdentity` so it round-trips.
- **`UserData.version` becomes `EventVersion`** (was `Int`, derived by `+1`). Recorded from the event's real per-stream version (`globalEvent.payload.position`), mirroring Account/Transaction. Grep-confirmed **no consumer reads `UserData.version`**, so this is internal-only — no DTO change.
- **`email` uniqueness.** `users.email` is `Text Maybe` with a `persistent` unique on the nullable column. Multiple `NULL`s are allowed by both Postgres and SQLite (the test harness), so Telegram-only users (no email) coexist. `getUserByEmail`/`emailExists` are unique-index lookups; callers always pass a concrete email.
- **OAuth identity list.** `UserData.oauthIdentities :: [OAuthIdentity]` is reconstructed from all `user_oauth` rows for the user. Link → `insertUnique` a row (idempotent on the unique key). Unlink → `deleteWhere [provider ==., subject ==.]`.
- **Telegram identity.** `UserData.telegramIdentity :: Maybe TelegramIdentity` is reconstructed from the single `user_telegram` row (if any). Link → replace (delete the user's row, insert the new one) — idempotent. Unlink → delete the user's row.
- **No in-memory fallback.** Consistent with the project's no-backward-compat constraint, the in-memory `UserReadModel`/`createUserReadModel`/`emptyUserReadModel`/`handleUserEvents`/`userToMap` are deleted, not kept behind a flag. `userToMap` is grep-confirmed to have no consumers.

---

## Part A — `PersistField` instances for User column types

### A1. Add instances + round-trip tests

**Files:** `src/Infrastructure/Database/Orphans.hs`; `test/Infrastructure/Database/OrphansSpec.hs`.

New instances:
- `ConfigurationId` — UUID-backed (`unConfigurationId`/`mkConfigurationIdSafe`), mirroring the `UserId`/`AccountId` instances. `PersistFieldSql … = sqlType (Proxy :: Proxy UUID)`.
- `TelegramId` — `Int64`-backed (`unTelegramId`/`TelegramId`). Store as an integer column: `toPersistValue = toPersistValue . unTelegramId`; `fromPersistValue v = TelegramId <$> fromPersistValue v`. `PersistFieldSql … = SqlInt64`.
- `OAuthProvider` — JSON text token via `jsonToPersist`/`jsonFromPersist` (`ToJSON`/`FromJSON` already exist; the enum is small and equality on the encoded text is a valid filter for `getUserByOAuthIdentity` and the unique key). `PersistFieldSql … = SqlString`.

(`UserId`, `AccountId` already exist; `EventVersion`, `Bool`, `Text` are provided by eventium/persistent.)

- [ ] **Step 1: Write failing round-trip property tests.** In `OrphansSpec`, add `prop_roundtrip` cases for `ConfigurationId`, `TelegramId`, `OAuthProvider`: `fromPersistValue (toPersistValue x) == Right x`. Reuse/extend generators in `test/Testkit/Generators.hs` (add generators if missing — `TelegramId` from arbitrary `Int64`; `OAuthProvider` from `elements [Google, GitHub, Microsoft]`; `ConfigurationId` from a UUID generator).
- [ ] **Step 2: Run, verify they fail to compile** (no instance): `cabal test backend-test --test-option=--match --test-option="/Orphans/" -fci`. Expected: build error "No instance for PersistField …".
- [ ] **Step 3: Add the three instances** in `Orphans.hs` (+ their `PersistFieldSql`), importing the needed names from `Domain.Core.Types`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `feat(read-models): PersistField instances for User column types`.

---

## Part B — Persistent User read model (schema + apply + queries)

This rewrites `src/Application/ReadModels/User.hs`. Keep the public query *names* and the `UserData` export (consumers depend on them); change query *signatures* from `TVar … -> … -> m a` to `… -> SqlPersistT m a`, dropping the `TVar` parameter. Remove `UserReadModel`, `createUserReadModel`, `emptyUserReadModel`, `handleUserEvents`, `userToMap`.

> **LiquidHaskell:** no obligation here (Application-layer projection of existing domain types; matches the merged Account/Transaction read models, which carry no refinements).

### B1. Schema + `migrateUser` + `resetUser`

**Files:** `src/Application/ReadModels/User.hs`.

- [ ] **Step 1:** Add the `share [mkPersist sqlSettings, mkMigrate "migrateUser"] [persistLowerCase| … |]` block defining `UserEntity sql=users`, `UserOAuthEntity sql=user_oauth`, `UserTelegramEntity sql=user_telegram` per the locked schema (with `UniqueUserId`, `UniqueUserEmail email`, `UniqueUserOAuth provider subject`, `UniqueUserTelegramId telegramId`, `UniqueUserTelegramUser userId`), plus `userProjectionName = CheckpointName "user"` and `resetUser` (deleteWhere all three tables, children first). Add the LANGUAGE pragmas used by Account (`QuasiQuotes`, `TemplateHaskell`, `TypeFamilies`, `DerivingStrategies`, `GADTs`, `StandaloneDeriving`, `DeriveGeneric`, `FlexibleContexts`, `GeneralizedNewtypeDeriving`, `OverloadedRecordDot`, `OverloadedStrings`). Import `Infrastructure.Database.Orphans ()`.
- [ ] **Step 2:** `cabal build backend -fci`. Expected: compiles (entities generate).
- [ ] **Step 3: Commit.** `feat(read-models): users + user_oauth + user_telegram schema`.

### B2. Event apply (`applyUserEvent`) + `userReadModel`

**Files:** `src/Application/ReadModels/User.hs`; new spec `test/Application/ReadModels/PersistentUserReadModelSpec.hs`.

Port `processUserEvent` to a total, idempotent `applyUserEvent :: MonadIO m => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()` (pattern from `applyAccountEvent`; key off `inner.key` via `mkUserIdSafe`, version from `inner.position`):
- `UserRegistered` → `insertUnique` the `users` row (`email = Just evt.email`, `hasPassword = True`, `externalAccountId`, `configurationId = defaultConfigurationId`, `version = pos`).
- `UserRegisteredViaTelegram` → `insertUnique` the `users` row (`email = Nothing`, `hasPassword = False`, …); `insertUnique` the `user_telegram` row from `evt.identity`.
- `OAuthAccountLinked` → `insertUnique` a `user_oauth` row `(userId, evt.identity.provider, evt.identity.subject)`; `bumpVersion`.
- `TelegramAccountLinked` → replace the user's `user_telegram` row (`deleteWhere [UserTelegramEntityUserId ==. uid]` then `insertUnique` from `evt.identity`); `bumpVersion`.
- `OAuthAccountUnlinked` → `deleteWhere [UserOAuthEntityProvider ==. evt.identity.provider, UserOAuthEntitySubject ==. evt.identity.subject]`; `bumpVersion`.
- `TelegramAccountUnlinked` → `deleteWhere [UserTelegramEntityUserId ==. uid]`; `bumpVersion`.
- `PasswordChanged` → set `hasPassword = True`; `version = pos`.
- `UserConfigurationAssigned` → set `configurationId = evt.configurationId`; `version = pos`.
- All non-user events → no-op.
- `bumpVersion`/field updates use a `modifyUser` read-modify-write helper (no-op if the row is absent), mirroring `modifyAccount`. Every mutating branch records `version = pos`.

Then `userReadModel :: ReadModel (SqlPersistT IO) AccountingEvent` = `{ initialize = void (runMigrationSilent migrateUser), eventHandler = EventHandler applyUserEvent, checkpointStore = postgresqlCheckpointStore userProjectionName, reset = resetUser }`.

- [ ] **Step 1: Write failing spec** `PersistentUserReadModelSpec` (SQLite harness, mirroring `PersistentAccountReadModelSpec` — uses `createTestAppEnvWithProcessManager` + `runDbIn`): register a user, assert `getUser`/`getUserByEmail` reflect it; link OAuth + Telegram, assert reconstruction and the index lookups; unlink, assert removal; apply-twice == apply-once (idempotency); `version` tracks the real per-stream `EventVersion`.
- [ ] **Step 2: Run, verify fail** (`applyUserEvent`/`userReadModel` undefined).
- [ ] **Step 3: Implement** apply + read model.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `feat(read-models): User event apply as eventium ReadModel`.

### B3. Indexed queries

**Files:** `src/Application/ReadModels/User.hs`.

Reconstruction helper `entToData :: UserEntity -> [OAuthIdentity] -> Maybe TelegramIdentity -> UserData`. Queries:
- `getUser :: MonadIO m => UserId -> SqlPersistT m (Maybe UserData)` — `getBy UniqueUserId` + load oauth rows (`selectList [UserOAuthEntityUserId ==. uid]`) + telegram row (`getBy UniqueUserTelegramUser`).
- `getUserByEmail :: MonadIO m => Text -> SqlPersistT m (Maybe (UserId, UserData))` — `getBy UniqueUserEmail` → reconstruct.
- `getUserByTelegramId :: MonadIO m => TelegramId -> SqlPersistT m (Maybe (UserId, UserData))` — `getBy UniqueUserTelegramId` → resolve `userId` → reconstruct.
- `getUserByOAuthIdentity :: MonadIO m => OAuthProvider -> Text -> SqlPersistT m (Maybe (UserId, UserData))` — `getBy UniqueUserOAuth` → resolve `userId` → reconstruct.
- `userExists :: MonadIO m => UserId -> SqlPersistT m Bool` — `isJust <$> getBy UniqueUserId`.
- `emailExists :: MonadIO m => Text -> SqlPersistT m Bool` — `isJust <$> getBy UniqueUserEmail`.
- `telegramIdLinked :: MonadIO m => TelegramId -> SqlPersistT m Bool` — `isJust <$> getBy UniqueUserTelegramId`.

A shared `loadUserData :: UserId -> UserEntity -> SqlPersistT m UserData` helper (load oauth + telegram, build `UserData`) keeps the by-key queries DRY.

- [ ] **Step 1: Write failing query spec** extending `PersistentUserReadModelSpec`: lookups by id/email/telegram/oauth return the right user; `emailExists`/`telegramIdLinked`/`userExists` truth table; Telegram-only user has `email = Nothing` and no email collision with another Telegram-only user (multiple NULL emails coexist); OAuth list reflects multiple linked identities.
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** queries.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit.** `feat(read-models): indexed User queries`.

---

## Part C — Wiring + consumer migration

### C1. Register the read model; drop in-memory wiring

**Files:** `src/Application/ReadModels/Persist.hs`, `src/Infrastructure/Database.hs` (`runMigrations`), `src/Application/EventDispatch.hs`, `src/Infrastructure/App.hs`, `app/Main.hs`, `test/Testkit/InMemoryEventStore.hs`.

- [ ] Add `(unCheckpointName userProjectionName, userReadModel)` to `persistentReadModels`.
- [ ] Add `migrateUser` to `runMigrations` in `Infrastructure/Database.hs`.
- [ ] `EventDispatch.hs`: remove `user` from `ReadModels`, `createReadModels`, `fromReadModels`, and drop the `Application.ReadModels.User` import of removed names (`UserReadModel`, `createUserReadModel`, `handleUserEvents`). `ReadModels` still carries `configuration` + `exchangeRate`.
- [ ] `App.hs`: remove the `userReadModel` field from `AppEnv` (`:206`), the **positional** parameter in `initializeAppEnv` (`:310` — among ~20 positional args; every caller's argument order shifts, get it right), and `userReadModelL` from `HasReadModel` (`:472-478`). `HasReadModel` **survives** with `configurationReadModelL` only.
- [ ] `Main.hs`: drop the `userReadModel`/`readModels.user` positional argument to `initializeAppEnv`.
- [ ] `InMemoryEventStore.hs`: drop `userReadModel = readModels.user` from the `AppEnv` build (`:261`) and the matching `initializeAppEnv` positional argument. The persistent model is already driven via `persistentReadModels`/`readModelPublisher` and `initialize`d in the harness setup loop (`:210`), so no further harness wiring is needed.
- [ ] `cabal build all -fci` — expect type errors only at the consumer call sites handled in C2.

### C2. Migrate consumers to `runDb (ReadModel.…)`

**Files (call sites):** `src/Application/Services/AuthService.hs`, `Internal.hs`, `BankImportService.hs`, `src/Telegram/Commands.hs`. (`ConfigurationService.hs`, `UserService.hs`, `Web/API/UserAPI.hs` import only the `UserData` type and go through `getUserData`/services — no read-model call to change.)

Transformation rule (mechanical, mirrors Account #112 / Transaction #114): replace `view userReadModelL` + `ReadModel.getX rm args` with `runDb (ReadModel.getX args)`; in `ExceptT`/`runExceptT` contexts, `lift (runDb …)`. Specific swaps:
- `AuthService` (all ExceptT): `emailExists`, `getUserByEmail`, `getUserByOAuthIdentity`, `getUserByTelegramId` — drop the `view userReadModelL` binding, wrap each call in `lift (runDb …)`.
- `Internal.getUserData` (ExceptT): `liftMaybeM (NotFound …) (lift (runDb (getUser userId)))` (drop the `view`).
- `BankImportService.importMatchedTransaction` (AppM): `runDb (getUser userId)`.
- `Telegram/Commands.hs` (AppM, 4 sites): `runDb (getUserByTelegramId telegramId)`. Note `handleStartNoPayload` currently wraps the call in `liftIO` — drop the `liftIO`, use `runDb`.

- [ ] **Step 1:** Apply the swaps file-by-file until `cabal build all -fci` is clean. (`runDb` capability is already in scope in these modules — confirm the import; add `Infrastructure.Database (runDb)` if missing.)
- [ ] **Step 2: Migrate the test specs** that reference the old `TVar` model or read it back. Re-grep the authoritative list — `grep -rln "userReadModel\|UserReadModel\|createUserReadModel\|handleUserEvents\|userToMap\|env.userReadModel" test`. At minimum: `test/Testkit/Fixtures.hs` (`userExternalAccountId`/`firstDictionaryEntry` use `getUser env.userReadModel uid` → `runDbIn env (getUser uid)`); `test/Testkit/InMemoryEventStore.hs`; `test/Application/Services/{AuthService,UserService,ConfigurationServiceInUse,ConfigurationServiceIntegration,ConfigurationService,BankImportService,AccountServiceIntegration,TransactionAllocationsIntegration,TransactionServiceLabels}Spec.hs`; `test/Integration/{BankImportWorkflow,TransactionCategoryIntegration,TransactionLabelsIntegration,TransactionMetadataEditIntegration}Spec.hs`; `test/Telegram/CommandsSpec.hs`; `test/Web/API/AccountAPISpec.hs`.
- [ ] **Step 3:** `just test` (full suite) green.
- [ ] **Step 4: Commit.** `refactor(read-models): migrate User consumers to runDb`.

---

## Part D — Verification

- [ ] `just rebuild` (clean `-fci` build, lib+exe+test) — definitive `-Werror` check.
- [ ] `just test` — full suite green.
- [ ] `just check` (ormolu + hlint) clean.
- [ ] Grep confirms no remaining `userReadModel`/`UserReadModel`/`handleUserEvents`/`createUserReadModel`/`userToMap` references outside history.
- [ ] Update `docs/specs/2026-06-25-persistent-read-models-design.md` rollout (mark User done) and set this plan's frontmatter `status: completed`.
- [ ] Open PR `refactor(read-models): persistent indexed User read model` against `master`, referencing #51.

---

## Done criteria

- User served from `users`/`user_oauth`/`user_telegram`; email / Telegram / OAuth lookups are indexed unique queries, no in-process index maps.
- `userReadModel` removed from `AppEnv`/`HasReadModel`/`ReadModels`/`EventDispatch`; the model runs as a registered eventium `ReadModel` via `readModelPublisher` with checkpoint-in-transaction.
- Per-row `version` recorded from the event (no `+1`); `UserData.version :: EventVersion`.
- Property/integration tests cover lookup correctness, link/unlink, multiple-NULL-email coexistence, idempotency, and version-from-event.
- All gates green.

## Out of scope (later phases)
- Configuration, ExchangeRate migrations (same pattern; rollout step 4).
