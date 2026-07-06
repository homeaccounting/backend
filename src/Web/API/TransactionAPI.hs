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
--   POST   /api/transactions/income            - Record an income transaction
--   POST   /api/transactions/expense           - Record an expense transaction
--   POST   /api/transactions/transfer          - Initiate an internal transfer
--   PUT    /api/transactions/:id/labels        - Replace label set
--   PATCH  /api/transactions/:id/allocations   - Replace allocations
--   PUT    /api/transactions/:id/description   - Replace description
--   PUT    /api/transactions/:id/date          - Replace business date
--   PUT    /api/transactions/:id/amendment     - Amend posting facts (saga)
--   GET    /api/transactions/:id/history       - Audit history
--   GET    /api/transactions/:id               - Get transaction status
--   DELETE /api/transactions/:id               - Cancel a transaction
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
    listTransactionsHandler,
    getTransactionHandler,
    setLabelsHandler,
    setAllocationsHandler,
    changeDescriptionHandler,
    changeDateHandler,
    amendTransactionHandler,
    transactionHistoryHandler,
    cancelTransactionHandler,
    relationsHandler,
  )
where

import Application.ReadModels.Transaction (mkTransactionFilter)
import Application.Services.TransactionHistoryService (TransactionHistory)
import qualified Application.Services.TransactionHistoryService as TransactionHistoryService
import qualified Application.Services.TransactionService as TransactionService
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Page (Page (..), mkPage)
import Domain.Core.Range (mkRange)
import Domain.Core.Types (Allocation (..), Allocations, Currency, Money (..), RelationSpec (..), TransactionType (..), allAllocations, mkAccountId, mkAllocation, mkAllocations, mkDictionaryEntryId, mkTransactionId, parseCurrency, parseRelationKind, renderRelationKind, unTransactionId, unsafeDictionaryEntryId)
import Domain.Transaction.Commands (AmendTransaction (..))
import Domain.Transaction.Projection (StatusKind)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Query (CommaSep (..))
import Web.Types
  ( AllocationsRequest (..),
    AmendTransactionRequest (..),
    CategoryAmount (..),
    ChangeTransactionDateRequest (..),
    ChangeTransactionDescriptionRequest (..),
    ExpenseRequest (..),
    IncomeRequest (..),
    SetTransactionAllocationsRequest (..),
    SetTransactionLabelsRequest (..),
    TransactionListResponse (..),
    TransactionRelation (..),
    TransactionRelationsResponse (..),
    TransactionResponse,
    TransferRequest (..),
    fromTransactionData,
    parseLabelIds,
    parseOptionalExchangeRate,
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
      :> ReqBody '[JSON] TransferRequest
      :> Post '[JSON] TransactionResponse
    -- GET /api/transactions - List transactions visible to the caller.
    -- Filters: accountId, dateFrom/dateTo (inclusive), status (CSV IN),
    -- label (CSV IN, set overlap). Pagination: limit (default 50, max 200),
    -- offset (default 0). All optional. See
    -- docs/specs/2026-06-09-transaction-query-language-design.md.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> QueryParam "accountId" UUID
      :> QueryParam "dateFrom" UTCTime
      :> QueryParam "dateTo" UTCTime
      :> QueryParam "status" (CommaSep StatusKind)
      :> QueryParam "label" (CommaSep UUID)
      :> QueryParam "limit" Int
      :> QueryParam "offset" Int
      :> Get '[JSON] TransactionListResponse
    -- PUT /api/transactions/:id/labels - Replace the label set on a Completed transaction.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "labels"
      :> ReqBody '[JSON] SetTransactionLabelsRequest
      :> Put '[JSON] TransactionResponse
    -- PATCH /api/transactions/:id/allocations - Replace the allocations on a Completed Income/Expense.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "allocations"
      :> ReqBody '[JSON] SetTransactionAllocationsRequest
      :> Patch '[JSON] TransactionResponse
    -- PUT /api/transactions/:id/description - Replace the description on a Completed transaction.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "description"
      :> ReqBody '[JSON] ChangeTransactionDescriptionRequest
      :> Put '[JSON] TransactionResponse
    -- PUT /api/transactions/:id/date - Replace the business date on a Completed transaction.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "date"
      :> ReqBody '[JSON] ChangeTransactionDateRequest
      :> Put '[JSON] TransactionResponse
    -- PUT /api/transactions/:id/amendment - Amend posting facts on a Completed transaction.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "amendment"
      :> ReqBody '[JSON] AmendTransactionRequest
      :> Put '[JSON] TransactionResponse
    -- GET /api/transactions/:id/history - Audit history (TX-aggregate events).
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "history"
      :> Get '[JSON] TransactionHistory
    -- GET /api/transactions/:id/relations - Outbound + inbound typed relations.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "relations"
      :> Get '[JSON] TransactionRelationsResponse
    -- GET /api/transactions/:id - Get transaction status (requires auth)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> Get '[JSON] TransactionResponse
    -- DELETE /api/transactions/:id - Cancel a transaction
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> DeleteNoContent

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
    :<|> listTransactionsHandler
    :<|> setLabelsHandler
    :<|> setAllocationsHandler
    :<|> changeDescriptionHandler
    :<|> changeDateHandler
    :<|> amendTransactionHandler
    :<|> transactionHistoryHandler
    :<|> relationsHandler
    :<|> getTransactionHandler
    :<|> cancelTransactionHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Map the two request buckets into a validated domain 'Allocations' plus
-- the derived categorised total (sum of all slices in the request currency).
buildAllocations :: Currency -> AllocationsRequest -> Either DomainError (Money, Allocations)
buildAllocations cur req = do
  incs <- traverse (toAlloc cur) req.incomes
  exps <- traverse (toAlloc cur) req.expenses
  allocs <- mkAllocations incs exps
  let total = Money (sum [a.amount.amount | a <- allAllocations allocs]) cur
  pure (total, allocs)
  where
    toAlloc c ca = mkAllocation (unsafeDictionaryEntryId ca.category) (toDomainMoney c ca.amount) ca.comment

-- | Handler for POST /api/transactions/income - Record an income transaction.
incomeHandler :: AuthenticatedUser -> IncomeRequest -> AppM TransactionResponse
incomeHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  accountId <- validateField "accountId" $ mkAccountId request.accountId
  cur <- validateField "currency" $ parseCurrency request.currency
  (total, allocations) <- either throwDomainError pure (buildAllocations cur request.allocations)
  labelSet <- validateField "labels" $ parseLabelIds request.labels
  mRelation <- traverse parseRelation request.relation
  result <- TransactionService.initiateIncome userId accountId total allocations labelSet request.description request.date mRelation
  case result of
    Right (txId, transaction) -> return $ fromTransactionData txId transaction
    Left err -> throwDomainError err

-- | Parse a 'TransactionRelation' DTO into a domain 'RelationSpec': the
-- referenced transaction id and the relation kind wire token. The kind is
-- validated against 'parseRelationKind'; the service enforces the per-kind
-- target rules.
parseRelation :: TransactionRelation -> AppM RelationSpec
parseRelation req = do
  tid <- validateField "relation.relatedTransactionId" (mkTransactionId req.relatedTransactionId)
  kind <-
    validateField "relation.relationKind"
      $ maybe (Left ("Unknown relation kind: " <> req.relationKind)) Right (parseRelationKind req.relationKind)
  pure (RelationSpec {relatedTransactionId = tid, relationKind = kind})

-- | Handler for POST /api/transactions/expense - Record an expense transaction.
expenseHandler :: AuthenticatedUser -> ExpenseRequest -> AppM TransactionResponse
expenseHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  accountId <- validateField "accountId" $ mkAccountId request.accountId
  cur <- validateField "currency" $ parseCurrency request.currency
  (total, allocations) <- either throwDomainError pure (buildAllocations cur request.allocations)
  labelSet <- validateField "labels" $ parseLabelIds request.labels
  -- The public expense endpoint does not expose relation edges (yet).
  result <- TransactionService.initiateExpense userId accountId total allocations labelSet request.description request.date Nothing
  case result of
    Right (txId, transaction) -> return $ fromTransactionData txId transaction
    Left err -> throwDomainError err

-- | Handler for POST /api/transactions/transfer - Initiate an internal transfer.
transferHandler :: AuthenticatedUser -> TransferRequest -> AppM TransactionResponse
transferHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  fromAccId <- validateField "sourceAccountId" $ mkAccountId request.sourceAccountId
  toAccId <- validateField "targetAccountId" $ mkAccountId request.targetAccountId
  cur <- validateField "currency" $ parseCurrency request.currency
  let money = toDomainMoney cur request.amount
  labelSet <- validateField "labels" $ parseLabelIds request.labels
  let maybeRate = fmap toRational request.exchangeRate
  result <- TransactionService.initiateTransfer userId fromAccId toAccId money labelSet request.description maybeRate request.date Nothing
  case result of
    Right (txId, transaction) -> return $ fromTransactionData txId transaction
    Left err -> throwDomainError err

-- | Handler for PUT /api/transactions/:id/labels — replace the label
-- set on an existing Completed transaction.
setLabelsHandler ::
  AuthenticatedUser ->
  UUID ->
  SetTransactionLabelsRequest ->
  AppM TransactionResponse
setLabelsHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  labelSet <- validateField "labels" $ parseLabelIds (Just req.labels)
  result <- TransactionService.setTransactionLabels user.userId transactionId labelSet
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

-- | Handler for PATCH /api/transactions/:id/allocations — replace the
-- allocations on an existing Completed Income\/Expense transaction.
--
-- The body carries only the new allocation list; the transaction's
-- kind is structurally preserved. The service layer enforces
-- per-category dictionary membership; the pure handler enforces
-- sum-against-total, currency, and positivity invariants.
setAllocationsHandler ::
  AuthenticatedUser ->
  UUID ->
  SetTransactionAllocationsRequest ->
  AppM TransactionResponse
setAllocationsHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  result <- TransactionService.setTransactionAllocations user.userId transactionId req.newAllocations
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

-- | Handler for PUT /api/transactions/:id/description — replace the
-- description on an existing Completed transaction.
changeDescriptionHandler ::
  AuthenticatedUser ->
  UUID ->
  ChangeTransactionDescriptionRequest ->
  AppM TransactionResponse
changeDescriptionHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  result <- TransactionService.changeTransactionDescription user.userId transactionId req.description
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

-- | Handler for PUT /api/transactions/:id/date — replace the business
-- date on an existing Completed transaction.
changeDateHandler ::
  AuthenticatedUser ->
  UUID ->
  ChangeTransactionDateRequest ->
  AppM TransactionResponse
changeDateHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  result <- TransactionService.changeTransactionDate user.userId transactionId req.at
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

-- | Handler for PUT /api/transactions/:id/amendment — replace the
-- posting facts on a Completed transaction. Synchronous: returns the
-- post-amendment 'TransactionResponse' once the saga has resolved
-- ('TransactionAmendmentCompleted') or surfaces
-- 'InsufficientFundsForAmendment' on saga failure.
--
-- Cross-kind amendment is supported via 'AmendTransactionRequest.newAllocations';
-- see 'AmendTransactionRequest' for field semantics.
amendTransactionHandler ::
  AuthenticatedUser ->
  UUID ->
  AmendTransactionRequest ->
  AppM TransactionResponse
amendTransactionHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  newSource <- validateField "sourceAccountId" $ mkAccountId req.sourceAccountId
  newTarget <- validateField "targetAccountId" $ mkAccountId req.targetAccountId
  srcCur <- validateField "sourceCurrency" $ parseCurrency req.sourceCurrency
  tgtCur <- validateField "targetCurrency" $ parseCurrency req.targetCurrency
  let srcMoney = toDomainMoney srcCur req.sourceAmount
      tgtMoney = toDomainMoney tgtCur req.targetAmount
  maybeRate <-
    validateField "exchangeRate" $ parseOptionalExchangeRate srcCur tgtCur req.exchangeRate
  let cmd =
        AmendTransaction
          { transactionId = transactionId,
            newSourceAccountId = newSource,
            newTargetAccountId = newTarget,
            newSourceAmount = srcMoney,
            newTargetAmount = tgtMoney,
            newExchangeRate = maybeRate,
            newAllocations = req.newAllocations,
            -- Placeholder; overwritten by synthesiseAmendmentTransactionType
            -- in TransactionService.amendTransaction before dispatch. The
            -- DTO does not expose this field; it's service-internal.
            newTransactionType = Transfer,
            by = user.userId
          }
  result <- TransactionService.amendTransaction user.userId transactionId cmd
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

-- | Handler for GET /api/transactions/:id/history — audit history.
transactionHistoryHandler ::
  AuthenticatedUser ->
  UUID ->
  AppM TransactionHistory
transactionHistoryHandler user rawId = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  result <- TransactionHistoryService.getTransactionHistory user.userId transactionId
  case result of
    Right (Just history) -> pure history
    Right Nothing ->
      throwDomainError (NotFound "Transaction" (tshow transactionId))
    Left err -> throwDomainError err

-- | Handler for GET /api/transactions/:id/relations — outbound + inbound
-- typed relationship edges, gated on caller visibility (404 if not visible or
-- absent, via the service's 'ensureCanAccessTransaction').
relationsHandler ::
  AuthenticatedUser ->
  UUID ->
  AppM TransactionRelationsResponse
relationsHandler user rawId = do
  transactionId <- validateField "id" (mkTransactionId rawId)
  result <- TransactionService.getRelations user.userId transactionId
  case result of
    Right (outbound, inbound) ->
      pure
        TransactionRelationsResponse
          { -- outbound: subject -> rel (the subject id is the @:id@ path param)
            outbound =
              [ TransactionRelation (unTransactionId rel) (renderRelationKind k)
              | (rel, k) <- outbound
              ],
            -- inbound: frm -> subject; the element names the other end (frm)
            inbound =
              [ TransactionRelation (unTransactionId frm) (renderRelationKind k)
              | (frm, k) <- inbound
              ]
          }
    Left err -> throwDomainError err

-- | Handler for GET /api/transactions - list transactions visible to the caller.
--
-- Optional query params (absent = no constraint on that field):
--   - accountId:        restrict to transactions touching this account
--   - dateFrom/dateTo:  inclusive bounds on business timestamp (UTCTime, ISO-8601)
--   - status:           comma-separated StatusKind set (IN), e.g. failed,cancelled
--   - label:            comma-separated label UUIDs (set overlap, "any of")
--   - limit/offset:     pagination (limit default 50, max 200; offset default 0)
--
-- dateFrom > dateTo (400 via mkRange) and out-of-range limit/offset (400 via
-- mkPage) are validation errors. An accountId the caller cannot see produces a
-- 200 empty list (hide existence). totalCount counts all matches before paging.
--
-- See docs/specs/2026-06-09-transaction-query-language-design.md.
listTransactionsHandler ::
  AuthenticatedUser ->
  Maybe UUID ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe (CommaSep StatusKind) ->
  Maybe (CommaSep UUID) ->
  Maybe Int ->
  Maybe Int ->
  AppM TransactionListResponse
listTransactionsHandler user mAccount mFrom mTo mStatus mLabel mLimit mOffset = do
  let userId = user.userId
  accountId <- traverse (validateField "accountId" . mkAccountId) mAccount
  dateRange <- validateField "date" $ mkRange mFrom mTo
  labels <-
    traverse (traverse (validateField "label" . mkDictionaryEntryId) . (.values)) mLabel
  page <- validateField "page" $ mkPage mLimit mOffset
  let statuses = (.values) <$> mStatus
      filt = mkTransactionFilter accountId dateRange statuses labels
  (total, results) <- TransactionService.listTransactions userId filt page
  let responses = map (uncurry fromTransactionData) results
  pure $ TransactionListResponse responses total page.limit page.offset

-- | Handler for GET /api/transactions/:id - Get transaction status.
getTransactionHandler :: AuthenticatedUser -> UUID -> AppM TransactionResponse
getTransactionHandler _user transactionUuid = do
  result <- TransactionService.getTransaction transactionUuid
  case result of
    Right (txId, transaction) -> return $ fromTransactionData txId transaction
    Left err -> throwDomainError err

-- | Handler for DELETE /api/transactions/:id - Cancel a transaction.
--
-- Returns 204 No Content on success.
-- Returns 409 Conflict when:
--   - the transaction is already cancelled ('TransactionAlreadyCancelled')
--   - a cancellation is already in progress ('CancellationAlreadyInProgress')
--   - an amendment saga is running ('CannotCancelDuringAmendment')
cancelTransactionHandler ::
  AuthenticatedUser ->
  UUID ->
  AppM NoContent
cancelTransactionHandler user rawId = do
  transactionId <- validateField "id" (mkTransactionId rawId)
  result <- TransactionService.cancelTransaction user.userId transactionId
  case result of
    Right _ -> pure NoContent
    Left err -> throwDomainError err
