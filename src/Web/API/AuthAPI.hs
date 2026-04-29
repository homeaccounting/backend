{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.AuthAPI
-- Description : Authentication API endpoints
--
-- This module defines the authentication API endpoints.
-- Handlers are thin HTTP adapters that delegate to 'AuthenticationService'
-- for business orchestration.
--
-- Endpoints:
--   - POST /api/auth/register - Email + password registration
--   - POST /api/auth/login - Email + password login
--   - GET /api/auth/oauth/:provider - Initiate OAuth flow
--   - GET /api/auth/oauth/:provider/callback - OAuth callback
--   - POST /api/auth/link-oauth - Link OAuth to existing account
--   - POST /api/auth/refresh - Refresh JWT token
--   - POST /api/auth/telegram/link-code - Issue Telegram deep-link code
module Web.API.AuthAPI
  ( -- * API Type
    AuthAPI,

    -- * Request Types
    RegisterRequest (..),
    LoginRequest (..),
    LinkOAuthRequest (..),
    RefreshTokenRequest (..),

    -- * Response Types
    AuthResponse (..),
    OAuthRedirectResponse (..),
    TelegramLinkCodeResponse (..),

    -- * Server
    authServer,
  )
where

import qualified Application.Services.AuthService as AuthService
import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Domain.Core.Types (OAuthProvider (..), UserId)
import Infrastructure.App (AppM)
import RIO hiding (Handler)
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser)
import qualified Web.Middleware.Auth as Auth

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Authentication API type.
type AuthAPI =
  -- Register with email + password
  "api"
    :> "auth"
    :> "register"
    :> ReqBody '[JSON] RegisterRequest
    :> Post '[JSON] AuthResponse
    -- Login with email + password
    :<|> "api"
      :> "auth"
      :> "login"
      :> ReqBody '[JSON] LoginRequest
      :> Post '[JSON] AuthResponse
    -- Initiate OAuth flow
    :<|> "api"
      :> "auth"
      :> "oauth"
      :> Capture "provider" Text
      :> Get '[JSON] OAuthRedirectResponse
    -- OAuth callback
    :<|> "api"
      :> "auth"
      :> "oauth"
      :> Capture "provider" Text
      :> "callback"
      :> QueryParam "code" Text
      :> QueryParam "state" Text
      :> Get '[JSON] AuthResponse
    -- Link OAuth to existing account (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "auth"
      :> "link-oauth"
      :> ReqBody '[JSON] LinkOAuthRequest
      :> Post '[JSON] NoContent
    -- Refresh token
    :<|> "api"
      :> "auth"
      :> "refresh"
      :> ReqBody '[JSON] RefreshTokenRequest
      :> Post '[JSON] AuthResponse
    -- Issue Telegram deep-link code (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "auth"
      :> "telegram"
      :> "link-code"
      :> Post '[JSON] TelegramLinkCodeResponse

-- -----------------------------------------------------------------------------
-- Request Types
-- -----------------------------------------------------------------------------

-- | Registration request.
data RegisterRequest = RegisterRequest
  { email :: Text,
    password :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RegisterRequest

instance FromJSON RegisterRequest

-- | Login request.
data LoginRequest = LoginRequest
  { email :: Text,
    password :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON LoginRequest

instance FromJSON LoginRequest

-- | Link OAuth account request.
data LinkOAuthRequest = LinkOAuthRequest
  { provider :: OAuthProvider,
    code :: Text,
    state :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON LinkOAuthRequest

instance FromJSON LinkOAuthRequest

-- | Token refresh request.
data RefreshTokenRequest = RefreshTokenRequest
  { token :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RefreshTokenRequest

instance FromJSON RefreshTokenRequest

-- -----------------------------------------------------------------------------
-- Response Types
-- -----------------------------------------------------------------------------

-- | Authentication response with JWT token.
data AuthResponse = AuthResponse
  { token :: Text,
    userId :: UserId,
    email :: Maybe Text,
    expiresIn :: Int -- seconds
  }
  deriving (Show, Eq, Generic)

instance ToJSON AuthResponse

instance FromJSON AuthResponse

-- | OAuth redirect response.
data OAuthRedirectResponse = OAuthRedirectResponse
  { redirectUrl :: Text,
    state :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON OAuthRedirectResponse

instance FromJSON OAuthRedirectResponse

-- | Telegram link-code issuance response.
data TelegramLinkCodeResponse = TelegramLinkCodeResponse
  { deepLink :: Text,
    expiresAt :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramLinkCodeResponse

instance FromJSON TelegramLinkCodeResponse

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Authentication API server.
authServer :: ServerT AuthAPI AppM
authServer =
  handleRegister
    :<|> handleLogin
    :<|> handleOAuthInitiate
    :<|> handleOAuthCallbackEndpoint
    :<|> handleLinkOAuth
    :<|> handleRefreshToken
    :<|> handleIssueTelegramLinkCode

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handle registration.
handleRegister :: RegisterRequest -> AppM AuthResponse
handleRegister RegisterRequest {..} = do
  result <- AuthService.register email password
  case result of
    Right r -> return $ toAuthResponse r
    Left err -> throwDomainError err

-- | Handle login.
handleLogin :: LoginRequest -> AppM AuthResponse
handleLogin LoginRequest {..} = do
  result <- AuthService.login email password
  case result of
    Right r -> return $ toAuthResponse r
    Left err -> throwDomainError err

-- | Handle OAuth initiate.
handleOAuthInitiate :: Text -> AppM OAuthRedirectResponse
handleOAuthInitiate providerText = do
  provider <- case AuthService.parseOAuthProvider providerText of
    Nothing -> throwIO err400 {errBody = "Unknown OAuth provider"}
    Just p -> return p
  result <- AuthService.initiateOAuth provider
  case result of
    Right r -> return $ OAuthRedirectResponse {redirectUrl = r.url, state = r.state}
    Left err -> throwDomainError err

-- | Handle OAuth callback.
handleOAuthCallbackEndpoint :: Text -> Maybe Text -> Maybe Text -> AppM AuthResponse
handleOAuthCallbackEndpoint providerText maybeCode maybeState = do
  provider <- case AuthService.parseOAuthProvider providerText of
    Nothing -> throwIO err400 {errBody = "Unknown OAuth provider"}
    Just p -> return p
  code <- case maybeCode of
    Nothing -> throwIO err400 {errBody = "Missing authorization code"}
    Just c -> return c
  state <- case maybeState of
    Nothing -> throwIO err400 {errBody = "Missing state parameter"}
    Just s -> return s
  result <- AuthService.handleOAuthCallback provider code state
  case result of
    Right r -> return $ toAuthResponse r
    Left err -> throwDomainError err

-- | Handle link OAuth to existing account.
handleLinkOAuth :: AuthenticatedUser -> LinkOAuthRequest -> AppM NoContent
handleLinkOAuth user LinkOAuthRequest {..} = do
  result <- AuthService.linkOAuth user.userId provider code state
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handle token refresh.
handleRefreshToken :: RefreshTokenRequest -> AppM AuthResponse
handleRefreshToken RefreshTokenRequest {..} = do
  result <- AuthService.refreshToken token
  case result of
    Right r -> return $ toAuthResponse r
    Left err -> throwDomainError err

-- | Handle issuance of a Telegram deep-link code for the authenticated user.
handleIssueTelegramLinkCode :: AuthenticatedUser -> AppM TelegramLinkCodeResponse
handleIssueTelegramLinkCode user = do
  result <- AuthService.issueTelegramLinkCode user.userId
  case result of
    Left err -> throwDomainError err
    Right res ->
      pure
        TelegramLinkCodeResponse
          { deepLink = res.deepLink,
            expiresAt = res.expiresAt
          }

-- -----------------------------------------------------------------------------
-- Conversion Helpers
-- -----------------------------------------------------------------------------

-- | Convert AuthResult to AuthResponse.
toAuthResponse :: AuthService.AuthResult -> AuthResponse
toAuthResponse r =
  AuthResponse
    { token = r.token,
      userId = r.userId,
      email = r.email,
      expiresIn = r.expiresIn
    }
