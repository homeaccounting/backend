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
--   POST   /api/banking/connections/:id/import            - Manual import (pull)
--   POST   /api/banking/connections/:id/import/file        - Statement-file import
module Web.API.BankingAPI
  ( -- * API Type
    BankingAPI,
    bankingAPI,

    -- * Server
    bankingServer,

    -- * Request/Response Types
    ConnectionImportRequest (..),
    ImportResponse (..),
    AccountImportSummary (..),
    ExternalAccountDTO (..),

    -- * Individual Handlers (exported for testing)
    importConnectionHandler,
    importStatementFileHandler,
    externalAccountsHandler,

    -- * Feature gate
    requireBankingEnabled,
  )
where

import Application.ReadModels.Account (getAccounts)
import Application.ReadModels.Configuration (ConfigurationData (..))
import Application.Services.BankImportService (ImportResult (..))
import qualified Application.Services.BankImportService as BankImportService
import qualified Application.Services.ConfigurationService as ConfigService
import Data.Aeson (FromJSON, ToJSON, encode)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime, diffUTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Banking.Types (BankConnectionId, mkBankConnectionId, unExternalAccountId)
import Domain.Configuration.Projection (BankConnection (..), BankingConfiguration (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountRole (..),
    UserId,
    currencyFromNumericCode,
    unAccountId,
  )
import Infrastructure.App
  ( AppM,
    bankingFeatureEnabled,
    runDb,
  )
import qualified Infrastructure.Banking.Provider as Banking
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types (ErrorResponse (..))
import Web.Validation (validateFieldCtx)

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Banking API type-level definition.
--
-- Endpoints:
--   - GET external-accounts: live list of a connection's external accounts.
--   - POST import: authenticated user triggers a manual pull import for a
--     stored connection, routed by its persisted externalId -> local account
--     map.
--   - POST import/file: authenticated user uploads a statement file for a
--     stored connection; parsed by the connection's provider (via its
--     'FileImportCapability') and routed the same way.
--
-- All endpoints are connection-scoped: the provider token (when the
-- transport needs one) is read from the connection's encrypted store rather
-- than carried on the wire, so no secret header is required.
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
    -- POST /api/banking/connections/:id/import
    -- Trigger a manual pull import for a stored connection, routed by its
    -- persisted externalId -> local account map.
    :<|> ( AuthProtect "jwt"
             :> "api"
             :> "banking"
             :> "connections"
             :> Capture "connId" UUID
             :> "import"
             :> ReqBody '[JSON] ConnectionImportRequest
             :> Post '[JSON] ImportResponse
         )
    -- POST /api/banking/connections/:id/import/file
    -- Upload a statement file for a stored connection; parsed by the
    -- connection's provider and routed by its accountMap.
    :<|> ( AuthProtect "jwt"
             :> "api"
             :> "banking"
             :> "connections"
             :> Capture "connId" UUID
             :> "import"
             :> "file"
             :> QueryParam' '[Required, Strict] "format" Banking.StatementFormat
             :> ReqBody '[OctetStream] ByteString
             :> Post '[JSON] ImportResponse
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
data ConnectionImportRequest = ConnectionImportRequest
  { -- | Start of the date range to import
    from :: UTCTime,
    -- | End of the date range to import
    to :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance FromJSON ConnectionImportRequest

instance ToJSON ConnectionImportRequest

-- | Per-account summary returned in the import response.
--
-- 'importedCount' and 'failureCount' are counts — the raw transaction IDs are
-- not exposed at the HTTP boundary. 'skipped' lists the human-readable reason
-- for each skipped transaction (dedup, currency mismatch, …) rather than a bare
-- count, so callers can explain why rows were not imported.
-- 'localAccountId' is rendered as its UUID text so callers do not depend on
-- internal representations.
data AccountImportSummary = AccountImportSummary
  { externalAccountId :: !Text,
    localAccountId :: !Text,
    importedCount :: !Int,
    skipped :: ![Text],
    failureCount :: !Int
  }
  deriving (Show, Eq, Generic)

instance FromJSON AccountImportSummary

instance ToJSON AccountImportSummary

-- | Response body for manual bank statement import.
--
-- Always returned with HTTP 200. Per-account failures are reported in the
-- body rather than raising at the top level; callers should inspect
-- 'failureCount' per account. 'unresolved' lists external account ids seen
-- in the imported data but absent from the connection's mapped accounts;
-- for the connection (pull) path this is always empty, since the link is
-- built strictly from the connection's own @accountMap@.
data ImportResponse = ImportResponse
  { accounts :: ![AccountImportSummary],
    unresolved :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance FromJSON ImportResponse

instance ToJSON ImportResponse

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
bankingServer = externalAccountsHandler :<|> importConnectionHandler :<|> importStatementFileHandler

-- -----------------------------------------------------------------------------
-- Wire parsing
-- -----------------------------------------------------------------------------

-- | Parse the @format@ query param of @POST .../import/file@. Orphan instance
-- (silenced project-wide via @-fno-warn-orphans@, same as 'Web.Query'\'s
-- @StatusKind@ instance): 'Banking.StatementFormat' lives in
-- 'Infrastructure.Banking.Provider' and stays wire-agnostic, so its wire
-- parsing lives here instead.
instance FromHttpApiData Banking.StatementFormat where
  parseUrlPiece "csv" = Right Banking.StatementCsv
  parseUrlPiece "xlsx" = Right Banking.StatementXlsx
  parseUrlPiece other = Left ("unknown statement format: " <> other)

-- -----------------------------------------------------------------------------
-- Feature gate
-- -----------------------------------------------------------------------------

-- | Reject the request with HTTP 404 @FEATURE_DISABLED@ unless the banking
-- feature is enabled ('bankingFeatureEnabled': master switch on AND at least
-- one provider registered).
--
-- 404 (rather than 403) hides the endpoint's existence entirely when the
-- feature is off. The error flows through the unified
-- @DomainError -> JSON@ envelope so clients see the same shape as every
-- other banking response. Wraps the shared 'bankingFeatureEnabled' predicate
-- so this gate and the configuration-banking DTO field cannot drift.
requireBankingEnabled :: AppM ()
requireBankingEnabled = do
  enabled <- bankingFeatureEnabled
  unless enabled
    $ throwDomainError
    $ FeatureDisabled "banking"

-- -----------------------------------------------------------------------------
-- Handlers
-- -----------------------------------------------------------------------------

-- | Shared preamble for connection-scoped import transports: validate the
-- captured id, load the caller's connection (404 if absent/not theirs), and
-- reject a disabled connection (both transports are inert when disabled).
resolveOwnedEnabledConnection :: UserId -> UUID -> AppM (BankConnectionId, BankConnection)
resolveOwnedEnabledConnection userId connUuid = do
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

  pure (connId, connection)

-- | Handler for POST /api/banking/connections/:id/import
--
-- Triggers a manual bank statement (pull) import for a stored connection, routed by
-- its persisted @externalId -> local account@ map. The provider token comes
-- from the connection's encrypted store rather than a request header, so no
-- secret is carried on the wire.
--
-- Flow:
--   0. Feature-flag gate: 404 when banking or monobank are disabled.
--   1-2a. 'resolveOwnedEnabledConnection': validate the captured connection
--      id, load the caller's connection (404 'BankConnectionNotFound' if
--      absent), and reject a disabled connection with 422
--      'BankConnectionDisabled'.
--   3. Validate the date range (max 31 days, strictly positive).
--   4-5. Resolve the connection's classifier + pull capability via the
--      configuration service ('getConnectionProvider'), which decrypts the
--      stored token and looks the connection's provider up in the registry.
--      The handler stays provider-agnostic.
--   6. Build the import link directly from @connection.accountMap@, keeping
--      only targets the caller may write to (Owner/Editor). External accounts
--      not in the map are simply absent and reported as skipped by the import.
--   7. Call BankImportService.importConnection and return import counts.
importConnectionHandler :: AuthenticatedUser -> UUID -> ConnectionImportRequest -> AppM ImportResponse
importConnectionHandler user connUuid request = do
  -- 0. Feature-flag gate.
  requireBankingEnabled

  let userId = user.userId

  -- 1-2a. Validate the connection id, load the caller's connection (404 if
  -- absent), and reject it if disabled (422 CONNECTION_DISABLED).
  (connId, connection) <- resolveOwnedEnabledConnection userId connUuid

  -- 3. Validate date range (max 31 days).
  let maxSeconds = 31 * 86400 :: Double
      rangeSeconds = realToFrac (diffUTCTime request.to request.from) :: Double
  when (rangeSeconds > maxSeconds)
    $ throwDomainError
    $ BankingError "Date range must not exceed 31 days"
  when (rangeSeconds <= 0)
    $ throwDomainError
    $ BankingError "Date range 'to' must be after 'from'"

  -- 4-5. Resolve the connection's classifier + pull capability. The service
  -- layer loads the connection, decrypts its stored token, and looks the
  -- connection's provider up in the registry, so the handler stays
  -- provider-agnostic and never touches app config.
  providerResult <- ConfigService.getConnectionProvider userId connId
  (interpretation, pull) <- case providerResult of
    Left err -> throwDomainError err
    Right p -> pure p

  -- 6. Build the import link from the connection's accountMap, keeping only
  -- Owner/Editor (writable) targets so an import never writes to a read-only
  -- share. accountMap :: Map ExternalAccountId AccountId, so each entry is
  -- already an (ExternalAccountId, AccountId) pair.
  localAccounts <- runDb (getAccounts userId)
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

  -- 7. Call BankImportService.importConnection and project to the HTTP response.
  result <- BankImportService.importConnection interpretation pull userId accountLink request.from request.to
  return $ toImportResponse result

-- | Handler for POST /api/banking/connections/:id/import/file
--
-- Uploads a statement file for a stored connection; the file is parsed by
-- the connection's provider (via its 'Banking.FileImportCapability') and the
-- resulting transactions are routed the same way a pull import routes them —
-- by the connection's persisted @externalId -> local account@ map.
--
-- Flow:
--   0. Feature-flag gate: 404 when banking is disabled.
--   1-2a. 'resolveOwnedEnabledConnection': validate the captured connection
--      id, load the caller's connection (404 'BankConnectionNotFound' if
--      absent), and reject a disabled connection with 422
--      'BankConnectionDisabled' — identical check to
--      'importConnectionHandler'.
--   3. Resolve the connection's classifier + file-import capability via the
--      configuration service ('ConfigService.getConnectionFileImport'); no
--      token is required for this transport.
--   4. Look up the parser for the requested 'Banking.StatementFormat'; 422
--      @UNSUPPORTED_STATEMENT_FORMAT@ when the provider has no parser for it.
--   5. Parse the uploaded bytes; a whole-file 'Banking.ParseError' surfaces as
--      422 @STATEMENT_PARSE_ERROR@. Otherwise split the per-row results into
--      successfully-parsed transactions and per-row 'Banking.RowError's.
--   6. Build the import link from @connection.accountMap@, filtered to
--      Owner/Editor (writable) targets exactly like 'importConnectionHandler'.
--      When exactly one writable target remains, every distinct card seen in
--      the file is routed to it (the common single-account statement case);
--      otherwise the filtered map is used as-is.
--   7. Delegate to 'BankImportService.importMany'.
--   8. Merge the per-row parse failures into the response's 'unresolved'
--      list alongside any account-routing misses.
importStatementFileHandler :: AuthenticatedUser -> UUID -> Banking.StatementFormat -> ByteString -> AppM ImportResponse
importStatementFileHandler user connUuid format bytes = do
  -- 0. Feature-flag gate.
  requireBankingEnabled

  let userId = user.userId

  -- 1-2a. Validate the connection id, load the caller's connection (404 if
  -- absent), and reject it if disabled (422 CONNECTION_DISABLED) — identical
  -- check to 'importConnectionHandler'.
  (connId, connection) <- resolveOwnedEnabledConnection userId connUuid

  -- 3. Resolve the connection's classifier + file-import capability.
  fileImportResult <- ConfigService.getConnectionFileImport userId connId
  (interpretation, cap) <- case fileImportResult of
    Left err -> throwDomainError err
    Right p -> pure p

  -- 4. Resolve the parser for the requested format.
  parser <- case Map.lookup format cap.parsers of
    Nothing -> throwUnsupportedFormat format
    Just p -> pure p

  -- 5. Parse the uploaded bytes; split per-row results into successes and
  -- row-level failures.
  rows <- case parser bytes of
    Left (Banking.ParseError msg) -> throwStatementParseError msg
    Right rs -> pure rs
  let (rowErrors, goods) = partitionEithers rows

  -- 6. Build the import link from the connection's accountMap, keeping only
  -- Owner/Editor (writable) targets — identical filter to
  -- 'importConnectionHandler'\'s step 6.
  localAccounts <- runDb (getAccounts userId)
  let writable =
        Set.fromList
          [ accId
          | (accId, _accData, role) <- localAccounts,
            role == Owner || role == Editor
          ]
      writableMap =
        [ (extId, accId)
        | (extId, accId) <- Map.toList connection.accountMap,
          Set.member accId writable
        ]
      -- Single-account statements route every distinct card seen in the file
      -- to the one writable target; a multi-account map is used as-is.
      accountLink = case writableMap of
        [(_, target)] -> [(cardId, target) | cardId <- nubOrd (map (.externalAccountId) goods)]
        _ -> writableMap

  -- 7. Import the parsed transactions.
  result <- BankImportService.importMany interpretation userId accountLink goods

  -- 8. Merge per-row parse failures into 'unresolved' alongside any
  -- account-routing misses 'importMany' already collected. Built via a fresh
  -- 'ImportResult' (rather than a record update) since 'unresolved' is also a
  -- field of 'ImportResponse', which a same-module record update cannot
  -- disambiguate.
  let mergedResult =
        ImportResult
          { accounts = result.accounts,
            unresolved = result.unresolved <> map renderRowError rowErrors
          }
  return $ toImportResponse mergedResult

-- | Handler for GET /api/banking/connections/:id/external-accounts
--
-- Returns the live list of external accounts for a stored connection, fetched
-- from the provider using the connection's decrypted token.
--
-- Flow:
--   0. Feature-flag gate: 404 when banking or monobank are disabled.
--   1. Validate the captured connection id.
--   2-3. Resolve the connection's classifier + pull capability via the
--      configuration service ('getConnectionProvider'), which loads the
--      connection, decrypts its stored token, and looks the connection's
--      provider up in the registry. Absent connection surfaces as
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

  -- 2-3. Resolve the connection's classifier + pull capability via the service
  -- layer, which loads the connection, decrypts its stored token, and looks the
  -- connection's provider up in the registry. An absent connection surfaces as
  -- 'BankConnectionNotFound' (404) and a decryption failure as a
  -- 'BankingError'; the handler stays provider-agnostic.
  providerResult <- ConfigService.getConnectionProvider user.userId connId
  (_interpretation, pull) <- case providerResult of
    Left err -> throwDomainError err
    Right p -> pure p

  -- 4. Fetch accounts; surface an upstream failure as a BankingError.
  fetchResult <- liftIO pull.fetchAccounts
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
    { externalId = unExternalAccountId acc.externalAccountId,
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

-- | Render a service-layer 'ImportResult' as the HTTP response, projecting
-- the per-account breakdown to counts and text IDs.
toImportResponse :: ImportResult -> ImportResponse
toImportResponse r =
  ImportResponse
    { accounts = map summarize r.accounts,
      unresolved = r.unresolved
    }
  where
    summarize acc =
      AccountImportSummary
        { externalAccountId = unExternalAccountId acc.externalAccountId,
          localAccountId = UUID.toText (unAccountId acc.localAccountId),
          importedCount = length acc.succeeded,
          skipped = acc.skipped,
          failureCount = length acc.failed
        }

-- | Render one statement-file 'Banking.RowError' as an 'ImportResponse'
-- \'unresolved\' entry, e.g. @"row 3: invalid date: 40.13.2026"@.
renderRowError :: Banking.RowError -> Text
renderRowError err = "row " <> tshow err.rowNumber <> ": " <> err.message

-- | 422 @UNSUPPORTED_STATEMENT_FORMAT@ — the connection's provider has no
-- parser registered for the requested 'Banking.StatementFormat'. Constructed
-- directly via Servant's 'err422' (mirroring
-- 'Web.API.TransactionAPI.requireLinkableKind') rather than through
-- 'Web.ErrorMapping', since no existing 'DomainError' constructor models
-- \"unsupported wire format\" without overloading an unrelated case.
throwUnsupportedFormat :: (MonadIO m) => Banking.StatementFormat -> m a
throwUnsupportedFormat format =
  throwIO
    $ err422
      { errBody =
          encode
            ErrorResponse
              { message = "Unsupported statement format for this connection's provider: " <> tshow format,
                code = "UNSUPPORTED_STATEMENT_FORMAT",
                details = Nothing
              }
      }

-- | 422 @STATEMENT_PARSE_ERROR@ — the uploaded file failed a whole-file
-- 'Banking.ParseError' (as opposed to a per-row 'Banking.RowError', which is
-- instead folded into the response's \'unresolved\' list). Same rationale as
-- 'throwUnsupportedFormat' for bypassing 'Web.ErrorMapping'.
throwStatementParseError :: (MonadIO m) => Text -> m a
throwStatementParseError msg =
  throwIO
    $ err422
      { errBody =
          encode
            ErrorResponse
              { message = msg,
                code = "STATEMENT_PARSE_ERROR",
                details = Nothing
              }
      }
