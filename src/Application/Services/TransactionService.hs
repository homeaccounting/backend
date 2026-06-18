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
-- The actual transfer is coordinated by the 'TransactionPostingManager' process manager
-- (saga). This service initiates the transfer by issuing the InitiateTransaction
-- command; the TransactionPostingManager then handles the debit/credit/complete/fail flow.
--
-- Usage:
--   Services are called by thin API handlers in @Web.API.TransactionAPI@.
module Application.Services.TransactionService
  ( -- * Service Functions
    initiateTransaction,
    initiateIncome,
    initiateExpense,
    initiateTransfer,
    getTransaction,
    listTransactions,
    setTransactionLabels,
    setTransactionAllocations,
    changeTransactionDescription,
    changeTransactionDate,
    amendTransaction,
    cancelTransaction,

    -- * Re-exported helpers for sibling services
    resolveAndInitiate,
    resolveAmounts,

    -- * Pure predicates (exposed for testing)
    isIdentityAmend,
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import Application.ReadModels.ExchangeRate (lookupHistoricalRate)
import Application.ReadModels.Transaction (TransactionData (..), TransactionFilter)
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.AuthorizationService (AccountAuthData (..), canModifyAccount)
import qualified Application.Services.ConfigurationService as ConfigurationService
import Application.Services.Internal
  ( getUserExternalAccountId,
    guardE,
    liftEitherWith,
    liftMaybeM,
    runTransactionCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (Day, UTCTime, getCurrentTime, utctDay)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Page (Page)
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Allocation (..),
    Allocations (..),
    Currency,
    DictionaryEntryId,
    DictionaryId,
    ExchangeRate,
    LabelId,
    Money,
    TransactionId,
    TransactionKind (..),
    TransactionType (..),
    UserId,
    convert,
    deriveTransactionKind,
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
      ( TransactionAmendmentCompletedEvent,
        TransactionAmendmentFailedEvent,
        TransactionCancellationCompletedEvent
      ),
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand
      ( AmendTransactionTransactionCommand,
        CancelTransactionTransactionCommand,
        ChangeTransactionDateTransactionCommand,
        ChangeTransactionDescriptionTransactionCommand,
        InitiateTransactionTransactionCommand,
        SetTransactionAllocationsTransactionCommand,
        SetTransactionLabelsTransactionCommand
      ),
    TransactionError,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( AmendTransaction (..),
    CancelTransaction (..),
    ChangeTransactionDate (..),
    ChangeTransactionDescription (..),
    InitiateTransaction (..),
    SetTransactionAllocations (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Events
  ( TransactionAmendmentFailed (..),
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
-- for converting the HTTP request DTO into an 'InitiateTransaction' command.
--
-- Orchestrates:
--   1. Generate new transaction ID (UUID)
--   2. Execute InitiateTransaction command via event store
--   3. Query read model for the created transaction
--
-- The TransactionPostingManager process manager will then:
--   - Debit the source account
--   - Credit the target account
--   - Complete or fail the transaction
--
-- Returns the TransactionId and TransactionData on success.
initiateTransaction ::
  InitiateTransaction ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateTransaction transferCmd = runExceptT $ do
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
    (InitiateTransactionTransactionCommand transferCmd)
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
  TransactionFilter ->
  Page ->
  AppM (Int, [(TransactionId, TransactionData)])
listTransactions userId filt page = do
  logDebug $ "Listing transactions for user " <> displayShow userId
  accountRM <- view accountReadModelL
  accessible <- AccountRM.getAccessibleAccounts accountRM userId
  let visible = Set.fromList [aid | (aid, _, _) <- accessible]
  if Set.null visible
    then do
      logDebug "User has no accessible accounts; returning empty list"
      pure (0, [])
    else do
      readModel <- view transactionReadModelL
      ReadModel.listTransactions readModel visible filt page

-- | Initiate an income transfer (External -> Regular account).
--
-- Looks up the user's External account and validates the target is a Regular
-- account. Resolves cross-currency amounts using ECB rates, then delegates
-- to 'initiateTransaction'.
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
    externalAccId <- getUserExternalAccountId userId
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
    -- Validate each allocation references a known category in its bucket.
    ExceptT (validateAllocationsAgainstDictionary userId allocations)
    -- Income: user provides amount in target (Regular) currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency False Nothing
          $ \date srcAmt tgtAmt rate -> do
            tt <- mkIncome tgtAmt allocations
            Right
              InitiateTransaction
                { sourceAccountId = externalAccId,
                  targetAccountId = targetAccountId,
                  sourceAmount = srcAmt,
                  targetAmount = tgtAmt,
                  exchangeRate = rate,
                  description = description,
                  initiatedBy = userId,
                  at = date,
                  transactionType = tt,
                  externalTransactionId = Nothing,
                  labels = labels
                }
      )

-- | Initiate an expense transfer (Regular -> External account).
--
-- Looks up the user's External account and validates the source is a Regular
-- account. Resolves cross-currency amounts using ECB rates, then delegates
-- to 'initiateTransaction'.
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
    externalAccId <- getUserExternalAccountId userId
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
    -- Validate each allocation references a known category in its bucket.
    ExceptT (validateAllocationsAgainstDictionary userId allocations)
    -- Expense: user provides amount in source (Regular) currency
    ExceptT
      ( resolveAndInitiate maybeTransferDate now amount srcCurrency tgtCurrency True Nothing
          $ \date srcAmt tgtAmt rate -> do
            tt <- mkExpense srcAmt allocations
            Right
              InitiateTransaction
                { sourceAccountId = sourceAccountId,
                  targetAccountId = externalAccId,
                  sourceAmount = srcAmt,
                  targetAmount = tgtAmt,
                  exchangeRate = rate,
                  description = description,
                  initiatedBy = userId,
                  at = date,
                  transactionType = tt,
                  externalTransactionId = Nothing,
                  labels = labels
                }
      )

-- | Initiate an internal transfer (Regular -> Regular account).
--
-- Validates both accounts exist and are Regular, resolves cross-currency
-- amounts, then delegates to 'initiateTransaction'.
initiateTransfer ::
  UserId ->
  AccountId ->
  AccountId ->
  Money ->
  Set LabelId ->
  Text ->
  Maybe Rational ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateTransfer userId sourceAccountId targetAccountId amount labels description maybeUserRate maybeTransferDate =
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
              InitiateTransaction
                { sourceAccountId = sourceAccountId,
                  targetAccountId = targetAccountId,
                  sourceAmount = srcAmt,
                  targetAmount = tgtAmt,
                  exchangeRate = rate,
                  description = description,
                  initiatedBy = userId,
                  at = date,
                  transactionType = Transfer,
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
--   * the existing 'TransactionType' is Income or Expense — Transfer and
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
  case pickCategoryDict transaction.transactionType of
    Nothing -> throwE CannotSetAllocationsOnUncategorisedTransaction
    Just _ -> pure ()
  ExceptT
    ( validateAllocationsAgainstDictionary
        userId
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
--      this implicitly preserves the transaction's 'transactionType', so
--      amendment never crosses the internal/external boundary. Use
--      delete-and-repost to recategorise across the boundary.
--   5. Identity short-circuit (spec §4.3): if the payload exactly matches
--      current canonical state, return the read-model entry unchanged.
--   6. Dispatch 'AmendTransaction'. The pure handler rejects same-account
--      and zero-amount payloads.
--   7. Read the TX stream to distinguish saga success
--      ('TransactionAmendmentCompleted') from saga failure
--      ('TransactionAmendmentFailed') and surface 'InsufficientFundsForAmendment'.
amendTransaction ::
  UserId ->
  TransactionId ->
  AmendTransaction ->
  AppM (Either DomainError TransactionData)
amendTransaction userId transactionId amendCmd = runExceptT $ do
  lift
    $ logInfo
    $ "Amending transaction "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  (newSrcAcc, newTgtAcc) <-
    ExceptT
      ( ensureEditorOnNewAccounts
          userId
          amendCmd.newSourceAccountId
          amendCmd.newTargetAccountId
      )
  let derivedKind =
        deriveTransactionKind newSrcAcc.accountType newTgtAcc.accountType
      existingTT = transaction.transactionType
  newTT <-
    ExceptT
      ( synthesiseAmendmentTransactionType
          userId
          derivedKind
          existingTT
          amendCmd
      )
  -- Resolve the leg amounts against the *actual* account currencies, mirroring
  -- the create flow (initiateIncome/Expense/Transfer). The client supplies one
  -- meaningful amount on the Regular leg; the External (or cross-currency
  -- counter-) leg is derived here via the ECB rate so each leg matches its
  -- account's currency. Without this, a cross-kind amendment into a
  -- non-base-currency account posts a leg in the wrong currency and the saga
  -- rejects it with 'CurrencyMismatch' (surfaced as InsufficientFundsForAmendment).
  -- The anchor is the Regular leg the user entered: source for Expense/Transfer,
  -- target for Income. A client-supplied rate (if any) overrides the lookup.
  let srcCurrency = moneyCurrency newSrcAcc.balance
      tgtCurrency = moneyCurrency newTgtAcc.balance
      (anchorAmount, anchorIsSource) = case derivedKind of
        IncomeKind -> (amendCmd.newTargetAmount, False)
        _ -> (amendCmd.newSourceAmount, True)
      maybeUserRate = exchangeRateValue <$> amendCmd.newExchangeRate
      rateDay = utctDay transaction.date
  (resolvedSrc, resolvedTgt, resolvedRate) <-
    ExceptT
      ( resolveAmounts
          anchorAmount
          srcCurrency
          tgtCurrency
          anchorIsSource
          maybeUserRate
          rateDay
      )
  let dispatched =
        amendCmd
          { newTransactionType = newTT,
            newSourceAmount = resolvedSrc,
            newTargetAmount = resolvedTgt,
            newExchangeRate = resolvedRate
          }
  if isIdentityAmend transaction dispatched
    then pure transaction
    else
      ExceptT
        ( dispatchAndAwaitAmendment
            transactionId
            (AmendTransactionTransactionCommand dispatched)
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
            CancelTransaction {transactionId = transactionId, by = userId}
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

-- | True when the amendment payload exactly matches the current
-- canonical state (per spec §4.3). Compared fields: accounts, amounts,
-- exchange rate, and transactionType (deep equality, including allocations).
isIdentityAmend :: TransactionData -> AmendTransaction -> Bool
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
    && td.transactionType
    == cmd.newTransactionType

-- | Synthesise the full new 'TransactionType' for an 'AmendTransaction'
-- from the derived kind and the caller-supplied 'newAllocations'.
--
-- Amount-changing amendments no longer rescale existing allocations:
-- the caller must supply explicit 'newAllocations' for categorised
-- kinds, validated and constructed via the 'mkIncome' / 'mkExpense'
-- smart constructors (which anchor sum/currency to the new amount and
-- enforce the contra rule on expense).
--
--   * 'Just allocs' + Income / Expense kind: validate categories then
--     build via 'mkIncome' / 'mkExpense' against the new amount.
--   * 'Just _' + Transfer kind: reject 'AllocationsNotAllowedForTransferKind'.
--   * 'Nothing' + Income / Expense kind: reject
--     'AllocationsRequiredForCategorisedKind'.
--   * 'Nothing' + Transfer kind: 'Transfer'.
--   * Anything + AdjustmentKind: defensive reject
--     'CannotAmendToAdjustmentKind' (unreachable via deriveTransactionKind).
synthesiseAmendmentTransactionType ::
  UserId ->
  TransactionKind ->
  TransactionType ->
  AmendTransaction ->
  AppM (Either DomainError TransactionType)
synthesiseAmendmentTransactionType userId derivedKind _existingTT cmd = runExceptT
  $ case (cmd.newAllocations, derivedKind) of
    (Just allocs, IncomeKind) -> do
      ExceptT (validateAllocationsAgainstDictionary userId allocs)
      ExceptT (pure (mkIncome cmd.newTargetAmount allocs))
    (Just allocs, ExpenseKind) -> do
      ExceptT (validateAllocationsAgainstDictionary userId allocs)
      ExceptT (pure (mkExpense cmd.newSourceAmount allocs))
    (Just _, TransferKind) -> throwE AllocationsNotAllowedForTransferKind
    (Just _, AdjustmentKind) -> throwE CannotAmendToAdjustmentKind
    (Nothing, IncomeKind) -> throwE AllocationsRequiredForCategorisedKind
    (Nothing, ExpenseKind) -> throwE AllocationsRequiredForCategorisedKind
    (Nothing, TransferKind) -> pure Transfer
    (Nothing, AdjustmentKind) -> throwE CannotAmendToAdjustmentKind

-- | Require Editor+ access on each of the two new accounts, returning the resolved data.
ensureEditorOnNewAccounts ::
  UserId ->
  AccountId ->
  AccountId ->
  AppM (Either DomainError (AccountData, AccountData))
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
  pure (src, tgt)

-- | Dispatch 'AmendTransaction' and surface the saga's outcome.
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
    step _ (TransactionAmendmentCompletedEvent _) = AmendmentSucceeded
    step _ (TransactionAmendmentFailedEvent (TransactionAmendmentFailed r)) =
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
translateTransactionError (CommandRejected TxCh.ContraIncomeNotSupported) =
  ContraIncomeNotSupported
translateTransactionError (CommandRejected TxCh.AllocationsEmpty) =
  AllocationsEmpty
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
translateTransactionError (CommandRejected TxCh.CannotAmendToAdjustmentKind) =
  CannotAmendToAdjustmentKind
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
pickCategoryDict :: TransactionType -> Maybe DictionaryId
pickCategoryDict tt = case kindOf tt of
  IncomeKind -> Just ConfigurationService.incomeCategoryDictId
  ExpenseKind -> Just ConfigurationService.expenseCategoryDictId
  TransferKind -> Nothing
  AdjustmentKind -> Nothing

-- | Verify every allocation's 'categoryId' exists in the dictionary that
-- matches its bucket: income-bucket categories against the income
-- dictionary, expense-bucket categories against the expense dictionary.
-- The handler enforces sum, currency and positivity invariants; this only
-- covers the side that depends on user configuration. Kind-agnostic — the
-- contra/empty rules live in the smart constructors and handler.
validateAllocationsAgainstDictionary ::
  UserId ->
  Allocations ->
  AppM (Either DomainError ())
validateAllocationsAgainstDictionary userId a = runExceptT $ do
  cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
  let incomeKnown = dictionaryEntryIds ConfigurationService.incomeCategoryDictId cfg
      expenseKnown = dictionaryEntryIds ConfigurationService.expenseCategoryDictId cfg
      badIncome = filter (\x -> not (Set.member x.categoryId incomeKnown)) a.incomes
      badExpense = filter (\x -> not (Set.member x.categoryId expenseKnown)) a.expenses
  case badIncome <> badExpense of
    [] -> pure ()
    (bad : _) -> throwE (CategoryNotFound (tshow (unDictionaryEntryId bad.categoryId)))

-- | Resolve cross-currency amounts and initiate a transfer.
--
-- Computes the rate date from the transfer date, resolves amounts via
-- exchange rates, then delegates to 'initiateTransaction'. The transfer
-- date is passed into 'mkCmd' so it can be set as the command's @at@.
resolveAndInitiate ::
  Maybe UTCTime ->
  UTCTime ->
  Money ->
  Currency ->
  Currency ->
  Bool ->
  Maybe Rational ->
  (UTCTime -> Money -> Money -> Maybe ExchangeRate -> Either DomainError InitiateTransaction) ->
  AppM (Either DomainError (TransactionId, TransactionData))
resolveAndInitiate maybeTransferDate now userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate mkCmd = runExceptT $ do
  let transferDate = fromMaybe now maybeTransferDate
      rateDay = utctDay transferDate
  (srcAmt, tgtAmt, rate) <-
    ExceptT (resolveAmounts userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate rateDay)
  cmd <- ExceptT (pure (mkCmd transferDate srcAmt tgtAmt rate))
  ExceptT (initiateTransaction cmd)

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
