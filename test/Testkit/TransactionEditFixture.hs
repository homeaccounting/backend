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
    seedTransfer,
    addIncomeCategory,
    addExpenseCategory,
    authHeaders,
    httpRequest,
    uuidText,
  )
where

import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    expenseCategoryDictId,
    incomeCategoryDictId,
    labelsDictId,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError)
import Domain.Core.Types
  ( AccountId,
    DictionaryEntryId,
    TransactionId,
    UserId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv, runAppM)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Network.HTTP.Types (hAuthorization, hContentType)
import Network.HTTP.Types.Header (Header)
import Network.Wai (Application)
import qualified Network.Wai as Wai
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, runSession, setPath, srequest)
import RIO
import Testkit.Fixtures (createDefaultAccount, firstDictionaryEntry, registerUser)
import Testkit.Helpers (singletonAllocation)
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
  categoryId <- firstDictionaryEntry env uid incomeCategoryDictId
  accId <- createDefaultAccount env uid "Wallet"
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

addLabel :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
addLabel env uid name = do
  res <- runAppM env $ addDictionaryEntry uid labelsDictId (unsafeEntryName name)
  unwrap ("addDictionaryEntry " <> show name) res

-- | Add a fresh income-category entry to the seed user's dictionary and
-- return its id. Used by specs that need to construct multi-allocation
-- payloads without colliding with the default-seeded entry.
addIncomeCategory :: Seed -> Text -> IO DictionaryEntryId
addIncomeCategory seed name = do
  res <-
    runAppM seed.seedEnv
      $ addDictionaryEntry seed.seedUserId incomeCategoryDictId (unsafeEntryName name)
  unwrap ("addIncomeCategory " <> show name) res

-- | Add a fresh expense-category entry to the seed user's dictionary
-- and return its id. Parallel to 'addIncomeCategory' for specs that
-- exercise the expense side of the allocations endpoint.
addExpenseCategory :: Seed -> Text -> IO DictionaryEntryId
addExpenseCategory seed name = do
  res <-
    runAppM seed.seedEnv
      $ addDictionaryEntry seed.seedUserId expenseCategoryDictId (unsafeEntryName name)
  unwrap ("addExpenseCategory " <> show name) res

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
        (singletonAllocation seed.seedCategory (unsafeMoney Core.USD 25))
        labels
        "Seed"
        Nothing
  case res of
    Left err -> fail $ "seedIncomeTransaction failed: " <> show err
    Right (txId, _) -> pure txId

-- | Create a Completed (with process manager) or Pending (without)
-- internal transfer between the seeded account and a fresh second one.
seedTransfer :: Seed -> IO TransactionId
seedTransfer seed = do
  other <- createDefaultAccount seed.seedEnv seed.seedUserId "Other"
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateTransfer
        seed.seedUserId
        seed.seedAccount
        other
        (unsafeMoney Core.USD 10)
        Set.empty
        "Seed transfer"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "seedTransfer failed: " <> show err
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
