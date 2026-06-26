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

    -- * Database helpers
    runDbIn,

    -- * Event Store Components
    InMemoryEventStores (..),
  )
where

import Application.EventDispatch (ReadModels (..), createReadModels, fromReadModels)
import Application.LinkCodeStore (newLinkCodeStore)
import Application.ProcessManagers (transactionCancellationProcessManager, transferAmendmentProcessManager, transferProcessManager)
import Application.ReadModels.BankImportReadModel (handleBankImportEvents, migrateBankImport)
import Application.ReadModels.User ()
import Control.Monad.Logger (LoggingT, runNoLoggingT)
import qualified Data.Set as Set
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.Sqlite (createSqlitePool)
import Domain.Models (AccountingEvent)
import Eventium (EventStoreReader (..))
import Eventium.ProjectionCache.Sql (migrateProjectionSnapshot)
import Eventium.Store.Memory
  ( EventMap,
    emptyEventMap,
    tvarEventStoreReader,
    tvarEventStoreWriter,
    tvarGlobalEventStoreReader,
  )
import Eventium.Store.Sql (migrateSqlEvent)
import Eventium.Store.Sqlite (sqliteTaggedEventStoreWriter)
import Infrastructure.App (AppEnv (..), BankingEnv (..), bankingKeyRingFromConfig, runAppM, runDb)
import Infrastructure.Auth.JWT (defaultJWTConfig)
import Infrastructure.Auth.OAuth (OAuthConfig (..))
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import Infrastructure.Banking.Monobank (mkBankProviderFactory)
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
import Infrastructure.Database (defaultSqlEventStoreConfig, runDbDirect)
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
    accountingEventStoreWriterWithRaw,
    accountingGlobalEventStoreReader,
    accountingVersionedEventStoreReader,
    createReadModelHandlersFrom,
    liftGlobalReader,
    liftIOEventHandler,
    liftTaggedWriter,
    liftVersionedReader,
    wireProcessManager,
    wireProcessManagers,
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

-- | Run a persistent action against a test 'AppEnv's (SQLite) pool. Shorthand
-- for the widely-repeated @runAppM env . runDb@ pattern in DB-backed specs.
runDbIn :: AppEnv -> SqlPersistT (LoggingT IO) a -> IO a
runDbIn env = runAppM env . runDb

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
-- Like 'createTestAppEnv', but also wires the TransactionPostingManager event handler
-- into the synchronous event bus. When a 'TransactionPostingInitiated' event is written,
-- the process manager will automatically:
--
--  1. Issue 'DebitAccount' to the source account
--  2. On 'AccountDebited', issue 'CreditAccount' + 'CompleteTransactionPosting'
--  3. On debit failure, the command dispatcher issues 'FailTransactionPosting'
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

  -- Real in-memory SQLite backend (pool size 1 so the single connection — and
  -- thus the in-memory DB — persists for the life of the AppEnv). This makes
  -- 'runDb' work and lets persistent read models be projected in the same
  -- transaction as the event append, exactly as in production.
  pool <- runNoLoggingT (createSqlitePool ":memory:" 1)
  runDbDirect pool $ do
    _ <- runMigrationSilent migrateSqlEvent
    _ <- runMigrationSilent migrateProjectionSnapshot
    _ <- runMigrationSilent migrateBankImport
    pure ()

  readModels <- createReadModels
  let handlers = fromReadModels readModels
      readModelHandlers = createReadModelHandlersFrom handlers
      eventStoreConfig = defaultSqlEventStoreConfig

      pmFactory =
        if withProcessManager
          then
            wireProcessManagers
              [ wireProcessManager transferProcessManager,
                wireProcessManager transferAmendmentProcessManager,
                wireProcessManager transactionCancellationProcessManager
              ]
          else wireProcessManagers []

      -- Same wiring as production (synchronous publisher; SQL read models apply
      -- in the writer transaction, in-memory ones via liftIOEventHandler), but
      -- with the SQLite raw writer.
      sqlWriter =
        accountingEventStoreWriterWithRaw
          (sqliteTaggedEventStoreWriter eventStoreConfig)
          eventStoreConfig
          pmFactory
          ( createReadModelHandlersFrom handleBankImportEvents
              ++ map liftIOEventHandler readModelHandlers
          )
      writer = liftTaggedWriter pool sqlWriter
      reader = liftVersionedReader pool (accountingVersionedEventStoreReader eventStoreConfig)
      globalReader = liftGlobalReader pool (accountingGlobalEventStoreReader eventStoreConfig)

      config = testAppConfig
      testVersionInfo = VersionInfo {appVersion = "0.0.0-test", commit = "test"}

  botState <- RIO.newTVarIO emptyBotState
  testHttpManager <- newManager defaultManagerSettings
  bankImportLocksVar <- RIO.newTVarIO Set.empty
  -- Deterministic banking key ring built from the test config's
  -- 'tokenEncKey' so encryption is reproducible across test runs.
  testBankingKeyRing <- bankingKeyRingFromConfig config.environment config.banking
  linkCodeStore <- newLinkCodeStore

  return
    AppEnv
      { logFunc = logFunc,
        config = config,
        databaseConfig = config.database,
        dbPool = pool,
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
        exchangeRateReadModel = readModels.exchangeRate,
        versionInfo = testVersionInfo,
        bankingEnv =
          BankingEnv
            { bankImportLocks = bankImportLocksVar,
              httpManager = testHttpManager,
              bankingKeyRing = testBankingKeyRing,
              -- Default factory mirrors production (dispatches on the
              -- provider enum, real Monobank provider over the test HTTP
              -- manager). Banking-enabled HTTP specs override this with a stub
              -- via 'Testkit.AppEnv'.
              bankProviderFactory = mkBankProviderFactory config testHttpManager
            },
        linkCodeStore = linkCodeStore
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
            apiBaseUrl = T.pack "http://localhost:8080",
            appBaseUrl = T.pack "http://localhost:5173"
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
            providers = BankingProvidersConfig (MonobankProviderConfig False "https://api.monobank.ua"),
            -- Deterministic base64 of 32 bytes (0x07 repeated) so the test
            -- key ring is reproducible across runs and processes.
            tokenEncKey = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc="
          }
    }
