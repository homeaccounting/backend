{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.AccountAPISpec
-- Description : Account HTTP endpoints — balance adjustment and close/reopen
--
-- Exercises endpoints through the full Servant stack via per-test seeded
-- environments.  Each test registers a fresh user, creates an account, and
-- drives requests through 'Testkit.TransactionEditFixture.httpRequest' so
-- the in-memory event store is in a clean state.
--
-- PUT /api/accounts/:id/balance — error → HTTP mapping verified:
--   200  happy path: positive adjustment recorded and response matches
--   400  Viewer role rejection (AccountError → 400)
--   400  currency mismatch (ValidationErr → 400)
--   400  date in the future (ValidationErr → 400)
--   400  zero delta / target equals current balance (ValidationErr → 400)
--   400  External account (ValidationErr → 400)
--   404  unknown account (NotFound → 404)
--
-- POST /api/accounts/:id/close and /reopen:
--   200  close then reopen round-trips; GET reflects status change each step
module Web.API.AccountAPISpec (spec) where

import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (shareAccount)
import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (UTCTime (..), addUTCTime, getCurrentTime, secondsToDiffTime)
import Data.Time.Calendar (fromGregorian)
import qualified Data.UUID as UUID
import Domain.Core.Types (UserId, unAccountId, unUserId)
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Network.HTTP.Types (status200, status400, status404)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, registerUser)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.TransactionEditFixture (authHeaders, httpRequest)
import Web.API.AccountAPI (AccountAccessEntry (..), AccountAccessListResponse (..))
import Web.Server (buildApplication)
import Web.Types
  ( AccountListResponse (..),
    AccountResponse (..),
    ErrorResponse (..),
    TransactionResponse (..),
    ValidationErrorResponse (..),
  )

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "PUT /api/accounts/:id/balance" $ do
    it
      "returns 200 with the resulting transaction for a positive adjustment"
      happyPathSpec

    it "returns 400 when caller has Viewer role" viewerRejectionSpec

    it "returns 404 when account does not exist" accountNotFoundSpec

    it
      "returns 400 when targetBalance currency does not match"
      currencyMismatchSpec

    it "returns 400 when date is in the future" futureDateSpec

    it
      "returns 400 when delta is zero (target equals current balance)"
      zeroDeltaSpec

    it "returns 400 when account is External" externalAccountSpec

  describe "POST /api/accounts/:id/close and /reopen" $ do
    it "closes then reopens, reporting status on GET" closeReopenEndpointSpec

  describe "GET /api/accounts" $ do
    it "includes role on listed accounts" listRoleSpec

    it "includes role for a shared (non-owner) user" listRoleSharedSpec

  describe "GET /api/accounts/:id/access" $ do
    it "returns the access list with roles and email labels for the owner" accessListOwnerSpec

    it "returns 404 for a non-owner requester" accessListNonOwnerSpec

-- -----------------------------------------------------------------------------
-- Fixture
-- -----------------------------------------------------------------------------

-- | Pre-seeded state for a single test scenario.
data Fixture = Fixture
  { fApp :: !Application,
    fEnv :: !AppEnv,
    fToken :: !Text,
    fAccountUuid :: !UUID.UUID,
    fUserId :: !UserId
  }

mkFixture :: Text -> IO Fixture
mkFixture email = do
  env <- createTestAppEnvWithProcessManager
  uid <- registerUser env email
  accId <- createDefaultAccount env uid "Wallet"
  tok <- mintToken uid email
  pure
    Fixture
      { fApp = buildApplication env,
        fEnv = env,
        fToken = tok,
        fAccountUuid = unAccountId accId,
        fUserId = uid
      }

-- | Mint a JWT for an existing user.
mintToken :: UserId -> Text -> IO Text
mintToken uid email = do
  res <- generateToken defaultJWTConfig uid email
  case res of
    Left err -> fail $ "mintToken failed: " <> show err
    Right tok -> pure tok

-- | A fixed past timestamp well before any test run.
pastTime :: UTCTime
pastTime = UTCTime (fromGregorian 2020 1 1) (secondsToDiffTime 0)

-- | Build the JSON body for a set-balance request.
adjustBody :: Double -> Text -> UTCTime -> Text -> LBS.ByteString
adjustBody balance cur at description =
  encode
    $ object
      [ "targetBalance" .= balance,
        "currency" .= cur,
        "date" .= at,
        "description" .= description
      ]

-- | PUT to PUT /api/accounts/:id/balance.
putBalance :: Fixture -> UUID.UUID -> LBS.ByteString -> IO SResponse
putBalance f accUuid =
  httpRequest
    f.fApp
    "PUT"
    (encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString accUuid) <> "/balance")
    (authHeaders f.fToken)

-- -----------------------------------------------------------------------------
-- Scenarios
-- -----------------------------------------------------------------------------

-- | 200: positive delta produces a Completed transaction in the response.
happyPathSpec :: IO ()
happyPathSpec = do
  f <- mkFixture "adjust-happy@test.com"
  -- The account starts at 5000 USD.  Adjust to 6000 => positive delta.
  let body = adjustBody 6000.0 "USD" pastTime "Reconcile"
  resp <- putBalance f f.fAccountUuid body
  simpleStatus resp `shouldBe` status200
  case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
    Left err -> expectationFailure $ "200 body is not a TransactionResponse: " <> err
    Right tx -> do
      tx.description `shouldBe` "Reconcile"
      tx.status `shouldBe` "Completed"

-- | 400: Viewer-role caller is rejected with ACCOUNT_ERROR.
viewerRejectionSpec :: IO ()
viewerRejectionSpec = do
  f <- mkFixture "adjust-viewer-owner@test.com"
  -- Register a second user and share the account with Viewer role.
  viewerId <- registerUser f.fEnv "adjust-viewer-user@test.com"
  shareResult <-
    runAppM f.fEnv
      $ shareAccount f.fUserId f.fAccountUuid (unUserId viewerId) "viewer"
  case shareResult of
    Left err -> fail $ "shareAccount failed: " <> show err
    Right () -> pure ()
  viewerToken <- mintToken viewerId "adjust-viewer-user@test.com"
  let viewerF = f {fToken = viewerToken}
  let body = adjustBody 6000.0 "USD" pastTime "Viewer attempt"
  resp <- putBalance viewerF f.fAccountUuid body
  simpleStatus resp `shouldBe` status400
  case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
    Left err -> expectationFailure $ "400 body is not an ErrorResponse: " <> err
    Right errResp -> errResp.code `shouldBe` "ACCOUNT_ERROR"

-- | 404: unknown account UUID is rejected before any business logic.
accountNotFoundSpec :: IO ()
accountNotFoundSpec = do
  f <- mkFixture "adjust-notfound@test.com"
  let unknownUuid = UUID.fromWords 0xDEAD 0xBEEF 0 1
  let body = adjustBody 100.0 "USD" pastTime "Ghost account"
  resp <- putBalance f unknownUuid body
  simpleStatus resp `shouldBe` status404
  case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
    Left err -> expectationFailure $ "404 body is not an ErrorResponse: " <> err
    Right errResp -> errResp.code `shouldBe` "NOT_FOUND"

-- | 400: currency mismatch (USD account, EUR request).
--
-- 'ValidationErr' maps to 400 via 'Web.ErrorMapping.mapDomainError'.
currencyMismatchSpec :: IO ()
currencyMismatchSpec = do
  f <- mkFixture "adjust-currency@test.com"
  -- Account is seeded as USD; send EUR.
  let body = adjustBody 6000.0 "EUR" pastTime "Wrong currency"
  resp <- putBalance f f.fAccountUuid body
  simpleStatus resp `shouldBe` status400
  case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
    Left err -> expectationFailure $ "400 body is not a ValidationErrorResponse: " <> err
    Right ve ->
      Map.lookup "currency" ve.fieldErrors `shouldNotBe` Nothing

-- | 400: business date is in the future.
--
-- Date guard fires before account lookup, so only a valid token is needed.
futureDateSpec :: IO ()
futureDateSpec = do
  f <- mkFixture "adjust-future@test.com"
  future <- fmap (addUTCTime 3600) getCurrentTime
  let body = adjustBody 6000.0 "USD" future "Time traveller"
  resp <- putBalance f f.fAccountUuid body
  simpleStatus resp `shouldBe` status400
  case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
    Left err -> expectationFailure $ "400 body is not a ValidationErrorResponse: " <> err
    Right ve ->
      Map.lookup "date" ve.fieldErrors `shouldNotBe` Nothing

-- | 400: target balance matches current balance (zero delta).
zeroDeltaSpec :: IO ()
zeroDeltaSpec = do
  f <- mkFixture "adjust-zero@test.com"
  -- 'createDefaultAccount' seeds the account with 5000 USD; sending 5000 is a no-op.
  let body = adjustBody 5000.0 "USD" pastTime "No-op"
  resp <- putBalance f f.fAccountUuid body
  simpleStatus resp `shouldBe` status400
  case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
    Left err -> expectationFailure $ "400 body is not a ValidationErrorResponse: " <> err
    Right ve ->
      Map.lookup "targetBalance" ve.fieldErrors `shouldNotBe` Nothing

-- | 400: cannot adjust an External account.
externalAccountSpec :: IO ()
externalAccountSpec = do
  f <- mkFixture "adjust-external@test.com"
  -- Retrieve the user's external account UUID from the read model.
  mUser <- runDbIn f.fEnv (getUser f.fUserId)
  externalUuid <- case mUser of
    Nothing -> fail "externalAccountSpec: user not found in read model"
    Just ud -> pure $ unAccountId ud.externalAccountId
  -- Use a non-zero target so the External-account rejection is unambiguously
  -- the only 400 path (a zero target would also trip the no-op delta check).
  let body = adjustBody 50.0 "USD" pastTime "External attempt"
  resp <- putBalance f externalUuid body
  simpleStatus resp `shouldBe` status400
  case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
    Left err -> expectationFailure $ "400 body is not a ValidationErrorResponse: " <> err
    Right ve ->
      Map.lookup "accountType" ve.fieldErrors `shouldNotBe` Nothing

-- | 200/200: close then reopen round-trips via the HTTP layer, and GET
-- reflects the status change on each step.
closeReopenEndpointSpec :: IO ()
closeReopenEndpointSpec = do
  f <- mkFixture "close-endpoint@test.com"
  let accPath seg = encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString f.fAccountUuid) <> seg
      getAcc = httpRequest f.fApp "GET" (accPath "") (authHeaders f.fToken) ""
      postAction seg = httpRequest f.fApp "POST" (accPath seg) (authHeaders f.fToken) ""
      decodeAccount resp = case eitherDecode (simpleBody resp) :: Either String AccountResponse of
        Right ar -> pure ar
        Left err -> fail ("AccountResponse decode failed: " <> err)

  -- Precondition: a freshly created account is Opened.
  before <- getAcc
  simpleStatus before `shouldBe` status200
  arBefore <- decodeAccount before
  arBefore.status `shouldBe` "Opened"

  -- Close -> 200, and the account now reports Closed.
  closed <- postAction "/close"
  simpleStatus closed `shouldBe` status200
  arAfterClose <- decodeAccount =<< getAcc
  arAfterClose.status `shouldBe` "Closed"

  -- Reopen -> 200, and the account reports Opened again.
  reopened <- postAction "/reopen"
  simpleStatus reopened `shouldBe` status200
  arAfterReopen <- decodeAccount =<< getAcc
  arAfterReopen.status `shouldBe` "Opened"

-- | GET /api/accounts includes the requesting user's role, "owner" for the
-- creator of the account (tracker#29).
listRoleSpec :: IO ()
listRoleSpec = do
  f <- mkFixture "list-role@test.com"
  resp <- httpRequest f.fApp "GET" "/api/accounts" (authHeaders f.fToken) ""
  simpleStatus resp `shouldBe` status200
  case eitherDecode (simpleBody resp) :: Either String AccountListResponse of
    Left err -> expectationFailure ("decode failed: " <> err)
    Right (AccountListResponse accs _) ->
      case accs of
        (a : _) -> a.role `shouldBe` ("owner" :: Text)
        [] -> expectationFailure "expected at least one account"

-- | GET /api/accounts includes the requesting user's role, "editor" for a
-- non-owner who was shared access, exercising Task 2's role-resolution path
-- on the list endpoint (tracker#29).
listRoleSharedSpec :: IO ()
listRoleSharedSpec = do
  f <- mkFixture "list-share-owner@test.com"
  viewerId <- registerUser f.fEnv "list-share-viewer@test.com"
  shareResult <-
    runAppM f.fEnv
      $ shareAccount f.fUserId f.fAccountUuid (unUserId viewerId) "editor"
  case shareResult of
    Left err -> fail $ "shareAccount failed: " <> show err
    Right () -> pure ()
  viewerTok <- mintToken viewerId "list-share-viewer@test.com"
  resp <- httpRequest f.fApp "GET" "/api/accounts" (authHeaders viewerTok) ""
  simpleStatus resp `shouldBe` status200
  case eitherDecode (simpleBody resp) :: Either String AccountListResponse of
    Left err -> expectationFailure ("decode failed: " <> err)
    Right (AccountListResponse accs _) ->
      case filter (\a -> a.id == f.fAccountUuid) accs of
        (a : _) -> a.role `shouldBe` ("editor" :: Text)
        [] -> expectationFailure "shared account not visible to editor"

-- | GET /api/accounts/:id/access - owner sees the full access list
-- (owner + shared users) with roles and email labels (tracker#29).
accessListOwnerSpec :: IO ()
accessListOwnerSpec = do
  f <- mkFixture "acl-owner@test.com"
  viewerId <- registerUser f.fEnv "acl-viewer@test.com"
  shareResult <-
    runAppM f.fEnv
      $ shareAccount f.fUserId f.fAccountUuid (unUserId viewerId) "viewer"
  case shareResult of
    Left err -> fail $ "shareAccount failed: " <> show err
    Right () -> pure ()
  let path = encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString f.fAccountUuid) <> "/access"
  resp <- httpRequest f.fApp "GET" path (authHeaders f.fToken) ""
  simpleStatus resp `shouldBe` status200
  case eitherDecode (simpleBody resp) :: Either String AccountAccessListResponse of
    Left err -> expectationFailure ("decode failed: " <> err)
    Right (AccountAccessListResponse entries) -> do
      length entries `shouldBe` 2
      any (\e -> e.role == ("owner" :: Text)) entries `shouldBe` True
      any (\e -> e.role == "viewer" && e.email == Just "acl-viewer@test.com") entries `shouldBe` True

-- | GET /api/accounts/:id/access - a non-owner (even one with access)
-- receives 404, not a distinct 403, to hide the account's existence.
accessListNonOwnerSpec :: IO ()
accessListNonOwnerSpec = do
  f <- mkFixture "acl-owner2@test.com"
  viewerId <- registerUser f.fEnv "acl-viewer2@test.com"
  shareResult <-
    runAppM f.fEnv
      $ shareAccount f.fUserId f.fAccountUuid (unUserId viewerId) "viewer"
  case shareResult of
    Left err -> fail $ "shareAccount failed: " <> show err
    Right () -> pure ()
  viewerTok <- mintToken viewerId "acl-viewer2@test.com"
  let path = encodeUtf8 $ "/api/accounts/" <> T.pack (UUID.toString f.fAccountUuid) <> "/access"
  resp <- httpRequest f.fApp "GET" path (authHeaders viewerTok) ""
  simpleStatus resp `shouldBe` status404
