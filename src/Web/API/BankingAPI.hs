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
--   GET    /api/banking/connections/:id/external-accounts - Live account list
--   POST   /api/banking/connections/:id/resync            - Manual resync
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
    ExternalAccountDTO (..),

    -- * Individual Handlers (exported for testing)
    resyncHandler,
    externalAccountsHandler,

    -- * Feature gate
    requireBankingEnabled,
  )
where

import Application.ReadModels.Account (getAccessibleAccounts)
import Application.ReadModels.Configuration (ConfigurationData (..))
import Application.Services.BankImportService (ResyncResult (..))
import qualified Application.Services.BankImportService as BankImportService
import qualified Application.Services.ConfigurationService as ConfigService
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime, diffUTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Banking.Types (mkBankConnectionId)
import Domain.Configuration.Projection (BankConnection (..), BankingConfiguration (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountRole (..),
    currencyFromNumericCode,
    unAccountId,
  )
import Infrastructure.App
  ( AppM,
    HasAppConfig (..),
    runDb,
  )
import Infrastructure.Banking.Provider (BankProvider (..))
import qualified Infrastructure.Banking.Provider as Banking
import Infrastructure.Config
  ( AppConfig (..),
    bankingFeatureAvailable,
  )
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Validation (validateFieldCtx)

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Banking API type-level definition.
--
-- Endpoints:
--   - GET external-accounts: live list of a connection's external accounts.
--   - POST resync: authenticated user triggers a manual import for a stored
--     connection, routed by its persisted externalId -> local account map.
--
-- Both endpoints are connection-scoped: the Monobank token is read from the
-- connection's encrypted store rather than carried on the wire, so no secret
-- header is required.
--
-- Webhook endpoints are deferred to Phase 2 (see module header).
type BankingAPI =
  -- GET /api/banking/connections/:id/external-accounts
  -- Live list of the connection's external accounts from the provider.
  ( AuthProtect "jwt"
      :> "api"
      :> "banking"
      :> "connections"
      :> Capture "connId" UUID
      :> "external-accounts"
      :> Get '[JSON] [ExternalAccountDTO]
  )
    -- POST /api/banking/connections/:id/resync
    -- Trigger a manual import for a stored connection, routed by its
    -- persisted externalId -> local account map.
    :<|> ( AuthProtect "jwt"
             :> "api"
             :> "banking"
             :> "connections"
             :> Capture "connId" UUID
             :> "resync"
             :> ReqBody '[JSON] ResyncRequest
             :> Post '[JSON] ResyncResponse
         )

-- | Proxy for the BankingAPI.
bankingAPI :: Proxy BankingAPI
bankingAPI = Proxy

-- -----------------------------------------------------------------------------
-- Request/Response Types
-- -----------------------------------------------------------------------------

-- | Request body for manual bank statement resync.
--
-- The Monobank token is read from the connection's encrypted store, not the
-- request, so it never appears in request-body logs or traces. Category
-- resolution is performed server-side from the user's banking configuration
-- (mccExpenseCategoryMap + default income/expense categories).
data ResyncRequest = ResyncRequest
  { -- | Start of the date range to import
    from :: UTCTime,
    -- | End of the date range to import
    to :: UTCTime
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

-- | A single external bank account as listed by the provider.
--
-- Returned by @GET /api/banking/connections/:id/external-accounts@. This is
-- the read-only projection a client needs to map external accounts to local
-- ones; it deliberately omits provider-specific internals.
--
-- @maskedPan@ is the first card mask, when the provider reports any. Monobank's
-- mapper currently hardcodes @cardMasks = []@ ('Monobank.hs'), so this is
-- always @null@ for monobank today.
data ExternalAccountDTO = ExternalAccountDTO
  { -- | Provider-specific account identifier.
    externalId :: !Text,
    -- | IBAN / account number reported by the provider.
    iban :: !Text,
    -- | First card mask, if any (monobank: always 'Nothing').
    maskedPan :: !(Maybe Text),
    -- | ISO-4217 alphabetic currency code (e.g. "UAH").
    currency :: !Text,
    -- | Balance in minor units (e.g. kopiykas/cents).
    balance :: !Integer
  }
  deriving (Show, Eq, Generic)

instance FromJSON ExternalAccountDTO

instance ToJSON ExternalAccountDTO

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Banking API server implementation.
bankingServer :: ServerT BankingAPI AppM
bankingServer = externalAccountsHandler :<|> resyncHandler

-- -----------------------------------------------------------------------------
-- Feature gate
-- -----------------------------------------------------------------------------

-- | Reject the request with HTTP 404 @FEATURE_DISABLED@ unless both the
-- global banking feature and the Monobank provider are enabled in config.
--
-- 404 (rather than 403) hides the endpoint's existence entirely when the
-- feature is off. The error flows through the unified
-- @DomainError -> JSON@ envelope so clients see the same shape as every
-- other banking response. Shared by the banking and configuration-banking
-- endpoints so the gate stays in one place.
requireBankingEnabled :: AppM ()
requireBankingEnabled = do
  cfg <- view appConfigL
  unless (bankingFeatureAvailable cfg.banking)
    $ throwDomainError
    $ FeatureDisabled "banking"

-- -----------------------------------------------------------------------------
-- Handlers
-- -----------------------------------------------------------------------------

-- | Handler for POST /api/banking/connections/:id/resync
--
-- Triggers a manual bank statement import for a stored connection, routed by
-- its persisted @externalId -> local account@ map. The provider token comes
-- from the connection's encrypted store rather than a request header, so no
-- secret is carried on the wire.
--
-- Flow:
--   0. Feature-flag gate: 404 when banking or monobank are disabled.
--   1. Validate the captured connection id.
--   2. Load the caller's connection (404 'BankConnectionNotFound' if absent);
--      reject a disabled connection with 422 'BankConnectionDisabled'.
--   3. Validate the date range (max 31 days, strictly positive).
--   4-5. Build a ready-to-use provider for the connection via the
--      configuration service ('getConnectionProvider'), which decrypts the
--      stored token and dispatches on the connection's provider. The handler
--      stays provider-agnostic.
--   6. Build the import link directly from @connection.accountMap@, keeping
--      only targets the caller may write to (Owner/Editor). External accounts
--      not in the map are simply absent and reported as skipped by the import.
--   7. Call BankImportService.resync and return import counts.
resyncHandler :: AuthenticatedUser -> UUID -> ResyncRequest -> AppM ResyncResponse
resyncHandler user connUuid request = do
  -- 0. Feature-flag gate.
  requireBankingEnabled

  let userId = user.userId

  -- 1. Validate the captured connection id.
  connId <- validateFieldCtx "connId" (tshow connUuid) (mkBankConnectionId connUuid)

  -- 2. Load the caller's connection; 404 when absent.
  configResult <- ConfigService.getConfigurationForUser userId
  configData <- case configResult of
    Left err -> throwDomainError err
    Right c -> pure c
  connection <- case Map.lookup connId configData.banking.connections of
    Nothing -> throwDomainError BankConnectionNotFound
    Just c -> pure c

  -- 2a. Reject a disabled connection with 422 CONNECTION_DISABLED.
  unless connection.enabled
    $ throwDomainError BankConnectionDisabled

  -- 3. Validate date range (max 31 days).
  let maxSeconds = 31 * 86400 :: Double
      rangeSeconds = realToFrac (diffUTCTime request.to request.from) :: Double
  when (rangeSeconds > maxSeconds)
    $ throwDomainError
    $ BankingError "Date range must not exceed 31 days"
  when (rangeSeconds <= 0)
    $ throwDomainError
    $ BankingError "Date range 'to' must be after 'from'"

  -- 4-5. Build a ready-to-use provider for this connection. The service layer
  -- loads the connection, decrypts its stored token, and dispatches on the
  -- connection's provider via the injected factory, so the handler stays
  -- provider-agnostic and never touches app config.
  providerResult <- ConfigService.getConnectionProvider userId connId
  provider <- case providerResult of
    Left err -> throwDomainError err
    Right p -> pure p

  -- 6. Build the import link from the connection's accountMap, keeping only
  -- Owner/Editor (writable) targets so an import never writes to a read-only
  -- share. accountMap :: Map ExternalAccountId AccountId, and
  -- BankAccountId = ExternalAccountId = Text, so each entry is already a
  -- (BankAccountId, AccountId) pair.
  localAccounts <- runDb (getAccessibleAccounts userId)
  let writable =
        Set.fromList
          [ accId
          | (accId, _accData, role) <- localAccounts,
            role == Owner || role == Editor
          ]
      accountLink =
        [ (extId, accId)
        | (extId, accId) <- Map.toList connection.accountMap,
          Set.member accId writable
        ]

  -- 7. Call BankImportService.resync and project to the HTTP response.
  result <- BankImportService.resync provider userId accountLink request.from request.to
  return $ toResyncResponse result

-- | Handler for GET /api/banking/connections/:id/external-accounts
--
-- Returns the live list of external accounts for a stored connection, fetched
-- from the provider using the connection's decrypted token.
--
-- Flow:
--   0. Feature-flag gate: 404 when banking or monobank are disabled.
--   1. Validate the captured connection id.
--   2-3. Build a ready-to-use provider for the connection via the
--      configuration service ('getConnectionProvider'), which loads the
--      connection, decrypts its stored token, and dispatches on the
--      connection's provider. Absent connection surfaces as
--      'BankConnectionNotFound' (404); decryption failure as a 'BankingError'.
--      The handler stays provider-agnostic.
--   4. Fetch accounts; an upstream failure surfaces as a 'BankingError'.
--   5. Map each 'BankAccount' to an 'ExternalAccountDTO'.
externalAccountsHandler :: AuthenticatedUser -> UUID -> AppM [ExternalAccountDTO]
externalAccountsHandler user connUuid = do
  -- 0. Feature-flag gate.
  requireBankingEnabled

  -- 1. Validate the captured connection id.
  connId <- validateFieldCtx "connId" (tshow connUuid) (mkBankConnectionId connUuid)

  -- 2-3. Build a ready-to-use provider for this connection via the service
  -- layer, which loads the connection, decrypts its stored token, and
  -- dispatches on the connection's provider. An absent connection surfaces as
  -- 'BankConnectionNotFound' (404) and a decryption failure as a
  -- 'BankingError'; the handler stays provider-agnostic.
  providerResult <- ConfigService.getConnectionProvider user.userId connId
  provider <- case providerResult of
    Left err -> throwDomainError err
    Right p -> pure p

  -- 4. Fetch accounts; surface an upstream failure as a BankingError.
  fetchResult <- liftIO provider.fetchAccounts
  case fetchResult of
    Left err -> do
      logError $ "Failed to list external accounts: " <> display err
      throwDomainError $ BankingError $ "Failed to fetch external accounts: " <> err
    Right accs -> pure (map toExternalAccountDTO accs)

-- | Project a provider 'BankAccount' onto the wire 'ExternalAccountDTO'.
--
-- The ISO-4217 numeric currency code is converted to its alphabetic form using
-- the same converter the import path uses ('currencyFromNumericCode'); an
-- unsupported code falls back to the numeric code rendered as text so the row
-- is still listed rather than failing the whole request.
toExternalAccountDTO :: Banking.BankAccount -> ExternalAccountDTO
toExternalAccountDTO acc =
  ExternalAccountDTO
    { externalId = acc.externalId,
      iban = acc.accountNumber,
      maskedPan = listToMaybe acc.cardMasks,
      currency = case currencyFromNumericCode acc.currencyCode of
        Right c -> tshow c
        Left _ -> tshow acc.currencyCode,
      balance = fromIntegral acc.balance
    }

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
