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

    -- * Metrics: process-global, registered once
    appMetrics,

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
    HasLlmClient (..),
    HasVersionInfo (..),
    HasBankingEnv (..),
    HasBankImportLocks (..),
    HasHttpManager (..),
    HasBankingKeyRing (..),
    HasBankProviderRegistry (..),
    HasLinkCodeStore (..),
    HasRequestContext (..),
    HasMetrics (..),
    HasLoggerSet (..),

    -- * Banking feature gate
    bankingFeatureEnabled,

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
import Control.Monad.Logger (LoggingT, filterLogger, runLoggingT, runStdoutLoggingT)
import qualified Control.Monad.Logger as ML
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.Set as Set
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import qualified Data.UUID as UUID
import qualified Data.Vault.Lazy as Vault
import Database.Persist.Postgresql (ConnectionPool, SqlBackend, runSqlPool)
import Domain.Core.Types (UserId)
import Infrastructure.Auth.JWT (JWTConfig)
import Infrastructure.Auth.OAuth (OAuthConfig)
import Infrastructure.Auth.Telegram (TelegramConfig)
import Infrastructure.Banking.Registry (BankProviderRegistry)
import Infrastructure.Config
  ( AppConfig (..),
    BankingConfig (..),
    DatabaseConfig,
    Environment (..),
    LoggingConfig (..),
    bankingMasterEnabled,
  )
import qualified Infrastructure.Config as Config
import Infrastructure.Crypto.SecretBox (KeyRing, mkKeyRing)
import Infrastructure.Eventium
  ( AccountingGlobalEventStoreReader,
    AccountingTaggedEventStoreWriter,
    AccountingVersionedEventStoreReader,
  )
import Infrastructure.Llm.Provider (LlmClient)
import Infrastructure.Observability.Context (HasRequestContext (..), RequestContext (..))
import Infrastructure.Observability.Logging (rioLevel, sqlJsonLogSink)
import Infrastructure.Observability.Metrics (HasMetrics (..), Metrics, registerMetrics)
import Infrastructure.Version (VersionInfo)
import Network.HTTP.Client (Manager)
import RIO
import qualified RIO.Text as T
import Servant.Client (ClientEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger (LoggerSet)
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
    -- | LLM client for transaction prompting (Nothing if LLM is disabled)
    llmClient :: !(Maybe LlmClient),
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
    linkCodeStore :: !LinkCodeStore,
    -- | Shared, thread-safe, buffered 'FastLogger.LoggerSet' backing every
    -- 'LogFunc' built via 'Infrastructure.Observability.Logging.mkContextLogFunc' — the
    -- process-base one built in @Main@ and any per-request one built with a
    -- request-scoped 'RequestContext'. Exactly one per process.
    loggerSet :: !LoggerSet,
    -- | The observability context (correlation id, acting user) for the
    -- current scope. On the process-base 'AppEnv' this is
    -- 'Infrastructure.Observability.Context.nilRequestContext'; a
    -- request-scoped 'AppEnv' (a later task) carries the context read from
    -- 'contextVaultKey' via WAI's request 'Vault.Vault'.
    requestContext :: !RequestContext,
    -- | The 'Vault.Key' used to stash/retrieve the per-request
    -- 'RequestContext' on a WAI request's 'Vault.Vault'. Minted once at
    -- startup so every middleware/handler that reads or writes the
    -- request-scoped context agrees on the same key.
    contextVaultKey :: !(Vault.Key RequestContext),
    -- | Registered Prometheus metric handles for event-store telemetry (see
    -- 'Infrastructure.Observability.Metrics'). Always the memoized
    -- 'appMetrics' CAF — see its haddock for why.
    metrics :: !Metrics
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
    -- | Registry of the compiled-in bank provider descriptors that are enabled
    -- for this deployment, keyed by their stable 'Domain.Banking.Types.BankProviderId'.
    -- Assembled in @app/Main.hs@ from the enabled entries of
    -- @banking.providers@. Handlers resolve a connection's provider through the
    -- configuration service ('getConnectionProvider'), which looks the
    -- descriptor up here, so the HTTP layer stays provider-agnostic; tests
    -- install a stub descriptor.
    bankProviderRegistry :: !BankProviderRegistry
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
  Maybe LlmClient ->
  LoggerSet ->
  RequestContext ->
  Vault.Key RequestContext ->
  Metrics ->
  AppEnv
initializeAppEnv logFunc config dbConfig pool writer reader globalReader jwtConfig oauthConfig telegramConfig botState telegramClientEnv versionInfo bankingEnv linkCodeStore' llmClient' loggerSet' requestContext' contextVaultKey' metrics' =
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
      llmClient = llmClient',
      versionInfo = versionInfo,
      bankingEnv = bankingEnv,
      linkCodeStore = linkCodeStore',
      loggerSet = loggerSet',
      requestContext = requestContext',
      contextVaultKey = contextVaultKey',
      metrics = metrics'
    }

-- -----------------------------------------------------------------------------
-- Metrics: process-global, registered once
-- -----------------------------------------------------------------------------

-- | The process-global 'Metrics' handle, registered exactly once.
--
-- 'Prometheus.register' does NOT deduplicate by metric name: calling
-- 'registerMetrics' a second time in the same process would register a
-- second, independent set of handles into the process-global registry,
-- silently duplicating every series on @\/metrics@ (and splitting the counts
-- between the two handles, since only one is ever referenced by any given
-- 'AppEnv'). 'AppEnv' construction is /not/ once-per-process — the test suite
-- builds a fresh 'AppEnv' per spec (see @Testkit.InMemoryEventStore@) — so the
-- registration itself must be memoized rather than tied to 'initializeAppEnv'
-- or a test builder.
--
-- 'unsafePerformIO' is safe here for the same reason it is safe in
-- @prometheus-client@\'s own default registry (also a top-level
-- 'unsafePerformIO' 'IORef'): the action is idempotent-by-construction (it is
-- only ever forced once, the CAF is shared process-wide by 'NOINLINE', and it
-- has no interesting side effect beyond the registration itself). Every
-- 'AppEnv' — production and test — must use this CAF for its 'metrics' field
-- rather than calling 'registerMetrics' directly.
{-# NOINLINE appMetrics #-}
appMetrics :: Metrics
appMetrics = unsafePerformIO registerMetrics

-- -----------------------------------------------------------------------------
-- Banking feature gate
-- -----------------------------------------------------------------------------

-- | Whether the banking feature is globally enabled for this deployment: the
-- master switch ('bankingMasterEnabled') is on AND at least one provider is
-- registered (the registry only ever holds compiled-in, enabled providers).
--
-- The single source of truth for the combined gate, shared by
-- 'Web.API.BankingAPI.requireBankingEnabled' (which wraps it in an
-- @unless … throw@) and 'Web.API.ConfigurationAPI.computeBankingFeatureEnabled'
-- (which surfaces it in the ungated DTO field), so the two cannot drift.
bankingFeatureEnabled ::
  (MonadReader env m, HasAppConfig env, HasBankProviderRegistry env) => m Bool
bankingFeatureEnabled = do
  cfg <- view appConfigL
  reg <- view bankProviderRegistryL
  pure (bankingMasterEnabled cfg.banking && not (null reg))

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

-- | Type class for environments that have an LLM client.
class HasLlmClient env where
  llmClientL :: Lens' env (Maybe LlmClient)

instance HasLlmClient AppEnv where
  llmClientL = lens (.llmClient) (\x y -> x {llmClient = y})

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

-- | Type class for environments that expose the bank provider registry.
-- The configuration service uses this to resolve a connection's provider
-- descriptor (by its 'Domain.Banking.Types.BankProviderId') without depending
-- on a concrete provider implementation, so tests can inject a stub registry.
class HasBankProviderRegistry env where
  bankProviderRegistryL :: Lens' env BankProviderRegistry

instance HasBankProviderRegistry AppEnv where
  bankProviderRegistryL = bankingEnvL . bankProviderRegistryL

instance HasBankProviderRegistry BankingEnv where
  bankProviderRegistryL = lens (.bankProviderRegistry) (\x y -> x {bankProviderRegistry = y})

-- | Type class for environments that have the short-lived Telegram link-code
-- store (used in the bot deep-link account-linking flow).
class HasLinkCodeStore env where
  linkCodeStoreL :: Lens' env LinkCodeStore

instance HasLinkCodeStore AppEnv where
  linkCodeStoreL = lens (.linkCodeStore) (\x y -> x {linkCodeStore = y})

-- | 'AppEnv' carries the observability 'RequestContext' — see
-- "Infrastructure.Observability.Context" for the class and its purpose.
instance HasRequestContext AppEnv where
  requestContextL = lens (.requestContext) (\x y -> x {requestContext = y})

-- | 'AppEnv' carries the registered 'Metrics' handle — see
-- "Infrastructure.Observability.Metrics" for the class and its purpose. The
-- handle stored here is always 'appMetrics', the memoized, process-wide
-- registration.
instance HasMetrics AppEnv where
  metricsL = lens (.metrics) (\x y -> x {metrics = y})

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

-- | Type class for environments that have the shared 'FastLogger.LoggerSet'.
--
-- Lets 'runDb' bridge persistent's SQL debug logging onto the same JSON
-- stdout stream as the rest of the app's structured logging (see
-- "Infrastructure.Observability.Logging".'Infrastructure.Observability.Logging.sqlJsonLogSink') without
-- depending on the full 'AppEnv'.
class HasLoggerSet env where
  loggerSetL :: Lens' env LoggerSet

instance HasLoggerSet AppEnv where
  loggerSetL = lens (.loggerSet) (\x y -> x {loggerSet = y})

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
-- Note: persistent emits each SQL statement at 'LevelDebug'. We gate that on
-- the configured log level, so @[Debug#SQL]@ / SQL JSON lines appear only
-- under @logging.level: debug@ and are silent otherwise.
--
-- In JSON log mode ('Config.LogJson'), the SQL logging is bridged onto the
-- shared 'FastLogger.LoggerSet' as JSON (@source:"sql"@, tagged with the
-- request's correlation id) via 'sqlJsonLogSink', instead of
-- 'runStdoutLoggingT' emitting raw plaintext straight to stdout — see
-- "Infrastructure.Observability.Logging". In text mode ('Config.LogText'),
-- 'runStdoutLoggingT' is kept for dev readability.
runDb ::
  (MonadReader env m, HasDbPool env, HasAppConfig env, HasRequestContext env, HasLoggerSet env, MonadUnliftIO m) =>
  ReaderT SqlBackend (LoggingT IO) a ->
  m a
runDb action = do
  pool <- view dbPoolL
  cfg <- view appConfigL
  ctx <- view requestContextL
  ls <- view loggerSetL
  let threshold = rioLevel cfg.logging.level
      mlThreshold = sqlLogMinLevel cfg.logging.level
      cid = Just (UUID.toText ctx.correlationId)
  liftIO $ case cfg.logging.format of
    Config.LogJson ->
      runLoggingT (runSqlPool action pool) (sqlJsonLogSink threshold cid ls)
    Config.LogText ->
      runStdoutLoggingT $ filterLogger (\_ lvl -> lvl >= mlThreshold) $ runSqlPool action pool

-- | Map the application's configured log level onto @monad-logger@'s, so the
-- text-mode SQL logging (persistent emits at @monad-logger@'s 'ML.LevelDebug')
-- honours the same threshold as the rest of the app. The JSON path uses
-- 'rioLevel' instead ('sqlJsonLogSink' gates in RIO's level space).
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
