{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Main
-- Description : Application entry point and composition root
--
-- This module is the composition root for the accounting backend application.
-- It initializes all infrastructure components, wires them together, and starts
-- the application.
--
-- Responsibilities:
--   1. Configuration loading from YAML files
--   2. Logging infrastructure setup
--   3. Database connection pool creation
--   4. Event store initialization
--   5. Read model creation and registration
--   6. Process manager registration
--   7. Web server startup (when ready)
--   8. Graceful shutdown handling
--
-- Architecture Pattern:
--
-- This follows the "Composition Root" pattern where all dependencies are
-- created and wired together at the application's entry point. This ensures:
--   - Single place for dependency wiring
--   - Clear initialization order
--   - Proper resource cleanup
--   - Testability (can create test environments)
--
-- Startup Sequence:
--
-- 1. Load configuration from YAML file
-- 2. Setup structured logging
-- 3. Initialize database connection pool
-- 4. Run database migrations
-- 5. Create event store readers/writers
-- 6. Initialize read models
-- 7. Register event handlers (process managers, read model updaters)
-- 8. Start web server (Phase 6, when ready)
-- 9. Wait for shutdown signal
-- 10. Cleanup resources
--
-- Error Handling:
--
-- Startup errors are fatal and will cause the application to exit with
-- a non-zero status code. This follows the "fail fast" principle:
--   - Configuration errors: Exit immediately with clear message
--   - Database errors: Exit immediately (can't run without database)
--   - Migration errors: Exit immediately (schema issues)
--
-- Resource Management:
--
-- All resources are properly managed:
--   - Database connections: Connection pool with automatic cleanup
--   - Event store: Initialized once, shared across threads
--   - Read models: STM ensures thread-safe access
--   - Web server: Graceful shutdown on SIGTERM/SIGINT
--
-- Usage:
--
-- Development:
-- >>> cabal run backend -- --config config/test.yaml
--
-- Production:
-- >>> accounting --config config/prod.yaml
--
-- Environment Variables:
--   - CONFIG_FILE: Path to configuration file (default: config/local.yaml)
--   - All other env vars are consumed via ${VAR} substitution in YAML configs
module Main (main) where

-- Configuration

-- Database

-- Event Store

-- Application

import Application.LinkCodeStore (newLinkCodeStore)
import Application.ProcessManagers (transactionCancellationProcessManager, transactionMergeProcessManager, transferAmendmentProcessManager, transferProcessManager)
import Application.ReadModels.Account (countRegularAccounts)
import Application.ReadModels.Persist (initializePersistentReadModels, persistentReadModels)
import Application.ReadModels.Transaction (countTransactions)
import Application.ReadModels.User (countUsers)
import Application.Services.ConfigurationService (seedDefaultConfiguration)
import Application.Services.ExchangeRatePublisher (spawnRatePublisher)
import Data.Text.Display (displayText)
import qualified Data.Vault.Lazy as Vault
import Domain.ExchangeRate.Events (unProvider)
import Infrastructure.App
  ( AppEnv,
    AppM,
    BankingEnv (..),
    HasAppConfig (appConfigL),
    HasBotState (botStateL),
    HasVersionInfo (versionInfoL),
    appMetrics,
    bankingKeyRingFromConfig,
    initializeAppEnv,
    runAppM,
  )
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import qualified Infrastructure.Banking.Providers as BankProviders
import Infrastructure.Bootstrap (configureProcess)
import Infrastructure.Config
  ( AppConfig (..),
    DatabaseConfig (..),
    ExchangeRateConfig (..),
    LlmConfig (..),
    LoggingConfig (..),
    ServerConfig (..),
    loadConfigWithEnv,
  )
import Infrastructure.Database
  ( convertDatabaseConfig,
    createConnectionPool,
    defaultSqlEventStoreConfig,
    initializeDatabase,
    runDbDirect,
  )
import Infrastructure.Eventium
  ( accountingEventStoreWriter,
    accountingGlobalEventStoreReader,
    accountingVersionedEventStoreReader,
    liftGlobalReader,
    liftTaggedWriter,
    liftVersionedReader,
    wireProcessManager,
    wireProcessManagers,
  )
import Infrastructure.ExchangeRate.ECB (ecbProvider)
import Infrastructure.ExchangeRate.NBU (nbuProvider)
import Infrastructure.Llm.OpenAICompat (mkOpenAICompatClient)
import Infrastructure.Observability.Context (nilRequestContext)
import Infrastructure.Observability.Interpreter (mkTelemetry)
import Infrastructure.Observability.Logging (mkContextLogFunc, newStdoutLoggerSet, rioLevel)
import Infrastructure.Observability.Metrics (gaugeSample, registerGaugeCollector)
import Infrastructure.Version (VersionInfo, displayVersion, mkVersionInfo)
import Network.HTTP.Client.TLS (newTlsManager)
import RIO
import qualified RIO.Set as Set
import qualified RIO.Text as T
-- Web Server

-- System
import System.Environment (getArgs, lookupEnv)
import System.IO (hPutStrLn)
import System.Log.FastLogger (LoggerSet, pushLogStr)
import Telegram.Api (createTelegramClientEnv)
import Telegram.Bot (initBot, runBotPolling, setupBotCommands, setupWebhook)
import Web.Server (runServer)

-- -----------------------------------------------------------------------------
-- Main Entry Point
-- -----------------------------------------------------------------------------

-- | Application entry point.
--
-- This is the main function that:
--  1. Parses command-line arguments
--  2. Loads configuration
--  3. Initializes all components
--  4. Runs the application
--  5. Handles shutdown
--
-- Example:
-- >>> main
-- >>> -- Starts the application with default configuration
main :: IO ()
main = do
  -- Process-level IO setup (stdout/stderr encoding today; see module).
  -- Must run before any logger or handle write.
  configureProcess

  -- Parse command-line arguments
  args <- getArgs
  configPath <- getConfigPath args

  -- Load configuration (with environment variable substitution)
  configResult <- loadConfigWithEnv configPath
  config <- case configResult of
    Left err -> do
      hPutStrLn stderr $ "Failed to load configuration: " <> T.unpack err
      exitFailure
    Right cfg -> return cfg

  -- Build version info (reads APP_COMMIT_HASH env var)
  versionInfo <- mkVersionInfo

  -- Setup logging: exactly one 'LoggerSet' for the whole process, shared by
  -- the process-base 'LogFunc' built here and any request-scoped 'LogFunc'
  -- built later from a request's 'RequestContext' (both render through
  -- 'mkContextLogFunc' onto this same buffered sink).
  loggerSet <- newStdoutLoggerSet
  let baseLogFunc = mkContextLogFunc config.logging.format (rioLevel config.logging.level) nilRequestContext loggerSet

  -- Run application with RIO
  runRIO baseLogFunc $ do
    logInfo "Starting Accounting Backend..."
    logInfo $ "Environment: " <> displayShow config.environment

    -- Initialize application environment
    env <- initializeEnvironment loggerSet baseLogFunc config versionInfo

    -- Run application
    liftIO $ runAppM env applicationMain

-- | Get configuration file path from command-line args or environment.
--
-- Priority:
--  1. Command-line argument: --config <path>
--  2. Environment variable: CONFIG_FILE
--  3. Default: config/local.yaml
--
-- Example:
-- >>> getConfigPath ["--config", "config/prod.yaml"]
-- >>> "config/prod.yaml"
--
-- >>> getConfigPath []
-- >>> -- Reads CONFIG_FILE or defaults to "config/local.yaml"
getConfigPath :: [String] -> IO FilePath
getConfigPath args = case args of
  ["--config", path] -> return path
  "--config" : path : _ -> return path
  _ -> do
    maybeEnvPath <- lookupEnv "CONFIG_FILE"
    return $ fromMaybe "config/local.yaml" maybeEnvPath

-- | Initialize the application environment.
--
-- This function creates and initializes all application resources:
--  1. Database connection pool
--  2. Database schema (migrations)
--  3. Event store readers/writers
--  4. Read models
--  5. Process managers
--
-- Returns the fully initialized AppEnv ready for use.
--
-- Example:
-- >>> env <- initializeEnvironment loggerSet logFunc config versionInfo
-- >>> -- AppEnv ready to use
initializeEnvironment :: LoggerSet -> LogFunc -> AppConfig -> VersionInfo -> RIO LogFunc AppEnv
initializeEnvironment loggerSet logFunc config versionInfo = do
  logInfo "Initializing application environment..."

  -- 1. Initialize database connection pool
  logInfo "Creating database connection pool..."
  let dbConfigForPool = convertDatabaseConfig config.database
  pool <- liftIO $ createConnectionPool config.logging.format (rioLevel config.logging.level) loggerSet dbConfigForPool
  logInfo
    $ "Database pool created (size: "
    <> displayShow config.database.poolSize
    <> ")"

  -- 2. Run database migrations and initialization
  logInfo "Initializing database and running migrations..."
  liftIO $ initializeDatabase pool
  logInfo "Database initialized successfully"

  -- 3. Create event store readers/writers with the read-model publishers on the bus
  logInfo "Creating event store readers and writers..."
  let eventStoreConfig = defaultSqlEventStoreConfig
      -- Write-path telemetry: turns every persisted batch / write conflict
      -- into a metrics bump (the process-global, once-registered 'appMetrics')
      -- and a level-gated structured log line pushed through the same
      -- 'LoggerSet' as request-path logging.
      telemetry = mkTelemetry config.logging.format (rioLevel config.logging.level) (pushLogStr loggerSet) appMetrics
      sqlWriter =
        accountingEventStoreWriter
          telemetry
          eventStoreConfig
          ( wireProcessManagers
              [ wireProcessManager transferProcessManager,
                wireProcessManager transferAmendmentProcessManager,
                wireProcessManager transactionCancellationProcessManager,
                wireProcessManager transactionMergeProcessManager
              ]
          )
          -- Persistent (SQL) read models: applied + checkpointed in the write
          -- transaction via readModelPublisher (real global positions).
          (map snd persistentReadModels)
      sqlReader = accountingVersionedEventStoreReader eventStoreConfig
      sqlGlobalReader = accountingGlobalEventStoreReader eventStoreConfig
      -- Lift to IO by running through the connection pool
      writer = liftTaggedWriter pool sqlWriter
      reader = liftVersionedReader pool sqlReader
      globalReader = liftGlobalReader pool sqlGlobalReader
  logInfo "Event store configured"

  -- 4. Persistent (SQL) read models: migrate tables, then bring them up to date
  -- (or rebuild those named in REBUILD_READ_MODELS). Their live updates commit in
  -- the event-append transaction; this is the one-time backfill / bounded boot
  -- catch-up / on-demand rebuild path.
  logInfo "Migrating + catching up persistent read models..."
  liftIO $ initializePersistentReadModels pool sqlGlobalReader
  logInfo "Persistent read models up to date"

  -- Business metrics: scrape-time COUNT(*) on the read-model tables, exposed as
  -- gauges on /metrics (a recomputed snapshot, not an accumulated total — a
  -- read-model rebuild under changed rules can lower it, which a counter would
  -- misread as a reset). Wrapped so a DB error drops only the business series,
  -- never the operator metrics on the same exposition path.
  logInfo "Registering business metrics collector..."
  baseLogFunc <- view logFuncL
  liftIO
    $ registerGaugeCollector
    $ handleAny (\e -> runRIO baseLogFunc (logWarn ("business-metrics fetch failed: " <> displayShow e)) >> pure [])
    $ runDbDirect pool
    $ do
      u <- countUsers
      a <- countRegularAccounts
      t <- countTransactions
      pure
        [ gaugeSample "users" "Registered users" (fromIntegral u),
          gaugeSample "accounts" "Regular accounts" (fromIntegral a),
          gaugeSample "transactions" "Recorded transactions" (fromIntegral t)
        ]

  -- 5. Auth configurations (loaded from YAML config)
  logInfo "Auth configurations loaded from config file"
  let jwtConfig = config.auth
      oauthConfig = config.oauth
      telegramConfig = config.telegram

  -- 5b. Initialize Telegram bot
  logInfo "Initializing Telegram bot..."
  botState <- liftIO $ initBot telegramConfig
  logInfo $ "Telegram bot initialized (polling: " <> displayShow telegramConfig.usePolling <> ")"

  -- 5c. Create Telegram API client environment
  telegramClientEnv <-
    if T.null telegramConfig.botToken
      then do
        logWarn "Telegram bot token is empty, bot will be disabled"
        return Nothing
      else do
        cEnv <- liftIO $ createTelegramClientEnv telegramConfig.botToken
        logInfo "Telegram API client environment created"
        setupBotCommands cEnv
        -- Register webhook URL with Telegram when in webhook mode
        case telegramConfig.webhookUrl of
          Just url | not telegramConfig.usePolling -> setupWebhook cEnv url
          _ -> return ()
        return (Just cEnv)

  -- 6. Register process managers
  -- transferProcessManager is passed to accountingEventStoreWriter via transferManagerHandler
  logInfo "Process managers registered via event bus"

  -- 6b. Spawn background rate publisher (best-effort, app starts even if provider is unreachable).
  -- Historical rates survive restarts via the persistent @exchange_rates@ read
  -- model, caught up from persisted 'ExchangeRatesPublishedEvent's by
  -- 'initializePersistentReadModels' above.
  logInfo "Spawning exchange rate publisher..."
  rateProvider <- case unProvider config.exchangeRate.provider of
    "nbu" -> pure nbuProvider
    "ecb" -> pure ecbProvider
    unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
  -- Fire-and-forget: the publisher loop catches and logs its own errors and
  -- runs for the lifetime of the process, so we do not retain the Async handle.
  void
    $ liftIO
    $ spawnRatePublisher rateProvider writer reader pool logFunc
  logInfo $ "Exchange rate publisher running (" <> display config.exchangeRate.provider <> ")"

  -- 6c. Create HTTP manager for bank API calls
  logInfo "Creating HTTP manager..."
  httpManager <- liftIO newTlsManager

  -- LLM client for transaction prompting (reuses the shared TLS manager);
  -- Nothing when LLM support is disabled in config.
  let llmClient =
        if config.llm.enabled
          then Just (mkOpenAICompatClient config.llm.baseUrl config.llm.model config.llm.apiKey config.llm.timeoutMs httpManager)
          else Nothing

  -- 6d. Per-user bank-import serialization locks
  bankImportLocksVar <- liftIO $ newTVarIO Set.empty

  -- 6e. Banking token-encryption key ring (fails fast in prod on a
  -- missing/invalid key; uses a dev key with a warning in local/test).
  bankingKeyRing' <-
    liftIO $ bankingKeyRingFromConfig config.environment config.banking

  -- Assemble the bank provider registry from every provider compiled into
  -- this build, keeping only those enabled in @banking.providers@. See
  -- 'Infrastructure.Banking.Providers.buildRegistry' for the full assembly.
  let registry = BankProviders.buildRegistry config.banking httpManager
      bankingEnv' =
        BankingEnv
          { bankImportLocks = bankImportLocksVar,
            httpManager = httpManager,
            bankingKeyRing = bankingKeyRing',
            bankProviderRegistry = registry
          }

  -- 7. Build application environment
  linkCodeStore <- liftIO newLinkCodeStore
  -- Minted once here so every middleware/handler that reads or writes the
  -- per-request 'RequestContext' on a WAI request's 'Vault.Vault' agrees on
  -- the same key.
  contextVaultKey <- liftIO Vault.newKey
  let configDbConfig = config.database -- Infrastructure.Config.DatabaseConfig for AppEnv
      env =
        initializeAppEnv
          logFunc
          config
          configDbConfig
          pool
          writer
          reader
          globalReader
          jwtConfig
          oauthConfig
          telegramConfig
          botState
          telegramClientEnv
          versionInfo
          bankingEnv'
          linkCodeStore
          llmClient
          loggerSet
          nilRequestContext
          contextVaultKey
          appMetrics

  logInfo "Application environment initialized successfully"
  return env

-- -----------------------------------------------------------------------------
-- Application Main
-- -----------------------------------------------------------------------------

-- | Main application logic.
--
-- This is the core application loop. It:
--  1. Logs startup information
--  2. Starts the HTTP web server
--  3. Blocks until shutdown signal (SIGTERM/SIGINT)
--  4. Handles graceful shutdown
--
-- The web server:
--  - Listens on configured port (default: 8080)
--  - Serves REST API endpoints
--  - Handles CORS requests
--  - Logs all requests/responses
--  - Handles errors gracefully
--
-- Example:
-- >>> runAppM env applicationMain
-- >>> -- HTTP server running at http://0.0.0.0:8080
applicationMain :: AppM ()
applicationMain = do
  vi <- view versionInfoL
  logInfo "==================================="
  logInfo $ "  Accounting Backend " <> displayVersion vi
  logInfo "==================================="

  -- Seed default configuration if not present
  seedDefaultConfiguration

  -- Display configuration info
  config <- view appConfigL
  logInfo $ "Server Port: " <> displayShow config.server.port
  logInfo $ "Database: " <> displayText config.database.database

  -- Get the application environment
  env <- ask
  let telegramCfg = config.telegram

  if telegramCfg.usePolling
    then do
      logInfo "Telegram bot: polling mode"
      botState <- view botStateL
      liftIO $ race_ (runAppM env $ runBotPolling telegramCfg botState) (runServer env)
    else do
      logInfo "Telegram bot: webhook mode (ensure webhook endpoint is registered)"
      liftIO $ runServer env

-- -----------------------------------------------------------------------------
-- Utilities
-- -----------------------------------------------------------------------------
