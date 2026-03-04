{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionService
-- Description : Transaction use case orchestration
--
-- This module implements the application-level orchestration for transaction
-- (transfer) operations, handling:
--
--   - ID generation and validation
--   - Event store interactions
--   - Read model queries
--   - Command execution
--
-- Services accept and return domain/application types only. Web-layer
-- DTO conversion is the responsibility of the API handlers.
--
-- The actual transfer is coordinated by the 'TransferManager' process manager
-- (saga). This service initiates the transfer by issuing the InitiateTransfer
-- command; the TransferManager then handles the debit/credit/complete/fail flow.
--
-- Usage:
--   Services are called by thin API handlers in @Web.API.TransactionAPI@.
module Application.Services.TransactionService
  ( -- * Service Functions
    initiateTransfer,
    getTransaction,
  )
where

import Application.ReadModels.TransactionSummary
  ( TransactionSummaryData,
    getTransactionSummary,
  )
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    TransactionId,
    UserId,
    mkTransactionId,
  )
import Domain.Transaction.CommandHandler (TransactionCommand (InitiateTransferTransactionCommand))
import Domain.Transaction.Commands (InitiateTransfer)
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasReadModel (..),
  )
import Infrastructure.Eventium (applyTransactionCommand)
import RIO

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Initiate a money transfer between accounts.
--
-- Accepts a validated domain command. The caller (Web handler) is responsible
-- for converting the HTTP request DTO into an 'InitiateTransfer' command.
--
-- Orchestrates:
--   1. Generate new transaction ID (UUID)
--   2. Execute InitiateTransfer command via event store
--   3. Query read model for the created transaction
--
-- The TransferManager process manager will then:
--   - Debit the source account
--   - Credit the target account
--   - Complete or fail the transaction
--
-- Returns the TransactionId and TransactionSummaryData on success.
initiateTransfer ::
  InitiateTransfer ->
  AppM (Either DomainError (TransactionId, TransactionSummaryData))
initiateTransfer transferCmd = do
  logInfo "Initiating money transfer..."

  -- 1. Generate new transaction ID
  transactionUuid <- liftIO UUID.nextRandom
  case mkTransactionId transactionUuid of
    Left err -> do
      logError $ "Failed to create TransactionId: " <> display err
      return $ Left $ TransactionError "Internal error: failed to generate transaction ID"
    Right transactionId -> do
      logInfo $ "Generated transaction ID: " <> displayShow transactionUuid

      -- 2. Execute command in event store
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyTransactionCommand writer reader transactionUuid (InitiateTransferTransactionCommand transferCmd)
      case result of
        Left err -> do
          logError $ "Transfer initiation rejected: " <> displayShow err
          return $ Left $ TransactionError "Transfer initiation rejected by domain"
        Right events -> do
          logInfo $ "Transfer initiated, " <> displayShow (length events) <> " event(s) emitted"

          -- 3. Query read model for current state
          queryTransactionResult transactionId

-- | Get a transaction by UUID.
--
-- Orchestrates:
--   1. Convert UUID to TransactionId
--   2. Query read model
--
-- Returns the TransactionId and TransactionSummaryData on success.
getTransaction ::
  UUID ->
  AppM (Either DomainError (TransactionId, TransactionSummaryData))
getTransaction transactionUuid = do
  logInfo $ "Getting transaction: " <> displayShow transactionUuid

  -- 1. Convert UUID to TransactionId
  case mkTransactionId transactionUuid of
    Left _err -> do
      logWarn $ "Transaction ID validation failed (treating as not found): " <> displayShow transactionUuid
      return $ Left $ NotFound "Transaction" (tshow transactionUuid)
    Right transactionId -> queryTransactionResult transactionId

-- -----------------------------------------------------------------------------
-- Internal Helpers
-- -----------------------------------------------------------------------------

-- | Query the read model for a transaction and return the result.
queryTransactionResult ::
  TransactionId ->
  AppM (Either DomainError (TransactionId, TransactionSummaryData))
queryTransactionResult transactionId = do
  readModel <- view transactionSummaryReadModelL
  maybeSummary <- liftIO $ getTransactionSummary readModel transactionId
  case maybeSummary of
    Just summary -> do
      logInfo "Transaction found"
      return $ Right (transactionId, summary)
    Nothing -> do
      logWarn "Transaction not found"
      return $ Left $ NotFound "Transaction" (tshow transactionId)

-- Note: Uses 'tshow' from RIO for Text conversion of Show-able values.
