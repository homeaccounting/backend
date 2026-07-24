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
    setTransactionContact,
    setTransactionAllocations,
    changeTransactionDescription,
    changeTransactionDate,
    amendTransaction,
    cancelTransaction,
    addTransactionRelation,
    removeTransactionRelation,
    getOutboundRelations,
    getRelations,

    -- * Re-exported helpers for sibling services
    resolveAndInitiate,
    resolveAmounts,

    -- * Pure predicates (exposed for testing)
    isIdentityAmend,

    -- * Contact validation (exposed for testing)
    validateContact,
    guardNoContactOnTransfer,
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Configuration (ConfigurationData (..), dictionaryItemIds)
import Application.ReadModels.ExchangeRate (lookupHistoricalRate)
import Application.ReadModels.Transaction (TransactionData (..), TransactionFilter)
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.AuthorizationService
  ( AccountAuthData (..),
    canModifyAccount,
    ensureCanAccessTransaction,
    ensureCanModifyTransaction,
  )
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
import Domain.Configuration.Dictionary (DictionaryKind)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Page (Page)
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Allocation (..),
    Allocations (..),
    ContactId,
    Currency,
    DictionaryEntryId,
    ExchangeRate,
    LabelId,
    Money,
    RelationKind (..),
    RelationSpec (..),
    TransactionId,
    TransactionKind (..),
    TransactionType (..),
    UserId,
    allocationsOf,
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
    unMoney,
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
      ( AddTransactionRelationTransactionCommand,
        AmendTransactionTransactionCommand,
        CancelTransactionTransactionCommand,
        ChangeTransactionDateTransactionCommand,
        ChangeTransactionDescriptionTransactionCommand,
        InitiateTransactionTransactionCommand,
        RemoveTransactionRelationTransactionCommand,
        SetTransactionAllocationsTransactionCommand,
        SetTransactionContactTransactionCommand,
        SetTransactionLabelsTransactionCommand
      ),
    TransactionError,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( AddTransactionRelation (..),
    AmendTransaction (..),
    CancelTransaction (..),
    ChangeTransactionDate (..),
    ChangeTransactionDescription (..),
    InitiateTransaction (..),
    RemoveTransactionRelation (..),
    SetTransactionAllocations (..),
    SetTransactionContact (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Events
  ( TransactionAmendmentFailed (..),
  )
import Domain.Transaction.Projection (TransactionStatus (..))
import Eventium (CommandHandlerError (..), EventStoreReader (..), StreamEvent (..), allEvents)
import Infrastructure.App
  ( AppM,
    HasAppConfig (..),
    HasDbPool (..),
    eventStoreReaderL,
    runDb,
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
  visible <- runDb (AccountRM.getAccessibleAccountIds userId)
  if Set.null visible
    then do
      logDebug "User has no accessible accounts; returning empty list"
      pure (0, [])
    else runDb (ReadModel.listTransactions visible filt page)

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
  Maybe RelationSpec ->
  Maybe ContactId ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateIncome userId targetAccountId amount allocations labels description maybeTransferDate maybeRelation maybeContactId =
  runExceptT $ do
    lift $ logInfo "Initiating income transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    ExceptT (validateContact userId maybeContactId)
    ExceptT (guardBooksClosed userId (fromMaybe now maybeTransferDate))
    externalAccId <- getUserExternalAccountId userId
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow targetAccountId))
        (runDb (AccountRM.getAccount targetAccountId))
    guardE
      (targetData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId))
      )
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow externalAccId))
        (runDb (AccountRM.getAccount externalAccId))
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    -- Validate each allocation references a known category in its bucket.
    ExceptT (validateAllocationsAgainstDictionary userId allocations)
    -- Optional relation edge: validate the target per its kind.
    rel <-
      case maybeRelation of
        Nothing -> pure Nothing
        Just spec -> ExceptT (validateRelationTarget userId spec) >> pure (Just spec)
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
                  importInfo = Nothing,
                  labels = labels,
                  contactId = maybeContactId,
                  relation = rel
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
  Maybe RelationSpec ->
  Maybe ContactId ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateExpense userId sourceAccountId amount allocations labels description maybeTransferDate maybeRelation maybeContactId =
  runExceptT $ do
    lift $ logInfo "Initiating expense transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    ExceptT (validateContact userId maybeContactId)
    ExceptT (guardBooksClosed userId (fromMaybe now maybeTransferDate))
    externalAccId <- getUserExternalAccountId userId
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow sourceAccountId))
        (runDb (AccountRM.getAccount sourceAccountId))
    guardE
      (sourceData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow sourceAccountId))
      )
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow externalAccId))
        (runDb (AccountRM.getAccount externalAccId))
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    -- Validate each allocation references a known category in its bucket.
    ExceptT (validateAllocationsAgainstDictionary userId allocations)
    -- Optional relation edge: validate the target per its kind.
    rel <-
      case maybeRelation of
        Nothing -> pure Nothing
        Just spec -> ExceptT (validateRelationTarget userId spec) >> pure (Just spec)
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
                  importInfo = Nothing,
                  labels = labels,
                  contactId = maybeContactId,
                  relation = rel
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
  Maybe RelationSpec ->
  AppM (Either DomainError (TransactionId, TransactionData))
initiateTransfer userId sourceAccountId targetAccountId amount labels description maybeUserRate maybeTransferDate maybeRelation =
  runExceptT $ do
    lift $ logInfo "Initiating internal transfer..."
    now <- liftIO getCurrentTime
    ExceptT (validateLabels userId labels)
    -- Internal transfers never carry a contact; this call has no
    -- observable effect today (the emitted contactId below is always
    -- Nothing), but it keeps the guard in the flow so a future caller
    -- that threads a contact into this path is rejected immediately
    -- rather than silently accepted.
    ExceptT (guardNoContactOnTransfer TransferKind Nothing)
    ExceptT (guardBooksClosed userId (fromMaybe now maybeTransferDate))
    sourceData <-
      liftMaybeM
        (NotFound "Account" (tshow sourceAccountId))
        (runDb (AccountRM.getAccount sourceAccountId))
    guardE
      (sourceData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow sourceAccountId))
      )
    targetData <-
      liftMaybeM
        (NotFound "Account" (tshow targetAccountId))
        (runDb (AccountRM.getAccount targetAccountId))
    guardE
      (targetData.accountType /= External)
      ( ValidationErr
          (mkValidationError "accountId" "Account must be a regular account" (tshow targetAccountId))
      )
    let srcCurrency = moneyCurrency sourceData.balance
        tgtCurrency = moneyCurrency targetData.balance
    -- Optional relation edge: validate the target per its kind.
    rel <-
      case maybeRelation of
        Nothing -> pure Nothing
        Just spec -> ExceptT (validateRelationTarget userId spec) >> pure (Just spec)
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
                  importInfo = Nothing,
                  labels = labels,
                  contactId = Nothing,
                  relation = rel
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
  _transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
  ExceptT (validateLabels userId labels)
  let cmd =
        SetTransactionLabelsTransactionCommand
          SetTransactionLabels
            { transactionId = transactionId,
              labels = labels
            }
  ExceptT (dispatchEdit transactionId cmd)

-- | Replace (or clear) the contact on an existing completed transaction.
--
-- Requires Editor+ access to at least one of the transaction's accounts.
-- Rejects the edit with 'ContactNotAllowedOnTransfer' when the existing
-- transaction is a Transfer/Adjustment, and with 'ContactNotFound' when
-- the given id is not in the user's contacts dictionary. 'Nothing' clears
-- the contact. Mirrors 'setTransactionLabels'.
setTransactionContact ::
  UserId ->
  TransactionId ->
  Maybe ContactId ->
  AppM (Either DomainError TransactionData)
setTransactionContact userId transactionId maybeContactId = runExceptT $ do
  lift
    $ logInfo
    $ "Setting contact on "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
  ExceptT (guardNoContactOnTransfer (kindOf transaction.transactionType) maybeContactId)
  ExceptT (validateContact userId maybeContactId)
  let cmd =
        SetTransactionContactTransactionCommand
          SetTransactionContact
            { transactionId = transactionId,
              contactId = maybeContactId
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
  transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
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
  _transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
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
  transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
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
  transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
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
  ExceptT (guardNoContactOnTransfer derivedKind amendCmd.contactId)
  ExceptT (validateContact userId amendCmd.contactId)
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
  transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
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
      let known = assignableEntryIds ConfigurationService.labelsDictKind cfg
          missing = Set.difference labels known
      case Set.toList missing of
        [] -> pure ()
        (eid : _) -> throwE (LabelNotFound (tshow (unDictionaryEntryId eid)))

-- | Verify the given contact id, if any, exists in the user's contacts
-- dictionary. Mirrors 'validateLabels' but for a single optional id
-- rather than a set.
validateContact ::
  UserId ->
  Maybe ContactId ->
  AppM (Either DomainError ())
validateContact _ Nothing = pure (Right ())
validateContact userId (Just cid) = runExceptT $ do
  cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
  let known = assignableEntryIds ConfigurationService.contactsDictKind cfg
  unless (Set.member cid known) $ throwE (ContactNotFound (tshow (unDictionaryEntryId cid)))

-- | Reject a contact attached to a Transfer or Adjustment transaction —
-- only Income/Expense transactions may carry a counterparty contact.
guardNoContactOnTransfer ::
  TransactionKind ->
  Maybe ContactId ->
  AppM (Either DomainError ())
guardNoContactOnTransfer kind (Just _)
  | kind `elem` [TransferKind, AdjustmentKind] = pure (Left ContactNotAllowedOnTransfer)
guardNoContactOnTransfer _ _ = pure (Right ())

-- | Validate the target ("to") endpoint of a relation edge, per kind:
--   * visible to the caller (else NotFound),
--   * Refund: target must be an Expense and not Cancelled,
--   * Merge/Split: no cancelled/kind restriction,
--   * depth-1: target must not already declare an outbound edge of the same kind.
-- Self-link is NOT checked here (callers handle it: vacuous at creation; explicit in addTransactionRelation).
validateRelationTarget :: UserId -> RelationSpec -> AppM (Either DomainError ())
validateRelationTarget userId spec = runExceptT $ do
  target <- ExceptT (ensureCanAccessTransaction userId spec.relatedTransactionId)
  case spec.relationKind of
    Refund -> do
      case target.transactionType of
        Expense _ -> pure ()
        _ -> throwE RefundTargetMustBeExpense
      when (target.status == Cancelled) $ throwE CannotRefundCancelledTransaction
    Merge -> pure ()
    Split -> pure ()
    Associated -> pure () -- generic link; endpoint kinds unrestricted
  outbound <- lift (getOutboundRelations spec.relatedTransactionId)
  when (any ((== spec.relationKind) . snd) outbound) $ throwE CannotChainRelations

-- | Outbound edges declared by a transaction: @(relatedTransactionId, kind)@.
getOutboundRelations :: TransactionId -> AppM [(TransactionId, RelationKind)]
getOutboundRelations txId = runDb (ReadModel.relationsFrom txId)

-- | Outbound + inbound relation edges of a transaction, gated on caller
-- visibility. Enforces the same access check ('ensureCanAccessTransaction') used by
-- relation validation, so a caller who cannot see the transaction gets a
-- 'NotFound'. Returns @(outbound, inbound)@ where each edge is
-- @(otherEndpointId, kind)@.
getRelations ::
  UserId ->
  TransactionId ->
  AppM (Either DomainError ([(TransactionId, RelationKind)], [(TransactionId, RelationKind)]))
getRelations userId txId = runExceptT $ do
  _ <- ExceptT (ensureCanAccessTransaction userId txId)
  outbound <- lift (getOutboundRelations txId)
  inbound <- lift (runDb (ReadModel.relationsTo txId))
  pure (outbound, inbound)

-- | Add a typed relationship edge on an existing transaction. Runs common +
-- per-kind validation, then dispatches 'AddTransactionRelation' on the "from"
-- stream. Named for the command it dispatches and to mirror
-- 'removeTransactionRelation'. Also used by the future merge/split domain
-- operations (which supply their own edge direction).
addTransactionRelation ::
  UserId ->
  TransactionId ->
  TransactionId ->
  RelationKind ->
  AppM (Either DomainError ())
addTransactionRelation userId fromId toId kind = runExceptT $ do
  when (unTransactionId fromId == unTransactionId toId)
    $ throwE CannotRelateTransactionToItself
  _ <- ExceptT (ensureCanAccessTransaction userId fromId)
  -- Reject a duplicate forward edge (or a reciprocal 'Associated' edge) before
  -- the per-kind depth-1 check, so an existing edge surfaces as
  -- 'RelationAlreadyExists' rather than 'CannotChainRelations'.
  ExceptT (validateNoExistingEdge fromId toId kind)
  -- Refund-specific source shape + refundable-amount cap guards.
  ExceptT (validateRefundSourceAndCap userId fromId toId kind)
  -- Common visibility + per-kind + depth-1 validation of the "to" endpoint.
  ExceptT (validateRelationTarget userId (RelationSpec toId kind))
  runTransactionCmd
    translateTransactionError
    id
    (unTransactionId fromId)
    (AddTransactionRelationTransactionCommand (AddTransactionRelation fromId toId kind))

-- | Remove a previously-added typed relationship between two transactions.
-- Mirror of 'addTransactionRelation'. The edge may be initiated from either
-- endpoint: the stored direction is resolved by inspecting both transactions'
-- outbound edges, and the 'RemoveTransactionRelation' command is dispatched on
-- whichever endpoint owns the "from" side.
--
-- Guards, in order:
--   * 'Merge'/'Split' lineage edges are structural provenance and are refused
--     ('CannotRemoveLineageRelation') — checked BEFORE existence so a lineage
--     edge never masquerades as 'RelationNotFound'.
--   * Caller must be able to access the acting endpoint.
--   * If neither direction carries the @(other, kind)@ edge, the removal is
--     'RelationNotFound' (also the idempotent second-removal outcome).
removeTransactionRelation ::
  UserId ->
  TransactionId ->
  TransactionId ->
  RelationKind ->
  AppM (Either DomainError ())
removeTransactionRelation userId actingId otherId kind = runExceptT $ do
  when (kind == Merge || kind == Split) $ throwE CannotRemoveLineageRelation
  _ <- ExceptT (ensureCanAccessTransaction userId actingId)
  fwd <- lift (getOutboundRelations actingId)
  rev <- lift (getOutboundRelations otherId)
  fromId <-
    if (otherId, kind) `elem` fwd
      then pure actingId
      else
        if (actingId, kind) `elem` rev
          then pure otherId
          else throwE RelationNotFound
  let toId = if fromId == actingId then otherId else actingId
  runTransactionCmd
    translateTransactionError
    id
    (unTransactionId fromId)
    (RemoveTransactionRelationTransactionCommand (RemoveTransactionRelation fromId toId kind))

-- | Total of an income's contra (expense-bucket) allocations, as a plain
-- 'Rational'. Zero for any transaction without expense-bucket allocations.
contraTotal :: TransactionData -> Rational
contraTotal td = case allocationsOf td.transactionType of
  Just a -> sum [unMoney al.amount | al <- a.expenses]
  Nothing -> 0

-- | True when the transaction is an 'Income' carrying at least one contra
-- (expense-bucket) allocation — the only shape that can refund an expense.
isIncomeWithContra :: TransactionData -> Bool
isIncomeWithContra td = case td.transactionType of
  Income _ -> not (null (maybe [] (.expenses) (allocationsOf td.transactionType)))
  _ -> False

-- | For a 'Refund' edge, verify the source ("from") is an income-with-contra
-- and that adding it does not push the total refunded amount above the
-- target expense's refundable amount. Non-Refund kinds pass through.
validateRefundSourceAndCap ::
  UserId ->
  TransactionId ->
  TransactionId ->
  RelationKind ->
  AppM (Either DomainError ())
validateRefundSourceAndCap userId fromId toId Refund = runExceptT $ do
  src <- ExceptT (ensureCanAccessTransaction userId fromId)
  unless (isIncomeWithContra src) $ throwE RefundSourceMustBeIncomeWithContra
  target <- ExceptT (ensureCanAccessTransaction userId toId)
  priorIds <- lift (runDb (ReadModel.reverseRelations toId Refund))
  priors <- lift (traverse contraOfId priorIds)
  when (contraTotal src + sum priors > unMoney target.sourceAmount)
    $ throwE RefundExceedsRefundableAmount
  where
    contraOfId tid = either (const 0) (contraTotal . snd) <$> getTransaction (unTransactionId tid)
validateRefundSourceAndCap _ _ _ _ = pure (Right ())

-- | Reject a relation edge that already exists: a duplicate forward edge
-- @from -> to@ of the same kind, or — for 'Associated' — a reciprocal edge
-- @to -> from@ (Association is undirected).
validateNoExistingEdge ::
  TransactionId ->
  TransactionId ->
  RelationKind ->
  AppM (Either DomainError ())
validateNoExistingEdge fromId toId kind = runExceptT $ do
  fwd <- lift (getOutboundRelations fromId)
  when ((toId, kind) `elem` fwd) $ throwE RelationAlreadyExists
  when (kind == Associated) $ do
    rev <- lift (getOutboundRelations toId)
    when ((fromId, Associated) `elem` rev) $ throwE RelationAlreadyExists

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
-- exchange rate, transactionType (deep equality, including allocations), and
-- contactId — an amendment that changes only the contact must NOT be
-- short-circuited as a no-op.
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
    && td.contactId
    == cmd.contactId

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
  src <-
    liftMaybeM
      (NotFound "Account" (tshow newSrc))
      (runDb (AccountRM.getAccount newSrc))
  tgt <-
    liftMaybeM
      (NotFound "Account" (tshow newTgt))
      (runDb (AccountRM.getAccount newTgt))
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
translateTransactionError (CommandRejected TxCh.RelationSelfLink) =
  CannotRelateTransactionToItself
translateTransactionError other =
  TransactionError (T.pack (show other))

-- | Assignable (item) entry ids for a dictionary — groups are excluded, since
-- only items may be attached to a transaction (ADR 002). Returns an empty set
-- when the dictionary is missing.
assignableEntryIds :: DictionaryKind -> ConfigurationData -> Set DictionaryEntryId
assignableEntryIds dictKind cfg =
  maybe Set.empty dictionaryItemIds (Map.lookup dictKind cfg.dictionaries)

-- | Pick the dictionary kind matching the current transfer type. Internal
-- transfers and adjustments have no category and return 'Nothing'.
pickCategoryDict :: TransactionType -> Maybe DictionaryKind
pickCategoryDict tt = case kindOf tt of
  IncomeKind -> Just ConfigurationService.incomeCategoryDictKind
  ExpenseKind -> Just ConfigurationService.expenseCategoryDictKind
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
  let incomeKnown = assignableEntryIds ConfigurationService.incomeCategoryDictKind cfg
      expenseKnown = assignableEntryIds ConfigurationService.expenseCategoryDictKind cfg
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
  transaction <-
    liftMaybeM
      (NotFound "Transaction" (tshow transactionId))
      (runDb (ReadModel.getTransaction transactionId))
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
  (MonadReader env m, HasDbPool env, HasAppConfig env, MonadUnliftIO m) =>
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
          cfg <- lift (view appConfigL)
          let providerName = cfg.exchangeRate.provider
          liftMaybeM
            ( ExchangeRateUnavailable
                $ "No rate for "
                <> tshow srcCurrency
                <> " -> "
                <> tshow tgtCurrency
            )
            (runDb (lookupHistoricalRate providerName rateDate srcCurrency tgtCurrency))
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
