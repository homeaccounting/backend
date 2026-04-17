{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankingAPI
-- Description : REST API endpoints for bank integration
--
-- This module defines the Servant API for banking operations.
--
-- Per the 2026-04-16 spec amendment, Phase 1 is resync-only. Webhook
-- endpoints (validation GET, event POST) are deferred to Phase 2, which
-- will introduce proper webhook secret validation and HMAC-based payload
-- authentication. The previous webhook handlers were non-functional stubs
-- and have been removed rather than shipped as security-dangerous
-- placeholders.
--
-- API Endpoints:
--
--   POST   /api/banking/resync                   - Manual resync (authenticated)
module Web.API.BankingAPI
  ( -- * API Type
    BankingAPI,
    bankingAPI,

    -- * Server
    bankingServer,

    -- * Request/Response Types
    ResyncRequest (..),
    ResyncResponse (..),
    AccountResyncSummary (..),

    -- * Individual Handlers (exported for testing)
    resyncHandler,
    buildBankLink,
  )
where

import Application.ReadModels.Account (AccountData (..), getAccessibleAccounts)
import Application.Services.BankImportService (ResyncResult (..))
import qualified Application.Services.BankImportService as BankImportService
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Text as T
import Data.Time (UTCTime, diffUTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    AccountRole (..),
    AccountSubtype (..),
    AccountType (..),
    BankAccountProperties (..),
    mkDictionaryEntryId,
    unAccountId,
  )
import Infrastructure.App
  ( AppM,
    HasAppConfig (..),
    HasHttpManager (..),
    HasReadModel (..),
  )
import Infrastructure.Banking.Monobank (mkMonobankProvider)
import Infrastructure.Banking.Provider (BankAccountId, BankProvider (..))
import qualified Infrastructure.Banking.Provider as Banking
import Infrastructure.Config
  ( AppConfig (..),
    BankingConfig (..),
    BankingProvidersConfig (..),
    MonobankProviderConfig (..),
  )
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Validation (validateField)

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Banking API type-level definition.
--
-- Endpoints:
--   - POST resync: Authenticated user triggers manual bank statement import
--
-- The Monobank API token is supplied via the dedicated @X-Banking-Token@
-- header rather than @Authorization: Bearer@. Reusing the @Authorization@
-- scheme would collide with the JWT bearer token already required by
-- @AuthProtect "jwt"@ on this route, so a distinct header is used.
--
-- Webhook endpoints are deferred to Phase 2 (see module header).
type BankingAPI =
  AuthProtect "jwt"
    :> Header' '[Required, Strict] "X-Banking-Token" Text
    :> "api"
    :> "banking"
    :> "resync"
    :> ReqBody '[JSON] ResyncRequest
    :> Post '[JSON] ResyncResponse

-- | Proxy for the BankingAPI.
bankingAPI :: Proxy BankingAPI
bankingAPI = Proxy

-- -----------------------------------------------------------------------------
-- Request/Response Types
-- -----------------------------------------------------------------------------

-- | Request body for manual bank statement resync.
--
-- The defaultCategory field is temporary until user configuration
-- integration is complete. Eventually this will be read from
-- UserConfiguration. The Monobank token is supplied in the
-- @X-Banking-Token@ header rather than the JSON body so it does not
-- appear in request-body logs or traces.
data ResyncRequest = ResyncRequest
  { -- | Start of the date range to import
    from :: UTCTime,
    -- | End of the date range to import
    to :: UTCTime,
    -- | Default category for uncategorized transactions
    defaultCategory :: UUID
  }
  deriving (Show, Eq, Generic)

instance FromJSON ResyncRequest

instance ToJSON ResyncRequest

-- | Per-account summary returned in the resync response.
--
-- Counts only — the raw transaction IDs are not exposed at the HTTP boundary.
-- 'localAccountId' is rendered as its UUID text so callers do not depend on
-- internal representations.
data AccountResyncSummary = AccountResyncSummary
  { externalAccountId :: !Text,
    localAccountId :: !Text,
    importedCount :: !Int,
    skippedCount :: !Int,
    failureCount :: !Int
  }
  deriving (Show, Eq, Generic)

instance FromJSON AccountResyncSummary

instance ToJSON AccountResyncSummary

-- | Response body for manual bank statement resync.
--
-- Always returned with HTTP 200. Per-account failures are reported in the
-- body rather than raising at the top level; callers should inspect
-- 'failureCount' per account.
data ResyncResponse = ResyncResponse
  { accounts :: ![AccountResyncSummary]
  }
  deriving (Show, Eq, Generic)

instance FromJSON ResyncResponse

instance ToJSON ResyncResponse

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Banking API server implementation.
bankingServer :: ServerT BankingAPI AppM
bankingServer = resyncHandler

-- -----------------------------------------------------------------------------
-- Handlers
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/banking/resync
--
-- Triggers a manual bank statement import for the authenticated user.
--
-- The Monobank API token is carried in a dedicated @X-Banking-Token@
-- header rather than @Authorization: Bearer@ because the same request
-- already uses an @Authorization: Bearer <jwt>@ header for the app's
-- own JWT scheme. Sharing one @Authorization@ header between two
-- independent bearer schemes is not expressible in Servant and would
-- confuse both clients and server-side auth handlers.
--
-- Flow:
--   0. Feature-flag gate: 404 when banking or monobank are disabled.
--   1. Validate date range (max 31 days)
--   2. Create Monobank provider from the header token
--   3. Fetch bank accounts from provider
--   4. Match bank accounts to Owner/Editor local accounts by accountNumber
--   5. Build the mapping list from the matches
--   6. Call BankImportService.resync
--   7. Return import counts
resyncHandler :: AuthenticatedUser -> Text -> ResyncRequest -> AppM ResyncResponse
resyncHandler user bankingToken request = do
  -- 0. Feature-flag gate: return 404 when the banking feature or the
  -- Monobank provider are disabled. 404 (rather than 403) hides the
  -- endpoint's existence entirely when the feature is off. The error
  -- flows through the unified DomainError -> JSON envelope so clients
  -- see the same shape as every other banking response.
  cfg <- view appConfigL
  let bankingCfg = cfg.banking
      monoCfg = bankingCfg.providers.monobank
  unless (bankingCfg.enabled && monoCfg.enabled)
    $ throwDomainError
    $ FeatureDisabled "banking"

  -- 1. Validate date range (max 31 days)
  let maxSeconds = 31 * 86400 :: Double
      rangeSeconds = realToFrac (diffUTCTime request.to request.from) :: Double
  when (rangeSeconds > maxSeconds)
    $ throwDomainError
    $ BankingError "Date range must not exceed 31 days"
  when (rangeSeconds <= 0)
    $ throwDomainError
    $ BankingError "Date range 'to' must be after 'from'"

  -- 1a. Reject an empty/whitespace-only X-Banking-Token early so the
  -- failure mode is a clear banking validation error rather than an
  -- opaque downstream 401 from the Monobank API.
  when (T.null (T.strip bankingToken))
    $ throwDomainError
    $ BankingError "X-Banking-Token header must not be empty"

  -- 2. Parse defaultCategory UUID into DictionaryEntryId
  categoryId <- validateField "defaultCategory" $ mkDictionaryEntryId request.defaultCategory

  let userId = user.userId

  -- 3. Create provider from token + httpManager
  manager <- view httpManagerL
  let MonobankProviderConfig {apiBaseUrl = apiBaseUrl} = monoCfg
      provider = mkMonobankProvider apiBaseUrl bankingToken manager

  -- 4. Fetch bank accounts from provider
  fetchResult <- liftIO provider.fetchAccounts
  bankAccounts <- case fetchResult of
    Left err -> do
      logError $ "Failed to fetch bank accounts: " <> display err
      throwDomainError $ BankingError $ "Failed to fetch bank accounts: " <> err
    Right accs -> return accs

  -- 5. Match bank accounts to local accounts (Owner/Editor only)
  accountRM <- view accountReadModelL
  localAccounts <- getAccessibleAccounts accountRM userId
  bankLink <- buildBankLink bankAccounts localAccounts

  -- 6. Call BankImportService.resync
  result <- BankImportService.resync provider userId bankLink categoryId request.from request.to
  return $ toResyncResponse result

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Render a service-layer 'ResyncResult' as the HTTP response, projecting
-- the per-account breakdown to counts and text IDs.
toResyncResponse :: ResyncResult -> ResyncResponse
toResyncResponse r =
  ResyncResponse
    { accounts = map summarize r.accounts
    }
  where
    summarize acc =
      AccountResyncSummary
        { externalAccountId = acc.externalAccountId,
          localAccountId = UUID.toText (unAccountId acc.localAccountId),
          importedCount = length acc.imported,
          skippedCount = acc.skipped,
          failureCount = length acc.failures
        }

-- | Build the account mapping list on the fly by matching bank accounts to local accounts.
--
-- For each bank account, finds local accounts with matching accountNumber
-- (from BankAccountProperties). Only accounts where the caller has the
-- 'Owner' or 'Editor' role are considered; 'Viewer'-shared accounts are
-- excluded so bank imports never write to a read-only share.
--
-- When a bank IBAN matches more than one local account the first candidate
-- is picked deterministically and a warning is logged listing all
-- candidates so the user can disambiguate manually.
--
-- Returns an error if no accounts could be matched.
buildBankLink ::
  (MonadIO m, MonadReader env m, HasLogFunc env) =>
  [Banking.BankAccount] ->
  [(AccountId, AccountData, AccountRole)] ->
  m [(BankAccountId, AccountId)]
buildBankLink bankAccounts localAccounts = do
  let writable =
        [ (accId, accData)
        | (accId, accData, role) <- localAccounts,
          role == Owner || role == Editor
        ]
  resolved <- forM bankAccounts $ \bankAcc -> do
    let bankIBAN = bankAcc.accountNumber
        candidates =
          [ (bankAcc.externalId, accId)
          | (accId, accData) <- writable,
            matchesAccountNumber bankIBAN accData
          ]
    case candidates of
      [] -> return Nothing
      [single] -> return (Just single)
      many@(firstCandidate : _) -> do
        logWarn
          $ "IBAN "
          <> display bankIBAN
          <> " matches multiple local accounts; picking first. Candidates: "
          <> displayShow (map snd many)
        return (Just firstCandidate)
  let collected = catMaybes resolved
  when (null collected)
    $ throwDomainError
    $ BankingError
      "No bank accounts could be matched to local accounts. Ensure your Owner/Editor accounts have matching IBANs."
  return collected
  where
    matchesAccountNumber :: Text -> AccountData -> Bool
    matchesAccountNumber bankNumber accData =
      case accData.accountType of
        Regular (BankAccount props) ->
          props.accountNumber == Just bankNumber
        _ -> False
