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
--   - POST /api/auth/telegram - Telegram login widget auth
--   - POST /api/auth/link-telegram - Link Telegram to existing account
--   - POST /api/auth/refresh - Refresh JWT token
module Web.API.AuthAPI
  ( -- * API Type
    AuthAPI,

    -- * Request Types
    RegisterRequest (..),
    LoginRequest (..),
    TelegramAuthRequest (..),
    LinkOAuthRequest (..),
    LinkTelegramRequest (..),
    RefreshTokenRequest (..),

    -- * Response Types
    AuthResponse (..),
    OAuthRedirectResponse (..),

    -- * Server
    authServer,
  )
where

import qualified Application.Services.AuthService as AuthService
import Data.Aeson (FromJSON, ToJSON)
import Domain.Core.Types (OAuthProvider (..), UserId)
import Infrastructure.App (AppM)
import qualified Infrastructure.Auth.Telegram as TelegramAuth
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
    -- Telegram login widget authentication
    :<|> "api"
      :> "auth"
      :> "telegram"
      :> ReqBody '[JSON] TelegramAuthRequest
      :> Post '[JSON] AuthResponse
    -- Link Telegram to existing account (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "auth"
      :> "link-telegram"
      :> ReqBody '[JSON] LinkTelegramRequest
      :> Post '[JSON] NoContent
    -- Refresh token
    :<|> "api"
      :> "auth"
      :> "refresh"
      :> ReqBody '[JSON] RefreshTokenRequest
      :> Post '[JSON] AuthResponse

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

-- | Telegram login widget auth request.
data TelegramAuthRequest = TelegramAuthRequest
  { id :: Int,
    firstName :: Text,
    lastName :: Maybe Text,
    username :: Maybe Text,
    photoUrl :: Maybe Text,
    authDate :: Int,
    hash :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramAuthRequest

instance FromJSON TelegramAuthRequest

-- | Link OAuth account request.
data LinkOAuthRequest = LinkOAuthRequest
  { provider :: OAuthProvider,
    code :: Text,
    state :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON LinkOAuthRequest

instance FromJSON LinkOAuthRequest

-- | Link Telegram account request.
data LinkTelegramRequest = LinkTelegramRequest
  { authData :: TelegramAuthRequest
  }
  deriving (Show, Eq, Generic)

instance ToJSON LinkTelegramRequest

instance FromJSON LinkTelegramRequest

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
    :<|> handleTelegramAuth
    :<|> handleLinkTelegram
    :<|> handleRefreshToken

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

-- | Handle Telegram login widget auth.
handleTelegramAuth :: TelegramAuthRequest -> AppM AuthResponse
handleTelegramAuth req = do
  let authData = toTelegramAuthData req
  result <- AuthService.authenticateTelegram authData
  case result of
    Right r -> return $ toAuthResponse r
    Left err -> throwDomainError err

-- | Handle link Telegram to existing account.
handleLinkTelegram :: AuthenticatedUser -> LinkTelegramRequest -> AppM NoContent
handleLinkTelegram user LinkTelegramRequest {..} = do
  let telegramAuthData = toTelegramAuthData authData
  result <- AuthService.linkTelegram user.userId telegramAuthData
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

-- | Convert TelegramAuthRequest to TelegramAuthData.
toTelegramAuthData :: TelegramAuthRequest -> TelegramAuth.TelegramAuthData
toTelegramAuthData req =
  TelegramAuth.TelegramAuthData
    { TelegramAuth.id = fromIntegral req.id,
      TelegramAuth.firstName = req.firstName,
      TelegramAuth.lastName = req.lastName,
      TelegramAuth.username = req.username,
      TelegramAuth.photoUrl = req.photoUrl,
      TelegramAuth.authDate = fromIntegral req.authDate,
      TelegramAuth.hash = req.hash
    }
