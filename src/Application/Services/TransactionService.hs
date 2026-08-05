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
-- (saga). This service initiates the transfer by issuing the InitiateTransactionPosting
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
    reconcileTransactionImport,
    changeTransactionDescription,
    changeTransactionDate,
    amendTransaction,
    cancelTransaction,
    mergeTransactions,
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
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (Day, NominalDiffTime, UTCTime, getCurrentTime, utctDay)
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
    BankProviderCategory,
    ContactId,
    Currency,
    DictionaryEntryId,
    ExchangeRate,
    ExternalTransactionId,
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
    mkMoney,
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
        TransactionCancellationCompletedEvent,
        TransactionMergeCompletedEvent,
        TransactionMergeFailedEvent
      ),
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand
      ( AddTransactionRelationTransactionCommand,
        ChangeTransactionAllocationsTransactionCommand,
        ChangeTransactionDateTransactionCommand,
        ChangeTransactionDescriptionTransactionCommand,
        InitiateTransactionAmendmentTransactionCommand,
        InitiateTransactionCancellationTransactionCommand,
        InitiateTransactionMergeTransactionCommand,
        InitiateTransactionPostingTransactionCommand,
        ReconcileTransactionImportTransactionCommand,
        RemoveTransactionRelationTransactionCommand,
        SetTransactionContactTransactionCommand,
        SetTransactionLabelsTransactionCommand
      ),
    TransactionError,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( AddTransactionRelation (..),
    ChangeTransactionAllocations (..),
    ChangeTransactionDate (..),
    ChangeTransactionDescription (..),
    InitiateTransactionAmendment (..),
    InitiateTransactionCancellation (..),
    InitiateTransactionMerge (..),
    InitiateTransactionPosting (..),
    ReconcileTransactionImport (..),
    RemoveTransactionRelation (..),
    SetTransactionContact (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Events
  ( TransactionAmendmentFailed (..),
    TransactionMergeFailed (..),
  )
import Domain.Transaction.Matching.Transfer (TransferDirection (..), TransferLeg (..), isTransferMatch)
import Domain.Transaction.Projection (TransactionStatus (..))
import Eventium (CommandHandlerError (..), EventStoreReader (..), StreamEvent (..), allEvents)
import Infrastructure.App
  ( AppM,
    HasAppConfig (..),
    HasDbPool (..),
    HasLoggerSet (..),
    HasRequestContext (..),
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
-- for converting the HTTP request DTO into an 'InitiateTransactionPosting' command.
--
-- Orchestrates:
--   1. Generate new transaction ID (UUID)
--   2. Execute InitiateTransactionPosting command via event store
--   3. Query read model for the created transaction
--
-- The TransactionPostingManager process manager will then:
--   - Debit the source account
--   - Credit the target account
--   - Complete or fail the transaction
--
-- Returns the TransactionId and TransactionData on success.
initiateTransaction ::
  InitiateTransactionPosting ->
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
    transactionUuid
    (InitiateTransactionPostingTransactionCommand transferCmd)
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
  visible <- runDb (AccountRM.getAccountIds userId)
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
              InitiateTransactionPosting
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
              InitiateTransactionPosting
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
              InitiateTransactionPosting
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
        ChangeTransactionAllocationsTransactionCommand
          ChangeTransactionAllocations
            { transactionId = transactionId,
              newAllocations = newAllocations
            }
  ExceptT (dispatchEdit transactionId cmd)

-- | Attach bank-import attribution (external id(s) + MCC) onto an existing
-- completed manual transaction — the reconcile leg of manual↔import dedup.
-- Mirrors 'setTransactionContact'\/'setTransactionLabels' (including the
-- Editor+ access check); issues 'ReconcileTransactionImport' via 'dispatchEdit'.
reconcileTransactionImport ::
  UserId ->
  TransactionId ->
  NonEmpty ExternalTransactionId ->
  Maybe BankProviderCategory ->
  AppM (Either DomainError TransactionData)
reconcileTransactionImport userId transactionId externalIds category = runExceptT $ do
  _transaction <- ExceptT (ensureCanModifyTransaction userId transactionId)
  let cmd =
        ReconcileTransactionImportTransactionCommand
          ReconcileTransactionImport
            { transactionId = transactionId,
              externalTransactionIds = externalIds,
              category = category
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
--   6. Dispatch 'InitiateTransactionAmendment'. The pure handler rejects same-account
--      and zero-amount payloads.
--   7. Read the TX stream to distinguish saga success
--      ('TransactionAmendmentCompleted') from saga failure
--      ('TransactionAmendmentFailed') and surface 'InsufficientFundsForAmendment'.
amendTransaction ::
  UserId ->
  TransactionId ->
  InitiateTransactionAmendment ->
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
  dispatched <- ExceptT (resolveAmendment userId transaction amendCmd)
  if isIdentityAmend transaction dispatched
    then pure transaction
    else
      ExceptT
        ( dispatchAndAwaitAmendment
            transactionId
            (InitiateTransactionAmendmentTransactionCommand dispatched)
        )

-- | Resolve an 'InitiateTransactionAmendment' payload against the read model: validate
-- Editor+ on the new accounts, derive the kind, validate/attach the contact,
-- synthesise the full 'newTransactionType', and resolve the leg amounts +
-- exchange rate against the actual account currencies (mirroring the create
-- flow). Returns the command with @newTransactionType@ / @newSourceAmount@ /
-- @newTargetAmount@ / @newExchangeRate@ overwritten with the resolved values.
--
-- Shared by 'amendTransaction' and 'mergeTransactions': the merge saga cannot
-- touch the read model or ECB rates, so all resolution must happen here, in the
-- service, before the merge command is emitted.
--
-- The anchor is the Regular leg the user entered: source for Expense/Transfer,
-- target for Income. A client-supplied rate (if any) overrides the ECB lookup.
resolveAmendment ::
  UserId ->
  TransactionData ->
  InitiateTransactionAmendment ->
  AppM (Either DomainError InitiateTransactionAmendment)
resolveAmendment userId transaction amendCmd = runExceptT $ do
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
  -- Explicit construction (not a record update): 'newTransactionType' etc. are
  -- now shared field labels with 'InitiateTransactionMerge', so an anonymous update is
  -- ambiguous under DuplicateRecordFields.
  pure
    InitiateTransactionAmendment
      { transactionId = amendCmd.transactionId,
        newSourceAccountId = amendCmd.newSourceAccountId,
        newTargetAccountId = amendCmd.newTargetAccountId,
        newSourceAmount = resolvedSrc,
        newTargetAmount = resolvedTgt,
        newExchangeRate = resolvedRate,
        newAllocations = amendCmd.newAllocations,
        newTransactionType = newTT,
        contactId = amendCmd.contactId,
        allowOverdraft = amendCmd.allowOverdraft,
        by = amendCmd.by
      }

-- | Cancel a completed transaction by its 'TransactionId'.
--
-- Orchestrates:
--
--   1. Verify caller has Editor+ access to the transaction's accounts.
--   2. Books-close gate against the transaction's current business date.
--   3. Dispatch 'InitiateTransactionCancellation'. The pure handler rejects requests when
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
        ( InitiateTransactionCancellationTransactionCommand
            InitiateTransactionCancellation {transactionId = transactionId, by = userId}
        )
    )

-- | Merge two or more Completed transactions into one survivor (the target).
--
-- See @docs/specs/2026-07-24-transaction-merge-operation-design.md@. Modelled
-- exactly like amend/cancel: the service does ALL read-model-dependent work up
-- front, then emits a single 'InitiateTransactionMerge' command whose entire
-- downstream cascade commits in ONE transaction via the
-- 'Application.ProcessManagers.TransactionMergeManager' saga. A failing leg
-- rolls back the whole merge — no partial state — so there is no
-- @MergeIncomplete@ outcome.
--
-- Orchestration (all read-only validation runs before the emit):
--
--   1. Load the target; require Editor+ and 'Completed'.
--   2. Reject a source equal to the target, and duplicate source ids.
--   3. Load every source; require Editor+ and 'Completed' (same-owner = Editor+
--      on all inputs).
--   4. Books-close gate against the target date and every source date,
--      fail-fast — runs before the kind branch so both paths below honour it
--      identically.
--   5. Branch on shape (tracker#44): a single Expense source against an
--      Income target is a transfer-merge — 'asTransferMerge' /
--      'transferMerge' reshape the pair into a single Transfer (source
--      account = the expense's account, target = the income's account,
--      keeping the income's date\/description), guarded by same-account
--      ('TransferMergeSameAccount') and matching-legs
--      ('TransferMergeLegsDoNotMatch') checks. Anything else takes the
--      same-kind path:
--        a. Pure compatibility guards: same kind (Income\/Expense only),
--           same categorised currency, same account pair, and at most one
--           distinct non-empty contact (the resolved merged contact).
--        b. Compose the combined categorised amount + allocations and fully
--           resolve the target amend payload ('resolveAmendment' —
--           currency/amount resolution + 'TransactionType' synthesis),
--           because the saga process manager cannot touch the read model or
--           ECB rates.
--   6. Emit 'InitiateTransactionMerge' with the resolved payload + ordered source
--      list; the saga amends the target, records a 'Merge' edge and cancels
--      each source in order, then completes. Await the terminal
--      'TransactionMergeCompleted' / 'TransactionMergeFailed' and return the
--      refreshed target (or surface the failure).
mergeTransactions ::
  UserId ->
  TransactionId ->
  NonEmpty TransactionId ->
  AppM (Either DomainError TransactionData)
mergeTransactions userId targetId sourceIds = runExceptT $ do
  lift
    $ logInfo
    $ "Merging into "
    <> displayShow targetId
    <> " for user "
    <> displayShow userId
  let sources = NE.toList sourceIds
  -- 1. Target: Editor+ and Completed.
  target <- ExceptT (ensureCanModifyTransaction userId targetId)
  guardE (target.status == Completed) CannotEditUncompletedTransaction
  -- 2. Self-merge / duplicate source ids.
  when (targetId `elem` sources) (throwE CannotMergeTransactionWithItself)
  when (hasDuplicateIds sources) (throwE CannotMergeTransactionWithItself)
  -- 3. Sources: Editor+ and Completed on each.
  sourceTxns <-
    traverse
      ( \sid -> do
          td <- ExceptT (ensureCanModifyTransaction userId sid)
          guardE (td.status == Completed) CannotEditUncompletedTransaction
          pure td
      )
      sources
  let allTxns = target : sourceTxns
  -- 4. Books-close gate on the target and every source date, fail-fast. Runs
  -- BEFORE the kind branch so both the transfer-merge and same-kind paths
  -- honour it identically.
  ExceptT (guardBooksClosed userId target.date)
  traverse_ (\td -> ExceptT (guardBooksClosed userId td.date)) sourceTxns
  -- 5. Branch: a single Expense source against an Income target is a
  -- transfer-merge (tracker#44); anything else takes the existing same-kind
  -- (Income+Income / Expense+Expense fan-in) path.
  case asTransferMerge target (zip sources sourceTxns) of
    Just (expenseId, expense) -> ExceptT (transferMerge userId targetId target expenseId expense)
    Nothing -> do
      -- Pure compatibility guards + resolved contact.
      ExceptT (pure (guardMergeCompatible allTxns))
      resolvedContact <- ExceptT (pure (resolveMergeContact allTxns))
      -- Compose the combined categorised amount + allocations, then fully
      -- resolve the amend payload (the saga cannot touch the read model / ECB).
      combined <- ExceptT (pure (combinedCategorisedAmount allTxns))
      let combinedAllocs = combineAllocations allTxns
          amendCmd =
            InitiateTransactionAmendment
              { transactionId = targetId,
                newSourceAccountId = target.sourceAccountId,
                newTargetAccountId = target.targetAccountId,
                -- The categorised leg carries the combined amount; the other leg is
                -- re-resolved by 'resolveAmendment' against the account currency.
                newSourceAmount = combined,
                newTargetAmount = combined,
                newExchangeRate = target.exchangeRate,
                newAllocations = Just combinedAllocs,
                -- Placeholder; 'resolveAmendment' synthesises the real kind from the
                -- (unchanged) account pair.
                newTransactionType = Transfer,
                contactId = resolvedContact,
                allowOverdraft = False,
                by = userId
              }
      resolved <- ExceptT (resolveAmendment userId target amendCmd)
      -- Emit the single atomic-merge command; the saga runs the whole cascade
      -- synchronously in one transaction and returns the refreshed target.
      let mergeCmd =
            InitiateTransactionMerge
              { newSourceAccountId = resolved.newSourceAccountId,
                newTargetAccountId = resolved.newTargetAccountId,
                newSourceAmount = resolved.newSourceAmount,
                newTargetAmount = resolved.newTargetAmount,
                newExchangeRate = resolved.newExchangeRate,
                newAllocations = resolved.newAllocations,
                newTransactionType = resolved.newTransactionType,
                contactId = resolved.contactId,
                sourceTransactionIds = sources,
                by = userId
              }
      ExceptT
        ( dispatchAndAwaitMerge
            targetId
            (InitiateTransactionMergeTransactionCommand mergeCmd)
        )

-- | True when the source id list contains a duplicate.
hasDuplicateIds :: [TransactionId] -> Bool
hasDuplicateIds ids =
  Set.size (Set.fromList (map unTransactionId ids)) /= length ids

-- | All elements of a list are equal (vacuously true for the empty list).
allSame :: (Eq a) => [a] -> Bool
allSame [] = True
allSame (x : xs) = all (== x) xs

-- | True for the categorisable kinds (Income \/ Expense) — the only kinds a
-- merge accepts.
isMergeableKind :: TransactionKind -> Bool
isMergeableKind IncomeKind = True
isMergeableKind ExpenseKind = True
isMergeableKind _ = False

-- | The categorised-side amount of a transaction: the target leg for an
-- Income, the source leg for an Expense. Defined only for the mergeable kinds;
-- callers guard the kind first.
categorisedMoneyOf :: TransactionData -> Money
categorisedMoneyOf td = case kindOf td.transactionType of
  IncomeKind -> td.targetAmount
  _ -> td.sourceAmount

-- | Pure compatibility guards over target + sources, in the order that keeps
-- every arm reachable (kind before currency before account: two inputs of
-- different currency necessarily sit on different accounts, so currency is
-- checked first to surface the more specific error).
guardMergeCompatible :: [TransactionData] -> Either DomainError ()
guardMergeCompatible txns = do
  let kinds = map (kindOf . (.transactionType)) txns
  unless (allSame kinds && all isMergeableKind kinds) (Left CannotMergeIncompatibleKinds)
  let currencies = map (moneyCurrency . categorisedMoneyOf) txns
  unless (allSame currencies) (Left CannotMergeDifferentCurrencies)
  let pairs = map (\td -> (td.sourceAccountId, td.targetAccountId)) txns
  unless (allSame pairs) (Left CannotMergeDifferentAccounts)

-- | Resolve the merged contact: at most one distinct non-empty contact is
-- allowed (carried onto the survivor); two or more is a conflict.
resolveMergeContact :: [TransactionData] -> Either DomainError (Maybe ContactId)
resolveMergeContact txns =
  case Set.toList (Set.fromList (mapMaybe (.contactId) txns)) of
    [] -> Right Nothing
    [c] -> Right (Just c)
    _ -> Left CannotMergeConflictingContacts

-- | Sum of the categorised-side amounts across all inputs, in their shared
-- currency. Guarded to be non-empty (the target is always present) and
-- single-currency (by 'guardMergeCompatible') before this is called.
combinedCategorisedAmount :: [TransactionData] -> Either DomainError Money
combinedCategorisedAmount [] =
  Left (TransactionError "merge: no transactions to combine")
combinedCategorisedAmount txns@(t0 : _) =
  let cur = moneyCurrency (categorisedMoneyOf t0)
      total = sum (map (unMoney . categorisedMoneyOf) txns)
   in either (Left . TransactionError) Right (mkMoney cur total)

-- | Concatenate the income and expense allocation buckets across all inputs.
-- The per-slice amounts are unchanged, so they still sum to the combined total
-- and pass 'mkIncome' \/ 'mkExpense' validation inside the amendment.
combineAllocations :: [TransactionData] -> Allocations
combineAllocations txns =
  Allocations
    { incomes = concatMap (bucket (.incomes)) txns,
      expenses = concatMap (bucket (.expenses)) txns
    }
  where
    bucket sel td = maybe [] sel (allocationsOf td.transactionType)

-- | Time tolerance for a manual income/expense → transfer merge. More relaxed
-- than import's 5-minute pairing window: a manually-reconciled transfer may have
-- legs dated further apart (settlement lag, hand-entered dates). Tunable.
mergeTransferWindow :: NominalDiffTime
mergeTransferWindow = 24 * 60 * 60 -- 24h

-- | When the target is an Income and its single source is an Expense, this is a
-- transfer-merge; returns that expense's id + read-model row. Otherwise
-- 'Nothing' (same-kind path). Read-model rows don't carry their own id
-- (it's the read model's key, not a stored field), so the id is paired in
-- alongside each row by the caller.
asTransferMerge :: TransactionData -> [(TransactionId, TransactionData)] -> Maybe (TransactionId, TransactionData)
asTransferMerge target [(sid, src)]
  | kindOf target.transactionType == IncomeKind,
    kindOf src.transactionType == ExpenseKind =
      Just (sid, src)
asTransferMerge _ _ = Nothing

-- | Project a leg for 'isTransferMatch'.
transferLegOf :: TransferDirection -> Money -> UTCTime -> TransferLeg Currency
transferLegOf dir m t =
  TransferLeg {direction = dir, magnitude = unMoney m, currency = moneyCurrency m, time = t}

-- | Reshape an Income + Expense into a single Transfer via the merge saga.
--
-- The transfer moves money FROM the expense's (Regular) account TO the
-- income's (Regular) account, keeping the income's date/description as the
-- survivor. Reuses 'resolveAmendment' for kind derivation / amount
-- resolution and 'dispatchAndAwaitMerge' for the same atomic saga cascade as
-- the same-kind path.
transferMerge ::
  UserId ->
  TransactionId ->
  TransactionData ->
  TransactionId ->
  TransactionData ->
  AppM (Either DomainError TransactionData)
transferMerge userId incomeId income expenseId expense = runExceptT $ do
  let incomeAcc = income.targetAccountId
      expenseAcc = expense.sourceAccountId
      incomeLeg = transferLegOf CreditLeg income.targetAmount income.date
      expenseLeg = transferLegOf DebitLeg expense.sourceAmount expense.date
  guardE (incomeAcc /= expenseAcc) TransferMergeSameAccount
  guardE (isTransferMatch mergeTransferWindow incomeLeg expenseLeg) TransferMergeLegsDoNotMatch
  let amendCmd =
        InitiateTransactionAmendment
          { transactionId = incomeId,
            newSourceAccountId = expenseAcc,
            newTargetAccountId = incomeAcc,
            newSourceAmount = income.targetAmount,
            newTargetAmount = income.targetAmount,
            newExchangeRate = Nothing,
            newAllocations = Nothing,
            newTransactionType = Transfer,
            contactId = Nothing,
            allowOverdraft = False, -- discarded; the saga's amendEffect sets True
            by = userId
          }
  resolved <- ExceptT (resolveAmendment userId income amendCmd)
  let mergeCmd =
        InitiateTransactionMerge
          { newSourceAccountId = resolved.newSourceAccountId,
            newTargetAccountId = resolved.newTargetAccountId,
            newSourceAmount = resolved.newSourceAmount,
            newTargetAmount = resolved.newTargetAmount,
            newExchangeRate = resolved.newExchangeRate,
            newAllocations = resolved.newAllocations,
            newTransactionType = resolved.newTransactionType,
            contactId = resolved.contactId,
            sourceTransactionIds = [expenseId],
            by = userId
          }
  ExceptT (dispatchAndAwaitMerge incomeId (InitiateTransactionMergeTransactionCommand mergeCmd))

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
  runTransactionCmd translateTransactionError (unTransactionId transactionId) cmd
  (_, td) <- ExceptT (queryTransactionResult transactionId)
  pure td

-- | True when the amendment payload exactly matches the current
-- canonical state (per spec §4.3). Compared fields: accounts, amounts,
-- exchange rate, transactionType (deep equality, including allocations), and
-- contactId — an amendment that changes only the contact must NOT be
-- short-circuited as a no-op.
isIdentityAmend :: TransactionData -> InitiateTransactionAmendment -> Bool
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

-- | Synthesise the full new 'TransactionType' for an 'InitiateTransactionAmendment'
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
  InitiateTransactionAmendment ->
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

-- | Dispatch 'InitiateTransactionAmendment' and surface the saga's outcome.
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
  runTransactionCmd translateTransactionError (unTransactionId txId) cmd
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

-- | Dispatch 'InitiateTransactionCancellation' and surface the saga's outcome.
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
  runTransactionCmd translateTransactionError (unTransactionId txId) cmd
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

-- | Dispatch 'InitiateTransactionMerge' and surface the saga's outcome.
--
-- Mirrors 'dispatchAndAwaitAmendment'. Eventium dispatches synchronously and
-- depth-first, so by the time 'runTransactionCmd' returns the whole merge
-- cascade (target amend + per-source edge/cancel + completion, or a failure)
-- has committed in the one write transaction. We then read the target stream
-- for the terminal 'TransactionMergeCompleted' / 'TransactionMergeFailed'.
--
-- A failure carries the amend rejection reason and is surfaced as
-- 'InsufficientFundsForAmendment' (the only realistic merge failure is the
-- target amend's insufficient-funds debit) — a 409, matching a standalone
-- amend failure. Because the amend is sequenced first, a failure leaves the
-- pre-merge ledger and read model fully intact.
dispatchAndAwaitMerge ::
  TransactionId ->
  TransactionCommand ->
  AppM (Either DomainError TransactionData)
dispatchAndAwaitMerge txId cmd = runExceptT $ do
  runTransactionCmd translateTransactionError (unTransactionId txId) cmd
  outcome <- ExceptT (readLastMergeOutcome txId)
  case outcome of
    MergeSucceeded -> do
      (_, td) <- ExceptT (queryTransactionResult txId)
      pure td
    MergeFailed reason -> throwE (InsufficientFundsForAmendment reason)
    MergeUnknown ->
      throwE
        ( TransactionError
            "Merge saga did not produce a terminal event"
        )

-- | Outcome of the merge saga as observed on the target's stream.
data MergeOutcome
  = MergeSucceeded
  | MergeFailed Text
  | -- | Should not happen on a valid stream once the saga is wired.
    MergeUnknown
  deriving (Show, Eq)

-- | Inspect the target aggregate's stream and report the most-recent
-- merge-terminating event.
readLastMergeOutcome ::
  TransactionId ->
  AppM (Either DomainError MergeOutcome)
readLastMergeOutcome txId = runExceptT $ do
  EventStoreReader readStream <- lift (view eventStoreReaderL)
  events <- liftIO (readStream (allEvents (unTransactionId txId)))
  pure (lastMergeOutcome (map (.payload) events))

-- | Pure helper exposed for testability via the surrounding service code.
lastMergeOutcome :: [AccountingEvent] -> MergeOutcome
lastMergeOutcome = foldl' step MergeUnknown
  where
    step _ (TransactionMergeCompletedEvent _) = MergeSucceeded
    step _ (TransactionMergeFailedEvent (TransactionMergeFailed r)) =
      MergeFailed r
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
translateTransactionError (CommandRejected TxCh.MergeAlreadyInProgress) =
  TransactionError "A merge is already in progress"
translateTransactionError (CommandRejected TxCh.NoMergeInProgress) =
  TransactionError "No merge in progress"
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
  (UTCTime -> Money -> Money -> Maybe ExchangeRate -> Either DomainError InitiateTransactionPosting) ->
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
  (MonadReader env m, HasDbPool env, HasAppConfig env, HasRequestContext env, HasLoggerSet env, MonadUnliftIO m) =>
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
