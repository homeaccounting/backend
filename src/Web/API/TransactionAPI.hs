{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionAPI
-- Description : REST API endpoints for transaction operations
--
-- This module defines the Servant API for transaction operations.
-- Handlers are thin HTTP adapters that delegate to 'TransactionService' for
-- business orchestration and use 'ErrorMapping' for error responses.
--
-- API Endpoints:
--
--   POST   /api/transactions             - Create a new transaction (transfer)
--   GET    /api/transactions/:id         - Get transaction status
--
-- Handler Responsibilities (HTTP concerns only):
--   1. Extract data from HTTP request (path params, body, auth)
--   2. Convert DTOs to domain types (request parsing)
--   3. Delegate to TransactionService
--   4. Convert domain types to DTOs (response building)
--   5. Map service errors to HTTP errors
--
-- Transfer Flow:
--
--   1. Client creates transfer (POST /api/transactions)
--   2. TransactionService validates and issues InitiateTransfer command
--   3. TransferManager process manager handles the saga:
--      - Debit source account
--      - Credit target account
--      - Complete or fail transfer
--   4. Client can poll status (GET /api/transactions/:id)
module Web.API.TransactionAPI
  ( -- * API Type
    TransactionAPI,
    transactionAPI,

    -- * Server
    transactionServer,

    -- * Individual Handlers (exported for testing)
    initiateTransferHandler,
    getTransactionHandler,
  )
where

import qualified Application.Services.TransactionService as TransactionService
import Data.UUID (UUID)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types (mkAccountId)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( TransactionResponse,
    TransferRequest (..),
    fromTransactionSummary,
    toInitiateTransferCommand,
  )

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Transaction API type-level definition.
--
-- Authentication:
--  - Endpoints with AuthProtect "jwt" require a valid JWT token
--  - Token is passed via Authorization: Bearer <token> header
--  - Handler receives AuthenticatedUser automatically on success
--  - Returns 401 Unauthorized if token is missing/invalid
type TransactionAPI =
  -- POST /api/transactions - Create a new transaction (transfer)
  AuthProtect "jwt"
    :> "api"
    :> "transactions"
    :> ReqBody '[JSON] TransferRequest
    :> Post '[JSON] TransactionResponse
    -- GET /api/transactions/:id - Get transaction status (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> Get '[JSON] TransactionResponse

-- | Proxy for the TransactionAPI.
transactionAPI :: Proxy TransactionAPI
transactionAPI = Proxy

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Transaction API server implementation.
transactionServer :: ServerT TransactionAPI AppM
transactionServer =
  initiateTransferHandler
    :<|> getTransactionHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/transactions - Create a new transaction (transfer).
initiateTransferHandler :: AuthenticatedUser -> TransferRequest -> AppM TransactionResponse
initiateTransferHandler user request = do
  let userId = user.authUserId
  -- 1. Convert account UUIDs to AccountIds (Web layer validation)
  case mkAccountId request.fromAccountId of
    Left err ->
      throwDomainError $ ValidationErr $ mkValidationError "fromAccountId" err err
    Right fromAccId ->
      case mkAccountId request.toAccountId of
        Left err ->
          throwDomainError $ ValidationErr $ mkValidationError "toAccountId" err err
        Right toAccId -> do
          -- 2. Convert DTO to domain command
          case toInitiateTransferCommand userId fromAccId toAccId request of
            Left err ->
              throwDomainError $ ValidationErr $ mkValidationError "request" err err
            Right transferCmd -> do
              -- 3. Delegate to service
              result <- TransactionService.initiateTransfer transferCmd
              case result of
                -- 4. Convert domain result to response DTO
                Right (txId, summary) -> return $ fromTransactionSummary txId summary
                Left err -> throwDomainError err

-- | Handler for GET /api/transactions/:id - Get transaction status.
getTransactionHandler :: AuthenticatedUser -> UUID -> AppM TransactionResponse
getTransactionHandler _user transactionUuid = do
  result <- TransactionService.getTransaction transactionUuid
  case result of
    Right (txId, summary) -> return $ fromTransactionSummary txId summary
    Left err -> throwDomainError err
