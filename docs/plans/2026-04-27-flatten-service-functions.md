---
status: completed
created: 2026-04-27
author: cursor-ai
reviewed-by: code-reviewer-subagent
spec: ../specs/2026-04-27-flatten-service-functions-design.md
issue: https://github.com/homeaccounting/backend/issues/56
---

# Flatten Service Functions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace deeply-nested `case Left/Right` ladders inside the six in-scope service modules with linear, ExceptT-shaped happy paths, while preserving every public `AppM (Either DomainError a)` signature, every `DomainError` value, and every existing test assertion.

**Architecture:** Tactical local `ExceptT DomainError AppM` inside each public function, unwrapped at the boundary by `runExceptT`. A new co-located helper module `Application.Services.Internal` exports four pure lifters (`liftMaybe`, `liftMaybeM`, `liftEitherWith`, `guardE`) and four per-aggregate command runners (`runAccountCmd`, `runUserCmd`, `runConfigurationCmd`, `runTransactionCmd`). RIO's `ReaderT`-only application monad is preserved — no `MonadError` constraint is added to `AppM` or any environment type.

**Tech Stack:** Haskell GHC 9.10.3, RIO prelude, `transformers >= 0.5 && < 0.7` (no new deps), Hpack/Cabal, Hspec + hspec-discover, ormolu, hlint, just task runner.

---

## Reference: Spec

This plan implements [docs/specs/2026-04-27-flatten-service-functions-design.md](../specs/2026-04-27-flatten-service-functions-design.md). When this plan and the spec disagree, the spec wins — re-read its "Scope", "Helper module", "Logging policy", "Per-service inventory" and "Verification gates" sections before starting any task.

## File Structure

### Created

| File | Responsibility |
|------|----------------|
| `src/Application/Services/Internal.hs` | Helper module: `liftMaybe`, `liftMaybeM`, `liftEitherWith`, `guardE`, plus per-aggregate `runXCmd` runners. ~120 lines. |
| `test/Application/Services/InternalSpec.hs` | Pure unit tests for the four lifters. The `runXCmd` runners are covered transitively by existing service specs. ~80 lines. |

### Modified

| File | Change |
|------|--------|
| `package.yaml` | Re-run via `hpack`; new `Application.Services.Internal` module is auto-discovered (the library uses `source-dirs: src` with no explicit `exposed-modules` list, so adding the file is sufficient). |
| `src/Application/Services/UserService.hs` | Refactor: 4 public fns + helpers. ~267 → ~210 lines. |
| `src/Application/Services/AccountService.hs` | Refactor: 6 public fns + `parseRole`. ~364 → ~270 lines. |
| `src/Application/Services/BankImportService.hs` | Refactor: `importTransaction` (deepest pyramid). Delete `logCrossCurrencyRate` helper + call site. ~408 → ~340 lines. |
| `src/Application/Services/ConfigurationService.hs` | Refactor: 9 public fns + `lookupUserConfiguration` / `ensureClonedConfiguration` / `cloneConfiguration`. `seedDefaultConfiguration` only collapses its outer `case`; inner per-entry loops keep their non-short-circuiting `case`s. ~597 → ~430 lines. |
| `src/Application/Services/AuthService.hs` | Refactor: 9 public fns + `generateAuthResult` / `createUserViaOAuth` / `createUserViaTelegram`. ~635 → ~470 lines. |
| `src/Application/Services/TransactionService.hs` | Refactor: 7 public fns + 7 helpers (`validateLabels`, `categoryExists`, `ensureEditorAccess`, `dispatchEdit`, `resolveAndInitiate`, `queryTransactionResult`, `resolveAmounts`). `translateTransactionError` and `pickCategoryDict` stay byte-identical. ~679 → ~500 lines. |

### Untouched (verify diff is empty)

- `src/Application/Services/AuthorizationService.hs`
- `src/Application/Services/ExchangeRatePublisher.hs`
- All of `src/Domain/`, `src/Infrastructure/`, `src/Web/`
- Every file under `test/` except the new `InternalSpec.hs`

---

## Per-Task Conventions

For every task that ends in a commit:

1. After commit, **push the branch**: `git push -u origin refactor/flatten-service-functions` on first push, `git push` thereafter.
2. **Commit messages** follow Conventional Commits. Use `refactor(<scope>): <subject>` for the service-rewrite tasks, `feat(<scope>):` only for the new helper module.
3. **No `--no-verify`**, no hook skipping. If a hook fails, fix the cause and re-commit.
4. **Branch name** for the work is `refactor/flatten-service-functions` (already created during brainstorming and currently checked out).

If a sub-step's expected output diverges from what you observe, **stop and investigate** — do not paper over with destructive `git` operations. The existing service tests are the regression suite; if any of them go red after a refactor commit, revert the offending change and re-do the function with smaller increments.

Run `nix develop` once at the start of the session so `just`, `cabal`, `ghc`, `hpack`, `ormolu`, `hlint` are on the path.

---

## Task 1: Helper module — pure lifters (TDD)

**Files:**
- Create: `src/Application/Services/Internal.hs`
- Create: `test/Application/Services/InternalSpec.hs`
- Modify: none yet (no `package.yaml` edit needed because the library has no explicit `exposed-modules` list — Hpack picks up new files under `src/` automatically; verify with the build step below).

### Step 1.1: Write the failing test for `liftMaybe`

- [ ] Create `test/Application/Services/InternalSpec.hs` with the following content:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.InternalSpec
-- Description : Unit tests for the service helper module.
--
-- Covers the four pure lifters: 'liftMaybe', 'liftMaybeM', 'liftEitherWith',
-- 'guardE'. The aggregate command runners ('runAccountCmd' etc.) are
-- exercised transitively by the per-service specs and are not unit-tested
-- here.
module Application.Services.InternalSpec (spec) where

import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
  )
import Control.Monad.Trans.Except (runExceptT)
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "liftMaybe" $ do
    it "returns Right a when given Just a" $ do
      result <- runExceptT (liftMaybe @IO ("err" :: Text) (Just (42 :: Int)))
      result `shouldBe` Right 42

    it "returns Left e when given Nothing" $ do
      result <- runExceptT (liftMaybe @IO ("err" :: Text) (Nothing :: Maybe Int))
      result `shouldBe` Left "err"

  describe "liftMaybeM" $ do
    it "returns Right a when the action yields Just a" $ do
      result <-
        runExceptT (liftMaybeM ("err" :: Text) (pure (Just (7 :: Int)) :: IO (Maybe Int)))
      result `shouldBe` Right 7

    it "returns Left e when the action yields Nothing" $ do
      result <-
        runExceptT (liftMaybeM ("err" :: Text) (pure (Nothing :: Maybe Int) :: IO (Maybe Int)))
      result `shouldBe` Left "err"

  describe "liftEitherWith" $ do
    it "returns Right a when given Right a, ignoring the mapper" $ do
      result <-
        runExceptT
          (liftEitherWith @IO @Text @Text (\_ -> "boom") (Right (1 :: Int)))
      result `shouldBe` Right 1

    it "applies the mapper to a Left e1" $ do
      result <-
        runExceptT
          (liftEitherWith @IO @Text @Text ("mapped: " <>) (Left "raw"))
      result `shouldBe` Left "mapped: raw"

  describe "guardE" $ do
    it "returns Right () when the predicate is True" $ do
      result <- runExceptT (guardE @IO True ("err" :: Text))
      result `shouldBe` Right ()

    it "returns Left e when the predicate is False" $ do
      result <- runExceptT (guardE @IO False ("err" :: Text))
      result `shouldBe` Left "err"
```

(Type applications like `@IO` make the inferred monad explicit; `TypeApplications` is already enabled project-wide.)

### Step 1.2: Run the test to verify it fails

- [ ] Run: `just test --test-option='--match' --test-option="Application.Services.Internal"`

Expected: compile error — `Could not find module 'Application.Services.Internal'` (the module does not exist yet). This is the desired red state.

### Step 1.3: Create the helper module

- [ ] Create `src/Application/Services/Internal.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Internal
-- Description : Internal helpers for flattened ExceptT-shaped service bodies.
--
-- Used only by the @Application.Services.*@ modules. The four pure lifters
-- ('liftMaybe', 'liftMaybeM', 'liftEitherWith', 'guardE') turn the common
-- "look up / validate / branch on Maybe-or-Either" patterns into single
-- monadic lines inside an @ExceptT DomainError AppM@ block. The four
-- aggregate command runners ('runAccountCmd', 'runUserCmd',
-- 'runConfigurationCmd', 'runTransactionCmd') wrap @apply*Command@ with
-- consistent rejection logging and 'CommandHandlerError' translation.
--
-- Public service signatures stay @AppM (Either DomainError a)@ — these
-- helpers live inside @runExceptT@ blocks, not in the type signatures.
module Application.Services.Internal
  ( -- * Lifting into ExceptT
    liftMaybe,
    liftMaybeM,
    liftEitherWith,
    guardE,

    -- * Aggregate command runners
    runAccountCmd,
    runUserCmd,
    runConfigurationCmd,
    runTransactionCmd,
  )
where

import Control.Monad.Trans.Except (ExceptT (..), throwE)
import qualified Data.Text as T
import Data.UUID (UUID)
import Domain.Account.CommandHandler (AccountCommand)
import Domain.Configuration.CommandHandler (ConfigurationCommand)
import Domain.Core.Errors (DomainError (..))
import Domain.Transaction.CommandHandler (TransactionCommand, TransactionError)
import Domain.User.CommandHandler (UserCommand)
import Eventium (CommandHandlerError, MetadataEnricher)
import Infrastructure.App (AppM, HasEventStore (..))
import Infrastructure.Eventium
  ( applyAccountCommand,
    applyConfigurationCommand,
    applyTransactionCommand,
    applyUserCommand,
  )
import RIO

-- -----------------------------------------------------------------------------
-- Pure Lifters
-- -----------------------------------------------------------------------------

-- | Throw the given error when the value is 'Nothing'; otherwise return it.
liftMaybe :: (Monad m) => e -> Maybe a -> ExceptT e m a
liftMaybe e = ExceptT . pure . maybe (Left e) Right

-- | Run the action, then 'liftMaybe' on its result.
liftMaybeM :: (Monad m) => e -> m (Maybe a) -> ExceptT e m a
liftMaybeM e action = ExceptT (maybe (Left e) Right <$> action)

-- | Adapt an 'Either' with a custom error producer.
liftEitherWith :: (Monad m) => (e1 -> e2) -> Either e1 a -> ExceptT e2 m a
liftEitherWith f = ExceptT . pure . either (Left . f) Right

-- | Throw the given error when the predicate is 'False'.
guardE :: (Monad m) => Bool -> e -> ExceptT e m ()
guardE cond e = unless cond (throwE e)

-- -----------------------------------------------------------------------------
-- Aggregate Command Runners
--
-- Each runner replaces the call-site triplet of:
--   1. read writer/reader from the env,
--   2. liftIO (apply*Command ...),
--   3. case-split + 'logError' + Left wrapping on rejection.
--
-- The canonical "<aggregate> command rejected" log line lives here once,
-- per the logging policy in the design spec.
-- -----------------------------------------------------------------------------

-- | Apply an Account command, logging and translating rejection.
runAccountCmd ::
  MetadataEnricher ->
  UUID ->
  AccountCommand ->
  ExceptT DomainError AppM ()
runAccountCmd enricher accountId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyAccountCommand writer reader enricher accountId cmd
  case result of
    Left err -> do
      lift $ logError $ "Account command rejected: " <> displayShow err
      throwE $ AccountError "Account command rejected by domain"
    Right _events -> pure ()

-- | Apply a User command, logging and translating rejection.
runUserCmd ::
  MetadataEnricher ->
  UUID ->
  UserCommand ->
  ExceptT DomainError AppM ()
runUserCmd enricher userId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyUserCommand writer reader enricher userId cmd
  case result of
    Left err -> do
      lift $ logError $ "User command rejected: " <> displayShow err
      throwE $ UserError "User command rejected by domain"
    Right _events -> pure ()

-- | Apply a Configuration command, logging and translating rejection.
runConfigurationCmd ::
  MetadataEnricher ->
  UUID ->
  ConfigurationCommand ->
  ExceptT DomainError AppM ()
runConfigurationCmd enricher configId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyConfigurationCommand writer reader enricher configId cmd
  case result of
    Left err -> do
      lift $ logError $ "Configuration command rejected: " <> displayShow err
      throwE $ ConfigurationError (T.pack (show err))
    Right _events -> pure ()

-- | Apply a Transaction command, logging and translating rejection.
--
-- Takes an explicit translator so 'TransactionService.translateTransactionError'
-- (which maps 'CannotEditLabelsInCurrentState' and
-- 'CannotChangeCategoryOnInternalTransfer' to dedicated 'DomainError' values)
-- stays local to its service.
runTransactionCmd ::
  (CommandHandlerError TransactionError -> DomainError) ->
  MetadataEnricher ->
  UUID ->
  TransactionCommand ->
  ExceptT DomainError AppM ()
runTransactionCmd translate enricher txId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyTransactionCommand writer reader enricher txId cmd
  case result of
    Left err -> do
      lift $ logError $ "Transaction command rejected: " <> displayShow err
      throwE (translate err)
    Right _events -> pure ()
```

> **Note on the runner return type:** the underlying `apply*Command` functions return `[AccountingEvent]`, but every existing service call site discards the events (they only branch on Left/Right). The runners therefore return `()` so call sites read `runAccountCmd id … cmd` rather than `_ <- runAccountCmd id … cmd`. If a future caller surfaces that needs the events, change the type to `[AccountingEvent]` and import the type explicitly — do not work around it.

### Step 1.4: Run the test to verify it passes

- [ ] Run: `just test --test-option='--match' --test-option="Application.Services.Internal"`

Expected: 8 examples, 0 failures.

### Step 1.5: Format and lint

- [ ] Run: `just check` (formats with ormolu, then runs hlint).

Expected: no errors. If ormolu reformats the new files, accept the diff. If hlint fires, fix at root cause — **no suppressions** without explicit user approval (per `CLAUDE.md`).

### Step 1.6: Commit and push

- [ ] Run:

```bash
git add src/Application/Services/Internal.hs test/Application/Services/InternalSpec.hs
git commit -m "$(cat <<'EOF'
feat(services): introduce Application.Services.Internal helpers

Adds liftMaybe / liftMaybeM / liftEitherWith / guardE pure lifters and
per-aggregate command runners (runAccountCmd / runUserCmd /
runConfigurationCmd / runTransactionCmd) used by the upcoming
service-flattening refactor (#56). No call sites yet — wired up service
by service in subsequent commits.
EOF
)"
git push -u origin refactor/flatten-service-functions
```

Expected: commit succeeds; push succeeds; CI may run.

---

## Task 2: Refactor `UserService.hs`

**Files:**
- Modify: `src/Application/Services/UserService.hs` (4 public fns: `getProfile`, `changePassword`, `unlinkOAuth`, `unlinkTelegram`)
- Run regression: `test/Application/Services/UserServiceSpec.hs` (untouched)

**Why this service first:** smallest of the six and has every helper category in play (`liftMaybe`/`liftMaybeM`, `liftEitherWith`, `guardE`, `runUserCmd`).

### Step 2.1: Establish a green baseline

- [ ] Run: `just test --test-option='--match' --test-option="Application.Services.UserService"`

Expected: 0 failures. **Record the test count for this module — every later step must show the same number.**

### Step 2.2: Add imports

- [ ] In `src/Application/Services/UserService.hs`, modify the imports block to add:

```haskell
import Application.Services.Internal
  ( guardE,
    liftMaybe,
    liftMaybeM,
    liftEitherWith,
    runUserCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
-- Drop `ExceptT (..)` if your refactor never constructs an ExceptT value via
-- `ExceptT (someAction)`. -Wunused-imports won't catch the redundant
-- constructor bundle, so audit your imports against the function bodies.
```

(Drop any imports that become unused after the rewrite — let `-Wunused-imports` guide you.)

### Step 2.3: Rewrite `getProfile`

- [ ] Replace the body of `getProfile` (currently a `case maybeUserData of Nothing/Just`) with:

```haskell
getProfile userId = runExceptT $ do
  lift $ logInfo "Getting user profile"
  userReadModel <- lift (view userReadModelL)
  userData <- liftMaybeM (NotFound "User" (tshow userId)) (getUser userReadModel userId)
  lift $ logInfo "User profile retrieved successfully"
  pure (userId, userData)
```

The "User not found in read model" warning at the failure site disappears (per the logging policy: `NotFound` lookups become canonical helper-emitted debug lines, not per-call warnings). Success log preserved verbatim.

### Step 2.4: Rewrite `changePassword`

- [ ] Replace the body with:

```haskell
changePassword userId _currentPassword newPassword = runExceptT $ do
  lift $ logInfo "Processing password change"
  guardE (T.length newPassword >= 8)
    $ ValidationErr
    $ mkValidationError "newPassword" "Password must be at least 8 characters" ""
  -- TODO: Verify current password (requires aggregate loading)
  lift $ logWarn "Current password verification skipped - implement aggregate loading"
  newPasswordHash <- lift (hashPassword newPassword)
  let changeCmd = ChangePasswordUserCommand ChangePassword {newHash = newPasswordHash}
  runUserCmd id (unUserId userId) changeCmd
  lift $ logInfo "Password changed successfully"
```

The `logWarn "Password too short"` line at the validation failure site disappears (its only information is what `guardE` already encodes in the `DomainError`). All other logs preserved.

### Step 2.5: Rewrite `unlinkOAuth`

- [ ] Replace the body with:

```haskell
unlinkOAuth userId providerText = runExceptT $ do
  lift $ logInfo $ "Unlinking OAuth provider: " <> display providerText
  provider <-
    liftMaybe
      (ValidationErr (mkValidationError "provider" "Unknown OAuth provider" providerText))
      (parseOAuthProvider providerText)
  userReadModel <- lift (view userReadModelL)
  userData <- liftMaybeM (NotFound "User" (tshow userId)) (getUser userReadModel userId)
  identity <-
    liftMaybe (NotFound "OAuthProvider" providerText)
      $ L.find (\i -> i.provider == provider) userData.oauthIdentities
  when (countLoginMethods userData <= 1) $ do
    lift $ logWarn "Cannot unlink last login method"
    throwE (UserError "Cannot unlink last login method")
  let unlinkCmd = UnlinkOAuthAccountUserCommand UnlinkOAuthAccount {identity = identity}
  runUserCmd id (unUserId userId) unlinkCmd
  lift $ logInfo "OAuth provider unlinked successfully"
```

The `logWarn "OAuth provider not linked"` disappears (it conveys nothing beyond the `NotFound "OAuthProvider"` error). The `"Cannot unlink last login method"` line **stays verbatim** — the spec lists it under "Lines that stay verbatim" because it's a meaningful refusal that helps operators trace why a delete attempt was blocked. Use this 2-line shape instead of `guardE` at that one site:

```haskell
when (countLoginMethods userData <= 1) $ do
  lift $ logWarn "Cannot unlink last login method"
  throwE (UserError "Cannot unlink last login method")
```

Apply the same 2-line pattern in `unlinkTelegram` (Step 2.6) for the same warning.

### Step 2.6: Rewrite `unlinkTelegram`

- [ ] Replace the body with:

```haskell
unlinkTelegram userId = runExceptT $ do
  lift $ logInfo "Unlinking Telegram account"
  userReadModel <- lift (view userReadModelL)
  userData <- liftMaybeM (NotFound "User" (tshow userId)) (getUser userReadModel userId)
  _telegramIdentity <-
    liftMaybe (NotFound "TelegramLink" (tshow userId)) userData.telegramIdentity
  when (countLoginMethods userData <= 1) $ do
    lift $ logWarn "Cannot unlink last login method"
    throwE (UserError "Cannot unlink last login method")
  let unlinkCmd = UnlinkTelegramAccountUserCommand UnlinkTelegramAccount
  runUserCmd id (unUserId userId) unlinkCmd
  lift $ logInfo "Telegram account unlinked successfully"
```

### Step 2.7: Verify nothing regressed

- [ ] Run: `just build` → expect clean.
- [ ] Run: `just test --test-option='--match' --test-option="Application.Services.UserService"` → expect the same example count and 0 failures as Step 2.1.
- [ ] Run: `just check` → expect ormolu/hlint clean.
- [ ] Verify by hand that `module Application.Services.UserService ( ... ) where` is byte-identical to its prior version. Run:

```bash
git diff master -- src/Application/Services/UserService.hs | grep -E "^[-+]\s*(getProfile|changePassword|unlinkOAuth|unlinkTelegram)\s*::"
```

Expected: no output (no exported signature lines changed).

### Step 2.8: Commit and push

- [ ] Run:

```bash
git add src/Application/Services/UserService.hs
git commit -m "$(cat <<'EOF'
refactor(services/user): flatten Either-pyramid in UserService

Rewrite getProfile / changePassword / unlinkOAuth / unlinkTelegram on top
of Application.Services.Internal helpers. Public AppM (Either DomainError
a) signatures and DomainError surface unchanged; UserServiceSpec passes
unmodified. Issue #56.
EOF
)"
git push
```

---

## Task 3: Refactor `AccountService.hs`

**Files:**
- Modify: `src/Application/Services/AccountService.hs`
- Run regression: `test/Application/Services/AccountServiceSpec.hs`

### Step 3.1: Baseline

- [ ] `just test --test-option='--match' --test-option="Application.Services.AccountService"` — record example count.

### Step 3.2: Add imports

```haskell
import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
    runAccountCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
-- Drop `ExceptT (..)` if your refactor never constructs an ExceptT value via
-- `ExceptT (someAction)`. -Wunused-imports won't catch the redundant
-- constructor bundle, so audit your imports against the function bodies.
```

### Step 3.3: Rewrite `createAccount`

- [ ] Replace its body with:

```haskell
createAccount createCmd = runExceptT $ do
  lift $ logInfo "Creating new account..."
  accountUuid <- liftIO UUID.nextRandom
  accountId <-
    liftEitherWith
      (\err -> AccountError ("Internal error: failed to generate account ID: " <> tshow err))
      (mkAccountId accountUuid)
  lift $ logInfo $ "Generated account ID: " <> displayShow accountUuid
  runAccountCmd id accountUuid (CreateAccountAccountCommand createCmd)
  readModel <- lift (view accountReadModelL)
  summary <-
    liftMaybeM (AccountError "Account created but not found in read model")
      (liftIO $ ReadModel.getAccount readModel accountId)
  lift $ logInfo "Account successfully created"
  pure (accountId, summary)
```

### Step 3.4: Rewrite `getAccount`

```haskell
getAccount accountUuid = runExceptT $ do
  lift $ logInfo $ "Getting account: " <> displayShow accountUuid
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  readModel <- lift (view accountReadModelL)
  summary <-
    liftMaybeM (NotFound "Account" (tshow accountUuid))
      (liftIO $ ReadModel.getAccount readModel accountId)
  lift $ logInfo "Account found"
  pure (accountId, summary)
```

### Step 3.5: Rewrite `shareAccount`

```haskell
shareAccount requestingUserId accountUuid targetUserUuid roleText = runExceptT $ do
  lift $ logInfo $ "Sharing account: " <> displayShow accountUuid
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  readModel <- lift (view accountReadModelL)
  summary <-
    liftMaybeM (NotFound "Account" (tshow accountUuid))
      (liftIO $ ReadModel.getAccount readModel accountId)
  guardE (summary.createdBy == requestingUserId)
    (AccountError "Only account owner can share access")
  guardE (summary.accountType /= External)
    (AccountError "External accounts cannot be shared")
  targetUserId <-
    liftEitherWith
      (\_ -> ValidationErr (mkValidationError "userId" "Invalid user ID" (tshow targetUserUuid)))
      (mkUserId targetUserUuid)
  role <-
    liftMaybe
      ( ValidationErr
          ( mkValidationError "role" "Invalid role. Must be 'owner', 'editor', or 'viewer'" roleText
          )
      )
      (parseRole roleText)
  let shareCmd =
        ShareAccountAccountCommand
          ShareAccount
            { userId = targetUserId,
              role = role,
              grantedBy = requestingUserId
            }
  runAccountCmd id accountUuid shareCmd
  lift $ logInfo "Account shared successfully"
```

### Step 3.6: Rewrite `revokeAccountAccess`

```haskell
revokeAccountAccess requestingUserId accountUuid targetUserUuid = runExceptT $ do
  lift $ logInfo $ "Revoking account access: " <> displayShow accountUuid
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  readModel <- lift (view accountReadModelL)
  summary <-
    liftMaybeM (NotFound "Account" (tshow accountUuid))
      (liftIO $ ReadModel.getAccount readModel accountId)
  guardE (summary.createdBy == requestingUserId)
    (AccountError "Only account owner can revoke access")
  targetUserId <-
    liftEitherWith
      (\_ -> ValidationErr (mkValidationError "userId" "Invalid user ID" (tshow targetUserUuid)))
      (mkUserId targetUserUuid)
  guardE (targetUserId /= summary.createdBy) (AccountError "Cannot revoke owner's access")
  let revokeCmd =
        RevokeAccountAccessAccountCommand
          RevokeAccountAccess
            { userId = targetUserId,
              revokedBy = requestingUserId
            }
  runAccountCmd id accountUuid revokeCmd
  lift $ logInfo "Account access revoked successfully"
```

### Step 3.7: Rewrite `setOverdraftLimit` and `setAccountSubtype`

Both share the same shape:

```haskell
setOverdraftLimit requestingUserId accountUuid newLimit = runExceptT $ do
  lift $ logInfo $ "Setting overdraft limit: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd =
        SetOverdraftLimitAccountCommand
          SetOverdraftLimit {overdraftLimit = newLimit, setBy = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Overdraft limit set successfully"

setAccountSubtype requestingUserId accountUuid newType = runExceptT $ do
  lift $ logInfo $ "Setting account type: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd =
        SetAccountSubtypeAccountCommand
          SetAccountSubtype {subtype = newType, setBy = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account type set successfully"
```

`listAccountsForUser` is already linear — leave it alone.

### Step 3.8: Verify, commit, push

- [ ] `just build` → clean.
- [ ] `just test --test-option='--match' --test-option="Application.Services.AccountService"` → 0 failures, same example count.
- [ ] `just check` → clean.
- [ ] Commit and push:

```bash
git add src/Application/Services/AccountService.hs
git commit -m "refactor(services/account): flatten Either-pyramid in AccountService (#56)"
git push
```

---

## Task 4: Refactor `BankImportService.hs`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`
- Run regression: `test/Application/Services/BankImportServiceSpec.hs`

This task includes the **deletion of `logCrossCurrencyRate`** (stale Phase 1 diagnostic — Phase 2 has shipped via PR #57).

### Step 4.1: Baseline

- [ ] `just test --test-option='--match' --test-option="Application.Services.BankImport"` — record example count.

### Step 4.2: Add imports, drop unused

- [ ] Add the same `Application.Services.Internal` and `Control.Monad.Trans.Except` imports as Task 2/3, plus `Control.Monad.Trans.Class (lift)` if not pulled in transitively.

### Step 4.3: Rewrite `importTransaction`

> **Why this service is not a single `runExceptT` block:** the original `importTransaction` returns `Right Nothing` (success-but-skipped) for "hold transaction", "already imported", "no account mapping", "unsupported currency", and "money construction failure" — but `Left DomainError` for "user not found", "config lookup failed", "category resolution failed", and "transfer initiation failed". `ExceptT` only short-circuits on `Left`, not on `Right Nothing`, so a single outer `runExceptT $ do` cannot model both. The rewrite splits the function into three layers: a top-level dispatcher that handles the cheap skip-paths (`tx.hold`, dedup, account-mapping miss); a middle helper `importMatchedTransaction` that handles the next two skip-paths (currency code, money construction); and a leaf helper `commitImport` running inside `ExceptT` that holds the genuinely-fallible work.

- [ ] Use this concrete shape for `importTransaction` (the dispatcher):

```haskell
importTransaction provider userId accountLink tx
  | tx.hold = logDebug ("Skipping hold transaction: " <> display tx.externalId) $> Right Nothing
  | otherwise = do
      bankImportRM <- view bankImportReadModelL
      alreadyImported <- isImported bankImportRM tx.externalId
      if alreadyImported
        then logDebug ("Skipping already-imported transaction: " <> display tx.externalId) $> Right Nothing
        else case lookup tx.accountId accountLink of
          Nothing ->
            logWarn ("No account mapping for external account: " <> display tx.accountId) $> Right Nothing
          Just localAccId -> importMatched provider userId localAccId tx
  where
    importMatched = importMatchedTransaction
```

Then introduce `importMatchedTransaction` as a top-level helper:

```haskell
importMatchedTransaction ::
  BankProvider ->
  UserId ->
  AccountId ->
  BankTransaction ->
  AppM (Either DomainError (Maybe TransactionId))
importMatchedTransaction provider userId localAccId tx = do
  userRM <- view userReadModelL
  maybeUser <- UserRM.getUser userRM userId
  case maybeUser of
    Nothing -> do
      logWarn $ "User not found: " <> displayShow userId
      pure (Left (NotFound "User" (tshow userId)))
    Just userData ->
      case currencyFromNumericCode tx.currencyCode of
        Left err -> do
          logWarn $ "Unsupported currency code " <> displayShow tx.currencyCode <> ": " <> display err
          pure (Right Nothing)
        Right currency ->
          case mkMoney currency (abs tx.amount) of
            Left err -> do
              logWarn $ "Failed to create money: " <> display err
              pure (Right Nothing)
            Right money -> runExceptT (commitImport provider userId userData localAccId tx money)
```

`commitImport` is the genuinely-fallible part (config lookup, category resolution, transfer initiation) and is the only function that benefits from `runExceptT`:

```haskell
commitImport ::
  BankProvider ->
  UserId ->
  UserData ->
  AccountId ->
  BankTransaction ->
  Money ->
  ExceptT DomainError AppM (Maybe TransactionId)
commitImport provider userId userData localAccId tx money = do
  let externalAccId = userData.externalAccountId
      direction = provider.classifyTransaction tx
  cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
  (categoryId, resolution) <-
    liftEitherWith id (resolveCategory cfg.banking cfg direction tx.mcc)
  lift $ logCategoryResolution tx direction cfg categoryId resolution
  let (sourceAccId, targetAccId, transferType) =
        classifyEndpoints localAccId externalAccId direction categoryId
      cmd = buildTransferCmd userId tx sourceAccId targetAccId money transferType
      enricher m = m {occurredAt = Just tx.time}
  (txId, _) <- ExceptT (TransactionService.initiateTransfer enricher cmd)
  lift $ logInfo $ "Imported transaction " <> display tx.externalId <> " as " <> displayShow txId
  pure (Just txId)
```

> **Note:** `classifyEndpoints` and `buildTransferCmd` move from `where`-bindings inside `importTransaction` to top-level helpers (or `where`-bindings inside `commitImport`); pick whichever the implementer judges most readable. `buildTransferCmd` now takes `userId` as an extra parameter since it's no longer enclosing the original function's lexical scope.

### Step 4.4: Delete `logCrossCurrencyRate`

- [ ] Remove the entire `logCrossCurrencyRate = case tx.originalAmount of …` `where`-binding **and** its single call site (the `logCrossCurrencyRate` line that used to sit inside the deepest branch). The comment block above it that explains "Phase 1: Monobank does not report the foreign currency code…" goes too — Phase 2 has shipped.

### Step 4.5: Verify, commit, push

- [ ] `just build` clean.
- [ ] `just test --test-option='--match' --test-option="Application.Services.BankImport"` → same example count, 0 failures.
- [ ] `just check` clean.

```bash
git add src/Application/Services/BankImportService.hs
git commit -m "$(cat <<'EOF'
refactor(services/bank): flatten importTransaction; drop Phase-1 rate log

Lifts the genuinely-fallible suffix of importTransaction into a
commitImport ExceptT helper while the skip-paths (hold, duplicate, no
account mapping, unsupported currency, money construction failure) keep
their early-return shape because each yields Right Nothing rather than
short-circuiting. Deletes logCrossCurrencyRate — stale Phase 1 diagnostic;
Phase 2 (#57) has shipped. Issue #56.
EOF
)"
git push
```

---

## Task 5: Refactor `ConfigurationService.hs`

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs`
- Run regression: `test/Application/Services/ConfigurationServiceSpec.hs`, `ConfigurationServiceInUseSpec.hs`, `ConfigurationServiceIntegrationSpec.hs`

**Special case:** `seedDefaultConfiguration` deliberately does not short-circuit — its inner per-entry loops keep their non-short-circuiting `case ... of Left err -> logWarn; Right _ -> pure ()` shape. Only its outer `case maybeConfig of Just _ -> skip; Nothing -> seed` collapses.

### Step 5.1: Baseline

- [ ] Run all three Configuration spec files matching `Application.Services.Configuration` and record the total example count.

### Step 5.2: Imports

```haskell
import Application.Services.Internal
  ( liftMaybe,
    liftMaybeM,
    runAccountCmd,
    runConfigurationCmd,
    runUserCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
-- Drop `ExceptT (..)` if your refactor never constructs an ExceptT value via
-- `ExceptT (someAction)`. -Wunused-imports won't catch the redundant
-- constructor bundle, so audit your imports against the function bodies.
```

### Step 5.3: Rewrite the small fns first

- [ ] `getConfigurationForUser`, `changeBaseCurrency`, `changeDefaultCurrency`, `addDictionaryEntry`, `renameDictionaryEntry`, `setBankingDefaultIncomeCategory`, `setBankingDefaultExpenseCategory`, `setBankingMccExpenseCategoryMap`. Each follows the same pattern: `runExceptT $ do { logInfo ...; configId <- ExceptT (ensureClonedConfiguration userId); runConfigurationCmd id (unConfigurationId configId) cmd; logInfo "..." }`.

Example for `addDictionaryEntry`:

```haskell
addDictionaryEntry userId dictId entryName = runExceptT $ do
  lift $ logInfo $ "Adding dictionary entry to " <> displayShow dictId <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  entryUuid <- liftIO UUID.nextRandom
  let entryId = unsafeDictionaryEntryId entryUuid
      cmd =
        AddDictionaryEntryConfigurationCommand
          AddDictionaryEntry
            { dictionaryId = dictId,
              entryId = entryId,
              name = entryName
            }
  runConfigurationCmd id (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry added successfully"
  pure entryId
```

`changeBaseCurrency` is the only one that does two commands (account currency + base currency). It lines up cleanly:

```haskell
changeBaseCurrency userId newCurrency = runExceptT $ do
  lift $ logInfo $ "Changing base currency to " <> displayShow newCurrency <> " for user " <> displayShow userId
  userRM <- lift (view userReadModelL)
  userData <- liftMaybeM (NotFound "User" (tshow userId)) (liftIO $ getUser userRM userId)
  configId <- ExceptT (ensureClonedConfiguration userId)
  runAccountCmd
    id
    (unAccountId userData.externalAccountId)
    (ChangeAccountCurrencyAccountCommand ChangeAccountCurrency {newCurrency = newCurrency})
  runConfigurationCmd
    id
    (unConfigurationId configId)
    (ChangeBaseCurrencyConfigurationCommand ChangeBaseCurrency {baseCurrency = newCurrency})
  lift $ logInfo "Base currency changed successfully"
```

### Step 5.4: Rewrite `removeDictionaryEntry`

```haskell
removeDictionaryEntry userId dictId entryId = runExceptT $ do
  lift $ logInfo $ "Removing dictionary entry from " <> displayShow dictId <> " for user " <> displayShow userId
  txnRM <- lift (view transactionReadModelL)
  usageCount <- lift (findReferencingTransactions txnRM entryId)
  let inUse =
        if dictId == labelsDictId
          then LabelInUse {entryId = T.pack (show (unDictionaryEntryId entryId)), usageCount = usageCount}
          else CategoryInUse {entryId = T.pack (show (unDictionaryEntryId entryId)), usageCount = usageCount}
  guardE (usageCount == 0) inUse
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RemoveDictionaryEntryConfigurationCommand
          RemoveDictionaryEntry {dictionaryId = dictId, entryId = entryId}
  runConfigurationCmd id (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry removed successfully"
```

The "Refusing to remove dictionary entry: N transaction(s)…" `logWarn` disappears (the `LabelInUse`/`CategoryInUse` `DomainError` carries the count, so the canonical helper line plus the error itself are sufficient).

### Step 5.5: Flatten `lookupUserConfiguration`, `ensureClonedConfiguration`, `cloneConfiguration`

Same pattern. `cloneConfiguration` is the largest helper (~90 lines); inside the function, the per-dictionary-entry copy loop and the per-banking-field copy keep their `forM_ ... case Left err -> logWarn; Right _ -> pure ()` shape — they intentionally do not short-circuit. Only the outer "create cloned config + assign to user" pair gets `runExceptT`.

```haskell
cloneConfiguration userId sourceConfigId configData = runExceptT $ do
  lift $ logInfo $ "Cloning configuration " <> displayShow sourceConfigId <> " for user " <> displayShow userId
  newConfigUuid <- liftIO UUID.nextRandom
  newConfigId <-
    liftEitherWith
      (\err -> ConfigurationError ("Internal error: failed to generate configuration ID: " <> tshow err))
      (mkConfigurationId newConfigUuid)
  let newConfigUuidVal = unConfigurationId newConfigId
  runConfigurationCmd
    id
    newConfigUuidVal
    ( CreateConfigurationConfigurationCommand
        CreateConfiguration
          { baseCurrency = configData.baseCurrency,
            defaultCurrency = configData.defaultCurrency,
            createdBy = ClonedBy userId sourceConfigId
          }
    )
  lift (copyDictionaries newConfigUuidVal configData.dictionaries)
  lift (copyBanking newConfigUuidVal configData.banking)
  runUserCmd
    id
    (unUserId userId)
    ( AssignConfigurationUserCommand
        AssignConfiguration {configurationId = newConfigId}
    )
  lift $ logInfo $ "Configuration cloned successfully: " <> displayShow newConfigId
  pure newConfigId
```

`copyDictionaries` and `copyBanking` are new top-level helpers that iterate with `forM_`/`unless` and keep the existing per-entry `logWarn`-on-failure shape verbatim. Extract per the auto-memory feedback that says: don't inline multi-line log construction inside case/do branches; lift to a named function.

### Step 5.6: Touch `seedDefaultConfiguration` only at its outer case

- [ ] Replace the outermost `case maybeConfig of Just _ -> ... ; Nothing -> ...` with a guard:

```haskell
seedDefaultConfiguration = do
  logInfo "Checking if default configuration needs seeding..."
  configRM <- view configurationReadModelL
  maybeConfig <- liftIO $ getConfiguration configRM defaultConfigurationId
  when (isNothing maybeConfig) seedFresh
  when (isJust maybeConfig) (logInfo "Default configuration already exists, skipping seed")
  where
    seedFresh = do
      logInfo "Seeding default configuration..."
      ... -- the rest of the function body, unchanged
```

(Or split into `seedFresh` as a top-level helper for readability.) **Do not** touch the inner `forM_`-with-per-entry-warnings loops — they intentionally do not short-circuit on failure.

### Step 5.7: Verify, commit, push

- [ ] `just build` clean.
- [ ] All three Configuration spec files green with same example counts.
- [ ] `just check` clean.

```bash
git add src/Application/Services/ConfigurationService.hs
git commit -m "refactor(services/configuration): flatten Either-pyramids; preserve seedDefaultConfiguration's non-short-circuiting loops (#56)"
git push
```

---

## Task 6: Refactor `AuthService.hs`

**Files:**
- Modify: `src/Application/Services/AuthService.hs`
- Run regression: any spec matching `Application.Services.AuthService` (search the test tree).

The largest gain is in `createUserViaOAuth` (7 levels deep) and `createUserViaTelegram` (same shape).

### Step 6.1: Baseline

- [ ] `just test` (full run; auth uses many fixtures and may not have a single matchable spec). Record the total count.

### Step 6.2: Imports

```haskell
import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
    runAccountCmd,
    runUserCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
-- Drop `ExceptT (..)` if your refactor never constructs an ExceptT value via
-- `ExceptT (someAction)`. -Wunused-imports won't catch the redundant
-- constructor bundle, so audit your imports against the function bodies.
```

### Step 6.3: Rewrite functions in dependency order

Order matters here because some public functions delegate to `createUserViaOAuth` / `createUserViaTelegram`. Rewrite leaves first.

- [ ] `generateAuthResult`:

```haskell
generateAuthResult userId email = runExceptT $ do
  jwtConfig <- lift (view jwtConfigL)
  let emailText = fromMaybe "unknown@example.com" email
  token <-
    ExceptT
      $ first (\err -> AccountError ("Failed to generate authentication token: " <> tshow err))
      <$> JWT.generateToken jwtConfig userId emailText
  pure
    AuthResult
      { token = token,
        userId = userId,
        email = email,
        expiresIn = jwtConfig.expirySeconds
      }
```

- [ ] `createUserViaOAuth`:

```haskell
createUserViaOAuth email oauthIdentity = runExceptT $ do
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom
  uid <- liftEitherWith (\_ -> AccountError "Internal error") (mkUserId userUuid)
  externalAccountId <-
    liftEitherWith (\_ -> AccountError "Internal error") (mkAccountId externalAccountUuid)
  pwHash <- lift (hashPassword "OAUTH_USER_NO_PASSWORD")
  runUserCmd
    id
    userUuid
    ( RegisterUserUserCommand
        RegisterUser
          { email = email,
            passwordHash = pwHash,
            externalAccountId = externalAccountId
          }
    )
  runUserCmd
    id
    userUuid
    (AssignConfigurationUserCommand (AssignConfiguration {configurationId = defaultConfigurationId}))
  configRM <- lift (view configurationReadModelL)
  maybeConfig <- lift (getConfiguration configRM defaultConfigurationId)
  let baseCur = maybe USD (\c -> c.baseCurrency) maybeConfig
  runAccountCmd
    id
    externalAccountUuid
    ( CreateAccountAccountCommand
        CreateAccount
          { name = "External",
            initialBalance = unsafeMoney baseCur 0,
            createdBy = uid,
            accountType = External,
            overdraftLimit = Nothing
          }
    )
  runUserCmd
    id
    userUuid
    (LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity})
  ExceptT (generateAuthResult uid (Just email))
```

- [ ] `createUserViaTelegram`: same shape, slightly different commands. Translate one-to-one.

- [ ] `register`: combines email-existence check, hashing, registration, configuration assignment, external account creation, JWT. Lifts to:

```haskell
register email password = runExceptT $ do
  lift $ logInfo "Processing registration request"
  userReadModel <- lift (view userReadModelL)
  exists <- lift (emailExists userReadModel email)
  guardE (not exists) (AccountError "Email already registered")
  passwordHash <- lift (hashPassword password)
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom
  userId <- liftEitherWith (\_ -> AccountError "Internal error") (mkUserId userUuid)
  externalAccountId <-
    liftEitherWith (\_ -> AccountError "Internal error") (mkAccountId externalAccountUuid)
  runUserCmd
    id
    userUuid
    ( RegisterUserUserCommand
        RegisterUser
          { email = email,
            passwordHash = passwordHash,
            externalAccountId = externalAccountId
          }
    )
  runUserCmd
    id
    userUuid
    (AssignConfigurationUserCommand (AssignConfiguration {configurationId = defaultConfigurationId}))
  configRM <- lift (view configurationReadModelL)
  maybeConfig <- lift (getConfiguration configRM defaultConfigurationId)
  let baseCur = maybe USD (\c -> c.baseCurrency) maybeConfig
  runAccountCmd
    id
    externalAccountUuid
    ( CreateAccountAccountCommand
        CreateAccount
          { name = "External",
            initialBalance = unsafeMoney baseCur 0,
            createdBy = userId,
            accountType = External,
            overdraftLimit = Nothing
          }
    )
  ExceptT (generateAuthResult userId (Just email))
```

- [ ] `login`: read user → check `hasPassword` → load aggregate → verify password → generate token. Each step lifts cleanly. Key wrinkle: the same `AccountError "Invalid email or password"` is returned for "no user", "no password set", "no hash on aggregate", and "verify failed" — preserve all four for parity:

```haskell
login email password = runExceptT $ do
  lift $ logInfo "Processing login request"
  userReadModel <- lift (view userReadModelL)
  (userId, userSummary) <-
    liftMaybeM (NotFound "User" email) (getUserByEmail userReadModel email)
  guardE userSummary.hasPassword (AccountError "Invalid email or password")
  reader <- lift (view eventStoreReaderL)
  userAggregate <- liftIO (loadUserAggregate reader (unUserId userId))
  storedHash <-
    liftMaybe
      (AccountError "Invalid email or password")
      userAggregate.passwordHash
  guardE (verifyPassword password storedHash) (AccountError "Invalid email or password")
  let userEmail = fromMaybe email userSummary.email
  ExceptT (generateAuthResult userId (Just userEmail))
```

The `logError "User has password flag but no hash in aggregate"` line — which signals a serious data inconsistency — is preserved by keeping a `logWarn`/`logError` adjacent to that specific `liftMaybe`. **Promote that one to a custom step:**

```haskell
storedHash <- case userAggregate.passwordHash of
  Just h -> pure h
  Nothing -> do
    lift $ logError "User has password flag but no hash in aggregate"
    throwE (AccountError "Invalid email or password")
```

(Per the spec's logging policy: domain-meaningful warnings stay verbatim. This one is a "should not happen, alert" line.)

- [ ] `initiateOAuth`, `handleOAuthCallback`, `linkOAuth`, `authenticateTelegram`, `linkTelegram`, `refreshToken`, `findOrCreateTelegramBotUser`: translate using the same pattern. Each ends with an `ExceptT (generateAuthResult ...)` or a `runUserCmd` final action.

### Step 6.4: Verify, commit, push

- [ ] `just build` clean.
- [ ] `just test` for any auth-related spec → 0 failures.
- [ ] `just check` clean.

```bash
git add src/Application/Services/AuthService.hs
git commit -m "refactor(services/auth): flatten Either-pyramids; deepest gain in createUserViaOAuth (#56)"
git push
```

---

## Task 7: Refactor `TransactionService.hs`

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`
- Run regression: `test/Application/Services/TransactionServiceSpec.hs`, `TransactionServiceLabelsSpec.hs`

This is the largest service and the one whose pyramid the issue cites first. Allocate the most attention here.

### Step 7.1: Baseline

- [ ] `just test --test-option='--match' --test-option="Application.Services.Transaction"` — record example count (across both Spec files).

### Step 7.2: Imports

```haskell
import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
    runTransactionCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
-- Drop `ExceptT (..)` if your refactor never constructs an ExceptT value via
-- `ExceptT (someAction)`. -Wunused-imports won't catch the redundant
-- constructor bundle, so audit your imports against the function bodies.
```

### Step 7.3: Rewrite helpers first

- [ ] `validateLabels` (currently a `case` over `getConfigurationForUser`): collapses to one ExceptT block.

```haskell
validateLabels userId labels
  | Set.null labels = pure (Right ())
  | otherwise = runExceptT $ do
      cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
      let known = dictionaryEntryIds ConfigurationService.labelsDictId cfg
          missing = Set.difference labels known
      case Set.toList missing of
        [] -> pure ()
        (eid : _) -> throwE (LabelNotFound (tshow (unDictionaryEntryId eid)))
```

- [ ] `categoryExists`: similar two-line ExceptT body.

- [ ] `ensureEditorAccess`, `dispatchEdit`, `resolveAndInitiate`, `queryTransactionResult`, `resolveAmounts`: each becomes a `runExceptT $ do …` block. `resolveAmounts` is polymorphic over `m`; keep its signature but switch the body to `runExceptT` over `ExceptT DomainError m`.

### Step 7.4: Rewrite `getTransaction`

- [ ] Replace the body with:

```haskell
getTransaction transactionUuid = runExceptT $ do
  lift $ logInfo $ "Getting transaction: " <> displayShow transactionUuid
  transactionId <-
    liftEitherWith
      (\_ -> NotFound "Transaction" (tshow transactionUuid))
      (mkTransactionId transactionUuid)
  ExceptT (queryTransactionResult transactionId)
```

The "Transaction ID validation failed" `logWarn` disappears (the helper-emitted "not found" line covers it).

### Step 7.5: Rewrite the four initiate fns

- [ ] `initiateTransfer`:

```haskell
initiateTransfer enricher transferCmd = runExceptT $ do
  lift $ logInfo "Initiating money transfer..."
  transactionUuid <- liftIO UUID.nextRandom
  transactionId <-
    liftEitherWith
      (\err -> TransactionError ("Internal error: failed to generate transaction ID: " <> tshow err))
      (mkTransactionId transactionUuid)
  lift $ logInfo $ "Generated transaction ID: " <> displayShow transactionUuid
  runTransactionCmd
    (\_ -> TransactionError "Transfer initiation rejected by domain")
    enricher
    transactionUuid
    (InitiateTransferTransactionCommand transferCmd)
  -- queryTransactionResult is itself ExceptT-shaped after Step 7.3
  ExceptT (queryTransactionResult transactionId)
```

- [ ] `initiateIncome`, `initiateExpense`, `initiateInternalTransfer`: each is ~25 lines now (down from ~50). Pattern (income shown):

```haskell
initiateIncome userId targetAccountId amount categoryEntryId labels description maybeTransferDate =
  runExceptT $ do
    lift $ logInfo "Initiating income transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    userRM <- lift (view userReadModelL)
    userData <- liftMaybeM (NotFound "User" (tshow userId)) (UserRM.getUser userRM userId)
    let externalAccId = userData.externalAccountId
    accountRM <- lift (view accountReadModelL)
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow targetAccountId))
        (AccountRM.getAccount accountRM targetAccountId)
    guardE
      (targetData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId))
      )
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow externalAccId))
        (AccountRM.getAccount accountRM externalAccId)
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency False Nothing
          $ \srcAmt tgtAmt rate ->
            InitiateTransfer
              { sourceAccountId = externalAccId,
                targetAccountId = targetAccountId,
                sourceAmount = srcAmt,
                targetAmount = tgtAmt,
                exchangeRate = rate,
                description = description,
                initiatedBy = userId,
                transferType = Income categoryEntryId,
                externalTransactionId = Nothing,
                labels = labels
              }
      )
```

The two `logWarn` lines per function ("Target account is not a regular account", "Source account is not a regular account") drop in favour of the canonical helper-emitted line — `guardE` carries the `DomainError` payload.

- [ ] `setTransactionLabels` and `changeTransactionCategory`: identical pattern to access-check + validate + dispatch.

```haskell
setTransactionLabels userId transactionId labels = runExceptT $ do
  lift $ logInfo $ "Setting labels on " <> displayShow transactionId <> " for user " <> displayShow userId
  _summary <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (validateLabels userId labels)
  let cmd =
        SetTransactionLabelsTransactionCommand
          SetTransactionLabels {transactionId = transactionId, labels = labels}
  ExceptT (dispatchEdit transactionId cmd)

changeTransactionCategory userId transactionId newCategory = runExceptT $ do
  lift $ logInfo $ "Changing category on " <> displayShow transactionId <> " for user " <> displayShow userId
  summary <- ExceptT (ensureEditorAccess userId transactionId)
  dictId <-
    liftMaybe CannotChangeCategoryOnInternalTransfer (pickCategoryDict summary.transferType)
  known <- ExceptT (categoryExists userId dictId newCategory)
  guardE known (CategoryNotFound (tshow (unDictionaryEntryId newCategory)))
  let cmd =
        ChangeTransactionCategoryTransactionCommand
          ChangeTransactionCategory {transactionId = transactionId, newCategory = newCategory}
  ExceptT (dispatchEdit transactionId cmd)
```

- [ ] `dispatchEdit` uses `runTransactionCmd translateTransactionError` as the reject mapping — that's the whole reason `runTransactionCmd` accepts a translator argument:

```haskell
dispatchEdit transactionId cmd = runExceptT $ do
  runTransactionCmd translateTransactionError id (unTransactionId transactionId) cmd
  (_, td) <- ExceptT (queryTransactionResult transactionId)
  pure td
```

`translateTransactionError` and `pickCategoryDict` stay byte-identical.

### Step 7.6: Verify, commit, push

- [ ] `just build` clean.
- [ ] Both Transaction spec files green with same example counts.
- [ ] `just check` clean.

```bash
git add src/Application/Services/TransactionService.hs
git commit -m "refactor(services/transaction): flatten initiateIncome/Expense/InternalTransfer pyramids (#56)"
git push
```

---

## Task 8: Final acceptance verification

This task creates no commits unless an issue surfaces. Its purpose is the issue's literal acceptance gate.

### Step 8.1: Surviving nested `case`s — enumerate and justify

- [ ] Run:

```bash
grep -nE '^\s{4,}case |^\s{6,}case ' src/Application/Services/*.hs | grep -v 'AuthorizationService\|ExchangeRatePublisher'
```

Expected: every match falls into one of the categories the spec marks as legitimate multi-way branching:

- `case TransferType` (in `pickCategoryDict`)
- `case OAuthProvider` / `case parseOAuthProvider t of`
- `case AccountType` / `case direction of`
- `case ... originalAmount of` was removed in Task 4 — should not appear
- `seedDefaultConfiguration`'s per-entry `case Left/Right` loops (intentional non-short-circuit; spec'd carve-out)
- `cloneConfiguration`'s per-entry copy loops (same — intentional non-short-circuit)
- `resync`'s per-account driver shape (intentional)

Anything else is a regression — go back to the offending service and rewrite that function before claiming done.

### Step 8.2: Exported-signature invariant

- [ ] Run for each refactored service file:

```bash
for f in UserService AccountService BankImportService ConfigurationService AuthService TransactionService; do
  echo "=== $f ==="
  git diff master -- "src/Application/Services/$f.hs" | sed -n '/^@@/,/^@@/p' | grep -E "^[-+]\s*(module|[a-z][A-Za-z0-9']*\s*::)" || true
done
```

Expected: no `module …` lines change; no exported-function `:: …` type signature lines change. (Internal helpers may show; verify each by name against the per-service inventory in the spec.)

### Step 8.3: Full suite green

- [ ] Run: `just test`. Expected: same total example count as the run on `master`, 0 failures, 0 pending.
- [ ] Run: `just check`. Expected: clean.
- [ ] Run: `just build` with the `-fci` flag (CI mode, `-Werror`):

```bash
cabal build -fci all
```

Expected: clean build under `-Werror`.

### Step 8.4: Update spec frontmatter

- [ ] Edit `docs/specs/2026-04-27-flatten-service-functions-design.md` frontmatter: change `status: draft` to `status: completed`. Same for any related plan README index entry if you maintain one.

```bash
git add docs/specs/2026-04-27-flatten-service-functions-design.md
git commit -m "docs(spec): mark flatten-service-functions design as completed"
git push
```

### Step 8.5: Open the PR

- [ ] Run:

```bash
gh pr create \
  --base master \
  --title "refactor: flatten service functions — less Either-nesting (#56)" \
  --body "$(cat <<'EOF'
## Summary

- Replaces the nested `case Left/Right` ladders inside the six in-scope services with linear `runExceptT $ do` happy paths, on top of a new `Application.Services.Internal` helper module (four pure lifters + four per-aggregate command runners).
- Public `AppM (Either DomainError a)` signatures, `DomainError` values, and HTTP error mapping are byte-identical to `master`. `just test` is green with no test assertion changes.
- Logging follows the spec's hybrid policy: canonical "rejected" / "not found" lines consolidated into helpers; domain-meaningful contextual logs preserved verbatim. Stale Phase 1 cross-currency-rate diagnostic deleted from `BankImportService`.

Closes #56.

## Test plan

- [ ] `just test` — full suite green, same example count as `master`.
- [ ] `just check` — ormolu + hlint clean.
- [ ] `cabal build -fci all` — `-Werror` clean.
- [ ] Spot check: `git diff master -- src/Application/Services/*.hs | grep -E "^[-+]\s*(module|[a-z][A-Za-z0-9']*\s*::)"` shows no exported signature changes.
- [ ] Spec & plan: `docs/specs/2026-04-27-flatten-service-functions-design.md`, `docs/plans/2026-04-27-flatten-service-functions.md`.
EOF
)"
```

---

## Risks during implementation

| Risk | Mitigation |
|------|------------|
| `ExceptT` short-circuiting changes the order of side effects vs. the original code (e.g. logs emitted before reads). | Each helper logs at the failure site before `throwE`. Side-effecting reads stay in the same lexical order; `ExceptT` only changes the path on `Left`. |
| Accidentally adjusting a `DomainError` constructor or message during translation. | The plan supplies the exact `DomainError` value at each call site. When in doubt, `git diff master` and ensure the `Left … =` shape matches the prior code's `return $ Left …`. |
| `seedDefaultConfiguration` accidentally rewritten to short-circuit. | Step 5.6 is explicit: only the outer existence-check `case` collapses. Inner `forM_`-with-warn loops are preserved verbatim. |
| Tests appear to pass but were never run (e.g. typo in `--match` filter). | Each task records the baseline example count before any change and re-checks it after; a count drop is a regression signal. |
| A helper imports more than it needs and triggers `-Wunused-imports` under `-Werror`. | Drop redundant imports in Task 1.3 immediately if the warning fires. |
| Push to `origin` blocked or fails. | Investigate; do not `--force`. The branch starts clean from `master` and only fast-forward pushes are needed. |

## Out-of-scope reminders

- Do not change `DomainError`, `AppM`, `AppEnv`, or any domain command/aggregate.
- Do not touch `AuthorizationService.hs`, `ExchangeRatePublisher.hs`, or anything outside `src/Application/Services/`.
- Do not modify any existing test file; only `test/Application/Services/InternalSpec.hs` is added.
- Do not promote `MonadError DomainError` into `AppM` even if it would shorten a signature — the spec is explicit that this is *not* an architecture change.
