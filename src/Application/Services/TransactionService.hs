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
    initiateIncome,
    initiateExpense,
    initiateInternalTransfer,
    getTransaction,
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData)
import qualified Application.ReadModels.Transaction as ReadModel
import Application.ReadModels.User (UserData (..))
import qualified Application.ReadModels.User as UserRM
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountCategory (..),
    AccountId,
    Currency,
    ExchangeRate,
    ExpenseCategory,
    IncomeCategory,
    Money,
    TransactionId,
    TransferCategory (..),
    TransferType (..),
    UserId,
    convert,
    exchangeRateValue,
    mkExchangeRate,
    mkTransactionId,
    moneyCurrency,
  )
import Domain.Transaction.CommandHandler (TransactionCommand (InitiateTransferTransactionCommand))
import Domain.Transaction.Commands (InitiateTransfer (..))
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasExchangeRateCache (..),
    HasReadModel (..),
  )
import Infrastructure.Eventium (applyTransactionCommand)
import Infrastructure.ExchangeRate.Provider (getCachedRate)
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
-- Returns the TransactionId and TransactionData on success.
initiateTransfer ::
  InitiateTransfer ->
  AppM (Either DomainError (TransactionId, TransactionData))
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
-- Returns the TransactionId and TransactionData on success.
getTransaction ::
  UUID ->
  AppM (Either DomainError (TransactionId, TransactionData))
getTransaction transactionUuid = do
  logInfo $ "Getting transaction: " <> displayShow transactionUuid

  -- 1. Convert UUID to TransactionId
  case mkTransactionId transactionUuid of
    Left _err -> do
      logWarn $ "Transaction ID validation failed (treating as not found): " <> displayShow transactionUuid
      return $ Left $ NotFound "Transaction" (tshow transactionUuid)
    Right transactionId -> queryTransactionResult transactionId

-- | Initiate an income transfer (External -> Regular account).
--
-- Looks up the user's External account and validates the target is a Regular
-- account. Resolves cross-currency amounts using ECB rates, then delegates
-- to 'initiateTransfer'.
initiateIncome ::
  UserId ->
  AccountId ->
  Money ->
  IncomeCategory ->
  Text ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateIncome userId targetAccountId amount incomeCat reason = do
  logInfo "Initiating income transfer..."

  -- 1. Look up user's External account
  userRM <- view userReadModelL
  maybeUser <- UserRM.getUser userRM userId
  case maybeUser of
    Nothing -> do
      logWarn $ "User not found: " <> displayShow userId
      return $ Left $ NotFound "User" (tshow userId)
    Just userData -> do
      let externalAccId = userData.externalAccountId

      -- 2. Validate target account exists and is Regular
      accountRM <- view accountReadModelL
      maybeTarget <- AccountRM.getAccount accountRM targetAccountId
      case maybeTarget of
        Nothing -> do
          logWarn $ "Target account not found: " <> displayShow targetAccountId
          return $ Left $ NotFound "Account" (tshow targetAccountId)
        Just targetData ->
          if targetData.accountCategory == External
            then do
              logWarn "Target account is not a regular account"
              return $ Left $ ValidationErr $ mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId)
            else do
              -- 3. Look up External account to get its currency
              maybeExternal <- AccountRM.getAccount accountRM externalAccId
              case maybeExternal of
                Nothing -> do
                  logWarn $ "External account not found: " <> displayShow externalAccId
                  return $ Left $ NotFound "Account" (tshow externalAccId)
                Just externalData -> do
                  let srcCurrency = moneyCurrency externalData.balance
                      tgtCurrency = moneyCurrency targetData.balance
                  -- Income: user provides amount in target (Regular) currency
                  resolveResult <- resolveAmounts amount srcCurrency tgtCurrency False Nothing
                  case resolveResult of
                    Left err -> return $ Left err
                    Right (srcAmt, tgtAmt, rate) -> do
                      let cmd =
                            InitiateTransfer
                              { fromAccountId = externalAccId,
                                toAccountId = targetAccountId,
                                sourceAmount = srcAmt,
                                targetAmount = tgtAmt,
                                exchangeRate = rate,
                                reason = reason,
                                initiatedBy = userId,
                                transferType = Income,
                                category = IncomeCat incomeCat
                              }
                      initiateTransfer cmd

-- | Initiate an expense transfer (Regular -> External account).
--
-- Looks up the user's External account and validates the source is a Regular
-- account. Resolves cross-currency amounts using ECB rates, then delegates
-- to 'initiateTransfer'.
initiateExpense ::
  UserId ->
  AccountId ->
  Money ->
  ExpenseCategory ->
  Text ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateExpense userId sourceAccountId amount expenseCat reason = do
  logInfo "Initiating expense transfer..."

  -- 1. Look up user's External account
  userRM <- view userReadModelL
  maybeUser <- UserRM.getUser userRM userId
  case maybeUser of
    Nothing -> do
      logWarn $ "User not found: " <> displayShow userId
      return $ Left $ NotFound "User" (tshow userId)
    Just userData -> do
      let externalAccId = userData.externalAccountId

      -- 2. Validate source account exists and is Regular
      accountRM <- view accountReadModelL
      maybeSource <- AccountRM.getAccount accountRM sourceAccountId
      case maybeSource of
        Nothing -> do
          logWarn $ "Source account not found: " <> displayShow sourceAccountId
          return $ Left $ NotFound "Account" (tshow sourceAccountId)
        Just sourceData ->
          if sourceData.accountCategory == External
            then do
              logWarn "Source account is not a regular account"
              return $ Left $ ValidationErr $ mkValidationError "accountId" "Account must be a regular account" (tshow sourceAccountId)
            else do
              -- 3. Look up External account to get its currency
              maybeExternal <- AccountRM.getAccount accountRM externalAccId
              case maybeExternal of
                Nothing -> do
                  logWarn $ "External account not found: " <> displayShow externalAccId
                  return $ Left $ NotFound "Account" (tshow externalAccId)
                Just externalData -> do
                  let srcCurrency = moneyCurrency sourceData.balance
                      tgtCurrency = moneyCurrency externalData.balance
                  -- Expense: user provides amount in source (Regular) currency
                  resolveResult <- resolveAmounts amount srcCurrency tgtCurrency True Nothing
                  case resolveResult of
                    Left err -> return $ Left err
                    Right (srcAmt, tgtAmt, rate) -> do
                      let cmd =
                            InitiateTransfer
                              { fromAccountId = sourceAccountId,
                                toAccountId = externalAccId,
                                sourceAmount = srcAmt,
                                targetAmount = tgtAmt,
                                exchangeRate = rate,
                                reason = reason,
                                initiatedBy = userId,
                                transferType = Expense,
                                category = ExpenseCat expenseCat
                              }
                      initiateTransfer cmd

-- | Initiate an internal transfer (Regular -> Regular account).
--
-- Validates both accounts exist and are Regular, resolves cross-currency
-- amounts, then delegates to 'initiateTransfer'.
initiateInternalTransfer ::
  UserId ->
  AccountId ->
  AccountId ->
  Money ->
  Text ->
  Maybe Rational ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateInternalTransfer userId sourceAccountId targetAccountId amount reason maybeUserRate = do
  logInfo "Initiating internal transfer..."

  -- 1. Validate both accounts exist and are Regular
  accountRM <- view accountReadModelL
  maybeSource <- AccountRM.getAccount accountRM sourceAccountId
  case maybeSource of
    Nothing -> do
      logWarn $ "Source account not found: " <> displayShow sourceAccountId
      return $ Left $ NotFound "Account" (tshow sourceAccountId)
    Just sourceData ->
      if sourceData.accountCategory == External
        then do
          logWarn "Source account is not a regular account"
          return $ Left $ ValidationErr $ mkValidationError "accountId" "Account must be a regular account" (tshow sourceAccountId)
        else do
          maybeTarget <- AccountRM.getAccount accountRM targetAccountId
          case maybeTarget of
            Nothing -> do
              logWarn $ "Target account not found: " <> displayShow targetAccountId
              return $ Left $ NotFound "Account" (tshow targetAccountId)
            Just targetData ->
              if targetData.accountCategory == External
                then do
                  logWarn "Target account is not a regular account"
                  return $ Left $ ValidationErr $ mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId)
                else do
                  let srcCurrency = moneyCurrency sourceData.balance
                      tgtCurrency = moneyCurrency targetData.balance
                  -- Internal: user provides amount in source currency
                  resolveResult <- resolveAmounts amount srcCurrency tgtCurrency True maybeUserRate
                  case resolveResult of
                    Left err -> return $ Left err
                    Right (srcAmt, tgtAmt, rate) -> do
                      let cmd =
                            InitiateTransfer
                              { fromAccountId = sourceAccountId,
                                toAccountId = targetAccountId,
                                sourceAmount = srcAmt,
                                targetAmount = tgtAmt,
                                exchangeRate = rate,
                                reason = reason,
                                initiatedBy = userId,
                                transferType = InternalTransfer,
                                category = InternalCat
                              }
                      initiateTransfer cmd

-- -----------------------------------------------------------------------------
-- Internal Helpers
-- -----------------------------------------------------------------------------

-- | Query the read model for a transaction and return the result.
queryTransactionResult ::
  TransactionId ->
  AppM (Either DomainError (TransactionId, TransactionData))
queryTransactionResult transactionId = do
  readModel <- view transactionReadModelL
  maybeSummary <- liftIO $ ReadModel.getTransaction readModel transactionId
  case maybeSummary of
    Just summary -> do
      logInfo "Transaction found"
      return $ Right (transactionId, summary)
    Nothing -> do
      logWarn "Transaction not found"
      return $ Left $ NotFound "Transaction" (tshow transactionId)

-- | Resolve amounts for a cross-currency transfer.
-- For same-currency: returns identical amounts with Nothing rate.
-- For different currencies: fetches rate and converts.
--
-- Parameters:
--   userAmount: the amount the user provided
--   srcCurrency: source account currency
--   tgtCurrency: target account currency
--   userAmountIsSource: True if userAmount is in source currency, False if in target
--   maybeUserRate: optional user-provided exchange rate override (src -> tgt)
resolveAmounts ::
  (MonadReader env m, HasExchangeRateCache env, MonadIO m) =>
  Money ->
  Currency ->
  Currency ->
  Bool ->
  Maybe Rational ->
  m (Either DomainError (Money, Money, Maybe ExchangeRate))
resolveAmounts userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate
  | srcCurrency == tgtCurrency =
      pure $ Right (userAmount, userAmount, Nothing)
  | otherwise = do
      -- Always resolve src->tgt rate
      rateResult <- case maybeUserRate of
        Just r ->
          pure $ first ExchangeRateUnavailable $ mkExchangeRate srcCurrency tgtCurrency r
        Nothing -> do
          cache <- view exchangeRateCacheL
          liftIO
            $ getCachedRate cache srcCurrency tgtCurrency
            <&> first ExchangeRateUnavailable
      case rateResult of
        Left err -> pure $ Left err
        Right er ->
          if userAmountIsSource
            then -- User gave source amount, compute target
              let tgtAmount = convert er userAmount
               in pure $ Right (userAmount, tgtAmount, Just er)
            else -- User gave target amount, compute source (use inverse rate)
              case mkExchangeRate tgtCurrency srcCurrency (1 / exchangeRateValue er) of
                Left err -> pure $ Left $ ExchangeRateUnavailable err
                Right inverseEr ->
                  let srcAmount = convert inverseEr userAmount
                   in pure $ Right (srcAmount, userAmount, Just er)

-- Note: Uses 'tshow' from RIO for Text conversion of Show-able values.
