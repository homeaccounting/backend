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
import Application.ReadModels.ExchangeRate (createExchangeRateReadModel)
import Application.ReadModels.User ()
import Control.Concurrent.STM (atomically)
import qualified Data.Set as Set
import Domain.Models (AccountingEvent)
import Eventium (Codec (..), EventStoreReader (..), EventStoreWriter (..), TaggedEvent (..), processManagerEventHandler, publishingTaggedCodecEventStoreWriter, synchronousPublisher)
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
    LogFormat (..),
    LogLevel (..),
    LoggingConfig (..),
    MonobankProviderConfig (..),
    ProcessManagerConfig (..),
    ServerConfig (..),
  )
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
    ReadModels (..),
    commandDispatcher,
    createReadModelHandlers,
  )
import Infrastructure.Version (VersionInfo (..))
import Network.HTTP.Client (defaultManagerSettings, newManager)
import RIO hiding (atomically, newTVarIO)
import qualified RIO
import qualified RIO.Text as T
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

-- | Create a complete test 'AppEnv' with in-memory components.
--
-- The environment is fully functional and isolated:
--  - In-memory event stores (no database)
--  - Read models wired into the event bus
--  - Logging to stderr (visible via @cabal test --test-show-details=direct@)
--
-- Note: This creates stores in STM but lifts them to IO for the AppEnv.
-- The lifting is done via 'atomically', so all operations remain transactional.
createTestAppEnv :: IO AppEnv
createTestAppEnv = mkAppEnv False

-- | Create a test 'AppEnv' with the Transfer Process Manager enabled.
--
-- Like 'createTestAppEnv', but also wires the TransferManager event handler
-- into the synchronous event bus. When a 'TransferInitiated' event is written,
-- the process manager will automatically:
--
--  1. Issue 'DebitAccount' to the source account
--  2. On 'AccountDebited', issue 'CreditAccount' + 'CompleteTransfer'
--  3. On debit failure, the command dispatcher issues 'FailTransfer'
--
-- Use this for integration tests that need end-to-end saga behavior.
createTestAppEnvWithProcessManager :: IO AppEnv
createTestAppEnvWithProcessManager = mkAppEnv True

-- | Shared implementation for the two test environment variants. The only
-- difference between them is whether the transfer process manager is wired
-- into the synchronous event bus.
mkAppEnv :: Bool -> IO AppEnv
mkAppEnv withProcessManager = do
  -- mkLogFunc instead of withLogFunc avoids resource cleanup issues:
  -- withLogFunc closes the LogFunc when its callback returns, which causes
  -- hangs in tests that hold an AppEnv past the call site.
  let logFunc = mkLogFunc $ \_callStack _source _level msg ->
        hPutBuilder stderr (getUtf8Builder (msg <> "\n"))

  stores <- createInMemoryEventStores
  (readModels, readModelHandlers) <- createReadModelHandlers

  let baseWriter = liftSTMWriter stores.inMemoryWriter
      reader = liftSTMReader stores.inMemoryReader
      globalReader = liftSTMGlobalReader stores.inMemoryGlobalReader

      -- CRITICAL: Read model handlers FIRST, then process manager LAST.
      -- See accountingEventStoreWriter for the depth-first dispatch explanation.
      pmHandler = processManagerEventHandler transferProcessManager globalReader (commandDispatcher writer reader)
      combinedHandler =
        if withProcessManager
          then mconcat readModelHandlers <> pmHandler
          else mconcat readModelHandlers
      writer =
        publishingTaggedCodecEventStoreWriter
          (jsonStringCodec :: Codec AccountingEvent JSONString)
          (decodingTaggedWriter baseWriter)
          (synchronousPublisher combinedHandler)

      config = testAppConfig
      testVersionInfo = VersionInfo {appVersion = "0.0.0-test", commit = "test"}

  botState <- RIO.newTVarIO emptyBotState
  exchangeRateRM <- createExchangeRateReadModel
  testHttpManager <- newManager defaultManagerSettings
  bankImportLocksVar <- RIO.newTVarIO Set.empty

  return
    AppEnv
      { logFunc = logFunc,
        config = config,
        databaseConfig = config.database,
        dbPool = error "Database pool should not be accessed in in-memory tests! Use event store abstractions instead.",
        eventStoreWriter = writer,
        eventStoreReader = reader,
        globalEventStoreReader = globalReader,
        accountReadModel = readModels.account,
        transactionReadModel = readModels.transaction,
        userReadModel = readModels.user,
        configurationReadModel = readModels.configuration,
        jwtConfig = config.auth,
        oauthConfig = config.oauth,
        telegramConfig = config.telegram,
        botState = botState,
        telegramClientEnv = Nothing,
        exchangeRateReadModel = exchangeRateRM,
        versionInfo = testVersionInfo,
        bankingEnv =
          BankingEnv
            { bankImportReadModel = readModels.bankImport,
              bankImportLocks = bankImportLocksVar,
              httpManager = testHttpManager
            }
      }

-- | The default 'AppConfig' used by every in-memory test environment.
--
-- Banking is disabled by default; specs that need to flip the feature flag
-- override @config.banking@ on the resulting 'AppEnv' (see
-- 'Web.API.BankingAPISpec' for an example).
testAppConfig :: AppConfig
testAppConfig =
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
      auth = defaultJWTConfig,
      oauth =
        OAuthConfig
          { google = Nothing,
            gitHub = Nothing,
            microsoft = Nothing
          },
      telegram =
        TelegramConfig
          { botToken = "test_token",
            botUsername = "test_bot",
            authMaxAge = 86400,
            webhookUrl = Nothing,
            usePolling = False,
            pollingTimeout = 30
          },
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
