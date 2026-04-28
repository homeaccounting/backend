---
status: draft
date: 2026-04-28
spec: docs/specs/2026-04-28-oauth-auto-link-by-email-design.md
branch: feat/oauth-auto-link
---

# OAuth Auto-Link by Verified Email Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When OAuth sign-in finds no existing user via `(provider, subject)` but the OAuth provider returns a *verified* email that already belongs to a registered user, attach the OAuth identity to that user instead of silently minting a duplicate account.

**Architecture:** Plumb a new `emailVerified :: Bool` signal up from the OAuth userinfo response (Google's `email_verified` claim today; default `False` for everything else). Extract the OAuth-callback decision tree from the HTTP-touching code in `AuthService.handleOAuthCallback` into a pure-of-HTTP helper `linkOrSignInWithOAuth :: OAuthProvider -> OAuthUserInfo -> AppM (Either DomainError AuthResult)`. Add the auto-link branch there. Tests drive the helper directly with handcrafted `OAuthUserInfo` values.

**Tech Stack:** Haskell 9.10.3, RIO, Servant, hspec + hspec-discover, Eventium in-memory event store, ormolu + hlint via `just check`.

**Branch:** `feat/oauth-auto-link` (already created during brainstorming — spec commit lives here, rebased on master).

**Design reference:** `docs/specs/2026-04-28-oauth-auto-link-by-email-design.md`. Read sections §1, §4, §6 before starting. The spec is authoritative; if the plan and spec disagree, flag it — do not silently diverge.

---

## File Map

Files modified:

- `src/Infrastructure/Auth/OAuth.hs`
  - Add `emailVerified :: Bool` field to `OAuthUserInfo`.
  - Extend `parseGoogleUserInfo` to read the `email_verified` claim.
  - `parseGitHubUserInfo` and `parseMicrosoftUserInfo` set `emailVerified = False` (their basic userinfo endpoints don't expose a verification signal).

- `src/Application/Services/AuthService.hs`
  - Extract `linkOrSignInWithOAuth :: OAuthProvider -> OAuth.OAuthUserInfo -> AppM (Either DomainError AuthResult)` from the body of `handleOAuthCallback`. Export it (the helper is the test surface).
  - `handleOAuthCallback` becomes a thin orchestrator: do HTTP, then delegate to `linkOrSignInWithOAuth`.
  - Add the auto-link branch in `linkOrSignInWithOAuth` per spec §1 / §6.

Files created:

- `test/Infrastructure/Auth/OAuthSpec.hs` — parser tests for `email_verified`.
- `test/Application/Services/AuthServiceSpec.hs` — service-layer tests for `linkOrSignInWithOAuth`'s 5 branches.

No changes to `package.yaml` / `backend.cabal`: `hspec-discover` auto-finds any new `*Spec.hs` under `test/`.

---

## Conventions

- **Branch & commits.** All work lands on `feat/oauth-auto-link`. Commits follow Conventional Commits.
- **TDD.** Failing test first, minimal implementation, passing test, commit. Each task should produce a single commit unless a fix-up is genuinely needed (then a follow-up commit, never `--amend`).
- **No rule disables.** Do not loosen ormolu / hlint output to make a check pass. If hlint fires on legitimate idiomatic code, ask before changing.
- **No hidden helpers.** New functions should be exported from their module's export list. The service test file (white-box) reaches into `Application.Services.AuthService` deliberately.
- **Backwards compatibility.** `OAuthUserInfo` gains a field. All construction sites in the codebase must be updated; the compiler will tell you which.

---

## Phase A — `OAuthUserInfo.emailVerified` (parser layer)

### Task 1 — Plumb `email_verified` from Google's userinfo

**Files:**
- Modify: `src/Infrastructure/Auth/OAuth.hs`
- Create: `test/Infrastructure/Auth/OAuthSpec.hs`

**Step 1.1: Write the failing tests for the Google parser.**

Create `test/Infrastructure/Auth/OAuthSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Auth.OAuthSpec (spec) where

import qualified Data.ByteString.Lazy.Char8 as LBS
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (OAuthUserInfo (..), parseUserInfo)
import Test.Hspec

spec :: Spec
spec = describe "parseUserInfo (Google)" $ do
  it "sets emailVerified=True when Google returns email_verified=true" $ do
    let body =
          LBS.pack
            "{\"id\":\"g-1\",\"email\":\"alice@example.com\",\"email_verified\":true,\"name\":\"Alice\"}"
    case parseUserInfo Google body of
      Just info -> do
        info.subject `shouldBe` "g-1"
        info.email `shouldBe` Just "alice@example.com"
        info.emailVerified `shouldBe` True
      Nothing -> expectationFailure "expected Just"

  it "sets emailVerified=False when Google returns email_verified=false" $ do
    let body =
          LBS.pack
            "{\"id\":\"g-2\",\"email\":\"bob@example.com\",\"email_verified\":false}"
    case parseUserInfo Google body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"

  it "defaults emailVerified=False when Google omits the email_verified claim" $ do
    -- Older Google responses or non-OIDC variants may omit the claim entirely.
    let body =
          LBS.pack
            "{\"id\":\"g-3\",\"email\":\"carol@example.com\"}"
    case parseUserInfo Google body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"

  it "defaults emailVerified=False for the GitHub parser" $ do
    -- GitHub's basic /user endpoint doesn't return email_verified.
    let body = LBS.pack "{\"id\":42,\"email\":\"dan@example.com\",\"login\":\"dan\"}"
    case parseUserInfo GitHub body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"

  it "defaults emailVerified=False for the Microsoft parser" $ do
    let body =
          LBS.pack
            "{\"id\":\"ms-1\",\"mail\":\"eve@example.com\",\"displayName\":\"Eve\"}"
    case parseUserInfo Microsoft body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"
```

> **Note:** the test imports `parseUserInfo` from `Infrastructure.Auth.OAuth`. That function is currently NOT in the module's export list — it is internal. Step 1.4 below adds it to the export list so the test can drive it directly.

> `OverloadedRecordDot` and `OverloadedStrings` are already on by `default-extensions` in `package.yaml`, so the test file doesn't need its own pragmas for them.

- [ ] **Step 1.2: Run tests — expect failure.**

```bash
just test
```

Expected: a compile error because `OAuthUserInfo` has no `emailVerified` field, OR a runtime test failure if the type already exists with a default. Most likely a compile error blocking the spec.

- [ ] **Step 1.3: Add `emailVerified` to `OAuthUserInfo` and update parsers.**

Edit `src/Infrastructure/Auth/OAuth.hs`:

1. Add `parseUserInfo` to the export list:

```haskell
module Infrastructure.Auth.OAuth
  ( -- * Configuration
    OAuthConfig (..),
    OAuthProviderConfig (..),

    -- * OAuth Flow
    getAuthorizationUrl,
    handleOAuthCallback,

    -- * User Info
    OAuthUserInfo (..),
    parseUserInfo,                 -- <-- add

    -- * Default Configs
    defaultGoogleConfig,
    defaultGitHubConfig,
    defaultMicrosoftConfig,

    -- * Errors
    OAuthError (..),

    -- * State Management
    generateOAuthState,
    validateOAuthState,
  )
```

2. Add `emailVerified` field to the record:

```haskell
data OAuthUserInfo = OAuthUserInfo
  { -- | User's unique ID from the provider
    subject :: Text,
    -- | User's email (may be Nothing if not provided)
    email :: Maybe Text,
    -- | Whether the provider asserts the email has been verified.
    -- For Google this is the OIDC `email_verified` claim; for providers
    -- that don't expose verification, defaults to False (do not auto-link).
    emailVerified :: Bool,
    -- | User's display name
    name :: Maybe Text,
    -- | URL to user's profile picture
    picture :: Maybe Text
  }
  deriving (Show, Eq, Generic)
```

3. Update `parseGoogleUserInfo` to read `email_verified`:

```haskell
parseGoogleUserInfo :: LBS.ByteString -> Maybe OAuthUserInfo
parseGoogleUserInfo body = do
  obj <- Aeson.decode body
  case obj of
    Aeson.Object v -> do
      subjectValue <- Aeson.lookup "id" v
      subjectVal <- case subjectValue of
        Aeson.String s -> Just s
        _ -> Nothing
      let emailVal = case Aeson.lookup "email" v of
            Just (Aeson.String e) -> Just e
            _ -> Nothing
          emailVerifiedVal = case Aeson.lookup "email_verified" v of
            Just (Aeson.Bool b) -> b
            _ -> False
          nameVal = case Aeson.lookup "name" v of
            Just (Aeson.String n) -> Just n
            _ -> Nothing
          pictureVal = case Aeson.lookup "picture" v of
            Just (Aeson.String p) -> Just p
            _ -> Nothing
      return
        OAuthUserInfo
          { subject = subjectVal,
            email = emailVal,
            emailVerified = emailVerifiedVal,
            name = nameVal,
            picture = pictureVal
          }
    _ -> Nothing
```

4. Update `parseGitHubUserInfo` to set `emailVerified = False`:

```haskell
      return
        OAuthUserInfo
          { subject = subjectVal,
            email = emailVal,
            emailVerified = False,
            name = nameVal,
            picture = pictureVal
          }
```

5. Update `parseMicrosoftUserInfo` similarly to set `emailVerified = False`.

6. Any other call sites that construct an `OAuthUserInfo` (search the codebase: `rg "OAuthUserInfo *\{"` from the backend root) must add the field. There should be only the three parsers.

- [ ] **Step 1.4: Run tests — expect pass.**

```bash
just test
```

Expected: `parseUserInfo (Google)` block reports 3 + 2 = 5 examples passing; the rest of the suite stays green (full count grew from prior baseline by +5).

- [ ] **Step 1.5: Run quality gates.**

```bash
just check    # ormolu + hlint
```

All clean.

- [ ] **Step 1.6: Commit.**

```bash
git add src/Infrastructure/Auth/OAuth.hs test/Infrastructure/Auth/OAuthSpec.hs
git commit -m "feat(auth): plumb email_verified into OAuthUserInfo (Google parser)"
```

---

## Phase B — Service-layer refactor (no behaviour change)

### Task 2 — Extract `linkOrSignInWithOAuth` from `handleOAuthCallback`

**Files:**
- Modify: `src/Application/Services/AuthService.hs`

This task is a pure refactor: move the decision logic out of the HTTP-touching wrapper and into a function that takes `OAuthUserInfo` directly. **No behaviour change.** Adding tests in this task is intentionally deferred to Task 3 — the new function will be tested as part of the auto-link branch implementation.

- [ ] **Step 2.1: Read the existing `handleOAuthCallback` for context.**

Re-read `src/Application/Services/AuthService.hs` lines 234-271 (the `handleOAuthCallback` body). The block we're extracting is everything *after* the OAuth HTTP call returns — i.e., from the `let oauthIdentity = …` on.

- [ ] **Step 2.2: Add `linkOrSignInWithOAuth` to the export list.**

```haskell
module Application.Services.AuthService
  ( -- * Result Types
    AuthResult (..),
    OAuthRedirectResult (..),

    -- * Service Functions
    register,
    login,
    initiateOAuth,
    handleOAuthCallback,
    linkOrSignInWithOAuth,        -- <-- add (white-box for tests)
    linkOAuth,
    authenticateTelegram,
    linkTelegram,
    refreshToken,
    findOrCreateTelegramBotUser,

    -- * Helpers re-exported for AuthAPI types
    parseOAuthProvider,
  )
```

- [ ] **Step 2.3: Replace `handleOAuthCallback` with a thin wrapper, and add `linkOrSignInWithOAuth`.**

Find the existing `handleOAuthCallback` (around line 240-271). Replace it with:

```haskell
-- | Handle OAuth callback after provider redirect.
--
-- Orchestrates:
--   1. Exchange code for user info (HTTP — Infrastructure.Auth.OAuth)
--   2. Delegate the find-or-create logic to 'linkOrSignInWithOAuth'.
handleOAuthCallback ::
  OAuthProvider ->
  Text ->
  Text ->
  AppM (Either DomainError AuthResult)
handleOAuthCallback provider code state = runExceptT $ do
  lift $ logInfo $ "Processing OAuth callback for provider: " <> displayShow provider
  oauthConfig <- lift (view oauthConfigL)
  result <- lift (OAuth.handleOAuthCallback oauthConfig provider code state state)
  userInfo <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "OAuth callback error: " <> displayShow err
      throwE (AccountError "OAuth authentication failed")
  ExceptT (linkOrSignInWithOAuth provider userInfo)

-- | Find-or-create a user from an already-resolved 'OAuth.OAuthUserInfo'.
--
-- Decision tree (see docs/specs/2026-04-28-oauth-auto-link-by-email-design.md §6):
--   - If a user already has this @(provider, subject)@ identity → sign in as that user.
--   - Otherwise (auto-link branch implemented in Task 3):
--       - if the provider didn't return an email → ValidationErr.
--       - else create a new user via OAuth.
--
-- Exported for white-box tests in @Application.Services.AuthServiceSpec@.
linkOrSignInWithOAuth ::
  OAuthProvider ->
  OAuth.OAuthUserInfo ->
  AppM (Either DomainError AuthResult)
linkOrSignInWithOAuth provider userInfo = runExceptT $ do
  let oauthIdentity =
        OAuthIdentity
          { provider = provider,
            subject = userInfo.subject
          }
  userReadModel <- lift (view userReadModelL)
  maybeUser <- lift (getUserByOAuthIdentity userReadModel provider userInfo.subject)
  case maybeUser of
    Just (uid, user) -> do
      lift $ logInfo "Existing user found via OAuth"
      ExceptT (generateAuthResult uid user.email)
    Nothing -> do
      lift $ logInfo "Creating new user via OAuth"
      case userInfo.email of
        Just email -> ExceptT (createUserViaOAuth email oauthIdentity)
        Nothing -> do
          lift $ logError "OAuth provider did not return email"
          throwE (ValidationErr (mkValidationError "email" "OAuth provider did not return email address" ""))
```

> The body of `linkOrSignInWithOAuth` is identical to the original tail of `handleOAuthCallback` from `let oauthIdentity = …` onward. No behaviour change.

- [ ] **Step 2.4: Build and run the existing test suite.**

```bash
just test
```

Expected: same count as after Task 1, all green. The refactor doesn't change behaviour.

- [ ] **Step 2.5: Quality gates.**

```bash
just check
```

All clean. **Stop and report if hlint fires** — the refactor was supposed to be neutral; any new warning is suspicious.

- [ ] **Step 2.6: Commit.**

```bash
git add src/Application/Services/AuthService.hs
git commit -m "refactor(auth): extract linkOrSignInWithOAuth from handleOAuthCallback"
```

---

## Phase C — Auto-link branch (TDD)

### Task 3 — Auto-link by verified email in `linkOrSignInWithOAuth`

**Files:**
- Modify: `src/Application/Services/AuthService.hs`
- Create: `test/Application/Services/AuthServiceSpec.hs`

This is the heart of the change. Add the auto-link branch and 5 unit tests covering the spec's behaviour matrix (§6).

- [ ] **Step 3.1: Write the failing test file.**

Create `test/Application/Services/AuthServiceSpec.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AuthServiceSpec
-- Description : Unit tests for AuthService — OAuth callback decision tree.
--
-- Drives 'linkOrSignInWithOAuth' directly with handcrafted 'OAuthUserInfo'
-- values, bypassing the HTTP layer in 'Infrastructure.Auth.OAuth'.
module Application.Services.AuthServiceSpec (spec) where

import Application.ReadModels.User (getUserByOAuthIdentity)
import Application.Services.AuthService (AuthResult (..), linkOrSignInWithOAuth)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (OAuthProvider (..))
import qualified Infrastructure.Auth.OAuth as OAuth
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test data
-- -----------------------------------------------------------------------------

-- | A baseline OAuth userinfo with the verified-email signal set. Tests override
-- specific fields with record update syntax.
mkUserInfo :: Text -> Text -> Bool -> OAuth.OAuthUserInfo
mkUserInfo subj email verified =
  OAuth.OAuthUserInfo
    { OAuth.subject = subj,
      OAuth.email = Just email,
      OAuth.emailVerified = verified,
      OAuth.name = Nothing,
      OAuth.picture = Nothing
    }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "linkOrSignInWithOAuth" $ do
  it "auto-links a verified Google email to the existing email/password user" $ do
    env <- createTestAppEnv
    existingUid <- registerUser env "alice@example.com"

    let userInfo = mkUserInfo "google-subject-1" "alice@example.com" True
    res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
    case res of
      Right auth -> auth.userId `shouldBe` existingUid
      Left err -> expectationFailure $ "expected Right, got Left: " <> show err

    -- The OAuth identity is now attached to the existing user.
    linked <- getUserByOAuthIdentity env.userReadModel Google "google-subject-1"
    case linked of
      Just (uid, _) -> uid `shouldBe` existingUid
      Nothing -> expectationFailure "expected the OAuth identity to be linked to the existing user"

  it "creates a new user when email is unverified, even if it matches an existing user" $ do
    env <- createTestAppEnv
    existingUid <- registerUser env "bob@example.com"

    let userInfo = mkUserInfo "google-subject-2" "bob@example.com" False
    res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
    case res of
      Right auth -> auth.userId `shouldNotBe` existingUid
      Left err -> expectationFailure $ "expected Right, got Left: " <> show err

  it "creates a new user when no pre-existing user has this email" $ do
    env <- createTestAppEnv

    let userInfo = mkUserInfo "google-subject-3" "fresh@example.com" True
    res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
    case res of
      Right _ -> pure () -- new user, any userId
      Left err -> expectationFailure $ "expected Right, got Left: " <> show err

    -- The new user is now reachable via the OAuth identity.
    linked <- getUserByOAuthIdentity env.userReadModel Google "google-subject-3"
    case linked of
      Just _ -> pure ()
      Nothing -> expectationFailure "expected the new user to be reachable via OAuth identity"

  it "signs in the same user on a repeat OAuth callback (no extra link emitted)" $ do
    env <- createTestAppEnv

    let userInfo = mkUserInfo "google-subject-4" "diana@example.com" True
    res1 <- runAppM env $ linkOrSignInWithOAuth Google userInfo
    res2 <- runAppM env $ linkOrSignInWithOAuth Google userInfo
    case (res1, res2) of
      (Right a1, Right a2) -> a1.userId `shouldBe` a2.userId
      _ -> expectationFailure $ "expected both Right, got: " <> show (res1, res2)

  it "rejects with ValidationErr when the OAuth provider returns no email" $ do
    env <- createTestAppEnv

    let userInfo = (mkUserInfo "google-subject-5" "ignored" True) {OAuth.email = Nothing}
    res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
    case res of
      Left (ValidationErr _) -> pure ()
      Left err -> expectationFailure $ "expected ValidationErr, got: " <> show err
      Right _ -> expectationFailure "expected Left ValidationErr"
```

- [ ] **Step 3.2: Run tests — expect failure on the auto-link case.**

```bash
just test
```

Expected: 4 of 5 new tests pass (current behaviour already covers no-pre-existing-user, repeat-sign-in, no-email, and unverified-but-no-existing-user). The "auto-links a verified Google email to the existing email/password user" test fails — currently a new user is created instead of linking.

If MORE than 1 test fails, stop and investigate before changing the implementation.

- [ ] **Step 3.3: Add `emailExists` and update the `linkOrSignInWithOAuth` decision tree.**

Edit `src/Application/Services/AuthService.hs`. Locate `linkOrSignInWithOAuth` (added in Task 2). Replace its body with the auto-link-aware version:

```haskell
linkOrSignInWithOAuth ::
  OAuthProvider ->
  OAuth.OAuthUserInfo ->
  AppM (Either DomainError AuthResult)
linkOrSignInWithOAuth provider userInfo = runExceptT $ do
  let oauthIdentity =
        OAuthIdentity
          { provider = provider,
            subject = userInfo.subject
          }
  userReadModel <- lift (view userReadModelL)
  maybeUser <- lift (getUserByOAuthIdentity userReadModel provider userInfo.subject)
  case maybeUser of
    Just (uid, user) -> do
      lift $ logInfo "Existing user found via OAuth"
      ExceptT (generateAuthResult uid user.email)
    Nothing -> case (userInfo.email, userInfo.emailVerified) of
      (Nothing, _) -> do
        lift $ logError "OAuth provider did not return email"
        throwE
          (ValidationErr
             (mkValidationError "email" "OAuth provider did not return email address" ""))
      (Just email, False) -> do
        lift $ logInfo "OAuth email not verified — creating new user without auto-link"
        ExceptT (createUserViaOAuth email oauthIdentity)
      (Just email, True) -> do
        maybeByEmail <- lift (getUserByEmail userReadModel email)
        case maybeByEmail of
          Just (uid, user) -> do
            lift $ logInfo "Auto-linking verified OAuth email to existing user"
            runUserCmd id (unUserId uid)
              (LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity})
            ExceptT (generateAuthResult uid user.email)
          Nothing -> do
            lift $ logInfo "Creating new user via OAuth (no existing email match)"
            ExceptT (createUserViaOAuth email oauthIdentity)
```

The two new branches:
- `(Just email, False)` — same as the old "create new" path.
- `(Just email, True)` — looks up by email; if found, links and signs in; otherwise creates new.

> **Why `runUserCmd id (unUserId uid)` and not a separate service call?** Reuses the same command machinery `linkOAuth` uses. The existing aggregate invariants (refuse-double-link, etc.) apply automatically.

- [ ] **Step 3.4: Run tests — expect pass.**

```bash
just test
```

All 5 tests in the new spec should pass; the rest of the suite stays green.

- [ ] **Step 3.5: Quality gates.**

```bash
just check
```

All clean.

- [ ] **Step 3.6: Commit.**

```bash
git add src/Application/Services/AuthService.hs test/Application/Services/AuthServiceSpec.hs
git commit -m "feat(auth): auto-link OAuth by verified email in linkOrSignInWithOAuth"
```

---

## Phase D — Wrap-up

### Task 4 — Final verification

- [ ] **Step 4.1: Full clean build + tests.**

```bash
just rebuild         # ormolu + hpack + cabal build
just test            # full suite including the new specs
```

All green. Note the new test count compared to baseline (should be +5 from `OAuthSpec` and +5 from `AuthServiceSpec`).

- [ ] **Step 4.2: Manual smoke against a fresh local backend (optional but recommended).**

```bash
just db-reset && just db-up && just run
```

In another terminal:

1. Register an email/password user:
   ```bash
   curl -s -X POST http://localhost:8080/api/auth/register \
     -H 'content-type: application/json' \
     -d '{"email":"smoke@example.com","password":"longenough"}' | jq .
   ```

2. The full real-Google end-to-end smoke is impractical from a script (it needs a real Google account + OAuth client). Document this as: ✅ unit tests cover the decision tree; manual smoke happens via the web client once `feat/web-mvp` is merged.

- [ ] **Step 4.3: Push branch and open PR.**

```bash
git push -u origin feat/oauth-auto-link
gh pr create --base master --head feat/oauth-auto-link \
  --title "feat(auth): auto-link OAuth by verified email" \
  --body "$(cat <<EOF
## Summary
- Plumbs the OIDC \`email_verified\` claim from Google's userinfo response into our \`OAuthUserInfo\` record.
- Extracts the OAuth-callback decision tree from \`handleOAuthCallback\` into \`linkOrSignInWithOAuth\` so it's testable without HTTP.
- Adds the auto-link branch: when \`(provider, subject)\` is unknown and the verified email matches an existing user, attach the OAuth identity to that user instead of creating a duplicate.

## Test plan
- [x] \`just test\` — full suite green; +10 new examples (5 parser, 5 service).
- [x] \`just check\` — ormolu + hlint clean.
- [x] Auto-link, unverified-email, no-pre-existing-user, repeat-sign-in, no-email-returned all covered as service-layer specs.
- [ ] End-to-end smoke happens via the web client (see homeaccounting/web#1 §5.4).

## Reference
\`docs/specs/2026-04-28-oauth-auto-link-by-email-design.md\` (web spec cross-reference: \`web/docs/specs/2026-04-28-web-mvp-design.md\` §5.4)
EOF
)"
```

---

## Done criteria

A user who:

1. Registers with email + password (`alice@example.com`).
2. Later signs in with Google whose verified `email_verified=true` claim returns the same email.

…is recognised as the **same** user (same `userId`), and the OAuth identity is attached to that user. New OAuth users with unmatched emails still create new accounts. Unverified emails never trigger auto-link.

`just test` passes (full suite + 10 new examples), `just check` passes, no lint disables added, behaviour for already-linked OAuth identities is preserved.
