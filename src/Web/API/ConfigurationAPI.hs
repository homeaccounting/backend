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
--   PUT    /api/users/me/configuration/banking                               - Update banking defaults
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
    BankingConfigurationDTO (..),
    DictionaryResponse (..),
    DictionaryEntryResponse (..),
    ChangeCurrencyRequest (..),
    UpdateBankingRequest (..),
    AddEntryRequest (..),
    AddEntryResponse (..),
    RenameEntryRequest (..),

    -- * Server
    configurationServer,
  )
where

import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import qualified Application.Services.ConfigurationService as ConfigService
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map.Strict as Map
import Data.UUID (UUID)
import Domain.Configuration.Projection (BankingConfiguration (..))
import Domain.Core.Types
  ( DictionaryId (..),
    mkDictionaryEntryId,
    mkEntryName,
    parseCurrency,
    unDictionaryEntryId,
    unDictionaryId,
    unEntryName,
  )
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
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

-- -----------------------------------------------------------------------------
-- Request/Response Types
-- -----------------------------------------------------------------------------

-- | Projection of BankingConfiguration for wire transport.
data BankingConfigurationDTO = BankingConfigurationDTO
  { defaultIncomeCategory :: Maybe UUID,
    defaultExpenseCategory :: Maybe UUID,
    mccExpenseCategoryMap :: Map Text UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON BankingConfigurationDTO

instance FromJSON BankingConfigurationDTO

-- | Convert domain BankingConfiguration to its wire DTO.
toBankingDTO :: BankingConfiguration -> BankingConfigurationDTO
toBankingDTO b =
  BankingConfigurationDTO
    { defaultIncomeCategory = unDictionaryEntryId <$> b.defaultIncomeCategory,
      defaultExpenseCategory = unDictionaryEntryId <$> b.defaultExpenseCategory,
      mccExpenseCategoryMap = Map.map unDictionaryEntryId b.mccExpenseCategoryMap
    }

-- | Configuration response DTO.
data ConfigurationResponse = ConfigurationResponse
  { baseCurrency :: Text,
    defaultCurrency :: Text,
    dictionaries :: Map Text DictionaryResponse,
    banking :: BankingConfigurationDTO
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
data UpdateBankingRequest = UpdateBankingRequest
  { defaultIncomeCategory :: Maybe UUID,
    defaultExpenseCategory :: Maybe UUID,
    mccExpenseCategoryMap :: Maybe (Map Text UUID)
  }
  deriving (Show, Eq, Generic)

instance ToJSON UpdateBankingRequest

instance FromJSON UpdateBankingRequest

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
    :<|> listDictionaryHandler
    :<|> addEntryHandler
    :<|> renameEntryHandler
    :<|> removeEntryHandler

-- -----------------------------------------------------------------------------
-- Handlers
-- -----------------------------------------------------------------------------

-- | Handler for GET /api/users/me/configuration
getConfigurationHandler :: AuthenticatedUser -> AppM ConfigurationResponse
getConfigurationHandler user = do
  result <- ConfigService.getConfigurationForUser user.userId
  case result of
    Left err -> throwDomainError err
    Right configData -> return $ toConfigurationResponse configData

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

  forM_ req.defaultIncomeCategory $ \uuid -> do
    cid <- validateFieldCtx "defaultIncomeCategory" (tshow uuid) (mkDictionaryEntryId uuid)
    result <- ConfigService.setBankingDefaultIncomeCategory uid cid
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

  forM_ req.defaultExpenseCategory $ \uuid -> do
    cid <- validateFieldCtx "defaultExpenseCategory" (tshow uuid) (mkDictionaryEntryId uuid)
    result <- ConfigService.setBankingDefaultExpenseCategory uid cid
    case result of
      Left err -> throwDomainError err
      Right () -> pure ()

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
-- Response Conversion
-- -----------------------------------------------------------------------------

-- | Convert domain ConfigurationData to API response DTO.
toConfigurationResponse ::
  ConfigurationData ->
  ConfigurationResponse
toConfigurationResponse configData =
  ConfigurationResponse
    { baseCurrency = tshow configData.baseCurrency,
      defaultCurrency = tshow configData.defaultCurrency,
      dictionaries =
        Map.mapKeys unDictionaryId
          $ Map.map toDictionaryResponse configData.dictionaries,
      banking = toBankingDTO configData.banking
    }

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
