{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.Server
-- Description : HTTP server setup and configuration using Warp
--
-- This module provides the HTTP server implementation using Warp, including
-- middleware for request context, metrics, CORS, logging, error handling,
-- and request/response processing.
--
-- Architecture:
--
--   HTTP Request
--     ↓
--   Warp Server (runSettings)
--     ↓
--   Middleware Stack (applied bottom-to-top):
--     ├─→ CORS Middleware (cross-origin resource sharing)
--     ├─→ Error Handling Middleware (uncaught exceptions)
--     ├─→ Metrics Middleware (/metrics endpoint + HTTP request duration)
--     ├─→ Logging Middleware (request/response logging; LogText mode only)
--     ├─→ Context Middleware (correlation id + best-effort user, outermost)
--     └─→ Compression Middleware (gzip responses)
--     ↓
--   Servant Application (per-request re-hoisted with the request's context)
--     ↓
--   AppM Handlers → Natural Transformation → Handler
--     ↓
--   Response (JSON)
--
-- Server Configuration:
--
--   The server is configured with:
--     - Port from configuration (default: 8080)
--     - Host binding (0.0.0.0 for all interfaces)
--     - Request timeout (30 seconds)
--     - Graceful shutdown (wait for in-flight requests)
--     - Structured logging (RIO LogFunc)
--
-- CORS Policy:
--
--   Development:
--     - Allow all origins
--     - All methods and headers
--     - For easy frontend development
--
--   Production:
--     - Whitelist specific origins
--     - Specific methods only
--     - Secure headers only
--
-- Middleware:
--
--   1. Context: establishes the per-request 'Infrastructure.Observability.Context.RequestContext'
--      (correlation id + best-effort user) and echoes @X-Correlation-Id@ on the response
--   2. Logging (LogText mode only): logs all requests/responses to stdout
--   3. Metrics: serves @GET \/metrics@ and records the HTTP request-duration histogram
--   4. Error: catches and formats uncaught exceptions
--   5. CORS: handles cross-origin requests
--   6. Compression: gzip compression for responses
--   7. Timeout: prevents long-running requests
--
-- Graceful Shutdown:
--
--   The server handles SIGTERM and SIGINT signals:
--     1. Stop accepting new connections
--     2. Wait for in-flight requests to complete (up to 30s)
--     3. Close database connections
--     4. Exit cleanly
--
-- Usage:
--
--   From Main.hs:
--   >>> config <- loadConfig "config/local.yaml"
--   >>> env <- initializeAppEnv logFunc config pool ...
--   >>> runServer env
--
--   Manual testing:
--   >>> curl http://localhost:8080/api/accounts
--   >>> curl -X POST http://localhost:8080/api/accounts -d '{"accountName":"Test","initialBalance":100}'
--
-- Performance:
--
--   Warp is one of the fastest HTTP servers available:
--     - ~100k requests/second on modern hardware
--     - Low latency (<1ms overhead)
--     - Efficient connection handling
--     - HTTP/1.1 with keep-alive
--     - Future: HTTP/2 support
module Web.Server
  ( -- * Server Execution
    runServer,

    -- * Server Configuration
    ServerSettings,
    makeServerSettings,

    -- * Application Building
    buildApplication,

    -- * Middleware
    corsMiddleware,
    loggingMiddleware,
    errorHandlingMiddleware,
    metricsMiddleware,
  )
where

import Data.Text.Display (displayText)
import Infrastructure.App (AppEnv (..), AppM, runAppM)
import Infrastructure.Config (AppConfig (..), LogFormat (..), LoggingConfig (..), ServerConfig (..))
import Infrastructure.Observability.Context (readRequestContext)
import Infrastructure.Observability.Logging (mkContextLogFunc, rioLevel)
-- For HTTP status and responses
import Network.HTTP.Types (status500)
import Network.Wai
  ( Application,
    Middleware,
    Request,
    responseLBS,
  )
import Network.Wai.Handler.Warp
  ( Port,
    Settings,
    defaultSettings,
    runSettings,
    setHost,
    setOnException,
    setPort,
    setTimeout,
  )
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy,
  )
import Network.Wai.Middleware.Gzip (defaultGzipSettings, gzip)
import Network.Wai.Middleware.Prometheus
  ( PrometheusSettings (..),
    instrumentApp,
    prometheus,
  )
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import Network.Wai.Parse (setMaxRequestNumFiles)
import RIO
import qualified Servant as S
import Servant.Multipart (Mem, MultipartOptions (..), defaultMultipartOptions)
import Servant.Server (err500, errBody)
import Servant.Server.Experimental.Auth (AuthHandler)
import Web.API (API, api, server)
import Web.API.InfoAPI (InfoAPI, infoAPI, infoHandler)
import Web.Middleware.Auth (AuthenticatedUser, authHandler)
import Web.Middleware.Context (contextMiddleware)

-- -----------------------------------------------------------------------------
-- Server Execution
-- -----------------------------------------------------------------------------

-- | Run the HTTP server with the given application environment.
--
-- This is the main entry point for starting the web server. It:
--  1. Extracts server configuration from AppEnv
--  2. Creates Warp server settings
--  3. Builds the Servant application with middleware
--  4. Starts the server and blocks until shutdown
--
-- Flow:
--  1. Extract server config from AppEnv
--  2. Build Warp settings
--  3. Create Servant application
--  4. Apply middleware stack
--  5. Start Warp server
--  6. Block until shutdown signal
--
-- Example:
--  >>> env <- initializeAppEnv logFunc config pool ...
--  >>> runServer env
--  >>> -- Server running at http://0.0.0.0:8080
--
-- Shutdown:
--  - SIGTERM or SIGINT: Graceful shutdown
--  - SIGKILL: Immediate shutdown (not graceful)
--  - Timeout: 30 seconds for in-flight requests
runServer :: AppEnv -> IO ()
runServer env = do
  let cfg = env.config
      port = cfg.server.port
      host = cfg.server.host

  -- Log startup
  runAppM env $ do
    logInfo "========================================="
    logInfo "  Starting HTTP Server"
    logInfo "========================================="
    logInfo $ "Port: " <> displayShow port
    logInfo $ "Host: " <> displayText host
    logInfo "Server ready to accept requests..."
    logInfo "========================================="

  -- Build server settings
  let settings = makeServerSettings env port

  -- Build application with middleware
  let app = buildApplication env

  -- Start server
  runSettings settings app

-- -----------------------------------------------------------------------------
-- Server Configuration
-- -----------------------------------------------------------------------------

-- | Type alias for Warp server settings.
type ServerSettings = Settings

-- | Create Warp server settings.
--
-- Configuration:
--  - Port: Configured port
--  - Host: 0.0.0.0 (all interfaces)
--  - Timeout: 30 seconds
--  - Exception handler: Log uncaught exceptions
--
-- Example:
--  >>> settings <- makeServerSettings 8080
--  >>> runSettings settings app
makeServerSettings :: AppEnv -> Port -> ServerSettings
makeServerSettings env port =
  defaultSettings
    & setPort port
    & setHost "0.0.0.0" -- Bind to all interfaces
    & setTimeout 30 -- 30 second timeout
    & setOnException exceptionHandler
  where
    exceptionHandler _req ex =
      when (shouldLogException ex)
        $ runAppM env
        $ logError
        $ "Uncaught exception (Warp): "
        <> displayShow ex

    -- Don't log expected exceptions (client disconnect, etc.)
    shouldLogException _ = True -- For now, log all

-- -----------------------------------------------------------------------------
-- Application Building
-- -----------------------------------------------------------------------------

-- | Build the complete Wai application with middleware.
--
-- Middleware Stack (applied bottom-to-top):
--  1. Servant application (core handlers)
--  2. CORS middleware
--  3. Error handling middleware
--  4. Logging middleware
--  5. Compression middleware
--
-- Authentication:
--  The Servant context includes an AuthHandler for JWT authentication.
--  Endpoints protected with @AuthProtect "jwt"@ will automatically:
--    - Extract and verify JWT tokens from Authorization headers
--    - Return 401 Unauthorized for missing/invalid tokens
--    - Pass AuthenticatedUser to handlers on success
--
-- Example:
--  >>> app <- buildApplication env
--  >>> runSettings settings app
-- | Full API including unauthenticated info endpoint.
--
-- The top-level 'S.Vault' combinator gives 'perRequestServer' access to the
-- request's WAI 'Data.Vault.Lazy.Vault' (populated by 'contextMiddleware'),
-- so it can read the per-request 'Infrastructure.Observability.Context.RequestContext'
-- and re-hoist the server with a context-bound 'AppEnv' — see 'servantApp'.
type FullAPI = S.Vault S.:> (InfoAPI S.:<|> API)

buildApplication :: AppEnv -> Application
buildApplication env =
  -- Middleware applied bottom-to-top (last applied is outermost)
  gzip defaultGzipSettings
    $ contextMiddleware env -- Establishes RequestContext (outermost: sees every request/response)
    $ requestLoggingMiddleware -- Dev-only human-readable request logging (LogText mode only)
    $ metricsMiddleware -- /metrics endpoint + HTTP request-duration histogram
    $ errorHandlingMiddleware env -- Uncaught-exception handling
    $ corsMiddleware -- CORS support
      servantApp -- Core application (innermost)
  where
    -- Create authentication context with JWT handler, plus the multipart
    -- upload options (see 'multipartOptions').
    jwtConfig = env.jwtConfig
    authContext = authHandler jwtConfig S.:. multipartOptions S.:. S.EmptyContext

    -- 'loggingMiddleware' (@logStdoutDev@) prints unstructured, colourised
    -- lines. In 'LogJson' mode stdout is a structured, one-JSON-object-per-line
    -- stream consumed by log shippers (Promtail/Grafana); interleaving it with
    -- ad-hoc text would violate that invariant, so it's only wired in for the
    -- human-oriented 'LogText' mode.
    requestLoggingMiddleware :: Middleware
    requestLoggingMiddleware = case env.config.logging.format of
      LogText -> loggingMiddleware
      LogJson -> id

    servantApp :: Application
    servantApp =
      S.serveWithContext
        (Proxy :: Proxy FullAPI)
        authContext
        perRequestServer

    -- \| Re-hoist the server per request with a context-bound 'AppEnv'.
    --
    -- 'contextMiddleware' stashes the request's 'RequestContext' (correlation
    -- id, best-effort acting user) on the WAI 'Vault.Vault' before the
    -- request reaches Servant; the 'S.Vault' combinator in 'FullAPI' hands
    -- that same vault back here on every request. We read the context back
    -- out and build a request-scoped 'AppEnv' — same resources, but with
    -- 'requestContext' set and a 'logFunc' rebuilt from it — so every log
    -- line and every persisted event's metadata for this request carries the
    -- same correlation id / acting user.
    perRequestServer :: S.Vault -> S.ServerT (InfoAPI S.:<|> API) S.Handler
    perRequestServer vault =
      S.hoistServer infoAPI (appMToHandler env') infoHandler
        S.:<|> hoistedServer env'
      where
        ctx = readRequestContext env.contextVaultKey vault
        env' =
          env
            { requestContext = ctx,
              logFunc = mkContextLogFunc env.config.logging.format (rioLevel env.config.logging.level) ctx env.loggerSet
            }

-- | Multipart upload options placed in the Servant 'S.Context'.
--
-- servant-multipart's default (inherited from wai-extra's
-- 'Network.Wai.Parse.defaultParseRequestBodyOptions') caps a single request at
-- __10 file parts__. The statement-file import endpoint accepts one file per
-- bank card, so a user with more than ~10 cards uploading them in one batch
-- would be rejected. We raise the cap to 100 (all other defaults — notably the
-- unlimited per-file/total size — are left as-is). If absent from the context,
-- servant-multipart silently falls back to its 10-file default, so this entry
-- must stay wired into 'authContext' and 'AuthContext'.
maxImportStatementFiles :: Int
maxImportStatementFiles = 100

multipartOptions :: MultipartOptions Mem
multipartOptions =
  base {generalOptions = setMaxRequestNumFiles maxImportStatementFiles base.generalOptions}
  where
    base = defaultMultipartOptions (Proxy :: Proxy Mem)

-- | Type alias for the authentication context.
--
-- Holds the JWT authentication handler Servant uses to authenticate requests
-- to protected endpoints, plus the 'MultipartOptions' for file uploads.
type AuthContext = '[AuthHandler Request AuthenticatedUser, MultipartOptions Mem]

-- | Convert AppM handlers to Servant's Handler monad.
--
-- This performs a "natural transformation" from AppM to Handler, allowing
-- our application monad to work with Servant.
--
-- Process:
--  1. Servant calls handler expecting `Handler a`
--  2. Our handler runs in `AppM a`
--  3. `hoistServerWithContext` transforms AppM → Handler
--  4. `appMToHandler` performs the actual transformation
--
-- Context:
--  The AuthContext is passed to hoistServerWithContext to enable
--  type-level authentication with AuthProtect "jwt".
--
-- Type Signature:
--  AppM a → Handler a
--
-- Implementation:
--  - Run AppM with the AppEnv
--  - Catch any exceptions
--  - Convert to Servant's ServerError
--  - Return in Handler monad
--
-- Example:
--  >>> hoistedServer env
--  >>> -- Server running in Handler monad
hoistedServer :: AppEnv -> S.ServerT API S.Handler
hoistedServer env = S.hoistServerWithContext api (Proxy :: Proxy AuthContext) (appMToHandler env) server

-- | Natural transformation from AppM to Handler.
--
-- This function converts our application monad (AppM) to Servant's Handler monad.
-- It runs the AppM computation with the given environment and catches any
-- exceptions, converting them to proper HTTP errors.
--
-- Error Handling:
--  - ServerError exceptions → Re-thrown as-is for proper HTTP status
--  - AppM exceptions → HTTP 500 Internal Server Error
--  - Business logic errors → Already converted to proper HTTP status by handlers
--  - Uncaught exceptions → Logged and returned as 500
--
-- Example:
--  >>> result <- appMToHandler env (someAppMAction)
--  >>> -- result :: Handler a
appMToHandler :: forall a. AppEnv -> AppM a -> S.Handler a
appMToHandler env action = do
  result <- liftIO (try (runAppM env action) :: IO (Either SomeException a))
  case result of
    Right value -> return value
    Left ex ->
      -- Check if it's a ServerError (from throwIO err400, err404, etc.)
      case fromException ex of
        Just (serverErr :: S.ServerError) ->
          -- Re-throw ServerError as-is for proper HTTP status codes
          S.throwError serverErr
        Nothing -> do
          -- Log other exceptions and return 500
          liftIO
            $ runAppM env
            $ logError
            $ "Uncaught exception in handler: "
            <> displayShow ex
          -- Return 500 Internal Server Error
          S.throwError err500 {errBody = "Internal server error"}

-- -----------------------------------------------------------------------------
-- Middleware
-- -----------------------------------------------------------------------------

-- | CORS middleware for cross-origin requests.
--
-- CORS (Cross-Origin Resource Sharing) allows web applications from different
-- origins to make requests to this API.
--
-- Development Policy:
--  - Allow all origins (*)
--  - All HTTP methods
--  - All headers
--  - Credentials allowed
--
-- Production Policy:
--  - Whitelist specific origins
--  - Specific methods only (GET, POST)
--  - Specific headers only
--  - Credentials only for whitelisted origins
--
-- Example:
--  >>> corsMiddleware app
--  >>> -- CORS headers added to responses
corsMiddleware :: Middleware
corsMiddleware = cors (const $ Just policy)
  where
    policy =
      simpleCorsResourcePolicy
        { corsOrigins = Nothing, -- Allow all origins (for development)
          corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
          corsRequestHeaders = ["Content-Type", "Authorization"],
          corsExposedHeaders = Just ["Content-Type"],
          corsMaxAge = Just 3600, -- Cache preflight for 1 hour
          corsVaryOrigin = False,
          corsRequireOrigin = False,
          corsIgnoreFailures = False
        }

-- | Logging middleware for request/response logging.
--
-- Logs:
--  - HTTP method
--  - Request path
--  - Response status code
--  - Response time
--
-- Format:
--  GET /api/accounts 200 OK (5ms)
--
-- Example:
--  >>> loggingMiddleware app
--  >>> -- Requests logged to stdout
loggingMiddleware :: Middleware
loggingMiddleware = logStdoutDev -- Development logging with colors

-- Production logging:
-- loggingMiddleware = logStdout

-- | Prometheus @/metrics@ endpoint + HTTP request-duration histogram.
--
-- Composes two middlewares from @wai-middleware-prometheus@:
--
--   * 'prometheus' serves @GET \/metrics@ (scraping the process-global
--     registry that 'Infrastructure.App.appMetrics' — and the standard GHC
--     runtime-statistics collector — register into) and is told __not__ to
--     auto-instrument the app itself ('prometheusInstrumentApp' = False):
--     its default auto-instrumentation labels the request-duration
--     histogram by the raw request path, which is unbounded cardinality for
--     a REST API whose paths embed ids (accounts, transactions, ...).
--   * 'instrumentApp' instruments the app with a single constant @"app"@
--     handler label instead, so @http_request_duration_seconds@ carries only
--     @{handler="app", method, status_code}@ — bounded regardless of how
--     many distinct paths are served.
--
-- Example:
--  >>> metricsMiddleware app
--  >>> -- GET /metrics now returns the Prometheus text exposition format;
--  >>> -- every other request bumps http_request_duration_seconds{handler="app",...}
metricsMiddleware :: Middleware
metricsMiddleware = prometheus settings . instrumentApp "app"
  where
    settings =
      PrometheusSettings
        { prometheusEndPoint = ["metrics"],
          prometheusInstrumentApp = False,
          prometheusInstrumentPrometheus = True
        }

-- | Error handling middleware for uncaught exceptions.
--
-- Catches any uncaught exceptions and returns a proper HTTP 500 response
-- with a generic error message (no stack trace in production).
--
-- Security:
--  - Never expose stack traces to clients
--  - Log full exception details server-side
--  - Return generic error message
--
-- Example:
--  >>> errorHandlingMiddleware app
--  >>> -- Uncaught exceptions → HTTP 500
--  >>> -- Note: Does not catch ServerError (Servant uses these for HTTP errors)
errorHandlingMiddleware :: AppEnv -> Middleware
errorHandlingMiddleware env app req respond =
  app req respond
    `catches` [
                -- Don't catch ServerError - Servant needs these for proper HTTP responses
                Handler $ \(ex :: S.ServerError) -> throwIO ex,
                -- Catch all other exceptions and turn them into 500
                Handler $ \(ex :: SomeException) -> do
                  -- Log exception with structured logging
                  runAppM env
                    $ logError
                    $ "Middleware caught exception: "
                    <> displayShow ex

                  -- Return generic 500 error
                  respond
                    $ responseLBS
                      status500
                      [("Content-Type", "application/json")]
                      "{\"error\":\"Internal server error\"}"
              ]
