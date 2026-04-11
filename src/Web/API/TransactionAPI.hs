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
--   POST   /api/transactions/income    - Record an income transaction
--   POST   /api/transactions/expense   - Record an expense transaction
--   POST   /api/transactions/transfer  - Initiate an internal transfer
--   GET    /api/transactions/:id       - Get transaction status
--
-- Handler Responsibilities (HTTP concerns only):
--   1. Extract data from HTTP request (path params, body, auth)
--   2. Convert DTOs to domain types (request parsing)
--   3. Delegate to TransactionService
--   4. Convert domain types to DTOs (response building)
--   5. Map service errors to HTTP errors
module Web.API.TransactionAPI
  ( -- * API Type
    TransactionAPI,
    transactionAPI,

    -- * Server
    transactionServer,

    -- * Individual Handlers (exported for testing)
    incomeHandler,
    expenseHandler,
    transferHandler,
    getTransactionHandler,
  )
where

import qualified Application.Services.TransactionService as TransactionService
import Data.UUID (UUID)
import Domain.Core.Types (mkAccountId, parseCurrency)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( ExpenseRequest (..),
    IncomeRequest (..),
    InternalTransferRequest (..),
    TransactionResponse,
    fromTransactionData,
    parseCategoryId,
    toDomainMoney,
  )
import Web.Validation (validateDateNotInFuture, validateField)

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
  -- POST /api/transactions/income - Record an income transaction
  AuthProtect "jwt"
    :> "api"
    :> "transactions"
    :> "income"
    :> ReqBody '[JSON] IncomeRequest
    :> Post '[JSON] TransactionResponse
    -- POST /api/transactions/expense - Record an expense transaction
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> "expense"
      :> ReqBody '[JSON] ExpenseRequest
      :> Post '[JSON] TransactionResponse
    -- POST /api/transactions/transfer - Initiate an internal transfer
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> "transfer"
      :> ReqBody '[JSON] InternalTransferRequest
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
  incomeHandler
    :<|> expenseHandler
    :<|> transferHandler
    :<|> getTransactionHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/transactions/income - Record an income transaction.
incomeHandler :: AuthenticatedUser -> IncomeRequest -> AppM TransactionResponse
incomeHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  categoryEntryId <- validateField "category" $ parseCategoryId request.category
  accountId <- validateField "accountId" $ mkAccountId request.accountId
  cur <- validateField "currency" $ parseCurrency request.currency
  money <- validateField "amount" $ toDomainMoney cur request.amount
  result <- TransactionService.initiateIncome userId accountId money categoryEntryId request.description request.date
  case result of
    Right (txId, summary) -> return $ fromTransactionData txId summary
    Left err -> throwDomainError err

-- | Handler for POST /api/transactions/expense - Record an expense transaction.
expenseHandler :: AuthenticatedUser -> ExpenseRequest -> AppM TransactionResponse
expenseHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  categoryEntryId <- validateField "category" $ parseCategoryId request.category
  accountId <- validateField "accountId" $ mkAccountId request.accountId
  cur <- validateField "currency" $ parseCurrency request.currency
  money <- validateField "amount" $ toDomainMoney cur request.amount
  result <- TransactionService.initiateExpense userId accountId money categoryEntryId request.description request.date
  case result of
    Right (txId, summary) -> return $ fromTransactionData txId summary
    Left err -> throwDomainError err

-- | Handler for POST /api/transactions/transfer - Initiate an internal transfer.
transferHandler :: AuthenticatedUser -> InternalTransferRequest -> AppM TransactionResponse
transferHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  fromAccId <- validateField "sourceAccountId" $ mkAccountId request.sourceAccountId
  toAccId <- validateField "targetAccountId" $ mkAccountId request.targetAccountId
  cur <- validateField "currency" $ parseCurrency request.currency
  money <- validateField "amount" $ toDomainMoney cur request.amount
  let maybeRate = fmap toRational request.exchangeRate
  result <- TransactionService.initiateInternalTransfer userId fromAccId toAccId money request.description maybeRate request.date
  case result of
    Right (txId, summary) -> return $ fromTransactionData txId summary
    Left err -> throwDomainError err

-- | Handler for GET /api/transactions/:id - Get transaction status.
getTransactionHandler :: AuthenticatedUser -> UUID -> AppM TransactionResponse
getTransactionHandler _user transactionUuid = do
  result <- TransactionService.getTransaction transactionUuid
  case result of
    Right (txId, summary) -> return $ fromTransactionData txId summary
    Left err -> throwDomainError err
