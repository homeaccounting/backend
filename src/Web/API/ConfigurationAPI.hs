{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.ConfigurationAPI
-- Description : REST API endpoints for user configuration operations
--
-- This module defines the Servant API for configuration management operations.
-- Handlers are thin HTTP adapters that delegate to 'ConfigurationService' for
-- business orchestration and use 'ErrorMapping' for error responses.
--
-- API Endpoints:
--
--   GET    /api/users/me/configuration                                       - Get my configuration
--   PUT    /api/users/me/configuration/base-currency                         - Update base currency
--   PUT    /api/users/me/configuration/default-currency                      - Update default currency
--   PUT    /api/users/me/configuration/banking                               - Update banking config (MCC map)
--   PUT    /api/users/me/configuration/defaults                              - Update global default categories
--   PUT    /api/users/me/configuration/books-close                           - Close books through a cutoff
--   GET    /api/users/me/configuration/dictionaries/:dictId                  - List dictionary entries
--   POST   /api/users/me/configuration/dictionaries/:dictId/entries          - Add entry
--   PUT    /api/users/me/configuration/dictionaries/:dictId/entries/:entryId - Rename entry
--   DELETE /api/users/me/configuration/dictionaries/:dictId/entries/:entryId - Remove entry
module Web.API.ConfigurationAPI
  ( -- * API Type
    ConfigurationAPI,
    configurationAPI,

    -- * Request/Response Types
    ConfigurationResponse (..),
    ConfigurationDefaultsDTO (..),
    BankingConfigurationDTO (..),
    BankConnectionDTO (..),
    DictionaryResponse (..),
    DictionaryEntryResponse (..),
    ChangeCurrencyRequest (..),
    UpdateBankingRequest (..),
    UpdateDefaultsRequest (..),
    CloseBooksThroughRequest (..),
    AddEntryRequest (..),
    AddEntryResponse (..),
    RenameEntryRequest (..),
    AddConnectionRequest (..),
    UpdateConnectionRequest (..),
    ChangeTokenRequest (..),
    SetAccountMapRequest (..),

    -- * Server
    configurationServer,
  )
where

import Application.ReadModels.Account (AccountData (..), getAccount)
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import qualified Application.Services.ConfigurationService as ConfigService
import Application.Services.Internal (getUserExternalAccountId)
import Control.Monad.Except (runExceptT)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Domain.Banking.Types
  ( BankConnectionId,
    BankProvider (..),
    ExternalAccountId,
    mkBankConnectionId,
    unBankConnectionId,
  )
import Domain.Configuration.Projection
  ( BankConnection (..),
    BankingConfiguration (..),
    ConfigurationDefaults (..),
  )
import Domain.Core.Types
  ( AccountSubtypeKind,
    DictionaryId (..),
    UserId,
    mkAccountId,
    mkDictionaryEntryId,
    mkEntryName,
    parseCurrency,
    unAccountId,
    unDictionaryEntryId,
    unDictionaryId,
    unEntryName,
  )
import Infrastructure.App (AppM, HasAppConfig (..), runDb)
import Infrastructure.Config
  ( AppConfig (..),
    bankingFeatureAvailable,
  )
import RIO
import Servant
import Web.API.BankingAPI (requireBankingEnabled)
import Web.ErrorMapping (throwDomainError, throwValidation)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Validation (validateFieldCtx)

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Configuration API type-level definition.
type ConfigurationAPI =
  -- GET /api/users/me/configuration - Get my configuration
  AuthProtect "jwt"
    :> "api"
    :> "users"
    :> "me"
    :> "configuration"
    :> Get '[JSON] ConfigurationResponse
    -- PUT /api/users/me/configuration/base-currency - Update base currency
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "base-currency"
      :> ReqBody '[JSON] ChangeCurrencyRequest
      :> Put '[JSON] NoContent
    -- PUT /api/users/me/configuration/default-currency - Update default currency
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "default-currency"
      :> ReqBody '[JSON] ChangeCurrencyRequest
      :> Put '[JSON] NoContent
    -- PUT /api/users/me/configuration/banking - Update banking defaults (partial)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> ReqBody '[JSON] UpdateBankingRequest
      :> Put '[JSON] BankingConfigurationDTO
    -- PUT /api/users/me/configuration/defaults - Update global default categories (partial)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "defaults"
      :> ReqBody '[JSON] UpdateDefaultsRequest
      :> Put '[JSON] ConfigurationResponse
    -- PUT /api/users/me/configuration/books-close - Close books through a cutoff
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "books-close"
      :> ReqBody '[JSON] CloseBooksThroughRequest
      :> Put '[JSON] ConfigurationResponse
    -- GET /api/users/me/configuration/dictionaries/:dictId - List dictionary entries
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "dictionaries"
      :> Capture "dictId" Text
      :> Get '[JSON] DictionaryResponse
    -- POST /api/users/me/configuration/dictionaries/:dictId/entries - Add entry
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "dictionaries"
      :> Capture "dictId" Text
      :> "entries"
      :> ReqBody '[JSON] AddEntryRequest
      :> Verb 'POST 201 '[JSON] AddEntryResponse
    -- PUT /api/users/me/configuration/dictionaries/:dictId/entries/:entryId - Rename entry
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "dictionaries"
      :> Capture "dictId" Text
      :> "entries"
      :> Capture "entryId" UUID
      :> ReqBody '[JSON] RenameEntryRequest
      :> Put '[JSON] NoContent
    -- DELETE /api/users/me/configuration/dictionaries/:dictId/entries/:entryId - Remove entry
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "dictionaries"
      :> Capture "dictId" Text
      :> "entries"
      :> Capture "entryId" UUID
      :> Delete '[JSON] NoContent
    -- POST …/configuration/banking/connections - Add a bank connection
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> "connections"
      :> ReqBody '[JSON] AddConnectionRequest
      :> Verb 'POST 201 '[JSON] BankConnectionDTO
    -- PUT …/configuration/banking/connections/:id - Update name and/or enabled
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> "connections"
      :> Capture "connId" UUID
      :> ReqBody '[JSON] UpdateConnectionRequest
      :> PutNoContent
    -- PUT …/configuration/banking/connections/:id/token - Replace the token
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> "connections"
      :> Capture "connId" UUID
      :> "token"
      :> ReqBody '[JSON] ChangeTokenRequest
      :> PutNoContent
    -- DELETE …/configuration/banking/connections/:id - Remove a connection
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> "connections"
      :> Capture "connId" UUID
      :> DeleteNoContent
    -- PUT …/configuration/banking/connections/:id/accounts - Set account map
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> "connections"
      :> Capture "connId" UUID
      :> "accounts"
      :> ReqBody '[JSON] SetAccountMapRequest
      :> PutNoContent

-- -----------------------------------------------------------------------------
-- Request/Response Types
-- -----------------------------------------------------------------------------

-- | Projection of BankingConfiguration for wire transport.
data BankingConfigurationDTO = BankingConfigurationDTO
  { mccExpenseCategoryMap :: Map Text UUID,
    -- | Configured bank connections (secrets never serialised).
    connections :: [BankConnectionDTO]
  }
  deriving (Show, Eq, Generic)

instance ToJSON BankingConfigurationDTO

instance FromJSON BankingConfigurationDTO

-- | Wire projection of a single 'BankConnection'.
--
-- The provider token is NEVER serialised; clients learn only that a token is
-- set ('tokenSet') and a non-secret 'tokenHint'.
data BankConnectionDTO = BankConnectionDTO
  { id :: UUID,
    provider :: Text,
    name :: Text,
    enabled :: Bool,
    -- | True iff an (encrypted) token is stored for the connection.
    tokenSet :: Bool,
    tokenHint :: Text,
    -- | External-account-id → local-account-id mapping.
    accountMap :: Map Text UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON BankConnectionDTO

instance FromJSON BankConnectionDTO

-- | Convert a domain 'BankConnection' to its wire DTO. The token is omitted.
toBankConnectionDTO :: BankConnection -> BankConnectionDTO
toBankConnectionDTO c =
  BankConnectionDTO
    { id = unBankConnectionId c.connectionId,
      provider = bankProviderText c.provider,
      name = c.name,
      enabled = c.enabled,
      tokenSet = True,
      tokenHint = c.tokenHint,
      accountMap = Map.map unAccountId c.accountMap
    }

-- | Render a 'BankProvider' as its wire string.
bankProviderText :: BankProvider -> Text
bankProviderText Monobank = "monobank"

-- | Convert domain BankingConfiguration to its wire DTO.
toBankingDTO :: BankingConfiguration -> BankingConfigurationDTO
toBankingDTO b =
  BankingConfigurationDTO
    { mccExpenseCategoryMap = Map.map unDictionaryEntryId b.mccExpenseCategoryMap,
      connections = map toBankConnectionDTO (Map.elems b.connections)
    }

-- | All per-configuration defaults, grouped for wire transport
-- (@configuration.defaults@).
data ConfigurationDefaultsDTO = ConfigurationDefaultsDTO
  { -- | Global default category for imported/inferred income transactions.
    incomeCategory :: Maybe UUID,
    -- | Global default category for imported/inferred expense transactions.
    expenseCategory :: Maybe UUID,
    -- | Global fallback account (no account named / subtype unidentifiable).
    account :: Maybe UUID,
    -- | Default account per account subtype, keyed by 'AccountSubtypeKind'.
    subtypeAccounts :: Map AccountSubtypeKind UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON ConfigurationDefaultsDTO

instance FromJSON ConfigurationDefaultsDTO

-- | Configuration response DTO.
data ConfigurationResponse = ConfigurationResponse
  { baseCurrency :: Text,
    defaultCurrency :: Text,
    dictionaries :: Map Text DictionaryResponse,
    banking :: BankingConfigurationDTO,
    -- | All per-configuration defaults (categories + accounts), grouped.
    defaults :: ConfigurationDefaultsDTO,
    booksClosedThrough :: Maybe UTCTime,
    -- | Whether the user's base currency can still be changed. False once any
    -- transaction has posted against the user's External account (which anchors
    -- reporting). Computed from the External account's @hasTransactions@ in
    -- the account read model; mirrors the @AccountCurrencyLocked@ precondition
    -- in 'Domain.Account.CommandHandler'.
    baseCurrencyEditable :: Bool,
    -- | Whether the banking feature is globally enabled for this deployment
    -- (banking + Monobank provider both on). Lets clients hide banking UI
    -- without probing a gated endpoint. This field is UNGATED.
    bankingFeatureEnabled :: Bool
  }
  deriving (Show, Eq, Generic)

instance ToJSON ConfigurationResponse

instance FromJSON ConfigurationResponse

-- | Dictionary response DTO.
data DictionaryResponse = DictionaryResponse
  { entries :: [DictionaryEntryResponse]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryResponse

instance FromJSON DictionaryResponse

-- | Dictionary entry response DTO.
data DictionaryEntryResponse = DictionaryEntryResponse
  { id :: UUID,
    name :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryEntryResponse

instance FromJSON DictionaryEntryResponse

-- | Request to change base or default currency.
data ChangeCurrencyRequest = ChangeCurrencyRequest
  { currency :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeCurrencyRequest

instance FromJSON ChangeCurrencyRequest

-- | Request to add a dictionary entry.
data AddEntryRequest = AddEntryRequest
  { name :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AddEntryRequest

instance FromJSON AddEntryRequest

-- | Response after adding a dictionary entry.
data AddEntryResponse = AddEntryResponse
  { id :: UUID,
    name :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AddEntryResponse

instance FromJSON AddEntryResponse

-- | Request to rename a dictionary entry.
data RenameEntryRequest = RenameEntryRequest
  { name :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON RenameEntryRequest

instance FromJSON RenameEntryRequest

-- | Partial-update request body for PUT /api/users/me/configuration/banking.
--
-- Absent or null fields mean no change; present value sets the field.
newtype UpdateBankingRequest = UpdateBankingRequest
  { mccExpenseCategoryMap :: Maybe (Map Text UUID)
  }
  deriving (Show, Eq, Generic)

instance ToJSON UpdateBankingRequest

instance FromJSON UpdateBankingRequest

-- | Partial-update body for PUT /api/users/me/configuration/defaults.
-- Set-only: a present value sets the field; absent OR null means "no change"
-- (matching the existing banking-defaults semantics — there is no clear path).
-- @subtypeAccounts@, when present, replaces the whole per-subtype map.
data UpdateDefaultsRequest = UpdateDefaultsRequest
  { incomeCategory :: Maybe UUID,
    expenseCategory :: Maybe UUID,
    account :: Maybe UUID,
    subtypeAccounts :: Maybe (Map AccountSubtypeKind UUID)
  }
  deriving (Show, Eq, Generic)

instance ToJSON UpdateDefaultsRequest

instance FromJSON UpdateDefaultsRequest

-- | Body for @PUT \/api\/users\/me\/configuration\/books-close@ — sets the
-- inclusive books-closed cutoff to the supplied UTC instant.
newtype CloseBooksThroughRequest = CloseBooksThroughRequest
  { closedThrough :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON CloseBooksThroughRequest

instance FromJSON CloseBooksThroughRequest

-- | Body for @POST …/configuration/banking/connections@.
data AddConnectionRequest = AddConnectionRequest
  { provider :: Text,
    name :: Text,
    token :: Text,
    enabled :: Bool
  }
  deriving (Show, Eq, Generic)

instance ToJSON AddConnectionRequest

instance FromJSON AddConnectionRequest

-- | Body for @PUT …/configuration/banking/connections/:id@.
--
-- Absent fields mean "no change"; present fields are applied.
data UpdateConnectionRequest = UpdateConnectionRequest
  { name :: Maybe Text,
    enabled :: Maybe Bool
  }
  deriving (Show, Eq, Generic)

instance ToJSON UpdateConnectionRequest

instance FromJSON UpdateConnectionRequest

-- | Body for @PUT …/configuration/banking/connections/:id/token@.
newtype ChangeTokenRequest = ChangeTokenRequest
  { token :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeTokenRequest

instance FromJSON ChangeTokenRequest

-- | Body for @PUT …/configuration/banking/connections/:id/accounts@.
newtype SetAccountMapRequest = SetAccountMapRequest
  { accountMap :: Map Text UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetAccountMapRequest

instance FromJSON SetAccountMapRequest

-- | Proxy for the ConfigurationAPI.
configurationAPI :: Proxy ConfigurationAPI
configurationAPI = Proxy

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Configuration API server implementation.
configurationServer :: ServerT ConfigurationAPI AppM
configurationServer =
  getConfigurationHandler
    :<|> changeBaseCurrencyHandler
    :<|> changeDefaultCurrencyHandler
    :<|> updateBankingHandler
    :<|> updateDefaultsHandler
    :<|> closeBooksThroughHandler
    :<|> listDictionaryHandler
    :<|> addEntryHandler
    :<|> renameEntryHandler
    :<|> removeEntryHandler
    :<|> addConnectionHandler
    :<|> updateConnectionHandler
    :<|> changeConnectionTokenHandler
    :<|> removeConnectionHandler
    :<|> setConnectionAccountsHandler

-- -----------------------------------------------------------------------------
-- Handlers
-- -----------------------------------------------------------------------------

-- | Handler for GET /api/users/me/configuration
getConfigurationHandler :: AuthenticatedUser -> AppM ConfigurationResponse
getConfigurationHandler user = do
  result <- ConfigService.getConfigurationForUser user.userId
  case result of
    Left err -> throwDomainError err
    Right configData -> do
      editable <- computeBaseCurrencyEditable user.userId
      featureEnabled <- computeBankingFeatureEnabled
      return $ toConfigurationResponse editable featureEnabled configData

-- | Handler for PUT /api/users/me/configuration/base-currency
changeBaseCurrencyHandler :: AuthenticatedUser -> ChangeCurrencyRequest -> AppM NoContent
changeBaseCurrencyHandler user req = do
  cur <- validateFieldCtx "currency" req.currency $ parseCurrency req.currency
  result <- ConfigService.changeBaseCurrency user.userId cur
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- | Handler for PUT /api/users/me/configuration/default-currency
changeDefaultCurrencyHandler :: AuthenticatedUser -> ChangeCurrencyRequest -> AppM NoContent
changeDefaultCurrencyHandler user req = do
  cur <- validateFieldCtx "currency" req.currency $ parseCurrency req.currency
  result <- ConfigService.changeDefaultCurrency user.userId cur
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- | Handler for PUT /api/users/me/configuration/banking
--
-- Partial update: absent (or null) fields are left unchanged; present values
-- are validated and applied via the Configuration service.
updateBankingHandler :: AuthenticatedUser -> UpdateBankingRequest -> AppM BankingConfigurationDTO
updateBankingHandler user req = do
  let uid = user.userId

  forM_ req.mccExpenseCategoryMap $ \rawMap -> do
    newMap <-
      Map.traverseWithKey
        (\_ uuid -> validateFieldCtx "mccExpenseCategoryMap" (tshow uuid) (mkDictionaryEntryId uuid))
        rawMap
    result <- ConfigService.setBankingMccExpenseCategoryMap uid newMap
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

  result <- ConfigService.getConfigurationForUser uid
  case result of
    Left err -> throwDomainError err
    Right configData -> pure (toBankingDTO configData.banking)

-- | Handler for PUT /api/users/me/configuration/defaults
--
-- Partial update of the grouped defaults: absent (or null) fields are left
-- unchanged; present values are validated and applied via the Configuration
-- service. Set-only for the scalar fields — there is no clear path;
-- @subtypeAccounts@, when present, replaces the whole per-subtype map (send
-- @{}@ to clear it). Account ownership is validated in the service layer.
updateDefaultsHandler :: AuthenticatedUser -> UpdateDefaultsRequest -> AppM ConfigurationResponse
updateDefaultsHandler user req = do
  let uid = user.userId

  forM_ req.incomeCategory $ \uuid -> do
    cid <- validateFieldCtx "incomeCategory" (tshow uuid) (mkDictionaryEntryId uuid)
    result <- ConfigService.setDefaultIncomeCategory uid cid
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

  forM_ req.expenseCategory $ \uuid -> do
    cid <- validateFieldCtx "expenseCategory" (tshow uuid) (mkDictionaryEntryId uuid)
    result <- ConfigService.setDefaultExpenseCategory uid cid
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

  forM_ req.account $ \uuid -> do
    aid <- validateFieldCtx "account" (tshow uuid) (mkAccountId uuid)
    result <- ConfigService.setDefaultAccount uid aid
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

  forM_ req.subtypeAccounts $ \rawMap -> do
    m <-
      Map.traverseWithKey
        (\_ uuid -> validateFieldCtx "subtypeAccounts" (tshow uuid) (mkAccountId uuid))
        rawMap
    result <- ConfigService.setDefaultSubtypeAccounts uid m
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

  result <- ConfigService.getConfigurationForUser uid
  case result of
    Left err -> throwDomainError err
    Right configData -> do
      editable <- computeBaseCurrencyEditable uid
      featureEnabled <- computeBankingFeatureEnabled
      pure (toConfigurationResponse editable featureEnabled configData)

-- | Handler for PUT /api/users/me/configuration/books-close
--
-- Sets the inclusive books-closed cutoff. Service rejects rewind / equal
-- attempts with @CannotRewindBooksCloseDate@ (HTTP 409).
closeBooksThroughHandler :: AuthenticatedUser -> CloseBooksThroughRequest -> AppM ConfigurationResponse
closeBooksThroughHandler user req = do
  result <- ConfigService.closeBooksThrough user.userId req.closedThrough
  case result of
    Left err -> throwDomainError err
    Right configData -> do
      editable <- computeBaseCurrencyEditable user.userId
      featureEnabled <- computeBankingFeatureEnabled
      return $ toConfigurationResponse editable featureEnabled configData

-- | Handler for GET /api/users/me/configuration/dictionaries/:dictId
listDictionaryHandler :: AuthenticatedUser -> Text -> AppM DictionaryResponse
listDictionaryHandler user dictIdText = do
  let dictId = DictionaryId dictIdText
  result <- ConfigService.getConfigurationForUser user.userId
  case result of
    Left err -> throwDomainError err
    Right configData ->
      case Map.lookup dictId configData.dictionaries of
        Nothing -> return $ DictionaryResponse []
        Just dictData ->
          return
            $ DictionaryResponse
              { entries =
                  map
                    (\(eId, eName) -> DictionaryEntryResponse {id = unDictionaryEntryId eId, name = unEntryName eName})
                    (Map.toList dictData.entries)
              }

-- | Handler for POST /api/users/me/configuration/dictionaries/:dictId/entries
addEntryHandler :: AuthenticatedUser -> Text -> AddEntryRequest -> AppM AddEntryResponse
addEntryHandler user dictIdText req = do
  let dictId = DictionaryId dictIdText
  entryName <- validateFieldCtx "name" req.name $ mkEntryName req.name
  result <- ConfigService.addDictionaryEntry user.userId dictId entryName
  case result of
    Left err -> throwDomainError err
    Right entryId ->
      return
        $ AddEntryResponse
          { id = unDictionaryEntryId entryId,
            name = unEntryName entryName
          }

-- | Handler for PUT /api/users/me/configuration/dictionaries/:dictId/entries/:entryId
renameEntryHandler :: AuthenticatedUser -> Text -> UUID -> RenameEntryRequest -> AppM NoContent
renameEntryHandler user dictIdText entryUuid req = do
  let dictId = DictionaryId dictIdText
  entryId <- validateFieldCtx "entryId" (tshow entryUuid) $ mkDictionaryEntryId entryUuid
  entryName <- validateFieldCtx "name" req.name $ mkEntryName req.name
  result <- ConfigService.renameDictionaryEntry user.userId dictId entryId entryName
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- | Handler for DELETE /api/users/me/configuration/dictionaries/:dictId/entries/:entryId
removeEntryHandler :: AuthenticatedUser -> Text -> UUID -> AppM NoContent
removeEntryHandler user dictIdText entryUuid = do
  let dictId = DictionaryId dictIdText
  entryId <- validateFieldCtx "entryId" (tshow entryUuid) $ mkDictionaryEntryId entryUuid
  result <- ConfigService.removeDictionaryEntry user.userId dictId entryId
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- -----------------------------------------------------------------------------
-- Bank-connection handlers
-- -----------------------------------------------------------------------------

-- | Parse the wire provider string into a domain 'BankProvider'.
parseBankProvider :: Text -> Either Text BankProvider
parseBankProvider "monobank" = Right Monobank
parseBankProvider other = Left ("unsupported provider: " <> other)

-- | Handler for POST …/configuration/banking/connections.
--
-- Adds a bank connection and returns its freshly-built DTO (201). The token is
-- accepted in the request body, encrypted by the service, and never echoed.
addConnectionHandler :: AuthenticatedUser -> AddConnectionRequest -> AppM BankConnectionDTO
addConnectionHandler user req = do
  requireBankingEnabled
  provider <- validateFieldCtx "provider" req.provider (parseBankProvider req.provider)
  result <- ConfigService.addBankConnection user.userId provider req.name req.token req.enabled
  case result of
    Left err -> throwDomainError err
    Right connId -> do
      conn <- loadConnection user.userId connId
      pure (toBankConnectionDTO conn)

-- | Handler for PUT …/configuration/banking/connections/:id.
--
-- Applies the rename and/or enabled change for the fields present in the body.
updateConnectionHandler :: AuthenticatedUser -> UUID -> UpdateConnectionRequest -> AppM NoContent
updateConnectionHandler user connUuid req = do
  requireBankingEnabled
  connId <- validateFieldCtx "connId" (tshow connUuid) (mkBankConnectionId connUuid)
  forM_ req.name $ \newName -> do
    result <- ConfigService.renameBankConnection user.userId connId newName
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()
  forM_ req.enabled $ \isEnabled -> do
    result <- ConfigService.setBankConnectionEnabled user.userId connId isEnabled
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()
  pure NoContent

-- | Handler for PUT …/configuration/banking/connections/:id/token.
changeConnectionTokenHandler :: AuthenticatedUser -> UUID -> ChangeTokenRequest -> AppM NoContent
changeConnectionTokenHandler user connUuid req = do
  requireBankingEnabled
  connId <- validateFieldCtx "connId" (tshow connUuid) (mkBankConnectionId connUuid)
  result <- ConfigService.changeBankConnectionToken user.userId connId req.token
  case result of
    Left err -> throwDomainError err
    Right () -> pure NoContent

-- | Handler for DELETE …/configuration/banking/connections/:id.
removeConnectionHandler :: AuthenticatedUser -> UUID -> AppM NoContent
removeConnectionHandler user connUuid = do
  requireBankingEnabled
  connId <- validateFieldCtx "connId" (tshow connUuid) (mkBankConnectionId connUuid)
  result <- ConfigService.removeBankConnection user.userId connId
  case result of
    Left err -> throwDomainError err
    Right () -> pure NoContent

-- | Handler for PUT …/configuration/banking/connections/:id/accounts.
--
-- Validates and converts each external→local mapping target into an 'AccountId',
-- then replaces the connection's account map wholesale. Cross-aggregate
-- ownership validation lives in the service.
setConnectionAccountsHandler :: AuthenticatedUser -> UUID -> SetAccountMapRequest -> AppM NoContent
setConnectionAccountsHandler user connUuid req = do
  requireBankingEnabled
  connId <- validateFieldCtx "connId" (tshow connUuid) (mkBankConnectionId connUuid)
  accountMap <-
    Map.traverseWithKey
      (\_extId uuid -> validateFieldCtx "accountMap" (tshow uuid) (mkAccountId uuid))
      (toExternalKeyedMap req.accountMap)
  result <- ConfigService.setBankConnectionAccountMap user.userId connId accountMap
  case result of
    Left err -> throwDomainError err
    Right () -> pure NoContent

-- | Re-key a @Map Text UUID@ wire map as @Map ExternalAccountId UUID@.
-- 'ExternalAccountId' is a 'Text' alias, so this is identity at runtime but
-- documents the conversion at the type level.
toExternalKeyedMap :: Map Text UUID -> Map ExternalAccountId UUID
toExternalKeyedMap = id

-- | Load a single bank connection for the user, or 'BankConnectionNotFound'.
loadConnection :: UserId -> BankConnectionId -> AppM BankConnection
loadConnection uid connId = do
  result <- ConfigService.getConfigurationForUser uid
  case result of
    Left err -> throwDomainError err
    Right configData ->
      case Map.lookup connId configData.banking.connections of
        Just conn -> pure conn
        Nothing -> throwValidation "connId" "bank connection not found"

-- -----------------------------------------------------------------------------
-- Response Conversion
-- -----------------------------------------------------------------------------

-- | Convert domain ConfigurationData to API response DTO.
--
-- @baseCurrencyEditable@ is supplied by the caller (typically derived from
-- the user's External account via 'computeBaseCurrencyEditable') because
-- that fact lives in the account read model, not in 'ConfigurationData'.
toConfigurationResponse ::
  Bool ->
  Bool ->
  ConfigurationData ->
  ConfigurationResponse
toConfigurationResponse editable featureEnabled configData =
  let ConfigurationDefaults
        { incomeCategory = mIncome,
          expenseCategory = mExpense,
          account = mAccount,
          subtypeAccounts = subAccts
        } = configData.defaults
      defaultsDTO =
        ConfigurationDefaultsDTO
          { incomeCategory = unDictionaryEntryId <$> mIncome,
            expenseCategory = unDictionaryEntryId <$> mExpense,
            account = unAccountId <$> mAccount,
            subtypeAccounts = Map.map unAccountId subAccts
          }
   in ConfigurationResponse
        { baseCurrency = tshow configData.baseCurrency,
          defaultCurrency = tshow configData.defaultCurrency,
          dictionaries =
            Map.mapKeys unDictionaryId
              $ Map.map toDictionaryResponse configData.dictionaries,
          banking = toBankingDTO configData.banking,
          defaults = defaultsDTO,
          booksClosedThrough = configData.booksClosedThrough,
          baseCurrencyEditable = editable,
          bankingFeatureEnabled = featureEnabled
        }

-- | Whether the banking feature is globally enabled (banking + Monobank both
-- on). Read directly from the app config; this is the same predicate the
-- banking feature gate uses.
computeBankingFeatureEnabled :: AppM Bool
computeBankingFeatureEnabled = do
  cfg <- view appConfigL
  pure (bankingFeatureAvailable cfg.banking)

-- | Compute whether the user's base currency can still be changed.
--
-- Returns 'False' once the user's External account has been touched by any
-- posted transaction (which is what the domain command handler uses to
-- reject 'ChangeAccountCurrency' with 'AccountCurrencyLocked'). Defaults to
-- 'True' if the External account can't be located in the read model — the
-- domain layer remains authoritative and will still reject a stale request.
computeBaseCurrencyEditable :: UserId -> AppM Bool
computeBaseCurrencyEditable uid = do
  extResult <- runExceptT (getUserExternalAccountId uid)
  case extResult of
    Left _ -> pure True
    Right extAccId -> do
      mAccount <- runDb (getAccount extAccId)
      pure $ maybe True (not . (.hasTransactions)) mAccount

-- | Convert domain DictionaryData to API response DTO.
toDictionaryResponse ::
  DictionaryData ->
  DictionaryResponse
toDictionaryResponse dictData =
  DictionaryResponse
    { entries =
        map
          (\(eId, eName) -> DictionaryEntryResponse {id = unDictionaryEntryId eId, name = unEntryName eName})
          (Map.toList dictData.entries)
    }
