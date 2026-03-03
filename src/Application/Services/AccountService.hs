{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AccountService
-- Description : Account use case orchestration
--
-- This module implements the application-level orchestration for account
-- operations, handling:
--
--   - ID generation and validation
--   - Event store interactions
--   - Read model queries
--   - Command construction and execution
--
-- Services accept and return domain/application types only. Web-layer
-- DTO conversion is the responsibility of the API handlers.
--
-- All functions return @Either DomainError a@ to make errors explicit in
-- the type, following the project's idiomatic error handling approach.
--
-- Usage:
--   Services are called by thin API handlers in @Web.API.AccountAPI@.
module Application.Services.AccountService
  ( -- * Service Functions
    createAccount,
    getAccount,
    listAccountsForUser,
    shareAccount,
    revokeAccountAccess,
  )
where

import Application.ReadModels.AccountSummary
  ( AccountSummaryData (..),
    getAccessibleAccounts,
    getAccountSummary,
  )
import Data.Text (Text)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands
  ( CreateAccount,
    RevokeAccountAccess (..),
    ShareAccount (..),
  )
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountId,
    AccountRole (..),
    AccountType (..),
    UserId,
    mkAccountId,
    mkUserId,
  )
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasReadModel (..),
  )
import Infrastructure.Eventium (applyAccountCommand)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Create a new account.
--
-- Accepts a validated domain command. The caller (Web handler) is responsible
-- for converting the HTTP request DTO into a 'CreateAccount' command.
--
-- Orchestrates:
--   1. Generate new account ID (UUID)
--   2. Execute CreateAccount command via event store
--   3. Query read model for the created account
--
-- Returns the AccountId and AccountSummaryData on success.
createAccount ::
  CreateAccount ->
  AppM (Either DomainError (AccountId, AccountSummaryData))
createAccount createCmd = do
  logInfo "Creating new account..."

  -- 1. Generate new account ID
  accountUuid <- liftIO UUID.nextRandom
  case mkAccountId accountUuid of
    Left err -> do
      logError $ "Failed to create AccountId: " <> display err
      return $ Left $ AccountError "Internal error: failed to generate account ID"
    Right accountId -> do
      logInfo $ "Generated account ID: " <> displayShow accountUuid

      -- 2. Execute command in event store
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyAccountCommand writer reader accountUuid (CreateAccountAccountCommand createCmd)
      case result of
        Left err -> do
          logError $ "Account creation rejected: " <> displayShow err
          return $ Left $ AccountError "Account creation rejected by domain"
        Right events -> do
          logInfo $ "Account created, " <> displayShow (length events) <> " event(s) emitted"

          -- 3. Query read model for current state
          readModel <- view accountSummaryReadModelL
          maybeSummary <- liftIO $ getAccountSummary readModel accountId

          case maybeSummary of
            Just summary -> do
              logInfo "Account successfully created"
              return $ Right (accountId, summary)
            Nothing -> do
              logError "Account not found in read model after creation!"
              return $ Left $ AccountError "Account created but not found in read model"

-- | Get an account by UUID.
--
-- Orchestrates:
--   1. Convert UUID to AccountId
--   2. Query read model
--
-- Returns the AccountId and AccountSummaryData on success.
getAccount ::
  UUID ->
  AppM (Either DomainError (AccountId, AccountSummaryData))
getAccount accountUuid = do
  logInfo $ "Getting account: " <> displayShow accountUuid

  -- 1. Convert UUID to AccountId
  case mkAccountId accountUuid of
    Left _err -> do
      logWarn $ "Account ID validation failed (treating as not found): " <> displayShow accountUuid
      return $ Left $ NotFound "Account" (tshow accountUuid)
    Right accountId -> do
      -- 2. Query read model
      readModel <- view accountSummaryReadModelL
      maybeSummary <- liftIO $ getAccountSummary readModel accountId

      case maybeSummary of
        Just summary -> do
          logInfo "Account found"
          return $ Right (accountId, summary)
        Nothing -> do
          logWarn "Account not found"
          return $ Left $ NotFound "Account" (tshow accountUuid)

-- | List accounts accessible to a given user.
--
-- Queries the read model for accounts where the user has access (owner, editor, or viewer).
-- Returns a list of (AccountId, AccountSummaryData) pairs.
listAccountsForUser :: UserId -> AppM [(AccountId, AccountSummaryData)]
listAccountsForUser userId = do
  logInfo $ "Listing accounts for user " <> displayShow userId

  readModel <- view accountSummaryReadModelL
  accountsList <- liftIO $ getAccessibleAccounts readModel userId

  let result = map (\(aid, summary, _role) -> (aid, summary)) accountsList

  logInfo $ "Found " <> displayShow (length result) <> " account(s)"
  return result

-- | Share an account with another user.
--
-- Orchestrates:
--   1. Validate account exists and user is Owner
--   2. Validate target user ID and role
--   3. Check account is not External (cannot share External accounts)
--   4. Issue ShareAccount command
shareAccount ::
  UserId ->
  UUID ->
  UUID ->
  Text ->
  AppM (Either DomainError ())
shareAccount requestingUserId accountUuid targetUserUuid roleText = do
  logInfo $ "Sharing account: " <> displayShow accountUuid

  -- 1. Convert account UUID to AccountId
  case mkAccountId accountUuid of
    Left _err -> return $ Left $ NotFound "Account" (tshow accountUuid)
    Right accountId -> do
      -- 2. Check account exists and user is Owner
      readModel <- view accountSummaryReadModelL
      maybeSummary <- liftIO $ getAccountSummary readModel accountId

      case maybeSummary of
        Nothing -> return $ Left $ NotFound "Account" (tshow accountUuid)
        Just summary
          -- Check if user is the owner
          | accountSummaryDataCreatedBy summary /= requestingUserId -> do
              logWarn "User is not account owner"
              return $ Left $ AccountError "Only account owner can share access"
          -- Check account is not External
          | accountSummaryDataType summary == ExternalAccount -> do
              logWarn "Cannot share External account"
              return $ Left $ AccountError "External accounts cannot be shared"
          | otherwise -> do
              -- 3. Parse target user ID
              case mkUserId targetUserUuid of
                Left _err -> return $ Left $ ValidationErr $ mkValidationError "userId" "Invalid user ID" (tshow targetUserUuid)
                Right targetUserId -> do
                  -- 4. Parse role
                  case parseRole roleText of
                    Nothing -> return $ Left $ ValidationErr $ mkValidationError "role" "Invalid role. Must be 'owner', 'editor', or 'viewer'" roleText
                    Just role -> do
                      -- 5. Issue ShareAccount command
                      let shareCmd =
                            ShareAccountAccountCommand
                              ShareAccount
                                { shareAccountUserId = targetUserId,
                                  shareAccountRole = role,
                                  shareAccountGrantedBy = requestingUserId
                                }

                      writer <- view eventStoreWriterL
                      reader <- view eventStoreReaderL
                      result <- liftIO $ applyAccountCommand writer reader accountUuid shareCmd
                      case result of
                        Left err -> do
                          logError $ "Share account rejected: " <> displayShow err
                          return $ Left $ AccountError "Share account rejected by domain"
                        Right _ -> do
                          logInfo "Account shared successfully"
                          return $ Right ()

-- | Revoke a user's access to an account.
--
-- Orchestrates:
--   1. Validate account exists and user is Owner
--   2. Validate target user ID
--   3. Cannot revoke owner's own access
--   4. Issue RevokeAccountAccess command
revokeAccountAccess ::
  UserId ->
  UUID ->
  UUID ->
  AppM (Either DomainError ())
revokeAccountAccess requestingUserId accountUuid targetUserUuid = do
  logInfo $ "Revoking account access: " <> displayShow accountUuid

  -- 1. Convert account UUID to AccountId
  case mkAccountId accountUuid of
    Left _err -> return $ Left $ NotFound "Account" (tshow accountUuid)
    Right accountId -> do
      -- 2. Check account exists and user is Owner
      readModel <- view accountSummaryReadModelL
      maybeSummary <- liftIO $ getAccountSummary readModel accountId

      case maybeSummary of
        Nothing -> return $ Left $ NotFound "Account" (tshow accountUuid)
        Just summary
          -- Check if user is the owner
          | accountSummaryDataCreatedBy summary /= requestingUserId -> do
              logWarn "User is not account owner"
              return $ Left $ AccountError "Only account owner can revoke access"
          | otherwise -> do
              -- 3. Parse target user ID
              case mkUserId targetUserUuid of
                Left _err -> return $ Left $ ValidationErr $ mkValidationError "userId" "Invalid user ID" (tshow targetUserUuid)
                Right targetUserId
                  -- Cannot revoke owner's own access
                  | targetUserId == accountSummaryDataCreatedBy summary -> do
                      logWarn "Cannot revoke owner's access"
                      return $ Left $ AccountError "Cannot revoke owner's access"
                  | otherwise -> do
                      -- 4. Issue RevokeAccountAccess command
                      let revokeCmd =
                            RevokeAccountAccessAccountCommand
                              RevokeAccountAccess
                                { revokeAccountAccessUserId = targetUserId,
                                  revokeAccountAccessRevokedBy = requestingUserId
                                }

                      writer <- view eventStoreWriterL
                      reader <- view eventStoreReaderL
                      result <- liftIO $ applyAccountCommand writer reader accountUuid revokeCmd
                      case result of
                        Left err -> do
                          logError $ "Revoke access rejected: " <> displayShow err
                          return $ Left $ AccountError "Revoke access rejected by domain"
                        Right _ -> do
                          logInfo "Account access revoked successfully"
                          return $ Right ()

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Parse role from text.
parseRole :: Text -> Maybe AccountRole
parseRole t = case T.toLower t of
  "owner" -> Just Owner
  "editor" -> Just Editor
  "viewer" -> Just Viewer
  _ -> Nothing

-- Note: Uses 'tshow' from RIO for Text conversion of Show-able values.
