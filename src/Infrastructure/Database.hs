{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Infrastructure.Database
-- Description : Database infrastructure and connection management
--
-- This module provides database infrastructure for the accounting system,
-- including PostgreSQL connection pooling, event store initialization,
-- and migration management.
--
-- Key Components:
--   - Connection Pool: Managed PostgreSQL connections
--   - Event Store Initialization: Schema creation and setup
--   - Configuration: Database connection configuration
--   - Migration Runner: Database schema migrations
--
-- Usage:
--
-- Application startup:
-- >>> appConfig <- loadConfigWithEnv "config/local.yaml"
-- >>> let dbConfig = convertDatabaseConfig appConfig.database
-- >>> pool <- createConnectionPool dbConfig
-- >>> initializeDatabase pool
-- >>> -- Database ready to use
--
-- Connection pool pattern:
-- >>> runDb pool $ do
-- >>>   events <- applyAccountCommand writer reader accountId cmd
-- >>>   pure events
--
-- Architecture:
--
-- The database layer provides:
--   1. Connection pooling for efficient resource usage
--   2. Event store schema management via eventium-postgresql
--   3. Custom read model tables (if needed)
--   4. Transaction management
--
-- PostgreSQL is used for:
--   - Event store (via eventium-postgresql)
--   - Read models (optimized queries)
--   - Projections (denormalized views)
module Infrastructure.Database
  ( -- * Configuration
    DatabaseConfig (..),
    defaultDatabaseConfig,
    convertDatabaseConfig,

    -- * Connection Pool (Initialization)
    ConnectionPool,
    createConnectionPool,
    createConnectionPoolNoLogging,

    -- * Database Operations (Low-level, for initialization)

    -- Note: Runtime code should use runDb from Infrastructure.App which uses HasDbPool
    runDbDirect,
    runDbLoggedDirect,

    -- * Initialization
    initializeDatabase,
    initializeEventStore,
    runMigrations,

    -- * Event Store Config
    defaultSqlEventStoreConfig,
    SqlEventStoreConfig,

    -- * Helper Functions
    buildConnectionString,

    -- * Re-exports
    module Database.Persist.Postgresql,
  )
where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger
  ( LogLevel (..),
    LoggingT,
    NoLoggingT (..),
    filterLogger,
    runNoLoggingT,
    runStdoutLoggingT,
  )
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.Persist.Postgresql
  ( ConnectionPool,
    ConnectionString,
    SqlBackend,
    SqlPersistT,
    createPostgresqlPool,
    runMigration,
    runSqlPool,
  )
import Eventium.Store.Sql (SqlEventStoreConfig, defaultSqlEventStoreConfig, migrateSqlEvent)
import qualified Infrastructure.Config as Config

-- -----------------------------------------------------------------------------
-- Database Configuration
-- -----------------------------------------------------------------------------

-- | Database configuration.
--
-- Contains all settings needed to connect to PostgreSQL and configure
-- the connection pool.
--
-- Fields:
--  - host: PostgreSQL host (e.g., "localhost")
--  - port: PostgreSQL port (usually 5432)
--  - name: Database name
--  - user: Database user
--  - password: Database password
--  - poolSize: Connection pool size
--
-- Example:
-- >>> let config = DatabaseConfig
-- >>>       { host = "localhost"
-- >>>       , port = 5432
-- >>>       , name = "accounting"
-- >>>       , user = "postgres"
-- >>>       , password = "postgres"
-- >>>       , poolSize = 10
-- >>>       }
data DatabaseConfig = DatabaseConfig
  { -- | PostgreSQL host
    host :: Text,
    -- | PostgreSQL port
    port :: Int,
    -- | Database name
    name :: Text,
    -- | Database user
    user :: Text,
    -- | Database password
    password :: Text,
    -- | Connection pool size (recommended: numCores * 2)
    poolSize :: Int
  }
  deriving (Show, Eq)

-- | Default database configuration.
--
-- Uses localhost PostgreSQL with common defaults.
-- Suitable for development but should be overridden in production.
--
-- Defaults:
--  - Host: localhost
--  - Port: 5432
--  - Database: accounting
--  - User: postgres
--  - Password: postgres
--  - Pool Size: 10
defaultDatabaseConfig :: DatabaseConfig
defaultDatabaseConfig =
  DatabaseConfig
    { host = "localhost",
      port = 5432,
      name = "accounting",
      user = "postgres",
      password = "postgres",
      poolSize = 10
    }

-- | Convert from Config.DatabaseConfig to Database.DatabaseConfig.
--
-- Infrastructure.Config has its own DatabaseConfig type for loading from YAML,
-- while Infrastructure.Database has its own DatabaseConfig type for connection pooling.
-- This function converts between them.
--
-- This is typically used at application composition root to convert the
-- configuration loaded from YAML into the type needed for database operations.
--
-- Usage:
-- >>> config <- loadConfig "config/local.yaml"
-- >>> let dbConfig = convertDatabaseConfig config.database
-- >>> pool <- createConnectionPool dbConfig
convertDatabaseConfig :: Config.DatabaseConfig -> DatabaseConfig
convertDatabaseConfig cfgDb =
  DatabaseConfig
    { host = cfgDb.host,
      port = cfgDb.port,
      name = cfgDb.database,
      user = cfgDb.user,
      password = cfgDb.password,
      poolSize = cfgDb.poolSize
    }

-- -----------------------------------------------------------------------------
-- Connection String
-- -----------------------------------------------------------------------------

-- | Build PostgreSQL connection string from configuration.
--
-- Creates a connection string suitable for persistent-postgresql.
--
-- Example:
-- >>> buildConnectionString config
-- "host=localhost port=5432 dbname=accounting user=postgres password=postgres"
buildConnectionString :: DatabaseConfig -> ConnectionString
buildConnectionString DatabaseConfig {..} =
  "host="
    <> TE.encodeUtf8 host
    <> " port="
    <> TE.encodeUtf8 (T.pack $ show port)
    <> " dbname="
    <> TE.encodeUtf8 name
    <> " user="
    <> TE.encodeUtf8 user
    <> " password="
    <> TE.encodeUtf8 password

-- -----------------------------------------------------------------------------
-- Connection Pool Management
-- -----------------------------------------------------------------------------

-- | Create a PostgreSQL connection pool.
--
-- Creates a connection pool based on the provided configuration.
-- The pool manages database connections efficiently for concurrent requests.
--
-- Pool Size Guidelines:
--  - Development: 5-10 connections
--  - Production: numCores * 2 + effectiveSpindleCount
--  - Web API: Based on max concurrent requests
--
-- Usage:
-- >>> pool <- createConnectionPool config
--
-- The pool should be created once at application startup and reused
-- throughout the application lifecycle.
--
-- Cleanup:
-- The pool is automatically cleaned up when no longer referenced.
createConnectionPool :: DatabaseConfig -> IO ConnectionPool
createConnectionPool config = do
  let connString = buildConnectionString config
      poolSizeValue = config.poolSize

  -- Create pool with logging (shows SQL in development)
  -- Use runNoLoggingT for production to disable SQL logging
  runStdoutLoggingT $ createPostgresqlPool connString poolSizeValue

-- | Create a PostgreSQL connection pool without logging.
--
-- Same as createConnectionPool but without SQL query logging.
-- Recommended for production use.
--
-- Usage:
-- >>> pool <- createConnectionPoolNoLogging config
createConnectionPoolNoLogging :: DatabaseConfig -> IO ConnectionPool
createConnectionPoolNoLogging config = do
  let connString = buildConnectionString config
      poolSizeValue = config.poolSize
  runNoLoggingT $ createPostgresqlPool connString poolSizeValue

-- -----------------------------------------------------------------------------
-- Database Operations
-- -----------------------------------------------------------------------------

-- | Run a database operation with the connection pool (low-level).
--
-- This is a low-level function for initialization code. Runtime code should
-- prefer the `runDb` function from Infrastructure.App which uses the RIO
-- pattern with HasDbPool.
--
-- Executes a database operation in a transaction using a connection
-- from the pool.
--
-- Usage (initialization only):
-- >>> result <- runDbDirect pool $ do
-- >>>   initializeEventStore
-- >>>   pure ()
--
-- The operation runs in a transaction:
--  - Success: Changes are committed
--  - Exception: Changes are rolled back
runDbDirect :: ConnectionPool -> SqlPersistT IO a -> IO a
runDbDirect = flip runSqlPool

-- | Run a database operation with logging (low-level).
--
-- This is a low-level function for initialization code.
--
-- Same as runDbDirect but logs SQL queries to stdout.
-- Useful for development and debugging during initialization.
--
-- Usage (initialization only):
-- >>> result <- runDbLoggedDirect pool $ do
-- >>>   runMigrations
-- >>>   pure ()
runDbLoggedDirect :: ConnectionPool -> SqlPersistT (LoggingT IO) a -> IO a
runDbLoggedDirect pool action = runStdoutLoggingT $ runSqlPool action pool

-- -----------------------------------------------------------------------------
-- Database Initialization
-- -----------------------------------------------------------------------------

-- | Initialize the database.
--
-- Performs complete database initialization:
--  1. Run migrations (create tables, indexes)
--  2. Initialize event store (eventium tables)
--  3. Create custom tables (read models)
--
-- This should be called once at application startup.
--
-- Usage:
-- >>> pool <- createConnectionPool config
-- >>> initializeDatabase pool
--
-- The function is idempotent - safe to call multiple times.
-- Existing tables and data are preserved.
initializeDatabase :: ConnectionPool -> IO ()
initializeDatabase pool = runDbDirect pool $ do
  -- Run migrations (event store schema)
  runMigrations

  -- Initialize event store (eventium-postgresql)
  initializeEventStore

-- | Initialize the event store schema.
--
-- Creates the event store tables required by eventium-postgresql:
--  - Events table (stores all domain events)
--  - Global events table (maintains global ordering)
--  - Indexes (for fast queries)
--
-- This is called automatically by initializeDatabase.
--
-- The function is idempotent - safe to call multiple times.
initializeEventStore :: (MonadIO m) => SqlPersistT m ()
initializeEventStore = do
  -- Run eventium-postgresql migrations
  -- This creates the event store tables
  void $ runMigration migrateSqlEvent

-- | Run database migrations.
--
-- Runs all database schema migrations:
--  - Event store tables (eventium)
--  - Custom read model tables
--  - Indexes and constraints
--
-- The function is idempotent and safe to call on every startup.
-- It only applies migrations that haven't been applied yet.
--
-- Usage:
-- >>> runDb pool runMigrations
runMigrations :: (MonadIO m) => SqlPersistT m ()
runMigrations = do
  -- Run eventium event store migration
  void $ runMigration migrateSqlEvent

-- NOTE: Read models are currently implemented as in-memory TVars
-- (AccountSummaryReadModel, TransactionSummaryReadModel).
-- This provides fast queries but requires rebuilding on restart.
--
-- If you need durable read models, add persistent-based migrations here:
-- Example:
--   void $ runMigration migrateAccountSummary
--   void $ runMigration migrateTransactionSummary
--
-- See Application.ReadModels.* for current in-memory implementations.

-- | Get the default SQL event store configuration.
--
-- Returns the default configuration used by eventium-postgresql.
-- This configuration works for most use cases.
--
-- Usage:
-- >>> let config = defaultSqlEventStoreConfig
-- >>> let writer = accountingEventStoreWriter config

-- Re-exported from Eventium.Store.Sql
-- defaultSqlEventStoreConfig :: SqlEventStoreConfig

-- -----------------------------------------------------------------------------
-- Connection Management Best Practices
-- -----------------------------------------------------------------------------

{- Connection Pool Sizing

Recommended formulas:

1. General purpose:
   poolSize = numCores * 2 + effectiveSpindleCount

2. Web applications:
   poolSize = maxConcurrentRequests / avgRequestsPerConnection

3. Development:
   poolSize = 5-10

Example sizing for 4-core server with SSD:
  poolSize = 4 * 2 + 1 = 9 connections

Monitor pool usage in production and adjust as needed.
-}

{- Transaction Management

All database operations run in transactions automatically.
This provides ACID guarantees:

- Atomicity: All or nothing
- Consistency: Constraints enforced
- Isolation: Concurrent operations don't interfere
- Durability: Committed changes are permanent

For long-running operations, consider:
1. Breaking into smaller transactions
2. Using optimistic concurrency control
3. Implementing retry logic
-}

{- Error Handling

Database operations can fail due to:
- Connection errors
- Constraint violations
- Deadlocks
- Timeouts

Recommended error handling:
1. Catch and log database exceptions
2. Implement retry logic with exponential backoff
3. Provide meaningful error messages
4. Use monitoring and alerting
-}
