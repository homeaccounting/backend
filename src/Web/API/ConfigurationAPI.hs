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
--   GET    /api/users/me/configuration/banking/providers                    - List available bank providers
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
    DictionaryEntryNode (..),
    ChangeCurrencyRequest (..),
    UpdateBankingRequest (..),
    UpdateDefaultsRequest (..),
    CloseBooksThroughRequest (..),
    AddEntryRequest (..),
    AddEntryResponse (..),
    RenameEntryRequest (..),
    MoveEntryRequest (..),
    AddConnectionRequest (..),
    UpdateConnectionRequest (..),
    ChangeTokenRequest (..),
    SetAccountMapRequest (..),
    BankProviderDTO (..),

    -- * Server
    configurationServer,

    -- * Response builders
    buildDictionaryResponse,
  )
where

import Application.ReadModels.Account (AccountData (..), getAccount)
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import qualified Application.Services.ConfigurationService as ConfigService
import Application.Services.Internal (getUserExternalAccountId)
import Control.Monad.Except (runExceptT)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Domain.Banking.Types
  ( BankConnectionId,
    BankProviderCredential (..),
    BankProviderId,
    mkBankConnectionId,
    mkBankProviderId,
    mkExternalAccountId,
    unBankConnectionId,
    unBankProviderId,
    unExternalAccountId,
  )
import Domain.Configuration.Dictionary (DictionaryKind, DictionaryNode (..), EntryRole (..), dictionaryKindSlug, parseDictionaryKind)
import Domain.Configuration.Projection
  ( BankConnection (..),
    BankingConfiguration (..),
    ConfigurationDefaults (..),
  )
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountSubtypeKind,
    DictionaryEntryId,
    UserId,
    mkAccountId,
    mkDictionaryEntryId,
    mkEntryName,
    parseBankProviderCategoryKey,
    parseCurrency,
    renderBankProviderCategoryKey,
    unAccountId,
    unDictionaryEntryId,
    unEntryName,
  )
import Infrastructure.App (AppM, HasBankProviderRegistry (..), bankingFeatureEnabled, runDb)
import Infrastructure.Banking.Provider
  ( BankProviderDescriptor (..),
    providerSupportsFile,
    providerSupportsPull,
  )
import Infrastructure.Banking.Registry (lookupProvider, registryBankProviderIds)
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
    -- PATCH …/dictionaries/:dictId/entries/:entryId/parent - Move entry to a new parent
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "dictionaries"
      :> Capture "dictId" Text
      :> "entries"
      :> Capture "entryId" UUID
      :> "parent"
      :> ReqBody '[JSON] MoveEntryRequest
      :> Patch '[JSON] NoContent
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
    -- GET …/configuration/banking/providers - List available bank providers
    --
    -- Authenticated but NOT behind 'requireBankingEnabled': this is just
    -- names/capabilities, and the account-creation UI needs it regardless of
    -- whether banking sync is globally enabled.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "users"
      :> "me"
      :> "configuration"
      :> "banking"
      :> "providers"
      :> Get '[JSON] [BankProviderDTO]

-- -----------------------------------------------------------------------------
-- Request/Response Types
-- -----------------------------------------------------------------------------

-- | Projection of BankingConfiguration for wire transport. The
-- @expenseCategoryMap@ keys are 'BankProviderCategory' key strings
-- (@"mcc:0742"@ / @"label:…"@); already nested under @banking@, so the field
-- needs no @bankProvider@ prefix.
data BankingConfigurationDTO = BankingConfigurationDTO
  { expenseCategoryMap :: Map Text UUID,
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

-- | Wire projection of a single registered 'BankProviderDescriptor', naming
-- the provider and exposing which transport capabilities it supports. This
-- lists every provider in the registry — compiled-in AND enabled — for the
-- account-creation UI to offer, independent of the operational
-- @requireBankingEnabled@ gate.
data BankProviderDTO = BankProviderDTO
  { id :: Text,
    displayName :: Text,
    supportsPull :: Bool,
    supportsFile :: Bool
  }
  deriving (Show, Eq, Generic)

instance ToJSON BankProviderDTO

instance FromJSON BankProviderDTO

-- | Convert a registered 'BankProviderDescriptor' to its wire DTO.
toBankProviderDTO :: BankProviderDescriptor -> BankProviderDTO
toBankProviderDTO d =
  BankProviderDTO
    { id = unBankProviderId d.providerId,
      displayName = d.displayName,
      supportsPull = providerSupportsPull d,
      supportsFile = providerSupportsFile d
    }

-- | Convert a domain 'BankConnection' to its wire DTO. The token is omitted;
-- 'tokenSet' reports whether one is stored. A file-only connection (no
-- credential) reports @tokenSet = False@ and an empty 'tokenHint'.
toBankConnectionDTO :: BankConnection -> BankConnectionDTO
toBankConnectionDTO c =
  BankConnectionDTO
    { id = unBankConnectionId c.connectionId,
      provider = unBankProviderId c.provider,
      name = c.name,
      enabled = c.enabled,
      tokenSet = isJust c.encryptedSecret,
      tokenHint = fromMaybe "" c.secretHint,
      accountMap = Map.mapKeys unExternalAccountId (Map.map unAccountId c.accountMap)
    }

-- | Convert domain BankingConfiguration to its wire DTO.
toBankingDTO :: BankingConfiguration -> BankingConfigurationDTO
toBankingDTO b =
  BankingConfigurationDTO
    { expenseCategoryMap = Map.mapKeys renderBankProviderCategoryKey (Map.map unDictionaryEntryId b.bankProviderExpenseCategoryMap),
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

-- | Dictionary response DTO — a server-materialised tree per dictionary.
--
-- @roots@ carries the nested entry tree so the client renders it directly
-- without any @parentId@ assembly. Each node's role is carried explicitly
-- (ADR 002); there is no per-dictionary @groupsAssignable@ flag.
newtype DictionaryResponse = DictionaryResponse
  { roots :: [DictionaryEntryNode]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryResponse

instance FromJSON DictionaryResponse

-- | A node in the materialised tree. @type@ is "group" or "item"; a group may
-- have children, an item never does. Role is explicit (an empty group has no
-- children yet is still a group).
data DictionaryEntryNode = DictionaryEntryNode
  { id :: UUID,
    name :: Text,
    type_ :: EntryRole,
    children :: [DictionaryEntryNode]
  }
  deriving (Show, Eq, Generic)

-- The JSON key must be @type@ (a Haskell keyword), so map it by hand to the
-- @type_@ field. 'EntryRole' already serialises to "group"/"item".
instance ToJSON DictionaryEntryNode where
  toJSON n =
    object
      [ "id" .= n.id,
        "name" .= n.name,
        "type" .= n.type_,
        "children" .= n.children
      ]

instance FromJSON DictionaryEntryNode where
  parseJSON = withObject "DictionaryEntryNode" $ \o ->
    DictionaryEntryNode
      <$> o
      .: "id"
      <*> o
      .: "name"
      <*> o
      .: "type"
      <*> o
      .: "children"

-- | Request to change base or default currency.
data ChangeCurrencyRequest = ChangeCurrencyRequest
  { currency :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeCurrencyRequest

instance FromJSON ChangeCurrencyRequest

-- | Request to add a dictionary entry.
data AddEntryRequest = AddEntryRequest
  { name :: Text,
    -- | Whether the new entry is a group (container) or item (leaf).
    type_ :: EntryRole,
    -- | Parent group for the new entry, or absent/null for a root-level node.
    parentId :: Maybe UUID
  }
  deriving (Show, Eq, Generic)

-- The JSON key must be @type@ (a Haskell keyword), so map it by hand to the
-- @type_@ field.
instance ToJSON AddEntryRequest where
  toJSON r =
    object
      [ "name" .= r.name,
        "type" .= r.type_,
        "parentId" .= r.parentId
      ]

instance FromJSON AddEntryRequest where
  parseJSON = withObject "AddEntryRequest" $ \o ->
    AddEntryRequest
      <$> o
      .: "name"
      <*> o
      .: "type"
      <*> o
      .:? "parentId"

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

-- | Request to move a dictionary entry to a new parent group. A 'Nothing'
-- (absent or null) @parentId@ moves the entry to the root level.
newtype MoveEntryRequest = MoveEntryRequest
  { parentId :: Maybe UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON MoveEntryRequest

instance FromJSON MoveEntryRequest

-- | Partial-update request body for PUT /api/users/me/configuration/banking.
--
-- Absent or null fields mean no change; present value sets the field.
newtype UpdateBankingRequest = UpdateBankingRequest
  { expenseCategoryMap :: Maybe (Map Text UUID)
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
--
-- @token@ is OPTIONAL: it is required only when the chosen provider supports
-- the pull/API transport ('BankProviderDescriptor.pull' is present); a
-- file-only provider has no credential, so the field may be absent or null.
data AddConnectionRequest = AddConnectionRequest
  { provider :: Text,
    name :: Text,
    token :: Maybe Text,
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
    :<|> moveEntryHandler
    :<|> addConnectionHandler
    :<|> updateConnectionHandler
    :<|> changeConnectionTokenHandler
    :<|> removeConnectionHandler
    :<|> setConnectionAccountsHandler
    :<|> listProvidersHandler

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

  forM_ req.expenseCategoryMap $ \rawMap -> do
    newMap <-
      fmap Map.fromList . forM (Map.toList rawMap) $ \(rawKey, uuid) -> do
        pc <-
          validateFieldCtx
            "expenseCategoryMap"
            rawKey
            (maybe (Left ("Invalid provider-category key: " <> rawKey)) Right (parseBankProviderCategoryKey rawKey))
        cat <- validateFieldCtx "expenseCategoryMap" (tshow uuid) (mkDictionaryEntryId uuid)
        pure (pc, cat)
    result <- ConfigService.setBankProviderExpenseCategoryMap uid newMap
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

-- | Resolve a dictionary slug to its 'DictionaryKind', 404ing on an unknown
-- slug (no more "unknown dictionary id" domain error path).
requireDictionaryKind :: Text -> AppM DictionaryKind
requireDictionaryKind t =
  maybe (throwDomainError (NotFound "Dictionary" t)) pure (parseDictionaryKind t)

-- | Validate an optional parent-entry UUID into a 'DictionaryEntryId',
-- reporting a field-level validation error under @label@ on a malformed value.
-- 'Nothing' (absent/null) passes through as 'Nothing' (root-level target).
validateOptionalEntryId :: Text -> Maybe UUID -> AppM (Maybe DictionaryEntryId)
validateOptionalEntryId label =
  traverse (\u -> validateFieldCtx label (tshow u) (mkDictionaryEntryId u))

-- | Handler for GET /api/users/me/configuration/dictionaries/:dictId
listDictionaryHandler :: AuthenticatedUser -> Text -> AppM DictionaryResponse
listDictionaryHandler user dictIdText = do
  dictKind <- requireDictionaryKind dictIdText
  result <- ConfigService.getConfigurationForUser user.userId
  case result of
    Left err -> throwDomainError err
    Right configData ->
      return
        $ buildDictionaryResponse
        $ Map.findWithDefault (DictionaryData []) dictKind configData.dictionaries

-- | Handler for POST /api/users/me/configuration/dictionaries/:dictId/entries
addEntryHandler :: AuthenticatedUser -> Text -> AddEntryRequest -> AppM AddEntryResponse
addEntryHandler user dictIdText req = do
  dictKind <- requireDictionaryKind dictIdText
  entryName <- validateFieldCtx "name" req.name $ mkEntryName req.name
  parentId <- validateOptionalEntryId "parentId" req.parentId
  result <- ConfigService.addDictionaryEntry user.userId dictKind entryName req.type_ parentId
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
  dictKind <- requireDictionaryKind dictIdText
  entryId <- validateFieldCtx "entryId" (tshow entryUuid) $ mkDictionaryEntryId entryUuid
  entryName <- validateFieldCtx "name" req.name $ mkEntryName req.name
  result <- ConfigService.renameDictionaryEntry user.userId dictKind entryId entryName
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- | Handler for DELETE /api/users/me/configuration/dictionaries/:dictId/entries/:entryId
removeEntryHandler :: AuthenticatedUser -> Text -> UUID -> AppM NoContent
removeEntryHandler user dictIdText entryUuid = do
  dictKind <- requireDictionaryKind dictIdText
  entryId <- validateFieldCtx "entryId" (tshow entryUuid) $ mkDictionaryEntryId entryUuid
  result <- ConfigService.removeDictionaryEntry user.userId dictKind entryId
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- | Handler for PATCH /api/users/me/configuration/dictionaries/:dictId/entries/:entryId/parent
--
-- Moves the entry under a new parent group, or to the root when @newParentId@
-- is 'Nothing'. Tree invariants (parent exists, cycle-free, depth, sibling-name
-- uniqueness) are enforced by the Configuration command handler.
moveEntryHandler :: AuthenticatedUser -> Text -> UUID -> MoveEntryRequest -> AppM NoContent
moveEntryHandler user dictIdText entryUuid req = do
  dictKind <- requireDictionaryKind dictIdText
  entryId <- validateFieldCtx "entryId" (tshow entryUuid) $ mkDictionaryEntryId entryUuid
  newParentId <- validateOptionalEntryId "parentId" req.parentId
  result <- ConfigService.moveDictionaryEntry user.userId dictKind entryId newParentId
  case result of
    Left err -> throwDomainError err
    Right () -> return NoContent

-- -----------------------------------------------------------------------------
-- Bank-connection handlers
-- -----------------------------------------------------------------------------

-- | Validate the wire provider string against the known (registered) providers.
-- Delegates to 'mkBankProviderId', which rejects unknown/unavailable slugs via
-- the standard 'ValidationErr' path.
parseBankProvider :: Set BankProviderId -> Text -> AppM BankProviderId
parseBankProvider known raw =
  case mkBankProviderId known raw of
    Left err -> throwDomainError err
    Right p -> pure p

-- | Handler for POST …/configuration/banking/connections.
--
-- Adds a bank connection and returns its freshly-built DTO (201). The token is
-- accepted in the request body, encrypted by the service, and never echoed.
--
-- The token is required only when the resolved provider supports the
-- pull/API transport; a file-only provider is accepted with no token
-- ('req.token == Nothing'). A missing token for a pull-capable provider is
-- rejected as a field validation error.
addConnectionHandler :: AuthenticatedUser -> AddConnectionRequest -> AppM BankConnectionDTO
addConnectionHandler user req = do
  requireBankingEnabled
  reg <- view bankProviderRegistryL
  provider <- parseBankProvider (registryBankProviderIds reg) req.provider
  case lookupProvider provider reg of
    Just desc
      | providerSupportsPull desc && isNothing req.token ->
          throwValidation "token" "token is required for a provider that supports live sync"
    _ -> pure ()
  result <- ConfigService.addBankConnection user.userId provider req.name (StaticSecret <$> req.token) req.enabled
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
  result <- ConfigService.changeBankConnectionCredential user.userId connId (StaticSecret req.token)
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
    Map.fromList
      <$> traverse
        ( \(extIdText, uuid) -> do
            extId <- validateFieldCtx "accountMap" extIdText (mkExternalAccountId extIdText)
            accId <- validateFieldCtx "accountMap" (tshow uuid) (mkAccountId uuid)
            pure (extId, accId)
        )
        (Map.toList req.accountMap)
  result <- ConfigService.setBankConnectionAccountMap user.userId connId accountMap
  case result of
    Left err -> throwDomainError err
    Right () -> pure NoContent

-- | Handler for GET …/configuration/banking/providers.
--
-- Lists every provider currently in the registry (compiled-in AND enabled)
-- with its capability flags. Deliberately NOT behind 'requireBankingEnabled':
-- it's just names/capabilities, and the account-creation UI needs this
-- regardless of whether banking sync is globally on.
listProvidersHandler :: AuthenticatedUser -> AppM [BankProviderDTO]
listProvidersHandler _user = do
  reg <- view bankProviderRegistryL
  pure $ map toBankProviderDTO (Map.elems reg)

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
            Map.mapKeys dictionaryKindSlug
              $ Map.map buildDictionaryResponse configData.dictionaries,
          banking = toBankingDTO configData.banking,
          defaults = defaultsDTO,
          booksClosedThrough = configData.booksClosedThrough,
          baseCurrencyEditable = editable,
          bankingFeatureEnabled = featureEnabled
        }

-- | Whether the banking feature is globally enabled, feeding the ungated
-- @bankingFeatureEnabled@ DTO field. Delegates to the shared
-- 'Infrastructure.App.bankingFeatureEnabled' predicate — the same one the
-- banking feature gate ('requireBankingEnabled') wraps — so the two cannot
-- drift.
computeBankingFeatureEnabled :: AppM Bool
computeBankingFeatureEnabled = bankingFeatureEnabled

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

-- | Map the read-model's already-materialised dictionary tree onto the nested
-- tree DTO. Each node carries its role explicitly ("group" / "item"); an item
-- is always a leaf.
--
-- Sibling order follows the read model's per-parent grouping and is out of
-- scope (see the design spec) — it is NOT id-sorted and callers must not rely
-- on it. Orphans and corrupt cycles were already dropped when the tree was
-- materialised in 'loadDictionaries', so this mapping is total.
buildDictionaryResponse :: DictionaryData -> DictionaryResponse
buildDictionaryResponse dictData =
  DictionaryResponse {roots = map toNode dictData.roots}
  where
    toNode :: DictionaryNode -> DictionaryEntryNode
    toNode (ItemNode eid nm) =
      DictionaryEntryNode {id = unDictionaryEntryId eid, name = unEntryName nm, type_ = ItemRole, children = []}
    toNode (GroupNode eid nm kids) =
      DictionaryEntryNode {id = unDictionaryEntryId eid, name = unEntryName nm, type_ = GroupRole, children = map toNode kids}
