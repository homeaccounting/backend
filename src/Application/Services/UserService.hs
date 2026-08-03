{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.UserService
-- Description : User profile use case orchestration
--
-- This module implements the application-level orchestration for user profile
-- operations, handling:
--
--   - Read model queries for user profiles
--   - Password change orchestration
--   - OAuth/Telegram account unlinking with login method safety checks
--   - Command construction and execution
--
-- Services accept and return domain/application types only. Web-layer
-- DTO conversion is the responsibility of the API handlers.
--
-- All functions return @Either DomainError a@ to make errors explicit in
-- the type, following the project's idiomatic error handling approach.
--
-- Usage:
--   Services are called by thin API handlers in @Web.API.UserAPI@.
module Application.Services.UserService
  ( -- * Service Functions
    getProfile,
    changePassword,
    unlinkOAuth,
    unlinkTelegram,
  )
where

import Application.ReadModels.User (UserData (..))
import Application.Services.Internal
  ( getUserData,
    guardE,
    liftMaybe,
    runUserCmd,
  )
import Control.Monad.Trans.Except (runExceptT, throwE)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( OAuthIdentity (..),
    OAuthProvider (..),
    UserId,
    unUserId,
  )
import Domain.User.CommandHandler (UserCommand (..))
import Domain.User.Commands
  ( ChangePassword (..),
    UnlinkOAuthAccount (..),
    UnlinkTelegramAccount (..),
  )
import Infrastructure.App (AppM)
import Infrastructure.Auth.Password (hashPassword)
import RIO
import qualified RIO.List as L
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Get a user's profile data.
--
-- Queries the read model for the user data.
-- Returns the UserId and UserData on success.
getProfile ::
  UserId ->
  AppM (Either DomainError (UserId, UserData))
getProfile userId = runExceptT $ do
  lift $ logInfo "Getting user profile"
  userData <- getUserData userId
  lift $ logInfo "User profile retrieved successfully"
  pure (userId, userData)

-- | Change a user's password.
--
-- Orchestrates:
--   1. Validate new password meets requirements
--   2. Hash the new password
--   3. Issue ChangePassword command
--
-- Returns Left if:
--   - New password is too short (< 8 characters)
--
-- Note: Current password verification is not yet implemented (TODO).
changePassword ::
  UserId ->
  Text ->
  Text ->
  AppM (Either DomainError ())
changePassword userId _currentPassword newPassword = runExceptT $ do
  lift $ logInfo "Processing password change"
  guardE (T.length newPassword >= 8)
    $ ValidationErr
    $ mkValidationError "newPassword" "Password must be at least 8 characters" ""
  -- TODO: Verify current password (requires aggregate loading)
  lift $ logWarn "Current password verification skipped - implement aggregate loading"
  newPasswordHash <- lift (hashPassword newPassword)
  let changeCmd = ChangePasswordUserCommand ChangePassword {newHash = newPasswordHash}
  runUserCmd (unUserId userId) changeCmd
  lift $ logInfo "Password changed successfully"

-- | Unlink an OAuth provider from a user's account.
--
-- Orchestrates:
--   1. Parse and validate provider name
--   2. Verify user exists
--   3. Verify the OAuth provider is actually linked
--   4. Ensure this is not the user's last login method
--   5. Issue UnlinkOAuthAccount command
--
-- Returns Left if:
--   - Unknown OAuth provider
--   - User not found
--   - OAuth provider not linked
--   - Would remove the user's last login method
unlinkOAuth ::
  UserId ->
  Text ->
  AppM (Either DomainError ())
unlinkOAuth userId providerText = runExceptT $ do
  lift $ logInfo $ "Unlinking OAuth provider: " <> display providerText
  provider <-
    liftMaybe
      (ValidationErr (mkValidationError "provider" "Unknown OAuth provider" providerText))
      (parseOAuthProvider providerText)
  userData <- getUserData userId
  identity <-
    liftMaybe (NotFound "OAuthProvider" providerText)
      $ L.find (\i -> i.provider == provider) userData.oauthIdentities
  when (countLoginMethods userData <= 1) $ do
    lift $ logWarn "Cannot unlink last login method"
    throwE (UserError "Cannot unlink last login method")
  let unlinkCmd = UnlinkOAuthAccountUserCommand UnlinkOAuthAccount {identity = identity}
  runUserCmd (unUserId userId) unlinkCmd
  lift $ logInfo "OAuth provider unlinked successfully"

-- | Unlink Telegram from a user's account.
--
-- Orchestrates:
--   1. Verify user exists
--   2. Verify Telegram is actually linked
--   3. Ensure this is not the user's last login method
--   4. Issue UnlinkTelegramAccount command
--
-- Returns Left if:
--   - User not found
--   - Telegram not linked
--   - Would remove the user's last login method
unlinkTelegram ::
  UserId ->
  AppM (Either DomainError ())
unlinkTelegram userId = runExceptT $ do
  lift $ logInfo "Unlinking Telegram account"
  userData <- getUserData userId
  _telegramIdentity <-
    liftMaybe (NotFound "TelegramLink" (tshow userId)) userData.telegramIdentity
  when (countLoginMethods userData <= 1) $ do
    lift $ logWarn "Cannot unlink last login method"
    throwE (UserError "Cannot unlink last login method")
  let unlinkCmd = UnlinkTelegramAccountUserCommand UnlinkTelegramAccount
  runUserCmd (unUserId userId) unlinkCmd
  lift $ logInfo "Telegram account unlinked successfully"

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Count the number of login methods for a user.
--
-- Used to prevent unlinking the last login method.
countLoginMethods :: UserData -> Int
countLoginMethods UserData {..} =
  (if hasPassword then 1 else 0)
    + length oauthIdentities
    + (if isJust telegramIdentity then 1 else 0)

-- | Parse OAuth provider from text.
parseOAuthProvider :: Text -> Maybe OAuthProvider
parseOAuthProvider t = case T.toLower t of
  "google" -> Just Google
  "github" -> Just GitHub
  "microsoft" -> Just Microsoft
  _ -> Nothing
