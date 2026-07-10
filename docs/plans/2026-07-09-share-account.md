# Share an Account — Backend Enablement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two read-side pieces the web account-sharing UI needs: expose the requesting user's `role` on account reads, and a new owner-only `GET /api/accounts/:id/access` endpoint listing who has access.

**Architecture:** Both changes are additive and read-only. The RBAC write path (`POST …/share`, `DELETE …/access/:userId`) already exists and is unchanged. Role data already flows from `ReadModel.getAccessibleAccounts` (a `[(AccountId, AccountData, AccountRole)]`) but is discarded in `listAccountsForUser`; we thread it through instead. The access list is built from `AccountData.accessList` (already fetched) joined against the user read model for display labels (email / Telegram username).

**Tech Stack:** Haskell, GHC 9.10.3, RIO prelude (NoImplicitPrelude), Servant, Aeson (Generic instances), Persistent (SqlPersistT), hspec + Network.Wai.Test. Build `-fci` (=`-Werror`). Enter `nix develop` first.

**Spec:** `../monorepo/docs/specs/2026-07-09-share-account-design.md` (web repo). Tracker: homeaccounting/tracker#29.

**Conventions verified in this repo:**
- Build: `just build` (`cabal build all -fci`). Test: `just test` (`cabal test all -fci --test-show-details=direct --enable-tests`). Format: `just format` (ormolu). Lint: `just lint` (hlint).
- Response types: plain `deriving Generic` + standalone empty `instance ToJSON X` / `instance FromJSON X`; record field names map 1:1 to JSON keys. Aeson default **omits** `Nothing` fields.
- `AccountRole` (`src/Domain/Core/Types.hs:992`) = `Owner | Editor | Viewer`; its Generic `ToJSON` renders **capitalized** ("Owner"). The web wants lowercase; we add a `roleToText` helper. The reverse already exists: `parseRole` (`src/Application/Services/AccountService.hs:261`).
- Tests: `test/Web/API/AccountAPISpec.hs`; hspec-discover root `test/Spec.hs`. Fixtures in `test/Testkit/` (`registerUser`, `createDefaultAccount`, `mintToken`, `authHeaders`, `httpRequest`).

---

## File Structure

**Backend (server-infra):**
- Modify: `src/Domain/Core/Types.hs` — add `roleToText :: AccountRole -> Text` (near `AccountRole`).
- Modify: `src/Web/Types.hs` — add `role` field to `AccountResponse` (`:267`); update `fromAccountData` (`:926`) to accept a role.
- Modify: `src/Application/Services/AccountService.hs` — `listAccountsForUser` keeps the role; add `getAccountAccessList` service function for B2.
- Modify: `src/Web/API/AccountAPI.hs` — update 3 `fromAccountData` call sites; add `AccountAccessEntry` / `AccountAccessListResponse` types, the `GET …/:id/access` route, and `getAccountAccessHandler`.
- Test: `test/Web/API/AccountAPISpec.hs` — add role-on-list and access-list endpoint specs.
- Test (unit): `test/Domain/Core/TypesSpec.hs` (create if absent) — `roleToText` cases.

---

## Task 1: `roleToText` helper (lowercase role rendering)

**Files:**
- Modify: `src/Domain/Core/Types.hs` (near the `AccountRole` decl, `:992-1000`; add to module export list)
- Test: `test/Domain/Core/TypesSpec.hs`

- [ ] **Step 1: Write the failing test**

Create/append `test/Domain/Core/TypesSpec.hs`:

```haskell
module Domain.Core.TypesSpec (spec) where

import RIO
import Test.Hspec
import Domain.Core.Types (AccountRole (..), roleToText)

spec :: Spec
spec = describe "roleToText" $ do
  it "renders Owner as lowercase owner"   $ roleToText Owner  `shouldBe` ("owner" :: Text)
  it "renders Editor as lowercase editor" $ roleToText Editor `shouldBe` ("editor" :: Text)
  it "renders Viewer as lowercase viewer" $ roleToText Viewer `shouldBe` ("viewer" :: Text)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c just test 2>&1 | grep -i "roleToText\|not in scope\|error"`
Expected: FAIL — `roleToText` not in scope (compile error).

- [ ] **Step 3: Implement `roleToText`**

In `src/Domain/Core/Types.hs`, add to the export list (alongside `AccountRole (..)`):

```haskell
    roleToText,
```

And near the `AccountRole` definition:

```haskell
-- | Render an 'AccountRole' as the lowercase wire token used by the HTTP API
-- ("owner"/"editor"/"viewer"). Inverse of 'Application.Services.AccountService.parseRole'.
roleToText :: AccountRole -> Text
roleToText Owner = "owner"
roleToText Editor = "editor"
roleToText Viewer = "viewer"
```

- [ ] **Step 4: Register the spec (if the file is new)**

`test/Spec.hs` uses hspec-discover (auto-collects `*Spec.hs`); no manual registration needed. Verify the file matches the `*Spec.hs` glob and exports `spec :: Spec`.

- [ ] **Step 5: Run test to verify it passes**

Run: `nix develop -c just test 2>&1 | grep -iA2 "roleToText"`
Expected: 3 examples, 0 failures for the `roleToText` describe block.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Core/Types.hs test/Domain/Core/TypesSpec.hs
git commit -m "feat(accounts): add roleToText helper for lowercase role wire tokens (tracker#29)"
```

---

## Task 2: Surface `role` on account reads (B1)

Adding a **required** field to `AccountResponse` is a compile-driven change touching `fromAccountData` and its 3 call sites. Do it as one coherent change, guarded by an endpoint test proving the list now carries the role.

**Files:**
- Modify: `src/Web/Types.hs:267` (`AccountResponse`), `:926` (`fromAccountData`)
- Modify: `src/Application/Services/AccountService.hs:157` (`listAccountsForUser`)
- Modify: `src/Web/API/AccountAPI.hs:277,285,293` (call sites)
- Test: `test/Web/API/AccountAPISpec.hs`

- [ ] **Step 1: Write the failing endpoint test**

In `test/Web/API/AccountAPISpec.hs`, add a spec asserting `GET /api/accounts` returns `role: "owner"` for the creator. Register it in the file's top-level `spec`/`main` list following the existing pattern (e.g. `it "includes role on listed accounts" listRoleSpec`). Body:

```haskell
listRoleSpec :: IO ()
listRoleSpec = do
  f <- mkFixture "list-role@test.com"
  resp <- httpRequest f.fApp "GET" "/api/accounts" (authHeaders f.fToken) ""
  simpleStatus resp `shouldBe` status200
  case eitherDecode (simpleBody resp) :: Either String AccountListResponse of
    Left err -> expectationFailure ("decode failed: " <> err)
    Right (AccountListResponse accs _) ->
      case accs of
        (a : _) -> a.role `shouldBe` ("owner" :: Text)
        []      -> expectationFailure "expected at least one account"
```

(Ensure `AccountListResponse` is imported in the spec's import list.)

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c just test 2>&1 | grep -i "role\|no field\|error"`
Expected: FAIL — `AccountResponse` has no field `role` (compile error). This confirms the field is missing.

- [ ] **Step 3: Add `role` to `AccountResponse`**

`src/Web/Types.hs`, in the `AccountResponse` record (`:267-282`) add after `status`:

```haskell
    status :: Text,
    role :: Text, -- current user's role: "owner"|"editor"|"viewer" (tracker#29)
    version :: Int
```

- [ ] **Step 4: Thread role into `fromAccountData`**

`src/Web/Types.hs:926` — change the signature to accept an `AccountRole` and set the field. Add `import Domain.Core.Types (AccountRole, roleToText)` (verified: `Web/Types.hs` currently imports neither — extend the existing `Domain.Core.Types` import list).

```haskell
fromAccountData :: AccountId -> AccountRole -> AccountData -> AccountResponse
fromAccountData accountId role AccountData {..} =
  AccountResponse
    { id = unAccountId accountId,
      name = name,
      balance = fromDomainMoney balance,
      currency = currencyToText (moneyCurrency balance),
      overdraftLimit = fmap fromDomainMoney overdraftLimit,
      subtype = case accountType of
        Regular at -> Just (fromAccountSubtype at)
        External -> Nothing,
      status = fromAccountStatus status,
      role = roleToText role,
      version = coerce version
    }
```

- [ ] **Step 5: Keep the role in `listAccountsForUser`**

`src/Application/Services/AccountService.hs:157` — change the return type and stop discarding role:

```haskell
listAccountsForUser :: UserId -> AppM [(AccountId, AccountRole, AccountData)]
listAccountsForUser userId = do
  logInfo $ "Listing accounts for user " <> displayShow userId
  accountsList <- runDb (ReadModel.getAccessibleAccounts userId)
  let result =
        [ (aid, role, account)
        | (aid, account, role) <- accountsList,
          account.accountType /= External
        ]
  logInfo $ "Found " <> displayShow (length result) <> " account(s)"
  return result
```

(Add `AccountRole` to the import from `Domain.Core.Types` if needed.)

- [ ] **Step 6: Update the 3 call sites in `AccountAPI.hs`**

- `listAccountsHandler` (`:293`): the tuple is now `(aid, role, account)`:
  ```haskell
  let responses = map (\(aid, role, account) -> fromAccountData aid role account) accountsList
  ```
- `createAccountHandler` (`:277`): the creator is Owner:
  ```haskell
  return $ fromAccountData accountId Owner account
  ```
- `getAccountHandler` (`:285`): resolve the requesting user's role from the account's access list (creator ⇒ Owner). Replace the handler body. **Inline the access-list lookup** — do NOT depend on `AuthorizationService.getUserRoleFromAccessList`, which is defined but **not exported** from that module (importing it fails to compile):
  ```haskell
  getAccountHandler :: AuthenticatedUser -> UUID -> AppM AccountResponse
  getAccountHandler user accountUuid = do
    result <- AccountService.getAccount accountUuid
    case result of
      Right (accountId, account) -> do
        let role =
              if account.createdBy == user.userId
                then Owner
                else maybe Viewer (.role) (find (\a -> a.userId == user.userId) account.accessList)
        return $ fromAccountData accountId role account
      Left err -> throwDomainError err
  ```
  Add imports: `Domain.Core.Types (AccountRole (..), AccountAccess (..))`. `find` comes from RIO's prelude (Data.Foldable) — no extra import. `.role` / `.userId` use OverloadedRecordDot on `AccountAccess`. (Note: the web never calls this endpoint — it derives single accounts from the list cache — so the `Viewer` fallback for a non-member is a harmless best-effort; single-GET authz is pre-existing behavior and out of scope.)

- [ ] **Step 7: Fix any hand-built `AccountResponse` in tests**

Search: `nix develop -c grep -rn "AccountResponse\b" test/ src/ | grep -v "fromAccountData\|:: AccountResponse\|AccountListResponse"` — any place constructing an `AccountResponse` record literal must add `role = "…"`. (Most tests decode from the app, so expect few or none.)

- [ ] **Step 8: Run the full suite**

Run: `nix develop -c just test 2>&1 | tail -20`
Expected: all green, including `includes role on listed accounts`.

- [ ] **Step 9: Format, lint, commit**

```bash
nix develop -c just format
nix develop -c just lint
git add -A
git commit -m "feat(accounts): expose current user's role on account reads (tracker#29)"
```

---

## Task 3: `GET /api/accounts/:id/access` — owner-only access list (B2)

**Files:**
- Modify: `src/Application/Services/AccountService.hs` — add `getAccountAccessList`
- Modify: `src/Web/API/AccountAPI.hs` — new response types, route, handler, exports
- Test: `test/Web/API/AccountAPISpec.hs`

### 3a — Response types

- [ ] **Step 1: Add the response types in `AccountAPI.hs`**

Near `ShareAccountRequest` (`:194`), add (match house Generic style; `Maybe` fields are omitted when `Nothing`, which the web treats as absent):

```haskell
-- | One entry in an account's access list (tracker#29).
data AccountAccessEntry = AccountAccessEntry
  { userId :: UUID,
    role :: Text, -- "owner"|"editor"|"viewer"
    email :: Maybe Text, -- display label; Nothing for users without an email (e.g. Telegram-only)
    telegramUsername :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountAccessEntry

instance FromJSON AccountAccessEntry

-- | Response for GET /api/accounts/:id/access.
data AccountAccessListResponse = AccountAccessListResponse
  { access :: [AccountAccessEntry]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountAccessListResponse

instance FromJSON AccountAccessListResponse
```

Add `AccountAccessEntry (..)` and `AccountAccessListResponse (..)` to the module export list (`:41-59`).

### 3b — Service function

- [ ] **Step 2: Write the service function `getAccountAccessList`**

In `src/Application/Services/AccountService.hs`, add (mirror the owner-guard idiom from `shareAccount` at `:193-195`; look up each member's display label via `ReadModel.getUser`):

```haskell
-- | Owner-only: list who has access to an account, with display labels.
-- Returns Left on missing account or non-owner requester (handler maps to 404).
getAccountAccessList ::
  UserId ->
  UUID ->
  AppM (Either DomainError [(UUID, AccountRole, Maybe Text, Maybe Text)])
getAccountAccessList requestingUserId accountUuid = runExceptT $ do
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  account <-
    liftMaybeM
      (NotFound "Account" (tshow accountUuid))
      (runDb (ReadModel.getAccount accountId))
  -- Hide existence from non-owners: return NotFound rather than a distinct 403.
  guardE (account.createdBy == requestingUserId) (NotFound "Account" (tshow accountUuid))
  forM account.accessList $ \(AccountAccess uid role) -> do
    mUser <- lift $ runDb (ReadModel.getUser uid)
    let email = mUser >>= (.email)
        tgUser = mUser >>= (.telegramIdentity) >>= (.username)
    pure (unUserId uid, role, email, tgUser)
```

Add imports as needed: `Domain.Core.Types (AccountAccess (..), AccountRole)`, `Application.ReadModels.User (getUser)` (aliased under `ReadModel` if that alias already covers it — otherwise import `qualified Application.ReadModels.User as UserRM` and use `UserRM.getUser`). Export `getAccountAccessList`.

> Note: read-model `UserData.email :: Maybe Text` (NULL for Telegram-only users) — no empty-string normalization needed. `telegramIdentity :: Maybe TelegramIdentity`, `username :: Maybe Text` → double-`>>=`.

### 3c — Route + handler

- [ ] **Step 3: Add the route to the `AccountAPI` type**

In `src/Web/API/AccountAPI.hs` `type AccountAPI` (`:108-187`), add a new alternative (place it immediately after the single-account GET so related routes are grouped; method/arity differs from the existing `access :> Capture "userId" :> Delete`, so no overlap):

```haskell
    -- GET /api/accounts/:id/access - List access (owner only) (tracker#29)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "access"
      :> Get '[JSON] AccountAccessListResponse
```

- [ ] **Step 4: Add the handler to `accountServer` in matching order**

`accountServer` (`:234-246`) must list handlers in the **same order** as the type. Insert `getAccountAccessHandler` right after `getAccountHandler`:

```haskell
accountServer =
  createAccountHandler
    :<|> getAccountHandler
    :<|> getAccountAccessHandler
    :<|> listAccountsHandler
    :<|> shareAccountHandler
    ...
```

Add the handler:

```haskell
getAccountAccessHandler :: AuthenticatedUser -> UUID -> AppM AccountAccessListResponse
getAccountAccessHandler user accountUuid = do
  result <- AccountService.getAccountAccessList user.userId accountUuid
  case result of
    Right entries ->
      return $
        AccountAccessListResponse
          [ AccountAccessEntry uid (roleToText role) email tg
          | (uid, role, email, tg) <- entries
          ]
    Left err -> throwDomainError err
```

Add imports: `Domain.Core.Types (roleToText)`.

### 3d — Tests

- [ ] **Step 5: Write failing endpoint tests**

In `test/Web/API/AccountAPISpec.hs`, add specs (register them in the file's `spec` list). Reuse `mkFixture`, `registerUser`, `mintToken`, `authHeaders`, `httpRequest`, and the `runAppM env $ shareAccount …` pattern (`:169-177`).

```haskell
accessListOwnerSpec :: IO ()
accessListOwnerSpec = do
  f <- mkFixture "acl-owner@test.com"
  -- share with a viewer
  viewerId <- registerUser f.fEnv "acl-viewer@test.com"
  _ <- runAppM f.fEnv $ shareAccount f.fUserId f.fAccountUuid (unUserId viewerId) "viewer"
  let path = encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString f.fAccountUuid) <> "/access"
  resp <- httpRequest f.fApp "GET" path (authHeaders f.fToken) ""
  simpleStatus resp `shouldBe` status200
  case eitherDecode (simpleBody resp) :: Either String AccountAccessListResponse of
    Left err -> expectationFailure ("decode failed: " <> err)
    Right (AccountAccessListResponse entries) -> do
      -- owner + viewer present
      length entries `shouldBe` 2
      any (\e -> e.role == ("owner" :: Text)) entries `shouldBe` True
      any (\e -> e.role == "viewer" && e.email == Just "acl-viewer@test.com") entries `shouldBe` True

accessListNonOwnerSpec :: IO ()
accessListNonOwnerSpec = do
  f <- mkFixture "acl-owner2@test.com"
  viewerId <- registerUser f.fEnv "acl-viewer2@test.com"
  _ <- runAppM f.fEnv $ shareAccount f.fUserId f.fAccountUuid (unUserId viewerId) "viewer"
  viewerTok <- mintToken viewerId "acl-viewer2@test.com"
  let path = encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString f.fAccountUuid) <> "/access"
  resp <- httpRequest f.fApp "GET" path (authHeaders viewerTok) ""
  simpleStatus resp `shouldBe` status404 -- hidden from non-owner
```

> Ensure `AccountAccessListResponse (..)` and `status404` are imported in the spec's import list.

- [ ] **Step 6: Run tests to verify they fail then pass**

Run (fail first, before 3a-3c are compiled in — if you wrote tests last, run after implementing): `nix develop -c just test 2>&1 | tail -30`
Expected: `access` specs pass; owner sees 2 entries incl. the viewer's email; non-owner gets 404.

- [ ] **Step 7: Format, lint, commit**

```bash
nix develop -c just format
nix develop -c just lint
git add -A
git commit -m "feat(accounts): owner-only GET /api/accounts/:id/access endpoint (tracker#29)"
```

---

## Task 4: Verify the full contract

- [ ] **Step 1: Run the whole suite + build**

Run: `nix develop -c just all` (or `just build && just test`)
Expected: green build (`-Werror`) and all specs pass.

- [ ] **Step 2: Manual smoke of the JSON shapes (optional)**

Boot the app (`just run` per repo README) and, with a JWT, confirm:
- `GET /api/accounts` items include `"role":"owner"`.
- `GET /api/accounts/:id/access` returns `{"access":[{"userId":…,"role":"owner",…}]}` and 404 for a non-owner token.

- [ ] **Step 3: Push branch & open backend PR**

```bash
git push -u origin HEAD
gh pr create --title "feat(accounts): sharing read endpoints — role + access list (tracker#29)" \
  --body "Backend enablement for tracker#29 web account-sharing. Adds role to account reads and an owner-only access-list endpoint. Spec: monorepo docs/specs/2026-07-09-share-account-design.md"
```

---

## Notes / Out of scope

- No new write endpoints (share/revoke already exist and are unchanged).
- No email→user lookup endpoint (web identifies targets by UUID from the profile page).
- Single-account `GET /:id` role is best-effort and not on any client's critical path.
