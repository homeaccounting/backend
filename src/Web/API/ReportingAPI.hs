{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.ReportingAPI
-- Description : REST API endpoints for reporting/analytics queries
--
-- This module defines the Servant API for read-only reporting endpoints.
-- Handlers are thin HTTP adapters that delegate to 'ReportingService' for
-- aggregation and use 'ErrorMapping' for error responses.
--
-- API Endpoints:
--
--   GET /api/reports/spending-by-category  - Expense totals grouped by category
--   GET /api/reports/income-vs-expense     - Income, expense, and net (base ccy)
--   GET /api/reports/net-worth             - Per-account and total net worth
--
-- All amounts are reported in the configured base currency. The optional
-- @from@/@to@ query params bound the business-date window; absent bounds are
-- treated as open (handled by the service).
module Web.API.ReportingAPI
  ( -- * API Type
    ReportingAPI,
    reportingAPI,

    -- * Server
    reportingServer,

    -- * Individual Handlers (exported for testing)
    spendingByCategoryHandler,
    incomeVsExpenseHandler,
    netWorthHandler,
  )
where

import qualified Application.Services.ReportingService as ReportingService
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Types (AccountId, CategoryId, unAccountId, unDictionaryEntryId)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types
  ( AccountNetWorth (..),
    CategorySpend (..),
    IncomeVsExpenseResponse (..),
    NetWorthResponse (..),
    SpendingByCategoryResponse (..),
  )

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Reporting API type-level definition.
--
-- Authentication:
--  - All endpoints require a valid JWT token (AuthProtect "jwt").
--  - Reports are scoped to the authenticated user.
type ReportingAPI =
  -- GET /api/reports/spending-by-category - Expense totals grouped by category.
  AuthProtect "jwt"
    :> "api"
    :> "reports"
    :> "spending-by-category"
    :> QueryParam "from" UTCTime
    :> QueryParam "to" UTCTime
    :> Get '[JSON] SpendingByCategoryResponse
    -- GET /api/reports/income-vs-expense - Income, expense, and net (base ccy).
    :<|> AuthProtect "jwt"
      :> "api"
      :> "reports"
      :> "income-vs-expense"
      :> QueryParam "from" UTCTime
      :> QueryParam "to" UTCTime
      :> Get '[JSON] IncomeVsExpenseResponse
    -- GET /api/reports/net-worth - Per-account and total net worth.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "reports"
      :> "net-worth"
      :> Get '[JSON] NetWorthResponse

-- | Proxy for the ReportingAPI.
reportingAPI :: Proxy ReportingAPI
reportingAPI = Proxy

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Reporting API server implementation.
reportingServer :: ServerT ReportingAPI AppM
reportingServer =
  spendingByCategoryHandler
    :<|> incomeVsExpenseHandler
    :<|> netWorthHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for GET /api/reports/spending-by-category.
spendingByCategoryHandler ::
  AuthenticatedUser ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  AppM SpendingByCategoryResponse
spendingByCategoryHandler user mFrom mTo = do
  (total, cats) <- ReportingService.spendingByCategory user.userId mFrom mTo
  pure
    SpendingByCategoryResponse
      { categories =
          [ CategorySpend {categoryId = renderCategoryId cid, total = m}
          | (cid, m) <- cats
          ],
        total = total
      }

-- | Handler for GET /api/reports/income-vs-expense.
incomeVsExpenseHandler ::
  AuthenticatedUser ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  AppM IncomeVsExpenseResponse
incomeVsExpenseHandler user mFrom mTo = do
  (income, expense, net) <- ReportingService.incomeVsExpense user.userId mFrom mTo
  pure IncomeVsExpenseResponse {income = income, expense = expense, net = net}

-- | Handler for GET /api/reports/net-worth.
netWorthHandler :: AuthenticatedUser -> AppM NetWorthResponse
netWorthHandler user = do
  result <- ReportingService.netWorth user.userId
  (total, rows) <- either throwDomainError pure result
  pure
    NetWorthResponse
      { accounts =
          [ AccountNetWorth {accountId = renderAccountId aid, balance = bal, baseBalance = bb}
          | (aid, bal, bb) <- rows
          ],
        total = total
      }

-- | Render a category id as the dictionary entry UUID in text form. Mirrors
-- 'Web.Types.toAllocationResponse' so the wire format matches allocation DTOs.
renderCategoryId :: CategoryId -> Text
renderCategoryId cid = T.pack $ UUID.toString $ unDictionaryEntryId cid

-- | Render an account id as its raw UUID.
renderAccountId :: AccountId -> UUID
renderAccountId = unAccountId
