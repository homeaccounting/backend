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
    listTransactions,
    setTransactionLabels,
    changeTransactionCategory,
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import Application.ReadModels.ExchangeRate (lookupHistoricalRate)
import Application.ReadModels.Transaction (TransactionData (..), TransactionQuery)
import qualified Application.ReadModels.Transaction as ReadModel
import Application.ReadModels.User (UserData (..))
import qualified Application.ReadModels.User as UserRM
import qualified Application.Services.ConfigurationService as ConfigurationService
import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
    runTransactionCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time (Day, UTCTime, getCurrentTime, utctDay)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountId,
    AccountRole (..),
    AccountType (..),
    CategoryId,
    Currency,
    DictionaryEntryId,
    DictionaryId,
    ExchangeRate,
    LabelId,
    Money,
    TransactionId,
    TransferType (..),
    UserId,
    convert,
    exchangeRateValue,
    mkExchangeRate,
    mkTransactionId,
    moneyCurrency,
    unDictionaryEntryId,
    unTransactionId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand
      ( ChangeTransactionCategoryTransactionCommand,
        InitiateTransferTransactionCommand,
        SetTransactionLabelsTransactionCommand
      ),
    TransactionError,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( ChangeTransactionCategory (..),
    InitiateTransfer (..),
    SetTransactionLabels (..),
  )
import Eventium (CommandHandlerError (..))
import Infrastructure.App
  ( AppM,
    HasAppConfig (..),
    HasExchangeRateReadModel (..),
    HasReadModel (..),
  )
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import RIO
import qualified RIO.Text as T

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
initiateTransfer transferCmd = runExceptT $ do
  lift $ logInfo "Initiating money transfer..."
  transactionUuid <- liftIO UUID.nextRandom
  transactionId <-
    liftEitherWith
      (\err -> TransactionError ("Internal error: failed to generate transaction ID: " <> tshow err))
      (mkTransactionId transactionUuid)
  lift $ logInfo $ "Generated transaction ID: " <> displayShow transactionUuid
  runTransactionCmd
    (\_ -> TransactionError "Transfer initiation rejected by domain")
    id
    transactionUuid
    (InitiateTransferTransactionCommand transferCmd)
  ExceptT (queryTransactionResult transactionId)

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
getTransaction transactionUuid = runExceptT $ do
  lift $ logInfo $ "Getting transaction: " <> displayShow transactionUuid
  transactionId <-
    liftEitherWith
      (\_ -> NotFound "Transaction" (tshow transactionUuid))
      (mkTransactionId transactionUuid)
  ExceptT (queryTransactionResult transactionId)

-- | List transactions visible to the given user, filtered by the provided
-- query. A transaction is visible when its source or target belongs to an
-- account the user has any role on (Owner / Editor / Viewer).
--
-- Returns '[]' — never an error — when the user has no accessible accounts
-- or when the query's accountId is outside the visible set. The HTTP layer
-- surfaces this as a 200 empty list (see
-- docs/specs/2026-04-18-list-transactions-endpoint-design.md §4).
listTransactions ::
  UserId ->
  TransactionQuery ->
  AppM [(TransactionId, TransactionData)]
listTransactions userId query = do
  logDebug $ "Listing transactions for user " <> displayShow userId
  accountRM <- view accountReadModelL
  accessible <- AccountRM.getAccessibleAccounts accountRM userId
  let visible = Set.fromList [aid | (aid, _, _) <- accessible]
  if Set.null visible
    then do
      logDebug "User has no accessible accounts; returning empty list"
      pure []
    else do
      readModel <- view transactionReadModelL
      ReadModel.listTransactions readModel visible query

-- | Initiate an income transfer (External -> Regular account).
--
-- Looks up the user's External account and validates the target is a Regular
-- account. Resolves cross-currency amounts using ECB rates, then delegates
-- to 'initiateTransfer'.
initiateIncome ::
  UserId ->
  AccountId ->
  Money ->
  CategoryId ->
  Set LabelId ->
  Text ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateIncome userId targetAccountId amount categoryEntryId labels description maybeTransferDate =
  runExceptT $ do
    lift $ logInfo "Initiating income transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    userRM <- lift (view userReadModelL)
    userData <- liftMaybeM (NotFound "User" (tshow userId)) (UserRM.getUser userRM userId)
    let externalAccId = userData.externalAccountId
    accountRM <- lift (view accountReadModelL)
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow targetAccountId))
        (AccountRM.getAccount accountRM targetAccountId)
    guardE
      (targetData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId))
      )
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow externalAccId))
        (AccountRM.getAccount accountRM externalAccId)
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    -- Income: user provides amount in target (Regular) currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency False Nothing
          $ \date srcAmt tgtAmt rate ->
            InitiateTransfer
              { sourceAccountId = externalAccId,
                targetAccountId = targetAccountId,
                sourceAmount = srcAmt,
                targetAmount = tgtAmt,
                exchangeRate = rate,
                description = description,
                initiatedBy = userId,
                at = date,
                transferType = Income categoryEntryId,
                externalTransactionId = Nothing,
                labels = labels
              }
      )

-- | Initiate an expense transfer (Regular -> External account).
--
-- Looks up the user's External account and validates the source is a Regular
-- account. Resolves cross-currency amounts using ECB rates, then delegates
-- to 'initiateTransfer'.
initiateExpense ::
  UserId ->
  AccountId ->
  Money ->
  CategoryId ->
  Set LabelId ->
  Text ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateExpense userId sourceAccountId amount categoryEntryId labels description maybeTransferDate =
  runExceptT $ do
    lift $ logInfo "Initiating expense transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    userRM <- lift (view userReadModelL)
    userData <- liftMaybeM (NotFound "User" (tshow userId)) (UserRM.getUser userRM userId)
    let externalAccId = userData.externalAccountId
    accountRM <- lift (view accountReadModelL)
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow sourceAccountId))
        (AccountRM.getAccount accountRM sourceAccountId)
    guardE
      (sourceData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow sourceAccountId))
      )
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow externalAccId))
        (AccountRM.getAccount accountRM externalAccId)
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    -- Expense: user provides amount in source (Regular) currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency True Nothing
          $ \date srcAmt tgtAmt rate ->
            InitiateTransfer
              { sourceAccountId = sourceAccountId,
                targetAccountId = externalAccId,
                sourceAmount = srcAmt,
                targetAmount = tgtAmt,
                exchangeRate = rate,
                description = description,
                initiatedBy = userId,
                at = date,
                transferType = Expense categoryEntryId,
                externalTransactionId = Nothing,
                labels = labels
              }
      )

-- | Initiate an internal transfer (Regular -> Regular account).
--
-- Validates both accounts exist and are Regular, resolves cross-currency
-- amounts, then delegates to 'initiateTransfer'.
initiateInternalTransfer ::
  UserId ->
  AccountId ->
  AccountId ->
  Money ->
  Set LabelId ->
  Text ->
  Maybe Rational ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateInternalTransfer userId sourceAccountId targetAccountId amount labels description maybeUserRate maybeTransferDate =
  runExceptT $ do
    lift $ logInfo "Initiating internal transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    accountRM <- lift (view accountReadModelL)
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow sourceAccountId))
        (AccountRM.getAccount accountRM sourceAccountId)
    guardE
      (sourceData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow sourceAccountId))
      )
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow targetAccountId))
        (AccountRM.getAccount accountRM targetAccountId)
    guardE
      (targetData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId))
      )
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    -- Internal: user provides amount in source currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency True maybeUserRate
          $ \date srcAmt tgtAmt rate ->
            InitiateTransfer
              { sourceAccountId = sourceAccountId,
                targetAccountId = targetAccountId,
                sourceAmount = srcAmt,
                targetAmount = tgtAmt,
                exchangeRate = rate,
                description = description,
                initiatedBy = userId,
                at = date,
                transferType = Transfer,
                externalTransactionId = Nothing,
                labels = labels
              }
      )

-- | Replace the label set on an existing completed transaction.
--
-- Requires Editor+ access to at least one of the transaction's accounts.
-- Validates every label id against the user's labels dictionary before
-- dispatching the command. Aggregate-level rejections
-- (non-Completed state, unknown transaction) are translated into
-- 'DomainError' for the HTTP layer.
setTransactionLabels ::
  UserId ->
  TransactionId ->
  Set LabelId ->
  AppM (Either DomainError TransactionData)
setTransactionLabels userId transactionId labels = runExceptT $ do
  lift
    $ logInfo
    $ "Setting labels on "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  _transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (validateLabels userId labels)
  let cmd =
        SetTransactionLabelsTransactionCommand
          SetTransactionLabels
            { transactionId = transactionId,
              labels = labels
            }
  ExceptT (dispatchEdit transactionId cmd)

-- | Change the category on an existing completed Income/Expense transaction.
--
-- Requires Editor+ access. Looks at the current 'TransferType' on the
-- read model to pick the dictionary (income / expense) against which the
-- new category id is validated. Internal transfers have no category and
-- are rejected.
changeTransactionCategory ::
  UserId ->
  TransactionId ->
  CategoryId ->
  AppM (Either DomainError TransactionData)
changeTransactionCategory userId transactionId newCategory = runExceptT $ do
  lift
    $ logInfo
    $ "Changing category on "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  dictId <-
    liftMaybe CannotChangeCategoryOnInternalTransfer (pickCategoryDict transaction.transferType)
  known <- ExceptT (categoryExists userId dictId newCategory)
  guardE known (CategoryNotFound (tshow (unDictionaryEntryId newCategory)))
  let cmd =
        ChangeTransactionCategoryTransactionCommand
          ChangeTransactionCategory
            { transactionId = transactionId,
              newCategory = newCategory
            }
  ExceptT (dispatchEdit transactionId cmd)

-- -----------------------------------------------------------------------------
-- Internal Helpers
-- -----------------------------------------------------------------------------

-- | Verify every id in the set exists in the user's labels dictionary.
validateLabels ::
  UserId ->
  Set LabelId ->
  AppM (Either DomainError ())
validateLabels userId labels
  | Set.null labels = pure (Right ())
  | otherwise = runExceptT $ do
      cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
      let known = dictionaryEntryIds ConfigurationService.labelsDictId cfg
          missing = Set.difference labels known
      case Set.toList missing of
        [] -> pure ()
        (eid : _) -> throwE (LabelNotFound (tshow (unDictionaryEntryId eid)))

-- | Check whether a category id is present in the given dictionary.
categoryExists ::
  UserId ->
  DictionaryId ->
  CategoryId ->
  AppM (Either DomainError Bool)
categoryExists userId dictId entryId = runExceptT $ do
  cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
  pure (Set.member entryId (dictionaryEntryIds dictId cfg))

-- | Enforce Editor+ access on one of the transaction's accounts and
-- return the matching 'TransactionData' on success. Missing
-- transactions surface as 'NotFound'.
ensureEditorAccess ::
  UserId ->
  TransactionId ->
  AppM (Either DomainError TransactionData)
ensureEditorAccess userId transactionId = runExceptT $ do
  txnRM <- lift (view transactionReadModelL)
  transaction <-
    liftMaybeM
      (NotFound "Transaction" (tshow transactionId))
      (liftIO (ReadModel.getTransaction txnRM transactionId))
  accountRM <- lift (view accountReadModelL)
  accessible <- lift (AccountRM.getAccessibleAccounts accountRM userId)
  let editorAccounts =
        Set.fromList
          [ aid
          | (aid, _, role) <- accessible,
            role == Owner || role == Editor
          ]
      allowed =
        Set.member transaction.sourceAccountId editorAccounts
          || Set.member transaction.targetAccountId editorAccounts
  guardE allowed (AccountError "User does not have edit access to this transaction")
  pure transaction

-- | Dispatch an edit command (SetTransactionLabels or
-- ChangeTransactionCategory) and return the resulting 'TransactionData'
-- read-model entry. Aggregate-level errors are translated to
-- 'DomainError' via 'translateTransactionError'.
dispatchEdit ::
  TransactionId ->
  TransactionCommand ->
  AppM (Either DomainError TransactionData)
dispatchEdit transactionId cmd = runExceptT $ do
  runTransactionCmd translateTransactionError id (unTransactionId transactionId) cmd
  (_, td) <- ExceptT (queryTransactionResult transactionId)
  pure td

-- | Translate an aggregate-local 'TransactionError' (wrapped in
-- 'CommandHandlerError') into the public 'DomainError' surface.
translateTransactionError ::
  CommandHandlerError TransactionError ->
  DomainError
translateTransactionError (CommandRejected TxCh.CannotEditLabelsInCurrentState) =
  CannotEditTransactionLabelsInCurrentState
translateTransactionError (CommandRejected TxCh.CannotChangeCategoryOnInternalTransfer) =
  CannotChangeCategoryOnInternalTransfer
translateTransactionError other =
  TransactionError (T.pack (show other))

-- | Look up the entry ids for the given dictionary in a configuration
-- snapshot, returning an empty set when the dictionary is missing.
dictionaryEntryIds :: DictionaryId -> ConfigurationData -> Set DictionaryEntryId
dictionaryEntryIds dictId cfg =
  case Map.lookup dictId cfg.dictionaries of
    Just dict -> Map.keysSet dict.entries
    Nothing -> Set.empty

-- | Pick the dictionary id matching the current transfer type. Internal
-- transfers have no category and return 'Nothing'.
pickCategoryDict :: TransferType -> Maybe DictionaryId
pickCategoryDict (Income _) = Just ConfigurationService.incomeCategoryDictId
pickCategoryDict (Expense _) = Just ConfigurationService.expenseCategoryDictId
pickCategoryDict Transfer = Nothing

-- | Resolve cross-currency amounts and initiate a transfer.
--
-- Computes the rate date from the transfer date, resolves amounts via
-- exchange rates, then delegates to 'initiateTransfer'. The transfer
-- date is passed into 'mkCmd' so it can be set as the command's @at@.
resolveAndInitiate ::
  Maybe UTCTime ->
  UTCTime ->
  Money ->
  Currency ->
  Currency ->
  Bool ->
  Maybe Rational ->
  (UTCTime -> Money -> Money -> Maybe ExchangeRate -> InitiateTransfer) ->
  AppM (Either DomainError (TransactionId, TransactionData))
resolveAndInitiate maybeTransferDate now userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate mkCmd = runExceptT $ do
  let transferDate = fromMaybe now maybeTransferDate
      rateDay = utctDay transferDate
  (srcAmt, tgtAmt, rate) <-
    ExceptT (resolveAmounts userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate rateDay)
  ExceptT (initiateTransfer (mkCmd transferDate srcAmt tgtAmt rate))

-- | Query the read model for a transaction and return the result.
queryTransactionResult ::
  TransactionId ->
  AppM (Either DomainError (TransactionId, TransactionData))
queryTransactionResult transactionId = runExceptT $ do
  readModel <- lift (view transactionReadModelL)
  transaction <-
    liftMaybeM
      (NotFound "Transaction" (tshow transactionId))
      (liftIO (ReadModel.getTransaction readModel transactionId))
  pure (transactionId, transaction)

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
--   rateDate: the date to look up exchange rates for
resolveAmounts ::
  (MonadReader env m, HasExchangeRateReadModel env, HasAppConfig env, MonadIO m) =>
  Money ->
  Currency ->
  Currency ->
  Bool ->
  Maybe Rational ->
  Day ->
  m (Either DomainError (Money, Money, Maybe ExchangeRate))
resolveAmounts userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate rateDate
  | srcCurrency == tgtCurrency =
      pure $ Right (userAmount, userAmount, Nothing)
  | otherwise = runExceptT $ do
      -- Always resolve src->tgt rate
      er <- case maybeUserRate of
        Just r ->
          liftEitherWith ExchangeRateUnavailable (mkExchangeRate srcCurrency tgtCurrency r)
        Nothing -> do
          rm <- lift (view exchangeRateReadModelL)
          cfg <- lift (view appConfigL)
          let providerName = cfg.exchangeRate.provider
          liftMaybeM
            ( ExchangeRateUnavailable
                $ "No rate for "
                <> tshow srcCurrency
                <> " -> "
                <> tshow tgtCurrency
            )
            (lookupHistoricalRate rm providerName rateDate srcCurrency tgtCurrency)
      if userAmountIsSource
        then -- User gave source amount, compute target
          let tgtAmount = convert er userAmount
           in pure (userAmount, tgtAmount, Just er)
        else -- User gave target amount, compute source (use inverse rate)
          do
            inverseEr <-
              liftEitherWith
                ExchangeRateUnavailable
                (mkExchangeRate tgtCurrency srcCurrency (1 / exchangeRateValue er))
            let srcAmount = convert inverseEr userAmount
            pure (srcAmount, userAmount, Just er)

-- Note: Uses 'tshow' from RIO for Text conversion of Show-able values.
