---
status: completed
spec: docs/specs/2026-04-17-api-base-url-derived-urls-design.md
issue: https://github.com/homeaccounting/backend/issues/42
---

# API_BASE_URL Derived URLs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `API_BASE_URL` the single source of truth for every URL that points at our own API, by (a) extending the YAML env-var substituter to support in-string substitution and (b) rewriting all derivable URLs in config/`.env`/docker-compose to reference `${API_BASE_URL}`.

**Architecture:** The existing `substituteEnvVars` in `Infrastructure.Config` only resolves strings that are entirely `${VAR}` or `${VAR:-default}`. We extend it to scan and resolve every `${…}` occurrence inside a string, preserving existing whole-string coercion semantics (number, bool, null). Derived URLs (`telegram.webhook_url`, three `oauth.*.redirect_uri`) then live in YAML as `${API_BASE_URL}`-prefixed strings, and the redundant env vars (`TELEGRAM_WEBHOOK_URL`, `*_REDIRECT_URI`) are removed from `infra/.env` and docker-compose.

**Tech Stack:** GHC 9.10.3, RIO, Aeson, Data.Yaml, Hspec (tests auto-discovered by `hspec-discover`), ormolu, hlint.

---

## File Structure

**Modified files:**

- `src/Infrastructure/Config.hs` — replace the `substituteText` helper inside `substituteEnvVars` with an in-string scanner.
- `config/prod.yaml` — rewrite `telegram.webhook_url` and three `oauth.*.redirect_uri` fields.
- `config/local.yaml` — rewrite three `oauth.*.redirect_uri` fields (telegram stays `null` for polling).
- `infra/.env` — add `API_BASE_URL`, remove `TELEGRAM_WEBHOOK_URL`.
- `infra/docker/docker-compose.yaml` — add `API_BASE_URL`, remove `TELEGRAM_WEBHOOK_URL` and three `*_REDIRECT_URI` entries from the `api` service env block.

**New files:**

- `test/Infrastructure/ConfigSpec.hs` — new Hspec module for `substituteEnvVars`. Auto-picked up by `hspec-discover` (no manual wiring needed).

---

## Pre-flight

- [ ] **Step 0.1: Confirm you are on the feature branch**

```bash
git rev-parse --abbrev-ref HEAD
```

Expected: `refactor/use-api-base-url-for-derived-urls`

- [ ] **Step 0.2: Enter the Nix dev shell**

```bash
nix develop
```

This puts `ghc`, `cabal`, `hpack`, `ormolu`, `hlint`, and `just` on `PATH`. All subsequent commands assume you are inside this shell.

- [ ] **Step 0.3: Baseline build is green**

```bash
just build
just test
```

Expected: build succeeds; all tests pass. If either fails, stop and investigate before continuing.

---

## Task 1: Create `ConfigSpec.hs` with regression coverage for current substituter

**Rationale:** Before changing `substituteEnvVars`, pin down its current behaviour with tests so the extension cannot silently regress the whole-string substitution path (including `coerceValue`'s number/bool/null handling).

**Files:**

- Create: `test/Infrastructure/ConfigSpec.hs`

- [ ] **Step 1.1: Write the regression spec**

Create `test/Infrastructure/ConfigSpec.hs` with:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ConfigSpec (spec) where

import Data.Aeson (Value (..))
import Infrastructure.Config (substituteEnvVars)
import RIO
import System.Environment (setEnv, unsetEnv)
import Test.Hspec

-- Helper: set an env var for the duration of an action, then restore.
withEnv :: String -> String -> IO a -> IO a
withEnv name value action = do
  prev <- lookupEnvIO name
  setEnv name value
  result <- action
  case prev of
    Just v -> setEnv name v
    Nothing -> unsetEnv name
  pure result
  where
    lookupEnvIO = System.Environment.lookupEnv

spec :: Spec
spec = describe "substituteEnvVars (existing behaviour)" $ do
  it "substitutes a whole-string ${VAR} with the env value as String" $
    withEnv "CFG_TEST_HOST" "example.com" $ do
      result <- substituteEnvVars (String "${CFG_TEST_HOST}")
      result `shouldBe` Right (String "example.com")

  it "coerces a numeric-looking whole-string substitution to Number" $
    withEnv "CFG_TEST_PORT" "8080" $ do
      result <- substituteEnvVars (String "${CFG_TEST_PORT}")
      result `shouldBe` Right (Number 8080)

  it "coerces a boolean whole-string substitution to Bool" $
    withEnv "CFG_TEST_FLAG" "true" $ do
      result <- substituteEnvVars (String "${CFG_TEST_FLAG}")
      result `shouldBe` Right (Bool True)

  it "coerces the literal 'null' to Null" $
    withEnv "CFG_TEST_NULL" "null" $ do
      result <- substituteEnvVars (String "${CFG_TEST_NULL}")
      result `shouldBe` Right Null

  it "uses the :- default when the variable is unset" $ do
    unsetEnv "CFG_TEST_MISSING"
    result <- substituteEnvVars (String "${CFG_TEST_MISSING:-fallback}")
    result `shouldBe` Right (String "fallback")

  it "returns Left when a required variable is unset" $ do
    unsetEnv "CFG_TEST_REQUIRED"
    result <- substituteEnvVars (String "${CFG_TEST_REQUIRED}")
    result `shouldSatisfy` isLeft
    case result of
      Left err -> err `shouldSatisfy` ("CFG_TEST_REQUIRED" `isInfixOf`)
      Right _ -> expectationFailure "expected Left"

  it "leaves strings with no ${...} untouched" $ do
    result <- substituteEnvVars (String "plain literal value")
    result `shouldBe` Right (String "plain literal value")

  it "recurses into objects and arrays" $
    withEnv "CFG_TEST_X" "resolved" $ do
      let input =
            Object $
              fromList
                [ ("a", String "${CFG_TEST_X}"),
                  ("b", Array $ fromList [String "${CFG_TEST_X}"])
                ]
      result <- substituteEnvVars input
      result
        `shouldBe` Right
          ( Object $
              fromList
                [ ("a", String "resolved"),
                  ("b", Array $ fromList [String "resolved"])
                ]
          )
  where
    isInfixOf needle haystack = needle `elem` tails haystack
    -- Uses Text; Prelude's Data.List.isInfixOf works with [Char]. Import
    -- Data.Text.isInfixOf instead if Prelude's is not in scope under RIO.
```

Notes before you save the file:

- `RIO` re-exports most of what you need. You will likely need to import:
  - `Data.Aeson (Value (..))`
  - `System.Environment (setEnv, unsetEnv, lookupEnv)`
  - `Data.Text (isInfixOf)` (aliased) for the infix check on `Text`
  - `Data.Aeson.KeyMap (fromList)` or use the `Map`-like literal via `Data.Aeson.Key`
- If `fromList` for `Object` / `Array` needs disambiguation, prefer the explicit `Data.Aeson.KeyMap.fromList` and `Data.Vector.fromList` imports.
- Keep the helper `withEnv` local to this spec; we don't need a Testkit helper yet.

- [ ] **Step 1.2: Run the new spec; verify it compiles and all cases pass against the current (unchanged) code**

```bash
cabal test all --test-option='--match' --test-option="/Infrastructure.Config/"
```

Expected: all cases in `ConfigSpec` pass. If any fail, it means the current substituter does not behave as the spec says — stop and reconcile with the spec doc.

- [ ] **Step 1.3: Format + lint**

```bash
just format
just lint
```

Expected: no diff, no lint warnings.

- [ ] **Step 1.4: Commit**

```bash
git add test/Infrastructure/ConfigSpec.hs
git commit -m "test(config): pin substituteEnvVars whole-string behaviour"
```

---

## Task 2: Add failing tests for in-string env-var substitution

**Rationale:** Red step of TDD. These tests describe the new behaviour (in-string substitution, concatenation, default inside a larger string, required-but-missing inside a larger string) and must fail against the current `substituteText`.

**Files:**

- Modify: `test/Infrastructure/ConfigSpec.hs`

- [ ] **Step 2.1: Append a new `describe` block to the spec**

Inside the same `spec` definition in `ConfigSpec.hs`, add after the existing `describe`:

```haskell
  describe "substituteEnvVars (in-string substitution)" $ do
    it "substitutes ${VAR} inside a larger string" $
      withEnv "CFG_TEST_BASE" "https://homeaccounting.com" $ do
        result <- substituteEnvVars (String "${CFG_TEST_BASE}/api/telegram/webhook")
        result
          `shouldBe` Right (String "https://homeaccounting.com/api/telegram/webhook")

    it "substitutes multiple ${VAR} occurrences in one string" $
      withEnv "CFG_TEST_A" "1" $
        withEnv "CFG_TEST_B" "2" $ do
          result <- substituteEnvVars (String "${CFG_TEST_A}-${CFG_TEST_B}")
          result `shouldBe` Right (String "1-2")

    it "uses :- default when variable is unset inside a larger string" $ do
      unsetEnv "CFG_TEST_MISSING2"
      result <- substituteEnvVars (String "${CFG_TEST_MISSING2:-fallback}/path")
      result `shouldBe` Right (String "fallback/path")

    it "returns Left when a required variable is unset inside a larger string" $ do
      unsetEnv "CFG_TEST_REQ2"
      result <- substituteEnvVars (String "prefix-${CFG_TEST_REQ2}-suffix")
      result `shouldSatisfy` isLeft

    it "preserves literal text surrounding the substitutions" $
      withEnv "CFG_TEST_HOST2" "host.example" $ do
        result <- substituteEnvVars (String "https://${CFG_TEST_HOST2}:8080/x")
        result `shouldBe` Right (String "https://host.example:8080/x")

    it "does not coerce the result of in-string substitution to Number" $
      withEnv "CFG_TEST_N" "42" $ do
        -- Pure ${VAR} still coerces (existing test); surrounded by literal
        -- text, it must stay a String.
        result <- substituteEnvVars (String "port=${CFG_TEST_N}")
        result `shouldBe` Right (String "port=42")
```

- [ ] **Step 2.2: Run the new spec; verify the new cases fail**

```bash
cabal test all --test-option='--match' --test-option="/Infrastructure.Config/in-string substitution/"
```

Expected: every case in the new `describe` fails. The existing whole-string cases must still pass (do not break them).

If any of the *new* cases accidentally passes against the current code, the test does not actually exercise the new behaviour — tighten it.

- [ ] **Step 2.3: Do NOT commit yet**

We keep red tests out of `HEAD`. Move straight to the implementation task.

---

## Task 3: Implement in-string substitution

**Rationale:** Green step. Replace `substituteText` with a scanner that resolves every `${…}` inside a string.

**Files:**

- Modify: `src/Infrastructure/Config.hs`

**Reference location:** `src/Infrastructure/Config.hs:460-524` (current `substituteEnvVars` and its helpers).

- [ ] **Step 3.1: Replace `substituteText` and its helpers**

Replace the existing `String` branch of `substituteEnvVars.go` and the helpers below it with this implementation. Everything above (`Object`/`Array`/`other` branches) stays untouched.

```haskell
    go :: Value -> IO (Either Text Value)
    go (Object obj) = do
      results <- traverse go obj
      pure $ Object <$> sequenceA results
    go (Array arr) = do
      results <- traverse go arr
      pure $ Array <$> sequenceA results
    go (String text) = do
      result <- substituteText text
      case result of
        Left err -> pure $ Left err
        Right (wasWholeString, newText)
          | wasWholeString -> pure $ Right $ coerceValue newText
          | otherwise -> pure $ Right $ String newText
    go other = pure $ Right other

    -- | Scan the input text, resolving every @${…}@ occurrence in place and
    -- concatenating the results with the surrounding literal text.
    --
    -- Returns @(wasWholeString, result)@. @wasWholeString@ is 'True' when the
    -- entire input was exactly one @${…}@ expression with no surrounding
    -- literals — the caller uses this to decide whether 'coerceValue' should
    -- run (preserving the legacy behaviour where @${PORT}@ becomes a
    -- 'Number').
    substituteText :: Text -> IO (Either Text (Bool, Text))
    substituteText input = go' input mempty
      where
        go' remaining acc =
          case T.breakOn "${" remaining of
            (prefix, rest)
              | T.null rest -> pure $ Right (isWholeMatch prefix acc input, acc <> prefix)
              | otherwise ->
                  let afterOpen = T.drop 2 rest
                   in case T.breakOn "}" afterOpen of
                        (_, closeRest)
                          | T.null closeRest ->
                              -- No closing brace: treat the rest as literal.
                              pure $ Right (False, acc <> prefix <> rest)
                        (expr, closeRest) -> do
                          let afterClose = T.drop 1 closeRest
                              (varName, mDefault) = parseVarExpr expr
                          envValue <- lookupEnv (T.unpack varName)
                          case (envValue, mDefault) of
                            (Just val, _) ->
                              go' afterClose (acc <> prefix <> T.pack val)
                            (Nothing, Just def') ->
                              go' afterClose (acc <> prefix <> def')
                            (Nothing, Nothing) ->
                              pure $ Left $ "Environment variable not set: " <> varName

        -- True when the entire original string was exactly one ${...}.
        -- Implementation: after scanning, if the accumulator is still empty
        -- and the current prefix is also empty, the only thing consumed was
        -- one ${...} that produced the value now being appended.
        isWholeMatch prefix acc original =
          T.null prefix
            && T.null acc == False
            && "${" `T.isPrefixOf` original
            && "}" `T.isSuffixOf` original
            && T.count "${" original == 1

    -- \| Split @VAR_NAME:-default@ into the variable name and an optional
    -- default value.  If the @:-@ separator is absent, no default is
    -- returned.
    parseVarExpr :: Text -> (Text, Maybe Text)
    parseVarExpr expr =
      case T.breakOn ":-" expr of
        (name, rest)
          | T.null rest -> (name, Nothing)
          | otherwise -> (name, Just $ T.drop 2 rest)

    -- \| Attempt to coerce a substituted text value to the appropriate JSON
    -- type.  Environment variable substitution always produces 'Text', but
    -- downstream 'FromJSON' instances expect 'Number', 'Bool', or 'Null'
    -- for non-string fields.
    coerceValue :: Text -> Value
    coerceValue t
      | T.null t = String t -- preserve empty strings for Text fields
      | T.toLower t == "null" = Null
      | T.toLower t == "true" = Bool True
      | T.toLower t == "false" = Bool False
      | Just n <- Read.readMaybe (T.unpack t) :: Maybe Integer =
          Number (fromInteger n)
      | Just d <- Read.readMaybe (T.unpack t) :: Maybe Double =
          Number (realToFrac d)
      | otherwise = String t
```

Key design points to keep in mind while adapting:

1. **Whole-string detection.** The legacy behaviour is: if the entire input is exactly one `${…}`, the resolved value is coerced (so `"${PORT}"` becomes `Number 8080`, not `String "8080"`). Anything with literal characters surrounding the substitution stays a `String`. The `isWholeMatch` helper encodes that rule; verify with Task 1's Number/Bool/Null tests that it still holds.
2. **Default with `:-`.** `parseVarExpr` logic is preserved verbatim.
3. **Required-missing error message** stays identical to the current format (`"Environment variable not set: VAR"`) so no call site needs to change.
4. **Unterminated `${`** (no matching `}`) should be treated as literal rather than crashing; the code above returns the rest as-is. This matches bash's tolerant behaviour and avoids a regression if a YAML string legitimately contains `$` followed by `{`.

You may find a cleaner formulation of `isWholeMatch`. As long as the Task 1 coercion tests keep passing, prefer what you find readable.

- [ ] **Step 3.2: Build**

```bash
just build
```

Expected: build succeeds with no warnings. If `-Wall` complains (e.g. unused bindings after restructuring), clean them up.

- [ ] **Step 3.3: Run the Config spec; verify every case passes**

```bash
cabal test all --test-option='--match' --test-option="/Infrastructure.Config/"
```

Expected: every case in both `describe` blocks passes.

- [ ] **Step 3.4: Run the full test suite to confirm no other regression**

```bash
just test
```

Expected: all suites pass.

- [ ] **Step 3.5: Format + lint**

```bash
just format
just lint
```

Expected: no diff; no lint warnings.

- [ ] **Step 3.6: Commit**

```bash
git add src/Infrastructure/Config.hs test/Infrastructure/ConfigSpec.hs
git commit -m "refactor(config): support in-string env var substitution"
git push
```

(Push keeps the PR branch current — see repo workflow convention.)

---

## Task 4: Update `config/prod.yaml` to derive URLs from `${API_BASE_URL}`

**Files:**

- Modify: `config/prod.yaml`

- [ ] **Step 4.1: Replace the three OAuth `redirect_uri` values**

Under `oauth:`, change:

```yaml
  google:
    client_id: "${GOOGLE_CLIENT_ID}"
    client_secret: "${GOOGLE_CLIENT_SECRET}"
    redirect_uri: "${GOOGLE_REDIRECT_URI}"
  github:
    client_id: "${GITHUB_CLIENT_ID}"
    client_secret: "${GITHUB_CLIENT_SECRET}"
    redirect_uri: "${GITHUB_REDIRECT_URI}"
  microsoft:
    client_id: "${MICROSOFT_CLIENT_ID}"
    client_secret: "${MICROSOFT_CLIENT_SECRET}"
    redirect_uri: "${MICROSOFT_REDIRECT_URI}"
```

to:

```yaml
  google:
    client_id: "${GOOGLE_CLIENT_ID}"
    client_secret: "${GOOGLE_CLIENT_SECRET}"
    redirect_uri: "${API_BASE_URL}/api/auth/oauth/google/callback"
  github:
    client_id: "${GITHUB_CLIENT_ID}"
    client_secret: "${GITHUB_CLIENT_SECRET}"
    redirect_uri: "${API_BASE_URL}/api/auth/oauth/github/callback"
  microsoft:
    client_id: "${MICROSOFT_CLIENT_ID}"
    client_secret: "${MICROSOFT_CLIENT_SECRET}"
    redirect_uri: "${API_BASE_URL}/api/auth/oauth/microsoft/callback"
```

- [ ] **Step 4.2: Replace `telegram.webhook_url`**

Under `telegram:`, change:

```yaml
  webhook_url: "${TELEGRAM_WEBHOOK_URL}"
```

to:

```yaml
  webhook_url: "${API_BASE_URL}/api/telegram/webhook"
```

- [ ] **Step 4.3: Do NOT commit yet**

We commit the YAML and env/docker changes together so the config stays loadable at every commit. Task 5 covers `local.yaml`; Task 6 covers `.env` and docker-compose; they commit as a single change.

---

## Task 5: Update `config/local.yaml` to derive OAuth redirects from `${API_BASE_URL:-http://localhost:8080}`

**Files:**

- Modify: `config/local.yaml`

- [ ] **Step 5.1: Replace the three OAuth `redirect_uri` values**

Under `oauth:`, change:

```yaml
  google:
    client_id: ${GOOGLE_CLIENT_ID:-}
    client_secret: ${GOOGLE_CLIENT_SECRET:-}
    redirect_uri: "http://localhost:8080/api/auth/oauth/google/callback"
  github:
    client_id: ${GITHUB_CLIENT_ID:-}
    client_secret: ${GITHUB_CLIENT_SECRET:-}
    redirect_uri: "http://localhost:8080/api/auth/oauth/github/callback"
  microsoft:
    client_id: ${MICROSOFT_CLIENT_ID:-}
    client_secret: ${MICROSOFT_CLIENT_SECRET:-}
    redirect_uri: "http://localhost:8080/api/auth/oauth/microsoft/callback"
```

to:

```yaml
  google:
    client_id: ${GOOGLE_CLIENT_ID:-}
    client_secret: ${GOOGLE_CLIENT_SECRET:-}
    redirect_uri: "${API_BASE_URL:-http://localhost:8080}/api/auth/oauth/google/callback"
  github:
    client_id: ${GITHUB_CLIENT_ID:-}
    client_secret: ${GITHUB_CLIENT_SECRET:-}
    redirect_uri: "${API_BASE_URL:-http://localhost:8080}/api/auth/oauth/github/callback"
  microsoft:
    client_id: ${MICROSOFT_CLIENT_ID:-}
    client_secret: ${MICROSOFT_CLIENT_SECRET:-}
    redirect_uri: "${API_BASE_URL:-http://localhost:8080}/api/auth/oauth/microsoft/callback"
```

Leave `telegram.webhook_url: null` unchanged — local dev uses polling.

- [ ] **Step 5.2: Do NOT commit yet**

---

## Task 6: Update `infra/.env` and `infra/docker/docker-compose.yaml`; verify; commit

**Files:**

- Modify: `infra/.env`
- Modify: `infra/docker/docker-compose.yaml`

- [ ] **Step 6.1: Edit `infra/.env`**

Add `API_BASE_URL` line (next to `DOMAIN=...`):

```
API_BASE_URL=https://homeaccounting.com
```

Remove the line:

```
TELEGRAM_WEBHOOK_URL=https://homeaccounting.com/api/telegram/webhook
```

The `GOOGLE_REDIRECT_URI`, `GITHUB_REDIRECT_URI`, and `MICROSOFT_REDIRECT_URI` entries in `.env` are already empty strings — they can stay as-is (they are no longer referenced by any config) or be removed. **Remove them** for clarity:

```
GOOGLE_REDIRECT_URI=
GITHUB_REDIRECT_URI=
MICROSOFT_REDIRECT_URI=
```

…are deleted.

- [ ] **Step 6.2: Edit `infra/docker/docker-compose.yaml` (api service environment block)**

Inside the `api:` service's `environment:` list, remove:

```
- GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI:-}
- GITHUB_REDIRECT_URI=${GITHUB_REDIRECT_URI:-}
- MICROSOFT_REDIRECT_URI=${MICROSOFT_REDIRECT_URI:-}
- TELEGRAM_WEBHOOK_URL=${TELEGRAM_WEBHOOK_URL:-}
```

Add (anywhere sensible in the list — near the top with the other base vars):

```
- API_BASE_URL=${API_BASE_URL}
```

Note the lack of `:-` default: `API_BASE_URL` is required in production, mirroring how prod YAML declares `${API_BASE_URL}` without a fallback.

- [ ] **Step 6.3: Verify prod config is loadable end-to-end**

Run the config loader with the prod YAML and a synthetic env:

```bash
env \
  API_BASE_URL=https://homeaccounting.com \
  DB_HOST=localhost DB_PORT=5432 DB_USER=x DB_PASSWORD=x DB_NAME=x \
  JWT_SECRET=dummy \
  GOOGLE_CLIENT_ID= GOOGLE_CLIENT_SECRET= \
  GITHUB_CLIENT_ID= GITHUB_CLIENT_SECRET= \
  MICROSOFT_CLIENT_ID= MICROSOFT_CLIENT_SECRET= \
  TELEGRAM_BOT_TOKEN= TELEGRAM_BOT_USERNAME= \
  CONFIG_PATH=config/prod.yaml \
  cabal run backend -- --check-config 2>&1 | head -40
```

If the backend does not have a `--check-config` flag, fall back to a one-off `cabal repl`:

```bash
cabal repl backend
```

then in the REPL:

```haskell
:set -XOverloadedStrings
import Infrastructure.Config
res <- loadConfigWithEnv "config/prod.yaml"
:t res
-- Expect: Right AppConfig { ... }
```

Expected: load succeeds; inspect the resulting values and confirm:

- `server.apiBaseUrl == "https://homeaccounting.com"`
- `telegram.webhookUrl == Just "https://homeaccounting.com/api/telegram/webhook"`
- All three `oauth.*.redirectUri` equal `https://homeaccounting.com/api/auth/oauth/<provider>/callback`.

- [ ] **Step 6.4: Verify local config is loadable with and without `API_BASE_URL`**

With `API_BASE_URL` unset:

```bash
unset API_BASE_URL
CONFIG_PATH=config/local.yaml cabal run backend -- --check-config 2>&1 | head -20
```

Expected: load succeeds; OAuth redirects fall back to `http://localhost:8080/api/auth/oauth/<provider>/callback`.

With `API_BASE_URL=https://dev.ngrok.io`:

```bash
API_BASE_URL=https://dev.ngrok.io CONFIG_PATH=config/local.yaml cabal run backend -- --check-config 2>&1 | head -20
```

Expected: load succeeds; OAuth redirects reflect the override.

(If `--check-config` is unavailable, repeat the `cabal repl` approach above with `config/local.yaml`.)

- [ ] **Step 6.5: Format + lint + full test suite**

```bash
just format
just lint
just test
```

Expected: no diff, no lint warnings, all tests pass.

- [ ] **Step 6.6: Commit**

```bash
git add config/prod.yaml config/local.yaml infra/.env infra/docker/docker-compose.yaml
git commit -m "refactor(config): derive service URLs from API_BASE_URL

Closes #42"
git push
```

---

## Task 7: Open the pull request

- [ ] **Step 7.1: Open PR targeting `master`**

```bash
gh pr create --base master --title "refactor(config): derive service URLs from API_BASE_URL" --body "$(cat <<'EOF'
## Summary

- Extend `substituteEnvVars` so `${VAR}` can appear inside a larger string (e.g. `${API_BASE_URL}/api/telegram/webhook`), preserving existing whole-string coercion to Number/Bool/Null.
- Replace `TELEGRAM_WEBHOOK_URL` and `GOOGLE_/GITHUB_/MICROSOFT_REDIRECT_URI` with derivations from `${API_BASE_URL}` in both `config/prod.yaml` and `config/local.yaml`.
- Remove the now-redundant env vars from `infra/.env` and `infra/docker/docker-compose.yaml`; add `API_BASE_URL` there.

Closes #42

## Test plan

- [x] New `test/Infrastructure/ConfigSpec.hs` covers the existing whole-string / coercion behaviour and the new in-string substitution rules.
- [x] `just test` passes locally.
- [x] `loadConfigWithEnv "config/prod.yaml"` with `API_BASE_URL=https://homeaccounting.com` resolves telegram and OAuth URLs as expected.
- [x] `loadConfigWithEnv "config/local.yaml"` with `API_BASE_URL` unset falls back to `http://localhost:8080/...`.
EOF
)"
```

Expected: PR URL returned. Verify the CI build (`-Werror`) passes.

---

## Out of scope (intentionally not in this plan)

- Wiring `server.apiBaseUrl` into downstream consumers. The field is available in `AppEnv` via `Infrastructure.Config.ServerConfig` and will be consumed by a later change.
- Adding validation that `API_BASE_URL` is a well-formed URL. Operators can supply any non-empty string; YAML-level validation is out of scope.
- Collapsing the unused `TelegramConfig.webhookUrl` / OAuth `redirect_uri` fields into computed-at-runtime derivations. The YAML remains the source of truth for resolved URLs.
