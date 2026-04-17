{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.InMemoryEventStore
-- Description : In-memory event store setup for testing
--
-- This module provides utilities for creating in-memory event stores
-- for testing. It uses the eventium-memory package to create STM-based
-- event stores that are fast, isolated, and don't require a database.
--
-- Benefits:
--   - Fast test execution (no I/O overhead)
--   - Isolated test state (each test gets fresh store)
--   - No database setup required
--   - Process managers and sagas work as in production
--
-- Usage:
--
-- >>> testEnv <- createTestAppEnv
-- >>> runAppM testEnv $ do
-- >>>   -- Use the test environment with in-memory event store
-- >>>   writer <- view eventStoreWriterL
-- >>>   reader <- view eventStoreReaderL
-- >>>   ...
module Testkit.InMemoryEventStore
  ( -- * Test Environment Creation
    createTestAppEnv,
    createTestAppEnvWithProcessManager,
    createInMemoryEventStores,

    -- * Event Store Components
    InMemoryEventStores (..),
  )
where

import Application.ProcessManagers (transferProcessManager)
import Application.ReadModels.Account (createAccountReadModel)
import Application.ReadModels.BankImportReadModel (createBankImportReadModel)
import Application.ReadModels.Transaction (createTransactionReadModel)
import Application.ReadModels.User ()
import Control.Concurrent.STM (TVar, atomically)
import qualified Data.Set as Set
import Domain.Models (AccountingEvent)
import Eventium (Codec (..), EventHandler (..), EventStoreReader (..), EventStoreWriter (..), TaggedEvent (..), VersionedStreamEvent, processManagerEventHandler, publishingTaggedCodecEventStoreWriter, synchronousPublisher)
import Eventium.Store.Memory
  ( EventMap,
    emptyEventMap,
    tvarEventStoreReader,
    tvarEventStoreWriter,
    tvarGlobalEventStoreReader,
  )
import Eventium.Store.Postgresql (JSONString, jsonStringCodec)
import Infrastructure.App (AppEnv (..), BankingEnv (..))
import Infrastructure.Auth.JWT (defaultJWTConfig)
import Infrastructure.Auth.OAuth (OAuthConfig (..))
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import Infrastructure.Config
  ( AppConfig (..),
    BankingConfig (..),
    BankingProvidersConfig (..),
    CorsConfig (..),
    DatabaseConfig (..),
    Environment (..),
    EventStoreConfig (..),
    ExchangeRateConfig (..),
    JWTConfig (..),
    LogFormat (..),
    LogLevel (..),
    LoggingConfig (..),
    MonobankProviderConfig (..),
    OAuthConfig (..),
    ProcessManagerConfig (..),
    ServerConfig (..),
    TelegramConfig (..),
  )
import qualified Infrastructure.Database as DB
import Infrastructure.Eventium
  ( AccountingEventHandler,
    AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
    ReadModels (..),
    commandDispatcher,
    createReadModelHandlers,
  )
import Infrastructure.ExchangeRate.ECB (ecbProvider)
import Infrastructure.ExchangeRate.Store (newExchangeRateStore)
import Infrastructure.Version (VersionInfo (..))
import Network.HTTP.Client (defaultManagerSettings, newManager)
import RIO hiding (atomically, newTVarIO)
import qualified RIO
import qualified RIO.Text as T
import System.Environment (lookupEnv)
import Telegram.Types (emptyBotState)

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------

-- | Container for in-memory event store components.
--
-- This holds the TVar-based event store implementations that work
-- entirely in memory using STM transactions.
data InMemoryEventStores = InMemoryEventStores
  { inMemoryWriter :: !(AccountingVersionedEventStoreWriter STM),
    inMemoryReader :: !(AccountingVersionedEventStoreReader STM),
    inMemoryGlobalReader :: !(AccountingGlobalEventStoreReader STM),
    inMemoryEventMap :: !(TVar (EventMap AccountingEvent))
  }

-- -----------------------------------------------------------------------------
-- In-Memory Event Store Creation
-- -----------------------------------------------------------------------------

-- | Create in-memory event stores using STM.
--
-- This creates a fresh event store backed by a TVar. All operations
-- are atomic via STM transactions.
--
-- The returned stores are fully functional and include:
--  - Event versioning and ordering
--  - Optimistic concurrency control
--  - Global event stream access
--
-- Usage:
-- >>> stores <- atomically createInMemoryEventStores
-- >>> -- Use stores.inMemoryWriter, stores.inMemoryReader, etc.
createInMemoryEventStores :: IO InMemoryEventStores
createInMemoryEventStores = do
  -- Create the TVar-backed event map
  eventMapVar <- RIO.newTVarIO emptyEventMap

  -- Create readers/writers that operate on this TVar
  let writer = tvarEventStoreWriter eventMapVar
      reader = tvarEventStoreReader eventMapVar
      globalReader = tvarGlobalEventStoreReader eventMapVar

  return
    InMemoryEventStores
      { inMemoryWriter = writer,
        inMemoryReader = reader,
        inMemoryGlobalReader = globalReader,
        inMemoryEventMap = eventMapVar
      }

-- -----------------------------------------------------------------------------
-- Test Environment Creation
-- -----------------------------------------------------------------------------

-- | Create a complete test AppEnv with in-memory components.
--
-- This creates a fully functional application environment suitable for testing:
--  - In-memory event stores (no database)
--  - Test configuration
--  - Read models
--  - Process managers (working via event bus)
--  - Logging to stderr (for test output)
--
-- The environment is completely isolated and can be discarded after tests.
--
-- Example:
-- >>> testEnv <- createTestAppEnv
-- >>> runAppM testEnv $ do
-- >>>   -- Create an account
-- >>>   writer <- view eventStoreWriterL
-- >>>   applyAccountCommand writer reader accountId createCmd
--
-- Note: This creates stores in STM but lifts them to IO for the AppEnv.
-- The lifting is done via atomically, so all operations remain transactional.
--
-- This creates a complete test environment with both:
--  - In-memory event stores (for fast, isolated testing)
--  - Real database pool (for full integration if needed)
--
-- The function will use environment variables or defaults for database connection:
--  - TEST_DB_HOST (default: localhost)
--  - TEST_DB_PORT (default: 5432)
--  - TEST_DB_NAME (default: accounting)
--  - TEST_DB_USER (default: postgres)
--  - TEST_DB_PASSWORD (default: postgres)
--
-- Note: Requires a PostgreSQL database to be running.
-- Use docker-compose to start it: `docker compose up -d`
createTestAppEnv :: IO AppEnv
createTestAppEnv = do
  -- Create a simple log function for tests that outputs to stderr
  -- Using mkLogFunc instead of withLogFunc to avoid resource cleanup issues
  -- (withLogFunc cleans up the LogFunc when callback returns, causing hangs)
  let logFunc = mkLogFunc $ \_callStack _source _level msg ->
        hPutBuilder stderr (getUtf8Builder (msg <> "\n"))

  -- Create in-memory event stores
  stores <- createInMemoryEventStores

  -- Create read models first (before lifting writers)
  (readModels, readModelHandlers) <- createReadModelHandlers

  -- Lift event stores from STM to IO
  -- This wraps each operation with `atomically`
  let baseWriter = liftSTMWriter stores.inMemoryWriter
      reader = liftSTMReader stores.inMemoryReader
      globalReader = liftSTMGlobalReader stores.inMemoryGlobalReader

      -- Wrap the in-memory versioned writer as a tagged writer with event bus.
      -- The base store accepts AccountingEvent, so we decode TaggedEvent payloads
      -- and publish decoded domain events to read model handlers.
      writer =
        publishingTaggedCodecEventStoreWriter
          (jsonStringCodec :: Codec AccountingEvent JSONString)
          (decodingTaggedWriter baseWriter)
          (synchronousPublisher (mconcat readModelHandlers))

  -- Create test auth configs
  let testJWTConfig = defaultJWTConfig
      testOAuthConfig =
        OAuthConfig
          { google = Nothing,
            gitHub = Nothing,
            microsoft = Nothing
          }
      testTelegramConfig =
        TelegramConfig
          { botToken = "test_token",
            botUsername = "test_bot",
            authMaxAge = 86400,
            webhookUrl = Nothing,
            usePolling = False,
            pollingTimeout = 30
          }

  -- Create test configuration
  let config =
        AppConfig
          { environment = EnvTest,
            server =
              ServerConfig
                { port = 8080,
                  host = T.pack "127.0.0.1",
                  apiBaseUrl = T.pack "http://localhost:8080"
                },
            database =
              DatabaseConfig
                { host = T.pack "localhost",
                  port = 5432,
                  user = T.pack "test",
                  password = T.pack "test",
                  database = T.pack "test",
                  poolSize = 1,
                  connectionTimeout = 10
                },
            logging =
              LoggingConfig
                { level = LogInfo,
                  format = LogText
                },
            cors =
              CorsConfig
                { enabled = True,
                  allowedOrigins = T.pack <$> ["*"],
                  allowedMethods = T.pack <$> ["GET", "POST", "PUT", "DELETE"],
                  allowedHeaders = T.pack <$> ["Content-Type", "Authorization"],
                  maxAge = Just 3600
                },
            eventStore =
              EventStoreConfig
                { snapshotFrequency = 100
                },
            processManagers =
              ProcessManagerConfig
                { pollIntervalMs = 1000
                },
            auth = testJWTConfig,
            oauth = testOAuthConfig,
            telegram = testTelegramConfig,
            exchangeRate =
              ExchangeRateConfig
                { provider = "ecb"
                },
            banking =
              BankingConfig
                { enabled = False,
                  providers = BankingProvidersConfig (MonobankProviderConfig False "https://api.monobank.ua")
                }
          }

      dbConfig = config.database
      testVersionInfo = VersionInfo {appVersion = "0.0.0-test", commit = "test"}

  -- Build the AppEnv
  -- Note: We don't have a real connection pool, but handlers don't need it
  -- because they work through the event store abstraction
  -- Using undefined instead of error so it's only evaluated if actually used
  botState <- RIO.newTVarIO emptyBotState
  exchangeRateStore' <- newExchangeRateStore ecbProvider
  testHttpManager <- newManager defaultManagerSettings
  bankImportLocksVar <- RIO.newTVarIO Set.empty

  return
    AppEnv
      { logFunc = logFunc,
        config = config,
        databaseConfig = dbConfig,
        dbPool = error "Database pool should not be accessed in in-memory tests! Use event store abstractions instead.",
        eventStoreWriter = writer,
        eventStoreReader = reader,
        globalEventStoreReader = globalReader,
        accountReadModel = readModels.account,
        transactionReadModel = readModels.transaction,
        userReadModel = readModels.user,
        configurationReadModel = readModels.configuration,
        jwtConfig = testJWTConfig,
        oauthConfig = testOAuthConfig,
        telegramConfig = testTelegramConfig,
        botState = botState,
        telegramClientEnv = Nothing,
        exchangeRateStore = exchangeRateStore',
        versionInfo = testVersionInfo,
        bankingEnv =
          BankingEnv
            { bankImportReadModel = readModels.bankImport,
              bankImportLocks = bankImportLocksVar,
              httpManager = testHttpManager
            }
      }

-- | Create a test AppEnv with the Transfer Process Manager enabled.
--
-- Like 'createTestAppEnv', but also wires the TransferManager event handler
-- into the synchronous event bus. This means that when a TransferInitiated
-- event is written, the process manager will automatically:
--  1. Issue DebitAccount to the source account
--  2. On AccountDebited, issue CreditAccount + CompleteTransfer
--  3. On debit failure, the command dispatcher issues FailTransfer
--
-- Use this for integration tests that need end-to-end saga behavior.
createTestAppEnvWithProcessManager :: IO AppEnv
createTestAppEnvWithProcessManager = do
  let logFunc = mkLogFunc $ \_callStack _source _level msg ->
        hPutBuilder stderr (getUtf8Builder (msg <> "\n"))

  stores <- createInMemoryEventStores

  (readModels, readModelHandlers) <- createReadModelHandlers

  let baseWriter = liftSTMWriter stores.inMemoryWriter
      reader = liftSTMReader stores.inMemoryReader
      globalReader = liftSTMGlobalReader stores.inMemoryGlobalReader

      -- CRITICAL: Read model handlers FIRST, then process manager LAST.
      -- See accountingEventStoreWriter for the depth-first dispatch explanation.
      writer =
        publishingTaggedCodecEventStoreWriter
          (jsonStringCodec :: Codec AccountingEvent JSONString)
          (decodingTaggedWriter baseWriter)
          (synchronousPublisher combinedHandler)
      pmHandler = processManagerEventHandler transferProcessManager globalReader (commandDispatcher writer reader)
      combinedHandler = mconcat readModelHandlers <> pmHandler

  let testJWTConfig = defaultJWTConfig
      testOAuthConfig =
        OAuthConfig
          { google = Nothing,
            gitHub = Nothing,
            microsoft = Nothing
          }
      testTelegramConfig =
        TelegramConfig
          { botToken = "test_token",
            botUsername = "test_bot",
            authMaxAge = 86400,
            webhookUrl = Nothing,
            usePolling = False,
            pollingTimeout = 30
          }

  let config =
        AppConfig
          { environment = EnvTest,
            server =
              ServerConfig
                { port = 8080,
                  host = T.pack "127.0.0.1",
                  apiBaseUrl = T.pack "http://localhost:8080"
                },
            database =
              DatabaseConfig
                { host = T.pack "localhost",
                  port = 5432,
                  user = T.pack "test",
                  password = T.pack "test",
                  database = T.pack "test",
                  poolSize = 1,
                  connectionTimeout = 10
                },
            logging =
              LoggingConfig
                { level = LogInfo,
                  format = LogText
                },
            cors =
              CorsConfig
                { enabled = True,
                  allowedOrigins = T.pack <$> ["*"],
                  allowedMethods = T.pack <$> ["GET", "POST", "PUT", "DELETE"],
                  allowedHeaders = T.pack <$> ["Content-Type", "Authorization"],
                  maxAge = Just 3600
                },
            eventStore =
              EventStoreConfig
                { snapshotFrequency = 100
                },
            processManagers =
              ProcessManagerConfig
                { pollIntervalMs = 1000
                },
            auth = testJWTConfig,
            oauth = testOAuthConfig,
            telegram = testTelegramConfig,
            exchangeRate =
              ExchangeRateConfig
                { provider = "ecb"
                },
            banking =
              BankingConfig
                { enabled = False,
                  providers = BankingProvidersConfig (MonobankProviderConfig False "https://api.monobank.ua")
                }
          }

      dbConfig = config.database
      testVersionInfo = VersionInfo {appVersion = "0.0.0-test", commit = "test"}

  botState <- RIO.newTVarIO emptyBotState
  exchangeRateStore <- newExchangeRateStore ecbProvider
  testHttpManager <- newManager defaultManagerSettings
  bankImportLocksVar <- RIO.newTVarIO Set.empty

  return
    AppEnv
      { logFunc = logFunc,
        config = config,
        databaseConfig = dbConfig,
        dbPool = error "Database pool should not be accessed in in-memory tests!",
        eventStoreWriter = writer,
        eventStoreReader = reader,
        globalEventStoreReader = globalReader,
        accountReadModel = readModels.account,
        transactionReadModel = readModels.transaction,
        userReadModel = readModels.user,
        configurationReadModel = readModels.configuration,
        jwtConfig = testJWTConfig,
        oauthConfig = testOAuthConfig,
        telegramConfig = testTelegramConfig,
        botState = botState,
        telegramClientEnv = Nothing,
        exchangeRateStore = exchangeRateStore,
        versionInfo = testVersionInfo,
        bankingEnv =
          BankingEnv
            { bankImportReadModel = readModels.bankImport,
              bankImportLocks = bankImportLocksVar,
              httpManager = testHttpManager
            }
      }

-- -----------------------------------------------------------------------------
-- STM to IO Lifting
-- -----------------------------------------------------------------------------

-- | Lift an STM event store writer to IO.
--
-- Wraps each write operation with `atomically` to ensure transactional
-- semantics are preserved when running in IO.
liftSTMWriter ::
  AccountingVersionedEventStoreWriter STM ->
  AccountingVersionedEventStoreWriter IO
liftSTMWriter (EventStoreWriter stmWrite) =
  EventStoreWriter $ \uuid expectedVersion events ->
    atomically $ stmWrite uuid expectedVersion events

-- | Lift an STM event store reader to IO.
--
-- Wraps each read operation with `atomically`.
liftSTMReader ::
  AccountingVersionedEventStoreReader STM ->
  AccountingVersionedEventStoreReader IO
liftSTMReader (EventStoreReader stmRead) =
  EventStoreReader $ \range ->
    atomically $ stmRead range

-- | Lift an STM global event store reader to IO.
--
-- Wraps each global read operation with `atomically`.
liftSTMGlobalReader ::
  AccountingGlobalEventStoreReader STM ->
  AccountingGlobalEventStoreReader IO
liftSTMGlobalReader (EventStoreReader stmRead) =
  EventStoreReader $ \range ->
    atomically $ stmRead range

-- -----------------------------------------------------------------------------
-- Tagged Writer Adapter (test-only)
-- -----------------------------------------------------------------------------

-- | Adapt a versioned (domain-event) writer to accept TaggedEvent by decoding
-- each payload through a Codec. Used for in-memory test stores that natively
-- store domain events but need a tagged writer interface.
decodingTaggedWriter ::
  (Monad m) =>
  AccountingVersionedEventStoreWriter m ->
  AccountingTaggedEventStoreWriter m
decodingTaggedWriter (EventStoreWriter write) =
  EventStoreWriter $ \uuid expectedVersion taggedEvents ->
    case traverse (jsonStringCodec.decode . (.payload)) taggedEvents of
      Nothing -> error "decodingTaggedWriter: codec decode failure"
      Just events -> write uuid expectedVersion events
