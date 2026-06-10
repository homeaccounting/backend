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
--   PUT    /api/accounts/:id/name    - Rename account
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
    RenameAccountRequest (..),

    -- * Server
    accountServer,

    -- * Individual Handlers (exported for testing)
    createAccountHandler,
    getAccountHandler,
    listAccountsHandler,
    shareAccountHandler,
    revokeAccountAccessHandler,
    setOverdraftLimitHandler,
    setAccountSubtypeHandler,
    adjustBalanceHandler,
    renameAccountHandler,
  )
where

import qualified Application.Services.AccountService as AccountService
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Text as T
import Data.UUID (UUID)
import Domain.Core.Types (mkAccountId, mkMoney, parseCurrency)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError, throwValidation)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( AccountListResponse (..),
    AccountResponse,
    AdjustBalanceRequest (..),
    CreateAccountRequest (..),
    SetAccountSubtypeRequest (..),
    TransactionResponse,
    fromAccountData,
    fromTransactionData,
    toAccountSubtype,
    toCreateAccountCommand,
    toDomainMoney,
  )
import Web.Validation (validateField, validateFieldCtx)

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
      :> ReqBody '[JSON] SetAccountSubtypeRequest
      :> Put '[JSON] NoContent
    -- PUT /api/accounts/:id/name - Rename account (requires auth, owner only)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "name"
      :> ReqBody '[JSON] RenameAccountRequest
      :> Put '[JSON] NoContent
    -- PUT /api/accounts/:id/balance - Adjust account balance (requires auth, editor+)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "balance"
      :> ReqBody '[JSON] AdjustBalanceRequest
      :> Put '[JSON] TransactionResponse

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

-- | Rename account request.
data RenameAccountRequest = RenameAccountRequest
  { name :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RenameAccountRequest

instance FromJSON RenameAccountRequest

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
    :<|> setAccountSubtypeHandler
    :<|> renameAccountHandler
    :<|> adjustBalanceHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/accounts - Create a new account.
createAccountHandler :: AuthenticatedUser -> CreateAccountRequest -> AppM AccountResponse
createAccountHandler user request = do
  let userId = user.userId

  -- Reject negative initial balance unless overdraft covers it.
  -- Mirrors handleAccountCommand's domain rule for a per-field 400 response.
  when (request.initialBalance < 0) $ case request.overdraftLimit of
    Nothing ->
      throwValidation
        "overdraftLimit"
        "Overdraft limit is required when initial balance is negative"
    Just lim
      | abs request.initialBalance > lim ->
          throwValidation
            "overdraftLimit"
            "Overdraft limit must be at least the absolute value of the initial balance"
      | otherwise -> pure ()

  -- 1. Convert DTO to domain command (Web layer responsibility)
  createCmd <- validateField "request" $ toCreateAccountCommand userId request
  -- 2. Delegate to service
  result <- AccountService.createAccount createCmd
  case result of
    -- 3. Convert domain result to response DTO
    Right (accountId, account) -> return $ fromAccountData accountId account
    Left err -> throwDomainError err

-- | Handler for GET /api/accounts/:id - Get account by ID.
getAccountHandler :: AuthenticatedUser -> UUID -> AppM AccountResponse
getAccountHandler _user accountUuid = do
  result <- AccountService.getAccount accountUuid
  case result of
    Right (accountId, account) -> return $ fromAccountData accountId account
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
      cur <- validateFieldCtx "currency" curText $ parseCurrency curText
      money <- validateFieldCtx "overdraftLimit" (tshow amt) $ mkMoney cur (toRational amt)
      return (Just money)

  result <- AccountService.setOverdraftLimit userId accountUuid domainLimit
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for PUT /api/accounts/:id/type - Set account subtype.
setAccountSubtypeHandler :: AuthenticatedUser -> UUID -> SetAccountSubtypeRequest -> AppM NoContent
setAccountSubtypeHandler user accountUuid SetAccountSubtypeRequest {..} = do
  let userId = user.userId
  domainType <- validateField "subtype" $ toAccountSubtype subtype
  result <- AccountService.setAccountSubtype userId accountUuid domainType
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for PUT /api/accounts/:id/name - Rename an account.
--
-- Trims the name and rejects empty or whitespace-only inputs and names
-- longer than 120 characters with per-field 400 responses. Other errors
-- (not found, forbidden, name unchanged) are mapped via 'throwDomainError'.
renameAccountHandler :: AuthenticatedUser -> UUID -> RenameAccountRequest -> AppM NoContent
renameAccountHandler user accountUuid RenameAccountRequest {..} = do
  let userId = user.userId
  let trimmed = T.strip name
  when (T.null trimmed) $ throwValidation "name" "Name is required"
  when (T.length trimmed > 120) $ throwValidation "name" "Name must be 120 characters or fewer"
  result <- AccountService.renameAccount userId accountUuid trimmed
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err

-- | Handler for PUT /api/accounts/:id/balance - Adjust account balance.
adjustBalanceHandler ::
  AuthenticatedUser ->
  UUID ->
  AdjustBalanceRequest ->
  AppM TransactionResponse
adjustBalanceHandler user accountUuid req = do
  let userId = user.userId
  accountId <- validateField "id" $ mkAccountId accountUuid
  cur <- validateField "currency" $ parseCurrency req.currency
  let amount = toDomainMoney cur req.targetBalance
  result <-
    AccountService.adjustAccountBalance
      userId
      accountId
      amount
      req.date
      req.description
  case result of
    Right (txId, txData) -> pure $ fromTransactionData txId txData
    Left err -> throwDomainError err
