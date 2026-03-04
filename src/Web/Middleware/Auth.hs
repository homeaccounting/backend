{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Web.Middleware.Auth
-- Description : Authentication middleware for protected endpoints
--
-- This module provides authentication using Servant's type-level AuthProtect.
--
-- Architecture:
--
--   HTTP Request with Authorization header
--     ↓
--   Servant routing matches AuthProtect "jwt"
--     ↓
--   authHandler extracts and verifies JWT token
--     ↓
--   Handler receives AuthenticatedUser directly
--
-- Benefits:
--   - Type-safe: Protected endpoints declared at type level
--   - Automatic 401: Invalid/missing token returns 401
--   - DRY: No need to call requireAuth in each handler
--   - Clear API: Easy to see which endpoints need auth
--
-- Usage:
--
--   Define protected endpoint:
--   >>> type ProtectedAPI = AuthProtect "jwt" :> "api" :> "protected" :> Get '[JSON] Response
--
--   Handler receives user directly:
--   >>> protectedHandler :: AuthenticatedUser -> AppM Response
--   >>> protectedHandler user = ...
module Web.Middleware.Auth
  ( -- * Servant Auth Types
    AuthenticatedUser (..),
    authHandler,
    type AuthProtect,

    -- * Legacy Helpers (for compatibility)
    getCurrentUser,
    requireAuth,
    extractBearerToken,
  )
where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Domain.Core.Types (UserId)
import Infrastructure.App (AppM)
import Infrastructure.Auth.JWT (JWTClaims (..), JWTConfig, verifyToken)
import Network.Wai (Request, requestHeaders)
import Servant
  ( AuthProtect,
    Handler,
    ServerError (..),
    err401,
  )
import qualified Servant
import Servant.Server.Experimental.Auth (AuthHandler, AuthServerData, mkAuthHandler)

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------

-- | Authenticated user information extracted from JWT.
data AuthenticatedUser = AuthenticatedUser
  { -- | User ID from JWT claims
    authUserId :: UserId,
    -- | User email from JWT claims
    authUserEmail :: Text
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Servant AuthProtect Type Instance
-- -----------------------------------------------------------------------------

-- | Type instance mapping "jwt" auth to AuthenticatedUser.
--
-- This tells Servant that endpoints protected with @AuthProtect "jwt"@
-- will receive an @AuthenticatedUser@ value after successful authentication.
type instance AuthServerData (AuthProtect "jwt") = AuthenticatedUser

-- -----------------------------------------------------------------------------
-- Authentication Handler
-- -----------------------------------------------------------------------------

-- | Create a Servant authentication handler for JWT tokens.
--
-- This handler:
--   1. Extracts the Authorization header from the request
--   2. Parses the Bearer token
--   3. Verifies the JWT signature and expiration
--   4. Returns the AuthenticatedUser on success
--   5. Returns 401 Unauthorized on failure
--
-- Usage in Server.hs:
-- >>> let ctx = authHandler jwtConfig :. EmptyContext
-- >>> serveWithContext api ctx (hoistedServer env)
--
-- Example flow:
-- >>> GET /api/protected with "Authorization: Bearer <token>"
-- >>>   ↓ authHandler verifies token
-- >>>   ↓ Handler receives AuthenticatedUser
-- >>> Response
authHandler :: JWTConfig -> AuthHandler Request AuthenticatedUser
authHandler config = mkAuthHandler handler
  where
    handler :: Request -> Handler AuthenticatedUser
    handler req = do
      -- Extract Authorization header
      let maybeAuthHeader = lookup "Authorization" (requestHeaders req)

      case maybeAuthHeader of
        Nothing ->
          throwError err401 {errBody = "Missing Authorization header"}
        Just authHeaderBS -> do
          let authHeader = decodeUtf8 authHeaderBS

          -- Extract Bearer token
          case extractBearerToken authHeader of
            Nothing ->
              throwError err401 {errBody = "Invalid Authorization header format. Expected: Bearer <token>"}
            Just token -> do
              -- Verify JWT token
              maybeClaims <- liftIO $ verifyToken config token
              case maybeClaims of
                Nothing ->
                  throwError err401 {errBody = "Invalid or expired token"}
                Just claims ->
                  return $ claimsToUser claims

    -- Use Servant's throwError from Handler monad
    throwError = Servant.throwError

-- -----------------------------------------------------------------------------
-- Authentication Helpers
-- -----------------------------------------------------------------------------

-- | Get current authenticated user, if any.
--
-- This function:
--   1. Extracts token from Authorization header
--   2. Verifies the token
--   3. Returns the user claims if valid, Nothing otherwise
--
-- Use this for endpoints that work with or without authentication.
--
-- Example:
-- >>> maybeUser <- getCurrentUser config authHeader
-- >>> case maybeUser of
-- >>>   Just user -> showUserContent user
-- >>>   Nothing -> showPublicContent
getCurrentUser :: JWTConfig -> Maybe Text -> AppM (Maybe AuthenticatedUser)
getCurrentUser config maybeAuthHeader = do
  case maybeAuthHeader >>= extractBearerToken of
    Nothing -> return Nothing
    Just token -> do
      maybeClaims <- verifyToken config token
      return $ fmap claimsToUser maybeClaims

-- | Require authentication or return 401.
--
-- This function:
--   1. Extracts token from Authorization header
--   2. Verifies the token
--   3. Returns the user if valid
--   4. Returns 401 Unauthorized if invalid or missing
--
-- Use this for endpoints that require authentication.
--
-- Example:
-- >>> user <- requireAuth config authHeader
-- >>> processRequest user
requireAuth :: JWTConfig -> Maybe Text -> AppM AuthenticatedUser
requireAuth config maybeAuthHeader = do
  maybeUser <- getCurrentUser config maybeAuthHeader
  case maybeUser of
    Just user -> return user
    Nothing -> liftIO $ throwIO err401 {errBody = "Invalid or missing authentication"}

-- | Extract Bearer token from Authorization header value.
--
-- Expected format: "Bearer <token>"
--
-- Example:
-- >>> extractBearerToken (Just "Bearer ***REMOVED***")
-- Just "***REMOVED***"
--
-- >>> extractBearerToken (Just "Basic dXNlcjpwYXNz")
-- Nothing
extractBearerToken :: Text -> Maybe Text
extractBearerToken authHeader =
  case T.words authHeader of
    ["Bearer", token] -> Just token
    _ -> Nothing

-- -----------------------------------------------------------------------------
-- Internal Helpers
-- -----------------------------------------------------------------------------

-- | Convert JWT claims to authenticated user.
claimsToUser :: JWTClaims -> AuthenticatedUser
claimsToUser JWTClaims {..} =
  AuthenticatedUser
    { authUserId = userId,
      authUserEmail = email
    }
