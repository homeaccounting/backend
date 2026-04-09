# Backend Versioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add version visibility to the backend — startup logging, unauthenticated `/api/info` endpoint, and Docker image version tagging.

**Architecture:** New `Infrastructure.Version` module holds `VersionInfo` (version from `Paths_backend`, commit from env var, environment from config). A `HasVersionInfo` lens on `AppEnv` exposes it. `Web.API.InfoAPI` serves `GET /api/info` outside the JWT-protected API tree. CI extracts the version from `package.yaml` for Docker tagging.

**Tech Stack:** Haskell (Servant, RIO, Aeson), Docker, GitHub Actions

**Spec:** `docs/specs/2026-04-09-backend-versioning-design.md`

---

### Task 1: Add `environment` field to config

**Files:**
- Modify: `src/Infrastructure/Config.hs`
- Modify: `config/local.yaml`
- Modify: `config/test.yaml`
- Modify: `config/prod.yaml`

- [ ] **Step 1: Add `Environment` type and field to `AppConfig`**

In `src/Infrastructure/Config.hs`, add after `ExchangeRateConfig`:

```haskell
-- | Application environment identifier.
data Environment
  = EnvLocal
  | EnvTest
  | EnvProd
  deriving (Show, Eq, Generic)

instance FromJSON Environment where
  parseJSON = withText "Environment" $ \t ->
    case T.toLower t of
      "local" -> pure EnvLocal
      "test" -> pure EnvTest
      "prod" -> pure EnvProd
      _ -> fail $ "Invalid environment: " <> T.unpack t

instance ToJSON Environment where
  toJSON EnvLocal = String "local"
  toJSON EnvTest = String "test"
  toJSON EnvProd = String "prod"
```

Add to `AppConfig`:

```haskell
data AppConfig = AppConfig
  { environment :: !Environment,  -- NEW
    server :: !ServerConfig,
    ...
  }
```

Update the `FromJSON AppConfig` instance to parse `environment` first:

```haskell
instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \v ->
    AppConfig
      <$> v .: "environment"
      <*> v .: "server"
      ...
```

Export `Environment(..)` from the module.

- [ ] **Step 2: Add `environment` to each YAML config**

`config/local.yaml` — add at line 1 (before `server:`):
```yaml
environment: local
```

`config/test.yaml` — add at line 3 (before `server:`):
```yaml
environment: test
```

`config/prod.yaml` — add at line 4 (before `server:`):
```yaml
environment: prod
```

- [ ] **Step 3: Add validation for environment field**

In `validateConfig`, no additional validation needed — `FromJSON` already rejects invalid values. But verify the existing config validation doesn't break.

- [ ] **Step 4: Build and verify**

Run: `just build`
Expected: Successful compilation

- [ ] **Step 5: Run tests**

Run: `just test`
Expected: All tests pass. `createTestAppEnv` will need the config update to parse; check that `test.yaml` is used correctly.

- [ ] **Step 6: Commit**

```bash
git add src/Infrastructure/Config.hs config/local.yaml config/test.yaml config/prod.yaml
git commit -m "feat: add environment field to AppConfig"
```

---

### Task 2: Create `Infrastructure.Version` module

**Files:**
- Create: `src/Infrastructure/Version.hs`

**Note:** The spec defines `VersionInfo` with three fields (version, commit, environment). This plan intentionally deviates: `environment` belongs in `AppConfig` (it's a config concern, not a version concern). `VersionInfo` holds only `appVersion` and `commit`. The handler reads environment from config. The spec should be updated to reflect this.

- [ ] **Step 1: Create `VersionInfo` type and `mkVersionInfo` constructor**

Create `src/Infrastructure/Version.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Version
-- Description : Application version information
module Infrastructure.Version
  ( VersionInfo (..),
    mkVersionInfo,
    displayVersion,
  )
where

import Data.Version (showVersion)
import Paths_backend (version)
import RIO
import qualified RIO.Text as T
import System.Environment (lookupEnv)

-- | Application version information.
--
-- Note: Constructor is exported for test convenience (creating test fixtures).
-- In production, use 'mkVersionInfo'.
data VersionInfo = VersionInfo
  { -- | Semantic version from package.yaml (e.g., "0.2.0")
    appVersion :: !Text,
    -- | Git commit hash (e.g., "abc123f"), "dev" if unset
    commit :: !Text
  }
  deriving (Show, Eq)

-- | Build VersionInfo by reading APP_COMMIT_HASH env var.
mkVersionInfo :: IO VersionInfo
mkVersionInfo = do
  commitHash <- lookupEnvDefault "APP_COMMIT_HASH" "dev"
  pure
    VersionInfo
      { appVersion = T.pack (showVersion version),
        commit = commitHash
      }

-- | Display version for logging: "v0.2.0 (abc123f)"
displayVersion :: VersionInfo -> Utf8Builder
displayVersion vi =
  "v" <> display vi.appVersion <> " (" <> display vi.commit <> ")"

-- | Lookup an environment variable with a default fallback.
lookupEnvDefault :: String -> Text -> IO Text
lookupEnvDefault key def = do
  val <- lookupEnv key
  pure $ maybe def T.pack val
```

The `Paths_backend` module is auto-generated by Cabal from `package.yaml`'s `version` field.

- [ ] **Step 2: Build and verify**

Run: `just build`
Expected: Successful compilation. `Paths_backend` should be found automatically (Cabal generates it).

- [ ] **Step 3: Commit**

```bash
git add src/Infrastructure/Version.hs
git commit -m "feat: add Infrastructure.Version module"
```

---

### Task 3: Wire `VersionInfo` into `AppEnv`, `Main.hs`, and test environment

This task modifies `App.hs`, `Main.hs`, and `InMemoryEventStore.hs` together to avoid committing broken intermediate states (all three must change atomically since `initializeAppEnv` signature changes).

**Files:**
- Modify: `src/Infrastructure/App.hs`
- Modify: `app/Main.hs`
- Modify: `test/Testkit/InMemoryEventStore.hs`

- [ ] **Step 1: Add `VersionInfo` field and `HasVersionInfo` class to `App.hs`**

In `src/Infrastructure/App.hs`:

1. Add import: `import Infrastructure.Version (VersionInfo)`
2. Add field to `AppEnv` (after `exchangeRateCache`):

```haskell
    -- | Application version information
    versionInfo :: !VersionInfo
```

3. Add `HasVersionInfo` type class:

```haskell
-- | Type class for environments that have version information.
class HasVersionInfo env where
  versionInfoL :: Lens' env VersionInfo

instance HasVersionInfo AppEnv where
  versionInfoL = lens (.versionInfo) (\x y -> x {versionInfo = y})
```

4. Export `HasVersionInfo(..)` in the module export list.
5. Add `VersionInfo` parameter to `initializeAppEnv` (last parameter) and wire it into the `AppEnv` record.

- [ ] **Step 2: Wire `VersionInfo` into `Main.hs`**

In `app/Main.hs`:

1. Add imports:

```haskell
import Infrastructure.Version (mkVersionInfo, displayVersion)
import Infrastructure.App (HasVersionInfo (versionInfoL))
```

2. In `main`, after config is loaded and before `runRIO`, construct version info:

```haskell
  versionInfo <- mkVersionInfo
```

3. In `initializeEnvironment`, accept `VersionInfo` as a parameter and pass it as the last argument to `initializeAppEnv`.

4. Replace the startup banner in `applicationMain` (which runs in `AppM`, so use the lens):

```haskell
  vi <- view versionInfoL
  logInfo "==================================="
  logInfo $ "  Accounting Backend " <> displayVersion vi
  logInfo "==================================="
```

5. Remove the `appEnvironment` helper function (no longer needed — environment is in config).

6. Update the startup log line to use config environment:

```haskell
  logInfo $ "Environment: " <> displayShow config.environment
```

- [ ] **Step 3: Fix test environment in `InMemoryEventStore.hs`**

In `test/Testkit/InMemoryEventStore.hs`:

1. Add imports:

```haskell
import Infrastructure.Version (VersionInfo (..))
import Infrastructure.Config (Environment (..))
```

2. In **both** `createTestAppEnv` and `createTestAppEnvWithProcessManager`:
   - Add `environment = EnvTest` to the `AppConfig` record (first field, matching the data declaration order)
   - Add `versionInfo = testVersionInfo` to the `AppEnv` record (after `exchangeRateCache`)
   - Define before the `AppEnv` construction:

```haskell
  let testVersionInfo = VersionInfo {appVersion = "0.0.0-test", commit = "test"}
```

Both functions construct `AppConfig` in code (not from YAML), so both need `environment = EnvTest` added.

- [ ] **Step 4: Build and run tests**

Run: `just build && just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Infrastructure/App.hs app/Main.hs test/Testkit/InMemoryEventStore.hs
git commit -m "feat: add VersionInfo to AppEnv, log version on startup"
```

---

### Task 4: Create `InfoAPI` endpoint

**Files:**
- Create: `src/Web/API/InfoAPI.hs`
- Modify: `src/Web/Server.hs`

- [ ] **Step 1: Write failing test for `/api/info` endpoint**

In `test/Integration/WebAPISpec.hs`, add a new describe block (at the top of the spec, since it needs no auth):

```haskell
  describe "GET /api/info" $ do
    it "returns 200 with version info" $ do
      resp <- getJSON "/api/info"
      simpleStatus resp `shouldBe` status200
      let body = decode (simpleBody resp) :: Maybe Value
      body `shouldSatisfy` isJust
      case body of
        Just (Object obj) -> do
          KeyMap.lookup "status" obj `shouldBe` Just (String "ok")
          KeyMap.member "version" obj `shouldBe` True
          KeyMap.member "commit" obj `shouldBe` True
          KeyMap.lookup "environment" obj `shouldBe` Just (String "test")
        _ -> expectationFailure "Expected JSON object"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option='/GET /api/info/'`
Expected: FAIL — endpoint doesn't exist yet (404).

- [ ] **Step 3: Create `InfoAPI` module**

Create `src/Web/API/InfoAPI.hs`:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.InfoAPI
-- Description : Unauthenticated application info endpoint
module Web.API.InfoAPI
  ( InfoAPI,
    infoAPI,
    InfoResponse (..),
    infoHandler,
  )
where

import Data.Aeson (ToJSON)
import Infrastructure.App (AppM, HasAppConfig (..), HasVersionInfo (..))
import Infrastructure.Config (Environment (..))
import Infrastructure.Version (VersionInfo (..))
import RIO
import Servant

-- | Info endpoint type: GET /api/info (no auth)
type InfoAPI = "api" :> "info" :> Get '[JSON] InfoResponse

-- | Proxy for InfoAPI.
infoAPI :: Proxy InfoAPI
infoAPI = Proxy

-- | Info response DTO.
data InfoResponse = InfoResponse
  { status :: Text,
    version :: Text,
    commit :: Text,
    environment :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON InfoResponse

-- | Handler for GET /api/info.
infoHandler :: AppM InfoResponse
infoHandler = do
  vi <- view versionInfoL
  config <- view appConfigL
  pure
    InfoResponse
      { status = "ok",
        version = vi.appVersion,
        commit = vi.commit,
        environment = environmentToText config.environment
      }

-- | Convert Environment to text for JSON response.
-- Note: This duplicates ToJSON Environment logic from Config.hs.
-- An alternative is to add a displayEnvironment function to Config.hs
-- and use it in both places. Either approach is acceptable for 3 cases.
environmentToText :: Environment -> Text
environmentToText EnvLocal = "local"
environmentToText EnvTest = "test"
environmentToText EnvProd = "prod"
```

- [ ] **Step 4: Mount `InfoAPI` in `Web.Server`**

In `src/Web/Server.hs`:

1. Add imports:

```haskell
import Web.API.InfoAPI (InfoAPI, infoAPI, infoHandler)
```

2. Add a `FullAPI` type that combines `InfoAPI` and the authenticated `API`:

```haskell
-- | Full API including unauthenticated info endpoint.
type FullAPI = InfoAPI :<|> API
```

3. In `buildApplication`, serve `FullAPI` instead of just `API`. The info endpoint runs outside the auth context:

```haskell
buildApplication :: AppEnv -> Application
buildApplication env =
  gzip defaultGzipSettings
    $ loggingMiddleware
    $ errorHandlingMiddleware env
    $ corsMiddleware
      servantApp
  where
    jwtConfig = env.jwtConfig
    authContext = authHandler jwtConfig S.:. S.EmptyContext

    servantApp =
      S.serveWithContext
        (Proxy :: Proxy FullAPI)
        authContext
        (infoServer :<|> hoistedServer env)

    infoServer :: S.ServerT InfoAPI S.Handler
    infoServer = S.hoistServer infoAPI (appMToHandler env) infoHandler
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cabal test all --test-option='--match' --test-option='/GET /api/info/'`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/Web/API/InfoAPI.hs src/Web/Server.hs test/Integration/WebAPISpec.hs
git commit -m "feat: add unauthenticated GET /api/info endpoint"
```

---

### Task 5: Dockerfile and CI changes

**Files:**
- Modify: `infra/docker/Dockerfile`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add `APP_COMMIT_HASH` build arg to Dockerfile**

In `infra/docker/Dockerfile`, in the runtime stage (after `WORKDIR /app`), add:

```dockerfile
ARG APP_COMMIT_HASH=dev
ENV APP_COMMIT_HASH=${APP_COMMIT_HASH}
```

Place it before `COPY --from=builder` lines so the env var is set when the container runs.

- [ ] **Step 2: Extract version and add to CI image tags**

In `.github/workflows/ci.yml`, in the `build-image` job:

1. In the "Extract metadata" step, add version extraction:

```yaml
      - name: Extract metadata
        id: meta
        run: |
          echo "sha_short=$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"
          BRANCH="${GITHUB_REF#refs/heads/}"
          BRANCH_SLUG="${BRANCH//\//-}"
          echo "branch_slug=$BRANCH_SLUG" >> "$GITHUB_OUTPUT"
          VERSION=$(grep '^version:' package.yaml | awk '{print $2}')
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
```

2. In the "Determine image tags" step, add version tag:

```yaml
      - name: Determine image tags
        id: tags
        run: |
          SHA_TAG="ghcr.io/${{ github.repository_owner }}/backend:${{ steps.meta.outputs.sha_short }}"
          BRANCH_TAG="ghcr.io/${{ github.repository_owner }}/backend:${{ steps.meta.outputs.branch_slug }}"
          VERSION_TAG="ghcr.io/${{ github.repository_owner }}/backend:${{ steps.meta.outputs.version }}"
          if [ "${{ github.ref }}" = "refs/heads/master" ]; then
            echo "tags=${SHA_TAG},$BRANCH_TAG,$VERSION_TAG,ghcr.io/${{ github.repository_owner }}/backend:latest" >> "$GITHUB_OUTPUT"
          else
            echo "tags=${SHA_TAG},$BRANCH_TAG" >> "$GITHUB_OUTPUT"
          fi
```

3. In the "Build and push" step, pass the build arg:

```yaml
      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: infra/docker/Dockerfile
          push: true
          tags: ${{ steps.tags.outputs.tags }}
          build-args: |
            APP_COMMIT_HASH=${{ steps.meta.outputs.sha_short }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 3: Commit**

```bash
git add infra/docker/Dockerfile .github/workflows/ci.yml
git commit -m "ci: add version tag and commit hash to Docker image"
```

---

### Task 6: Format, lint, and final verification

**Files:** All modified files

- [ ] **Step 1: Format code**

Run: `just format`

- [ ] **Step 2: Lint code**

Run: `just lint`
Expected: No warnings/errors.

- [ ] **Step 3: Full build and test**

Run: `just build && just test`
Expected: All pass.

- [ ] **Step 4: Commit any formatting fixes**

```bash
git add -A
git commit -m "style: format code"
```

(Only if formatting produced changes.)

- [ ] **Step 5: Update spec status**

Change `status: draft` to `status: completed` in `docs/specs/2026-04-09-backend-versioning-design.md`.

```bash
git add docs/specs/2026-04-09-backend-versioning-design.md
git commit -m "docs: mark backend versioning spec as completed"
```
