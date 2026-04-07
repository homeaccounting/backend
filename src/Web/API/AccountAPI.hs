{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.AccountAPI
-- Description : REST API endpoints for account operations
--
-- This module defines the Servant API for account management operations.
-- Handlers are thin HTTP adapters that delegate to 'AccountService' for
-- business orchestration and use 'ErrorMapping' for error responses.
--
-- API Endpoints:
--
--   POST   /api/accounts              - Create a new account
--   GET    /api/accounts/:id          - Get account by ID
--   GET    /api/accounts              - List all accounts
--   POST   /api/accounts/:id/share    - Share account with another user
--   DELETE /api/accounts/:id/access/:userId - Revoke user's access
--   PUT    /api/accounts/:id/overdraft-limit - Set overdraft limit
--
-- Handler Responsibilities (HTTP concerns only):
--   1. Extract data from HTTP request (path params, body, auth)
--   2. Convert DTOs to domain types (request parsing)
--   3. Delegate to AccountService
--   4. Convert domain types to DTOs (response building)
--   5. Map service errors to HTTP errors
module Web.API.AccountAPI
  ( -- * API Type
    AccountAPI,
    accountAPI,

    -- * Request/Response Types
    ShareAccountRequest (..),
    SetOverdraftLimitRequest (..),

    -- * Server
    accountServer,

    -- * Individual Handlers (exported for testing)
    createAccountHandler,
    getAccountHandler,
    listAccountsHandler,
    shareAccountHandler,
    revokeAccountAccessHandler,
    setOverdraftLimitHandler,
    setAccountTypeHandler,
  )
where

import qualified Application.Services.AccountService as AccountService
import Data.Aeson (FromJSON, ToJSON)
import Data.UUID (UUID)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types (mkMoney, parseCurrency)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( AccountListResponse (..),
    AccountResponse,
    CreateAccountRequest,
    SetAccountTypeRequest (..),
    fromAccountData,
    toAccountType,
    toCreateAccountCommand,
  )

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Account API type-level definition.
--
-- This defines the REST API structure using Servant's type-level DSL.
-- Each endpoint is composed of:
--  - HTTP method (Get, Post, etc.)
--  - Path segments ("accounts", Capture for :id)
--  - Request body (ReqBody)
--  - Response type (JSON)
--
-- Authentication:
--  - Endpoints with AuthProtect "jwt" require a valid JWT token
--  - Token is passed via Authorization: Bearer <token> header
--  - Handler receives AuthenticatedUser automatically on success
--  - Returns 401 Unauthorized if token is missing/invalid
--
-- The type ensures compile-time correctness of the API implementation.
type AccountAPI =
  -- POST /api/accounts - Create new account (requires auth, returns 201 Created)
  AuthProtect "jwt"
    :> "api"
    :> "accounts"
    :> ReqBody '[JSON] CreateAccountRequest
    :> Verb 'POST 201 '[JSON] AccountResponse
    -- GET /api/accounts/:id - Get account by ID (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> Get '[JSON] AccountResponse
    -- GET /api/accounts - List all accounts (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Get '[JSON] AccountListResponse
    -- POST /api/accounts/:id/share - Share account with another user (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "share"
      :> ReqBody '[JSON] ShareAccountRequest
      :> Post '[JSON] NoContent
    -- DELETE /api/accounts/:id/access/:userId - Revoke user's access (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "access"
      :> Capture "userId" UUID
      :> Delete '[JSON] NoContent
    -- PUT /api/accounts/:id/overdraft-limit - Set overdraft limit (requires auth, owner only)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "overdraft-limit"
      :> ReqBody '[JSON] SetOverdraftLimitRequest
      :> Put '[JSON] NoContent
    -- PUT /api/accounts/:id/type - Set account type (requires auth, owner only)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "type"
      :> ReqBody '[JSON] SetAccountTypeRequest
      :> Put '[JSON] NoContent

-- -----------------------------------------------------------------------------
-- Request Types
-- -----------------------------------------------------------------------------

-- | Share account request.
data ShareAccountRequest = ShareAccountRequest
  { userId :: UUID,
    role :: Text -- "owner", "editor", or "viewer"
  }
  deriving (Show, Eq, Generic)

instance ToJSON ShareAccountRequest

instance FromJSON ShareAccountRequest

-- | Set overdraft limit request.
data SetOverdraftLimitRequest = SetOverdraftLimitRequest
  { overdraftLimit :: Maybe Double,
    currency :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetOverdraftLimitRequest

instance FromJSON SetOverdraftLimitRequest

-- | Proxy for the AccountAPI.
accountAPI :: Proxy AccountAPI
accountAPI = Proxy

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Account API server implementation.
accountServer :: ServerT AccountAPI AppM
accountServer =
  createAccountHandler
    :<|> getAccountHandler
    :<|> listAccountsHandler
    :<|> shareAccountHandler
    :<|> revokeAccountAccessHandler
    :<|> setOverdraftLimitHandler
    :<|> setAccountTypeHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/accounts - Create a new account.
createAccountHandler :: AuthenticatedUser -> CreateAccountRequest -> AppM AccountResponse
createAccountHandler user request = do
  let userId = user.userId
  -- 1. Convert DTO to domain command (Web layer responsibility)
  case toCreateAccountCommand userId request of
    Left err -> throwDomainError $ ValidationErr $ mkValidationError "request" err err
    Right createCmd -> do
      -- 2. Delegate to service
      result <- AccountService.createAccount createCmd
      case result of
        -- 3. Convert domain result to response DTO
        Right (accountId, summary) -> return $ fromAccountData accountId summary
        Left err -> throwDomainError err

-- | Handler for GET /api/accounts/:id - Get account by ID.
getAccountHandler :: AuthenticatedUser -> UUID -> AppM AccountResponse
getAccountHandler _user accountUuid = do
  result <- AccountService.getAccount accountUuid
  case result of
    Right (accountId, summary) -> return $ fromAccountData accountId summary
    Left err -> throwDomainError err

-- | Handler for GET /api/accounts - List accounts accessible to the authenticated user.
listAccountsHandler :: AuthenticatedUser -> AppM AccountListResponse
listAccountsHandler user = do
  let userId = user.userId
  accountsList <- AccountService.listAccountsForUser userId
  let responses = map (uncurry fromAccountData) accountsList
      totalCount = length responses
  return $ AccountListResponse responses totalCount

-- | Handler for POST /api/accounts/:id/share - Share account with another user.
shareAccountHandler :: AuthenticatedUser -> UUID -> ShareAccountRequest -> AppM NoContent
shareAccountHandler user accountUuid ShareAccountRequest {..} = do
  let currentUserId = user.userId
  result <- AccountService.shareAccount currentUserId accountUuid userId role
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for DELETE /api/accounts/:id/access/:userId - Revoke user's access.
revokeAccountAccessHandler :: AuthenticatedUser -> UUID -> UUID -> AppM NoContent
revokeAccountAccessHandler user accountUuid targetUserUuid = do
  let userId = user.userId
  result <- AccountService.revokeAccountAccess userId accountUuid targetUserUuid
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for PUT /api/accounts/:id/overdraft-limit - Set overdraft limit.
setOverdraftLimitHandler :: AuthenticatedUser -> UUID -> SetOverdraftLimitRequest -> AppM NoContent
setOverdraftLimitHandler user accountUuid SetOverdraftLimitRequest {..} = do
  let userId = user.userId

  domainLimit <- case overdraftLimit of
    Nothing -> return Nothing
    Just amt -> do
      let curText = fromMaybe "USD" currency
      case parseCurrency curText of
        Left err -> throwDomainError $ ValidationErr $ mkValidationError "currency" err curText
        Right cur ->
          case mkMoney cur (toRational amt) of
            Left err -> throwDomainError $ ValidationErr $ mkValidationError "overdraftLimit" err (tshow amt)
            Right money -> return (Just money)

  result <- AccountService.setOverdraftLimit userId accountUuid domainLimit
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for PUT /api/accounts/:id/type - Set account type.
setAccountTypeHandler :: AuthenticatedUser -> UUID -> SetAccountTypeRequest -> AppM NoContent
setAccountTypeHandler user accountUuid SetAccountTypeRequest {..} = do
  let userId = user.userId
  case toAccountType accountType of
    Left err -> throwDomainError $ ValidationErr $ mkValidationError "accountType" err err
    Right domainType -> do
      result <- AccountService.setAccountType userId accountUuid domainType
      case result of
        Right () -> return NoContent
        Left err -> throwDomainError err
