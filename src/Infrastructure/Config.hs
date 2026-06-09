{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Infrastructure.Config
-- Description : Application configuration loading and parsing
--
-- This module provides configuration loading from YAML files with support for
-- environment variable substitution. The configuration is validated at load time
-- to ensure all required values are present and valid.
--
-- Usage:
--   >>> config <- loadConfig "config/local.yaml"
--   >>> case config of
--   >>>   Right appConfig -> runApp appConfig
--   >>>   Left err -> handleError err
module Infrastructure.Config
  ( -- * Configuration Types
    AppConfig (..),
    Environment (..),
    ServerConfig (..),
    DatabaseConfig (..),
    LoggingConfig (..),
    LogLevel (..),
    LogFormat (..),
    CorsConfig (..),
    EventStoreConfig (..),
    ProcessManagerConfig (..),
    ExchangeRateConfig (..),
    BankingConfig (..),
    BankingProvidersConfig (..),
    MonobankProviderConfig (..),
    anyProviderEnabled,
    bankingFeatureAvailable,

    -- * Auth Configuration (re-exports)
    JWTConfig (..),
    OAuthConfig (..),
    TelegramConfig (..),

    -- * Configuration Loading
    loadConfig,
    loadConfigWithEnv,

    -- * Configuration Validation
    validateConfig,

    -- * Environment Variable Substitution
    substituteEnvVars,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (..),
    withObject,
    withText,
    (.!=),
    (.:),
    (.:?),
  )
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Yaml (decodeEither', prettyPrintParseException)
import Domain.ExchangeRate.Events (Provider (..), unProvider)
import GHC.Generics (Generic)
import Infrastructure.Auth.JWT (JWTConfig (..))
import Infrastructure.Auth.OAuth (OAuthConfig (..), applyOAuthDefaults)
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import System.Environment (lookupEnv)
import qualified Text.Read as Read

-- -----------------------------------------------------------------------------
-- Configuration Types
-- -----------------------------------------------------------------------------

-- | Application environment identifier.
data Environment
  = EnvLocal
  | EnvTest
  | EnvProd
  deriving (Show, Eq, Generic)

instance FromJSON Environment where
  parseJSON = withText "Environment" $ \t ->
    case T.toLower t of
      "local" -> pure EnvLocal
      "test" -> pure EnvTest
      "prod" -> pure EnvProd
      _ -> fail $ "Invalid environment: " <> T.unpack t

instance ToJSON Environment where
  toJSON EnvLocal = String "local"
  toJSON EnvTest = String "test"
  toJSON EnvProd = String "prod"

-- | Top-level application configuration.
--
-- Contains all configuration sections for the application including server,
-- database, logging, CORS, event store, and process manager settings.
data AppConfig = AppConfig
  { environment :: !Environment,
    server :: !ServerConfig,
    database :: !DatabaseConfig,
    logging :: !LoggingConfig,
    cors :: !CorsConfig,
    eventStore :: !EventStoreConfig,
    processManagers :: !ProcessManagerConfig,
    auth :: !JWTConfig,
    oauth :: !OAuthConfig,
    telegram :: !TelegramConfig,
    exchangeRate :: !ExchangeRateConfig,
    banking :: !BankingConfig
  }
  deriving (Show, Eq, Generic)

instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \v ->
    AppConfig
      <$> v .: "environment"
      <*> v .: "server"
      <*> v .: "database"
      <*> v .: "logging"
      <*> v .: "cors"
      <*> v .: "event_store"
      <*> v .: "process_managers"
      <*> v .: "auth"
      <*> v .: "oauth"
      <*> v .: "telegram"
      <*> v .: "exchange_rate"
      <*> v .:? "banking" .!= defaultBankingConfig

instance ToJSON AppConfig

-- | Server configuration.
--
-- Defines the host and port for the HTTP server.
--
-- Properties:
--  - serverHost: Network interface to bind to (e.g., "0.0.0.0", "127.0.0.1")
--  - serverPort: TCP port to listen on (1-65535)
data ServerConfig = ServerConfig
  { host :: !Text,
    port :: !Int,
    apiBaseUrl :: !Text,
    appBaseUrl :: !Text
  }
  deriving (Show, Eq, Generic)

instance FromJSON ServerConfig where
  parseJSON = withObject "ServerConfig" $ \v ->
    ServerConfig
      <$> v .: "host"
      <*> v .: "port"
      <*> v .:? "api_base_url" .!= "http://localhost:8080"
      <*> v .:? "app_base_url" .!= "http://localhost:5173"

instance ToJSON ServerConfig

-- | Database configuration.
--
-- PostgreSQL connection settings including connection pool configuration.
--
-- Properties:
--  - dbHost: Database server hostname
--  - dbPort: Database server port (typically 5432)
--  - dbUser: Database username
--  - dbPassword: Database password
--  - dbDatabase: Database name
--  - dbPoolSize: Maximum number of connections in pool
--  - dbConnectionTimeout: Connection timeout in seconds
data DatabaseConfig = DatabaseConfig
  { host :: !Text,
    port :: !Int,
    user :: !Text,
    password :: !Text,
    database :: !Text,
    poolSize :: !Int,
    connectionTimeout :: !Int
  }
  deriving (Show, Eq, Generic)

instance FromJSON DatabaseConfig where
  parseJSON = withObject "DatabaseConfig" $ \v ->
    DatabaseConfig
      <$> v .: "host"
      <*> v .: "port"
      <*> v .: "user"
      <*> v .: "password"
      <*> v .: "database"
      <*> v .: "pool_size"
      <*> v .: "connection_timeout"

instance ToJSON DatabaseConfig

-- | Logging configuration.
--
-- Defines logging level and output format.
data LoggingConfig = LoggingConfig
  { level :: !LogLevel,
    format :: !LogFormat
  }
  deriving (Show, Eq, Generic)

instance FromJSON LoggingConfig where
  parseJSON = withObject "LoggingConfig" $ \v ->
    LoggingConfig
      <$> v .: "level"
      <*> v .: "format"

instance ToJSON LoggingConfig

-- | Log level enumeration.
--
-- Defines the verbosity of logging output.
data LogLevel
  = LogDebug
  | LogInfo
  | LogWarn
  | LogError
  deriving (Show, Eq, Generic)

instance FromJSON LogLevel where
  parseJSON = withText "LogLevel" $ \t ->
    case T.toLower t of
      "debug" -> pure LogDebug
      "info" -> pure LogInfo
      "warn" -> pure LogWarn
      "warning" -> pure LogWarn
      "error" -> pure LogError
      _ -> fail $ "Invalid log level: " <> T.unpack t

instance ToJSON LogLevel where
  toJSON LogDebug = String "debug"
  toJSON LogInfo = String "info"
  toJSON LogWarn = String "warn"
  toJSON LogError = String "error"

-- | Log format enumeration.
--
-- Defines the output format for log messages.
data LogFormat
  = LogText
  | LogJson
  deriving (Show, Eq, Generic)

instance FromJSON LogFormat where
  parseJSON = withText "LogFormat" $ \t ->
    case T.toLower t of
      "text" -> pure LogText
      "json" -> pure LogJson
      _ -> fail $ "Invalid log format: " <> T.unpack t

instance ToJSON LogFormat where
  toJSON LogText = String "text"
  toJSON LogJson = String "json"

-- | CORS configuration.
--
-- Cross-Origin Resource Sharing settings for the HTTP server.
data CorsConfig = CorsConfig
  { enabled :: !Bool,
    allowedOrigins :: ![Text],
    allowedMethods :: ![Text],
    allowedHeaders :: ![Text],
    maxAge :: !(Maybe Int)
  }
  deriving (Show, Eq, Generic)

instance FromJSON CorsConfig where
  parseJSON = withObject "CorsConfig" $ \v ->
    CorsConfig
      <$> v .: "enabled"
      <*> v .: "allowed_origins"
      <*> v .: "allowed_methods"
      <*> v .: "allowed_headers"
      <*> v .:? "max_age"

instance ToJSON CorsConfig

-- | Event store configuration.
--
-- Settings for the event sourcing event store.
data EventStoreConfig = EventStoreConfig
  { snapshotFrequency :: !Int
  }
  deriving (Show, Eq, Generic)

instance FromJSON EventStoreConfig where
  parseJSON = withObject "EventStoreConfig" $ \v ->
    EventStoreConfig
      <$> v .: "snapshot_frequency"

instance ToJSON EventStoreConfig

-- | Process manager configuration.
--
-- Settings for process managers (sagas) that coordinate across aggregates.
data ProcessManagerConfig = ProcessManagerConfig
  { pollIntervalMs :: !Int
  }
  deriving (Show, Eq, Generic)

instance FromJSON ProcessManagerConfig where
  parseJSON = withObject "ProcessManagerConfig" $ \v ->
    ProcessManagerConfig
      <$> v .: "poll_interval_ms"

instance ToJSON ProcessManagerConfig

-- | Exchange rate provider configuration.
data ExchangeRateConfig = ExchangeRateConfig
  { provider :: !Provider
  }
  deriving (Show, Eq, Generic)

instance FromJSON ExchangeRateConfig where
  parseJSON = withObject "ExchangeRateConfig" $ \v ->
    ExchangeRateConfig
      <$> v .: "provider"

instance ToJSON ExchangeRateConfig

-- | Banking integration configuration.
data BankingConfig = BankingConfig
  { enabled :: !Bool,
    providers :: !BankingProvidersConfig,
    -- | Base64-encoded 32-byte key used to encrypt persisted bank-connection
    -- access tokens (see 'Infrastructure.Crypto.SecretBox'). Sourced from the
    -- @BANKING_TOKEN_ENC_KEY@ environment variable via the @token_enc_key@
    -- YAML key. Decoded and validated into a 'KeyRing' at startup; defaults to
    -- the empty string when unset (rejected outside the dev/test environment).
    tokenEncKey :: !Text
  }
  deriving (Show, Eq, Generic)

instance FromJSON BankingConfig where
  parseJSON = withObject "BankingConfig" $ \v ->
    BankingConfig
      <$> v .:? "enabled" .!= False
      <*> v .:? "providers" .!= defaultBankingProviders
      <*> v .:? "token_enc_key" .!= ""

instance ToJSON BankingConfig

defaultBankingConfig :: BankingConfig
defaultBankingConfig = BankingConfig False defaultBankingProviders ""

data BankingProvidersConfig = BankingProvidersConfig
  { monobank :: !MonobankProviderConfig
  }
  deriving (Show, Eq, Generic)

instance FromJSON BankingProvidersConfig where
  parseJSON = withObject "BankingProvidersConfig" $ \v ->
    BankingProvidersConfig
      <$> v .:? "monobank" .!= MonobankProviderConfig False defaultMonoApiBaseUrl

instance ToJSON BankingProvidersConfig

defaultBankingProviders :: BankingProvidersConfig
defaultBankingProviders = BankingProvidersConfig (MonobankProviderConfig False defaultMonoApiBaseUrl)

-- | Upstream Monobank API base URL, used as the fallback when no override is
-- supplied in the YAML config. Tests and production deployments override via
-- the @api_base_url@ key under @banking.providers.monobank@.
defaultMonoApiBaseUrl :: Text
defaultMonoApiBaseUrl = "https://api.monobank.ua"

data MonobankProviderConfig = MonobankProviderConfig
  { enabled :: !Bool,
    apiBaseUrl :: !Text
  }
  deriving (Show, Eq, Generic)

instance FromJSON MonobankProviderConfig where
  parseJSON = withObject "MonobankProviderConfig" $ \v ->
    MonobankProviderConfig
      <$> v .:? "enabled" .!= False
      <*> v .:? "api_base_url" .!= defaultMonoApiBaseUrl

instance ToJSON MonobankProviderConfig

-- | True when at least one bank provider is enabled. Aggregates across all
-- providers (currently just monobank) so adding a provider automatically
-- participates in the banking feature gate.
anyProviderEnabled :: BankingProvidersConfig -> Bool
anyProviderEnabled providers = or [providers.monobank.enabled]

-- | True when the banking feature is globally available: the master switch is
-- on AND at least one provider is enabled.
bankingFeatureAvailable :: BankingConfig -> Bool
bankingFeatureAvailable cfg = cfg.enabled && anyProviderEnabled cfg.providers

-- -----------------------------------------------------------------------------
-- Configuration Loading
-- -----------------------------------------------------------------------------

-- | Load configuration from a YAML file.
--
-- Reads and parses a YAML configuration file. Does not perform environment
-- variable substitution.
--
-- >>> loadConfig "config/local.yaml"
-- Right (AppConfig {...})
--
-- Returns an error if:
--  - File cannot be read
--  - YAML parsing fails
--  - Configuration validation fails
loadConfig :: FilePath -> IO (Either Text AppConfig)
loadConfig path = do
  result <- try $ BS.readFile path
  case result of
    Left (err :: IOException) ->
      pure $ Left $ T.pack $ "Failed to read config file: " <> show err
    Right contents ->
      case decodeEither' contents of
        Left err ->
          pure $ Left $ T.pack $ "Failed to parse config: " <> prettyPrintParseException err
        Right config -> do
          let configWithDefaults = config {oauth = applyOAuthDefaults config.oauth}
          case validateConfig configWithDefaults of
            Left validationErr -> pure $ Left validationErr
            Right () -> pure $ Right configWithDefaults

-- | Load configuration from a YAML file with environment variable substitution.
--
-- Reads and parses a YAML configuration file, substituting environment variables
-- in string values. Environment variables should be in the format ${VAR_NAME}.
--
-- >>> loadConfigWithEnv "config/prod.yaml"
-- Right (AppConfig {...})
--
-- This function:
--  1. Reads the YAML file
--  2. Substitutes environment variables
--  3. Parses the configuration
--  4. Validates the result
--
-- Returns an error if:
--  - File cannot be read
--  - YAML parsing fails
--  - Required environment variable is not set
--  - Configuration validation fails
loadConfigWithEnv :: FilePath -> IO (Either Text AppConfig)
loadConfigWithEnv path = do
  result <- try $ BS.readFile path
  case result of
    Left (err :: IOException) ->
      pure $ Left $ "Failed to read config file: " <> T.pack (show err)
    Right contents -> do
      -- Decode to JSON Value first for env var substitution
      case decodeEither' contents of
        Left err ->
          pure $ Left $ "Failed to parse config: " <> T.pack (prettyPrintParseException err)
        Right (value :: Value) -> do
          -- Substitute environment variables
          substitutedValue <- substituteEnvVars value
          case substitutedValue of
            Left err -> pure $ Left err
            Right newValue ->
              -- Parse the substituted value into AppConfig
              case Aeson.fromJSON newValue of
                Aeson.Error err ->
                  pure $ Left $ T.pack $ "Failed to parse config after substitution: " <> err
                Aeson.Success config -> do
                  let configWithDefaults = config {oauth = applyOAuthDefaults config.oauth}
                  case validateConfig configWithDefaults of
                    Left validationErr -> pure $ Left validationErr
                    Right () -> pure $ Right configWithDefaults

-- | Substitute environment variables in a JSON value.
--
-- Recursively traverses a JSON value and replaces strings of the format
-- \${VAR_NAME} with the value of the environment variable VAR_NAME.
--
-- Returns an error if a required environment variable is not set.
substituteEnvVars :: Value -> IO (Either Text Value)
substituteEnvVars = go
  where
    go :: Value -> IO (Either Text Value)
    go (Object obj) = do
      results <- traverse go obj
      pure $ Object <$> sequenceA results
    go (Array arr) = do
      results <- traverse go arr
      pure $ Array <$> sequenceA results
    go (String text) = do
      result <- substituteText text
      case result of
        Left err -> pure $ Left err
        Right (wasWholeString, newText)
          | wasWholeString -> pure $ Right $ coerceValue newText
          | otherwise -> pure $ Right $ String newText
    go other = pure $ Right other

    -- \| Scan the input text, resolving every @${…}@ occurrence in place and
    -- concatenating the results with the surrounding literal text.
    --
    -- Returns @(wasWholeString, result)@.  @wasWholeString@ is 'True' when the
    -- entire input was exactly one @${…}@ expression with no surrounding
    -- literals — the caller uses this to decide whether 'coerceValue' should
    -- run (preserving the legacy behaviour where @${PORT}@ becomes a
    -- 'Number').
    substituteText :: Text -> IO (Either Text (Bool, Text))
    substituteText input = scan input mempty
      where
        scan remaining acc =
          case T.breakOn "${" remaining of
            (prefix, rest)
              | T.null rest ->
                  -- No more ${ in the remainder: we're done.
                  pure $ Right (wasWholeString prefix acc, acc <> prefix)
              | otherwise ->
                  let afterOpen = T.drop 2 rest
                   in case T.breakOn "}" afterOpen of
                        (_, closeRest)
                          | T.null closeRest ->
                              -- No closing brace: treat the rest as literal text.
                              pure $ Right (False, acc <> prefix <> rest)
                        (expr, closeRest) -> do
                          let afterClose = T.drop 1 closeRest
                              (varName, mDefault) = parseVarExpr expr
                          envValue <- lookupEnv (T.unpack varName)
                          case (envValue, mDefault) of
                            (Just val, _) ->
                              scan afterClose (acc <> prefix <> T.pack val)
                            (Nothing, Just def') ->
                              scan afterClose (acc <> prefix <> def')
                            (Nothing, Nothing) ->
                              pure $
                                Left $
                                  "Environment variable not set: " <> varName

        -- True when the entire original input was exactly one @${…}@ with no
        -- surrounding literal characters.
        wasWholeString prefix acc =
          T.null prefix
            && not (T.null acc)
            && "${" `T.isPrefixOf` input
            && "}" `T.isSuffixOf` input
            && T.count "${" input == 1

    -- \| Split @VAR_NAME:-default@ into the variable name and an optional
    -- default value.  If the @:-@ separator is absent, no default is
    -- returned.
    parseVarExpr :: Text -> (Text, Maybe Text)
    parseVarExpr expr =
      case T.breakOn ":-" expr of
        (name, rest)
          | T.null rest -> (name, Nothing)
          | otherwise -> (name, Just $ T.drop 2 rest)

    -- \| Attempt to coerce a substituted text value to the appropriate JSON
    -- type.  Environment variable substitution always produces 'Text', but
    -- downstream 'FromJSON' instances expect 'Number', 'Bool', or 'Null'
    -- for non-string fields.
    coerceValue :: Text -> Value
    coerceValue t
      | T.null t = String t -- preserve empty strings for Text fields
      | T.toLower t == "null" = Null
      | T.toLower t == "true" = Bool True
      | T.toLower t == "false" = Bool False
      | Just n <- Read.readMaybe (T.unpack t) :: Maybe Integer =
          Number (fromInteger n)
      | Just d <- Read.readMaybe (T.unpack t) :: Maybe Double =
          Number (realToFrac d)
      | otherwise = String t

-- -----------------------------------------------------------------------------
-- Configuration Validation
-- -----------------------------------------------------------------------------

-- | Validate application configuration.
--
-- Checks that all configuration values are within valid ranges and make sense.
--
-- Validation rules:
--  - Server port must be between 1 and 65535
--  - Database port must be between 1 and 65535
--  - Database pool size must be positive
--  - Database connection timeout must be positive
--  - Snapshot frequency must be positive
--  - Poll interval must be positive
validateConfig :: AppConfig -> Either Text ()
validateConfig config = do
  -- Validate server config
  let serverPortValue = config.server.port
  when (serverPortValue < 1 || serverPortValue > 65535) $
    Left $
      "Invalid server port: " <> T.pack (show serverPortValue) <> " (must be 1-65535)"

  -- Validate database config
  let dbPortValue = config.database.port
  when (dbPortValue < 1 || dbPortValue > 65535) $
    Left $
      "Invalid database port: " <> T.pack (show dbPortValue) <> " (must be 1-65535)"

  let poolSizeValue = config.database.poolSize
  when (poolSizeValue < 1) $
    Left $
      "Invalid database pool size: " <> T.pack (show poolSizeValue) <> " (must be positive)"

  let connTimeout = config.database.connectionTimeout
  when (connTimeout < 1) $
    Left $
      "Invalid database connection timeout: " <> T.pack (show connTimeout) <> " (must be positive)"

  -- Validate event store config
  let snapshotFreq = config.eventStore.snapshotFrequency
  when (snapshotFreq < 1) $
    Left $
      "Invalid snapshot frequency: " <> T.pack (show snapshotFreq) <> " (must be positive)"

  -- Validate process manager config
  let pollInterval = config.processManagers.pollIntervalMs
  when (pollInterval < 1) $
    Left $
      "Invalid poll interval: " <> T.pack (show pollInterval) <> " (must be positive)"

  -- Validate exchange rate config
  let providerValue = config.exchangeRate.provider
  when (providerValue `notElem` [Provider "ecb", Provider "nbu"]) $
    Left $
      "Invalid exchange rate provider: " <> unProvider providerValue <> " (must be \"ecb\" or \"nbu\")"

-- Helper function for when
when :: Bool -> Either Text () -> Either Text ()
when True action = action
when False _ = Right ()
