{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.UserAPI
-- Description : REST API endpoints for user profile operations
--
-- This module defines the Servant API for user profile management.
-- Handlers are thin HTTP adapters that delegate to 'UserService' for
-- business orchestration and use 'ErrorMapping' for error responses.
--
-- API Endpoints:
--
--   GET    /api/users/me                    - Current user profile
--   PUT    /api/users/me                    - Update profile
--   POST   /api/users/me/change-password    - Change password
--   DELETE /api/users/me/oauth/:provider    - Unlink OAuth
--   DELETE /api/users/me/telegram           - Unlink Telegram
--
-- Handler Responsibilities (HTTP concerns only):
--   1. Extract data from HTTP request (path params, body, auth)
--   2. Delegate to UserService
--   3. Convert domain types to DTOs (response building)
--   4. Map service errors to HTTP errors
module Web.API.UserAPI
  ( -- * API Type
    UserAPI,

    -- * Request Types
    UpdateProfileRequest (..),
    ChangePasswordRequest (..),

    -- * Response Types
    UserProfileResponse (..),

    -- * Server
    userServer,
  )
where

import Application.ReadModels.UserSummary (UserSummaryData (..))
import qualified Application.Services.UserService as UserService
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Domain.Core.Types
  ( AccountId,
    OAuthIdentity,
    TelegramIdentity,
    UserId,
  )
import GHC.Generics (Generic)
import Infrastructure.App (AppM)
import RIO hiding (Handler)
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | User profile API type.
--
-- All endpoints require authentication via AuthProtect "jwt".
-- The AuthenticatedUser is automatically passed to handlers on successful auth.
type UserAPI =
  -- Get current user profile
  AuthProtect "jwt"
    :> "api"
    :> "users"
    :> "me"
    :> Get '[JSON] UserProfileResponse
    -- Update profile
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> ReqBody '[JSON] UpdateProfileRequest
      :> Put '[JSON] UserProfileResponse
    -- Change password
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "change-password"
      :> ReqBody '[JSON] ChangePasswordRequest
      :> Post '[JSON] NoContent
    -- Unlink OAuth provider
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "oauth"
      :> Capture "provider" Text
      :> Delete '[JSON] NoContent
    -- Unlink Telegram
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "telegram"
      :> Delete '[JSON] NoContent

-- -----------------------------------------------------------------------------
-- Request Types
-- -----------------------------------------------------------------------------

-- | Update profile request.
data UpdateProfileRequest = UpdateProfileRequest
  { updateEmail :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON UpdateProfileRequest

instance FromJSON UpdateProfileRequest

-- | Change password request.
data ChangePasswordRequest = ChangePasswordRequest
  { currentPassword :: Text,
    newPassword :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangePasswordRequest

instance FromJSON ChangePasswordRequest

-- -----------------------------------------------------------------------------
-- Response Types
-- -----------------------------------------------------------------------------

-- | User profile response.
data UserProfileResponse = UserProfileResponse
  { profileUserId :: UserId,
    profileEmail :: Maybe Text,
    profileHasPassword :: Bool,
    profileOAuthIdentities :: [OAuthIdentity],
    profileTelegramIdentity :: Maybe TelegramIdentity,
    profileExternalAccountId :: AccountId
  }
  deriving (Show, Eq, Generic)

instance ToJSON UserProfileResponse

instance FromJSON UserProfileResponse

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | User API server.
userServer :: ServerT UserAPI AppM
userServer =
  handleGetProfile
    :<|> handleUpdateProfile
    :<|> handleChangePassword
    :<|> handleUnlinkOAuth
    :<|> handleUnlinkTelegram

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for GET /api/users/me - Get current user profile.
handleGetProfile :: AuthenticatedUser -> AppM UserProfileResponse
handleGetProfile user = do
  result <- UserService.getProfile user.authUserId
  case result of
    Right (userId, userData) -> return $ userDataToProfileResponse userId userData
    Left err -> throwDomainError err

-- | Handler for PUT /api/users/me - Update profile.
--
-- Note: Email update is not yet implemented at the domain level.
handleUpdateProfile :: AuthenticatedUser -> UpdateProfileRequest -> AppM UserProfileResponse
handleUpdateProfile user UpdateProfileRequest {..} =
  case updateEmail of
    Just _newEmail -> do
      -- TODO: Implement UpdateUserEmail command
      logWarn "Email update not yet implemented"
      throwIO err501 {errBody = "Email update not yet implemented"}
    Nothing -> do
      -- No changes, return current profile
      result <- UserService.getProfile user.authUserId
      case result of
        Right (userId, userData) -> return $ userDataToProfileResponse userId userData
        Left err -> throwDomainError err

-- | Handler for POST /api/users/me/change-password - Change password.
handleChangePassword :: AuthenticatedUser -> ChangePasswordRequest -> AppM NoContent
handleChangePassword user ChangePasswordRequest {..} = do
  result <- UserService.changePassword user.authUserId currentPassword newPassword
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for DELETE /api/users/me/oauth/:provider - Unlink OAuth provider.
handleUnlinkOAuth :: AuthenticatedUser -> Text -> AppM NoContent
handleUnlinkOAuth user providerText = do
  result <- UserService.unlinkOAuth user.authUserId providerText
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for DELETE /api/users/me/telegram - Unlink Telegram.
handleUnlinkTelegram :: AuthenticatedUser -> AppM NoContent
handleUnlinkTelegram user = do
  result <- UserService.unlinkTelegram user.authUserId
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- -----------------------------------------------------------------------------
-- DTO Conversion (Web layer responsibility)
-- -----------------------------------------------------------------------------

-- | Convert user summary data to profile response DTO.
userDataToProfileResponse :: UserId -> UserSummaryData -> UserProfileResponse
userDataToProfileResponse userId UserSummaryData {..} =
  UserProfileResponse
    { profileUserId = userId,
      profileEmail = email,
      profileHasPassword = hasPassword,
      profileOAuthIdentities = oauthIdentities,
      profileTelegramIdentity = telegramIdentity,
      profileExternalAccountId = externalAccountId
    }
