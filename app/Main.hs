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

import Application.EventDispatch
  ( ReadModels (..),
    createReadModels,
    fromReadModels,
  )
import Application.LinkCodeStore (newLinkCodeStore)
import Application.ProcessManagers (transferProcessManager)
import Application.Services.ConfigurationService (seedDefaultConfiguration)
import Application.Services.ExchangeRatePublisher (spawnRatePublisher)
import Data.Text.Display (displayText)
import Domain.ExchangeRate.Events (unProvider)
import Infrastructure.App
  ( AppEnv,
    AppM,
    BankingEnv (..),
    HasAppConfig (appConfigL),
    HasBotState (botStateL),
    HasVersionInfo (versionInfoL),
    initializeAppEnv,
    runAppM,
  )
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import Infrastructure.Bootstrap (configureProcess)
import Infrastructure.Config
  ( AppConfig (..),
    ServerConfig (..),
    loadConfigWithEnv,
  )
import qualified Infrastructure.Config as Config
import Infrastructure.Database
  ( convertDatabaseConfig,
    createConnectionPool,
    defaultSqlEventStoreConfig,
    initializeDatabase,
  )
import Infrastructure.Eventium
  ( accountingEventStoreWriter,
    accountingGlobalEventStoreReader,
    accountingVersionedEventStoreReader,
    createReadModelHandlersFrom,
    liftGlobalReader,
    liftIOEventHandler,
    liftTaggedWriter,
    liftVersionedReader,
    replayWith,
    wireProcessManager,
  )
import Infrastructure.ExchangeRate.ECB (ecbProvider)
import Infrastructure.ExchangeRate.NBU (nbuProvider)
import Infrastructure.Version (VersionInfo, displayVersion, mkVersionInfo)
import Network.HTTP.Client.TLS (newTlsManager)
import RIO
import qualified RIO.Set as Set
import qualified RIO.Text as T
-- Web Server

-- System
import System.Environment (getArgs, lookupEnv)
import System.IO (hPutStrLn)
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

  -- Setup logging
  logOptions <- createLogOptions config
  withLogFunc logOptions $ \logFunc -> do
    -- Run application with RIO
    runRIO logFunc $ do
      logInfo "Starting Accounting Backend..."
      logInfo $ "Environment: " <> displayShow config.environment

      -- Initialize application environment
      env <- initializeEnvironment logFunc config versionInfo

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

-- | Create log options based on configuration.
--
-- This configures RIO's structured logging:
--  - Log output destination (stdout)
--  - Log level filtering
--  - Timestamp format
--  - Color output (for TTY)
--
-- Example:
-- >>> logOptions <- createLogOptions config
-- >>> -- LogOptions configured based on appLogging config
createLogOptions :: AppConfig -> IO LogOptions
createLogOptions config = do
  let minLevel = convertLogLevel config.logging.level
  baseOptions <- logOptionsHandle stdout True
  return
    $ setLogMinLevel minLevel
    $ setLogUseLoc False
    $ setLogUseTime True baseOptions
  where
    convertLogLevel :: Config.LogLevel -> RIO.LogLevel
    convertLogLevel Config.LogDebug = LevelDebug
    convertLogLevel Config.LogInfo = LevelInfo
    convertLogLevel Config.LogWarn = LevelWarn
    convertLogLevel Config.LogError = LevelError

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
-- >>> env <- initializeEnvironment logFunc config
-- >>> -- AppEnv ready to use
initializeEnvironment :: LogFunc -> AppConfig -> VersionInfo -> RIO LogFunc AppEnv
initializeEnvironment logFunc config versionInfo = do
  logInfo "Initializing application environment..."

  -- 1. Initialize database connection pool
  logInfo "Creating database connection pool..."
  let dbConfigForPool = convertDatabaseConfig config.database
  pool <- liftIO $ createConnectionPool dbConfigForPool
  logInfo
    $ "Database pool created (size: "
    <> displayShow config.database.poolSize
    <> ")"

  -- 2. Run database migrations and initialization
  logInfo "Initializing database and running migrations..."
  liftIO $ initializeDatabase pool
  logInfo "Database initialized successfully"

  -- 3. Initialize read models (must happen before creating the writer)
  logInfo "Initializing read models..."
  readModels <- liftIO createReadModels
  let handlers = fromReadModels readModels
      readModelHandlers = createReadModelHandlersFrom handlers
  logInfo "Read models initialized"

  -- 4. Create event store readers/writers with read model handlers on the event bus
  logInfo "Creating event store readers and writers..."
  let eventStoreConfig = defaultSqlEventStoreConfig
      -- Create SQL-based event stores with read model handlers on the event bus
      sqlWriter =
        accountingEventStoreWriter
          eventStoreConfig
          (wireProcessManager transferProcessManager)
          (map liftIOEventHandler readModelHandlers)
      sqlReader = accountingVersionedEventStoreReader eventStoreConfig
      sqlGlobalReader = accountingGlobalEventStoreReader eventStoreConfig
      -- Lift to IO by running through the connection pool
      writer = liftTaggedWriter pool sqlWriter
      reader = liftVersionedReader pool sqlReader
      globalReader = liftGlobalReader pool sqlGlobalReader
  logInfo "Event store configured with read model handlers"

  -- 4b. Replay historical events into read models
  -- Must run before server/bot starts to avoid concurrent writes to TVars.
  logInfo "Replaying historical events into read models..."
  eventCount <- liftIO $ replayWith globalReader handlers
  logInfo $ "Read models populated from event store (" <> displayShow eventCount <> " events)"

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
  -- Historical rates survive restarts via the ExchangeRateReadModel replayed
  -- from persisted 'ExchangeRatesPublishedEvent's in 'replayReadModels' above.
  logInfo "Spawning exchange rate publisher..."
  rateProvider <- case unProvider config.exchangeRate.provider of
    "nbu" -> pure nbuProvider
    "ecb" -> pure ecbProvider
    unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
  -- Fire-and-forget: the publisher loop catches and logs its own errors and
  -- runs for the lifetime of the process, so we do not retain the Async handle.
  void
    $ liftIO
    $ spawnRatePublisher rateProvider writer reader readModels.exchangeRate logFunc
  logInfo $ "Exchange rate publisher running (" <> display config.exchangeRate.provider <> ")"

  -- 6c. Create HTTP manager for bank API calls
  logInfo "Creating HTTP manager..."
  httpManager <- liftIO newTlsManager

  -- 6d. Per-user bank-import serialization locks
  bankImportLocksVar <- liftIO $ newTVarIO Set.empty

  let bankingEnv' =
        BankingEnv
          { bankImportReadModel = readModels.bankImport,
            bankImportLocks = bankImportLocksVar,
            httpManager = httpManager
          }

  -- 7. Build application environment
  linkCodeStore <- liftIO newLinkCodeStore
  let configDbConfig = config.database -- Config.DatabaseConfig for AppEnv
      env =
        initializeAppEnv
          logFunc
          config
          configDbConfig
          pool
          writer
          reader
          globalReader
          readModels.account
          readModels.transaction
          readModels.user
          readModels.configuration
          jwtConfig
          oauthConfig
          telegramConfig
          botState
          telegramClientEnv
          readModels.exchangeRate
          versionInfo
          bankingEnv'
          linkCodeStore

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
