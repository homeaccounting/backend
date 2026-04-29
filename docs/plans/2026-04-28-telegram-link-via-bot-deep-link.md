---
status: draft
date: 2026-04-28
spec: docs/specs/2026-04-28-telegram-link-via-bot-deep-link-design.md
branch: feat/telegram-link-via-bot-deep-link
---

# Telegram Link via Bot Deep-Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the duplicate-creating Telegram authentication flow with a server-issued single-use link code redeemed via the bot's `/start LINK_<token>` deep-link, so an existing email/OAuth user can attach their Telegram identity without ever exposing email or any other identifier in plaintext. Remove the unused web-side Telegram widget surfaces.

**Architecture:** A new in-memory `LinkCodeStore` (TVar of `HashMap LinkCodeToken (UserId, UTCTime)`) holds short-lived (10 min) cryptographically-random tokens issued by an authenticated `POST /auth/telegram/link-code` endpoint. The bot's `/start LINK_<token>` handler atomically redeems the token and dispatches the existing `LinkTelegramAccount` aggregate command on the resolved user. `/start` with no payload no longer creates users — it now prompts the user to either link via the web app or run `/signup`. The widget endpoints (`POST /auth/telegram` and `POST /auth/link-telegram`) and their helpers are deleted.

**Tech Stack:** Haskell 9.10.3, RIO, Servant, hspec + hspec-discover, QuickCheck, Eventium in-memory event store, ormolu + hlint via `just check`.

**Branch:** `feat/telegram-link-via-bot-deep-link` (create at start of Task 1, off `master`).

**Design reference:** `docs/specs/2026-04-28-telegram-link-via-bot-deep-link-design.md`. Read sections §1–§7 before starting. The spec is authoritative; if the plan and spec disagree, flag it — do not silently diverge.

---

## File Map

Files created:

- `src/Application/LinkCodeStore.hs` — opaque `LinkCodeStore`, `LinkCodeToken`, and the `issue` / `redeem` / `purgeExpired` operations. STM-internal, IO-facing API.
- `test/Application/LinkCodeStoreSpec.hs` — unit tests (issue replaces, redeem is single-use, expiry, concurrent redeem).
- `test/Application/LinkCodeStorePropertySpec.hs` — QuickCheck properties (per-user uniqueness, redeem idempotency-by-deletion).

Files modified:

- `src/Infrastructure/App.hs`
  - Add `linkCodeStore :: !LinkCodeStore` field to `AppEnv`.
  - Add and implement a `HasLinkCodeStore env` capability class with `linkCodeStoreL :: Lens' env LinkCodeStore`.
  - Update `initializeAppEnv` signature to accept and store the new value.
- `app/Main.hs`
  - Construct `LinkCodeStore` via `newLinkCodeStore` at startup, pass into `initializeAppEnv`.
- `src/Application/Services/AuthService.hs`
  - Add `issueTelegramLinkCode :: UserId -> AppM (Either DomainError TelegramLinkCodeResult)`.
  - Add `redeemTelegramLinkCode :: LinkCodeToken -> TelegramIdentity -> AppM (Either DomainError UserId)`.
  - Export both, plus the new `TelegramLinkCodeResult` data type.
  - Delete `authenticateTelegram` and `linkTelegram` (the widget-driven function — its responsibility moves to `redeemTelegramLinkCode`).
- `src/Web/API/AuthAPI.hs`
  - Add the `POST /api/auth/telegram/link-code` route (auth required) plus its handler, request DTO (empty body), and response DTO `TelegramLinkCodeResponse { deepLink, expiresAt }`.
  - Remove the `POST /api/auth/telegram` and `POST /api/auth/link-telegram` routes, their handlers, the `TelegramAuthRequest` and `LinkTelegramRequest` DTOs, and the `toTelegramAuthData` helper.
- `src/Telegram/Commands.hs`
  - Rewrite `handleStart` decision tree per spec §1.
  - Add `handleSignup` for the explicit-create path (wraps existing `findOrCreateTelegramBotUser`).
  - Wire `/signup` into the command dispatcher next to `/start`.
- `src/Infrastructure/Auth/Telegram.hs`
  - Delete `authenticateViaTelegram`, `TelegramAuthData`, `TelegramAuthError`, `computeTelegramHash`. Module remains for `TelegramConfig` and any future bot-side helpers; export list shrinks accordingly.
- `test/Infrastructure/Auth/TelegramSpec.hs` — delete (HMAC widget verification tests for removed code).
- `test/Application/Services/AuthServiceSpec.hs` — extend with white-box tests for the new functions; delete tests covering the removed `authenticateTelegram` / `linkTelegram` (if any).
- `test/Web/API/AuthAPIIntegrationSpec.hs` — extend with integration tests for the new endpoint and 404 regression guards for the removed routes.
- `test/Telegram/CommandsSpec.hs` — extend with `/start` decision-tree tests and a `/signup` happy-path test.
- `docs/architecture.md` — small edit to the auth section reflecting the change.

No changes to `package.yaml` / `backend.cabal`: `hspec-discover` auto-finds new `*Spec.hs` under `test/`. `LinkCodeStore` uses already-vendored libs (`stm`, `unordered-containers`, `bytestring`, `memory`, `cryptonite` — verify; if `cryptonite` is not already a dep, prefer `entropy` which is).

`TelegramConfig.botUsername` already exists in `src/Infrastructure/Auth/Telegram.hs` (`:81`) — **no config-file change required**. Verify the local/test/prod YAMLs pass it through (existing tests already exercise this).

---

## Conventions

- **Branch & commits.** All work lands on `feat/telegram-link-via-bot-deep-link`. Commits follow Conventional Commits.
- **TDD.** Failing test first, minimal implementation, passing test, commit. Each task should produce a single commit unless a fix-up is genuinely needed (then a follow-up commit, never `--amend`).
- **Push per task.** Push to origin after each task's commit so the PR — once opened — stays current. (Per the user's recorded workflow preference.)
- **`-Werror` in CI.** Project builds with `cabal build -fci -Werror`. `just build` does not pass `-fci` but the test suite does — run `cabal test --enable-tests` (or `just test`) before committing.
- **No rule disables.** Do not loosen ormolu / hlint output to make a check pass. If hlint fires on legitimate idiomatic code, ask before changing.
- **Memory recall:** event payloads have no timestamp fields (envelope handles it). Multi-line logging logic should be lifted into named helpers, not inlined.
- **Don't pre-emptively touch unrelated code.** Microsoft OAuth is *not* in scope for this plan even though it lives in adjacent files.

---

## Phase A — `LinkCodeStore` infrastructure

### Task 1 — Create `LinkCodeStore` module with failing unit tests

**Files:**
- Create: `src/Application/LinkCodeStore.hs`
- Create: `test/Application/LinkCodeStoreSpec.hs`

**Goal:** A self-contained module with deterministic, well-tested `issue` / `redeem` / `purgeExpired` semantics. No `AppM`, no `AppEnv` dependency yet.

- [ ] **Step 1.1: Create the branch.**

```bash
git checkout master
git pull --ff-only
git checkout -b feat/telegram-link-via-bot-deep-link
```

- [ ] **Step 1.2: Write the failing unit tests.**

Create `test/Application/LinkCodeStoreSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Application.LinkCodeStoreSpec (spec) where

import Application.LinkCodeStore
  ( LinkCodeStore,
    LinkCodeToken,
    issueAt,
    newLinkCodeStore,
    redeemAt,
  )
import Control.Concurrent.Async (mapConcurrently)
import qualified Data.UUID.V4 as UUID
import Data.Time (UTCTime, addUTCTime)
import qualified Data.Time as Time
import Domain.Core.Types (mkUserId)
import RIO
import qualified RIO.List as L
import Test.Hspec

aUserId :: IO _
aUserId = do
  u <- UUID.nextRandom
  case mkUserId u of
    Right uid -> pure uid
    Left e -> fail (show e)

ttl :: Time.NominalDiffTime
ttl = 600 -- 10 min

spec :: Spec
spec = describe "Application.LinkCodeStore" $ do
  it "issue stores a token redeemable to the issuing user" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _exp) <- issueAt store uid ttl now
    redeemed <- redeemAt store tok now
    redeemed `shouldBe` Just uid

  it "issue replaces a prior code for the same user (only the latest is redeemable)" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tokOld, _) <- issueAt store uid ttl now
    (tokNew, _) <- issueAt store uid ttl now
    -- Old token gone:
    redeemAt store tokOld now `shouldReturn` Nothing
    -- New token works:
    redeemAt store tokNew now `shouldReturn` Just uid

  it "redeem is single-use" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    redeemAt store tok now `shouldReturn` Just uid
    redeemAt store tok now `shouldReturn` Nothing

  it "redeem returns Nothing for an expired token" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    let later = addUTCTime (ttl + 1) now
    redeemAt store tok later `shouldReturn` Nothing

  it "redeem returns Nothing for an unknown token" $ do
    store <- newLinkCodeStore
    now <- Time.getCurrentTime
    -- Construct a token that was never issued via the only public path:
    -- issue one, redeem it, then try again.
    uid <- aUserId
    (tok, _) <- issueAt store uid ttl now
    _ <- redeemAt store tok now
    redeemAt store tok now `shouldReturn` Nothing

  it "concurrent redeem of the same token: exactly one wins" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    results <- mapConcurrently (const (redeemAt store tok now)) [(1 :: Int) .. 32]
    length (L.filter (== Just uid) results) `shouldBe` 1
    length (L.filter (== Nothing) results) `shouldBe` 31
```

Note: tests drive a clock-injecting variant (`issueAt`, `redeemAt`). The IO-facing wrappers (`issue`, `redeem`) read `getCurrentTime` and call into these. This avoids `threadDelay` flakiness for the expiry test.

- [ ] **Step 1.3: Run tests, see them fail.**

```bash
just test 2>&1 | head -40
```

Expected: compile failure, `Application.LinkCodeStore` module not found.

- [ ] **Step 1.4: Implement `LinkCodeStore`.**

Create `src/Application/LinkCodeStore.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.LinkCodeStore
-- Description : In-memory store for short-lived, single-use Telegram link codes.
--
-- Tokens are 32-byte cryptographically-random values base64url-encoded to
-- ~43 ASCII characters. The store is a single 'TVar' over a 'HashMap'; all
-- mutations are STM transactions so concurrent redeems can never both
-- succeed.
--
-- Issuing replaces any prior active code for the same user (one active code
-- per user). Redeeming atomically reads, expiry-checks, and deletes.
module Application.LinkCodeStore
  ( -- * Types
    LinkCodeStore,
    LinkCodeToken,
    unLinkCodeToken,

    -- * Lifecycle
    newLinkCodeStore,

    -- * Operations (IO, real clock)
    issue,
    redeem,
    purgeExpired,

    -- * Operations (clock-injecting; for tests)
    issueAt,
    redeemAt,
    purgeExpiredAt,
  )
where

import qualified Data.ByteArray.Encoding as BA
import qualified Data.ByteString as BS
import Data.Hashable (Hashable)
import qualified Data.HashMap.Strict as HM
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Domain.Core.Types (UserId)
import qualified RIO.Text as T
import RIO
import qualified System.Entropy as Entropy

-- | An opaque, URL-safe random link code token.
newtype LinkCodeToken = LinkCodeToken {unLinkCodeToken :: Text}
  deriving (Eq, Show, Generic)

instance Hashable LinkCodeToken

-- | In-memory store of pending link codes, keyed by token.
newtype LinkCodeStore = LinkCodeStore
  { unStore :: TVar (HM.HashMap LinkCodeToken Entry)
  }

data Entry = Entry
  { entryUserId :: !UserId,
    entryExpiresAt :: !UTCTime
  }
  deriving (Show)

-- -----------------------------------------------------------------------------
-- Lifecycle
-- -----------------------------------------------------------------------------

newLinkCodeStore :: IO LinkCodeStore
newLinkCodeStore = LinkCodeStore <$> newTVarIO HM.empty

-- -----------------------------------------------------------------------------
-- IO API (real clock)
-- -----------------------------------------------------------------------------

issue :: LinkCodeStore -> UserId -> NominalDiffTime -> IO (LinkCodeToken, UTCTime)
issue store uid ttl = do
  now <- getCurrentTime
  issueAt store uid ttl now

redeem :: LinkCodeStore -> LinkCodeToken -> IO (Maybe UserId)
redeem store tok = do
  now <- getCurrentTime
  redeemAt store tok now

purgeExpired :: LinkCodeStore -> IO ()
purgeExpired store = do
  now <- getCurrentTime
  purgeExpiredAt store now

-- -----------------------------------------------------------------------------
-- Clock-injecting API (deterministic; tests)
-- -----------------------------------------------------------------------------

issueAt :: LinkCodeStore -> UserId -> NominalDiffTime -> UTCTime -> IO (LinkCodeToken, UTCTime)
issueAt store uid ttl now = do
  purgeExpiredAt store now
  raw <- Entropy.getEntropy 32
  let token = LinkCodeToken (decodeUtf8Lenient (BA.convertToBase BA.Base64URLUnpadded raw))
      expiresAt = addUTCTime ttl now
  atomically $ modifyTVar' (unStore store) $ \m ->
    let cleared = HM.filter (\e -> entryUserId e /= uid) m
     in HM.insert token (Entry uid expiresAt) cleared
  pure (token, expiresAt)

redeemAt :: LinkCodeStore -> LinkCodeToken -> UTCTime -> IO (Maybe UserId)
redeemAt store tok now = atomically $ do
  m <- readTVar (unStore store)
  case HM.lookup tok m of
    Nothing -> pure Nothing
    Just e
      | entryExpiresAt e <= now -> do
          writeTVar (unStore store) (HM.delete tok m)
          pure Nothing
      | otherwise -> do
          writeTVar (unStore store) (HM.delete tok m)
          pure (Just (entryUserId e))

purgeExpiredAt :: LinkCodeStore -> UTCTime -> IO ()
purgeExpiredAt store now =
  atomically $ modifyTVar' (unStore store) $
    HM.filter (\e -> entryExpiresAt e > now)
```

If `System.Entropy` is not already a dep, add `entropy` to `package.yaml` (`dependencies:`) and re-run `hpack`. Verify with `cabal build` before continuing.

- [ ] **Step 1.5: Run the tests, see them pass.**

```bash
just test 2>&1 | tail -30
```

Expected: green for `Application.LinkCodeStore` spec.

- [ ] **Step 1.6: `just check` and commit.**

```bash
just check
git add src/Application/LinkCodeStore.hs test/Application/LinkCodeStoreSpec.hs package.yaml backend.cabal
git commit -m "feat(auth): add in-memory LinkCodeStore for Telegram link codes"
git push -u origin feat/telegram-link-via-bot-deep-link
```

(`package.yaml` / `backend.cabal` only included if you needed to add `entropy`.)

### Task 2 — QuickCheck properties for `LinkCodeStore`

**Files:**
- Create: `test/Application/LinkCodeStorePropertySpec.hs`

- [ ] **Step 2.1: Write the property tests.**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Application.LinkCodeStorePropertySpec (spec) where

import Application.LinkCodeStore
import qualified Data.UUID.V4 as UUID
import qualified Data.Time as Time
import Domain.Core.Types (UserId, mkUserId)
import RIO
import qualified RIO.List as L
import qualified RIO.Set as Set
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, run)

genUserId :: IO UserId
genUserId = do
  u <- UUID.nextRandom
  case mkUserId u of
    Right uid -> pure uid
    Left e -> fail (show e)

spec :: Spec
spec = describe "LinkCodeStore properties" $ do
  it "issuing for N distinct users yields N distinct active tokens" $
    property $ \(Positive (Small n)) ->
      n <= 50 ==> monadicIO $ do
        store <- run newLinkCodeStore
        now <- run Time.getCurrentTime
        toks <- run $ replicateM n $ do
          uid <- genUserId
          fst <$> issueAt store uid 600 now
        assert (length (Set.fromList toks) == n)

  it "redeem is observationally equivalent to redeem >> redeem (idempotent by deletion)" $
    property $ monadicIO $ do
      store <- run newLinkCodeStore
      now <- run Time.getCurrentTime
      uid <- run genUserId
      (tok, _) <- run $ issueAt store uid 600 now
      r1 <- run $ redeemAt store tok now
      r2 <- run $ redeemAt store tok now
      r3 <- run $ redeemAt store tok now
      assert (r1 == Just uid && r2 == Nothing && r3 == Nothing)
```

- [ ] **Step 2.2: Run, see pass.**

```bash
just test 2>&1 | tail -30
```

- [ ] **Step 2.3: Commit and push.**

```bash
just check
git add test/Application/LinkCodeStorePropertySpec.hs
git commit -m "test(auth): property tests for LinkCodeStore"
git push
```

---

## Phase B — Wire `LinkCodeStore` into `AppEnv`

### Task 3 — Add `linkCodeStore` to `AppEnv` + capability class

**Files:**
- Modify: `src/Infrastructure/App.hs`
- Modify: `app/Main.hs`
- Modify: `test/Testkit/Helpers.hs` (or wherever `mkTestAppEnv` lives — locate at start of step 3.1)

- [ ] **Step 3.1: Locate the test environment factory.**

```bash
grep -rn "initializeAppEnv\|mkTestAppEnv\|AppEnv{" /Users/oleksandrsy/Projects/Self/HomeAccounting/backend/test --include="*.hs" | head
```

Note the exact callers — every one must be updated when `initializeAppEnv` gains a parameter.

- [ ] **Step 3.2: Modify `src/Infrastructure/App.hs`.**

Add to imports:

```haskell
import Application.LinkCodeStore (LinkCodeStore)
```

Add a field to `AppEnv` (alongside the existing read-model fields, around `:188`):

```haskell
linkCodeStore :: !LinkCodeStore,
```

Add a parameter to `initializeAppEnv` in the order matching the field list (mirror the existing prologue at `:267`). Set it on the constructed record.

Add a capability class near the existing `HasReadModel` / `HasAuthConfig` definitions:

```haskell
class HasLinkCodeStore env where
  linkCodeStoreL :: Lens' env LinkCodeStore

instance HasLinkCodeStore AppEnv where
  linkCodeStoreL = lens (.linkCodeStore) (\x y -> x {linkCodeStore = y})
```

Export `HasLinkCodeStore (..)` from the module's export list.

- [ ] **Step 3.3: Modify `app/Main.hs`.**

Import `Application.LinkCodeStore (newLinkCodeStore)`. In the composition root, just before calling `initializeAppEnv`:

```haskell
linkCodeStore <- newLinkCodeStore
```

Pass `linkCodeStore` into `initializeAppEnv` at the new positional slot.

- [ ] **Step 3.4: Update test factory.**

Whichever module constructs the test `AppEnv`, add the same `newLinkCodeStore` step and pass it into the constructor. Build to confirm.

- [ ] **Step 3.5: Build and test.**

```bash
just build
just test
```

Expected: all green. No new test logic yet — this task is plumbing.

- [ ] **Step 3.6: Commit and push.**

```bash
just check
git add src/Infrastructure/App.hs app/Main.hs test/
git commit -m "chore(app): wire LinkCodeStore into AppEnv"
git push
```

---

## Phase C — `AuthService.issueTelegramLinkCode`

### Task 4 — Issue link code, return deep-link

**Files:**
- Modify: `src/Application/Services/AuthService.hs`
- Modify: `test/Application/Services/AuthServiceSpec.hs`

- [ ] **Step 4.1: Write the failing service test.**

In `test/Application/Services/AuthServiceSpec.hs`, add a new `describe` block:

```haskell
describe "issueTelegramLinkCode" $ do
  it "returns a deep-link of the form https://t.me/<botUsername>?start=LINK_<token>" $ do
    -- Arrange: bring up an in-memory env, register a user, capture their UserId.
    -- (Mirror the setup pattern used by the existing OAuth tests.)
    env <- mkTestEnv
    let runApp = runRIO env
    Right authResult <- runApp (register "alice@example.com" "hunter2hunter2")
    let uid = authResult.userId
    -- Act:
    Right res <- runApp (issueTelegramLinkCode uid)
    -- Assert: link starts with the expected prefix.
    res.deepLink `shouldSatisfy` ("https://t.me/" `T.isPrefixOf`)
    -- Token round-trips through the store:
    let token = extractTokenFromDeepLink res.deepLink
    redeemed <- redeemAt env.linkCodeStore token =<< Time.getCurrentTime
    redeemed `shouldBe` Just uid

  it "replaces a prior code for the same user" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    Right authResult <- runApp (register "bob@example.com" "hunter2hunter2")
    let uid = authResult.userId
    Right firstRes <- runApp (issueTelegramLinkCode uid)
    Right _secondRes <- runApp (issueTelegramLinkCode uid)
    let firstTok = extractTokenFromDeepLink firstRes.deepLink
    redeemAt env.linkCodeStore firstTok =<< Time.getCurrentTime
      `shouldReturn` Nothing
```

`extractTokenFromDeepLink` is a tiny test helper: split on `start=LINK_` and `LinkCodeToken` the suffix.

- [ ] **Step 4.2: See it fail with "function not in scope".**

```bash
just test 2>&1 | head -40
```

- [ ] **Step 4.3: Implement `issueTelegramLinkCode`.**

In `src/Application/Services/AuthService.hs`:

```haskell
data TelegramLinkCodeResult = TelegramLinkCodeResult
  { deepLink :: Text,
    expiresAt :: UTCTime
  }

-- | Issue a single-use deep-link the user can open in Telegram to attach
-- their Telegram identity to their existing account.
--
-- Replaces any prior active code for the same user. The 10-minute TTL is
-- defined here, not in 'LinkCodeStore', because it is an authentication
-- policy decision rather than a storage detail.
issueTelegramLinkCode :: UserId -> AppM (Either DomainError TelegramLinkCodeResult)
issueTelegramLinkCode userId = runExceptT $ do
  lift $ logInfo "Issuing Telegram link code"
  store <- lift (view linkCodeStoreL)
  telegramConfig <- lift (view telegramConfigL)
  (tok, expiresAt) <- liftIO (LinkCodeStore.issue store userId linkCodeTtl)
  let deepLink =
        "https://t.me/"
          <> telegramConfig.botUsername
          <> "?start=LINK_"
          <> LinkCodeStore.unLinkCodeToken tok
  pure TelegramLinkCodeResult {deepLink, expiresAt}

linkCodeTtl :: NominalDiffTime
linkCodeTtl = 600 -- 10 minutes
```

Add to imports:

```haskell
import qualified Application.LinkCodeStore as LinkCodeStore
import Data.Time (NominalDiffTime, UTCTime)
import Infrastructure.App (HasLinkCodeStore (..))
```

Export `issueTelegramLinkCode` and `TelegramLinkCodeResult (..)` from the module.

- [ ] **Step 4.4: Run tests, see pass.**

```bash
just test
```

- [ ] **Step 4.5: Commit and push.**

```bash
just check
git add src/Application/Services/AuthService.hs test/Application/Services/AuthServiceSpec.hs
git commit -m "feat(auth): add issueTelegramLinkCode service function"
git push
```

---

## Phase D — `AuthService.redeemTelegramLinkCode`

### Task 5 — Redeem link code and run `LinkTelegramAccount`

**Files:**
- Modify: `src/Application/Services/AuthService.hs`
- Modify: `test/Application/Services/AuthServiceSpec.hs`

- [ ] **Step 5.1: Write the failing service tests.**

```haskell
describe "redeemTelegramLinkCode" $ do
  let aTgIdent =
        TelegramIdentity
          { id = unsafeTelegramId 4242,
            username = Just "alice_tg",
            firstName = "Alice"
          }

  it "happy path: links Telegram identity to the issued user and emits TelegramAccountLinked" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    Right auth <- runApp (register "alice@example.com" "hunter2hunter2")
    Right res <- runApp (issueTelegramLinkCode auth.userId)
    let tok = extractTokenFromDeepLink res.deepLink
    runApp (redeemTelegramLinkCode tok aTgIdent) `shouldReturn` Right auth.userId
    -- Verify event store side effect:
    events <- loadUserEvents env (unUserId auth.userId)
    events `shouldSatisfy` any isTelegramAccountLinked

  it "rejects when the token is unknown" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    let bogus = LinkCodeToken "not-a-real-token"
    runApp (redeemTelegramLinkCode bogus aTgIdent)
      `shouldSatisfy` isLeftWith (NotFound "telegram-link-code" _)

  it "rejects when the token has been consumed" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    Right auth <- runApp (register "alice@example.com" "hunter2hunter2")
    Right res <- runApp (issueTelegramLinkCode auth.userId)
    let tok = extractTokenFromDeepLink res.deepLink
    _ <- runApp (redeemTelegramLinkCode tok aTgIdent)
    runApp (redeemTelegramLinkCode tok aTgIdent)
      `shouldSatisfy` isLeftWith (NotFound "telegram-link-code" _)

  it "rejects when this Telegram ID is already linked to a different user" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    Right authA <- runApp (register "alice@example.com" "hunter2hunter2")
    Right authB <- runApp (register "bob@example.com"   "hunter2hunter2")
    -- Pre-bind aTgIdent to user A by issuing+redeeming for them.
    Right resA <- runApp (issueTelegramLinkCode authA.userId)
    let tokA = extractTokenFromDeepLink resA.deepLink
    _ <- runApp (redeemTelegramLinkCode tokA aTgIdent)
    -- Now user B issues a code and tries to redeem with the same Telegram ID.
    Right resB <- runApp (issueTelegramLinkCode authB.userId)
    let tokB = extractTokenFromDeepLink resB.deepLink
    runApp (redeemTelegramLinkCode tokB aTgIdent)
      `shouldSatisfy` isLeftWith
        (AccountError "Telegram account already linked to another user")

  it "rejects when the target user already has a different Telegram linked" $ do
    -- Aggregate-level invariant via existing LinkTelegramAccount handler.
    env <- mkTestEnv
    let runApp = runRIO env
    Right auth <- runApp (register "alice@example.com" "hunter2hunter2")
    let firstTg = aTgIdent
        secondTg = aTgIdent {id = unsafeTelegramId 9999}
    -- Link first.
    Right res1 <- runApp (issueTelegramLinkCode auth.userId)
    _ <- runApp (redeemTelegramLinkCode (extractTokenFromDeepLink res1.deepLink) firstTg)
    -- Try to link second.
    Right res2 <- runApp (issueTelegramLinkCode auth.userId)
    runApp (redeemTelegramLinkCode (extractTokenFromDeepLink res2.deepLink) secondTg)
      `shouldSatisfy` isLeft
```

`isLeftWith`, `unsafeTelegramId`, `loadUserEvents`, `isTelegramAccountLinked` come from `Testkit.Helpers` and the existing test scaffolding; if they don't exist with these exact names, fold inline pattern matching into each test.

- [ ] **Step 5.2: See them fail.**

- [ ] **Step 5.3: Implement `redeemTelegramLinkCode`.**

```haskell
redeemTelegramLinkCode ::
  LinkCodeStore.LinkCodeToken ->
  TelegramIdentity ->
  AppM (Either DomainError UserId)
redeemTelegramLinkCode tok tgIdent = runExceptT $ do
  lift $ logInfo "Processing Telegram link-code redemption"
  store <- lift (view linkCodeStoreL)
  maybeUid <- liftIO (LinkCodeStore.redeem store tok)
  uid <- case maybeUid of
    Nothing -> do
      lift $ logInfo "Telegram link code not found / expired / consumed"
      throwE (NotFound "telegram-link-code" "")
    Just u -> pure u
  -- Cross-user collision: the Telegram ID is already attached elsewhere.
  userReadModel <- lift (view userReadModelL)
  maybeExisting <- lift (getUserByTelegramId userReadModel tgIdent.id)
  guardE
    (isNothing maybeExisting)
    (AccountError "Telegram account already linked to another user")
  -- Aggregate-level invariant (target user has no other Telegram linked) is
  -- enforced inside LinkTelegramAccount's handler.
  runUserCmd
    id
    (unUserId uid)
    (LinkTelegramAccountUserCommand LinkTelegramAccount {identity = tgIdent})
  lift $ logInfo "Telegram identity linked via redemption"
  pure uid
```

Export `redeemTelegramLinkCode` from `Application.Services.AuthService`.

- [ ] **Step 5.4: Run, see pass.**

- [ ] **Step 5.5: Commit and push.**

```bash
just check
git add src/Application/Services/AuthService.hs test/Application/Services/AuthServiceSpec.hs
git commit -m "feat(auth): add redeemTelegramLinkCode service function"
git push
```

---

## Phase E — `POST /auth/telegram/link-code` HTTP route

### Task 6 — Expose `issueTelegramLinkCode` over HTTP

**Files:**
- Modify: `src/Web/API/AuthAPI.hs`
- Modify: `test/Web/API/AuthAPIIntegrationSpec.hs`

- [ ] **Step 6.1: Write the failing integration test.**

In `test/Web/API/AuthAPIIntegrationSpec.hs`, append:

```haskell
describe "POST /api/auth/telegram/link-code" $ do
  it "returns 401 when called without a JWT" $ do
    withTestApp $ \app -> do
      resp <- post app "/api/auth/telegram/link-code" emptyBody
      resp.status `shouldBe` status401

  it "returns a deep-link redeemable in the bot for the authenticated user" $ do
    withTestApp $ \app env -> do
      Right auth <- registerViaApp app "alice@example.com" "hunter2hunter2"
      resp <- postWithJwt app auth.token "/api/auth/telegram/link-code" emptyBody
      resp.status `shouldBe` status200
      body <- decodeBody @TelegramLinkCodeResponse resp
      body.deepLink `shouldSatisfy` ("https://t.me/" `T.isPrefixOf`)
      let token = extractTokenFromDeepLink body.deepLink
      -- Round-trip through the live store:
      redeemed <- redeemAt env.linkCodeStore token =<< Time.getCurrentTime
      redeemed `shouldBe` Just auth.userId
```

If the existing integration spec uses a different scaffolding pattern (`hspec-wai` etc.), match it; the assertions are what matter.

- [ ] **Step 6.2: See it fail.**

- [ ] **Step 6.3: Add the route, DTO, and handler.**

In `Web.API.AuthAPI`:

Add the response DTO next to the other auth response types:

```haskell
data TelegramLinkCodeResponse = TelegramLinkCodeResponse
  { deepLink :: Text,
    expiresAt :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramLinkCodeResponse
instance FromJSON TelegramLinkCodeResponse
```

Add the route to the API type, in the auth block, after `link-oauth`:

```haskell
:<|> AuthProtect "jwt"
  :> "api"
  :> "auth"
  :> "telegram"
  :> "link-code"
  :> Post '[JSON] TelegramLinkCodeResponse
```

Add the handler:

```haskell
handleIssueTelegramLinkCode :: AuthenticatedUser -> AppM TelegramLinkCodeResponse
handleIssueTelegramLinkCode user = do
  result <- AuthService.issueTelegramLinkCode user.userId
  case result of
    Left err -> throwM (toServerError err)
    Right res -> pure
      TelegramLinkCodeResponse
        { deepLink = res.deepLink,
          expiresAt = res.expiresAt
        }
```

Wire the handler into the API server in the same place as the other auth handlers (just below `handleLinkOAuth`).

- [ ] **Step 6.4: Run, see pass.**

- [ ] **Step 6.5: Commit and push.**

```bash
just check
git add src/Web/API/AuthAPI.hs test/Web/API/AuthAPIIntegrationSpec.hs
git commit -m "feat(auth): add POST /api/auth/telegram/link-code endpoint"
git push
```

---

## Phase F — Bot `/start LINK_<token>` redeem branch

### Task 7 — Recognise and consume `LINK_<token>` payload in `/start`

**Files:**
- Modify: `src/Telegram/Commands.hs`
- Modify: `test/Telegram/CommandsSpec.hs`

- [ ] **Step 7.1: Write the failing bot tests.**

```haskell
describe "handleStart" $ do
  it "/start LINK_<valid> redeems the code and replies with success" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    Right auth <- runApp (register "alice@example.com" "hunter2hunter2")
    Right res <- runApp (issueTelegramLinkCode auth.userId)
    let tok = stripLinkPrefix (extractFromDeepLink res.deepLink)
    msgs <- captureSentMessages env $ runApp $
      handleStart botState aliceTgIdent chatId (Just ("LINK_" <> tok))
    msgs `shouldSatisfy` containsText "linked"

  it "/start LINK_<garbage> replies with the unknown-token wording" $ do
    env <- mkTestEnv
    let runApp = runRIO env
    msgs <- captureSentMessages env $ runApp $
      handleStart botState aliceTgIdent chatId (Just "LINK_not-a-real-token")
    msgs `shouldSatisfy` containsText "no longer valid"
```

`captureSentMessages` is whatever spy/recorder the existing bot tests use. If none exists, follow the pattern in `test/Telegram/CommandsSpec.hs` for asserting on outgoing messages.

- [ ] **Step 7.2: Implement the LINK_ branch.**

Replace the body of `handleStart` (`src/Telegram/Commands.hs:225`):

```haskell
handleStart :: TVar BotState -> TelegramIdentity -> Int64 -> Maybe Text -> AppM ()
handleStart _botState tgIdentity chatId args = do
  case stripLinkPrefix args of
    Just tok -> do
      result <- redeemTelegramLinkCode (LinkCodeToken tok) tgIdentity
      case result of
        Right _uid ->
          sendMsg chatId
            "Done — this Telegram is now linked to your account. Send /help to get started."
        Left _err -> do
          sendMsg chatId
            "That link is no longer valid. Generate a new one in the web app under \"Link Telegram\"."
          sendUnknownUserPrompt chatId
    Nothing -> do
      -- Existing-user vs. unknown-user split — implemented in Task 8.
      handleStartNoPayload tgIdentity chatId

stripLinkPrefix :: Maybe Text -> Maybe Text
stripLinkPrefix = (>>= T.stripPrefix "LINK_")

-- Stub for now; final wording lands in Task 8.
sendUnknownUserPrompt :: Int64 -> AppM ()
sendUnknownUserPrompt chatId =
  sendMsg chatId
    "I don't recognise this Telegram account. Open the web app to link it, or send /signup to create a new account."

handleStartNoPayload :: TelegramIdentity -> Int64 -> AppM ()
handleStartNoPayload tgIdentity chatId = do
  -- Temporary: in this task we still defer to the old behaviour so the test
  -- focuses on the LINK_ branch. Task 8 replaces this with the spec §1 logic.
  result <- findOrCreateTelegramBotUser tgIdentity
  case result of
    Left err -> do
      logError $ "Failed to register Telegram user: " <> displayShow err
      sendMsg chatId "Failed to create your account. Please try again later."
    Right (_uid, _isNew) -> sendMsg chatId "Welcome."
```

Imports: `Application.LinkCodeStore (LinkCodeToken (..))`, `Application.Services.AuthService (redeemTelegramLinkCode)`.

- [ ] **Step 7.3: Run, see pass.**

- [ ] **Step 7.4: Commit and push.**

```bash
just check
git add src/Telegram/Commands.hs test/Telegram/CommandsSpec.hs
git commit -m "feat(telegram-bot): handle /start LINK_<token> redemption"
git push
```

---

## Phase G — Bot `/start` no-payload behaviour + `/signup`

### Task 8 — Block-and-prompt unknown users; route `/signup` to create

**Files:**
- Modify: `src/Telegram/Commands.hs`
- Modify: `test/Telegram/CommandsSpec.hs`

- [ ] **Step 8.1: Write the failing tests.**

```haskell
it "/start (no payload) from an unknown Telegram ID does NOT create a user" $ do
  env <- mkTestEnv
  let runApp = runRIO env
  msgs <- captureSentMessages env $ runApp $
    handleStart botState newTgIdent chatId Nothing
  msgs `shouldSatisfy` containsText "I don't recognise"
  -- And no user was created:
  rm <- readTVarIO env.userReadModel
  getUserByTelegramId rm newTgIdent.id `shouldReturn` Nothing

it "/start (no payload) from an already-linked Telegram ID returns the welcome (regression)" $ do
  env <- mkTestEnv
  let runApp = runRIO env
  -- Set up: create a user with linked Telegram via /signup.
  runApp $ handleSignup botState aliceTgIdent chatId Nothing
  msgs <- captureSentMessages env $ runApp $
    handleStart botState aliceTgIdent chatId Nothing
  msgs `shouldSatisfy` containsText "Welcome back"

it "/signup from an unknown Telegram ID creates the user via findOrCreateTelegramBotUser" $ do
  env <- mkTestEnv
  let runApp = runRIO env
  msgs <- captureSentMessages env $ runApp $
    handleSignup botState newTgIdent chatId Nothing
  msgs `shouldSatisfy` containsText "account has been created"
  rm <- readTVarIO env.userReadModel
  result <- getUserByTelegramId rm newTgIdent.id
  result `shouldSatisfy` isJust

it "/signup from an already-linked Telegram ID is idempotent (welcome, no error)" $ do
  env <- mkTestEnv
  let runApp = runRIO env
  runApp $ handleSignup botState aliceTgIdent chatId Nothing
  msgs <- captureSentMessages env $ runApp $
    handleSignup botState aliceTgIdent chatId Nothing
  msgs `shouldSatisfy` containsText "Welcome back"
```

- [ ] **Step 8.2: Implement the spec §1 decision tree and `/signup`.**

```haskell
handleStartNoPayload :: TelegramIdentity -> Int64 -> AppM ()
handleStartNoPayload tgIdentity chatId = do
  rm <- view userReadModelL
  existing <- getUserByTelegramId rm tgIdentity.id
  case existing of
    Just _ -> sendWelcome True chatId
    Nothing -> sendUnknownUserPrompt chatId

handleSignup :: TVar BotState -> TelegramIdentity -> Int64 -> Maybe Text -> AppM ()
handleSignup _botState tgIdentity chatId _args = do
  result <- findOrCreateTelegramBotUser tgIdentity
  case result of
    Left err -> do
      logError $ "Telegram /signup failed: " <> displayShow err
      sendMsg chatId "Failed to create your account. Please try again later."
    Right (_uid, isNew) -> sendWelcome isNew chatId

sendWelcome :: Bool -> Int64 -> AppM ()
sendWelcome isNew chatId =
  sendMsg chatId $
    T.unlines $
      [ if isNew
          then "Welcome to HomeAccounting Bot!\n\nYour account has been created successfully."
          else "Welcome back to HomeAccounting Bot!",
        "",
        "Available commands:"
      ]
        ++ formatCommandList
```

Wire `/signup` into the dispatcher next to `/start`. In the dispatch table around `:117–:130`:

```haskell
"/signup" -> handleSignup botState tgIdentity chatId args
```

- [ ] **Step 8.3: Run, see pass.**

- [ ] **Step 8.4: Commit and push.**

```bash
just check
git add src/Telegram/Commands.hs test/Telegram/CommandsSpec.hs
git commit -m "feat(telegram-bot): block-and-prompt unknown users on /start; add /signup"
git push
```

---

## Phase H — Removal of widget surfaces

### Task 9 — Delete `POST /api/auth/telegram` and `POST /api/auth/link-telegram`

**Files:**
- Modify: `src/Web/API/AuthAPI.hs`
- Modify: `src/Application/Services/AuthService.hs`
- Modify: `src/Infrastructure/Auth/Telegram.hs`
- Modify: `test/Web/API/AuthAPIIntegrationSpec.hs`
- Delete: `test/Infrastructure/Auth/TelegramSpec.hs` (HMAC widget verification tests)

- [ ] **Step 9.1: Write the regression-guard test first.**

```haskell
describe "removed widget endpoints" $ do
  it "POST /api/auth/telegram returns 404" $
    withTestApp $ \app -> do
      resp <- post app "/api/auth/telegram" emptyJsonObject
      resp.status `shouldBe` status404
  it "POST /api/auth/link-telegram returns 404 (with JWT)" $
    withTestApp $ \app -> do
      Right auth <- registerViaApp app "alice@example.com" "hunter2hunter2"
      resp <- postWithJwt app auth.token "/api/auth/link-telegram" emptyJsonObject
      resp.status `shouldBe` status404
```

- [ ] **Step 9.2: Run, see one pass and one fail (the link-telegram one passes immediately if Servant returns 404 for a missing route; otherwise both fail until removal).**

- [ ] **Step 9.3: Remove the widget routes and DTOs from `Web.API.AuthAPI`.**

Delete:
- `POST /api/auth/telegram` route from the API type and its handler.
- `POST /api/auth/link-telegram` route and handler.
- `TelegramAuthRequest` and `LinkTelegramRequest` data types.
- `toTelegramAuthData` helper.
- The doc comment lines at `:23` and `:24` referring to these endpoints.

Adjust the server hookup (`:<|>` chain) so the remaining endpoints stay correctly composed.

- [ ] **Step 9.4: Remove the widget service functions from `AuthService`.**

Delete `authenticateTelegram` and `linkTelegram` and their imports of `TelegramAuth.{authenticateViaTelegram, TelegramAuthData}`. Trim the export list.

- [ ] **Step 9.5: Remove the HMAC widget verification from `Infrastructure.Auth.Telegram`.**

Delete:
- `authenticateViaTelegram`
- `TelegramAuthData`
- `TelegramAuthError`
- `computeTelegramHash`

Keep `TelegramConfig` and `defaultTelegramConfig` — used by the bot. Trim the export list. If the module's only remaining responsibility is `TelegramConfig`, this is acceptable; do not collapse it into another module in this plan (out of scope).

- [ ] **Step 9.6: Delete `test/Infrastructure/Auth/TelegramSpec.hs`.**

Plus any test fixtures that exist solely to construct `TelegramAuthData`.

- [ ] **Step 9.7: Build and run all tests.**

```bash
just build
just test
```

Expected: green. The 404 regression guards now pass; nothing else regresses.

- [ ] **Step 9.8: Commit and push.**

```bash
just check
git add -A
git commit -m "refactor(auth)!: remove Telegram login widget endpoints

The bot deep-link flow (POST /api/auth/telegram/link-code +
/start LINK_<token>) replaces both sign-in via the widget and link via
the widget. Widget surfaces had the same duplicate-account trap as the
old bot /start flow and are not used by the maintained frontend.

BREAKING CHANGE: POST /api/auth/telegram and POST /api/auth/link-telegram
now return 404."
git push
```

---

## Phase I — Documentation

### Task 10 — Update `docs/architecture.md`

**Files:**
- Modify: `docs/architecture.md`

- [ ] **Step 10.1: Locate the auth section.**

```bash
grep -n "Telegram\|OAuth\|Authentication" /Users/oleksandrsy/Projects/Self/HomeAccounting/backend/docs/architecture.md | head
```

- [ ] **Step 10.2: Update the auth subsection.**

- Note that Telegram identities are attached only via the bot's `/start LINK_<token>` flow.
- Note the new `Application.LinkCodeStore` component (transient, in-memory, not event-sourced) and the rationale (spec §Storage).
- Remove any reference to the deleted widget endpoints.

- [ ] **Step 10.3: Commit and push.**

```bash
git add docs/architecture.md
git commit -m "docs(architecture): document Telegram bot link-code flow"
git push
```

---

## Verification

After Task 10, run from the repo root:

```bash
just check
just test
cabal build -fci
```

All three must succeed. Then open a PR titled `feat(auth)!: telegram link via bot deep-link` against `master`.

---

## Open Risks / Notes

- The `TelegramConfig.botUsername` value flows through to a user-visible URL. Misconfiguration produces a non-resolving deep-link. Consider a startup-time sanity check (non-empty + matches `[A-Za-z0-9_]{5,32}`) — out of scope for this plan; flag if it becomes a real issue.
- `Infrastructure.Auth.Telegram` shrinks substantially after Task 9. If the module becomes effectively empty (only `TelegramConfig`), follow-up cleanup may relocate it next to other config types — explicitly **not** in this plan.
- No data migration is needed: the link code is transient, and the existing `TelegramAccountLinked` event semantics are unchanged.
