---
status: in-progress
---

# Wire Telegram Bot into Application Startup — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Initialize and start the Telegram bot from `Main.hs`, with config-driven polling/webhook mode selection.

**Architecture:** Unify `BotConfig` into `TelegramConfig` (eliminating duplication), add `TVar BotState` to `AppEnv`, and start the bot alongside the HTTP server in `applicationMain`.

**Tech Stack:** Haskell, RIO, STM, Servant, hspec/QuickCheck

---

## Task 1: Add `telegramPollingTimeout` to `TelegramConfig`

**Files:**
- Modify: `src/Infrastructure/Auth/Telegram.hs` (lines 74-97)
- Modify: `config/local.yaml` (line 74)
- Modify: `config/test.yaml` (line 74)
- Modify: `config/prod.yaml` (line 62)
- Test: `test/Infrastructure/Auth/TelegramSpec.hs`

**Step 1: Write failing test for the new field**

In `test/Infrastructure/Auth/TelegramSpec.hs`, add a test inside the existing `describe "TelegramConfig"` block:

```haskell
    it "has correct default polling timeout of 30 seconds" $ do
      telegramPollingTimeout testConfig `shouldBe` 30
```

Update `testConfig` to include the new field:

```haskell
testConfig :: TelegramConfig
testConfig =
  TelegramConfig
    { telegramBotToken = "123456789:ABCdefGHIjklMNOpqrsTUVwxyz",
      telegramBotUsername = "test_bot",
      telegramAuthMaxAge = 86400,
      telegramWebhookUrl = Nothing,
      telegramUsePolling = True,
      telegramPollingTimeout = 30
    }
```

**Step 2: Run test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option='/Telegram/'`
Expected: Compilation error — `telegramPollingTimeout` does not exist on `TelegramConfig`.

**Step 3: Add `telegramPollingTimeout` field to `TelegramConfig`**

In `src/Infrastructure/Auth/Telegram.hs`, add field to `TelegramConfig`:

```haskell
data TelegramConfig = TelegramConfig
  { telegramBotToken :: Text,
    telegramBotUsername :: Text,
    telegramAuthMaxAge :: NominalDiffTime,
    telegramWebhookUrl :: Maybe Text,
    telegramUsePolling :: Bool,
    telegramPollingTimeout :: Int
  }
  deriving (Show, Eq, Generic)
```

Update the `FromJSON` instance:

```haskell
instance FromJSON TelegramConfig where
  parseJSON = withObject "TelegramConfig" $ \v ->
    TelegramConfig
      <$> v .: "bot_token"
      <*> v .: "bot_username"
      <*> (secondsToNominalDiffTime . fromIntegral <$> (v .:? "auth_max_age_seconds" .!= (86400 :: Int)))
      <*> v .:? "webhook_url"
      <*> v .:? "use_polling" .!= True
      <*> v .:? "polling_timeout" .!= 30
```

Update `defaultTelegramConfig`:

```haskell
defaultTelegramConfig :: Text -> Text -> TelegramConfig
defaultTelegramConfig botToken botUsername =
  TelegramConfig
    { telegramBotToken = botToken,
      telegramBotUsername = botUsername,
      telegramAuthMaxAge = 86400,
      telegramWebhookUrl = Nothing,
      telegramUsePolling = True,
      telegramPollingTimeout = 30
    }
```

**Step 4: Add `polling_timeout` to YAML config files**

In `config/local.yaml` and `config/test.yaml`, add after `use_polling: true`:
```yaml
  polling_timeout: 30
```

In `config/prod.yaml`, add after `use_polling: false`:
```yaml
  polling_timeout: "${TELEGRAM_POLLING_TIMEOUT:-30}"
```

**Step 5: Run tests to verify they pass**

Run: `cabal test all --test-option='--match' --test-option='/Telegram/'`
Expected: All Telegram tests pass.

**Step 6: Build the full project**

Run: `just build`
Expected: Clean build (no errors, no new warnings).

**Step 7: Commit**

```bash
git add src/Infrastructure/Auth/Telegram.hs test/Infrastructure/Auth/TelegramSpec.hs config/local.yaml config/test.yaml config/prod.yaml
git commit -m "feat: add telegramPollingTimeout to TelegramConfig"
```

---

## Task 2: Remove `BotConfig` from `Telegram.Types`

**Files:**
- Modify: `src/Telegram/Types.hs` (lines 17, 39-55)
- Modify: `src/Telegram/Bot.hs` (lines 37, 49-50, 62-71)

**Step 1: Remove `BotConfig` from `Telegram.Types`**

In `src/Telegram/Types.hs`:
- Remove `BotConfig (..)` from the module export list
- Remove the entire `BotConfig` data type definition (lines 39-51) and its `ToJSON`/`FromJSON` instances (lines 53-55)
- Remove the `-- Bot Configuration` section header comment

**Step 2: Update `Telegram.Bot` to use `TelegramConfig`**

In `src/Telegram/Bot.hs`:

Replace the import:
```haskell
import Telegram.Types
```
with:
```haskell
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import Telegram.Types
```

Update `initBot` signature and body:
```haskell
initBot :: (MonadIO m) => TelegramConfig -> m (TVar BotState)
initBot _config = liftIO $ newTVarIO emptyBotState
  where
    emptyBotState = BotState mempty
```

Update `runBotPolling` signature and body:
```haskell
runBotPolling :: TelegramConfig -> TVar BotState -> AppM ()
runBotPolling config botState = do
  logInfo $ "Starting bot polling for @" <> display (telegramBotUsername config)
  liftIO $ threadDelay (telegramPollingTimeout config * 1000000)
  runBotPolling config botState
```

Update the module export list — replace `BotConfig` references if any (current exports reference `BotConfig` implicitly via types).

**Step 3: Build to verify no compilation errors**

Run: `just build`
Expected: Clean build. No references to `BotConfig` remain.

**Step 4: Run all tests**

Run: `just test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/Telegram/Types.hs src/Telegram/Bot.hs
git commit -m "refactor: remove BotConfig, use TelegramConfig in Telegram.Bot"
```

---

## Task 3: Add `TVar BotState` to `AppEnv`

**Files:**
- Modify: `src/Infrastructure/App.hs` (lines 72-218)

**Step 1: Add import for `BotState`**

In `src/Infrastructure/App.hs`, add:
```haskell
import Telegram.Types (BotState)
```

**Step 2: Add `appBotState` field to `AppEnv`**

After `appTelegramConfig` field:
```haskell
    -- | Telegram bot state (conversation tracking)
    appBotState :: !(TVar BotState)
```

**Step 3: Add `HasBotState` type class**

Add to module export list: `HasBotState (..)`.

Add after the `HasAuthConfig` instance:
```haskell
-- | Type class for environments that have Telegram bot state.
class HasBotState env where
  botStateL :: Lens' env (TVar BotState)

instance HasBotState AppEnv where
  botStateL = lens appBotState (\x y -> x {appBotState = y})
```

**Step 4: Update `initializeAppEnv` to accept `TVar BotState`**

Add parameter and field assignment:

```haskell
initializeAppEnv ::
  LogFunc ->
  AppConfig ->
  DatabaseConfig ->
  ConnectionPool ->
  AccountingVersionedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  AccountingGlobalEventStoreReader IO ->
  TVar AccountSummaryReadModel ->
  TVar TransactionSummaryReadModel ->
  TVar UserSummaryReadModel ->
  JWTConfig ->
  OAuthConfig ->
  TelegramConfig ->
  TVar BotState ->
  AppEnv
initializeAppEnv logFunc config dbConfig pool writer reader globalReader accountReadModel transactionReadModel userReadModel jwtConfig oauthConfig telegramConfig botState =
  AppEnv
    { appLogFunc = logFunc,
      appConfig = config,
      appDatabaseConfig = dbConfig,
      appDbPool = pool,
      appEventStoreWriter = writer,
      appEventStoreReader = reader,
      appGlobalEventStoreReader = globalReader,
      appAccountSummaryReadModel = accountReadModel,
      appTransactionSummaryReadModel = transactionReadModel,
      appUserSummaryReadModel = userReadModel,
      appJWTConfig = jwtConfig,
      appOAuthConfig = oauthConfig,
      appTelegramConfig = telegramConfig,
      appBotState = botState
    }
```

**Step 5: Build to verify**

Run: `just build`
Expected: Compilation error in `Main.hs` only (missing argument to `initializeAppEnv`). This is expected — we fix it in Task 4.

**Step 6: Commit (with build warning acknowledged)**

```bash
git add src/Infrastructure/App.hs
git commit -m "feat: add TVar BotState and HasBotState to AppEnv"
```

---

## Task 4: Wire bot initialization into `Main.hs`

**Files:**
- Modify: `app/Main.hs` (lines 89-367)

**Step 1: Add imports**

Add to `app/Main.hs`:
```haskell
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import Telegram.Bot (initBot, runBotPolling)
```

**Step 2: Initialize bot state in `initializeEnvironment`**

After step 5 (auth configurations), add:
```haskell
  -- 5b. Initialize Telegram bot
  logInfo "Initializing Telegram bot..."
  botState <- liftIO $ initBot telegramConfig
  logInfo $ "Telegram bot initialized (polling: " <> displayShow (telegramUsePolling telegramConfig) <> ")"
```

Update the `initializeAppEnv` call to pass `botState` as the last argument:
```haskell
  let env =
        initializeAppEnv
          logFunc
          config
          configDbConfig
          pool
          writer
          reader
          globalReader
          accountSummaryReadModel
          transactionSummaryReadModel
          userSummaryReadModel
          jwtConfig
          oauthConfig
          telegramConfig
          botState
```

**Step 3: Start bot in `applicationMain`**

Replace the current `applicationMain` body (after the log banner and config display) with config-driven mode selection:

```haskell
applicationMain :: AppM ()
applicationMain = do
  logInfo "==================================="
  logInfo "  Accounting Backend Started"
  logInfo "==================================="

  config <- view appConfigL
  logInfo $ "Server Port: " <> displayShow (Config.serverPort $ appServer config)
  logInfo $ "Database: " <> displayText (Config.dbDatabase $ appDatabase config)

  env <- ask
  let telegramCfg = appTelegram config

  if telegramUsePolling telegramCfg
    then do
      logInfo "Telegram bot: polling mode"
      botState <- view botStateL
      liftIO $ race_ (runAppM env $ runBotPolling telegramCfg botState) (runServer env)
    else do
      logInfo "Telegram bot: webhook mode (ensure webhook endpoint is registered)"
      liftIO $ runServer env
```

This requires adding these imports to `Main.hs`:
```haskell
import Infrastructure.App (HasBotState (botStateL))
```

And `race_` from RIO (already available via RIO re-export).

**Step 4: Build the full project**

Run: `just build`
Expected: Clean build, no errors.

**Step 5: Run all tests**

Run: `just test`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add app/Main.hs
git commit -m "feat: wire Telegram bot initialization into Main.hs"
```

---

## Task 5: Update any remaining test helpers that construct `AppEnv`

**Files:**
- Search: `test/**/*.hs` for any direct `AppEnv` construction or `initializeAppEnv` calls

**Step 1: Find all test files referencing `AppEnv` or `initializeAppEnv`**

Run: `grep -r "initializeAppEnv\|AppEnv {" test/`

If any test constructs `AppEnv` directly, add the `botState` field/parameter. If none do (tests use mock event stores and don't build full `AppEnv`), skip this task.

**Step 2: Build and test**

Run: `just build && just test`
Expected: Clean build, all tests pass.

**Step 3: Commit (if changes were needed)**

```bash
git add test/
git commit -m "test: update test helpers for new AppEnv botState field"
```

---

## Task 6: Final verification and format/lint

**Step 1: Format**

Run: `just format`

**Step 2: Lint**

Run: `just lint`

**Step 3: Full test suite**

Run: `just test`

**Step 4: Fix any issues found by format/lint**

**Step 5: Final commit**

```bash
git add -A
git commit -m "chore: format and lint after telegram bot wiring"
```
