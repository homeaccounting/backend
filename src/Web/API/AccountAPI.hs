{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
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

    -- * Server
    accountServer,

    -- * Individual Handlers (exported for testing)
    createAccountHandler,
    getAccountHandler,
    listAccountsHandler,
    shareAccountHandler,
    revokeAccountAccessHandler,
  )
where

import qualified Application.Services.AccountService as AccountService
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.UUID (UUID)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types (AccountType (..))
import GHC.Generics (Generic)
import Infrastructure.App (AppM)
import RIO
import Servant
import Servant.API (NoContent (..))
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( AccountListResponse (..),
    AccountResponse,
    CreateAccountRequest,
    fromAccountSummary,
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

-- -----------------------------------------------------------------------------
-- Request Types
-- -----------------------------------------------------------------------------

-- | Share account request.
data ShareAccountRequest = ShareAccountRequest
  { shareUserId :: UUID,
    shareRole :: Text -- "owner", "editor", or "viewer"
  }
  deriving (Show, Eq, Generic)

instance ToJSON ShareAccountRequest

instance FromJSON ShareAccountRequest

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

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/accounts - Create a new account.
createAccountHandler :: AuthenticatedUser -> CreateAccountRequest -> AppM AccountResponse
createAccountHandler user request = do
  let userId = authUserId user
      accountType = RegularAccount
  -- 1. Convert DTO to domain command (Web layer responsibility)
  case toCreateAccountCommand userId accountType request of
    Left err -> throwDomainError $ ValidationErr $ mkValidationError "request" err err
    Right createCmd -> do
      -- 2. Delegate to service
      result <- AccountService.createAccount createCmd
      case result of
        -- 3. Convert domain result to response DTO
        Right (accountId, summary) -> return $ fromAccountSummary accountId summary
        Left err -> throwDomainError err

-- | Handler for GET /api/accounts/:id - Get account by ID.
getAccountHandler :: AuthenticatedUser -> UUID -> AppM AccountResponse
getAccountHandler _user accountUuid = do
  result <- AccountService.getAccount accountUuid
  case result of
    Right (accountId, summary) -> return $ fromAccountSummary accountId summary
    Left err -> throwDomainError err

-- | Handler for GET /api/accounts - List accounts accessible to the authenticated user.
listAccountsHandler :: AuthenticatedUser -> AppM AccountListResponse
listAccountsHandler user = do
  let userId = authUserId user
  accountsList <- AccountService.listAccountsForUser userId
  let responses = map (uncurry fromAccountSummary) accountsList
      totalCount = length responses
  return $ AccountListResponse responses totalCount

-- | Handler for POST /api/accounts/:id/share - Share account with another user.
shareAccountHandler :: AuthenticatedUser -> UUID -> ShareAccountRequest -> AppM NoContent
shareAccountHandler user accountUuid ShareAccountRequest {..} = do
  let userId = authUserId user
  result <- AccountService.shareAccount userId accountUuid shareUserId shareRole
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for DELETE /api/accounts/:id/access/:userId - Revoke user's access.
revokeAccountAccessHandler :: AuthenticatedUser -> UUID -> UUID -> AppM NoContent
revokeAccountAccessHandler user accountUuid targetUserUuid = do
  let userId = authUserId user
  result <- AccountService.revokeAccountAccess userId accountUuid targetUserUuid
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err
