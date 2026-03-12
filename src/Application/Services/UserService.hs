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

import Application.ReadModels.User
  ( UserData (..),
    getUser,
  )
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
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasReadModel (..),
  )
import Infrastructure.Auth.Password (hashPassword)
import Infrastructure.Eventium (applyUserCommand)
import RIO
import qualified RIO.List as L
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Get a user's profile data.
--
-- Queries the read model for the user summary.
-- Returns the UserId and UserData on success.
getProfile ::
  UserId ->
  AppM (Either DomainError (UserId, UserData))
getProfile userId = do
  logInfo "Getting user profile"

  userReadModel <- view userReadModelL
  maybeUserData <- getUser userReadModel userId

  case maybeUserData of
    Nothing -> do
      logError "User not found in read model"
      return $ Left $ NotFound "User" (tshow userId)
    Just userData -> do
      logInfo "User profile retrieved successfully"
      return $ Right (userId, userData)

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
changePassword userId _currentPassword newPassword = do
  logInfo "Processing password change"

  -- 1. Validate new password
  if T.length newPassword < 8
    then do
      logWarn "Password too short"
      return $ Left $ ValidationErr $ mkValidationError "newPassword" "Password must be at least 8 characters" ""
    else do
      -- TODO: Verify current password (requires aggregate loading)
      logWarn "Current password verification skipped - implement aggregate loading"

      -- 2. Hash new password
      newPasswordHash <- hashPassword newPassword

      -- 3. Issue ChangePassword command
      let changeCmd = ChangePasswordUserCommand ChangePassword {newHash = newPasswordHash}

      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      let userUuid = unUserId userId
      result <- liftIO $ applyUserCommand writer reader userUuid changeCmd
      case result of
        Left err -> do
          logError $ "Password change rejected: " <> displayShow err
          return $ Left $ UserError "Password change rejected by domain"
        Right _ -> do
          logInfo "Password changed successfully"
          return $ Right ()

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
unlinkOAuth userId providerText = do
  logInfo $ "Unlinking OAuth provider: " <> display providerText

  -- 1. Parse provider
  case parseOAuthProvider providerText of
    Nothing ->
      return $ Left $ ValidationErr $ mkValidationError "provider" "Unknown OAuth provider" providerText
    Just provider -> do
      -- 2. Get user data
      userReadModel <- view userReadModelL
      maybeUserData <- getUser userReadModel userId

      case maybeUserData of
        Nothing -> return $ Left $ NotFound "User" (tshow userId)
        Just userData -> do
          -- 3. Check if OAuth provider is linked
          case L.find (\i -> i.provider == provider) userData.oauthIdentities of
            Nothing -> do
              logWarn "OAuth provider not linked"
              return $ Left $ NotFound "OAuthProvider" providerText
            Just identity -> do
              -- 4. Check login method count
              let loginMethods = countLoginMethods userData
              if loginMethods <= 1
                then do
                  logWarn "Cannot unlink last login method"
                  return $ Left $ UserError "Cannot unlink last login method"
                else do
                  -- 5. Issue UnlinkOAuthAccount command
                  let unlinkCmd = UnlinkOAuthAccountUserCommand UnlinkOAuthAccount {identity = identity}

                  writer <- view eventStoreWriterL
                  reader <- view eventStoreReaderL
                  let userUuid = unUserId userId
                  result <- liftIO $ applyUserCommand writer reader userUuid unlinkCmd
                  case result of
                    Left err -> do
                      logError $ "Unlink OAuth rejected: " <> displayShow err
                      return $ Left $ UserError "Unlink OAuth rejected by domain"
                    Right _ -> do
                      logInfo "OAuth provider unlinked successfully"
                      return $ Right ()

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
unlinkTelegram userId = do
  logInfo "Unlinking Telegram account"

  -- 1. Get user data
  userReadModel <- view userReadModelL
  maybeUserData <- getUser userReadModel userId

  case maybeUserData of
    Nothing -> return $ Left $ NotFound "User" (tshow userId)
    Just userData ->
      -- 2. Check if Telegram is linked
      case userData.telegramIdentity of
        Nothing -> do
          logWarn "Telegram not linked"
          return $ Left $ NotFound "TelegramLink" (tshow userId)
        Just _ -> do
          -- 3. Check login method count
          let loginMethods = countLoginMethods userData
          if loginMethods <= 1
            then do
              logWarn "Cannot unlink last login method"
              return $ Left $ UserError "Cannot unlink last login method"
            else do
              -- 4. Issue UnlinkTelegramAccount command
              let unlinkCmd = UnlinkTelegramAccountUserCommand UnlinkTelegramAccount

              writer <- view eventStoreWriterL
              reader <- view eventStoreReaderL
              let userUuid = unUserId userId
              result <- liftIO $ applyUserCommand writer reader userUuid unlinkCmd
              case result of
                Left err -> do
                  logError $ "Unlink Telegram rejected: " <> displayShow err
                  return $ Left $ UserError "Unlink Telegram rejected by domain"
                Right _ -> do
                  logInfo "Telegram account unlinked successfully"
                  return $ Right ()

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
