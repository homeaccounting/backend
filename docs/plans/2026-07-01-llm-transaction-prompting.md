# LLM Transaction Prompting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `POST /api/prompt` that turns a free-text message into a committed income/expense/transfer transaction, using a free open-weights LLM (OpenAI-compatible API) for extraction and deterministic code for resolution.

**Architecture:** The LLM only *extracts* a structured `TransactionIntent` (names/amounts as text, in any language); pure code *resolves* those against the user's real accounts + category dictionary and delegates to the existing `TransactionService`. The LLM is an infrastructure provider (record-of-functions, like `RateProvider`), injected as `Maybe LlmClient` in `AppEnv`. `Domain.*` is untouched; resolution failures reuse `ValidationErr`→400; feature-disabled/upstream failures are thrown as Servant `err503`/`err502` at the Web layer.

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Servant, Aeson, http-client + http-client-tls, Hspec + QuickCheck. Spec: `docs/specs/2026-07-01-llm-transaction-prompting-design.md`.

---

## Conventions for every task

- **New module header** (mirror existing files):
  ```haskell
  {-# LANGUAGE OverloadedRecordDot #-}
  {-# LANGUAGE OverloadedStrings #-}
  {-# LANGUAGE NoImplicitPrelude #-}
  ```
  Add `{-# LANGUAGE ScopedTypeVariables #-}` / `{-# LANGUAGE LambdaCase #-}` where used. Default extensions (`NoFieldSelectors`, `DuplicateRecordFields`, `OverloadedRecordDot`, `DataKinds`, `TypeFamilies`, …) come from `package.yaml`.
- Because `NoFieldSelectors` is on, access fields with `.field` (e.g. `msg.content`), never as bare functions.
- `source-dirs: src` uses hpack auto-discovery — new `.hs` files are picked up automatically after `hpack` (run by `just build`). New test `*Spec.hs` files are auto-found by `hspec-discover`.
- **Build:** `just build` (runs `hpack` + `cabal build all -fci`). **Test:** `just test`. **Single test:** `cabal test all -fci --test-show-details=direct --test-option="--match" --test-option="PATTERN"`. **Format+lint before every commit:** `just check` (ormolu + hlint), or `just format`.
- Commit after each task with a Conventional Commit message. Branch is already `feat/llm-transaction-prompting`.
- Never export data constructors/field selectors except via the module export list already shown; total functions only; no `error`/`undefined`.

---

## File Structure

**Create:**
- `src/Data/Text/Match.hs` — generic pure name matcher (`MatchResult`, `matchByName`, `normalizeName`).
- `src/Infrastructure/Llm/Provider.hs` — `LlmClient` record-of-functions + `LlmRequest`/`LlmResponse`/`LlmMessage`/`LlmRole`.
- `src/Infrastructure/Llm/OpenAICompat.hs` — concrete OpenAI-compatible client + pure request-encode / response-decode helpers.
- `src/Application/Services/Prompt/Transaction/Intent.hs` — `TransactionIntent` payload + its decoder + JSON-schema fragment + `PromptContext` + `transactionGuide` (prompt text for this intent).
- `src/Application/Services/Prompt/Transaction/Resolve.hs` — pure `resolveIntent` (names→ids, currency/amount/date defaults) → `Resolved` + interpretation.
- `src/Application/Services/Prompt/Transaction/Handler.hs` — `gatherContext` + `runCreateTransaction` (resolve + commit), in `AppM`, returns `PromptResult`.
- `src/Application/Services/Prompt/Types.hs` — `IntentEnvelope` + `decodeEnvelope`, `PromptIntent` sum + `decodePromptIntent`, `PromptResult` sum, `ResolveError`.
- `src/Application/Services/Prompt/Builder.hs` — intent-agnostic prompt assembler (envelope instructions + registered intent guides) → `[LlmMessage]`.
- `src/Application/Services/PromptService.hs` — `handlePrompt` router: build prompt, LLM call + retry, decode envelope, exhaustive dispatch, in `AppM`.
- `src/Web/API/PromptAPI.hs` — `PromptAPI` type, `PromptRequest`/`PromptResponse` DTOs, `promptHandler`, `promptServer` (maps `PromptResult`→tagged JSON).
- `test/Data/Text/MatchSpec.hs`, `test/Data/Text/MatchPropertySpec.hs`
- `test/Infrastructure/Llm/OpenAICompatSpec.hs`
- `test/Application/Services/Prompt/Transaction/IntentSpec.hs`
- `test/Application/Services/Prompt/Transaction/ResolveSpec.hs`
- `test/Application/Services/Prompt/TypesSpec.hs` (envelope + PromptIntent decode)
- `test/Application/Services/Prompt/BuilderSpec.hs`
- `test/Integration/TransactionPromptIntegrationSpec.hs`
- `test/Testkit/Llm.hs` — stub `LlmClient` builders for tests.

**Modify:**
- `src/Infrastructure/Config.hs` — add `LlmConfig` + `llm` field + FromJSON.
- `src/Infrastructure/App.hs` — add `llmClient :: Maybe LlmClient` field, `HasLlmClient`, extend `initializeAppEnv`.
- `app/Main.hs` — build client from config, pass to `initializeAppEnv`.
- `src/Web/API.hs` — add `PromptAPI` to `type API` and `promptServer` to `server`.
- `test/Testkit/InMemoryEventStore.hs` — pass `Nothing` (default) for `llmClient` when building the test env.
- `config/local.yaml`, `config/test.yaml`, `config/prod.yaml` — add `llm:` section.
- `docs/architecture.md` — one line noting the new endpoint + LLM provider.

---

> **⚠ Intent-architecture refactor (authoritative: spec §2a + File Structure above).**
> Tasks 1–4 below are unchanged. Tasks 5–9 were drafted before the extensible
> intent redesign and their **module paths + structure are superseded** by the
> File Structure list and spec §2a. When executing Tasks 5–9, apply:
> - Transaction extraction lives under `Application.Services.Prompt.Transaction.{Intent,Resolve,Handler}` (not `TransactionPrompt.*`).
> - Add the `intent` discriminator field (`"create_transaction"`) to the transaction schema/decoder (§5.1).
> - New module `Application.Services.Prompt.Types` holds `IntentEnvelope`+`decodeEnvelope`, the `PromptIntent` sum (`CreateTransactionIntent TransactionIntent | …`) + `decodePromptIntent`, the `PromptResult` sum (`TransactionCreated {…} | …`), and `ResolveError`.
> - New module `Application.Services.Prompt.Builder` assembles the prompt (envelope instructions + per-intent guides).
> - `Application.Services.PromptService.handlePrompt` is the router: build prompt → LLM (+retry) → `decodePromptIntent` → **exhaustive `case`** dispatch → `PromptResult`. Unknown intent → 400; malformed/LLM failure → 502; disabled → 503.
> - `Web.API.PromptAPI` maps each `PromptResult` variant to the `kind`-tagged JSON.
> The code bodies in Tasks 5–9 remain valid as the transaction intent's implementation; only names/placement and the added envelope/router layer change. The controller's per-task dispatch prompts carry the final authoritative text.

## Task 1: `Data.Text.Match` — generic name matcher

**Files:**
- Create: `src/Data/Text/Match.hs`
- Test: `test/Data/Text/MatchSpec.hs`, `test/Data/Text/MatchPropertySpec.hs`

- [ ] **Step 1: Write failing unit test** — `test/Data/Text/MatchSpec.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Text.MatchSpec (spec) where

import Data.Text.Match (MatchResult (..), matchByName, normalizeName)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Data.Text.Match" $ do
  describe "matchByName" $ do
    let cs = ["Cash", "Bank", "Card"] :: [Text]
    it "exact match (case/space-insensitive)" $
      matchByName id "  cASH " cs `shouldBe` Matched "Cash"
    it "canonical name returned verbatim" $
      matchByName id "Cash" cs `shouldBe` Matched "Cash"
    it "unambiguous substring match" $
      matchByName id "ban" cs `shouldBe` Matched "Bank"
    it "no match" $
      matchByName id "wallet" cs `shouldBe` (NoMatch :: MatchResult Text)
    it "ambiguous exact duplicates" $
      matchByName id "cash" (["Cash", "cash"] :: [Text]) `shouldBe` Ambiguous ["Cash", "cash"]
    it "ambiguous substring" $
      matchByName id "car" (["Card", "Carwash"] :: [Text]) `shouldBe` Ambiguous ["Card", "Carwash"]
    it "empty query is NoMatch" $
      matchByName id "" cs `shouldBe` (NoMatch :: MatchResult Text)
  describe "normalizeName" $
    it "casefolds, trims, collapses whitespace" $
      normalizeName "  Foo   Bar " `shouldBe` "foo bar"
```

- [ ] **Step 2: Run it, verify it fails** — `cabal test all -fci --test-show-details=direct --test-option="--match" --test-option="Data.Text.Match"` → FAIL (module not found).

- [ ] **Step 3: Implement** — `src/Data/Text/Match.hs`

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Data.Text.Match
-- Description : Generic name matching (normalize → exact → unambiguous substring).
--
-- A pure text utility with no domain semantics. Used to resolve a user-supplied
-- (possibly LLM-produced) name to one of a known set of named values.
module Data.Text.Match
  ( MatchResult (..),
    matchByName,
    normalizeName,
  )
where

import RIO
import qualified RIO.Text as T

-- | Result of matching a query against a candidate set.
data MatchResult a = Matched a | Ambiguous [a] | NoMatch
  deriving (Show, Eq)

-- | Normalize for comparison: trim, casefold, collapse internal whitespace.
normalizeName :: Text -> Text
normalizeName = T.unwords . T.words . T.toCaseFold . T.strip

-- | Match @query@ against @candidates@ by a name projection.
--
-- Exact (normalized) match wins. If there is no exact match, an unambiguous
-- substring match is used. Ties yield 'Ambiguous'; nothing yields 'NoMatch'.
-- Cross-lingual mapping is NOT attempted here — callers rely on the LLM to
-- return the canonical name, which then matches exactly.
matchByName :: (a -> Text) -> Text -> [a] -> MatchResult a
matchByName name query candidates =
  case exact of
    [x] -> Matched x
    (_ : _) -> Ambiguous exact
    [] -> case subs of
      [x] -> Matched x
      (_ : _) -> Ambiguous subs
      [] -> NoMatch
  where
    q = normalizeName query
    exact = [c | c <- candidates, normalizeName (name c) == q]
    subs
      | T.null q = []
      | otherwise = [c | c <- candidates, q `T.isInfixOf` normalizeName (name c)]
```

- [ ] **Step 4: Run unit test, verify pass.**

- [ ] **Step 5: Write property test** — `test/Data/Text/MatchPropertySpec.hs`

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Text.MatchPropertySpec (spec) where

import Data.Text.Match (MatchResult (..), matchByName, normalizeName)
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "Data.Text.Match properties" $ do
  it "a unique non-blank name matches itself (any casing)" $
    property $ \(s :: String) ->
      let n = T.pack s
       in not (T.null (normalizeName n)) ==>
            matchByName id (T.toUpper n) [n] === Matched n
  it "normalizeName is idempotent" $
    property $ \(s :: String) ->
      let n = T.pack s in normalizeName (normalizeName n) === normalizeName n
  it "duplicate identical names are Ambiguous" $
    property $ \(s :: String) ->
      let n = T.pack s
       in not (T.null (normalizeName n)) ==>
            matchByName id n [n, n] === Ambiguous [n, n]
```

- [ ] **Step 6: Run both, verify pass. Then `just check`.**

- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat(util): generic name matcher Data.Text.Match"`

---

## Task 2: `Infrastructure.Llm` — provider interface + OpenAI-compatible client

**Files:**
- Create: `src/Infrastructure/Llm/Provider.hs`, `src/Infrastructure/Llm/OpenAICompat.hs`
- Test: `test/Infrastructure/Llm/OpenAICompatSpec.hs`

- [ ] **Step 1: Implement the provider interface** — `src/Infrastructure/Llm/Provider.hs`

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Llm.Provider
-- Description : LLM provider interface (record-of-functions), like RateProvider.
module Infrastructure.Llm.Provider
  ( LlmRole (..),
    LlmMessage (..),
    LlmRequest (..),
    LlmResponse (..),
    LlmClient (..),
  )
where

import Data.Aeson (Value)
import RIO

data LlmRole = System | User | Assistant
  deriving (Show, Eq)

data LlmMessage = LlmMessage
  { role :: !LlmRole,
    content :: !Text
  }
  deriving (Show, Eq)

-- | A single structured completion request. @jsonSchema@, when present, is sent
-- as an OpenAI @response_format@ json_schema; otherwise json_object is requested.
data LlmRequest = LlmRequest
  { messages :: ![LlmMessage],
    jsonSchema :: !(Maybe Value)
  }

-- | The assistant's raw text content (expected to be JSON).
newtype LlmResponse = LlmResponse
  { content :: Text
  }
  deriving (Show, Eq)

-- | Provider interface. One value per configured backend.
data LlmClient = LlmClient
  { modelName :: !Text,
    complete :: LlmRequest -> IO (Either Text LlmResponse)
  }
```

- [ ] **Step 2: Write failing test for the pure JSON helpers** — `test/Infrastructure/Llm/OpenAICompatSpec.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Llm.OpenAICompatSpec (spec) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import Infrastructure.Llm.OpenAICompat (decodeChatContent, encodeChatBody)
import Infrastructure.Llm.Provider (LlmMessage (..), LlmRequest (..), LlmRole (..))
import RIO
import qualified RIO.ByteString.Lazy as BL
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Llm.OpenAICompat" $ do
  describe "decodeChatContent" $ do
    it "extracts choices[0].message.content" $ do
      let body =
            Aeson.encode $
              object ["choices" .= [object ["message" .= object ["content" .= ("hi" :: Text)]]]]
      decodeChatContent body `shouldBe` Right "hi"
    it "errors on empty choices" $ do
      let body = Aeson.encode $ object ["choices" .= ([] :: [Value])]
      decodeChatContent body `shouldSatisfy` isLeft
    it "errors on non-JSON" $
      decodeChatContent "not json" `shouldSatisfy` isLeft
  describe "encodeChatBody" $
    it "includes model, messages, response_format, temperature 0" $ do
      let req = LlmRequest [LlmMessage User "hello"] Nothing
          body = encodeChatBody "qwen" req
          Just (v :: Value) = Aeson.decode body
      -- round-trips to an object carrying the model name
      (BL.length body > 0) `shouldBe` True
      case Aeson.encode v of s -> ("qwen" `BL.isInfixOf` s) `shouldBe` True
```

- [ ] **Step 3: Run it, verify fail** (module missing).

- [ ] **Step 4: Implement the client** — `src/Infrastructure/Llm/OpenAICompat.hs` (model the IO on `ECB.hs`; keep encode/decode pure and exported for tests)

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Llm.OpenAICompat
-- Description : OpenAI-compatible /chat/completions client (Ollama, vLLM, …).
module Infrastructure.Llm.OpenAICompat
  ( mkOpenAICompatClient,
    -- exported for tests
    encodeChatBody,
    decodeChatContent,
  )
where

import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import Infrastructure.Llm.Provider
  ( LlmClient (..),
    LlmMessage (..),
    LlmRequest (..),
    LlmResponse (..),
    LlmRole (..),
  )
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
  )
import qualified Network.HTTP.Client as HC
import Network.HTTP.Types.Status (statusCode)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

roleText :: LlmRole -> Text
roleText = \case
  System -> "system"
  User -> "user"
  Assistant -> "assistant"

-- | Build the /chat/completions request body (pure; deterministic).
encodeChatBody :: Text -> LlmRequest -> BL.ByteString
encodeChatBody model req =
  Aeson.encode $
    object $
      [ "model" .= model,
        "temperature" .= (0 :: Int),
        "stream" .= False,
        "messages" .= map msg req.messages,
        "response_format" .= responseFormat
      ]
  where
    msg m = object ["role" .= roleText m.role, "content" .= m.content]
    responseFormat = case req.jsonSchema of
      Nothing -> object ["type" .= ("json_object" :: Text)]
      Just sch -> object ["type" .= ("json_schema" :: Text), "json_schema" .= sch]

-- | Extract choices[0].message.content from a chat-completions response body.
decodeChatContent :: BL.ByteString -> Either Text Text
decodeChatContent body =
  case Aeson.eitherDecode body of
    Left e -> Left ("LLM: invalid JSON response: " <> T.pack e)
    Right v -> first T.pack (parseEither parse v)
  where
    parse = withObject "ChatResponse" $ \o -> do
      choices <- o .: "choices"
      case choices of
        [] -> fail "no choices"
        (c : _) -> do
          m <- withObject "choice" (.: "message") c
          withObject "message" (.: "content") m

-- | Construct an 'LlmClient' backed by an OpenAI-compatible endpoint.
mkOpenAICompatClient :: Text -> Text -> Text -> Int -> Manager -> LlmClient
mkOpenAICompatClient baseUrl model apiKey timeoutMs manager =
  LlmClient
    { modelName = model,
      complete = \req -> tryAsEither $ do
        initReq <- parseRequest (T.unpack (T.dropSuffix "/" baseUrl <> "/chat/completions"))
        let httpReq =
              initReq
                { method = "POST",
                  requestBody = RequestBodyLBS (encodeChatBody model req),
                  requestHeaders =
                    ("Content-Type", "application/json")
                      : [("Authorization", encodeUtf8 ("Bearer " <> apiKey)) | not (T.null apiKey)],
                  HC.responseTimeout = responseTimeoutMicro (timeoutMs * 1000)
                }
        resp <- httpLbs httpReq manager
        let code = statusCode (responseStatus resp)
        pure $
          if code >= 200 && code < 300
            then LlmResponse <$> decodeChatContent (responseBody resp)
            else Left ("LLM: HTTP " <> T.pack (show code))
    }
  where
    tryAsEither io = do
      r <- tryAny io
      pure $ case r of
        Left ex -> Left ("LLM: request failed: " <> T.pack (show ex))
        Right e -> e
```

- [ ] **Step 5: Run test, verify pass.** Fix the `Just (v ...)` incomplete-pattern warning in the test if `-Werror` complains (use a `case Aeson.decode body of Just v -> ...; Nothing -> expectationFailure ...`).

- [ ] **Step 6: `just check`, then commit** — `git commit -am "feat(llm): OpenAI-compatible LLM client + provider interface"`

---

## Task 3: `LlmConfig` in `Infrastructure.Config`

**Files:**
- Modify: `src/Infrastructure/Config.hs`
- Test: add to an existing config spec or create `test/Infrastructure/ConfigLlmSpec.hs`

- [ ] **Step 1: Write failing test** — `test/Infrastructure/ConfigLlmSpec.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ConfigLlmSpec (spec) where

import Data.Aeson (eitherDecode, object, (.=))
import Infrastructure.Config (LlmConfig (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "LlmConfig FromJSON" $ do
  it "parses full object" $ do
    let j = eitherDecode "{\"enabled\":true,\"base_url\":\"http://x/v1\",\"model\":\"m\",\"api_key\":\"k\",\"timeout_ms\":15000}"
    (fmap (.model) j) `shouldBe` Right ("m" :: Text)
  it "applies defaults for missing optional fields" $ do
    let j = eitherDecode "{}" :: Either String LlmConfig
    (fmap (.enabled) j) `shouldBe` Right False
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Add `LlmConfig`** to `src/Infrastructure/Config.hs` (place beside `ExchangeRateConfig`; add to the export list):

```haskell
-- | LLM provider configuration (OpenAI-compatible endpoint).
data LlmConfig = LlmConfig
  { enabled :: !Bool,
    baseUrl :: !Text,
    model :: !Text,
    apiKey :: !Text,
    timeoutMs :: !Int
  }
  deriving (Show, Eq, Generic)

instance FromJSON LlmConfig where
  parseJSON = withObject "LlmConfig" $ \v ->
    LlmConfig
      <$> v .:? "enabled" .!= False
      <*> v .:? "base_url" .!= "http://localhost:11434/v1"
      <*> v .:? "model" .!= "qwen2.5:7b-instruct"
      <*> v .:? "api_key" .!= ""
      <*> v .:? "timeout_ms" .!= 20000

instance ToJSON LlmConfig
```

- [ ] **Step 4: Add the field to `AppConfig`** and its FromJSON:
  - In `data AppConfig`: add `llm :: !LlmConfig` (after `banking`).
  - In `instance FromJSON AppConfig`: add `<*> v .:? "llm" .!= defaultLlmConfig` where `defaultLlmConfig = LlmConfig False "http://localhost:11434/v1" "qwen2.5:7b-instruct" "" 20000` (define near `defaultBankingConfig`; export it).

- [ ] **Step 5: Run test + `just build`, verify pass/compile.** (`AppConfig` now has a new field — the compiler will flag any exhaustive record construction; there are none outside FromJSON.)

- [ ] **Step 6: `just check`, commit** — `git commit -am "feat(config): add LlmConfig section"`

---

## Task 4: Wire `llmClient` into `AppEnv` (+ Main + Testkit)

**Files:**
- Modify: `src/Infrastructure/App.hs`, `app/Main.hs`, `test/Testkit/InMemoryEventStore.hs`

- [ ] **Step 1: Add field + capability to `src/Infrastructure/App.hs`:**
  - Import: `import Infrastructure.Llm.Provider (LlmClient)`.
  - Add to `data AppEnv`: `llmClient :: !(Maybe LlmClient),` (place after `telegramClientEnv`).
  - Add capability (near `HasTelegramClient`):
    ```haskell
    class HasLlmClient env where
      llmClientL :: Lens' env (Maybe LlmClient)

    instance HasLlmClient AppEnv where
      llmClientL = lens (.llmClient) (\x y -> x {llmClient = y})
    ```
  - Export `HasLlmClient (..)` and `llmClientL` in the module export list.
  - Extend `initializeAppEnv`: add a `Maybe LlmClient` parameter (append it as the **last** parameter, after `LinkCodeStore`), bind it, and set `llmClient = <param>` in the record.

- [ ] **Step 2: Update `app/Main.hs`:**
  - Imports: `import Infrastructure.Llm.OpenAICompat (mkOpenAICompatClient)`.
  - After the HTTP manager is created (the `httpManager <- liftIO newTlsManager` line ~349), build the client:
    ```haskell
    let llmClient =
          if config.llm.enabled
            then Just (mkOpenAICompatClient config.llm.baseUrl config.llm.model config.llm.apiKey config.llm.timeoutMs httpManager)
            else Nothing
    ```
    (Reuse the existing `httpManager`; it is a shared TLS manager.)
  - Pass `llmClient` as the new final argument to `initializeAppEnv` at the construction call site (~line 372).

- [ ] **Step 3: Update `test/Testkit/InMemoryEventStore.hs`:** this file builds the test `AppEnv` by **direct record construction** (not `initializeAppEnv`), so add `llmClient = Nothing` to that record literal. (Expect a record-field addition here, not a positional argument.) Keep the default test env LLM-less; the integration test injects a stub via a record update (`withLlmClient`, Task 8).

- [ ] **Step 4: `just build`** — verify the whole tree compiles with the new parameter threaded through both call sites.

- [ ] **Step 5: `just test`** — verify existing tests still pass (no behavior change).

- [ ] **Step 6: `just check`, commit** — `git commit -am "feat(app): thread Maybe LlmClient through AppEnv"`

---

## Task 5: `TransactionIntent` — extraction type + decoder + schema

**Files:**
- Create: `src/Application/Services/TransactionPrompt/Intent.hs`
- Test: `test/Application/Services/TransactionPrompt/IntentSpec.hs`

- [ ] **Step 1: Write failing test** with golden fixtures for each kind + nulls + rejection of bad kind.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.TransactionPrompt.IntentSpec (spec) where

import qualified Data.Aeson as Aeson
import Application.Services.TransactionPrompt.Intent (IntentKind (..), TransactionIntent (..), decodeIntent)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "TransactionIntent decoding" $ do
  it "decodes an expense with nulls" $ do
    let j = "{\"kind\":\"expense\",\"amount\":\"123\",\"currency\":null,\"account\":\"Cash\",\"toAccount\":null,\"category\":\"Food\",\"description\":null,\"date\":null}"
    case decodeIntent j of
      Right i -> do
        i.kind `shouldBe` ExpenseKind
        i.amount `shouldBe` "123"
        i.account `shouldBe` Just "Cash"
        i.category `shouldBe` Just "Food"
      Left e -> expectationFailure (show e)
  it "decodes a transfer" $ do
    let j = "{\"kind\":\"transfer\",\"amount\":\"200\",\"account\":\"Cash\",\"toAccount\":\"Card\"}"
    (fmap (.kind) (decodeIntent j)) `shouldBe` Right TransferKind
  it "rejects an unknown kind" $
    decodeIntent "{\"kind\":\"nonsense\",\"amount\":\"1\",\"account\":\"x\"}" `shouldSatisfy` isLeft
  it "rejects non-JSON" $
    decodeIntent "oops" `shouldSatisfy` isLeft
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** — `src/Application/Services/TransactionPrompt/Intent.hs`. Use a flat record (optional fields as `Maybe Text`) + a decoded `IntentKind`; provide the JSON-schema `Value` for `response_format`; keep `decodeIntent :: BL.ByteString -> Either Text TransactionIntent`.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.TransactionPrompt.Intent
  ( IntentKind (..),
    TransactionIntent (..),
    decodeIntent,
    intentSchema,
  )
where

import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser, parseEither)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

data IntentKind = IncomeKind | ExpenseKind | TransferKind
  deriving (Show, Eq)

data TransactionIntent = TransactionIntent
  { kind :: !IntentKind,
    amount :: !Text,
    currency :: !(Maybe Text),
    account :: !(Maybe Text),
    toAccount :: !(Maybe Text),
    category :: !(Maybe Text),
    description :: !(Maybe Text),
    date :: !(Maybe Text)
  }
  deriving (Show, Eq)

parseKind :: Text -> Parser IntentKind
parseKind t = case T.toLower t of
  "income" -> pure IncomeKind
  "expense" -> pure ExpenseKind
  "transfer" -> pure TransferKind
  other -> fail ("unknown kind: " <> T.unpack other)

decodeIntent :: BL.ByteString -> Either Text TransactionIntent
decodeIntent bs = case Aeson.eitherDecode bs of
  Left e -> Left ("intent: invalid JSON: " <> T.pack e)
  Right v -> first T.pack (parseEither parse v)
  where
    parse = withObject "TransactionIntent" $ \o -> do
      k <- o .: "kind" >>= parseKind
      TransactionIntent k
        <$> o .: "amount"
        <*> o .:? "currency"
        <*> o .:? "account"
        <*> o .:? "toAccount"
        <*> o .:? "category"
        <*> o .:? "description"
        <*> o .:? "date"

-- | JSON schema value sent as response_format.json_schema (best-effort; servers
-- that ignore it still get the shape from the prompt text).
intentSchema :: Value
intentSchema =
  object
    [ "name" .= ("transaction_intent" :: Text),
      "schema"
        .= object
          [ "type" .= ("object" :: Text),
            "required" .= (["kind", "amount"] :: [Text]),
            "properties"
              .= object
                [ "kind" .= object ["type" .= ("string" :: Text), "enum" .= (["income", "expense", "transfer"] :: [Text])],
                  "amount" .= strType,
                  "currency" .= nullableStr,
                  "account" .= nullableStr,
                  "toAccount" .= nullableStr,
                  "category" .= nullableStr,
                  "description" .= nullableStr,
                  "date" .= nullableStr
                ]
          ]
    ]
  where
    strType = object ["type" .= ("string" :: Text)]
    nullableStr = object ["type" .= (["string", "null"] :: [Text])]
```

- [ ] **Step 4: Run test, verify pass. `just check`, commit** — `git commit -am "feat(llm): TransactionIntent extraction type + decoder + schema"`

---

## Task 6: `Prompt` — multilingual system prompt builder

**Files:**
- Create: `src/Application/Services/TransactionPrompt/Prompt.hs`
- Test: `test/Application/Services/TransactionPrompt/PromptSpec.hs`

Define `PromptContext` here (shared with Resolve — see Task 7; if you prefer, put `PromptContext` in `Resolve.hs` and import it here — pick one home and import). This plan puts `PromptContext` in `Prompt.hs` and `Resolve.hs` imports it.

- [ ] **Step 1: Write failing test** — assert the built messages embed account names, category names, the "any language" instruction, and the ISO current date.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.TransactionPrompt.PromptSpec (spec) where

import Application.Services.TransactionPrompt.Prompt (PromptContext (..), buildMessages)
import Infrastructure.Llm.Provider (LlmMessage (..), LlmRole (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec

ctx :: PromptContext
ctx = PromptContext
  { accountNames = ["Cash", "Card"],
    incomeCategoryNames = ["Salary"],
    expenseCategoryNames = ["Food", "Transport"],
    labelNames = []
  }

spec :: Spec
spec = describe "buildMessages" $ do
  let msgs = buildMessages ctx "2026-07-01" "готівка 123 їжа"
      sys = maybe "" (.content) (find ((== System) . (.role)) msgs)
      usr = maybe "" (.content) (find ((== User) . (.role)) msgs)
  it "includes the account names" $ ("Cash" `T.isInfixOf` sys) `shouldBe` True
  it "includes the category names" $ ("Food" `T.isInfixOf` sys) `shouldBe` True
  it "mentions multilingual mapping" $ ("language" `T.isInfixOf` T.toLower sys) `shouldBe` True
  it "includes today's date" $ ("2026-07-01" `T.isInfixOf` sys) `shouldBe` True
  it "passes the raw text as the user message" $ usr `shouldBe` "готівка 123 їжа"
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** — `src/Application/Services/TransactionPrompt/Prompt.hs`. Build a `System` message with task description, the exact JSON shape, the user's names, the multilingual + date + formatting instructions, and 3–4 few-shot examples (include one Ukrainian). Then the raw text as a `User` message. Keep the schema text in sync with `Intent`.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.TransactionPrompt.Prompt
  ( PromptContext (..),
    buildMessages,
  )
where

import Infrastructure.Llm.Provider (LlmMessage (..), LlmRole (..))
import RIO
import qualified RIO.Text as T

data PromptContext = PromptContext
  { accountNames :: ![Text],
    incomeCategoryNames :: ![Text],
    expenseCategoryNames :: ![Text],
    labelNames :: ![Text]
  }
  deriving (Show, Eq)

buildMessages :: PromptContext -> Text -> Text -> [LlmMessage]
buildMessages ctx todayIso userText =
  [ LlmMessage System (systemPrompt ctx todayIso),
    LlmMessage User userText
  ]

systemPrompt :: PromptContext -> Text -> Text
systemPrompt ctx today =
  T.unlines
    [ "You convert a personal-finance note into a single JSON object describing one transaction.",
      "Today's date is " <> today <> ".",
      "",
      "Output ONLY a JSON object with these keys:",
      "  kind: \"income\" | \"expense\" | \"transfer\"",
      "  amount: decimal number as a string, '.' decimal separator",
      "  currency: one of UAH,USD,EUR,GBP or null",
      "  account: the account the money leaves (expense) or enters (income); source for transfer",
      "  toAccount: destination account for transfer, else null",
      "  category: spending/earning category, else null; ignored for transfer",
      "  description: short note in the user's original language, or null",
      "  date: absolute ISO YYYY-MM-DD (resolve 'yesterday' etc. using today's date), or null",
      "",
      "The user may write in ANY language. Map their words to exactly one of the",
      "names listed below and return that name VERBATIM as shown. If nothing fits a",
      "category, use null (the system will pick a default).",
      "",
      "Accounts: " <> commas ctx.accountNames,
      "Income categories: " <> commas ctx.incomeCategoryNames,
      "Expense categories: " <> commas ctx.expenseCategoryNames,
      labelsLine ctx.labelNames,
      "",
      "Examples:",
      "  'cash 123 food' -> {\"kind\":\"expense\",\"amount\":\"123\",\"currency\":null,\"account\":\"Cash\",\"toAccount\":null,\"category\":\"Food\",\"description\":null,\"date\":null}",
      "  'salary 5000 to bank' -> {\"kind\":\"income\",\"amount\":\"5000\",\"currency\":null,\"account\":\"Bank\",\"toAccount\":null,\"category\":\"Salary\",\"description\":null,\"date\":null}",
      "  'move 200 from cash to card' -> {\"kind\":\"transfer\",\"amount\":\"200\",\"currency\":null,\"account\":\"Cash\",\"toAccount\":\"Card\",\"category\":null,\"description\":null,\"date\":null}",
      "  'готівка 123 їжа' -> {\"kind\":\"expense\",\"amount\":\"123\",\"currency\":null,\"account\":\"Cash\",\"toAccount\":null,\"category\":\"Food\",\"description\":null,\"date\":null}"
    ]
  where
    commas = T.intercalate ", "
    labelsLine [] = "Labels: (none)"
    labelsLine ls = "Labels: " <> commas ls
```

- [ ] **Step 4: Run test, verify pass. `just check`, commit** — `git commit -am "feat(llm): multilingual transaction prompt builder"`

---

## Task 7: `Resolve` — pure intent→command resolution

**Files:**
- Create: `src/Application/Services/TransactionPrompt/Resolve.hs`
- Test: `test/Application/Services/TransactionPrompt/ResolveSpec.hs`

`Resolve` takes the *rich* context (ids + names + currencies) and a decoded intent and produces a `Resolved` value plus an interpretation string, or a `ResolveError` (field + message) for the 400 path. It is pure and the heart of the accuracy/safety logic.

Rich context type (define here):

```haskell
data ResolveContext = ResolveContext
  { accounts :: ![(AccountId, Text, Currency)],          -- id, name, native currency
    incomeCategories :: ![(CategoryId, Text)],
    expenseCategories :: ![(CategoryId, Text)],
    labels :: ![(LabelId, Text)],
    defaultIncomeCategory :: !(Maybe CategoryId),
    defaultExpenseCategory :: !(Maybe CategoryId)
  }

data Resolved
  = ResolvedIncome  { account :: AccountId, total :: Money, allocations :: Allocations, labelSet :: Set LabelId, description :: Text, date :: Maybe UTCTime }
  | ResolvedExpense { account :: AccountId, total :: Money, allocations :: Allocations, labelSet :: Set LabelId, description :: Text, date :: Maybe UTCTime }
  | ResolvedTransfer { source :: AccountId, target :: AccountId, amount :: Money, labelSet :: Set LabelId, description :: Text, date :: Maybe UTCTime }

data ResolveError = ResolveError { field :: Text, message :: Text }
```

`resolveIntent :: ResolveContext -> UTCTime -> Text -> TransactionIntent -> Either ResolveError (Resolved, Text)`
(the last `Text` is the interpretation; `UTCTime` is "now" for the date default; the `Text` arg is the original prompt for the description fallback.)

Resolution steps (in order, short-circuiting to `ResolveError`):
1. **amount**: `T.replace "," "." intent.amount`, `readMaybe`→`Rational`; must be `> 0`; build `Money` after currency resolved.
2. **account(s)**: `matchByName (\(_,n,_)->n) name accounts`; `Matched (id,_,cur)`; `NoMatch`→ error `"account"` listing names; `Ambiguous`→ error. For transfer resolve both `account` and `toAccount`.
3. **currency**: if `intent.currency` present → `parseCurrency`; else the resolved account's native currency (source for expense, target for income; for transfer use source's currency for the amount).
4. **category** (income/expense only): if `intent.category` present → `matchByName` over the kind's list → `Matched id`; else/`NoMatch`/`Ambiguous` → the kind's `defaultXCategory` (`Maybe`); if that is `Nothing` → error `"category"`.
5. **allocations**: `mkAllocation catId money` then `mkAllocations` (income bucket for income, expense bucket for expense); on `Left DomainError` → `ResolveError "allocations" (textDisplay err)` (or `tshow`).
6. **labels**: best-effort `matchByName` per token — for v1 there is no label token in the schema, so `labelSet = mempty` (keep the field for future; do not fail).
7. **date**: if `intent.date` present → parse ISO `YYYY-MM-DD` (`parseTimeM True defaultTimeLocale "%Y-%m-%d"`), set to `Just utc`; else `Nothing` (service passes `Nothing`, existing write path defaults to now). Do **not** reject future here (the write path does).
8. **interpretation**: e.g. `"Expense 123 UAH from ‘Cash’, category Food"` built from resolved names/amount.

- [ ] **Step 1: Write failing tests** covering: expense happy path; income; transfer; unknown account→Left "account"; ambiguous account→Left "account"; unknown category→default "Other" used; missing default+unknown category→Left "category"; comma-decimal amount normalized; non-positive amount→Left "amount"; ISO date parsed; explicit currency honored; currency defaults to account currency. Use `Testkit.Helpers` mock ids (`mockAccountIdN`, `mockCategoryIdN`) and `Core.Currency`.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `resolveIntent` per the steps above. Keep it total; return `Either ResolveError (Resolved, Text)`.

- [ ] **Step 4: Run tests, verify pass.**

- [ ] **Step 5: Add a property** (e.g. "any amount with a comma resolves identically to the same amount with a dot"). Run.

- [ ] **Step 6: `just check`, commit** — `git commit -am "feat(llm): pure intent resolution against user data"`

---

## Task 8: `TransactionPromptService` — orchestration (gather → call → retry → commit)

**Files:**
- Create: `src/Application/Services/TransactionPromptService.hs`, `test/Testkit/Llm.hs`
- Test: `test/Integration/TransactionPromptIntegrationSpec.hs`

Service responsibilities (in `AppM`):
- `gatherContext :: UserId -> AppM (PromptContext, ResolveContext)` — `runDb (getUserRegularAccounts uid)` → accounts (name + `moneyCurrency balance`); `getConfigurationForUser uid` → income/expense category `(id,name)` lists from `dictionaries` via `incomeCategoryDictId`/`expenseCategoryDictId` (+ `unEntryName`), `defaultIncomeCategory`/`defaultExpenseCategory`, labels via `labelsDictId`. Build both the `PromptContext` (names only) and `ResolveContext` (ids+names+currency).
- `promptTransaction :: UserId -> Text -> AppM PromptOutcome`:
  1. `client <- view llmClientL` → if `Nothing`, `throwIO (err503 { errBody = ... })`.
  2. `now <- liftIO getCurrentTime`; `today = formatTime iso now`.
  3. `msgs = buildMessages promptCtx today text`.
  4. call `client.complete (LlmRequest msgs (Just intentSchema))`; on `Left _`, `throwIO err502`.
  5. `decodeIntent`; on `Left`, retry once with an appended `User` "Return only valid JSON matching the schema."; on second `Left`, `throwIO err502`.
  6. `resolveIntent resolveCtx now text intent`; on `Left (ResolveError f m)`, `throwDomainError (ValidationErr (mkValidationError f m text))`.
  7. dispatch on `Resolved`: call `TransactionService.initiate{Income,Expense,Transfer}` with the resolved args; on `Left err`, `throwDomainError err`; on `Right (txId, tx)` return `PromptOutcome interpretation txId tx`.

Return a small `PromptOutcome { interpretation :: Text, txId :: TransactionId, tx :: TransactionData }` that the Web layer maps to the DTO.

- [ ] **Step 1: Create the stub client helper** — `test/Testkit/Llm.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Testkit.Llm (constLlmClient, queueLlmClient, withLlmClient) where

import Infrastructure.App (AppEnv (..))
import Infrastructure.Llm.Provider (LlmClient (..), LlmResponse (..))
import RIO

-- | A client that always returns the same JSON content.
constLlmClient :: Text -> LlmClient
constLlmClient c = LlmClient "stub" (\_ -> pure (Right (LlmResponse c)))

-- | A client that returns successive contents (for retry tests); then errors.
queueLlmClient :: [Text] -> IO LlmClient
queueLlmClient xs = do
  ref <- newIORef xs
  pure $ LlmClient "stub" $ \_ -> do
    cur <- readIORef ref
    case cur of
      (h : t) -> writeIORef ref t >> pure (Right (LlmResponse h))
      [] -> pure (Left "stub exhausted")

withLlmClient :: LlmClient -> AppEnv -> AppEnv
withLlmClient c env = env {llmClient = Just c}
```

- [ ] **Step 2: Write failing integration test** — `test/Integration/TransactionPromptIntegrationSpec.hs`. Mirror `TransactionAmendmentIntegrationSpec` structure: `createTestAppEnvWithProcessManager`, seed a user + a regular account + configuration (reuse `Testkit.Fixtures` — `createDefaultAccount`, `userExternalAccountId`, and whatever seeds a user's configuration; check fixtures for a config seeder), inject the stub via `withLlmClient (constLlmClient expenseJson) env`, then `runAppM env (TransactionPromptService.promptTransaction uid "cash 123 food")` and assert the returned `TransactionData` (amount, source account, expense allocation category). Add cases: unknown account (stub returns account "Nope") → expect a thrown 400 (catch `ServerError`/`DomainError` mapping); unknown category → committed with default; `llmClient=Nothing` → 503.

  > NOTE for the implementer: inspect `test/Testkit/Fixtures.hs` for the exact user/account/configuration seeding helpers and match their signatures. If a helper to seed a user's default configuration does not exist, seed it via `ConfigurationService` default-seeding in the test setup.

- [ ] **Step 3: Run, verify fail.**

- [ ] **Step 4: Implement `TransactionPromptService`.** Use `getConfigurationForUser`, `runDb (getUserRegularAccounts uid)`, `moneyCurrency`, dictionary lookups, and the Servant error throws described above. For ISO formatting use `Data.Time.Format` (`formatTime defaultTimeLocale "%Y-%m-%d"`).

- [ ] **Step 5: Run integration test, verify pass.**

- [ ] **Step 6: `just check`, commit** — `git commit -am "feat(llm): transaction prompt orchestration service"`

---

## Task 9: Web endpoint `POST /api/prompt`

**Files:**
- Create: `src/Web/API/PromptAPI.hs`
- Modify: `src/Web/API.hs`
- Test: extend `test/Integration/TransactionPromptIntegrationSpec.hs` with an HTTP-level case (optional; the service-level cases already cover logic).

- [ ] **Step 1: Implement `src/Web/API/PromptAPI.hs`:**

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.API.PromptAPI (PromptAPI, promptServer) where

import qualified Application.Services.TransactionPromptService as PromptService
import Data.Aeson (FromJSON, ToJSON (..), object, (.=))
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types (TransactionResponse, fromTransactionData)

type PromptAPI =
  AuthProtect "jwt"
    :> "api"
    :> "prompt"
    :> ReqBody '[JSON] PromptRequest
    :> Post '[JSON] PromptResponse

newtype PromptRequest = PromptRequest {text :: Text}
  deriving (Show, Eq, Generic)

instance FromJSON PromptRequest

instance ToJSON PromptRequest

-- | kind-tagged result. Only the transaction variant exists today.
data PromptResponse = TransactionResult
  { interpretation :: Text,
    transaction :: TransactionResponse
  }
  deriving (Show, Eq, Generic)

instance ToJSON PromptResponse where
  toJSON r =
    object
      [ "kind" .= ("transaction" :: Text),
        "interpretation" .= r.interpretation,
        "transaction" .= r.transaction
      ]

promptServer :: ServerT PromptAPI AppM
promptServer = promptHandler

promptHandler :: AuthenticatedUser -> PromptRequest -> AppM PromptResponse
promptHandler user req = do
  outcome <- PromptService.promptTransaction user.userId req.text
  pure $
    TransactionResult
      outcome.interpretation
      (fromTransactionData outcome.txId outcome.tx)
```

- [ ] **Step 2: Wire into `src/Web/API.hs`:** add `PromptAPI` to `type API` (e.g. after `TransactionAPI`) and `promptServer` to `server` in the matching position. Add `import Web.API.PromptAPI (PromptAPI, promptServer)`.

- [ ] **Step 3: `just build`** — verify Servant type/`server` shapes line up (order of `:<|>` must match).

- [ ] **Step 4:** (Optional) add an hspec-wai HTTP case posting `{"text":"cash 123 food"}` with auth headers, asserting `200` and the JSON `kind`/`interpretation` fields. Reuse the auth/token helpers from `Testkit.TransactionEditFixture`. Inject the stub client into the app's env (may require a test app builder that sets `llmClient`; if the hspec-wai app builder can't inject a stub, keep coverage at the service level and skip this).

- [ ] **Step 5: `just test`, `just check`, commit** — `git commit -am "feat(web): POST /api/prompt endpoint"`

---

## Task 10: Config YAML + docs

**Files:**
- Modify: `config/local.yaml`, `config/test.yaml`, `config/prod.yaml`, `docs/architecture.md`

- [ ] **Step 1: Add to `config/local.yaml`:**
  ```yaml
  llm:
    enabled: ${LLM_ENABLED:-true}
    base_url: ${LLM_BASE_URL:-http://localhost:11434/v1}
    model: ${LLM_MODEL:-qwen2.5:7b-instruct}
    api_key: ${LLM_API_KEY:-}
    timeout_ms: ${LLM_TIMEOUT_MS:-20000}
  ```

- [ ] **Step 2: Add to `config/test.yaml`** with `enabled: false` (tests inject a stub):
  ```yaml
  llm:
    enabled: false
    base_url: http://localhost:11434/v1
    model: qwen2.5:7b-instruct
    api_key: ""
    timeout_ms: 20000
  ```

- [ ] **Step 3: Add to `config/prod.yaml`** (all from env; `enabled` default false unless configured):
  ```yaml
  llm:
    enabled: ${LLM_ENABLED:-false}
    base_url: ${LLM_BASE_URL:-http://localhost:11434/v1}
    model: ${LLM_MODEL:-qwen2.5:7b-instruct}
    api_key: ${LLM_API_KEY:-}
    timeout_ms: ${LLM_TIMEOUT_MS:-20000}
  ```

- [ ] **Step 4:** Add one line to `docs/architecture.md` documenting the `POST /api/prompt` endpoint and the `Infrastructure.Llm` provider (mirror how banking/exchange-rate providers are described).

- [ ] **Step 5:** `just run` locally is optional; if Ollama is running, `curl -H "Authorization: Bearer <jwt>" -d '{"text":"cash 123 food"}' localhost:<port>/api/prompt` to smoke-test. Otherwise rely on tests.

- [ ] **Step 6: Commit** — `git commit -am "chore(config): add llm section + docs"`

---

## Task 11: Final verification

- [ ] **Step 1:** `just rebuild` (clean + `-fci`) — definitive `-Werror` check across lib+exe+test (warm cache can mask warnings).
- [ ] **Step 2:** `just test` — full suite green.
- [ ] **Step 3:** `just check` — ormolu + hlint clean (no new suppressions).
- [ ] **Step 4:** Review the diff for layering: `Domain.*` unchanged; no new `DomainError` constructor; `Application` imports only `Domain`/`Infrastructure`; `Infrastructure.Llm` imports no `Application`/`Web`.
- [ ] **Step 5:** Open the PR: `gh pr create --base master --title "feat(llm): natural-language transaction prompting (#86)" --body "Implements #86. See docs/specs/2026-07-01-llm-transaction-prompting-design.md"`. Do this only when the user asks to push/PR.

---

## Notes / gotchas for the implementer

- **`-Werror` via `-fci`**: incomplete patterns, unused imports, and redundant constraints fail the build. The `Just (v ...)` style in a test will warn — use explicit `case`/`maybe`.
- **`NoFieldSelectors`**: use `.field`; if you need a projection function, write a lambda (`\m -> m.content`).
- **Ordering in `Web.API`**: the `:<|>` order in `type API` and in `server` must match exactly, or Servant fails to typecheck with a confusing error.
- **`initializeAppEnv` is positional**: after appending the `Maybe LlmClient` parameter, `app/Main.hs` must pass it. The test kit (`test/Testkit/InMemoryEventStore.hs`) builds `AppEnv` by direct record construction, so it needs `llmClient = Nothing` added to the record instead. Both broken until updated — the failing build is your reminder (Task 4).
- **Transfers**: pass `Nothing` for the exchange-rate argument to `initiateTransfer`; a cross-currency prompt transfer that needs a rate will surface an existing `DomainError` → mapped response. That's acceptable for v1.
- **Fixtures**: Task 8 depends on the exact user/account/configuration seeding helpers in `test/Testkit/Fixtures.hs` — read them first and match signatures rather than guessing.
