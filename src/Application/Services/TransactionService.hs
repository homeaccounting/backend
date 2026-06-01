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
    setTransactionAllocations,
    changeTransactionDescription,
    changeTransactionDate,
    amendTransfer,
    cancelTransaction,

    -- * Re-exported helpers for sibling services
    resolveAndInitiate,
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import Application.ReadModels.ExchangeRate (lookupHistoricalRate)
import Application.ReadModels.Transaction (TransactionData (..), TransactionQuery)
import qualified Application.ReadModels.Transaction as ReadModel
import Application.ReadModels.User (UserData (..))
import Application.Services.AuthorizationService (AccountAuthData (..), canModifyAccount)
import qualified Application.Services.ConfigurationService as ConfigurationService
import Application.Services.Internal
  ( getUserData,
    guardE,
    liftEitherWith,
    liftMaybeM,
    runTransactionCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Time (Day, UTCTime, getCurrentTime, utctDay)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Allocation (..),
    Allocations,
    CategoryId,
    Currency,
    DictionaryEntryId,
    DictionaryId,
    ExchangeRate,
    LabelId,
    Money,
    TransactionId,
    TransferKind (..),
    TransferType (..),
    UserId,
    convert,
    exchangeRateValue,
    kindOf,
    mkExchangeRate,
    mkExpense,
    mkIncome,
    mkTransactionId,
    moneyCurrency,
    unDictionaryEntryId,
    unTransactionId,
  )
import Domain.Models
  ( AccountingEvent
      ( TransactionCancellationCompletedEvent,
        TransferAmendmentCompletedEvent,
        TransferAmendmentFailedEvent
      ),
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand
      ( AmendTransferTransactionCommand,
        CancelTransactionTransactionCommand,
        ChangeTransactionDateTransactionCommand,
        ChangeTransactionDescriptionTransactionCommand,
        InitiateTransferTransactionCommand,
        SetTransactionAllocationsTransactionCommand,
        SetTransactionLabelsTransactionCommand
      ),
    TransactionError,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( AmendTransfer (..),
    CancelTransaction (..),
    ChangeTransactionDate (..),
    ChangeTransactionDescription (..),
    InitiateTransfer (..),
    SetTransactionAllocations (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Events
  ( TransferAmendmentFailed (..),
  )
import Eventium (CommandHandlerError (..), EventStoreReader (..), StreamEvent (..), allEvents)
import Infrastructure.App
  ( AppM,
    HasAppConfig (..),
    HasExchangeRateReadModel (..),
    HasReadModel (..),
    eventStoreReaderL,
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
  Allocations ->
  Set LabelId ->
  Text ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateIncome userId targetAccountId amount allocations labels description maybeTransferDate =
  runExceptT $ do
    lift $ logInfo "Initiating income transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    ExceptT (guardBooksClosed userId (fromMaybe now maybeTransferDate))
    userData <- getUserData userId
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
    -- Validate each allocation references a known income category.
    ExceptT (validateAllocationsAgainstDictionary userId IncomeKind allocations)
    -- Income: user provides amount in target (Regular) currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency False Nothing
          $ \date srcAmt tgtAmt rate -> do
            tt <- mkIncome tgtAmt allocations
            Right
              InitiateTransfer
                { sourceAccountId = externalAccId,
                  targetAccountId = targetAccountId,
                  sourceAmount = srcAmt,
                  targetAmount = tgtAmt,
                  exchangeRate = rate,
                  description = description,
                  initiatedBy = userId,
                  at = date,
                  transferType = tt,
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
  Allocations ->
  Set LabelId ->
  Text ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateExpense userId sourceAccountId amount allocations labels description maybeTransferDate =
  runExceptT $ do
    lift $ logInfo "Initiating expense transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    ExceptT (guardBooksClosed userId (fromMaybe now maybeTransferDate))
    userData <- getUserData userId
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
    -- Validate each allocation references a known expense category.
    ExceptT (validateAllocationsAgainstDictionary userId ExpenseKind allocations)
    -- Expense: user provides amount in source (Regular) currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency True Nothing
          $ \date srcAmt tgtAmt rate -> do
            tt <- mkExpense srcAmt allocations
            Right
              InitiateTransfer
                { sourceAccountId = sourceAccountId,
                  targetAccountId = externalAccId,
                  sourceAmount = srcAmt,
                  targetAmount = tgtAmt,
                  exchangeRate = rate,
                  description = description,
                  initiatedBy = userId,
                  at = date,
                  transferType = tt,
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
    ExceptT (guardBooksClosed userId (fromMaybe now maybeTransferDate))
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
            Right
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

-- | Replace the allocation list on an existing completed Income/Expense
-- transaction.
--
-- Requires Editor+ access. Validates that:
--
--   * the existing 'TransferType' is Income or Expense — Transfer and
--     Adjustment have no allocations and are rejected.
--   * each allocation's category id exists in the dictionary appropriate
--     to the existing kind (income / expense).
--
-- Sum-against-total, currency, and positivity invariants are enforced
-- by the pure handler. The transaction's kind is structurally preserved
-- by this signature — only allocations are passed in.
setTransactionAllocations ::
  UserId ->
  TransactionId ->
  Allocations ->
  AppM (Either DomainError TransactionData)
setTransactionAllocations userId transactionId newAllocations = runExceptT $ do
  lift
    $ logInfo
    $ "Setting allocations on "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  -- Existing TX must be Income/Expense; pick the matching dictionary
  -- for the existing kind. Uncategorised aggregates are rejected up
  -- front so we can validate each allocation's category id against
  -- the right dictionary.
  case pickCategoryDict transaction.transferType of
    Nothing -> throwE CannotSetAllocationsOnUncategorisedTransaction
    Just _ -> pure ()
  ExceptT
    ( validateAllocationsAgainstDictionary
        userId
        (kindOf transaction.transferType)
        newAllocations
    )
  let cmd =
        SetTransactionAllocationsTransactionCommand
          SetTransactionAllocations
            { transactionId = transactionId,
              newAllocations = newAllocations
            }
  ExceptT (dispatchEdit transactionId cmd)

-- | Change the free-text description on an existing completed transaction.
--
-- Requires Editor+ access to one of the transaction's accounts. The
-- aggregate-level state guard (Completed) is enforced by the pure handler
-- and surfaced as 'CannotEditUncompletedTransaction'. The
-- description field is not subject to the books-close cutoff because
-- it carries no period-affecting information.
changeTransactionDescription ::
  UserId ->
  TransactionId ->
  Text ->
  AppM (Either DomainError TransactionData)
changeTransactionDescription userId transactionId newDescription = runExceptT $ do
  lift
    $ logInfo
    $ "Changing description on "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  _transaction <- ExceptT (ensureEditorAccess userId transactionId)
  let cmd =
        ChangeTransactionDescriptionTransactionCommand
          ChangeTransactionDescription
            { transactionId = transactionId,
              newDescription = newDescription
            }
  ExceptT (dispatchEdit transactionId cmd)

-- | Change the business date ('at') on an existing completed transaction.
--
-- Requires Editor+ access. Rejects the edit with
-- 'CannotEditClosedPeriod' when either the current TX date or the new
-- target date falls on or before the user's @booksClosedThrough@
-- cutoff. The aggregate-level state guard (Completed) is enforced by
-- the pure handler.
changeTransactionDate ::
  UserId ->
  TransactionId ->
  UTCTime ->
  AppM (Either DomainError TransactionData)
changeTransactionDate userId transactionId newAt = runExceptT $ do
  lift
    $ logInfo
    $ "Changing date on "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  ExceptT (guardBooksClosed userId newAt)
  let cmd =
        ChangeTransactionDateTransactionCommand
          ChangeTransactionDate
            { transactionId = transactionId,
              newAt = newAt
            }
  ExceptT (dispatchEdit transactionId cmd)

-- | Amend a completed transfer's posting facts.
--
-- Orchestration:
--
--   1. Load the transaction; require it exists and the caller has Editor+
--      on either of its current accounts.
--   2. Books-close gate against the transaction's current business date.
--   3. Caller has Editor+ on each of the new source / target accounts.
--   4. 'AccountType' (Regular vs External) preservation on each leg —
--      this implicitly preserves the transaction's 'transferType', so
--      amendment never crosses the internal/external boundary. Use
--      delete-and-repost to recategorise across the boundary.
--   5. Identity short-circuit (spec §4.3): if the payload exactly matches
--      current canonical state, return the read-model entry unchanged.
--   6. Dispatch 'AmendTransfer'. The pure handler rejects same-account
--      and zero-amount payloads.
--   7. Read the TX stream to distinguish saga success
--      ('TransferAmendmentCompleted') from saga failure
--      ('TransferAmendmentFailed') and surface 'InsufficientFundsForAmendment'.
amendTransfer ::
  UserId ->
  TransactionId ->
  AmendTransfer ->
  AppM (Either DomainError TransactionData)
amendTransfer userId transactionId amendCmd = runExceptT $ do
  lift
    $ logInfo
    $ "Amending transaction "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  ExceptT
    ( ensureEditorOnNewAccounts
        userId
        amendCmd.newSourceAccountId
        amendCmd.newTargetAccountId
    )
  ExceptT
    ( validateAccountTypePreserved
        transaction.sourceAccountId
        amendCmd.newSourceAccountId
        transaction.targetAccountId
        amendCmd.newTargetAccountId
    )
  -- Kind is structurally preserved by 'validateAccountTypePreserved'
  -- (the transferType is a function of source/target 'AccountType').
  -- Allocations are not on the amendment surface — when the categorised
  -- amount changes, the projection rescales existing allocations
  -- proportionally; deliberate re-splits are done via
  -- 'setTransactionAllocations'.
  if isIdentityAmend transaction amendCmd
    then pure transaction
    else
      ExceptT
        ( dispatchAndAwaitAmendment
            transactionId
            (AmendTransferTransactionCommand amendCmd)
        )

-- | Cancel a completed transaction by its 'TransactionId'.
--
-- Orchestrates:
--
--   1. Verify caller has Editor+ access to the transaction's accounts.
--   2. Books-close gate against the transaction's current business date.
--   3. Dispatch 'CancelTransaction'. The pure handler rejects requests when
--      the transaction is already cancelled, a cancellation or amendment
--      saga is already in flight.
--   4. Read the TX stream to confirm the saga terminated with
--      'TransactionCancellationCompleted'.
cancelTransaction ::
  UserId ->
  TransactionId ->
  AppM (Either DomainError TransactionData)
cancelTransaction userId transactionId = runExceptT $ do
  lift
    $ logInfo
    $ "Cancelling transaction "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  ExceptT
    ( dispatchAndAwaitCancellation
        transactionId
        ( CancelTransactionTransactionCommand
            CancelTransaction {transactionId = transactionId, cancelledBy = userId}
        )
    )

-- -----------------------------------------------------------------------------
-- Internal Helpers
-- -----------------------------------------------------------------------------

-- | Fetch the user's @booksClosedThrough@ cutoff from the configuration
-- read model. Returns 'Nothing' when the user has never closed books.
--
-- A missing user record is treated as \"no cutoff\": the gate is purely
-- a books-close concern, so it must not invent additional 'NotFound'
-- rejections for unregistered test fixtures and pre-clone-on-write
-- users only. A missing 'Configuration' record, by contrast, is a
-- genuine inconsistency and must propagate to the caller.
booksClosedThroughFor ::
  UserId ->
  AppM (Either DomainError (Maybe UTCTime))
booksClosedThroughFor userId = do
  result <- ConfigurationService.getConfigurationForUser userId
  case result of
    Right cfg -> pure (Right cfg.booksClosedThrough)
    Left (NotFound "User" _) -> pure (Right Nothing)
    Left err -> pure (Left err)

-- | Reject a creation whose business date falls in a closed period.
-- The cutoff is inclusive: dates equal to the cutoff are closed.
guardBooksClosed ::
  UserId ->
  UTCTime ->
  AppM (Either DomainError ())
guardBooksClosed userId attempted = runExceptT $ do
  cutoff <- ExceptT (booksClosedThroughFor userId)
  case cutoff of
    Just c
      | attempted <= c ->
          throwE
            CannotEditClosedPeriod
              { current = c,
                attempted = attempted
              }
    _ -> pure ()

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
  mSrc <- liftIO (AccountRM.getAccount accountRM transaction.sourceAccountId)
  mTgt <- liftIO (AccountRM.getAccount accountRM transaction.targetAccountId)
  let toAuthData acc =
        AccountAuthData
          { createdBy = acc.createdBy,
            accountType = acc.accountType,
            accessList = acc.accessList
          }
      allowed = any (canModifyAccount userId . toAuthData) $ catMaybes [mSrc, mTgt]
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

-- | True when the amendment payload exactly matches the current canonical
-- state (per spec §4.3). Compared fields: accounts, amounts, exchange
-- rate. 'transferType' is preserved by construction (see
-- 'validateAccountTypePreserved') so it is not compared here.
isIdentityAmend :: TransactionData -> AmendTransfer -> Bool
isIdentityAmend td cmd =
  td.sourceAccountId
    == cmd.newSourceAccountId
    && td.targetAccountId
    == cmd.newTargetAccountId
    && td.sourceAmount
    == cmd.newSourceAmount
    && td.targetAmount
    == cmd.newTargetAmount
    && td.exchangeRate
    == cmd.newExchangeRate

-- | Require Editor+ access on each of the two new accounts.
ensureEditorOnNewAccounts ::
  UserId ->
  AccountId ->
  AccountId ->
  AppM (Either DomainError ())
ensureEditorOnNewAccounts userId newSrc newTgt = runExceptT $ do
  accountRM <- lift (view accountReadModelL)
  src <-
    liftMaybeM
      (NotFound "Account" (tshow newSrc))
      (liftIO (AccountRM.getAccount accountRM newSrc))
  tgt <-
    liftMaybeM
      (NotFound "Account" (tshow newTgt))
      (liftIO (AccountRM.getAccount accountRM newTgt))
  let toAuthData acc =
        AccountAuthData
          { createdBy = acc.createdBy,
            accountType = acc.accountType,
            accessList = acc.accessList
          }
  guardE
    (canModifyAccount userId (toAuthData src))
    (AccountError "User does not have edit access to the new source account")
  guardE
    (canModifyAccount userId (toAuthData tgt))
    (AccountError "User does not have edit access to the new target account")

-- | Require that the amendment preserves each leg's 'AccountType'
-- (Regular vs External). The transaction's 'transferType' is a function
-- of the leg-type pair, so preserving the pair preserves the type and
-- amendment never crosses the internal/external boundary.
--
-- (Recategorising across the boundary is a delete-and-repost operation;
-- editing the category in place on a Completed Income\/Expense remains
-- available via 'changeTransactionCategory'.)
validateAccountTypePreserved ::
  AccountId ->
  AccountId ->
  AccountId ->
  AccountId ->
  AppM (Either DomainError ())
validateAccountTypePreserved oldSrc newSrc oldTgt newTgt = runExceptT $ do
  accountRM <- lift (view accountReadModelL)
  let fetch aid =
        liftMaybeM
          (NotFound "Account" (tshow aid))
          (liftIO (AccountRM.getAccount accountRM aid))
  oldS <- fetch oldSrc
  newS <- fetch newSrc
  oldT <- fetch oldTgt
  newT <- fetch newTgt
  guardE
    (sameAccountType oldS.accountType newS.accountType)
    CannotAmendAcrossAccountType
  guardE
    (sameAccountType oldT.accountType newT.accountType)
    CannotAmendAcrossAccountType
  where
    sameAccountType :: AccountType -> AccountType -> Bool
    sameAccountType (Regular _) (Regular _) = True
    sameAccountType External External = True
    sameAccountType _ _ = False

-- | Dispatch 'AmendTransfer' and surface the saga's outcome.
--
-- Eventium's in-process event bus dispatches synchronously and
-- depth-first: by the time 'runTransactionCmd' returns, every event the
-- command emitted has been delivered to every subscribed process
-- manager, and every command that PM issued has itself completed
-- (transitively). We therefore read the TX-aggregate's stream to find
-- the most-recent 'TransferAmendment*' terminator and translate it.
dispatchAndAwaitAmendment ::
  TransactionId ->
  TransactionCommand ->
  AppM (Either DomainError TransactionData)
dispatchAndAwaitAmendment txId cmd = runExceptT $ do
  runTransactionCmd translateTransactionError id (unTransactionId txId) cmd
  outcome <- ExceptT (readLastAmendmentOutcome txId)
  case outcome of
    AmendmentSucceeded -> do
      (_, td) <- ExceptT (queryTransactionResult txId)
      pure td
    AmendmentFailed reason -> throwE (InsufficientFundsForAmendment reason)
    AmendmentUnknown ->
      throwE
        ( TransactionError
            "Amendment saga did not produce a terminal event"
        )

-- | Outcome of the saga as observed on the TX stream.
data AmendmentOutcome
  = AmendmentSucceeded
  | AmendmentFailed Text
  | -- | Should not happen on a valid stream once the saga is wired.
    AmendmentUnknown

-- | Inspect the TX aggregate's stream and report the most-recent
-- amendment-terminating event.
readLastAmendmentOutcome ::
  TransactionId ->
  AppM (Either DomainError AmendmentOutcome)
readLastAmendmentOutcome txId = runExceptT $ do
  EventStoreReader readStream <- lift (view eventStoreReaderL)
  events <- liftIO (readStream (allEvents (unTransactionId txId)))
  pure (lastAmendmentOutcome (map (.payload) events))

-- | Pure helper exposed for testability via the surrounding service code.
lastAmendmentOutcome :: [AccountingEvent] -> AmendmentOutcome
lastAmendmentOutcome = foldl' step AmendmentUnknown
  where
    step _ (TransferAmendmentCompletedEvent _) = AmendmentSucceeded
    step _ (TransferAmendmentFailedEvent (TransferAmendmentFailed r)) =
      AmendmentFailed r
    step acc _ = acc

-- | Dispatch 'CancelTransaction' and surface the saga's outcome.
--
-- Mirrors 'dispatchAndAwaitAmendment'. By the time 'runTransactionCmd'
-- returns the in-process bus has delivered all downstream events; we
-- therefore inspect the TX stream immediately to find the most-recent
-- 'TransactionCancellationCompleted' terminator.
dispatchAndAwaitCancellation ::
  TransactionId ->
  TransactionCommand ->
  AppM (Either DomainError TransactionData)
dispatchAndAwaitCancellation txId cmd = runExceptT $ do
  runTransactionCmd translateTransactionError id (unTransactionId txId) cmd
  outcome <- ExceptT (readLastCancellationOutcome txId)
  case outcome of
    CancellationSucceeded -> do
      (_, td) <- ExceptT (queryTransactionResult txId)
      pure td
    CancellationUnknown ->
      throwE
        ( TransactionError
            "Cancellation saga did not produce a terminal event"
        )

-- | Outcome of the cancellation saga as observed on the TX stream.
data CancellationOutcome
  = CancellationSucceeded
  | -- | Should not happen on a valid stream once the saga is wired.
    CancellationUnknown
  deriving (Show, Eq)

-- | Inspect the TX aggregate's stream and report the most-recent
-- cancellation-terminating event.
readLastCancellationOutcome ::
  TransactionId ->
  AppM (Either DomainError CancellationOutcome)
readLastCancellationOutcome txId = runExceptT $ do
  EventStoreReader readStream <- lift (view eventStoreReaderL)
  events <- liftIO (readStream (allEvents (unTransactionId txId)))
  pure (lastCancellationOutcome (map (.payload) events))

-- | Pure helper exposed for testability via the surrounding service code.
lastCancellationOutcome :: [AccountingEvent] -> CancellationOutcome
lastCancellationOutcome = foldl' step CancellationUnknown
  where
    step _ (TransactionCancellationCompletedEvent _) = CancellationSucceeded
    step acc _ = acc

-- | Translate an aggregate-local 'TransactionError' (wrapped in
-- 'CommandHandlerError') into the public 'DomainError' surface.
translateTransactionError ::
  CommandHandlerError TransactionError ->
  DomainError
translateTransactionError (CommandRejected TxCh.CannotEditUncompletedTransaction) =
  CannotEditUncompletedTransaction
translateTransactionError (CommandRejected TxCh.CannotSetAllocationsOnUncategorisedTransaction) =
  CannotSetAllocationsOnUncategorisedTransaction
translateTransactionError (CommandRejected TxCh.CannotChangeKindOfCategorisedTransaction) =
  CannotChangeKindOfCategorisedTransaction
translateTransactionError (CommandRejected TxCh.AllocationsDoNotSumToTotal) =
  AllocationsDoNotSumToTotal
translateTransactionError (CommandRejected TxCh.AllocationAmountNotPositive) =
  AllocationAmountNotPositive
translateTransactionError (CommandRejected TxCh.AllocationCurrencyMismatch) =
  AllocationCurrencyMismatch
translateTransactionError (CommandRejected TxCh.AmendTransferToSameAccountPair) =
  CannotAmendToSameAccountPair
translateTransactionError (CommandRejected TxCh.AmendTransferToZeroAmount) =
  CannotAmendToZeroAmount
translateTransactionError (CommandRejected TxCh.NoAmendmentInProgress) =
  TransactionError "No amendment in progress"
translateTransactionError (CommandRejected TxCh.TransactionAlreadyCancelled) =
  TransactionAlreadyCancelled
translateTransactionError (CommandRejected TxCh.CancellationAlreadyInProgress) =
  CancellationAlreadyInProgress
translateTransactionError (CommandRejected TxCh.CannotCancelDuringAmendment) =
  CannotCancelDuringAmendment
translateTransactionError (CommandRejected TxCh.NoCancellationInProgress) =
  TransactionError "No cancellation in progress"
translateTransactionError (CommandRejected TxCh.CannotAmendDuringCancellation) =
  CannotAmendDuringCancellation
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
-- transfers and adjustments have no category and return 'Nothing'.
pickCategoryDict :: TransferType -> Maybe DictionaryId
pickCategoryDict tt = pickCategoryDictForKind (kindOf tt)

-- | Pick the dictionary id matching a 'TransferKind'.
pickCategoryDictForKind :: TransferKind -> Maybe DictionaryId
pickCategoryDictForKind IncomeKind = Just ConfigurationService.incomeCategoryDictId
pickCategoryDictForKind ExpenseKind = Just ConfigurationService.expenseCategoryDictId
pickCategoryDictForKind TransferKind = Nothing
pickCategoryDictForKind AdjustmentKind = Nothing

-- | Verify every allocation's 'categoryId' exists in the dictionary that
-- matches the supplied 'TransferKind'. The handler enforces sum, currency
-- and positivity invariants; this only covers the side that depends on
-- user configuration. Caller is responsible for ensuring the kind is
-- categorised (Income/Expense); other kinds short-circuit to 'Right ()'.
validateAllocationsAgainstDictionary ::
  UserId ->
  TransferKind ->
  Allocations ->
  AppM (Either DomainError ())
validateAllocationsAgainstDictionary userId kind allocs =
  case pickCategoryDictForKind kind of
    Nothing -> pure (Right ())
    Just dictId -> runExceptT $ do
      cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
      let known = dictionaryEntryIds dictId cfg
      case filter (\a -> not (Set.member a.categoryId known)) (NE.toList allocs) of
        [] -> pure ()
        (bad : _) -> throwE (CategoryNotFound (tshow (unDictionaryEntryId bad.categoryId)))

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
  (UTCTime -> Money -> Money -> Maybe ExchangeRate -> Either DomainError InitiateTransfer) ->
  AppM (Either DomainError (TransactionId, TransactionData))
resolveAndInitiate maybeTransferDate now userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate mkCmd = runExceptT $ do
  let transferDate = fromMaybe now maybeTransferDate
      rateDay = utctDay transferDate
  (srcAmt, tgtAmt, rate) <-
    ExceptT (resolveAmounts userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate rateDay)
  cmd <- ExceptT (pure (mkCmd transferDate srcAmt tgtAmt rate))
  ExceptT (initiateTransfer cmd)

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
