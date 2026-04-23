{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.TransactionEditFixture
-- Description : Shared HTTP fixture for the transaction label / category edit specs.
--
-- Both 'Web.API.TransactionLabelsAPISpec' and
-- 'Web.API.TransactionCategoryAPISpec' share the same seed strategy:
-- register a user, populate labels + income-category dictionaries,
-- create a Regular account, mint a JWT signed for that user, and drive
-- HTTP requests directly via 'Network.Wai.Test' (the shared-app
-- @with mkApp@ pattern doesn't fit — each scenario wants a fresh,
-- independently seeded env).
--
-- The fixture is intentionally not re-used by the integration specs;
-- those run through the service layer and don't need the HTTP wiring.
module Testkit.TransactionEditFixture
  ( Seed (..),
    mkSeed,
    seedToken,
    seedIncomeTransaction,
    seedInternalTransfer,
    createRegularAccount,
    authHeaders,
    httpRequest,
    uuidText,
  )
where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    incomeCategoryDictId,
    labelsDictId,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError)
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    DictionaryEntryId,
    TransactionId,
    UserId,
    defaultCash,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Network.HTTP.Types (hAuthorization, hContentType)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application)
import qualified Network.Wai as Wai
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, runSession, setPath, srequest)
import RIO
import Web.Server (buildApplication)

-- | Handles to the pre-seeded state a test needs to build requests.
data Seed = Seed
  { seedApp :: !Application,
    seedEnv :: !AppEnv,
    seedUserId :: !UserId,
    seedEmail :: !Text,
    seedAccount :: !AccountId,
    seedLabelA :: !DictionaryEntryId,
    seedLabelB :: !DictionaryEntryId,
    seedCategory :: !DictionaryEntryId
  }

-- | Seed an env (with or without the transfer process manager), register
-- a user, populate labels + the first income category, and create a
-- starting Regular account.
mkSeed :: IO AppEnv -> Text -> IO Seed
mkSeed mkEnv email = do
  env <- mkEnv
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  labelA <- addLabel env uid "kids"
  labelB <- addLabel env uid "school"
  categoryId <- firstIncomeCategory env uid
  accId <- createRegularAccount env uid "Wallet"
  pure
    Seed
      { seedApp = buildApplication env,
        seedEnv = env,
        seedUserId = uid,
        seedEmail = email,
        seedAccount = accId,
        seedLabelA = labelA,
        seedLabelB = labelB,
        seedCategory = categoryId
      }

registerUser :: AppEnv -> Text -> IO UserId
registerUser env email = do
  res <- runAppM env $ register email "password123"
  case res of
    Left err -> fail $ "register failed: " <> show err
    Right auth -> pure auth.userId

addLabel :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
addLabel env uid name = do
  res <- runAppM env $ addDictionaryEntry uid labelsDictId (unsafeEntryName name)
  unwrap ("addDictionaryEntry " <> show name) res

firstIncomeCategory :: AppEnv -> UserId -> IO DictionaryEntryId
firstIncomeCategory env uid = do
  mUser <- getUser env.userReadModel uid
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- ConfigRM.getConfiguration env.configurationReadModel ud.configurationId
      case mCfg of
        Nothing -> fail "configuration not found"
        Just cfg ->
          case Map.lookup incomeCategoryDictId cfg.dictionaries of
            Nothing -> fail "income-category dictionary missing"
            Just dict ->
              case Map.keys dict.entries of
                (eid : _) -> pure eid
                [] -> fail "income-category dictionary is empty"

createRegularAccount :: AppEnv -> UserId -> Text -> IO AccountId
createRegularAccount env uid accName = do
  res <-
    runAppM env
      $ createAccount
      $ CreateAccount
        { name = accName,
          initialBalance = unsafeMoney Core.USD 5000,
          createdBy = uid,
          accountType = Regular defaultCash,
          overdraftLimit = Nothing
        }
  case res of
    Left err -> fail $ "createAccount failed: " <> show err
    Right (aid, _) -> pure aid

unwrap :: String -> Either DomainError a -> IO a
unwrap ctx = \case
  Left err -> fail $ ctx <> " failed: " <> show err
  Right v -> pure v

-- | Mint a JWT signed for the seeded user so @AuthProtect \"jwt\"@
-- resolves back to the same 'UserId' that owns the seeded transaction.
seedToken :: Seed -> IO Text
seedToken seed = do
  res <- generateToken defaultJWTConfig seed.seedUserId seed.seedEmail
  case res of
    Left err -> fail $ "generateToken failed: " <> show err
    Right tok -> pure tok

-- | Create a Completed (with process manager) or Pending (without)
-- income transaction on the seeded account.
seedIncomeTransaction ::
  Seed ->
  Set DictionaryEntryId ->
  IO TransactionId
seedIncomeTransaction seed labels = do
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateIncome
        seed.seedUserId
        seed.seedAccount
        (unsafeMoney Core.USD 25)
        seed.seedCategory
        labels
        "Seed"
        Nothing
  case res of
    Left err -> fail $ "seedIncomeTransaction failed: " <> show err
    Right (txId, _) -> pure txId

-- | Create a Completed (with process manager) or Pending (without)
-- internal transfer between the seeded account and a fresh second one.
seedInternalTransfer :: Seed -> IO TransactionId
seedInternalTransfer seed = do
  other <- createRegularAccount seed.seedEnv seed.seedUserId "Other"
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateInternalTransfer
        seed.seedUserId
        seed.seedAccount
        other
        (unsafeMoney Core.USD 10)
        Set.empty
        "Seed transfer"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "seedInternalTransfer failed: " <> show err
    Right (txId, _) -> pure txId

-- | @Authorization: Bearer ...@ plus @Content-Type: application/json@.
authHeaders :: Text -> [Header]
authHeaders token =
  [ (hContentType, "application/json"),
    (hAuthorization, "Bearer " <> encodeUtf8 token)
  ]

-- | Render a UUID as lower-case text suitable for a JSON field.
uuidText :: UUID -> Text
uuidText = T.pack . UUID.toString

-- | Run a single-request interaction against a pre-built 'Application'.
-- Each spec wants a freshly seeded env, so the shared @with mkApp@
-- fixture from hspec-wai doesn't fit — we drive the app directly via
-- 'Network.Wai.Test'.
httpRequest ::
  Application ->
  ByteString ->
  ByteString ->
  [Header] ->
  LBS.ByteString ->
  IO SResponse
httpRequest app method path headers body = do
  let baseReq = setPath defaultRequest path
      req =
        baseReq
          { Wai.requestMethod = method,
            Wai.requestHeaders = headers
          }
      sreq = SRequest req body
  runSession (srequest sreq) app
