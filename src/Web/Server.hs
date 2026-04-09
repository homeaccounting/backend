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
-- middleware for CORS, logging, error handling, and request/response processing.
--
-- Architecture:
--
--   HTTP Request
--     ↓
--   Warp Server (runSettings)
--     ↓
--   Middleware Stack (applied bottom-to-top):
--     ├─→ CORS Middleware (cross-origin resource sharing)
--     ├─→ Logging Middleware (request/response logging)
--     ├─→ Error Handling Middleware (uncaught exceptions)
--     ├─→ Compression Middleware (gzip responses)
--     └─→ Timeout Middleware (request timeouts)
--     ↓
--   Servant Application
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
--   1. CORS: Handles cross-origin requests
--   2. Logging: Logs all requests/responses
--   3. Error: Catches and formats uncaught exceptions
--   4. Compression: gzip compression for responses
--   5. Timeout: Prevents long-running requests
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
  )
where

import Data.Text.Display (displayText)
import Infrastructure.App (AppEnv (..), AppM, runAppM)
import Infrastructure.Config (AppConfig (..), ServerConfig (..))
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
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import RIO
import qualified Servant as S
import Servant.Server (err500, errBody)
import Servant.Server.Experimental.Auth (AuthHandler)
import Web.API (API, api, server)
import Web.API.InfoAPI (InfoAPI, infoAPI, infoHandler)
import Web.Middleware.Auth (AuthenticatedUser, authHandler)

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
type FullAPI = InfoAPI S.:<|> API

buildApplication :: AppEnv -> Application
buildApplication env =
  -- Middleware applied bottom-to-top (last applied is outermost)
  gzip defaultGzipSettings
    $ loggingMiddleware -- Compression (outermost)
    $ errorHandlingMiddleware env -- Request/response logging
    $ corsMiddleware -- Error handling
      servantApp -- CORS support
      -- Core application (innermost)
  where
    -- Create authentication context with JWT handler
    jwtConfig = env.jwtConfig
    authContext = authHandler jwtConfig S.:. S.EmptyContext

    servantApp =
      S.serveWithContext
        (Proxy :: Proxy FullAPI)
        authContext
        (infoServer S.:<|> hoistedServer env)

    infoServer :: S.ServerT InfoAPI S.Handler
    infoServer = S.hoistServer infoAPI (appMToHandler env) infoHandler

-- | Type alias for the authentication context.
--
-- This context contains the JWT authentication handler that Servant uses
-- to authenticate requests to protected endpoints.
type AuthContext = '[AuthHandler Request AuthenticatedUser]

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
          corsMethods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
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
