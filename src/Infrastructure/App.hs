{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.App
-- Description : Application environment and monad using RIO
--
-- This module defines the application environment and monad stack using the RIO
-- library. RIO provides a batteries-included ReaderT pattern with structured
-- logging, exception handling, and UnliftIO support.
--
-- Key Components:
--   - AppEnv: Application environment containing all runtime dependencies
--   - AppM: Application monad (type alias for RIO AppEnv)
--   - Type classes: HasDbPool, HasEventStore, HasReadModel for dependency access
--   - Helper functions: For running the application monad
--
-- Architecture Benefits:
--
-- Using RIO provides:
--   1. **Structured Logging**: Built-in LogFunc with proper structure
--   2. **Resource Safety**: UnliftIO for safe resource management
--   3. **Reader Pattern**: Environment passed implicitly via MonadReader
--   4. **Exception Handling**: Type-safe exception handling
--   5. **Better Prelude**: Modern, safe prelude with no partial functions
--
-- Design Pattern:
--
-- The application environment (AppEnv) contains all global resources:
--   - Database connection pool
--   - Event store readers/writers
--   - Read models (in-memory or cached)
--   - Configuration
--   - Logging infrastructure
--
-- Type classes (HasDbPool, HasEventStore, etc.) provide lenses for accessing
-- specific resources, enabling:
--   - Dependency injection
--   - Testability (mock environments)
--   - Modularity (functions depend only on what they need)
--
-- Usage Example:
--
-- Application startup:
-- >>> main :: IO ()
-- >>> main = do
-- >>>   logOptions <- logOptionsHandle stdout True
-- >>>   withLogFunc logOptions $ \logFunc -> do
-- >>>     env <- initializeAppEnv logFunc config
-- >>>     runRIO env applicationMain
--
-- In application code:
-- >>> createAccount :: UUID -> CreateAccountRequest -> AppM AccountResponse
-- >>> createAccount accountId request = do
-- >>>   logInfo "Creating account..."
-- >>>   pool <- view dbPoolL
-- >>>   writer <- view eventStoreWriterL
-- >>>   -- Use resources...
--
-- Integration with Servant:
--
-- >>> appToHandler :: AppEnv -> AppM a -> Handler a
-- >>> appToHandler env app = Handler $ ExceptT $ try $ runRIO env app
-- >>>
-- >>> server :: ServerT API AppM
-- >>> server = accountServer :<|> transactionServer
-- >>>
-- >>> runServer :: ServerConfig -> AppM ()
-- >>> runServer config = do
-- >>>   env <- ask
-- >>>   let application = serve api $ hoistServer api (appToHandler env) server
-- >>>   liftIO $ run (serverPort config) application
module Infrastructure.App
  ( -- * Application Environment
    AppEnv (..),
    initializeAppEnv,

    -- * Application Monad
    AppM,

    -- * Type Classes for Resource Access
    HasDbPool (..),
    HasEventStore (..),
    HasReadModel (..),
    HasAppConfig (..),
    HasDatabaseConfig (..),
    HasAuthConfig (..),
    HasBotState (..),
    HasTelegramClient (..),

    -- * Running the Application
    runAppM,

    -- * Database Helpers
    runDb,

    -- * RIO Re-exports
    module RIO,
  )
where

-- Local imports
import Application.ReadModels.Account (AccountReadModel)
import Application.ReadModels.Transaction (TransactionReadModel)
import Application.ReadModels.User (UserReadModel)
import Control.Monad.Logger (LoggingT, runStdoutLoggingT)
import Database.Persist.Postgresql (ConnectionPool, SqlBackend, runSqlPool)
import Infrastructure.Auth.JWT (JWTConfig)
import Infrastructure.Auth.OAuth (OAuthConfig)
import Infrastructure.Auth.Telegram (TelegramConfig)
import Infrastructure.Config (AppConfig, DatabaseConfig)
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
  )
import RIO
import Servant.Client (ClientEnv)
import Telegram.Types (BotState)

-- -----------------------------------------------------------------------------
-- Application Environment
-- -----------------------------------------------------------------------------

-- | Application environment containing all runtime dependencies.
--
-- This structure holds all the resources and configuration needed by the
-- application at runtime. It's passed implicitly to all functions via the
-- Reader monad.
--
-- Fields:
--  - logFunc: RIO's structured logging function
--  - config: Application configuration (database, server, etc.)
--  - databaseConfig: Database configuration (for RIO pattern consistency)
--  - dbPool: PostgreSQL connection pool
--  - eventStoreWriter: Event store writer with event bus
--  - eventStoreReader: Event store reader for loading aggregates
--  - globalEventStoreReader: Global event reader for read models
--  - accountReadModel: In-memory account summary read model
--  - transactionReadModel: In-memory transaction summary read model
--
-- Design Notes:
--  - All fields are strict (!) for performance
--  - Immutable after initialization
--  - Shared across all application threads
--  - Resources managed by RIO's UnliftIO
-- TODO: Think about we have here duplication, for example: DatabaseConfig is part of AppConfig,
-- also maybe it worth to group dependencies like: configs, eventStore, readModels to simplify AppEnv
data AppEnv = AppEnv
  { -- | Structured logging function (RIO requirement)
    logFunc :: !LogFunc,
    -- | Application configuration
    config :: !AppConfig,
    -- | Database configuration (for HasDatabaseConfig pattern)
    databaseConfig :: !DatabaseConfig,
    -- | PostgreSQL connection pool (lazy to support in-memory tests)
    dbPool :: ConnectionPool,
    -- | Event store writer (with synchronous event bus)
    eventStoreWriter :: !(AccountingVersionedEventStoreWriter IO),
    -- | Event store reader for loading aggregate state
    eventStoreReader :: !(AccountingVersionedEventStoreReader IO),
    -- | Global event store reader for read models
    globalEventStoreReader :: !(AccountingGlobalEventStoreReader IO),
    -- | In-memory account summary read model (STM)
    accountReadModel :: !(TVar AccountReadModel),
    -- | In-memory transaction summary read model (STM)
    transactionReadModel :: !(TVar TransactionReadModel),
    -- | In-memory user summary read model (STM)
    userReadModel :: !(TVar UserReadModel),
    -- | JWT authentication configuration
    jwtConfig :: !JWTConfig,
    -- | OAuth authentication configuration
    oauthConfig :: !OAuthConfig,
    -- | Telegram authentication configuration
    telegramConfig :: !TelegramConfig,
    -- | Telegram bot state (conversation tracking)
    botState :: !(TVar BotState),
    -- | Telegram API client environment (Nothing if bot token is empty)
    telegramClientEnv :: !(Maybe ClientEnv)
  }

-- | Initialize the application environment.
--
-- This function creates and initializes all application resources:
--  1. Database connection pool
--  2. Event store readers/writers
--  3. Read models
--  4. Process manager registration
--
-- This should be called once at application startup.
--
-- Example:
-- >>> withLogFunc logOptions $ \logFunc -> do
-- >>>   env <- initializeAppEnv logFunc config
-- >>>   runRIO env main
initializeAppEnv ::
  LogFunc ->
  AppConfig ->
  DatabaseConfig ->
  ConnectionPool ->
  AccountingVersionedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  AccountingGlobalEventStoreReader IO ->
  TVar AccountReadModel ->
  TVar TransactionReadModel ->
  TVar UserReadModel ->
  JWTConfig ->
  OAuthConfig ->
  TelegramConfig ->
  TVar BotState ->
  Maybe ClientEnv ->
  AppEnv
initializeAppEnv logFunc config dbConfig pool writer reader globalReader accountReadModel transactionReadModel userReadModel jwtConfig oauthConfig telegramConfig botState telegramClientEnv =
  AppEnv
    { logFunc = logFunc,
      config = config,
      databaseConfig = dbConfig,
      dbPool = pool,
      eventStoreWriter = writer,
      eventStoreReader = reader,
      globalEventStoreReader = globalReader,
      accountReadModel = accountReadModel,
      transactionReadModel = transactionReadModel,
      userReadModel = userReadModel,
      jwtConfig = jwtConfig,
      oauthConfig = oauthConfig,
      telegramConfig = telegramConfig,
      botState = botState,
      telegramClientEnv = telegramClientEnv
    }

-- -----------------------------------------------------------------------------
-- Application Monad
-- -----------------------------------------------------------------------------

-- | Application monad type alias.
--
-- This is the main monad used throughout the application. It's simply RIO
-- with our AppEnv environment.
--
-- Benefits:
--  - MonadReader AppEnv: Access to environment via 'ask' and 'view'
--  - MonadIO: Lift IO operations
--  - MonadUnliftIO: Safe resource management
--  - MonadThrow, MonadCatch: Exception handling
--  - Built-in logging via RIO's logging functions
--
-- Usage:
-- >>> myFunction :: AppM Result
-- >>> myFunction = do
-- >>>   logInfo "Doing something..."
-- >>>   pool <- view dbPoolL
-- >>>   liftIO $ doSomethingWith pool
type AppM = RIO AppEnv

-- -----------------------------------------------------------------------------
-- Type Classes for Resource Access
-- -----------------------------------------------------------------------------

-- | Type class for environments that have a database connection pool.
--
-- Provides a lens to access the connection pool, enabling functions to
-- declare they need database access without depending on the full AppEnv.
--
-- Example:
-- >>> saveData :: (MonadReader env m, HasDbPool env, MonadUnliftIO m) => Data -> m ()
-- >>> saveData dat = do
-- >>>   pool <- view dbPoolL
-- >>>   runDb $ insert dat
class HasDbPool env where
  dbPoolL :: Lens' env ConnectionPool

instance HasDbPool AppEnv where
  dbPoolL = lens (.dbPool) (\x y -> x {dbPool = y})

-- | Type class for environments that have event store access.
--
-- Provides lenses to access event store readers and writers.
--
-- Example:
-- >>> loadAccount :: (MonadReader env m, HasEventStore env, MonadIO m) => UUID -> m Account
-- >>> loadAccount accountId = do
-- >>>   reader <- view eventStoreReaderL
-- >>>   liftIO $ loadAggregate reader accountId
class HasEventStore env where
  eventStoreWriterL :: Lens' env (AccountingVersionedEventStoreWriter IO)
  eventStoreReaderL :: Lens' env (AccountingVersionedEventStoreReader IO)
  globalEventStoreReaderL :: Lens' env (AccountingGlobalEventStoreReader IO)

instance HasEventStore AppEnv where
  eventStoreWriterL = lens (.eventStoreWriter) (\x y -> x {eventStoreWriter = y})
  eventStoreReaderL = lens (.eventStoreReader) (\x y -> x {eventStoreReader = y})
  globalEventStoreReaderL = lens (.globalEventStoreReader) (\x y -> x {globalEventStoreReader = y})

-- | Type class for environments that have read model access.
--
-- Provides lenses to access account, transaction, and user read models.
--
-- Example:
-- >>> getAccount :: (MonadReader env m, HasReadModel env, MonadIO m) => AccountId -> m (Maybe AccountData)
-- >>> getAccount accountId = do
-- >>>   readModel <- view accountReadModelL
-- >>>   liftIO $ getAccount readModel accountId
class HasReadModel env where
  accountReadModelL :: Lens' env (TVar AccountReadModel)
  transactionReadModelL :: Lens' env (TVar TransactionReadModel)
  userReadModelL :: Lens' env (TVar UserReadModel)

instance HasReadModel AppEnv where
  accountReadModelL = lens (.accountReadModel) (\x y -> x {accountReadModel = y})
  transactionReadModelL = lens (.transactionReadModel) (\x y -> x {transactionReadModel = y})
  userReadModelL = lens (.userReadModel) (\x y -> x {userReadModel = y})

-- | Type class for environments that have auth configuration access.
--
-- Provides lenses to access JWT, OAuth, and Telegram configurations.
--
-- Example:
-- >>> verifyToken :: (MonadReader env m, HasAuthConfig env, MonadIO m) => Text -> m (Maybe JWTClaims)
-- >>> verifyToken token = do
-- >>>   jwtConfig <- view jwtConfigL
-- >>>   JWT.verifyToken jwtConfig token
class HasAuthConfig env where
  jwtConfigL :: Lens' env JWTConfig
  oauthConfigL :: Lens' env OAuthConfig
  telegramConfigL :: Lens' env TelegramConfig

instance HasAuthConfig AppEnv where
  jwtConfigL = lens (.jwtConfig) (\x y -> x {jwtConfig = y})
  oauthConfigL = lens (.oauthConfig) (\x y -> x {oauthConfig = y})
  telegramConfigL = lens (.telegramConfig) (\x y -> x {telegramConfig = y})

-- | Type class for environments that have Telegram bot state.
class HasBotState env where
  botStateL :: Lens' env (TVar BotState)

instance HasBotState AppEnv where
  botStateL = lens (.botState) (\x y -> x {botState = y})

-- | Type class for environments that have a Telegram API client.
class HasTelegramClient env where
  telegramClientEnvL :: Lens' env (Maybe ClientEnv)

instance HasTelegramClient AppEnv where
  telegramClientEnvL = lens (.telegramClientEnv) (\x y -> x {telegramClientEnv = y})

-- | Type class for environments that have application configuration.
--
-- Provides a lens to access the application configuration.
--
-- Example:
-- >>> getServerPort :: (MonadReader env m, HasAppConfig env) => m Int
-- >>> getServerPort = do
-- >>>   config <- view appConfigL
-- >>>   return config.server.port
class HasAppConfig env where
  appConfigL :: Lens' env AppConfig

instance HasAppConfig AppEnv where
  appConfigL = lens (.config) (\x y -> x {config = y})

-- | Type class for environments that have database configuration.
--
-- Provides a lens to access the database configuration.
-- This enables functions to use database configuration through the RIO pattern
-- without explicitly passing it as an argument.
--
-- Example:
-- >>> createPool :: (MonadReader env m, HasDatabaseConfig env, MonadIO m) => m ConnectionPool
-- >>> createPool = do
-- >>>   dbConfig <- view databaseConfigL
-- >>>   liftIO $ createPostgresqlPool (buildConnectionString dbConfig) (dbPoolSize dbConfig)
class HasDatabaseConfig env where
  databaseConfigL :: Lens' env DatabaseConfig

instance HasDatabaseConfig AppEnv where
  databaseConfigL = lens (.databaseConfig) (\x y -> x {databaseConfig = y})

-- -----------------------------------------------------------------------------
-- RIO Integration
-- -----------------------------------------------------------------------------

-- | RIO requires HasLogFunc instance for structured logging.
--
-- This enables the use of RIO's logging functions:
--  - logDebug, logInfo, logWarn, logError
--  - Structured logging with context
--  - Automatic log level filtering
instance HasLogFunc AppEnv where
  logFuncL = lens (.logFunc) (\x y -> x {logFunc = y})

-- -----------------------------------------------------------------------------
-- Running the Application
-- -----------------------------------------------------------------------------

-- | Run the application monad with the given environment.
--
-- This is the primary way to execute AppM actions in IO.
--
-- Example:
-- >>> main :: IO ()
-- >>> main = do
-- >>>   env <- initializeAppEnv logFunc config
-- >>>   runAppM env applicationMain
runAppM :: AppEnv -> AppM a -> IO a
runAppM = runRIO

-- -----------------------------------------------------------------------------
-- Database Helpers
-- -----------------------------------------------------------------------------

-- | Run a database action with the connection pool.
--
-- This function bridges the gap between RIO and persistent's SqlPersistT.
-- It properly handles:
--  - Transaction management
--  - Logging integration
--  - Exception handling
--  - Resource cleanup
--
-- Example:
-- >>> saveAccount :: AppM ()
-- >>> saveAccount = runDb $ do
-- >>>   insert $ DbAccount "Savings" 1000.0
-- >>>   insert $ DbAccount "Checking" 500.0
--
-- Note: Database operations run with runStdoutLoggingT for persistent's logging.
runDb ::
  (MonadReader env m, HasDbPool env, MonadUnliftIO m) =>
  ReaderT SqlBackend (LoggingT IO) a ->
  m a
runDb action = do
  pool <- view dbPoolL
  liftIO $ runStdoutLoggingT $ runSqlPool action pool
