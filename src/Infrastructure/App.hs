{-# LANGUAGE OverloadedStrings #-}
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
--   - Type classes: HasDbPool, HasEventStore for dependency access
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
    BankingEnv (..),
    initializeAppEnv,

    -- * Application Monad
    AppM,

    -- * Type Classes for Resource Access
    HasDbPool (..),
    HasEventStore (..),
    HasAppConfig (..),
    HasDatabaseConfig (..),
    HasAuthConfig (..),
    HasBotState (..),
    HasTelegramClient (..),
    HasVersionInfo (..),
    HasBankingEnv (..),
    HasBankImportLocks (..),
    HasHttpManager (..),
    HasBankingKeyRing (..),
    HasBankProviderFactory (..),
    HasLinkCodeStore (..),

    -- * Banking provider factory
    BankProviderFactory,

    -- * Banking key ring construction
    bankingKeyRingFromConfig,

    -- * Running the Application
    runAppM,

    -- * Database Helpers
    runDb,

    -- * Concurrency Helpers
    withUserLock,

    -- * RIO Re-exports
    module RIO,
  )
where

-- Local imports
import Application.LinkCodeStore (LinkCodeStore)
import Control.Concurrent.STM (retry)
import Control.Monad.Logger (LoggingT, filterLogger, runStdoutLoggingT)
import qualified Control.Monad.Logger as ML
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.Set as Set
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Database.Persist.Postgresql (ConnectionPool, SqlBackend, runSqlPool)
import Domain.Banking.Types (PlainToken)
import qualified Domain.Banking.Types as Domain
import Domain.Core.Types (UserId)
import Infrastructure.Auth.JWT (JWTConfig)
import Infrastructure.Auth.OAuth (OAuthConfig)
import Infrastructure.Auth.Telegram (TelegramConfig)
import Infrastructure.Banking.Provider (BankProvider)
import Infrastructure.Config
  ( AppConfig (..),
    BankingConfig (..),
    DatabaseConfig,
    Environment (..),
    LoggingConfig (..),
  )
import qualified Infrastructure.Config as Config
import Infrastructure.Crypto.SecretBox (KeyRing, mkKeyRing)
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
  )
import Infrastructure.Version (VersionInfo)
import Network.HTTP.Client (Manager)
import RIO
import qualified RIO.Text as T
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
--    (all read models are persistent SQL, accessed via 'runDb')
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
    -- | Tagged event store writer (with synchronous event bus and per-call MetadataEnricher support)
    eventStoreWriter :: !(AccountingTaggedEventStoreWriter IO),
    -- | Event store reader for loading aggregate state
    eventStoreReader :: !(AccountingVersionedEventStoreReader IO),
    -- | Global event store reader for read models
    globalEventStoreReader :: !(AccountingGlobalEventStoreReader IO),
    -- | JWT authentication configuration
    jwtConfig :: !JWTConfig,
    -- | OAuth authentication configuration
    oauthConfig :: !OAuthConfig,
    -- | Telegram authentication configuration
    telegramConfig :: !TelegramConfig,
    -- | Telegram bot state (conversation tracking)
    botState :: !(TVar BotState),
    -- | Telegram API client environment (Nothing if bot token is empty)
    telegramClientEnv :: !(Maybe ClientEnv),
    -- | Application version information
    versionInfo :: !VersionInfo,
    -- | Banking-subsystem runtime dependencies (dedup read model,
    -- per-user import locks, shared HTTP manager). Grouped into a
    -- 'BankingEnv' to keep 'AppEnv' uncluttered; access the individual
    -- resources through their capability classes ('HasBankImportReadModel',
    -- 'HasBankImportLocks', 'HasHttpManager') which are re-exported from
    -- 'BankingEnv'. Named 'bankingEnv' to avoid clashing with
    -- 'AppConfig.banking'.
    bankingEnv :: !BankingEnv,
    -- | In-memory store for short-lived, single-use Telegram link codes
    -- used in the bot deep-link account-linking flow.
    linkCodeStore :: !LinkCodeStore
  }

-- | Runtime dependencies scoped to the banking subsystem.
--
-- Held as a single field on 'AppEnv' so the top-level environment stays
-- focused on cross-cutting resources (logging, DB, event store, read
-- models, auth). The narrow capability classes ('HasBankImportReadModel',
-- 'HasBankImportLocks', 'HasHttpManager') still give call-sites dependency
-- injection without leaking the full 'AppEnv' — the grouping is purely
-- organisational.
data BankingEnv = BankingEnv
  { -- | Per-user bank-import serialization locks (STM). Holds the set of
    -- 'UserId' values whose bank import is currently in flight.
    bankImportLocks :: !(TVar (Set.Set UserId)),
    -- | HTTP client manager (shared, for bank API calls).
    httpManager :: !Manager,
    -- | Key ring used to encrypt/decrypt persisted bank-connection access
    -- tokens (see 'Infrastructure.Crypto.SecretBox'). Built from
    -- @banking.token_enc_key@ at startup via 'bankingKeyRingFromConfig'.
    bankingKeyRing :: !KeyRing,
    -- | Factory that builds a (per-request, ephemeral) 'BankProvider' from a
    -- connection's 'Domain.BankProvider' and a user's decrypted access token.
    -- Production wires this via 'mkBankProviderFactory', which dispatches on
    -- the provider enum and captures the per-provider config (e.g. the
    -- Monobank API base URL) and the shared 'Manager' at env-build time; tests
    -- install an in-memory stub. Handlers obtain the provider through the
    -- configuration service ('getConnectionProvider') rather than constructing
    -- a concrete provider inline, which keeps the HTTP layer
    -- provider-injectable. 'BankProvider' itself stays ephemeral (see
    -- 'Infrastructure.Banking.Provider'); only the factory is held in the env.
    bankProviderFactory :: !BankProviderFactory
  }

-- | A pure factory producing an ephemeral 'BankProvider' from a connection's
-- 'Domain.BankProvider' and a user's decrypted access token. All
-- provider-specific configuration (e.g. the Monobank API base URL) and the
-- shared HTTP 'Manager' (or, for tests, the stub state) are captured in the
-- closure at env-build time, so the factory dispatches on the provider enum
-- without exposing any provider internals to its callers.
type BankProviderFactory = Domain.BankProvider {- provider -} -> PlainToken {- token -} -> BankProvider

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
  AccountingTaggedEventStoreWriter IO ->
  AccountingVersionedEventStoreReader IO ->
  AccountingGlobalEventStoreReader IO ->
  JWTConfig ->
  OAuthConfig ->
  TelegramConfig ->
  TVar BotState ->
  Maybe ClientEnv ->
  VersionInfo ->
  BankingEnv ->
  LinkCodeStore ->
  AppEnv
initializeAppEnv logFunc config dbConfig pool writer reader globalReader jwtConfig oauthConfig telegramConfig botState telegramClientEnv versionInfo bankingEnv linkCodeStore' =
  AppEnv
    { logFunc = logFunc,
      config = config,
      databaseConfig = dbConfig,
      dbPool = pool,
      eventStoreWriter = writer,
      eventStoreReader = reader,
      globalEventStoreReader = globalReader,
      jwtConfig = jwtConfig,
      oauthConfig = oauthConfig,
      telegramConfig = telegramConfig,
      botState = botState,
      telegramClientEnv = telegramClientEnv,
      versionInfo = versionInfo,
      bankingEnv = bankingEnv,
      linkCodeStore = linkCodeStore'
    }

-- -----------------------------------------------------------------------------
-- Banking key ring construction
-- -----------------------------------------------------------------------------

-- | Build the banking token-encryption 'KeyRing' from configuration.
--
-- The configured @banking.token_enc_key@ is base64-decoded and must yield
-- exactly 32 bytes (AES-256). The resulting ring designates key version @1@
-- as the current key.
--
-- Behaviour when the key is missing or invalid:
--
--   * In production ('EnvProd') the application __fails fast__ — a missing or
--     wrong-length key aborts startup via 'exitFailure', because operating
--     without a valid key would silently disable token encryption.
--   * In the local/test environments ('EnvLocal', 'EnvTest') a fixed,
--     well-known development key is substituted and a warning is logged, so
--     developers and the test suite can run without provisioning a real key.
--     This key is __not secret__ and must never be used in production.
bankingKeyRingFromConfig :: Environment -> BankingConfig -> IO KeyRing
bankingKeyRingFromConfig env cfg =
  case decodeKey cfg.tokenEncKey of
    Right key -> pure (mkKeyRing 1 [(1, key)])
    Left reason ->
      if isDev
        then do
          TIO.hPutStrLn
            stderr
            ( "WARNING: banking.token_enc_key "
                <> T.pack reason
                <> "; using an insecure fixed development key. "
                <> "Do NOT use this in production."
            )
          pure (mkKeyRing 1 [(1, devKey)])
        else do
          TIO.hPutStrLn
            stderr
            ( "FATAL: banking.token_enc_key "
                <> T.pack reason
                <> ". Set BANKING_TOKEN_ENC_KEY to a base64-encoded 32-byte key."
            )
          exitFailure
  where
    isDev = env == EnvLocal || env == EnvTest

    -- \| Decode and length-validate the configured key. 'Left' carries a
    -- human-readable reason suitable for a log message.
    decodeKey :: Text -> Either String BS.ByteString
    decodeKey t
      | T.null t = Left "is not set"
      | otherwise =
          case B64.decode (TE.encodeUtf8 t) of
            Left err -> Left ("is not valid base64 (" <> err <> ")")
            Right bs
              | BS.length bs == 32 -> Right bs
              | otherwise ->
                  Left
                    ( "must decode to 32 bytes but decoded to "
                        <> show (BS.length bs)
                    )

    -- \| Insecure, fixed 32-byte development key. Distinct, recognisable
    -- bytes so it never collides with a real key by accident.
    devKey :: BS.ByteString
    devKey = BS.pack [0xDE, 0xAD, 0xBE, 0xEF] <> BS.replicate 28 0x2A

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
  eventStoreWriterL :: Lens' env (AccountingTaggedEventStoreWriter IO)
  eventStoreReaderL :: Lens' env (AccountingVersionedEventStoreReader IO)
  globalEventStoreReaderL :: Lens' env (AccountingGlobalEventStoreReader IO)

instance HasEventStore AppEnv where
  eventStoreWriterL = lens (.eventStoreWriter) (\x y -> x {eventStoreWriter = y})
  eventStoreReaderL = lens (.eventStoreReader) (\x y -> x {eventStoreReader = y})
  globalEventStoreReaderL = lens (.globalEventStoreReader) (\x y -> x {globalEventStoreReader = y})

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

-- | Type class for environments that have version information.
class HasVersionInfo env where
  versionInfoL :: Lens' env VersionInfo

instance HasVersionInfo AppEnv where
  versionInfoL = lens (.versionInfo) (\x y -> x {versionInfo = y})

-- | Type class for environments that expose the banking subsystem's
-- runtime dependencies as a group.
--
-- The narrow capability classes ('HasBankImportReadModel',
-- 'HasBankImportLocks', 'HasHttpManager') are defined in terms of this one
-- so that any env with a 'BankingEnv' automatically gets all three.
class HasBankingEnv env where
  bankingEnvL :: Lens' env BankingEnv

instance HasBankingEnv AppEnv where
  bankingEnvL = lens (.bankingEnv) (\x y -> x {bankingEnv = y})

instance HasBankingEnv BankingEnv where
  bankingEnvL = id

-- | Type class for environments that have the per-user bank-import lock set.
--
-- The lock set serializes @resync@/import operations per user so that a
-- second request does not race the first and produce duplicate transfers
-- through a dedup TOCTOU window.
class HasBankImportLocks env where
  bankImportLocksL :: Lens' env (TVar (Set.Set UserId))

instance HasBankImportLocks AppEnv where
  bankImportLocksL = bankingEnvL . bankImportLocksL

instance HasBankImportLocks BankingEnv where
  bankImportLocksL = lens (.bankImportLocks) (\x y -> x {bankImportLocks = y})

-- | Type class for environments that have an HTTP client manager.
class HasHttpManager env where
  httpManagerL :: Lens' env Manager

instance HasHttpManager AppEnv where
  httpManagerL = bankingEnvL . httpManagerL

instance HasHttpManager BankingEnv where
  httpManagerL = lens (.httpManager) (\x y -> x {httpManager = y})

-- | Type class for environments that expose the banking token-encryption
-- 'KeyRing'. Used by the configuration service to encrypt/decrypt persisted
-- bank-connection access tokens.
class HasBankingKeyRing env where
  bankingKeyRingL :: Lens' env KeyRing

instance HasBankingKeyRing AppEnv where
  bankingKeyRingL = bankingEnvL . bankingKeyRingL

instance HasBankingKeyRing BankingEnv where
  bankingKeyRingL = lens (.bankingKeyRing) (\x y -> x {bankingKeyRing = y})

-- | Type class for environments that expose the banking provider factory.
-- The configuration service uses this to obtain an ephemeral 'BankProvider'
-- (from a connection's 'Domain.BankProvider' + decrypted token) without
-- depending on a concrete provider implementation, so tests can inject an
-- in-memory stub.
class HasBankProviderFactory env where
  bankProviderFactoryL :: Lens' env BankProviderFactory

instance HasBankProviderFactory AppEnv where
  bankProviderFactoryL = bankingEnvL . bankProviderFactoryL

instance HasBankProviderFactory BankingEnv where
  bankProviderFactoryL = lens (.bankProviderFactory) (\x y -> x {bankProviderFactory = y})

-- | Type class for environments that have the short-lived Telegram link-code
-- store (used in the bot deep-link account-linking flow).
class HasLinkCodeStore env where
  linkCodeStoreL :: Lens' env LinkCodeStore

instance HasLinkCodeStore AppEnv where
  linkCodeStoreL = lens (.linkCodeStore) (\x y -> x {linkCodeStore = y})

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
-- Note: persistent emits each SQL statement at 'ML.LevelDebug'. We gate that on
-- the configured log level via 'filterLogger', so @[Debug#SQL]@ lines appear
-- only under @logging.level: debug@ and are silent otherwise.
runDb ::
  (MonadReader env m, HasDbPool env, HasAppConfig env, MonadUnliftIO m) =>
  ReaderT SqlBackend (LoggingT IO) a ->
  m a
runDb action = do
  pool <- view dbPoolL
  cfg <- view appConfigL
  let minLevel = sqlLogMinLevel cfg.logging.level
  liftIO $ runStdoutLoggingT $ filterLogger (\_ lvl -> lvl >= minLevel) $ runSqlPool action pool

-- | Map the application's configured log level onto monad-logger's, so SQL
-- logging (emitted at 'ML.LevelDebug') honours the same threshold as the rest
-- of the app.
sqlLogMinLevel :: Config.LogLevel -> ML.LogLevel
sqlLogMinLevel Config.LogDebug = ML.LevelDebug
sqlLogMinLevel Config.LogInfo = ML.LevelInfo
sqlLogMinLevel Config.LogWarn = ML.LevelWarn
sqlLogMinLevel Config.LogError = ML.LevelError

-- -----------------------------------------------------------------------------
-- Concurrency Helpers
-- -----------------------------------------------------------------------------

-- | Serialize an action per user using the 'bankImportLocks' STM set.
--
-- Acquires a per-user lock by inserting the 'UserId' into the shared
-- @TVar (Set UserId)@. If the user is already present, the STM
-- transaction 'retry's — which blocks the caller until a transaction
-- mutating the set commits (i.e. until the first holder releases).
-- On exit (normal or exception) the 'UserId' is removed.
--
-- This closes the TOCTOU window between the bank-import dedup check
-- ('isImported') and the 'TransactionPostingInitiated' emit: with the lock held,
-- two concurrent @resync@ calls for the same user are serialized, so
-- at most one in-flight resync per user per process.
--
-- __Warning:__ this lock is non-reentrant. Do not nest 'withUserLock'
-- for the same 'UserId' — the inner call will @retry@ forever and
-- deadlock the thread.
--
-- Example:
-- >>> resync provider userId link from to =
-- >>>   withUserLock userId $ do
-- >>>     ... -- existing body
withUserLock ::
  (MonadReader env m, HasBankImportLocks env, MonadUnliftIO m) =>
  UserId ->
  m a ->
  m a
withUserLock uid action = do
  locksVar <- view bankImportLocksL
  bracket_ (acquire locksVar) (release locksVar) action
  where
    acquire locksVar = atomically $ do
      locks <- readTVar locksVar
      if Set.member uid locks
        then retry
        else writeTVar locksVar (Set.insert uid locks)
    release locksVar = atomically $ modifyTVar' locksVar (Set.delete uid)
